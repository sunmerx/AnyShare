//! Native VAAPI H.264 decoder (Linux): libva via dlopen, no libavcodec, no
//! subprocess. Scope: streams produced by this project (Main/High, I/P only).

pub mod ffi;
pub mod h264;

use std::os::fd::AsRawFd;
use std::path::Path;

use anyhow::{bail, Context, Result};

use ffi::*;
use h264::{nal_type, parse_pps, parse_slice_header, parse_sps, split_nals, Pps, SliceHeader, Sps};

const SURFACE_COUNT: usize = 17;

pub struct VaapiDecoder {
    lib: VaLib,
    _device: std::fs::File,
    dpy: VADisplay,
    config: u32,
    context: u32,
    surfaces: Vec<u32>,
    next_surface: usize,
    sps: Option<Sps>,
    pps: Option<Pps>,
    dpb: Vec<(u32, i32, u32)>,
    prev_poc_lsb: u32,
    poc_msb: i32,
    // POC type 2 state (H.264 8.2.1.3): wraps MaxFrameNum into the offset.
    prev_frame_num: u32,
    frame_num_offset: u32,
    width: u32,
    height: u32,
}

fn check(status: i32, what: &str) -> Result<()> {
    if status == VA_STATUS_SUCCESS {
        Ok(())
    } else {
        bail!("{what} failed with VAStatus {status:#x}");
    }
}

impl VaapiDecoder {
    pub fn new(device_path: &str) -> Result<Self> {
        let device = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(Path::new(device_path))
            .with_context(|| format!("opening VAAPI device {device_path}"))?;
        let lib = VaLib::load()?;
        let dpy = unsafe { (lib.va_get_display_drm)(device.as_raw_fd()) };
        if dpy.is_null() {
            bail!("vaGetDisplayDRM returned null");
        }
        let mut major = 0i32;
        let mut minor = 0i32;
        check(unsafe { (lib.va_initialize)(dpy, &mut major, &mut minor) }, "vaInitialize")?;

        let mut config = VA_INVALID_ID;
        let mut last_status = 0;
        for profile in [VA_PROFILE_H264_MAIN, VA_PROFILE_H264_HIGH] {
            let status = unsafe {
                (lib.va_create_config)(dpy, profile, VA_ENTRYPOINT_VLD, std::ptr::null_mut(), 0, &mut config)
            };
            if status == VA_STATUS_SUCCESS {
                last_status = 0;
                break;
            }
            last_status = status;
        }
        if config == VA_INVALID_ID {
            bail!("no H.264 VLD config (VAStatus {last_status:#x})");
        }

        Ok(Self {
            lib,
            _device: device,
            dpy,
            config,
            context: VA_INVALID_ID,
            surfaces: Vec::new(),
            next_surface: 0,
            sps: None,
            pps: None,
            dpb: Vec::new(),
            prev_poc_lsb: 0,
            prev_frame_num: 0,
            frame_num_offset: 0,
            poc_msb: 0,
            width: 0,
            height: 0,
        })
    }

