//! Media Foundation H.264 encoder wrapper with trial-encode arbitration
//! (discrete GPU > integrated GPU > CPU candidates, first working wins).

use anyhow::{bail, Context, Result};
use windows::core::{Interface, VARIANT};
use windows::Win32::Media::MediaFoundation::{
    IMFActivate, IMFMediaEventGenerator, IMFMediaType, IMFSample, IMFTransform, ICodecAPI, MFCreateMediaType,
    MFCreateMemoryBuffer, MFCreateSample, MFMediaType_Video, MFVideoFormat_H264, MFVideoFormat_I420, MFVideoFormat_IYUV,
    MFVideoFormat_NV12, MFVideoFormat_YV12, MFVideoInterlace_Progressive, MFSampleExtension_Discontinuity,
    METransformDrainComplete, METransformHaveOutput, METransformNeedInput, MFT_MESSAGE_COMMAND_DRAIN,
    MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_NOTIFY_END_OF_STREAM, MFT_MESSAGE_NOTIFY_START_OF_STREAM,
    MFT_OUTPUT_DATA_BUFFER, MF_EVENT_FLAG_NO_WAIT, MF_MT_AVG_BITRATE, MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE,
    MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_MPEG_SEQUENCE_HEADER, MF_MT_SUBTYPE, MF_TRANSFORM_ASYNC,
    MF_TRANSFORM_ASYNC_UNLOCK, CODECAPI_AVEncCommonLowLatency, CODECAPI_AVEncCommonMeanBitRate, CODECAPI_AVEncCommonRateControlMode, CODECAPI_AVEncVideoGradualIntraRefresh,
    CODECAPI_AVEncMPVDefaultBPictureCount, CODECAPI_AVEncVideoForceKeyFrame, CODECAPI_AVEncVideoMaxNumRefFrame,
};

use crate::windows_encoders::h264_encoder_candidates;

const HRESULT_NEED_MORE_INPUT: i32 = 0xC00D6D72u32 as i32;
const HRESULT_STREAM_CHANGE: i32 = 0xC00D6D61u32 as i32;
const HRESULT_NOT_ACCEPTING: i32 = 0xC00D36B5u32 as i32;
const HRESULT_NO_EVENTS: i32 = 0xC00D3E80u32 as i32;
const HRESULT_BUFFER_TOOSMALL: i32 = 0xC00D36B6u32 as i32;
const MFT_OUTPUT_DATA_BUFFER_FORMAT_CHANGE: u32 = 0x00000001;

#[derive(Clone, Copy)]
enum EventPumpMode {
    NonBlocking,
    UntilNeedInput,
}

#[derive(Clone, Copy, Debug)]
pub struct EncoderConfig {
    pub width: u32,
    pub height: u32,
    pub bitrate_bps: u32,
    pub fps: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputPixelFormat {
    Nv12,
    I420,
    Yv12,
}

impl InputPixelFormat {
    pub fn name(self) -> &'static str {
        match self {
            InputPixelFormat::Nv12 => "NV12",
            InputPixelFormat::I420 => "I420",
            InputPixelFormat::Yv12 => "YV12",
        }
    }
}

fn pack_ratio(high: u32, low: u32) -> u64 {
    (u64::from(high) << 32) | u64::from(low)
}

pub struct H264Encoder {
    transform: IMFTransform,
    events: Option<IMFMediaEventGenerator>,
    event_driven: bool,
    codec_api: Option<ICodecAPI>,
    hardware: bool,
    name: String,
    config: EncoderConfig,
    input_format: InputPixelFormat,
    sequence_header: Option<Vec<u8>>,
    spare_sample: Option<IMFSample>,
    output_capacity: u32,
    drained: bool,
    keyframe_force_supported: bool,
    gradual_intra_refresh: bool,
}

fn configure_input_type(media_type: &IMFMediaType, config: &EncoderConfig) -> Result<()> {
    unsafe {
        media_type
            .SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
            .map_err(mf_err("input interlace"))?;
        media_type
            .SetUINT64(&MF_MT_FRAME_SIZE, pack_ratio(config.width, config.height))
            .map_err(mf_err("input frame size"))?;
        media_type
            .SetUINT64(&MF_MT_FRAME_RATE, pack_ratio(config.fps, 1))
            .map_err(mf_err("input frame rate"))?;
    }
    Ok(())
}

