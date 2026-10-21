//! Screen sender: capture -> VFR gate -> H.264 encode -> packetize + FEC -> UDP.
//! Library form of the former ss-send main loop; Windows-only.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::events::{EndReason, StreamEvent, StreamState, StreamStats};

pub struct SenderConfig {
    /// `ip:port` of the receiver's data plane.
    pub target: String,
    /// Output index (as string) or device-name substring; `None` auto-picks.
    pub output: Option<String>,
    pub bitrate_bps: u32,
    pub fps: u32,
    pub timeout_ms: u32,
    /// `None` runs until [SenderHandle::stop].
    pub duration: Option<Duration>,
}

impl Default for SenderConfig {
    fn default() -> Self {
        Self {
            target: String::new(),
            output: None,
            bitrate_bps: 8_000_000,
            fps: 60,
            timeout_ms: 500,
            duration: None,
        }
    }
}

pub struct SenderHandle {
    stop: Arc<AtomicBool>,
    force_keyframe: Arc<AtomicBool>,
    bitrate_bps: Arc<std::sync::atomic::AtomicU32>,
    stats: Arc<Mutex<StreamStats>>,
    join: Option<JoinHandle<()>>,
}

impl SenderHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    pub fn stats(&self) -> StreamStats {
        *self.stats.lock().unwrap()
    }

    /// Asks the encoder for an IDR on the next frame (receiver loss
    /// recovery). Safe to call from any thread; requests coalesce.
    pub fn request_keyframe(&self) {
        self.force_keyframe.store(true, Ordering::Release);
    }

    /// Requests a new encoder bitrate (adaptive quality). 0 is ignored;
    /// requests coalesce, the latest value wins.
    pub fn set_bitrate(&self, bitrate_bps: u32) {
        if bitrate_bps >= 500_000 && bitrate_bps <= 50_000_000 {
            self.bitrate_bps.store(bitrate_bps, Ordering::Release);
        }
    }

    /// Waits for the sender thread to finish (stops it first).
    pub fn join(mut self) {
        self.stop();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for SenderHandle {
    /// Signals the thread to stop but does NOT join it: Drop can run on a
    /// finalizer thread (FRB GC) where blocking is not acceptable. The thread
    /// exits on its own; use [SenderHandle::join] to wait for it.
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.join.take();
    }
}

pub fn start_sender(config: SenderConfig, event_tx: Sender<StreamEvent>) -> Result<SenderHandle> {
    #[cfg(not(windows))]
    {
        let _ = (config, event_tx);
        anyhow::bail!("screen sending is Windows-only (capture/encode layers)");
    }

    #[cfg(windows)]
    {
        imp::start(config, event_tx)
    }
}

#[cfg(windows)]
mod imp {
    use super::*;

    use std::net::UdpSocket;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::transport::{packetize, Nack, Packet, PacketHistory, FLAG_DISCONTINUITY, FLAG_HEADER, FLAG_KEYFRAME};
    use crate::types::{Acquire, FrameMeta, FramePixels};
    use crate::vfr::{EncodeDecision, VfrConfig, VfrGate};
    use crate::{create_best_encoder, enumerate_outputs, windows_capture, Duplicator};

    fn send_event(event_tx: &Sender<StreamEvent>, event: StreamEvent) {
        let _ = event_tx.send(event);
    }

