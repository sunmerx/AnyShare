//! Media Foundation encoder enumeration (candidate list for the
//! discrete-GPU > integrated-GPU > CPU selection chain; the final trial-encode
//! arbitration lands with the encoder implementation).

use anyhow::{Context, Result};
use windows::core::PWSTR;
use windows::Win32::Media::MediaFoundation::{
    MFTEnumEx, IMFActivate, MFMediaType_Video, MFStartup, MFShutdown, MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_ASYNCMFT,
    MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER, MFT_ENUM_FLAG_SYNCMFT, MFT_FRIENDLY_NAME_Attribute,
    MFT_REGISTER_TYPE_INFO, MF_VERSION, MFVideoFormat_H264,
};
use windows::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_MULTITHREADED};

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

fn encode_candidates(kind: EncoderKind) -> Result<Vec<EncoderMftInfo>> {
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
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_ENCODER,
            flags,
            None,
            Some(&output_type),
            &mut activates,
            &mut count,
        )
        .context("MFTEnumEx failed")?;

        if activates.is_null() {
            return Ok(result);
        }

        for i in 0..count as usize {
            let activate = (*activates.add(i)).clone();
            if let Some(activate) = activate {
                let mut name_ptr = PWSTR::null();
                let mut name_len = 0u32;
                if activate
                    .GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut name_ptr, &mut name_len)
                    .is_ok()
                    && !name_ptr.is_null()
                {
                    let name = name_ptr.to_string().unwrap_or_else(|_| "<invalid utf16>".into());
                    CoTaskMemFree(Some(name_ptr.as_ptr() as *const core::ffi::c_void));
                    result.push(EncoderMftInfo {
                        kind,
                        friendly_name: name,
                    });
                } else {
                    result.push(EncoderMftInfo {
                        kind,
                        friendly_name: "<unnamed>".into(),
                    });
                }
            }
        }

        for i in 0..count as usize {
            drop((*activates.add(i)).take());
        }
        CoTaskMemFree(Some(activates as *const core::ffi::c_void));
    }
    Ok(result)
}

/// Lists H.264 video encoder MFTs: hardware candidates first, then software.
pub fn list_h264_encoders() -> Result<Vec<EncoderMftInfo>> {
    unsafe {
        let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
        if hr.is_err() && hr != windows::Win32::Foundation::RPC_E_CHANGED_MODE {
            hr.ok().context("CoInitializeEx failed")?;
        }
        MFStartup(MF_VERSION, 0).context("MFStartup failed")?;
    }

    let result = (|| {
        let mut all = encode_candidates(EncoderKind::Hardware)?;
        all.extend(encode_candidates(EncoderKind::Software)?);
        Ok::<_, anyhow::Error>(all)
    })();

    unsafe {
        let _ = MFShutdown();
    }

    result
}
