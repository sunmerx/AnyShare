//! GPU color conversion + scaling for the Windows sender using the Direct3D 11
//! Video Processor (same building block OBS/remote-desktop stacks use): the
//! duplication texture is blitted to an NV12 render target on the GPU, and only
//! the small NV12 result is read back for transport.

use anyhow::{Context, Result};
use windows::core::Interface;
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, ID3D11VideoContext, ID3D11VideoDevice, ID3D11VideoProcessor,
    ID3D11VideoProcessorEnumerator, ID3D11VideoProcessorInputView, ID3D11VideoProcessorOutputView,
    D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE, D3D11_CPU_ACCESS_READ,
    D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE, D3D11_VIDEO_PROCESSOR_COLOR_SPACE,
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC,
    D3D11_VIDEO_PROCESSOR_STREAM, D3D11_VIDEO_USAGE_PLAYBACK_NORMAL, D3D11_VPIV_DIMENSION_TEXTURE2D,
    D3D11_VPOV_DIMENSION_TEXTURE2D,
};
use windows::Win32::Foundation::BOOL;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_RATIONAL, DXGI_SAMPLE_DESC};

pub struct GpuConverter {
    video_device: ID3D11VideoDevice,
    video_context: ID3D11VideoContext,
    enumerator: ID3D11VideoProcessorEnumerator,
    processor: ID3D11VideoProcessor,
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    output_size: (u32, u32),
    output_texture: ID3D11Texture2D,
    output_view: ID3D11VideoProcessorOutputView,
    staging: Option<ID3D11Texture2D>,
    staging_size: (u32, u32),
    buffer: Vec<u8>,
}

impl GpuConverter {
    pub fn new(
        device: &ID3D11Device,
        context: &ID3D11DeviceContext,
        input_size: (u32, u32),
        output_size: (u32, u32),
    ) -> Result<Self> {
        unsafe {
            let video_device: ID3D11VideoDevice = device.cast().context("ID3D11VideoDevice")?;
            let video_context: ID3D11VideoContext = context.cast().context("ID3D11VideoContext")?;

            let content_desc = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
                InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
                InputFrameRate: DXGI_RATIONAL {
                    Numerator: 60,
                    Denominator: 1,
                },
                InputWidth: input_size.0,
                InputHeight: input_size.1,
                OutputFrameRate: DXGI_RATIONAL {
                    Numerator: 60,
                    Denominator: 1,
                },
                OutputWidth: output_size.0,
                OutputHeight: output_size.1,
                Usage: D3D11_VIDEO_USAGE_PLAYBACK_NORMAL,
            };
            let enumerator = video_device
                .CreateVideoProcessorEnumerator(&content_desc)
                .context("CreateVideoProcessorEnumerator")?;
            let processor = video_device.CreateVideoProcessor(&enumerator, 0).context("CreateVideoProcessor")?;
            video_context.VideoProcessorSetStreamFrameFormat(&processor, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
            // Desktop RGB is full range; encode as BT.601 limited range (what a
            // decoder without VUI assumes).
            let color_space = D3D11_VIDEO_PROCESSOR_COLOR_SPACE {
                _bitfield: 0x10, // Nominal_Range = limited, RGB full, BT.601
            };
            let _ = video_context.VideoProcessorSetStreamColorSpace(&processor, 0, &color_space);
            let _ = video_context.VideoProcessorSetOutputColorSpace(&processor, &color_space);

            let output_desc = D3D11_TEXTURE2D_DESC {
                Width: output_size.0,
                Height: output_size.1,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_NV12,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                CPUAccessFlags: 0,
                MiscFlags: 0,
            };
            let mut output_texture: Option<ID3D11Texture2D> = None;
            device
                .CreateTexture2D(&output_desc, None, Some(&mut output_texture))
                .context("CreateTexture2D(NV12 output)")?;
            let output_texture = output_texture.context("NV12 output texture missing")?;
            let output_view_desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC {
                ViewDimension: D3D11_VPOV_DIMENSION_TEXTURE2D,
                Anonymous: windows::Win32::Graphics::Direct3D11::D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC_0 {
                    Texture2D: D3D11_TEX2D_VPOV { MipSlice: 0 },
                },
            };
            let mut output_view_opt: Option<ID3D11VideoProcessorOutputView> = None;
            video_device
                .CreateVideoProcessorOutputView(
                    &output_texture,
                    &enumerator,
                    &output_view_desc,
                    Some(&mut output_view_opt as *mut _),
                )
                .context("CreateVideoProcessorOutputView")?;
            let output_view = output_view_opt.context("output view missing")?;

            Ok(Self {
                video_device,
                video_context,
                enumerator,
                processor,
                device: device.clone(),
                context: context.clone(),
                output_size,
                output_texture,
                output_view,
                staging: None,
                staging_size: (0, 0),
                buffer: Vec::new(),
            })
        }
    }

