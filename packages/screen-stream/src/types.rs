//! Platform-independent capture types.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub fn width(&self) -> i32 {
        self.right.saturating_sub(self.left).max(0)
    }

    pub fn height(&self) -> i32 {
        self.bottom.saturating_sub(self.top).max(0)
    }

    pub fn area(&self) -> i64 {
        i64::from(self.width()) * i64::from(self.height())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MoveRect {
    pub source_x: i32,
    pub source_y: i32,
    pub dest: Rect,
}

#[derive(Clone, Debug)]
pub struct OutputInfo {
    /// Flattened adapter/output index — the identifier used to select a capture target.
    pub index: usize,
    pub adapter_name: String,
    /// Device name such as `\\.\DISPLAY1`.
    pub device_name: String,
    /// Desktop-space rectangle (already reflects the desktop layout after rotation).
    pub desktop_rect: Rect,
    /// DXGI_MODE_ROTATION value.
    pub rotation: u32,
    pub attached: bool,
}

#[derive(Clone, Debug, Default)]
pub struct FrameMeta {
    pub frame_index: u64,
    /// DXGI semantics: 0 means no new desktop content in this frame (pointer-only update).
    pub last_present_time: i64,
    pub dirty: Vec<Rect>,
    pub moved: Vec<MoveRect>,
    pub pointer_shape_updated: bool,
}

#[derive(Clone, Debug)]
pub enum Acquire {
    Frame(FrameMeta),
    /// No frame arrived within the acquire timeout (desktop is idle).
    Idle,
}

/// Captured pixels in compact rows (stride = width * 4), BGRA8.
#[derive(Clone, Debug)]
pub struct FramePixels {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}