    /// UDP send with a single WouldBlock retry. Persistent blocking means the
    /// kernel buffer is full: dropping a datagram is fine (FEC/NACK recover);
    /// it must never stall the capture loop or kill the stream.
    fn send_udp(socket: &UdpSocket, bytes: &[u8]) -> Result<()> {
        for _ in 0..2 {
            match socket.send(bytes) {
                Ok(_) => return Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => std::thread::sleep(std::time::Duration::from_millis(1)),
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    /// One encoded frame handed to the network thread.
    struct NetJob {
        frame_id: u32,
        /// All encoded packets in send order: (is parity, bytes, payload len).
        packets: Vec<(bool, Vec<u8>, usize)>,
    }

    #[derive(Default)]
    struct NetCounters {
        packets: std::sync::atomic::AtomicU64,
        bytes: std::sync::atomic::AtomicU64,
    }

    fn encode_packets(packets: &[Packet]) -> Vec<(bool, Vec<u8>, usize)> {
        packets
            .iter()
            .map(|packet| (packet.is_fec(), packet.encode(), packet.payload.len()))
            .collect()
    }

    /// Applies a NACK to the history under the per-frame retransmission
    /// budget. Returns the number of packets resent.
    fn apply_nack<F>(
        history: &PacketHistory,
        nack: &Nack,
        budget: &mut std::collections::HashMap<u32, u8>,
        mut send: F,
    ) -> u32
    where
        F: FnMut(&[u8]) -> bool,
    {
        let remaining = budget.entry(nack.frame_id).or_insert(2);
        if *remaining == 0 {
            return 0;
        }
        let Some(frames) = history.get(nack.frame_id) else {
            return 0;
        };
        let mut resent = 0;
        for &index in &nack.missing {
            let Some(bytes) = frames.get(index) else { continue };
            if send(bytes) {
                resent += 1;
            }
            *remaining = remaining.saturating_sub(1);
            if *remaining == 0 {
                break;
            }
        }
        resent
    }

    /// Dedicated network thread: sending, NACK-retransmission and the packet
    /// history run off the capture/encode thread so a busy socket or a NACK
    /// burst can never delay frame acquisition. Fatal send errors are reported
    /// through `error` and stop the session instead of being swallowed.
    fn spawn_net_thread(
        socket: UdpSocket,
        session: u32,
        stop: Arc<AtomicBool>,
        counters: Arc<NetCounters>,
        error: Arc<std::sync::Mutex<Option<String>>>,
    ) -> (std::sync::mpsc::SyncSender<NetJob>, JoinHandle<()>) {
        let (tx, rx) = std::sync::mpsc::sync_channel::<NetJob>(8);
        let join = std::thread::spawn(move || {
            let mut history = PacketHistory::new(48);
            let mut nack_budget: std::collections::HashMap<u32, u8> = std::collections::HashMap::new();
            let mut nack_buf = [0u8; 1200];
            'outer: loop {
                match rx.recv_timeout(std::time::Duration::from_millis(1)) {
                    Ok(job) => {
                        let mut history_packets = Vec::new();
                        for (is_fec, bytes, payload_len) in job.packets {
                            if stop.load(Ordering::Acquire) {
                                break 'outer;
                            }
                            match send_udp(&socket, &bytes) {
                                Ok(()) => {
                                    counters.packets.fetch_add(1, Ordering::Relaxed);
                                    counters.bytes.fetch_add(payload_len as u64, Ordering::Relaxed);
                                }
                                Err(e) => {
                                    *error.lock().unwrap() = Some(format!("UDP send failed: {e:#}"));
                                    stop.store(true, Ordering::Release);
                                    break 'outer;
                                }
                            }
                            if !is_fec {
                                history_packets.push(bytes);
                            }
                        }
                        history.push(job.frame_id, history_packets);
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
                if stop.load(Ordering::Acquire) {
                    break;
                }
                // Bounded NACK drain: a spoofed/duplicated flood must never
                // starve the send queue. Two retransmissions per frame max.
                let mut processed = 0;
                while processed < 32 {
                    if stop.load(Ordering::Acquire) {
                        break 'outer;
                    }
                    let Ok(len) = socket.recv(&mut nack_buf) else { break };
                    processed += 1;
                    let Some(packet) = Packet::decode(&nack_buf[..len]) else { continue };
                    let Some(nack) = Nack::from_packet(&packet) else { continue };
                    if nack.session != session {
                        continue;
                    }
                    let resent = apply_nack(&history, &nack, &mut nack_budget, |bytes| {
                        if send_udp(&socket, bytes).is_ok() {
                            counters.packets.fetch_add(1, Ordering::Relaxed);
                            counters.bytes.fetch_add(
                                bytes.len().saturating_sub(crate::transport::HEADER_LEN) as u64,
                                Ordering::Relaxed,
                            );
                            true
                        } else {
                            false
                        }
                    });
                    let _ = resent;
                }
                if nack_budget.len() > 64 {
                    nack_budget.retain(|frame_id, budget| *budget > 0 && history.get(*frame_id).is_some());
                }
            }
        });
        (tx, join)
    }

    /// True when the Annex-B access unit contains an IDR slice (NAL type 5).
    fn au_has_idr(payload: &[u8]) -> bool {
        let mut i = 0;
        while i + 3 < payload.len() {
            if payload[i] == 0 && payload[i + 1] == 0 && payload[i + 2] == 1 {
                if payload[i + 3] & 0x1f == 5 {
                    return true;
                }
                i += 3;
            } else {
                i += 1;
            }
        }
        false
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn sample_history() -> PacketHistory {
            let mut history = PacketHistory::new(4);
            history.push(7, vec![vec![1], vec![2], vec![3]]);
            history
        }

        #[test]
        fn nack_budget_is_shared_per_frame() {
            let history = sample_history();
            let mut budget = std::collections::HashMap::new();
            let first = Nack {
                session: 1,
                frame_id: 7,
                count: 3,
                missing: vec![0, 1],
            };
            let mut sent = 0;
            let resent = apply_nack(&history, &first, &mut budget, |_| {
                sent += 1;
                true
            });
            assert_eq!((resent, sent), (2, 2));
            let second = Nack {
                session: 1,
                frame_id: 7,
                count: 3,
                missing: vec![2],
            };
            let resent = apply_nack(&history, &second, &mut budget, |_| {
                sent += 1;
                true
            });
            assert_eq!(resent, 0, "the two-retransmission budget is exhausted");
            assert_eq!(sent, 2);
        }

        #[test]
        fn nack_ignores_evicted_frames_and_out_of_range_indices() {
            let history = sample_history();
            let mut budget = std::collections::HashMap::new();
            let missing = Nack {
                session: 1,
                frame_id: 7,
                count: 3,
                missing: vec![2, 9],
            };
            assert_eq!(apply_nack(&history, &missing, &mut budget, |_| true), 1);
            let evicted = Nack {
                session: 1,
                frame_id: 99,
                count: 3,
                missing: vec![0],
            };
            assert_eq!(apply_nack(&history, &evicted, &mut budget, |_| true), 0);
        }
    }
    pub fn start(config: SenderConfig, event_tx: Sender<StreamEvent>) -> Result<SenderHandle> {
        let stop = Arc::new(AtomicBool::new(false));
        let force_keyframe = Arc::new(AtomicBool::new(false));
        let bitrate_bps = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let stats = Arc::new(Mutex::new(StreamStats::default()));

        let thread_stop = Arc::clone(&stop);
        let thread_force_keyframe = Arc::clone(&force_keyframe);
        let thread_bitrate = Arc::clone(&bitrate_bps);
        let thread_stats = Arc::clone(&stats);
        // Everything COM/DXGI/MF related (output enumeration, duplicator,
        // encoder) is created and used on this one worker thread: the objects
        // are not Send, and MF wants a stable apartment per object.
        let join = std::thread::spawn(move || {
            send_event(&event_tx, StreamEvent::Status(StreamState::Starting));
            if let Err(e) = run(config, thread_stop, thread_force_keyframe, thread_bitrate, Arc::clone(&thread_stats), &event_tx) {
                send_event(&event_tx, StreamEvent::Error(format!("{e:#}")));
                send_event(&event_tx, StreamEvent::Ended(EndReason::Error));
                return;
            }
            send_event(&event_tx, StreamEvent::Ended(EndReason::Stopped));
        });

        Ok(SenderHandle {
            stop,
            force_keyframe,
            bitrate_bps,
            stats,
            join: Some(join),
        })
    }

    fn run(
        config: SenderConfig,
        stop: Arc<AtomicBool>,
        force_keyframe: Arc<AtomicBool>,
        bitrate_bps: Arc<std::sync::atomic::AtomicU32>,
        stats: Arc<Mutex<StreamStats>>,
        event_tx: &Sender<StreamEvent>,
    ) -> Result<()> {
        let outputs = enumerate_outputs()?;
        let attached: Vec<_> = outputs.iter().filter(|o| o.attached).cloned().collect();
        let target_output = match &config.output {
            Some(spec) => {
                if let Ok(idx) = spec.parse::<usize>() {
                    outputs
                        .iter()
                        .find(|o| o.index == idx)
                        .cloned()
                        .ok_or_else(|| anyhow::anyhow!("output index {idx} not found"))?
                } else {
                    outputs
                        .iter()
                        .find(|o| o.device_name.to_ascii_lowercase().contains(&spec.to_ascii_lowercase()))
                        .cloned()
                        .ok_or_else(|| anyhow::anyhow!("no output name matches {spec:?}"))?
                }
            }
            None => attached
                .iter()
                // Primary output sits at the desktop origin (0,0). Sharing the
                // real main screen is what "share screen" means; the old
                // smallest-output auto-pick selected the (often empty) virtual
                // display and sent blank frames.
                .find(|o| o.desktop_rect.left == 0 && o.desktop_rect.top == 0)
                .or_else(|| attached.iter().max_by_key(|o| o.desktop_rect.area()))
                .or_else(|| attached.first())
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("no attached output to auto-pick"))?,
        };

        if windows_capture::rotation_name(target_output.rotation) != "identity" {
            anyhow::bail!("capturing rotated outputs is not supported yet");
        }

        let socket = {
            let raw = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, None)?;
            raw.set_send_buffer_size(8 * 1024 * 1024)?;
            raw.connect(&config.target.parse::<std::net::SocketAddr>()?.into())?;
            let std_socket: UdpSocket = raw.into();
            // Non-blocking receive: the same socket doubles as the NACK
            // feedback channel from the receiver.
            std_socket.set_nonblocking(true)?;
            std_socket
        };

        let session = (SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() & 0xFFFF_FFFF) as u32 | 1;

        let dup = Duplicator::new(target_output.index)?;

        // The duplication texture size can differ from the desktop rect when
        // the driver GPU-scales (panel mode 2880x1800 vs 1920x1200 desktop):
        // the encoder must match the actual capture size.
        let (capture_width, capture_height) = dup.capture_size()?;
        // E2.0 decision D5: encode at most 1080p (the capture may be larger,
        // e.g. a 2880x1800 panel). The fixed base bitrate then buys a much
        // sharper picture and every downstream stage gets cheaper.
        let (encode_width, encode_height) = crate::convert::scale_to_fit(capture_width, capture_height, 1920, 1080);
        let encoder_config = crate::EncoderConfig {
            width: encode_width,
            height: encode_height,
            bitrate_bps: config.bitrate_bps,
            fps: config.fps,
        };
        let encoder = create_best_encoder(&encoder_config)?;
        eprintln!(
            "sender: encoder {} (input {}), capture {}x{}, encode {}x{}, bitrate {} Mbps",
            encoder.name(),
            encoder.input_format().name(),
            capture_width,
            capture_height,
            encode_width,
            encode_height,
            config.bitrate_bps / 1_000_000
        );

        let gpu = if encoder.input_format() == crate::windows_encoder::InputPixelFormat::Nv12
            && std::env::var("ANYSHARE_CPU_CONVERT").as_deref() != Ok("1")
        {
            match crate::gpu_convert::GpuConverter::new(
                dup.device(),
                dup.context(),
                (capture_width, capture_height),
                (encode_width, encode_height),
            ) {
                Ok(converter) => Some(converter),
                Err(e) => {
                    eprintln!("sender: GPU convert unavailable, using CPU path: {e:#}");
                    None
                }
            }
        } else {
            None
        };
        eprintln!("sender: gpu convert = {}", gpu.is_some());

        run_loop(config, socket, session, encoder, dup, gpu, stop, force_keyframe, bitrate_bps, stats, event_tx)
    }

    #[allow(clippy::too_many_arguments)]
    fn run_loop(
        config: SenderConfig,
        socket: UdpSocket,
        session: u32,
        mut encoder: crate::windows_encoder::H264Encoder,
        mut dup: Duplicator,
        mut gpu: Option<crate::gpu_convert::GpuConverter>,
        stop: Arc<AtomicBool>,
        force_keyframe: Arc<AtomicBool>,
        bitrate_bps: Arc<std::sync::atomic::AtomicU32>,
        stats: Arc<Mutex<StreamStats>>,
        event_tx: &Sender<StreamEvent>,
    ) -> Result<()> {
        let mut gate = VfrGate::new(VfrConfig::with_intra_refresh(encoder.gradual_intra_refresh()));
        if encoder.gradual_intra_refresh() {
            eprintln!("sender: gradual intra refresh enabled (periodic keyframes relaxed to 10s)");
        }
        let mut force_rejected_warned = false;
        let mut bitrate_pending: Option<(u32, Instant)> = None;
        let mut bitrate_warned = false;
        let mut i420: Vec<u8> = Vec::new();
        let mut scaled_bgra: Vec<u8> = Vec::new();
        let mut pending_meta: std::collections::VecDeque<(bool, bool, u64)> = std::collections::VecDeque::new();
        let (encode_width, encode_height) = encoder.dimensions();

        let mut frame_id: u32 = 1;
        let mut frames_sent: u64 = 0;
        let mut keyframes_sent: u64 = 0;
        // Network worker: sending/retransmission off the capture thread.
        let net_counters = Arc::new(NetCounters::default());
        let net_error: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));
        let (net_tx, net_join) = spawn_net_thread(
            socket.try_clone()?,
            session,
            Arc::clone(&stop),
            Arc::clone(&net_counters),
            Arc::clone(&net_error),
        );
        let mut last_net_packets: u64 = 0;
        let mut last_net_bytes: u64 = 0;
        let mut dropped_jobs: u64 = 0;
        let mut last_enc_time_100ns: i64 = -1;
        let mut last_rebuild_count = dup.rebuild_count();
        // Drop the first frame of each duplication session (it can be blank).
        let mut skip_first_frame = true;
        let mut last_send_time_100ns: i64 = -1;

        let mut sequence_header: Option<Vec<u8>> = encoder.take_sequence_header();
        if let Some(header) = &sequence_header {
            let packets = packetize(session, 0, FLAG_HEADER, 0, header);
            // Header packets join the same queue as frames so the single
            // network writer keeps everything in FIFO order.
            let _ = net_tx.try_send(NetJob {
                frame_id: 0,
                packets: encode_packets(&packets),
            });
        }

        let started = Instant::now();
        let mut last_stats = Instant::now();
        let mut window_frames: u64 = 0;
        let mut window_encode_ms: f64 = 0.0;
        let mut window_acquires: u64 = 0;
        let mut window_none: u64 = 0;
        let mut window_dirty: u64 = 0;
        let mut window_moved: u64 = 0;
        let mut window_pointer_moved: u64 = 0;
        let mut window_pointer_shape: u64 = 0;
        let mut window_zero_present: u64 = 0;
        let mut window_acquire_ms: f64 = 0.0;
        let mut window_convert_ms: f64 = 0.0;
        let mut window_loop_ms: f64 = 0.0;
        let mut window_encode_frames: u64 = 0;
        let mut window_keyframes: u64 = 0;

        while !stop.load(Ordering::Acquire) {
            if let Some(message) = net_error.lock().unwrap().clone() {
                anyhow::bail!("network worker: {message}");
            }
            if let Some(duration) = config.duration {
                if started.elapsed() >= duration {
                    break;
                }
            }

            // Adaptive bitrate: apply the latest receiver feedback request.
            // 0 means "no pending request". On failure keep retrying with a
            // 5 s backoff (some encoders reject changes transiently) and log
            // only once so the capture loop stays quiet.
            let requested_bitrate = bitrate_bps.swap(0, Ordering::AcqRel);
            if requested_bitrate != 0 {
                bitrate_pending = Some((requested_bitrate, Instant::now()));
            }
            if let Some((target, retry_at)) = bitrate_pending {
                if Instant::now() >= retry_at {
                    match encoder.set_bitrate(target) {
                        Ok(()) => {
                            bitrate_pending = None;
                            bitrate_warned = false;
                        }
                        Err(e) => {
                            if !bitrate_warned {
                                bitrate_warned = true;
                                eprintln!("sender: bitrate change to {target} failed (retrying): {e:#}");
                            }
                            bitrate_pending = Some((target, Instant::now() + Duration::from_secs(5)));
                        }
                    }
                }
            }

            let iter_started = Instant::now();
            let t100 = started.elapsed().as_nanos() as i64 / 100;
            let acquire_started = Instant::now();
            let mut nv12_ready: Option<Vec<u8>> = None;
            let mut rebuild_converter = false;
            let acquired: Option<(FrameMeta, Option<FramePixels>)> = if gpu.is_some() {
                if dup.acquire_texture(config.timeout_ms)? {
                    let meta = dup.frame_meta().cloned().unwrap_or_default();
                    let converted = (|| -> anyhow::Result<Vec<u8>> {
                        let converter = gpu.as_mut().context("gpu converter missing")?;
                        let texture = dup.frame_texture()?;
                        Ok(converter.convert(&texture, t100, 16_666)?.to_vec())
                    })();
                    dup.release_frame().ok();
                    match converted {
                        Ok(mut bytes) => {
                            dup.composite_pointer_nv12(&mut bytes, encode_width, encode_height);
                            nv12_ready = Some(bytes);
                            Some((meta, None))
                        }
                        Err(e) => {
                            eprintln!("sender: GPU convert failed ({e:#}); falling back to the CPU path");
                            gpu = None;
                            None // drop this frame; the next one uses the CPU path
                        }
                    }
                } else {
                    None
                }
            } else {
                dup.acquire_full(config.timeout_ms)?.map(|(meta, pixels)| (meta, Some(pixels)))
            };
            window_acquire_ms += acquire_started.elapsed().as_secs_f64() * 1000.0;
            if let Some(meta) = acquired.as_ref().map(|(meta, _)| meta) {
                if dup.rebuild_count() != last_rebuild_count {
                    let _ = meta;
                    rebuild_converter = true;
                }
            }
            if rebuild_converter {
                if let Ok((cap_w, cap_h)) = dup.capture_size() {
                    match crate::gpu_convert::GpuConverter::new(
                        dup.device(),
                        dup.context(),
                        (cap_w, cap_h),
                        (encode_width, encode_height),
                    ) {
                        Ok(converter) => gpu = Some(converter),
                        Err(e) => {
                            eprintln!("sender: GPU converter rebuild failed ({e:#}); CPU path");
                            gpu = None;
                        }
                    }
                }
            }
            match acquired {
                None => {
                    window_none += 1;
                    let _ = gate.decide(&FrameMeta::default(), Instant::now());
                }
                Some((meta, pixels_opt)) => {
                    let rebuild_changed = dup.rebuild_count() != last_rebuild_count;
                    last_rebuild_count = dup.rebuild_count();
                    window_acquires += 1;
                    if !meta.dirty.is_empty() {
                        window_dirty += 1;
                    }
                    if !meta.moved.is_empty() {
                        window_moved += 1;
                    }
                    if meta.pointer_moved {
                        window_pointer_moved += 1;
                    }
                    if meta.pointer_shape_updated {
                        window_pointer_shape += 1;
                    }
                    if meta.last_present_time == 0 {
                        window_zero_present += 1;
                    }

                    // The first frame of a fresh duplication session can be
                    // blank (observed on AMD with scaled displays): encoding it
                    // would publish a black keyframe and VFR would then only
                    // stream tiny diffs, leaving the receiver stuck on black.
                    if rebuild_changed {
                        skip_first_frame = true;
                    }
                    if skip_first_frame {
                        skip_first_frame = false;
                        // Only drop a BLANK frame; a static desktop may never
                        // produce another frame, and dropping a valid first
                        // frame would leave the receiver black forever.
                        let blank = if let Some(nv12) = &nv12_ready {
                            crate::convert::nv12_looks_blank(nv12, encode_width, encode_height)
                        } else if let Some(pixels) = &pixels_opt {
                            crate::convert::bgra_looks_blank(&pixels.bgra)
                        } else {
                            false
                        };
                        if blank {
                            if let Some(pixels) = pixels_opt {
                                dup.recycle_pixels(pixels);
                            }
                            continue;
                        }
                    }

                    let mut decision = gate.decide(&meta, Instant::now());
                    if force_keyframe.load(Ordering::Acquire) {
                        // Loss-recovery request from the receiver: force an IDR
                        // and bypass the VFR skip. The flag is only cleared once
                        // the encoder accepted the request; a rejected request
                        // stays pending. Note: while the screen is completely
                        // static no frame is encoded at all, so the request is
                        // serviced by the next content change (the stale frame
                        // stays on screen until then).
                        if encoder.force_keyframe() {
                            force_keyframe.store(false, Ordering::Release);
                            decision = EncodeDecision::Encode { keyframe: true };
                        } else if !force_rejected_warned {
                            force_rejected_warned = true;
                            eprintln!("sender: encoder rejected the keyframe request (unsupported CodecAPI)");
                        }
                    }
                    if let EncodeDecision::Encode { keyframe } = decision {
                        let convert_started = Instant::now();
                        if nv12_ready.is_none() {
                        {
                            let pixels = pixels_opt.as_ref().expect("cpu pixels missing");
                            use crate::windows_encoder::InputPixelFormat;
                            // E2.0 decision D5: encode at most 1080p. The panel
                            // may be larger (2880x1800); downscale at the
                            // sender so conversion, encoding, transport and the
                            // receiver all pay the smaller pixel bill.
                            let (sw, sh) = if (pixels.width, pixels.height) == (encode_width, encode_height) {
                                (pixels.width, pixels.height)
                            } else {
                                crate::convert::bgra_box_scale(
                                    &pixels.bgra,
                                    pixels.width,
                                    pixels.height,
                                    encode_width,
                                    encode_height,
                                    &mut scaled_bgra,
                                );
                                (encode_width, encode_height)
                            };
                            let bgra = if (pixels.width, pixels.height) == (sw, sh) { &pixels.bgra } else { &scaled_bgra };
                            match encoder.input_format() {
                                InputPixelFormat::Nv12 => crate::convert::bgra_to_nv12(bgra, sw, sh, &mut i420),
                                InputPixelFormat::I420 => crate::convert::bgra_to_i420(bgra, sw, sh, &mut i420),
                                InputPixelFormat::Yv12 => {
                                    crate::convert::bgra_to_i420(bgra, sw, sh, &mut i420);
                                    crate::convert::i420_to_yv12_in_place(&mut i420, sw, sh);
                                }
                            }
                        }

                        }
                        window_convert_ms += convert_started.elapsed().as_secs_f64() * 1000.0;

                        let delta = if last_enc_time_100ns >= 0 {
                            t100 - last_enc_time_100ns
                        } else {
                            10_000_000 / i64::from(config.fps.max(1))
                        };
                        let duration = delta.clamp(10_000, 5_000_000);
                        let discontinuity = rebuild_changed || delta > 2_000_000;

                        if let Some(header) = encoder.take_sequence_header() {
                            let packets = packetize(session, frame_id, FLAG_HEADER, t100 as u64, &header);
                            let queued = net_tx
                                .try_send(NetJob {
                                    frame_id,
                                    packets: encode_packets(&packets),
                                })
                                .is_ok();
                            if !queued {
                                dropped_jobs += 1;
                            }
                            frame_id = frame_id.wrapping_add(1);
                            sequence_header = Some(header);
                        }

                        let encode_started = Instant::now();
                        let converted: &[u8] = if let Some(nv12) = &nv12_ready {
                            nv12
                        } else {
                            &i420
                        };
                        let outputs = encoder.encode(converted, t100, duration, discontinuity, keyframe)?;
                        window_encode_ms += encode_started.elapsed().as_secs_f64() * 1000.0;
                        window_encode_frames += 1;
                        // With pipelined encoding, outputs belong to EARLIER
                        // submissions: queue the per-request flags and pair them
                        // in order instead of using the current gate decision.
                        pending_meta.push_back((keyframe, discontinuity, t100 as u64));
                        let had_output = !outputs.is_empty();
                        for chunk in &outputs {
                            let (out_keyframe_requested, out_discontinuity, out_ts) = pending_meta
                                .pop_front()
                                .unwrap_or((keyframe, discontinuity, t100 as u64));
                            // The MF force-keyframe property can be accepted
                            // (S_OK) and silently ignored, so the bitstream is
                            // the ground truth. Encoder-spontaneous IDRs are
                            // flagged too (a receiver needs the SPS/PPS prefix
                            // and the keyframe flag to resync).
                            let out_keyframe = au_has_idr(chunk);
                            if out_keyframe_requested && !out_keyframe {
                                // Ask again on the next frame; the MFT ignored
                                // the property this time.
                                force_keyframe.store(true, Ordering::Release);
                            }
                            let mut flags = 0u8;
                            if out_keyframe {
                                flags |= FLAG_KEYFRAME;
                            }
                            if out_discontinuity {
                                flags |= FLAG_DISCONTINUITY;
                            }
                            let with_header;
                            let payload: &[u8] = if out_keyframe {
                                match &sequence_header {
                                    Some(header) => {
                                        let mut combined = Vec::with_capacity(header.len() + chunk.len());
                                        combined.extend_from_slice(header);
                                        combined.extend_from_slice(chunk);
                                        with_header = combined;
                                        &with_header
                                    }
                                    None => chunk,
                                }
                            } else {
                                chunk
                            };
                            let packets = packetize(session, frame_id, flags, out_ts, payload);
                            let job = NetJob {
                                frame_id,
                                packets: encode_packets(&packets),
                            };
                            let queued = net_tx.try_send(job).is_ok();
                            if queued {
                                frames_sent += 1;
                                window_frames += 1;
                                if out_keyframe {
                                    keyframes_sent += 1;
                                    window_keyframes += 1;
                                }
                            } else {
                                dropped_jobs += 1;
                                // A dropped keyframe would leave the peer
                                // without a sync point: ask for a new one.
                                if out_keyframe {
                                    force_keyframe.store(true, Ordering::Release);
                                }
                            }
                            frame_id = frame_id.wrapping_add(1);
                            if frames_sent == 1 && queued {
                                send_event(event_tx, StreamEvent::Status(StreamState::Streaming));
                            }
                        }
                        let _ = had_output;
                        if last_enc_time_100ns < 0 && started.elapsed() > Duration::from_secs(5) {
                            anyhow::bail!("encoder produced no output within 5s (activating-but-mute MFT?)");
                        }
                        last_enc_time_100ns = t100;
                        last_send_time_100ns = t100;
                    }
                    if let Some(pixels) = pixels_opt {
                        dup.recycle_pixels(pixels);
                    }
                    window_loop_ms += iter_started.elapsed().as_secs_f64() * 1000.0;
                }
            }

            if last_stats.elapsed() >= Duration::from_secs(1) {
                // Sending happens on the network thread: derive the window
                // counters from its totals (includes retransmissions).
                let total_net_packets = net_counters.packets.load(Ordering::Relaxed);
                let total_net_bytes = net_counters.bytes.load(Ordering::Relaxed);
                let window_packets = total_net_packets - last_net_packets;
                let window_bytes = total_net_bytes - last_net_bytes;
                last_net_packets = total_net_packets;
                last_net_bytes = total_net_bytes;
                let mbps = window_bytes as f64 * 8.0 / 1_000_000.0;
                eprintln!(
                    "sender: t={:.0}s fps={} kf={} mbps={:.2} enc_ms={:.1}",
                    started.elapsed().as_secs_f64(),
                    window_frames,
                    window_keyframes,
                    mbps,
                    if window_encode_frames > 0 { window_encode_ms / window_encode_frames as f64 } else { 0.0 }
                );
                eprintln!(
                    "sender meta: acq={} none={} dirty={} moved={} pm={} ps={} zp={} rebuilds={} dropped={}",
                    window_acquires,
                    window_none,
                    window_dirty,
                    window_moved,
                    window_pointer_moved,
                    window_pointer_shape,
                    window_zero_present,
                    last_rebuild_count,
                    dropped_jobs
                );
                eprintln!(
                    "sender timing: acq_ms={:.1} conv_ms={:.1} loop_ms={:.1} (per frame with data)",
                    if window_acquires > 0 { window_acquire_ms / window_acquires as f64 } else { 0.0 },
                    if window_encode_frames > 0 { window_convert_ms / window_encode_frames as f64 } else { 0.0 },
                    if window_acquires > 0 { window_loop_ms / window_acquires as f64 } else { 0.0 }
                );
                {
                    let mut shared = stats.lock().unwrap();
                    shared.frames = window_frames;
                    shared.keyframes = window_keyframes;
                    shared.fps = window_frames as f64;
                    shared.mbps = mbps;
                    shared.packets = window_packets;
                }
                send_event(
                    event_tx,
                    StreamEvent::Stats(StreamStats {
                        frames: window_frames,
                        keyframes: window_keyframes,
                        fps: window_frames as f64,
                        mbps,
                        packets: window_packets,
                        ..Default::default()
                    }),
                );
                window_frames = 0;
                window_keyframes = 0;
                window_encode_ms = 0.0;
                window_encode_frames = 0;
                window_acquires = 0;
                window_none = 0;
                window_dirty = 0;
                window_moved = 0;
                window_pointer_moved = 0;
                window_pointer_shape = 0;
                window_zero_present = 0;
                window_acquire_ms = 0.0;
                window_convert_ms = 0.0;
                window_loop_ms = 0.0;
                last_stats = Instant::now();
            }
        }

        drop(net_tx);
        let _ = net_join.join();
        send_event(event_tx, StreamEvent::Status(StreamState::Stopping));
        for chunk in encoder.shutdown()? {
            let packets = packetize(session, frame_id, 0, last_send_time_100ns.max(0) as u64, &chunk);
            for packet in &packets {
                if send_udp(&socket, &packet.encode()).is_ok() {
                    net_counters.packets.fetch_add(1, Ordering::Relaxed);
                    net_counters.bytes.fetch_add(packet.payload.len() as u64, Ordering::Relaxed);
                }
            }
            frame_id = frame_id.wrapping_add(1);
        }

        let total_packets = net_counters.packets.load(Ordering::Relaxed);
        let total_bytes = net_counters.bytes.load(Ordering::Relaxed);
        eprintln!(
            "sender: frames={frames_sent} keyframes={keyframes_sent} packets={total_packets} sent={:.2} MiB in {}s",
            total_bytes as f64 / 1048576.0,
            started.elapsed().as_secs()
        );
        let _ = Acquire::Idle;
        Ok(())
    }
}