    /// Blits one BGRA duplication texture into the NV12 output and returns the
    /// tight NV12 frame (width*height*3/2).
    pub fn convert(&mut self, texture: &ID3D11Texture2D, _time_100ns: i64, _duration_100ns: i64) -> Result<&[u8]> {
        unsafe {
            let input_desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC {
                FourCC: 0,
                ViewDimension: D3D11_VPIV_DIMENSION_TEXTURE2D,
                Anonymous: windows::Win32::Graphics::Direct3D11::D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC_0 {
                    Texture2D: D3D11_TEX2D_VPIV {
                        MipSlice: 0,
                        ArraySlice: 0,
                    },
                },
            };
            let mut input_view_opt: Option<ID3D11VideoProcessorInputView> = None;
            self.video_device
                .CreateVideoProcessorInputView(texture, &self.enumerator, &input_desc, Some(&mut input_view_opt as *mut _))
                .context("CreateVideoProcessorInputView")?;
            let input_view = input_view_opt.context("input view missing")?;

            let mut stream = D3D11_VIDEO_PROCESSOR_STREAM {
                Enable: BOOL(1),
                OutputIndex: 0,
                InputFrameOrField: 0,
                PastFrames: 0,
                FutureFrames: 0,
                ppPastSurfaces: std::ptr::null_mut(),
                pInputSurface: std::mem::ManuallyDrop::new(Some(input_view)),
                ppFutureSurfaces: std::ptr::null_mut(),
                ppPastSurfacesRight: std::ptr::null_mut(),
                pInputSurfaceRight: std::mem::ManuallyDrop::new(None),
                ppFutureSurfacesRight: std::ptr::null_mut(),
            };
            let blt = self
                .video_context
                .VideoProcessorBlt(&self.processor, &self.output_view, 0, std::slice::from_mut(&mut stream));
            let _ = std::mem::ManuallyDrop::take(&mut stream.pInputSurface);
            blt.context("VideoProcessorBlt")?;

            let (w, h) = self.output_size;
            if self.staging.is_none() || self.staging_size != (w, h) {
                let desc = D3D11_TEXTURE2D_DESC {
                    Width: w,
                    Height: h,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_NV12,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_STAGING,
                    BindFlags: 0,
                    CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                    MiscFlags: 0,
                };
                let mut staging: Option<ID3D11Texture2D> = None;
                self.device
                    .CreateTexture2D(&desc, None, Some(&mut staging))
                    .context("CreateTexture2D(NV12 staging)")?;
                self.staging = staging;
                self.staging_size = (w, h);
            }
            let staging = self.staging.as_ref().context("staging missing")?;
            self.context.CopyResource(staging, &self.output_texture);
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            self.context
                .Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                .context("Map(NV12 staging)")?;
            let y_size = (w * h) as usize;
            let total = y_size + y_size / 2;
            self.buffer.clear();
            self.buffer.resize(total, 0);
            let src = mapped.pData as *const u8;
            let pitch = mapped.RowPitch as usize;
            for row in 0..h as usize {
                std::ptr::copy_nonoverlapping(src.add(row * pitch), self.buffer.as_mut_ptr().add(row * w as usize), w as usize);
            }
            for row in 0..(h / 2) as usize {
                std::ptr::copy_nonoverlapping(
                    src.add((h as usize + row) * pitch),
                    self.buffer.as_mut_ptr().add(y_size + row * w as usize),
                    w as usize,
                );
            }
            self.context.Unmap(staging, 0);
            Ok(&self.buffer)
        }
    }
}