fn select_input_type(transform: &IMFTransform, config: &EncoderConfig) -> Result<(IMFMediaType, InputPixelFormat)> {
    let mut fallback: Option<(IMFMediaType, InputPixelFormat)> = None;
    let mut available: Vec<String> = Vec::new();

    for index in 0u32.. {
        let Ok(media_type) = (unsafe { transform.GetInputAvailableType(0, index) }) else {
            break;
        };
        let subtype = unsafe { media_type.GetGUID(&MF_MT_SUBTYPE) }.map_err(mf_err("input subtype"))?;
        let format = format_from_guid(&subtype);
        if let Some(format) = format {
            configure_input_type(&media_type, config)?;
            if format == InputPixelFormat::Nv12 {
                return Ok((media_type, format));
            }
            if fallback.is_none() {
                fallback = Some((media_type, format));
            }
        } else {
            available.push(format!("{subtype:?}"));
        }
    }

    if let Some(fallback) = fallback {
        return Ok(fallback);
    }

    for candidate in [InputPixelFormat::Nv12, InputPixelFormat::I420, InputPixelFormat::Yv12] {
        let media_type: IMFMediaType = unsafe { MFCreateMediaType() }.map_err(mf_err("MFCreateMediaType"))?;
        unsafe {
            media_type
                .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
                .map_err(mf_err("candidate major type"))?;
            media_type
                .SetGUID(&MF_MT_SUBTYPE, &guid_for_format(candidate))
                .map_err(mf_err("candidate subtype"))?;
        }
        configure_input_type(&media_type, config)?;
        if unsafe { transform.SetInputType(0, &media_type, 0) }.is_ok() {
            return Ok((media_type, candidate));
        }
    }

    bail!(
        "no supported input pixel format (NV12/I420/YV12) among MFT types: [{}]",
        available.join(", ")
    )
}

fn format_from_guid(guid: &windows::core::GUID) -> Option<InputPixelFormat> {
    if *guid == MFVideoFormat_NV12 {
        Some(InputPixelFormat::Nv12)
    } else if *guid == MFVideoFormat_I420 || *guid == MFVideoFormat_IYUV {
        Some(InputPixelFormat::I420)
    } else if *guid == MFVideoFormat_YV12 {
        Some(InputPixelFormat::Yv12)
    } else {
        None
    }
}

fn guid_for_format(format: InputPixelFormat) -> windows::core::GUID {
    match format {
        InputPixelFormat::Nv12 => MFVideoFormat_NV12,
        InputPixelFormat::I420 => MFVideoFormat_I420,
        InputPixelFormat::Yv12 => MFVideoFormat_YV12,
    }
}

impl H264Encoder {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn keyframe_force_supported(&self) -> bool {
        self.keyframe_force_supported
    }

    fn from_activate(info_name: &str, activate: &IMFActivate, config: &EncoderConfig) -> Result<Self> {
        crate::windows_encoders::ensure_mf_started()?;

        let transform: IMFTransform = unsafe { activate.ActivateObject() }.map_err(mf_err("ActivateObject"))?;
        let attributes = unsafe { transform.GetAttributes() }.map_err(mf_err("GetAttributes"))?;
        let hardware = unsafe { attributes.GetUINT32(&MF_TRANSFORM_ASYNC) }
            .map(|v| v != 0)
            .unwrap_or(false);
        if hardware {
            // Required before any other MFT method; hardware (async) MFTs then
            // must be driven by their event stream (METransformNeedInput /
            // METransformHaveOutput).
            unsafe { attributes.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1) }
                .map_err(mf_err("SetUINT32 async unlock"))?;
        }
        let events: Option<IMFMediaEventGenerator> = transform.cast().ok();
        if hardware && events.is_none() {
            bail!("hardware MFT does not expose IMFMediaEventGenerator");
        }
        let event_driven = hardware;
        let codec_api: Option<ICodecAPI> = transform.cast().ok();

