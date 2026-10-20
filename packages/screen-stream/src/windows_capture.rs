//! Windows screen capture via DXGI Desktop Duplication (metadata level).

use std::mem::size_of;

use anyhow::{bail, Context, Result};
use windows::core::Interface;
use windows::Win32::Foundation::{HINSTANCE, RECT};
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, D3D11_CPU_ACCESS_READ,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_MODE_ROTATION_IDENTITY, DXGI_MODE_ROTATION_ROTATE180,
    DXGI_MODE_ROTATION_ROTATE270, DXGI_MODE_ROTATION_ROTATE90, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter, IDXGIAdapter1, IDXGIFactory1, IDXGIOutput, IDXGIOutput1, IDXGIOutputDuplication,
    IDXGIResource, DXGI_ERROR_ACCESS_DENIED, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_INVALID_CALL, DXGI_ERROR_NOT_FOUND,
    DXGI_ERROR_WAIT_TIMEOUT, DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_MOVE_RECT, DXGI_OUTDUPL_POINTER_SHAPE_INFO,
    DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR, DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME, DXGI_OUTPUT_DESC,
};

use crate::types::{Acquire, FrameMeta, FramePixels, MoveRect, OutputInfo, Rect};

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

fn create_d3d11_device(adapter: &IDXGIAdapter1) -> Result<(ID3D11Device, ID3D11DeviceContext)> {
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
    Ok((
        device.context("D3D11CreateDevice returned no device")?,
        context.context("D3D11CreateDevice returned no context")?,
    ))
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
    context: ID3D11DeviceContext,
    output: IDXGIOutput,
    duplication: Option<IDXGIOutputDuplication>,
    output_info: OutputInfo,
    frame_index: u64,
    rebuild_count: u64,
    metadata_buffer: Vec<u32>,
    staging: Option<ID3D11Texture2D>,
    staging_size: (u32, u32),
    pixel_buffer: Vec<u8>,
    // Cursor state: DXGI duplication frames do not include the pointer, it
    // must be composited from the frame metadata.
    pointer_shape: Vec<u8>,
    pointer_shape_info: DXGI_OUTDUPL_POINTER_SHAPE_INFO,
    pointer_position: (i32, i32),
    pointer_visible: bool,
}

impl Duplicator {
    pub fn new(output_index: usize) -> Result<Self> {
        let all = enumerate_raw()?;
        let (info, output, adapter) = all
            .into_iter()
            .find(|(info, _, _)| info.index == output_index)
            .with_context(|| format!("output index {output_index} not found"))?;

        let (device, context) = create_d3d11_device(&adapter)?;
        let duplication = duplicate(&device, &output)?;
        Ok(Self {
            device,
            context,
            output,
            duplication: Some(duplication),
            output_info: info,
            frame_index: 0,
            rebuild_count: 0,
            metadata_buffer: Vec::new(),
            staging: None,
            staging_size: (0, 0),
            pixel_buffer: Vec::new(),
            pointer_shape: Vec::new(),
            pointer_shape_info: DXGI_OUTDUPL_POINTER_SHAPE_INFO::default(),
            pointer_position: (0, 0),
            pointer_visible: false,
        })
    }

    pub fn output_info(&self) -> &OutputInfo {
        &self.output_info
    }

    /// The size the duplication texture actually carries. This can differ from
    /// [`OutputInfo::desktop_rect`] when the driver GPU-scales a lower desktop
    /// resolution onto a larger panel mode (e.g. 1920x1200 desktop on a
    /// 2880x1800 panel); the encoder must be configured with this size or it
    /// is fed mismatched buffers and emits garbage.
    pub fn capture_size(&self) -> Result<(u32, u32)> {
        let dup = self.duplication.as_ref().context("duplication session missing")?;
        let desc = unsafe { dup.GetDesc() };
        Ok((desc.ModeDesc.Width, desc.ModeDesc.Height))
    }