    fn ensure_surfaces(&mut self, width: u32, height: u32) -> Result<()> {
        if self.context != VA_INVALID_ID && self.width == width && self.height == height {
            return Ok(());
        }
        if self.context != VA_INVALID_ID {
            unsafe {
                let _ = (self.lib.va_destroy_context)(self.dpy, self.context);
                let _ = (self.lib.va_destroy_surfaces)(self.dpy, self.surfaces.as_mut_ptr(), self.surfaces.len() as i32);
            }
            self.context = VA_INVALID_ID;
            self.surfaces.clear();
            self.dpb.clear();
        }

        let mut surfaces = vec![VA_INVALID_ID; SURFACE_COUNT];
        check(
            unsafe {
                (self.lib.va_create_surfaces)(
                    self.dpy,
                    VA_RT_FORMAT_YUV420,
                    width,
                    height,
                    surfaces.as_mut_ptr(),
                    SURFACE_COUNT as u32,
                    std::ptr::null_mut(),
                    0,
                )
            },
            "vaCreateSurfaces",
        )?;

        let mut context = VA_INVALID_ID;
        let create = unsafe {
            (self.lib.va_create_context)(
                self.dpy,
                self.config,
                width as i32,
                height as i32,
                VA_PROGRESSIVE,
                surfaces.as_mut_ptr(),
                surfaces.len() as i32,
                &mut context,
            )
        };
        if create != VA_STATUS_SUCCESS {
            unsafe {
                let _ = (self.lib.va_destroy_surfaces)(self.dpy, surfaces.as_mut_ptr(), surfaces.len() as i32);
            }
            check(create, "vaCreateContext")?;
        }

        self.surfaces = surfaces;
        self.context = context;
        self.width = width;
        self.height = height;
        self.next_surface = 0;
        Ok(())
    }

    fn alloc_surface(&mut self) -> u32 {
        for _ in 0..SURFACE_COUNT {
            let surface = self.surfaces[self.next_surface];
            self.next_surface = (self.next_surface + 1) % SURFACE_COUNT;
            if !self.dpb.iter().any(|(_, _, s)| *s == surface) {
                return surface;
            }
        }
        // All surfaces referenced: steal the oldest DPB entry.
        let surface = self.surfaces[self.next_surface];
        self.next_surface = (self.next_surface + 1) % SURFACE_COUNT;
        self.dpb.retain(|(_, _, s)| *s != surface);
        surface
    }

    fn compute_poc(&mut self, sps: &Sps, slice: &SliceHeader) -> Result<i32> {
        if slice.idr {
            self.prev_poc_lsb = 0;
            self.poc_msb = 0;
            self.prev_frame_num = 0;
            self.frame_num_offset = 0;
            return Ok(0);
        }
        match sps.pic_order_cnt_type {
            0 => {
                let max_lsb = 1u32 << sps.log2_max_poc_lsb();
                if slice.poc_lsb < self.prev_poc_lsb && self.prev_poc_lsb - slice.poc_lsb >= max_lsb / 2 {
                    self.poc_msb += max_lsb as i32;
                } else if slice.poc_lsb > self.prev_poc_lsb && slice.poc_lsb - self.prev_poc_lsb > max_lsb / 2 {
                    self.poc_msb -= max_lsb as i32;
                }
                self.prev_poc_lsb = slice.poc_lsb;
                Ok(self.poc_msb + slice.poc_lsb as i32)
            }
            // Type 2 (no reordering, frame_num-derived) is what low-latency
            // encoders emit (no B-frames). H.264 8.2.1.3: FrameNumOffset
            // accumulates MaxFrameNum on wrap; non-reference pictures use POC
            // -1. Without the wrap handling, POC goes backwards after a GOP
            // longer than MaxFrameNum and the reference list order breaks
            // until the next IDR.
            2 => {
                let max_frame_num = 1u32 << sps.log2_max_frame_num();
                let frame_num = slice.frame_num;
                if self.prev_frame_num > frame_num {
                    self.frame_num_offset = self.frame_num_offset.wrapping_add(max_frame_num);
                }
                self.prev_frame_num = frame_num;
                if slice.nal_ref_idc == 0 {
                    Ok(-1)
                } else {
                    Ok(2 * (self.frame_num_offset.wrapping_add(frame_num) as i32))
                }
            }
            other => bail!("pic_order_cnt_type {other} unsupported"),
        }
    }

    fn picture_from(&self, surface: u32, frame_idx: u32, poc: i32, reference: bool) -> VAPictureH264 {
        VAPictureH264 {
            picture_id: surface,
            frame_idx,
            flags: if reference { VA_PICTURE_H264_SHORT_TERM_REFERENCE } else { 0 },
            top_field_order_cnt: poc,
            bottom_field_order_cnt: poc,
            va_reserved: [0; 4],
        }
    }