        let output: IMFMediaType =
            unsafe { transform.GetOutputAvailableType(0, 0) }.map_err(mf_err("GetOutputAvailableType"))?;
        unsafe {
            output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(mf_err("SetGUID h264"))?;
            output
                .SetUINT32(&MF_MT_AVG_BITRATE, config.bitrate_bps)
                .map_err(mf_err("SetUINT32 bitrate"))?;
            output
                .SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)
                .map_err(mf_err("SetUINT32 out interlace"))?;
            output
                .SetUINT64(&MF_MT_FRAME_SIZE, pack_ratio(config.width, config.height))
                .map_err(mf_err("SetUINT64 out frame size"))?;
            output
                .SetUINT64(&MF_MT_FRAME_RATE, pack_ratio(config.fps, 1))
                .map_err(mf_err("SetUINT64 out frame rate"))?;
            transform.SetOutputType(0, &output, 0).map_err(mf_err("SetOutputType(H264)"))?;
        }

        let (input, chosen_format) =
            select_input_type(&transform, config).context("input type negotiation")?;
        unsafe {
            transform.SetInputType(0, &input, 0).map_err(mf_err("SetInputType"))?;
        }

        // Low-latency streaming profile, applied after the types are set but
        // before streaming starts (some MFTs ignore CodecAPI changes later).
        // The default (VBR with lookahead and B-frames) delayed every
        // ProcessOutput by ~30 ms; live screen streaming needs
        // CBR/LowDelayVBR, no B-frames and one reference.
        let mut gradual_intra_refresh = false;
        if let Some(api) = &codec_api {
            configure_low_latency(api);
            gradual_intra_refresh = configure_intra_refresh(api);
        }

        unsafe {
            transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                .map_err(mf_err("BEGIN_STREAMING"))?;
            transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
                .map_err(mf_err("START_OF_STREAM"))?;
        }

        let sequence_header = read_sequence_header(&transform);

        Ok(Self {
            transform,
            events,
            event_driven,
            codec_api,
            hardware,
            name: info_name.to_string(),
            config: *config,
            input_format: chosen_format,
            sequence_header,
            spare_sample: None,
            output_capacity: 8 * 1024 * 1024,
            drained: false,
            keyframe_force_supported: false,
            gradual_intra_refresh,
        })
    }

    /// Takes the out-of-band SPS/PPS (Annex-B) blob once, if the encoder
    /// provides it via MF_MT_MPEG_SEQUENCE_HEADER. Prepending it to the stream
    /// is required for standalone player compatibility.
    pub fn take_sequence_header(&mut self) -> Option<Vec<u8>> {
        self.sequence_header.take()
    }

    pub fn input_format(&self) -> InputPixelFormat {
        self.input_format
    }

    /// Encoder frame dimensions (after any sender-side scaling).
    pub fn dimensions(&self) -> (u32, u32) {
        (self.config.width, self.config.height)
    }

    pub fn is_hardware(&self) -> bool {
        self.hardware
    }

    fn make_sample(
        &self,
        i420: &[u8],
        time_100ns: i64,
        duration_100ns: i64,
        discontinuity: bool,
    ) -> Result<IMFSample> {
        let len = i420.len();
        let expected = (self.config.width * self.config.height) as usize * 3 / 2;
        if len != expected {
            bail!("I420 buffer size {len} does not match expected {expected}");
        }

        let buffer = unsafe { MFCreateMemoryBuffer(len as u32) }.map_err(mf_err("MFCreateMemoryBuffer"))?;
        unsafe {
            let mut ptr: *mut u8 = std::ptr::null_mut();
            let mut max_len = 0u32;
            let mut cur_len = 0u32;
            buffer.Lock(&mut ptr, Some(&mut max_len), Some(&mut cur_len)).map_err(mf_err("buffer Lock"))?;
            std::ptr::copy_nonoverlapping(i420.as_ptr(), ptr, len);
            buffer.Unlock().map_err(mf_err("buffer Unlock"))?;
            buffer.SetCurrentLength(len as u32).map_err(mf_err("SetCurrentLength"))?;
        }

        let sample = unsafe { MFCreateSample() }.map_err(mf_err("MFCreateSample"))?;
        unsafe {
            sample.AddBuffer(&buffer).map_err(mf_err("AddBuffer"))?;
            sample.SetSampleTime(time_100ns).map_err(mf_err("SetSampleTime"))?;
            sample.SetSampleDuration(duration_100ns).map_err(mf_err("SetSampleDuration"))?;
            if discontinuity {
                sample
                    .SetUINT32(&MFSampleExtension_Discontinuity, 1)
                    .map_err(mf_err("SetUINT32 discontinuity"))?;
            }
        }
        Ok(sample)
    }

    pub fn encode(
        &mut self,
        i420: &[u8],
        time_100ns: i64,
        duration_100ns: i64,
        discontinuity: bool,
        force_keyframe: bool,
    ) -> Result<Vec<Vec<u8>>> {
        if force_keyframe {
            let _ = self.force_keyframe();
        }

        let sample = self.make_sample(i420, time_100ns, duration_100ns, discontinuity)?;
        let mut outputs: Vec<Vec<u8>> = Vec::new();

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        if self.event_driven {
            self.pump_events(&mut outputs, EventPumpMode::NonBlocking, deadline)?;
        }

        loop {
            if std::time::Instant::now() >= deadline {
                bail!("timed out pushing a frame into the MFT (persistent NOT_ACCEPTING)");
            }
            let result = unsafe { self.transform.ProcessInput(0, &sample, 0) };
            match result {
                Ok(()) => break,
                Err(e) if e.code().0 == HRESULT_NOT_ACCEPTING => {
                    if self.event_driven {
                        self.pump_events(&mut outputs, EventPumpMode::UntilNeedInput, deadline)?;
                    } else {
                        self.drain_sync(&mut outputs)?;
                    }
                }
                Err(e) => return Err(anyhow::anyhow!("ProcessInput failed: {e:?}")),
            }
        }

        if self.event_driven {
            // Pipelined: do not wait for THIS frame's output — it arrives while
            // the next frame is being submitted (waiting here serialised the
            // pipeline and made every frame cost the full encoder latency).
            self.pump_events(
                &mut outputs,
                EventPumpMode::NonBlocking,
                std::time::Instant::now() + std::time::Duration::from_millis(1),
            )?;
        } else {
            self.drain_sync(&mut outputs)?;
        }
        Ok(outputs)
    }

    fn drain_sync(&mut self, outputs: &mut Vec<Vec<u8>>) -> Result<()> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if std::time::Instant::now() >= deadline {
                bail!("sync drain did not finish within 2s");
            }
            match self.process_output_once()? {
                Some(chunk) => outputs.push(chunk),
                None => break,
            }
        }
        Ok(())
    }

    fn pump_events(
        &mut self,
        outputs: &mut Vec<Vec<u8>>,
        mode: EventPumpMode,
        deadline: std::time::Instant,
    ) -> Result<()> {
        let events = self
            .events
            .clone()
            .ok_or_else(|| anyhow::anyhow!("event-driven MFT without event generator"))?;
        loop {
            if std::time::Instant::now() >= deadline {
                return Ok(());
            }
            match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(event) => {
                    let event_type = unsafe { event.GetType() }.map_err(mf_err("event GetType"))? as i32;
                    if event_type == METransformHaveOutput.0 {
                        if let Some(chunk) = self.process_output_once()? {
                            outputs.push(chunk);
                        }
                    } else if event_type == METransformNeedInput.0 {
                        return Ok(());
                    } else if event_type == METransformDrainComplete.0 {
                        self.drained = true;
                    } else {
                        let status = unsafe { event.GetStatus() }.map_err(mf_err("event GetStatus"))?;
                        if status.is_err() {
                            bail!("MFT event {event_type:#x} failed: {status:?}");
                        }
                    }
                }
                Err(e) if e.code().0 == HRESULT_NO_EVENTS => match mode {
                    EventPumpMode::NonBlocking => return Ok(()),
                    EventPumpMode::UntilNeedInput => {
                        std::thread::sleep(std::time::Duration::from_millis(1));
                    }
                },
                Err(e) => return Err(anyhow::anyhow!("GetEvent failed: {e:?}")),
            }
        }
    }

    fn process_output_once(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            let sample = match self.spare_sample.take() {
                Some(sample) => sample,
                None => make_output_sample(self.output_capacity)?,
            };
            let mut data_buffer = MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: std::mem::ManuallyDrop::new(Some(sample)),
                dwStatus: 0,
                pEvents: std::mem::ManuallyDrop::new(None),
            };
            let mut status = 0u32;
            let result = unsafe {
                self.transform
                    .ProcessOutput(0, std::slice::from_mut(&mut data_buffer), &mut status)
            };
            let returned_sample = unsafe { std::mem::ManuallyDrop::take(&mut data_buffer.pSample) };
            let _events = unsafe { std::mem::ManuallyDrop::take(&mut data_buffer.pEvents) };

            match result {
                Ok(()) => {
                    if status & MFT_OUTPUT_DATA_BUFFER_FORMAT_CHANGE != 0 {
                        self.renegotiate_output()?;
                    }
                    let Some(sample) = returned_sample else {
                        return Ok(None);
                    };
                    let chunk = unsafe {
                        let buffer = sample.ConvertToContiguousBuffer().map_err(mf_err("ConvertToContiguousBuffer"))?;
                        let mut ptr: *mut u8 = std::ptr::null_mut();
                        let mut max_len = 0u32;
                        let mut cur_len = 0u32;
                        buffer
                            .Lock(&mut ptr, Some(&mut max_len), Some(&mut cur_len))
                            .map_err(mf_err("bitstream Lock"))?;
                        let chunk = if cur_len > 0 {
                            Some(std::slice::from_raw_parts(ptr, cur_len as usize).to_vec())
                        } else {
                            None
                        };
                        buffer.Unlock().map_err(mf_err("bitstream Unlock"))?;
                        chunk
                    };
                    self.spare_sample = Some(sample);
                    return Ok(chunk);
                }
                Err(e) if e.code().0 == HRESULT_NEED_MORE_INPUT => {
                    self.spare_sample = returned_sample;
                    return Ok(None);
                }
                Err(e) if e.code().0 == HRESULT_STREAM_CHANGE => {
                    self.spare_sample = returned_sample;
                    self.renegotiate_output()?;
                    return Ok(None);
                }
                Err(e) if e.code().0 == HRESULT_BUFFER_TOOSMALL => {
                    self.spare_sample = None;
                    if self.output_capacity >= 64 * 1024 * 1024 {
                        bail!("output buffer kept overflowing even at 64 MiB");
                    }
                    self.output_capacity = (self.output_capacity * 2).min(64 * 1024 * 1024);
                    continue;
                }
                Err(e) => {
                    self.spare_sample = returned_sample;
                    return Err(anyhow::anyhow!("ProcessOutput failed: {e:?}"));
                }
            }
        }
    }

    /// Live bitrate change for adaptive quality. Uses
    /// CODECAPI_AVEncCommonMeanBitRate, which is safe mid-stream. There is no
    /// output-type fallback: renegotiating while streaming requires a drain
    /// and a fresh SPS/PPS + IDR, so a failure keeps the old bitrate and the
    /// caller retries with backoff.
    pub fn set_bitrate(&mut self, bitrate_bps: u32) -> Result<()> {
        if bitrate_bps == 0 || bitrate_bps == self.config.bitrate_bps {
            return Ok(());
        }
        let Some(api) = &self.codec_api else {
            anyhow::bail!("encoder exposes no CodecAPI for live bitrate changes");
        };
        let value = VARIANT::from(bitrate_bps);
        if unsafe { api.SetValue(&CODECAPI_AVEncCommonMeanBitRate, &value) }.is_ok() {
            self.config.bitrate_bps = bitrate_bps;
            Ok(())
        } else {
            anyhow::bail!("encoder rejected CODECAPI_AVEncCommonMeanBitRate")
        }
    }

    fn renegotiate_output(&mut self) -> Result<()> {
        let output: IMFMediaType = unsafe { self.transform.GetOutputAvailableType(0, 0) }
            .map_err(mf_err("renegotiate: GetOutputAvailableType"))?;
        unsafe {
            output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_H264).map_err(mf_err("renegotiate subtype"))?;
            output
                .SetUINT32(&MF_MT_AVG_BITRATE, self.config.bitrate_bps)
                .map_err(mf_err("renegotiate bitrate"))?;
            output
                .SetUINT64(&MF_MT_FRAME_SIZE, pack_ratio(self.config.width, self.config.height))
                .map_err(mf_err("renegotiate frame size"))?;
            output
                .SetUINT64(&MF_MT_FRAME_RATE, pack_ratio(self.config.fps, 1))
                .map_err(mf_err("renegotiate frame rate"))?;
            self.transform.SetOutputType(0, &output, 0).map_err(mf_err("renegotiate SetOutputType"))?;
        }
        self.sequence_header = read_sequence_header(&self.transform);
        Ok(())
    }

    /// True when the encoder accepted gradual intra refresh (MB refresh instead
    /// of full IDRs). The sender relaxes its periodic keyframe cadence then.
    pub fn gradual_intra_refresh(&self) -> bool {
        self.gradual_intra_refresh
    }

    /// Requests an IDR at the next encoded frame. Returns false when the
    /// encoder does not expose CODECAPI_AVEncVideoForceKeyFrame. VT_UI4 is
    /// the documented type, but some MFTs (AMD) reject it and accept VT_BOOL.
    pub fn force_keyframe(&mut self) -> bool {
        let Some(api) = &self.codec_api else {
            return false;
        };
        for value in [VARIANT::from(1u32), VARIANT::from(true)] {
            if unsafe { api.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &value) }.is_ok() {
                self.keyframe_force_supported = true;
                return true;
            }
        }
        false
    }
    pub fn shutdown(&mut self) -> Result<Vec<Vec<u8>>> {
        let mut outputs: Vec<Vec<u8>> = Vec::new();
        unsafe {
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
        if self.event_driven {
            // Pipelined encoding leaves 1-2 access units in flight; keep
            // pumping until they emerge (or the deadline passes) instead of
            // returning on the first empty pump.
            let mut idle_since = std::time::Instant::now();
            while std::time::Instant::now() < deadline {
                let before = outputs.len();
                let _ = self.pump_events(&mut outputs, EventPumpMode::NonBlocking, deadline);
                if outputs.len() > before {
                    idle_since = std::time::Instant::now();
                } else if idle_since.elapsed() > std::time::Duration::from_millis(100) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        } else {
            let _ = self.drain_sync(&mut outputs);
        }
        Ok(outputs)
    }
}

fn mf_err(what: &'static str) -> impl Fn(windows::core::Error) -> anyhow::Error {
    move |e| anyhow::anyhow!("{what} failed: {e:?}")
}

fn read_sequence_header(transform: &IMFTransform) -> Option<Vec<u8>> {
    let output_type = unsafe { transform.GetOutputCurrentType(0) }.ok()?;
    let size = unsafe { output_type.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) }.ok()?;
    if size == 0 {
        return None;
    }
    let mut buffer = vec![0u8; size as usize];
    let mut written = 0u32;
    unsafe {
        output_type
            .GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut buffer, Some(&mut written))
            .ok()?;
    }
    buffer.truncate(written as usize);
    Some(buffer)
}

