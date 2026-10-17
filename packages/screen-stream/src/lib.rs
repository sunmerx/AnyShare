//! AnyShare E-2 screen streaming engine (capture layer prototype).
//!
//! Platform-gated: the DXGI Desktop Duplication implementation is Windows-only;
//! every other platform currently exposes an empty/unsupported stub so the
//! workspace still builds everywhere.

pub mod convert;
pub mod transport;
pub mod types;
pub mod vfr;

#[cfg(windows)]
pub mod windows_capture;

#[cfg(windows)]
pub mod windows_encoder;

#[cfg(windows)]
pub mod windows_encoders;

#[cfg(windows)]
pub use windows_capture::{enumerate_outputs, Duplicator};
#[cfg(windows)]
pub use windows_encoder::{create_best_encoder, EncoderConfig, H264Encoder};
#[cfg(windows)]
pub use windows_encoders::{list_h264_encoders, EncoderKind, EncoderMftInfo};

#[cfg(not(windows))]
mod stub {
    use anyhow::{bail, Result};

    use crate::types::OutputInfo;

    pub fn enumerate_outputs() -> Result<Vec<OutputInfo>> {
        Ok(Vec::new())
    }

    pub struct Duplicator;

    impl Duplicator {
        pub fn new(_output_index: usize) -> Result<Self> {
            bail!("screen capture is not implemented on this platform yet")
        }
    }
}

#[cfg(not(windows))]
pub use stub::{enumerate_outputs, Duplicator};