    /// Decodes one access unit. Returns `(width, height, argb)` when a picture
    /// was produced.
    pub fn decode(&mut self, au: &[u8]) -> Result<Option<(u32, u32, Vec<u32>)>> {
        let mut slices: Vec<&[u8]> = Vec::new();
        for nal in split_nals(au) {
            match nal_type(nal) {
                7 => self.sps = Some(parse_sps(nal).context("SPS parse")?),
                8 => {
                    let pps = parse_pps(nal).context("PPS parse")?;
                    self.pps = Some(pps);
                }
                1 | 5 => slices.push(nal),
                _ => {}
            }
        }
        if slices.is_empty() {
            return Ok(None);
        }
        let Some(sps) = self.sps.clone() else {
            bail!("slice without SPS");
        };
        let Some(pps) = self.pps.clone() else {
            bail!("slice without PPS");
        };
        if sps.chroma_format_idc != 1 || sps.bit_depth_luma_minus8 != 0 {
            bail!("unsupported chroma/depth (chroma_format_idc={})", sps.chroma_format_idc);
        }
        let mb_width = sps.pic_width_in_mbs_minus1 + 1;
        let mb_height = (sps.pic_height_in_map_units_minus1 + 1) * if sps.frame_mbs_only { 1 } else { 2 };
        let surface_width = mb_width * 16;
        let surface_height = mb_height * 16;
        self.ensure_surfaces(surface_width, surface_height)?;

        let mut headers = Vec::with_capacity(slices.len());
        for slice in &slices {
            headers.push(parse_slice_header(slice, &sps, &pps).context("slice header parse")?);
        }
        let first = headers[0].clone();
        let is_idr = first.idr;
        let poc = self.compute_poc(&sps, &first)?;
        if is_idr {
            self.dpb.clear();
        }
        let curr_surface = self.alloc_surface();

        // H.264 8.2.4.2: short-term references are ordered by descending
        // PicOrderCnt (frame_num only breaks ties).
        let mut refs: Vec<(u32, i32, u32)> = self.dpb.clone();
        refs.sort_by(|a, b| b.1.cmp(&a.1).then(b.0.cmp(&a.0)));
        refs.truncate(16);

        let mut picture = VAPictureParameterBufferH264::default();
        picture.curr_pic = self.picture_from(curr_surface, 0, poc, first.nal_ref_idc != 0);
        for (i, slot) in picture.reference_frames.iter_mut().enumerate() {
            *slot = match refs.get(i) {
                Some((frame_num, ref_poc, surface)) => self.picture_from(*surface, *frame_num, *ref_poc, true),
                None => VAPictureH264 {
                    flags: VA_PICTURE_H264_INVALID,
                    ..Default::default()
                },
            };
        }
        picture.picture_width_in_mbs_minus1 = sps.pic_width_in_mbs_minus1 as u16;
        picture.picture_height_in_mbs_minus1 = sps.pic_height_in_map_units_minus1 as u16;
        picture.bit_depth_luma_minus8 = sps.bit_depth_luma_minus8;
        picture.bit_depth_chroma_minus8 = sps.bit_depth_chroma_minus8;
        picture.num_ref_frames = sps.max_num_ref_frames.min(16) as u8;
        picture.seq_fields = (u32::from(sps.chroma_format_idc) & 0x3)
            | ((u32::from(sps.frame_mbs_only as u8)) << 4)
            | ((u32::from(sps.mb_adaptive_frame_field as u8)) << 5)
            | ((u32::from(sps.direct_8x8_inference as u8)) << 6)
            | ((u32::from(sps.log2_max_frame_num_minus4) & 0xF) << 8)
            | ((u32::from(sps.pic_order_cnt_type) & 0x3) << 12)
            | ((u32::from(sps.log2_max_pic_order_cnt_lsb_minus4) & 0xF) << 14)
            | ((u32::from(sps.delta_pic_order_always_zero as u8)) << 18);
        picture.pic_init_qp_minus26 = pps.pic_init_qp_minus26 as i8;
        picture.pic_init_qs_minus26 = pps.pic_init_qs_minus26 as i8;
        picture.chroma_qp_index_offset = pps.chroma_qp_index_offset as i8;
        picture.second_chroma_qp_index_offset = pps.second_chroma_qp_index_offset as i8;
        picture.pic_fields = (u32::from(pps.entropy_coding_mode as u8))
            | ((u32::from(pps.weighted_pred as u8)) << 1)
            | ((u32::from(pps.weighted_bipred_idc) & 0x3) << 2)
            | ((u32::from(pps.transform_8x8_mode as u8)) << 4)
            | ((u32::from(pps.constrained_intra_pred as u8)) << 6)
            | ((u32::from(pps.bottom_field_pic_order_in_frame_present as u8)) << 7)
            | ((u32::from(pps.deblocking_filter_control_present as u8)) << 8)
            | ((u32::from(pps.redundant_pic_cnt_present as u8)) << 9)
            | ((u32::from(first.nal_ref_idc != 0)) << 10);
        picture.frame_num = first.frame_num as u16;

        let mut picture_buf = VA_INVALID_ID;
        check(
            unsafe {
                (self.lib.va_create_buffer)(
                    self.dpy,
                    self.context,
                    VA_PICTURE_PARAMETER_BUFFER_TYPE,
                    std::mem::size_of::<VAPictureParameterBufferH264>() as u32,
                    1,
                    &mut picture as *mut _ as *mut std::ffi::c_void,
                    &mut picture_buf,
                )
            },
            "vaCreateBuffer(picture)",
        )?;

        let mut iq_buf = VA_INVALID_ID;
        let mut iq_matrix = VAIQMatrixBufferH264::default();
        let iq_status = unsafe {
            (self.lib.va_create_buffer)(
                self.dpy,
                self.context,
                VA_IQ_MATRIX_PARAMETER_BUFFER_TYPE,
                std::mem::size_of::<VAIQMatrixBufferH264>() as u32,
                1,
                &mut iq_matrix as *mut _ as *mut std::ffi::c_void,
                &mut iq_buf,
            )
        };
        if iq_status != VA_STATUS_SUCCESS {
            unsafe {
                let _ = (self.lib.va_destroy_buffer)(self.dpy, picture_buf);
            }
            check(iq_status, "vaCreateBuffer(iq matrix)")?;
        }

        let mut to_destroy: Vec<u32> = vec![picture_buf, iq_buf];
        let mut render_buffers: Vec<u32> = vec![picture_buf, iq_buf];

        let begin = unsafe { (self.lib.va_begin_picture)(self.dpy, self.context, curr_surface) };
        if begin != VA_STATUS_SUCCESS {
            for &buffer in &to_destroy {
                unsafe {
                    let _ = (self.lib.va_destroy_buffer)(self.dpy, buffer);
                }
            }
            check(begin, "vaBeginPicture")?;
        }
        let result = (|| -> Result<()> {
            for (slice_nal, header) in slices.iter().zip(headers.iter()) {
                let mut slice_param = VASliceParameterBufferH264::default();
                slice_param.slice_data_size = slice_nal.len() as u32;
                slice_param.slice_data_offset = 0;
                slice_param.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
                slice_param.slice_data_bit_offset = header.slice_data_bit_offset;
                slice_param.first_mb_in_slice = header.first_mb_in_slice as u16;
                slice_param.slice_type = header.slice_type as u8;
                slice_param.direct_spatial_mv_pred_flag = 0;
                slice_param.num_ref_idx_l0_active_minus1 = header.num_ref_idx_l0_active_minus1 as u8;
                slice_param.num_ref_idx_l1_active_minus1 = header.num_ref_idx_l1_active_minus1 as u8;
                slice_param.cabac_init_idc = header.cabac_init_idc as u8;
                slice_param.slice_qp_delta = header.slice_qp_delta as i8;
                slice_param.disable_deblocking_filter_idc = header.disable_deblocking_filter_idc as u8;
                slice_param.slice_alpha_c0_offset_div2 = header.slice_alpha_c0_offset_div2 as i8;
                slice_param.slice_beta_offset_div2 = header.slice_beta_offset_div2 as i8;
                for (i, slot) in slice_param.ref_pic_list0.iter_mut().enumerate() {
                    *slot = match refs.get(i) {
                        Some((frame_num, ref_poc, surface)) => self.picture_from(*surface, *frame_num, *ref_poc, true),
                        None => VAPictureH264 {
                            flags: VA_PICTURE_H264_INVALID,
                            ..Default::default()
                        },
                    };
                }

                let mut param_buf = VA_INVALID_ID;
                check(
                    unsafe {
                        (self.lib.va_create_buffer)(
                            self.dpy,
                            self.context,
                            VA_SLICE_PARAMETER_BUFFER_TYPE,
                            std::mem::size_of::<VASliceParameterBufferH264>() as u32,
                            1,
                            &mut slice_param as *mut _ as *mut std::ffi::c_void,
                            &mut param_buf,
                        )
                    },
                    "vaCreateBuffer(slice params)",
                )?;
                to_destroy.push(param_buf);

                let mut data_buf = VA_INVALID_ID;
                check(
                    unsafe {
                        (self.lib.va_create_buffer)(
                            self.dpy,
                            self.context,
                            VA_SLICE_DATA_BUFFER_TYPE,
                            slice_nal.len() as u32,
                            1,
                            slice_nal.as_ptr() as *mut std::ffi::c_void,
                            &mut data_buf,
                        )
                    },
                    "vaCreateBuffer(slice data)",
                )?;
                to_destroy.push(data_buf);
                render_buffers.push(param_buf);
                render_buffers.push(data_buf);
            }
            check(
                unsafe {
                    (self.lib.va_render_picture)(self.dpy, self.context, render_buffers.as_mut_ptr(), render_buffers.len() as i32)
                },
                "vaRenderPicture",
            )?;
            check(unsafe { (self.lib.va_end_picture)(self.dpy, self.context) }, "vaEndPicture")?;
            Ok(())
        })();

        // If rendering failed after the picture was opened, close it so the
        // context does not stay wedged until the next IDR.
        if result.is_err() {
            unsafe {
                let _ = (self.lib.va_end_picture)(self.dpy, self.context);
            }
        }
        for buffer in to_destroy {
            unsafe {
                let _ = (self.lib.va_destroy_buffer)(self.dpy, buffer);
            }
        }
        result?;

        check(unsafe { (self.lib.va_sync_surface)(self.dpy, curr_surface) }, "vaSyncSurface")?;

        if first.nal_ref_idc != 0 {
            self.dpb.push((first.frame_num, poc, curr_surface));
            let max_refs = (sps.max_num_ref_frames.max(1) as usize).min(SURFACE_COUNT - 1);
            while self.dpb.len() > max_refs {
                self.dpb.remove(0);
            }
        }

        let argb = self.export_argb(curr_surface, &sps)?;
        Ok(Some((sps.width, sps.height, argb)))
    }

