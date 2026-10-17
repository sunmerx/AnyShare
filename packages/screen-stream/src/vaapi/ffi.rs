//! libva FFI: structs transcribed from libva 2.20 `va.h` (H.264 decode API
//! lives in the legacy section of va.h, not in va_dec_*.h) and dynamic
//! bindings via libloading (no build-time linkage to libva).

#![allow(non_snake_case, dead_code)]

use std::ffi::c_void;

pub const VA_STATUS_SUCCESS: i32 = 0;
pub const VA_PROGRESSIVE: i32 = 1;
pub const VA_RT_FORMAT_YUV420: u32 = 0x0000_0001;
pub const VA_INVALID_ID: u32 = 0xFFFF_FFFF;
pub const VA_FOURCC_NV12: u32 = 0x3231_564E;
pub const VA_SLICE_DATA_FLAG_ALL: u32 = 0x00;

pub const VA_PROFILE_H264_MAIN: i32 = 6;
pub const VA_PROFILE_H264_HIGH: i32 = 7;
pub const VA_ENTRYPOINT_VLD: i32 = 1;

pub const VA_PICTURE_PARAMETER_BUFFER_TYPE: u32 = 0;
pub const VA_IQ_MATRIX_PARAMETER_BUFFER_TYPE: u32 = 1;
pub const VA_SLICE_PARAMETER_BUFFER_TYPE: u32 = 4;
pub const VA_SLICE_DATA_BUFFER_TYPE: u32 = 5;

pub const VA_PICTURE_H264_INVALID: u32 = 0x0000_0001;
pub const VA_PICTURE_H264_SHORT_TERM_REFERENCE: u32 = 0x0000_0008;