fn make_output_sample(capacity: u32) -> Result<IMFSample> {
    let buffer = unsafe { MFCreateMemoryBuffer(capacity) }.map_err(mf_err("output MFCreateMemoryBuffer"))?;
    let sample = unsafe { MFCreateSample() }.map_err(mf_err("output MFCreateSample"))?;
    unsafe {
        sample.AddBuffer(&buffer).map_err(mf_err("output AddBuffer"))?;
    }
    Ok(sample)
}

/// Creates the best available encoder: candidates in enumeration order
/// (hardware first, software fallback). The first candidate that activates and
/// negotiates both media types wins.
///
/// Note: a functional trial encode was tried in Step 4 but had to be removed —
/// trial frames linger in the (asynchronous) MFT pipeline and leak into the
/// real stream as reference-less P-frames, and neither a second instance nor
/// COMMAND_FLUSH reset the AMD MFT's event flow. Activation success is now the
/// arbitration criterion; stream validation happens on the first real keyframe.
pub fn create_best_encoder(config: &EncoderConfig) -> Result<H264Encoder> {
    let candidates = h264_encoder_candidates()?;
    if candidates.is_empty() {
        bail!("no H.264 encoder MFTs found");
    }

    let mut failures: Vec<String> = Vec::new();
    for (info, activate) in candidates {
        match H264Encoder::from_activate(&info.friendly_name, &activate, config) {
            Ok(encoder) => return Ok(encoder),
            Err(e) => failures.push(format!("{}: {e:#}", info.friendly_name)),
        }
    }

    bail!("all encoder candidates failed: {}", failures.join(" | "))
}