    fn export_argb(&mut self, surface: u32, sps: &Sps) -> Result<Vec<u32>> {
        let mut image = VAImage::default();
        check(unsafe { (self.lib.va_derive_image)(self.dpy, surface, &mut image) }, "vaDeriveImage")?;
        if image.format.fourcc != VA_FOURCC_NV12 {
            unsafe {
                let _ = (self.lib.va_destroy_image)(self.dpy, image.image_id);
            }
            bail!("derived image format {:#x} is not NV12", image.format.fourcc);
        }

        let mut ptr: *mut std::ffi::c_void = std::ptr::null_mut();
        let map_result = unsafe { (self.lib.va_map_buffer)(self.dpy, image.buf, &mut ptr) };
        if map_result != VA_STATUS_SUCCESS || ptr.is_null() {
            unsafe {
                let _ = (self.lib.va_destroy_image)(self.dpy, image.image_id);
            }
            bail!("vaMapBuffer failed ({map_result:#x})");
        }

        let width = sps.width as usize;
        let height = sps.height as usize;
        // CropUnitX = SubWidthC, CropUnitY = SubHeightC * (frame_mbs_only ? 1 : 2); 4:2:0 -> 2x2 or 2x4.
        let crop_unit_y = 2 * if sps.frame_mbs_only { 1 } else { 2 };
        let (crop_x, crop_y) = (sps.crop.0 as usize * 2, sps.crop.2 as usize * crop_unit_y);
        let y_pitch = image.pitches[0] as usize;
        let uv_pitch = image.pitches[1] as usize;
        let y_offset = image.offsets[0] as usize;
        let uv_offset = image.offsets[1] as usize;
        if std::env::var("ANYSHARE_VAAPI_TRACE").is_ok() {
            let base = ptr as *const u8;
            let mut ys = Vec::new();
            for i in 0..6 {
                let row = (crop_y + i * 50).min(image.height as usize - 1);
                ys.push(unsafe { *base.add(y_offset + row * y_pitch + crop_x) });
            }
            eprintln!(
                "vaapi trace: surface={} planes={} y_pitch={} uv_pitch={} y_off={} uv_off={} size={}x{} y_samples={:?}",
                surface,
                image.num_planes,
                y_pitch,
                uv_pitch,
                y_offset,
                uv_offset,
                image.width,
                image.height,
                ys
            );
        }

        let mut argb = Vec::with_capacity(width * height);
        unsafe {
            let base = ptr as *const u8;
            for row in 0..height {
                let src_y = crop_y + row;
                let y_row = base.add(y_offset + src_y * y_pitch);
                let uv_row = base.add(uv_offset + (src_y / 2) * uv_pitch);
                for col in 0..width {
                    let src_x = crop_x + col;
                    let y = i32::from(*y_row.add(src_x)) - 16;
                    let u = i32::from(*uv_row.add((src_x / 2) * 2)) - 128;
                    let v = i32::from(*uv_row.add((src_x / 2) * 2 + 1)) - 128;
                    let y = if y < 0 { 0 } else { y };
                    let r = (298 * y + 409 * v + 128) >> 8;
                    let g = (298 * y - 100 * u - 208 * v + 128) >> 8;
                    let b = (298 * y + 516 * u + 128) >> 8;
                    argb.push(
                        (r.clamp(0, 255) as u32) << 16 | (g.clamp(0, 255) as u32) << 8 | (b.clamp(0, 255) as u32),
                    );
                }
            }
        }

        unsafe {
            let _ = (self.lib.va_unmap_buffer)(self.dpy, image.buf);
            let _ = (self.lib.va_destroy_image)(self.dpy, image.image_id);
        }
        Ok(argb)
    }
}

impl Drop for VaapiDecoder {
    fn drop(&mut self) {
        unsafe {
            if self.context != VA_INVALID_ID {
                let _ = (self.lib.va_destroy_context)(self.dpy, self.context);
            }
            if !self.surfaces.is_empty() {
                let _ = (self.lib.va_destroy_surfaces)(self.dpy, self.surfaces.as_mut_ptr(), self.surfaces.len() as i32);
            }
            if self.config != VA_INVALID_ID {
                let _ = (self.lib.va_destroy_config)(self.dpy, self.config);
            }
            let _ = (self.lib.va_terminate)(self.dpy);
        }
    }
}