pub type VADisplay = *mut c_void;
pub type VASurfaceID = u32;
pub type VAConfigID = u32;
pub type VAContextID = u32;
pub type VABufferID = u32;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct VAPictureH264 {
    pub picture_id: VASurfaceID,
    pub frame_idx: u32,
    pub flags: u32,
    pub top_field_order_cnt: i32,
    pub bottom_field_order_cnt: i32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VAPictureParameterBufferH264 {
    pub curr_pic: VAPictureH264,
    pub reference_frames: [VAPictureH264; 16],
    pub picture_width_in_mbs_minus1: u16,
    pub picture_height_in_mbs_minus1: u16,
    pub bit_depth_luma_minus8: u8,
    pub bit_depth_chroma_minus8: u8,
    pub num_ref_frames: u8,
    pub seq_fields: u32,
    pub num_slice_groups_minus1: u8,
    pub slice_group_map_type: u8,
    pub slice_group_change_rate_minus1: u16,
    pub pic_init_qp_minus26: i8,
    pub pic_init_qs_minus26: i8,
    pub chroma_qp_index_offset: i8,
    pub second_chroma_qp_index_offset: i8,
    pub pic_fields: u32,
    pub frame_num: u16,
    pub va_reserved: [u32; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VASliceParameterBufferH264 {
    pub slice_data_size: u32,
    pub slice_data_offset: u32,
    pub slice_data_flag: u32,
    pub slice_data_bit_offset: u16,
    pub first_mb_in_slice: u16,
    pub slice_type: u8,
    pub direct_spatial_mv_pred_flag: u8,
    pub num_ref_idx_l0_active_minus1: u8,
    pub num_ref_idx_l1_active_minus1: u8,
    pub cabac_init_idc: u8,
    pub slice_qp_delta: i8,
    pub disable_deblocking_filter_idc: u8,
    pub slice_alpha_c0_offset_div2: i8,
    pub slice_beta_offset_div2: i8,
    pub ref_pic_list0: [VAPictureH264; 32],
    pub ref_pic_list1: [VAPictureH264; 32],
    pub luma_log2_weight_denom: u8,
    pub chroma_log2_weight_denom: u8,
    pub luma_weight_l0_flag: u8,
    pub luma_weight_l0: [i16; 32],
    pub luma_offset_l0: [i16; 32],
    pub chroma_weight_l0_flag: u8,
    pub chroma_weight_l0: [[i16; 2]; 32],
    pub chroma_offset_l0: [[i16; 2]; 32],
    pub luma_weight_l1_flag: u8,
    pub luma_weight_l1: [i16; 32],
    pub luma_offset_l1: [i16; 32],
    pub chroma_weight_l1_flag: u8,
    pub chroma_weight_l1: [[i16; 2]; 32],
    pub chroma_offset_l1: [[i16; 2]; 32],
    pub va_reserved: [u32; 4],
}

impl Default for VASliceParameterBufferH264 {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

/// Zero-filled means flat/default scaling lists (libva convention).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct VAIQMatrixBufferH264 {
    pub scaling_list4x4: [[u8; 16]; 6],
    pub scaling_list8x8: [[u8; 64]; 2],
    pub va_reserved: [u32; 4],
}

impl Default for VAIQMatrixBufferH264 {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

impl Default for VAPictureParameterBufferH264 {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct VAImageFormat {
    pub fourcc: u32,
    pub byte_order: u32,
    pub bits_per_pixel: u32,
    pub depth: u32,
    pub red_mask: u32,
    pub green_mask: u32,
    pub blue_mask: u32,
    pub alpha_mask: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VAImage {
    pub image_id: u32,
    pub format: VAImageFormat,
    pub buf: u32,
    pub width: u16,
    pub height: u16,
    pub data_size: u32,
    pub num_planes: u32,
    pub pitches: [u32; 3],
    pub offsets: [u32; 3],
    pub num_palette_entries: i32,
    pub entry_bytes: i32,
    pub component_order: [i8; 4],
    pub va_reserved: [u32; 4],
}

impl Default for VAImage {
    fn default() -> Self {
        unsafe { std::mem::zeroed() }
    }
}

pub struct VaLib {
    _libva: libloading::Library,
    _libva_drm: libloading::Library,

    pub va_get_display_drm: unsafe extern "C" fn(fd: i32) -> VADisplay,
    pub va_initialize: unsafe extern "C" fn(dpy: VADisplay, major: *mut i32, minor: *mut i32) -> i32,
    pub va_terminate: unsafe extern "C" fn(dpy: VADisplay) -> i32,
    pub va_create_config:
        unsafe extern "C" fn(dpy: VADisplay, profile: i32, entrypoint: i32, attribs: *mut c_void, num: i32, config: *mut u32) -> i32,
    pub va_destroy_config: unsafe extern "C" fn(dpy: VADisplay, config: u32) -> i32,
    pub va_create_surfaces: unsafe extern "C" fn(
        dpy: VADisplay,
        format: u32,
        width: u32,
        height: u32,
        surfaces: *mut u32,
        num_surfaces: u32,
        attribs: *mut c_void,
        num_attribs: u32,
    ) -> i32,
    pub va_destroy_surfaces: unsafe extern "C" fn(dpy: VADisplay, surfaces: *mut u32, num: i32) -> i32,
    pub va_create_context: unsafe extern "C" fn(
        dpy: VADisplay,
        config: u32,
        width: i32,
        height: i32,
        flags: i32,
        surfaces: *mut u32,
        num: i32,
        context: *mut u32,
    ) -> i32,
    pub va_destroy_context: unsafe extern "C" fn(dpy: VADisplay, context: u32) -> i32,
    pub va_create_buffer: unsafe extern "C" fn(
        dpy: VADisplay,
        context: u32,
        buf_type: u32,
        size: u32,
        num_elements: u32,
        data: *mut c_void,
        buf: *mut u32,
    ) -> i32,
    pub va_destroy_buffer: unsafe extern "C" fn(dpy: VADisplay, buf: u32) -> i32,
    pub va_begin_picture: unsafe extern "C" fn(dpy: VADisplay, context: u32, target: u32) -> i32,
    pub va_render_picture: unsafe extern "C" fn(dpy: VADisplay, context: u32, buffers: *mut u32, num: i32) -> i32,
    pub va_end_picture: unsafe extern "C" fn(dpy: VADisplay, context: u32) -> i32,
    pub va_sync_surface: unsafe extern "C" fn(dpy: VADisplay, surface: u32) -> i32,
    pub va_derive_image: unsafe extern "C" fn(dpy: VADisplay, surface: u32, image: *mut VAImage) -> i32,
    pub va_destroy_image: unsafe extern "C" fn(dpy: VADisplay, image: u32) -> i32,
    pub va_map_buffer: unsafe extern "C" fn(dpy: VADisplay, buf: u32, ptr: *mut *mut c_void) -> i32,
    pub va_unmap_buffer: unsafe extern "C" fn(dpy: VADisplay, buf: u32) -> i32,
}

macro_rules! sym {
    ($lib:expr, $name:literal, $ty:ty) => {
        *$lib
            .get($name)
            .map_err(|e| anyhow::anyhow!("libva symbol {} missing: {e}", stringify!($name)))?
    };
}

impl VaLib {
    pub fn load() -> anyhow::Result<Self> {
        unsafe {
            let libva = libloading::Library::new("libva.so.2")
                .map_err(|e| anyhow::anyhow!("dlopen libva.so.2 failed: {e}"))?;
            let libva_drm = libloading::Library::new("libva-drm.so.2")
                .map_err(|e| anyhow::anyhow!("dlopen libva-drm.so.2 failed: {e}"))?;

            Ok(Self {
                va_get_display_drm: sym!(libva_drm, b"vaGetDisplayDRM\0", unsafe extern "C" fn(i32) -> VADisplay),
                va_initialize: sym!(libva, b"vaInitialize\0", unsafe extern "C" fn(VADisplay, *mut i32, *mut i32) -> i32),
                va_terminate: sym!(libva, b"vaTerminate\0", unsafe extern "C" fn(VADisplay) -> i32),
                va_create_config: sym!(
                    libva,
                    b"vaCreateConfig\0",
                    unsafe extern "C" fn(VADisplay, i32, i32, *mut c_void, i32, *mut u32) -> i32
                ),
                va_destroy_config: sym!(libva, b"vaDestroyConfig\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_create_surfaces: sym!(
                    libva,
                    b"vaCreateSurfaces\0",
                    unsafe extern "C" fn(VADisplay, u32, u32, u32, *mut u32, u32, *mut c_void, u32) -> i32
                ),
                va_destroy_surfaces: sym!(libva, b"vaDestroySurfaces\0", unsafe extern "C" fn(VADisplay, *mut u32, i32) -> i32),
                va_create_context: sym!(
                    libva,
                    b"vaCreateContext\0",
                    unsafe extern "C" fn(VADisplay, u32, i32, i32, i32, *mut u32, i32, *mut u32) -> i32
                ),
                va_destroy_context: sym!(libva, b"vaDestroyContext\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_create_buffer: sym!(
                    libva,
                    b"vaCreateBuffer\0",
                    unsafe extern "C" fn(VADisplay, u32, u32, u32, u32, *mut c_void, *mut u32) -> i32
                ),
                va_destroy_buffer: sym!(libva, b"vaDestroyBuffer\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_begin_picture: sym!(libva, b"vaBeginPicture\0", unsafe extern "C" fn(VADisplay, u32, u32) -> i32),
                va_render_picture: sym!(libva, b"vaRenderPicture\0", unsafe extern "C" fn(VADisplay, u32, *mut u32, i32) -> i32),
                va_end_picture: sym!(libva, b"vaEndPicture\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_sync_surface: sym!(libva, b"vaSyncSurface\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_derive_image: sym!(libva, b"vaDeriveImage\0", unsafe extern "C" fn(VADisplay, u32, *mut VAImage) -> i32),
                va_destroy_image: sym!(libva, b"vaDestroyImage\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                va_map_buffer: sym!(libva, b"vaMapBuffer\0", unsafe extern "C" fn(VADisplay, u32, *mut *mut c_void) -> i32),
                va_unmap_buffer: sym!(libva, b"vaUnmapBuffer\0", unsafe extern "C" fn(VADisplay, u32) -> i32),
                _libva: libva,
                _libva_drm: libva_drm,
            })
        }
    }
}
