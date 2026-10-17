//! Media Foundation encoder enumeration (candidate list for the
//! discrete-GPU > integrated-GPU > CPU selection chain).

use anyhow::{Context, Result};
use std::sync::OnceLock;
use windows::core::PWSTR;
use windows::Win32::Media::MediaFoundation::{
    MFTEnumEx, IMFActivate, MFMediaType_Video, MFStartup, MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_ASYNCMFT,
    MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER, MFT_ENUM_FLAG_SYNCMFT, MFT_FRIENDLY_NAME_Attribute,
    MFT_REGISTER_TYPE_INFO, MF_VERSION, MFVideoFormat_H264,
};
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};

static MF_INIT: OnceLock<Result<(), String>> = OnceLock::new();

/// Starts COM (multithreaded) and Media Foundation exactly once per process;
/// the outcome (including failures) is cached and re-raised on every call.
pub fn ensure_mf_started() -> Result<()> {
    let result = MF_INIT.get_or_init(|| {
        unsafe {
            let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
            if hr.is_err() && hr != windows::Win32::Foundation::RPC_E_CHANGED_MODE {
                return Err(format!("CoInitializeEx failed: {hr:?}"));
            }
            if let Err(e) = MFStartup(MF_VERSION, 0) {
                return Err(format!("MFStartup failed: {e:?}"));
            }
        }
        Ok(())
    });
    match result {
        Ok(()) => Ok(()),
        Err(message) => Err(anyhow::anyhow!("{message}")),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EncoderKind {
    Hardware,
    Software,
}

#[derive(Clone, Debug)]
pub struct EncoderMftInfo {
    pub kind: EncoderKind,
    pub friendly_name: String,
}

fn encode_candidates(kind: EncoderKind) -> Result<Vec<(EncoderMftInfo, IMFActivate)>> {
    let mut result = Vec::new();
    unsafe {
        let output_type = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_H264,
        };
        let flags = match kind {
            EncoderKind::Hardware => MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            EncoderKind::Software => MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        };

        let mut activates: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count = 0u32;
        match MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            flags,
            None,
            Some(&output_type),
            &mut activates,
            &mut count,
        ) {
            Ok(()) => {}
            Err(e) if activates.is_null() => {
                return Err(e).context("MFTEnumEx failed");
            }
            Err(_) => {}
        }

        if activates.is_null() {
            return Ok(result);
        }

        for i in 0..count as usize {
            let activate = (*activates.add(i)).take();
            if let Some(activate) = activate {
                let mut name_ptr = PWSTR::null();
                let mut name_len = 0u32;
                let name = if activate
                    .GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut name_ptr, &mut name_len)
                    .is_ok()
                    && !name_ptr.is_null()
                {
                    let name = name_ptr.to_string().unwrap_or_else(|_| "<invalid utf16>".into());
                    CoTaskMemFree(Some(name_ptr.as_ptr() as *const core::ffi::c_void));
                    name
                } else {
                    "<unnamed>".into()
                };
                result.push((EncoderMftInfo { kind, friendly_name: name }, activate));
            }
        }

        CoTaskMemFree(Some(activates as *const core::ffi::c_void));
    }
    Ok(result)
}

/// Encoder candidates in priority order: hardware first, software as fallback.
/// The dGPU-vs-iGPU decision is made by trial encode at creation time.
pub fn h264_encoder_candidates() -> Result<Vec<(EncoderMftInfo, IMFActivate)>> {
    ensure_mf_started()?;
    let mut all = encode_candidates(EncoderKind::Hardware)?;
    all.extend(encode_candidates(EncoderKind::Software)?);
    Ok(all)
}

/// Lists H.264 video encoder MFTs (hardware first, then software).
pub fn list_h264_encoders() -> Result<Vec<EncoderMftInfo>> {
    Ok(h264_encoder_candidates()?.into_iter().map(|(info, _)| info).collect())
}