    /// Number of session rebuilds (ACCESS_LOST / invalid-call recovery) since creation.
    pub fn rebuild_count(&self) -> u64 {
        self.rebuild_count
    }

    /// Acquires the next frame metadata only. `Idle` means nothing changed within the timeout.
    /// Session resets (ACCESS_LOST etc.) are rebuilt transparently and reported as `Idle`.
    pub fn acquire(&mut self, timeout_ms: u32) -> Result<Acquire> {
        Ok(match self.acquire_internal(timeout_ms, false)? {
            None => Acquire::Idle,
            Some((meta, _)) => Acquire::Frame(meta),
        })
    }

    /// Acquires the next frame together with its pixels (compact BGRA8 rows).
    /// `None` means nothing changed within the timeout.
    pub fn acquire_full(&mut self, timeout_ms: u32) -> Result<Option<(FrameMeta, FramePixels)>> {
        match self.acquire_internal(timeout_ms, true)? {
            None => Ok(None),
            Some((meta, pixels)) => Ok(Some((
                meta,
                pixels.context("pixel copy requested but not produced")?,
            ))),
        }
    }

    fn acquire_internal(
        &mut self,
        timeout_ms: u32,
        copy_pixels: bool,
    ) -> Result<Option<(FrameMeta, Option<FramePixels>)>> {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource: Option<IDXGIResource> = None;

        let acquired = {
            let dup = self.duplication.as_ref().context("duplication session missing")?;
            unsafe { dup.AcquireNextFrame(timeout_ms, &mut info, &mut resource) }
        };

        match acquired {
            Ok(()) => {
                self.frame_index += 1;
                let mut meta = {
                    let dup = self.duplication.as_ref().context("duplication session missing")?;
                    let buffer = &mut self.metadata_buffer;
                    unsafe { read_metadata(dup, buffer, self.frame_index, &info) }
                };

                // Pointer state: the position fields are only valid when
                // LastMouseUpdateTime says the mouse actually changed —
                // overwriting them on desktop-only frames would teleport the
                // cursor to (0,0) / mark it invisible.
                if info.LastMouseUpdateTime != 0 {
                    let new_position = (info.PointerPosition.Position.x, info.PointerPosition.Position.y);
                    let new_visible = info.PointerPosition.Visible.as_bool();
                    if let Ok(meta) = meta.as_mut() {
                        meta.pointer_moved =
                            new_visible != self.pointer_visible || (new_visible && new_position != self.pointer_position);
                    }
                    self.pointer_position = new_position;
                    self.pointer_visible = new_visible;
                }
                if info.PointerShapeBufferSize > 0 {
                    let size = info.PointerShapeBufferSize as usize;
                    self.pointer_shape.resize(size, 0);
                    let mut required = 0u32;
                    let mut shape_info = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
                    let dup = self.duplication.as_ref().context("duplication session missing")?;
                    let fetched = unsafe {
                        dup.GetFramePointerShape(
                            size as u32,
                            self.pointer_shape.as_mut_ptr() as *mut _,
                            &mut required,
                            &mut shape_info,
                        )
                    };
                    match fetched {
                        Ok(()) => {
                            self.pointer_shape.truncate((required as usize).min(size));
                            self.pointer_shape_info = shape_info;
                        }
                        Err(e) => {
                            eprintln!("windows_capture: GetFramePointerShape failed: {e}");
                            self.pointer_shape.clear();
                        }
                    }
                }

                let pixels = if copy_pixels {
                    match resource.as_ref() {
                        Some(resource) => Some(unsafe { self.copy_pixels(resource) }),
                        None => Some(Err(anyhow::anyhow!("no desktop resource in frame"))),
                    }
                } else {
                    None
                };

                drop(resource);
                let released = {
                    let dup = self.duplication.as_ref().context("duplication session missing")?;
                    unsafe { dup.ReleaseFrame() }
                };
                if released.is_err() {
                    self.rebuild().context("rebuilding after ReleaseFrame failure failed")?;
                    return Ok(None);
                }
                Ok(Some((meta?, pixels.transpose()?)))
            }
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => Ok(None),
            Err(e)
                if e.code() == DXGI_ERROR_ACCESS_LOST
                    || e.code() == DXGI_ERROR_INVALID_CALL
                    || e.code() == DXGI_ERROR_ACCESS_DENIED =>
            {
                self.rebuild().context("rebuilding duplication session failed")?;
                Ok(None)
            }
            Err(e) => Err(e).context("AcquireNextFrame failed"),
        }
    }