/// Best-effort low-latency streaming configuration via ICodecAPI. Unsupported
/// properties are skipped (the encoder decides).
fn configure_low_latency(api: &ICodecAPI) {
    fn set_u32(api: &ICodecAPI, guid: &windows::core::GUID, value: u32) -> bool {
        unsafe { api.SetValue(guid, &VARIANT::from(value)).is_ok() }
    }
    fn set_bool(api: &ICodecAPI, guid: &windows::core::GUID, value: bool) -> bool {
        unsafe { api.SetValue(guid, &VARIANT::from(value)).is_ok() }
    }

    // LowDelayVBR (4) keeps the rate control window short; CBR (0) is the
    // fallback when the encoder rejects it.
    if !set_u32(api, &CODECAPI_AVEncCommonRateControlMode, 4) {
        let _ = set_u32(api, &CODECAPI_AVEncCommonRateControlMode, 0);
    }
    let _ = set_bool(api, &CODECAPI_AVEncCommonLowLatency, true);
    let _ = set_u32(api, &CODECAPI_AVEncMPVDefaultBPictureCount, 0);
    let _ = set_u32(api, &CODECAPI_AVEncVideoMaxNumRefFrame, 1);
}

/// Enables gradual intra refresh (MB refresh) when the encoder supports it:
/// the picture stays fresh without full-IDR bitrate spikes, so the sender can
/// relax its periodic keyframe cadence. Forced IDRs still work on demand.
///
/// S_OK is not proof: some MFTs accept the property and ignore it, so the
/// value is read back before the capability is reported.
fn configure_intra_refresh(api: &ICodecAPI) -> bool {
    if unsafe { api.SetValue(&CODECAPI_AVEncVideoGradualIntraRefresh, &VARIANT::from(true)) }.is_err() {
        return false;
    }
    match unsafe { api.GetValue(&CODECAPI_AVEncVideoGradualIntraRefresh) } {
        Ok(value) => bool::try_from(&value).unwrap_or(false),
        Err(_) => false,
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    /// Annex-B scan for an IDR slice (NAL type 5).
    fn has_idr(au: &[u8]) -> bool {
        let mut i = 0;
        while i + 3 < au.len() {
            if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
                if au[i + 3] & 0x1f == 5 {
                    return true;
                }
                i += 3;
            } else {
                i += 1;
            }
        }
        false
    }

    fn mid_gray_frame(format: InputPixelFormat, width: u32, height: u32) -> Vec<u8> {
        let luma = (width * height) as usize;
        let chroma = luma / 4;
        let mut frame = vec![128u8; luma];
        frame.resize(luma + chroma * 2, 128);
        let _ = format;
        frame
    }

    /// Regression for the receiver loss-recovery path: a forced keyframe must
    /// actually put an IDR on the wire (the MF property can report success and
    /// be ignored, which is why the sender verifies the bitstream).
    #[test]
    fn forced_keyframe_produces_idr() {
        let config = EncoderConfig {
            width: 320,
            height: 240,
            bitrate_bps: 1_500_000,
            fps: 30,
        };
        let mut encoder = match create_best_encoder(&config) {
            Ok(encoder) => encoder,
            Err(e) => {
                eprintln!("skipping (no encoder on this host): {e:#}");
                return;
            }
        };
        eprintln!(
            "encoder={} gradual_intra_refresh={}",
            encoder.name(),
            encoder.gradual_intra_refresh()
        );
        let frame = mid_gray_frame(encoder.input_format(), config.width, config.height);
        // Baseline: exactly the startup IDR, nothing else. Counted instead of
        // pinning arrival indexes because async/hardware MFTs buffer outputs.
        let mut baseline_idrs = 0;
        for index in 0..10i64 {
            let outputs = encoder
                .encode(&frame, index * 333_333, 333_333, false, false)
                .expect("encode");
            baseline_idrs += outputs.iter().filter(|au| has_idr(au)).count();
        }
        assert_eq!(baseline_idrs, 1, "expected exactly the startup IDR before the force request");
        let mut forced_seen = false;
        let mut idr_after_force = false;
        // The forced IDR must follow the request promptly; a late IDR would
        // just be a periodic GOP one (default GOP is far larger than this).
        let mut aus_after_force = 0;
        for index in 10..40i64 {
            let force = !forced_seen;
            let outputs = encoder
                .encode(&frame, index * 333_333, 333_333, false, force)
                .expect("encode");
            let had_output = !outputs.is_empty();
            if force && had_output {
                forced_seen = true;
            }
            for au in &outputs {
                if !forced_seen {
                    continue;
                }
                aus_after_force += 1;
                if has_idr(au) {
                    idr_after_force = true;
                    break;
                }
            }
            if idr_after_force {
                break;
            }
        }
        let _ = encoder.shutdown();
        assert!(forced_seen, "no output after the forced request");
        assert!(idr_after_force, "forced keyframe did not produce an IDR");
        assert!(
            aus_after_force <= 5,
            "forced IDR arrived after {aus_after_force} access units (likely a periodic GOP, not the request)"
        );
    }
}
