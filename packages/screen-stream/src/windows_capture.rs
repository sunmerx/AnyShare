//! Windows screen capture via DXGI Desktop Duplication (metadata level).

use std::mem::size_of;

use anyhow::{bail, Context, Result};
use windows::core::Interface;
use windows::Win32::Foundation::{HINSTANCE, RECT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_ROTATE180, DXGI_MODE_ROTATION_ROTATE270, DXGI_MODE_ROTATION_ROTATE90,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutputDuplication,
    IDXGIResource, DXGI_ERROR_ACCESS_DENIED, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_INVALID_CALL, DXGI_ERROR_NOT_FOUND,
    DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_MOVE_RECT, DXGI_OUTPUT_DESC,
};

use crate::types::{Acquire, FrameMeta, MoveRect, OutputInfo, Rect};

const MAX_METADATA_BYTES: usize = 16 * 1024 * 1024;

fn wide_to_string(wide: &[u16]) -> String {
    let len = wide.iter().position(|c| *c == 0).unwrap_or(wide.len());
    String::from_utf16_lossy(&wide[..len])
}

fn rect_from_dxgi(r: &RECT) -> Rect {
    Rect {
        left: r.left,
        top: r.top,
        right: r.right,
        bottom: r.bottom,
    }
}

fn create_d3d11_device(adapter: &IDXGIAdapter1) -> Result<ID3D11Device> {
    let adapter_base: IDXGIAdapter = adapter.cast().context("cast adapter -> IDXGIAdapter failed")?;
    let mut device: Option<ID3D11Device> = None;
    let mut context: Option<ID3D11DeviceContext> = None;
    unsafe {
        D3D11CreateDevice(
            &adapter_base,
            D3D_DRIVER_TYPE_UNKNOWN,
            HINSTANCE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
        .context("D3D11CreateDevice failed")?;
    }
    device.context("D3D11CreateDevice returned no device")
}

fn enumerate_raw() -> Result<Vec<(OutputInfo, IDXGIOutput, IDXGIAdapter1)>> {
    let mut result = Vec::new();
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().context("CreateDXGIFactory1 failed")?;
        let mut adapter_index = 0u32;
        loop {
            let adapter = match factory.EnumAdapters1(adapter_index) {
                Ok(adapter) => adapter,
                Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                Err(e) => return Err(e).context(format!("EnumAdapters1({adapter_index}) failed")),
            };
            let adapter_desc = adapter.GetDesc1().context("IDXGIAdapter1::GetDesc1 failed")?;
            let adapter_name = wide_to_string(&adapter_desc.Description);
            let mut output_index = 0u32;
            loop {
                let output = match adapter.EnumOutputs(output_index) {
                    Ok(output) => output,
                    Err(e) if e.code() == DXGI_ERROR_NOT_FOUND => break,
                    Err(e) => {
                        return Err(e).context(format!("EnumOutputs({output_index}) on adapter {adapter_index} failed"))
                    }
                };
                let desc: DXGI_OUTPUT_DESC = output.GetDesc().context("IDXGIOutput::GetDesc failed")?;
                let info = OutputInfo {
                    index: result.len(),
                    adapter_name: adapter_name.clone(),
                    device_name: wide_to_string(&desc.DeviceName),
                    desktop_rect: rect_from_dxgi(&desc.DesktopCoordinates),
                    rotation: desc.Rotation.0 as u32,
                    attached: desc.AttachedToDesktop.as_bool(),
                };
                result.push((info, output, adapter.clone()));
                output_index += 1;
            }
            adapter_index += 1;
        }
    }
    Ok(result)
}

/// Lists every display output across all adapters (flattened index order).
pub fn enumerate_outputs() -> Result<Vec<OutputInfo>> {
    Ok(enumerate_raw()?.into_iter().map(|(info, _, _)| info).collect())
}

/// Desktop Duplication session for one output.
pub struct Duplicator {
    device: ID3D11Device,
    output: IDXGIOutput,
    duplication: Option<IDXGIOutputDuplication>,
    output_info: OutputInfo,
    frame_index: u64,
    rebuild_count: u64,
    metadata_buffer: Vec<u32>,
}

impl Duplicator {
    pub fn new(output_index: usize) -> Result<Self> {
        let all = enumerate_raw()?;
        let (info, output, adapter) = all
            .into_iter()
            .find(|(info, _, _)| info.index == output_index)
            .with_context(|| format!("output index {output_index} not found"))?;

        let device = create_d3d11_device(&adapter)?;
        let duplication = duplicate(&device, &output)?;
        Ok(Self {
            device,
            output,
            duplication: Some(duplication),
            output_info: info,
            frame_index: 0,
            rebuild_count: 0,
            metadata_buffer: Vec::new(),
        })
    }

    pub fn output_info(&self) -> &OutputInfo {
        &self.output_info
    }

    /// Number of session rebuilds (ACCESS_LOST / invalid-call recovery) since creation.
    pub fn rebuild_count(&self) -> u64 {
        self.rebuild_count
    }