    unsafe fn copy_pixels(&mut self, resource: &IDXGIResource) -> Result<FramePixels> {
        let texture: ID3D11Texture2D = resource.cast().context("cast frame resource -> ID3D11Texture2D failed")?;
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        texture.GetDesc(&mut desc);
        if desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM {
            bail!("unsupported capture pixel format {:?} (expected BGRA8)", desc.Format.0);
        }
        let (width, height) = (desc.Width, desc.Height);

        if self.staging.is_none() || self.staging_size != (width, height) {
            let staging_desc = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: desc.Format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut staging: Option<ID3D11Texture2D> = None;
            self.device
                .CreateTexture2D(&staging_desc, None, Some(&mut staging))
                .context("CreateTexture2D(staging) failed")?;
            self.staging = staging;
            self.staging_size = (width, height);
        }

        let staging = self.staging.as_ref().context("staging texture missing")?;
        self.context.CopyResource(staging, &texture);

        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        self.context
            .Map(staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
            .context("Map(staging) failed")?;

        let pitch = mapped.RowPitch as usize;
        let row_bytes = width as usize * 4;
        let total = row_bytes * height as usize;
        self.pixel_buffer.resize(total, 0);
        {
            let src = std::slice::from_raw_parts(mapped.pData as *const u8, pitch * height as usize);
            for row in 0..height as usize {
                let src_row = &src[row * pitch..row * pitch + row_bytes];
                let start = row * row_bytes;
                self.pixel_buffer[start..start + row_bytes].copy_from_slice(src_row);
            }
        }
        self.context.Unmap(staging, 0);

        self.composite_pointer(width, height);

        Ok(FramePixels {
            width,
            height,
            bgra: std::mem::take(&mut self.pixel_buffer),
        })
    }

    /// Draws the cursor into the BGRA buffer. DXGI duplication frames never
    /// contain the pointer; without this the stream looks frozen (the VFR gate
    /// sees no change while the user moves the mouse).
    fn composite_pointer(&mut self, width: u32, height: u32) {
        if !self.pointer_visible || self.pointer_shape.is_empty() {
            return;
        }
        let info = self.pointer_shape_info;
        if info.Width == 0 || info.Height == 0 || info.Pitch == 0 {
            return;
        }
        // DXGI reports the pointer relative to this output's top-left corner;
        // scale it when the duplication texture differs from the desktop rect
        // (GPU-scaled modes).
        let origin_w = self.output_info.desktop_rect.width().max(1);
        let origin_h = self.output_info.desktop_rect.height().max(1);
        let px = (self.pointer_position.0 as i64 * width as i64 / origin_w as i64) as i32;
        let py = (self.pointer_position.1 as i64 * height as i64 / origin_h as i64) as i32;
        let buffer = &mut self.pixel_buffer;
        let shape = &self.pointer_shape;
        match info.Type {
            t if t == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR.0 as u32 => {
                let pitch = info.Pitch as usize;
                for row in 0..info.Height as usize {
                    let dy = py + row as i32;
                    if dy < 0 || dy >= height as i32 {
                        continue;
                    }
                    for col in 0..info.Width as usize {
                        let dx = px + col as i32;
                        if dx < 0 || dx >= width as i32 {
                            continue;
                        }
                        let s = row * pitch + col * 4;
                        if s + 4 > shape.len() {
                            continue;
                        }
                        let alpha = shape[s + 3] as u32;
                        if alpha == 0 {
                            continue;
                        }
                        // COLOR shapes are premultiplied BGRA.
                        let b = shape[s] as u32;
                        let g = shape[s + 1] as u32;
                        let r = shape[s + 2] as u32;
                        let di = (dy as usize * width as usize + dx as usize) * 4;
                        let db = buffer[di] as u32;
                        let dg = buffer[di + 1] as u32;
                        let dr = buffer[di + 2] as u32;
                        let inv = 255 - alpha;
                        buffer[di] = (b + db * inv / 255).min(255) as u8;
                        buffer[di + 1] = (g + dg * inv / 255).min(255) as u8;
                        buffer[di + 2] = (r + dr * inv / 255).min(255) as u8;
                    }
                }
            }
            t if t == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME.0 as u32 => {
                // 1bpp AND mask followed by the XOR mask, MSB-first rows.
                let row_bytes = info.Pitch as usize;
                let mask_len = row_bytes * info.Height as usize;
                for row in 0..info.Height as usize {
                    let dy = py + row as i32;
                    if dy < 0 || dy >= height as i32 {
                        continue;
                    }
                    for col in 0..info.Width as usize {
                        let dx = px + col as i32;
                        if dx < 0 || dx >= width as i32 {
                            continue;
                        }
                        let byte = col / 8;
                        let bit = 7 - (col % 8) as u32;
                        let and_off = row * row_bytes + byte;
                        let xor_off = mask_len + and_off;
                        if xor_off >= shape.len() {
                            continue;
                        }
                        let and_b = (shape[and_off] >> bit) & 1;
                        let xor_b = (shape[xor_off] >> bit) & 1;
                        let di = (dy as usize * width as usize + dx as usize) * 4;
                        match (and_b, xor_b) {
                            (0, 0) => {
                                buffer[di] = 0;
                                buffer[di + 1] = 0;
                                buffer[di + 2] = 0;
                            }
                            (0, 1) => {
                                buffer[di] = 255;
                                buffer[di + 1] = 255;
                                buffer[di + 2] = 255;
                            }
                            (1, 0) => {}
                            (1, 1) => {
                                buffer[di] = !buffer[di];
                                buffer[di + 1] = !buffer[di + 1];
                                buffer[di + 2] = !buffer[di + 2];
                            }
                            _ => unreachable!(),
                        }
                    }
                }
            }
            t if t == 4u32 => {
                // MASKED_COLOR: alpha 0 replaces RGB, alpha 255 XORs the
                // destination (per DXGI semantics).
                let pitch = info.Pitch as usize;
                for row in 0..info.Height as usize {
                    let dy = py + row as i32;
                    if dy < 0 || dy >= height as i32 {
                        continue;
                    }
                    for col in 0..info.Width as usize {
                        let dx = px + col as i32;
                        if dx < 0 || dx >= width as i32 {
                            continue;
                        }
                        let s = row * pitch + col * 4;
                        if s + 4 > shape.len() {
                            continue;
                        }
                        let di = (dy as usize * width as usize + dx as usize) * 4;
                        match shape[s + 3] {
                            0 => {
                                buffer[di] = shape[s];
                                buffer[di + 1] = shape[s + 1];
                                buffer[di + 2] = shape[s + 2];
                            }
                            0xFF => {
                                buffer[di] = !buffer[di];
                                buffer[di + 1] = !buffer[di + 1];
                                buffer[di + 2] = !buffer[di + 2];
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }

    /// Returns the pixel buffer to the duplicator so the next capture can reuse
    /// its allocation instead of re-allocating ~8 MiB per frame.
    pub fn recycle_pixels(&mut self, pixels: FramePixels) {
        self.pixel_buffer = pixels.bgra;
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
        pointer_moved: false,
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