    /// Acquires the next frame. `Idle` means nothing changed within the timeout.
    /// Session resets (ACCESS_LOST etc.) are rebuilt transparently and reported as `Idle`.
    pub fn acquire(&mut self, timeout_ms: u32) -> Result<Acquire> {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;

        let acquired = {
            let dup = self.duplication.as_ref().context("duplication session missing")?;
            unsafe { dup.AcquireNextFrame(timeout_ms, &mut info, &mut resource) }
        };

        match acquired {
            Ok(()) => {
                self.frame_index += 1;
                let meta = {
                    let dup = self.duplication.as_ref().context("duplication session missing")?;
                    let buffer = &mut self.metadata_buffer;
                    unsafe { read_metadata(dup, buffer, self.frame_index, &info) }
                };
                drop(resource);
                let released = {
                    let dup = self.duplication.as_ref().context("duplication session missing")?;
                    unsafe { dup.ReleaseFrame() }
                };
                if released.is_err() {
                    self.rebuild().context("rebuilding after ReleaseFrame failure failed")?;
                    return Ok(Acquire::Idle);
                }
                Ok(Acquire::Frame(meta?))
            }
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => Ok(Acquire::Idle),
            Err(e)
                if e.code() == DXGI_ERROR_ACCESS_LOST
                    || e.code() == DXGI_ERROR_INVALID_CALL
                    || e.code() == DXGI_ERROR_ACCESS_DENIED =>
            {
                self.rebuild().context("rebuilding duplication session failed")?;
                Ok(Acquire::Idle)
            }
            Err(e) => Err(e).context("AcquireNextFrame failed"),
        }
    }

    fn rebuild(&mut self) -> Result<()> {
        self.duplication = None;
        let duplication = duplicate(&self.device, &self.output)?;
        self.duplication = Some(duplication);
        self.rebuild_count += 1;
        Ok(())
    }
}

unsafe fn read_metadata(
    dup: &IDXGIOutputDuplication,
    buffer: &mut Vec<u32>,
    frame_index: u64,
    info: &DXGI_OUTDUPL_FRAME_INFO,
) -> Result<FrameMeta> {
    let mut meta = FrameMeta {
        frame_index,
        last_present_time: info.LastPresentTime,
        dirty: Vec::new(),
        moved: Vec::new(),
        pointer_shape_updated: info.PointerShapeBufferSize > 0,
    };

    let cap = info.TotalMetadataBufferSize as usize;
    if cap == 0 {
        return Ok(meta);
    }
    if cap > MAX_METADATA_BYTES {
        bail!("driver reported an implausible metadata size: {cap} bytes");
    }

    buffer.resize(cap.div_ceil(4), 0);
    let byte_ptr = buffer.as_mut_ptr() as *mut u8;

    let mut required = 0u32;
    dup.GetFrameDirtyRects(cap as u32, byte_ptr as *mut RECT, &mut required)
        .context("GetFrameDirtyRects failed")?;
    if required as usize > cap {
        bail!("GetFrameDirtyRects required {required} bytes, buffer was {cap}");
    }
    let rect_count = (required as usize) / size_of::<RECT>();
    let rects = std::slice::from_raw_parts(byte_ptr as *const RECT, rect_count);
    meta.dirty = rects.iter().map(rect_from_dxgi).collect();

    let mut required = 0u32;
    dup.GetFrameMoveRects(cap as u32, byte_ptr as *mut DXGI_OUTDUPL_MOVE_RECT, &mut required)
        .context("GetFrameMoveRects failed")?;
    if required as usize > cap {
        bail!("GetFrameMoveRects required {required} bytes, buffer was {cap}");
    }
    let move_count = (required as usize) / size_of::<DXGI_OUTDUPL_MOVE_RECT>();
    let moves = std::slice::from_raw_parts(byte_ptr as *const DXGI_OUTDUPL_MOVE_RECT, move_count);
    meta.moved = moves
        .iter()
        .map(|m| MoveRect {
            source_x: m.SourcePoint.x,
            source_y: m.SourcePoint.y,
            dest: rect_from_dxgi(&m.DestinationRect),
        })
        .collect();

    Ok(meta)
}

fn duplicate(device: &ID3D11Device, output: &IDXGIOutput) -> Result<IDXGIOutputDuplication> {
    unsafe {
        let output1: IDXGIOutput1 = output.cast().context("cast IDXGIOutput -> IDXGIOutput1 failed")?;
        let unknown = device
            .cast::<windows::core::IUnknown>()
            .context("cast device -> IUnknown failed")?;
        output1
            .DuplicateOutput(&unknown)
            .context("IDXGIOutput1::DuplicateOutput failed (is an RDP session watching this desktop?)")
    }
}

pub fn rotation_name(rotation: u32) -> &'static str {
    let value = rotation as i32;
    if value == DXGI_MODE_ROTATION_IDENTITY.0 {
        "identity"
    } else if value == DXGI_MODE_ROTATION_ROTATE90.0 {
        "rotate90"
    } else if value == DXGI_MODE_ROTATION_ROTATE180.0 {
        "rotate180"
    } else if value == DXGI_MODE_ROTATION_ROTATE270.0 {
        "rotate270"
    } else {
        "unspecified"
    }
}
