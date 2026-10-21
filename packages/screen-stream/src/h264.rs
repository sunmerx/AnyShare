//! Minimal H.264 parser: SPS / PPS / slice headers — just enough to fill the
//! VAAPI parameter buffers. Scope matches this project's own encoder output
//! (Main/High, progressive, single slice per frame, no B-frames, no weighted
//! prediction, no ref-list modifications); anything outside that scope is
//! rejected with a clear error so the caller can fall back.

use anyhow::{bail, Result};

pub struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> BitReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn read_bit(&mut self) -> Result<u32> {
        if self.pos >= self.data.len() * 8 {
            bail!("bitstream exhausted");
        }
        let byte = self.data[self.pos / 8];
        let bit = (byte >> (7 - (self.pos % 8))) & 1;
        self.pos += 1;
        Ok(u32::from(bit))
    }

    pub fn read_bits(&mut self, n: u32) -> Result<u32> {
        let mut value = 0u32;
        for _ in 0..n {
            value = (value << 1) | self.read_bit()?;
        }
        Ok(value)
    }

    pub fn ue(&mut self) -> Result<u32> {
        let mut zeros = 0u32;
        while self.read_bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                bail!("exp-golomb overflow");
            }
        }
        if zeros == 0 {
            return Ok(0);
        }
        let rest = self.read_bits(zeros)?;
        Ok((1 << zeros) - 1 + rest)
    }

    pub fn se(&mut self) -> Result<i32> {
        let code = self.ue()?;
        let value = code.div_ceil(2) as i32;
        if code % 2 == 0 {
            Ok(-value)
        } else {
            Ok(value)
        }
    }

    pub fn bit_pos(&self) -> usize {
        self.pos
    }

    /// True when more RBSP data follows, i.e. the remaining bits are not just
    /// the rbsp_stop_one_bit plus zero padding (H.264 7.2 `more_rbsp_data`).
    pub fn more_rbsp_data(&self) -> bool {
        let total = self.data.len() * 8;
        if self.pos >= total {
            return false;
        }
        let first = (self.data[self.pos / 8] >> (7 - (self.pos % 8))) & 1;
        if first == 0 {
            return true;
        }
        ((self.pos + 1)..total).any(|bit| (self.data[bit / 8] >> (7 - (bit % 8))) & 1 == 1)
    }
}

pub fn split_nals(au: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            let start = if i > 0 && au[i - 1] == 0 { i - 1 } else { i };
            starts.push((start, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut nals = Vec::new();
    for (index, (_, data_start)) in starts.iter().enumerate() {
        let end = starts.get(index + 1).map(|(s, _)| *s).unwrap_or(au.len());
        if *data_start < end {
            nals.push(&au[*data_start..end]);
        }
    }
    nals
}

pub fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1f).unwrap_or(0)
}

pub fn nal_ref_idc(nal: &[u8]) -> u8 {
    nal.first().map(|b| (b >> 5) & 3).unwrap_or(0)
}

pub fn remove_epb(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut zeros = 0;
    for &byte in data {
        if zeros >= 2 && byte == 0x03 {
            zeros = 0;
            continue;
        }
        if byte == 0 {
            zeros += 1;
        } else {
            zeros = 0;
        }
        out.push(byte);
    }
    out
}

#[derive(Clone, Debug)]
pub struct Sps {
    pub profile_idc: u8,
    pub chroma_format_idc: u8,
    pub separate_colour_plane: bool,
    pub bit_depth_luma_minus8: u8,
    pub bit_depth_chroma_minus8: u8,
    pub log2_max_frame_num_minus4: u8,
    pub pic_order_cnt_type: u8,
    pub delta_pic_order_always_zero: bool,
    pub log2_max_pic_order_cnt_lsb_minus4: u8,
    pub max_num_ref_frames: u32,
    pub pic_width_in_mbs_minus1: u32,
    pub pic_height_in_map_units_minus1: u32,
    pub frame_mbs_only: bool,
    pub mb_adaptive_frame_field: bool,
    pub direct_8x8_inference: bool,
    pub crop: (u32, u32, u32, u32),
    pub width: u32,
    pub height: u32,
}

impl Sps {
    pub fn log2_max_frame_num(&self) -> u32 {
        u32::from(self.log2_max_frame_num_minus4) + 4
    }

    pub fn log2_max_poc_lsb(&self) -> u32 {
        u32::from(self.log2_max_pic_order_cnt_lsb_minus4) + 4
    }
}

#[derive(Clone, Debug)]
pub struct Pps {
    pub pps_id: u32,
    pub sps_id: u32,
    pub entropy_coding_mode: bool,
    pub bottom_field_pic_order_in_frame_present: bool,
    pub num_ref_idx_l0_default_minus1: u32,
    pub num_ref_idx_l1_default_minus1: u32,
    pub weighted_pred: bool,
    pub weighted_bipred_idc: u8,
    pub pic_init_qp_minus26: i32,
    pub pic_init_qs_minus26: i32,
    pub chroma_qp_index_offset: i32,
    pub second_chroma_qp_index_offset: i32,
    pub transform_8x8_mode: bool,
    pub deblocking_filter_control_present: bool,
    pub constrained_intra_pred: bool,
    pub redundant_pic_cnt_present: bool,
}

fn skip_scaling_list(reader: &mut BitReader, size: usize) -> Result<()> {
    let mut last_scale = 8i32;
    let mut next_scale = 8i32;
    for _ in 0..size {
        if next_scale != 0 {
            let delta = reader.se()?;
            next_scale = (last_scale + delta + 256) % 256;
        }
        last_scale = if next_scale == 0 { last_scale } else { next_scale };
    }
    Ok(())
}

pub fn parse_sps(nal: &[u8]) -> Result<Sps> {
    let data = remove_epb(nal);
    let mut reader = BitReader::new(&data);
    let _ = reader.read_bits(8)?; // NAL header
    let profile_idc = reader.read_bits(8)? as u8;
    let _constraint = reader.read_bits(8)?;
    let _level_idc = reader.read_bits(8)?;
    let _sps_id = reader.ue()?;

    let mut chroma_format_idc = 1u8;
    let mut separate_colour_plane = false;
    let mut bit_depth_luma_minus8 = 0u8;
    let mut bit_depth_chroma_minus8 = 0u8;
    if matches!(profile_idc, 100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135) {
        chroma_format_idc = reader.ue()? as u8;
        if chroma_format_idc == 3 {
            separate_colour_plane = reader.read_bit()? == 1;
        }
        bit_depth_luma_minus8 = reader.ue()? as u8;
        bit_depth_chroma_minus8 = reader.ue()? as u8;
        let _qpprime = reader.read_bit()?;
        let seq_scaling = reader.read_bit()?;
        if seq_scaling == 1 {
            let count = if chroma_format_idc != 3 { 8 } else { 12 };
            for i in 0..count {
                if reader.read_bit()? == 1 {
                    skip_scaling_list(&mut reader, if i < 6 { 16 } else { 64 })?;
                }
            }
        }
    }

    let log2_max_frame_num_minus4 = reader.ue()? as u8;
    let pic_order_cnt_type = reader.ue()? as u8;
    let mut delta_pic_order_always_zero = false;
    let mut log2_max_pic_order_cnt_lsb_minus4 = 0u8;
    if pic_order_cnt_type == 0 {
        log2_max_pic_order_cnt_lsb_minus4 = reader.ue()? as u8;
    } else if pic_order_cnt_type == 1 {
        delta_pic_order_always_zero = reader.read_bit()? == 1;
        let _offset_for_non_ref_pic = reader.se()?;
        let _offset_for_top_to_bottom_field = reader.se()?;
        let cycle = reader.ue()?;
        if cycle > 255 {
            bail!("pic_order_cnt_cycle too large");
        }
        for _ in 0..cycle {
            let _ = reader.se()?;
        }
    } else if pic_order_cnt_type != 2 {
        bail!("unsupported pic_order_cnt_type {pic_order_cnt_type}");
    }

    let max_num_ref_frames = reader.ue()?;
    let _gaps_in_frame_num_value_allowed = reader.read_bit()?;
    let pic_width_in_mbs_minus1 = reader.ue()?;
    let pic_height_in_map_units_minus1 = reader.ue()?;
    let frame_mbs_only = reader.read_bit()? == 1;
    let mut mb_adaptive_frame_field = false;
    if !frame_mbs_only {
        mb_adaptive_frame_field = reader.read_bit()? == 1;
    }
    let direct_8x8_inference = reader.read_bit()? == 1;
    let crop_flag = reader.read_bit()?;
    let mut crop = (0u32, 0u32, 0u32, 0u32);
    if crop_flag == 1 {
        crop = (reader.ue()?, reader.ue()?, reader.ue()?, reader.ue()?);
    }
    let _vui_present = reader.read_bit()?;

    let chroma_array_type = if separate_colour_plane { 0 } else { chroma_format_idc };
    let (sub_width_c, sub_height_c) = match chroma_array_type {
        0 => (1u32, 1u32),
        1 => (2, 2),
        2 => (2, 1),
        _ => (1, 1),
    };
    let crop_unit_x = sub_width_c;
    let crop_unit_y = sub_height_c * if frame_mbs_only { 1 } else { 2 };
    let width = (pic_width_in_mbs_minus1 + 1) * 16 - (crop.0 + crop.1) * crop_unit_x;
    let height = (pic_height_in_map_units_minus1 + 1) * 16 * if frame_mbs_only { 1 } else { 2 }
        - (crop.2 + crop.3) * crop_unit_y;

    Ok(Sps {
        profile_idc,
        chroma_format_idc,
        separate_colour_plane,
        bit_depth_luma_minus8,
        bit_depth_chroma_minus8,
        log2_max_frame_num_minus4,
        pic_order_cnt_type,
        delta_pic_order_always_zero,
        log2_max_pic_order_cnt_lsb_minus4,
        max_num_ref_frames,
        pic_width_in_mbs_minus1,
        pic_height_in_map_units_minus1,
        frame_mbs_only,
        mb_adaptive_frame_field,
        direct_8x8_inference,
        crop,
        width,
        height,
    })
}

pub fn parse_pps(nal: &[u8]) -> Result<Pps> {
    let data = remove_epb(nal);
    let mut reader = BitReader::new(&data);
    let _ = reader.read_bits(8)?;
    let pps_id = reader.ue()?;
    let sps_id = reader.ue()?;
    let entropy_coding_mode = reader.read_bit()? == 1;
    let bottom_field_pic_order_in_frame_present = reader.read_bit()? == 1;
    let num_slice_groups_minus1 = reader.ue()?;
    if num_slice_groups_minus1 != 0 {
        bail!("slice groups (FMO) unsupported");
    }
    let num_ref_idx_l0_default_minus1 = reader.ue()?;
    let num_ref_idx_l1_default_minus1 = reader.ue()?;
    let weighted_pred = reader.read_bit()? == 1;
    let weighted_bipred_idc = reader.read_bits(2)? as u8;
    let pic_init_qp_minus26 = reader.se()?;
    let pic_init_qs_minus26 = reader.se()?;
    let chroma_qp_index_offset = reader.se()?;
    let deblocking_filter_control_present = reader.read_bit()? == 1;
    let constrained_intra_pred = reader.read_bit()? == 1;
    let redundant_pic_cnt_present = reader.read_bit()? == 1;
    let mut transform_8x8_mode = false;
    let mut second_chroma_qp_index_offset = chroma_qp_index_offset;
    if reader.more_rbsp_data() {
        transform_8x8_mode = reader.read_bit()? == 1;
        let pic_scaling_matrix_present = reader.read_bit()? == 1;
        if pic_scaling_matrix_present {
            bail!("pic_scaling_matrix unsupported");
        }
        second_chroma_qp_index_offset = reader.se()?;
    }
    Ok(Pps {
        pps_id,
        sps_id,
        entropy_coding_mode,
        bottom_field_pic_order_in_frame_present,
        num_ref_idx_l0_default_minus1,
        num_ref_idx_l1_default_minus1,
        weighted_pred,
        weighted_bipred_idc,
        pic_init_qp_minus26,
        pic_init_qs_minus26,
        chroma_qp_index_offset,
        second_chroma_qp_index_offset,
        transform_8x8_mode,
        deblocking_filter_control_present,
        constrained_intra_pred,
        redundant_pic_cnt_present,
    })
}

#[derive(Clone, Debug)]
pub struct SliceHeader {
    pub nal_ref_idc: u8,
    pub first_mb_in_slice: u32,
    pub slice_type: u32,
    pub pps_id: u32,
    pub frame_num: u32,
    pub field_pic_flag: bool,
    pub idr: bool,
    pub poc_lsb: u32,
    pub delta_poc_bottom: i32,
    pub num_ref_idx_l0_active_minus1: u32,
    pub num_ref_idx_l1_active_minus1: u32,
    pub cabac_init_idc: u32,
    pub slice_qp_delta: i32,
    pub disable_deblocking_filter_idc: u32,
    pub slice_alpha_c0_offset_div2: i32,
    pub slice_beta_offset_div2: i32,
    /// End of the slice header fields, in bits (emulation prevention bytes
    /// removed), relative to the start of the NAL.
    pub bit_offset: u16,
    /// Bit offset of the slice data (after CABAC byte alignment, when CABAC is
    /// on), emulation prevention bytes removed — the domain libva expects.
    pub slice_data_bit_offset: u16,
}

pub fn parse_slice_header(nal: &[u8], sps: &Sps, pps: &Pps) -> Result<SliceHeader> {
    let data = remove_epb(nal);
    let mut reader = BitReader::new(&data);
    let _ = reader.read_bits(8)?;
    let ref_idc = nal_ref_idc(nal);
    let idr = nal_type(nal) == 5;

    let first_mb_in_slice = reader.ue()?;
    let slice_type = reader.ue()?;
    if matches!(slice_type % 5, 3 | 4) {
        bail!("SP/SI slices unsupported");
    }
    let pps_id = reader.ue()?;
    if pps_id != pps.pps_id {
        bail!("slice references unknown pps {pps_id}");
    }
    if sps.separate_colour_plane {
        bail!("separate colour plane unsupported");
    }
    let frame_num = reader.read_bits(sps.log2_max_frame_num())?;
    let mut field_pic_flag = false;
    if !sps.frame_mbs_only {
        field_pic_flag = reader.read_bit()? == 1;
        if field_pic_flag {
            let _bottom_field = reader.read_bit()?;
            bail!("field pictures unsupported");
        }
    }
    if idr {
        let _idr_pic_id = reader.ue()?;
    }
    let mut poc_lsb = 0u32;
    let mut delta_poc_bottom = 0i32;
    match sps.pic_order_cnt_type {
        0 => {
            poc_lsb = reader.read_bits(sps.log2_max_poc_lsb())?;
            if pps.bottom_field_pic_order_in_frame_present {
                delta_poc_bottom = reader.se()?;
            }
        }
        1 => {
            if !sps.delta_pic_order_always_zero {
                let _delta0 = reader.se()?;
                if pps.bottom_field_pic_order_in_frame_present {
                    let _delta1 = reader.se()?;
                }
            }
        }
        _ => {}
    }
    if pps.redundant_pic_cnt_present {
        let _redundant = reader.ue()?;
    }
    let slice_is_b = slice_type % 5 == 1;
    if slice_is_b {
        let _direct_spatial = reader.read_bit()?;
    }
    let mut num_ref_idx_l0_active_minus1 = pps.num_ref_idx_l0_default_minus1;
    let mut num_ref_idx_l1_active_minus1 = pps.num_ref_idx_l1_default_minus1;
    let slice_is_p_or_b = matches!(slice_type % 5, 0 | 1);
    if slice_is_p_or_b {
        let override_flag = reader.read_bit()?;
        if override_flag == 1 {
            num_ref_idx_l0_active_minus1 = reader.ue()?;
            if slice_is_b {
                num_ref_idx_l1_active_minus1 = reader.ue()?;
            }
        }
    }
    let slice_is_i_or_si = matches!(slice_type % 5, 2 | 4);
    if !slice_is_i_or_si {
        let flag_l0 = reader.read_bit()?;
        if flag_l0 == 1 {
            loop {
                let idc = reader.ue()?;
                match idc {
                    0 | 1 | 2 => {
                        let _ = reader.ue()?;
                    }
                    3 => break,
                    _ => bail!("invalid modification_of_pic_nums_idc {idc}"),
                }
            }
        }
        if slice_is_b {
            let flag_l1 = reader.read_bit()?;
            if flag_l1 == 1 {
                loop {
                    let idc = reader.ue()?;
                    match idc {
                        0 | 1 | 2 => {
                            let _ = reader.ue()?;
                        }
                        3 => break,
                        _ => bail!("invalid modification_of_pic_nums_idc {idc}"),
                    }
                }
            }
        }
    }
    let weighted = (pps.weighted_pred && matches!(slice_type % 5, 0 | 3)) || (pps.weighted_bipred_idc == 1 && slice_is_b);
    if weighted {
        bail!("weighted prediction unsupported");
    }
    if ref_idc != 0 {
        if idr {
            let _no_output = reader.read_bit()?;
            let _long_term = reader.read_bit()?;
        } else {
            let adaptive = reader.read_bit()?;
            if adaptive == 1 {
                bail!("adaptive ref pic marking unsupported");
            }
        }
    }
    let mut cabac_init_idc = 0u32;
    if pps.entropy_coding_mode && !slice_is_i_or_si {
        cabac_init_idc = reader.ue()?;
    }
    let slice_qp_delta = reader.se()?;
    let mut disable_deblocking_filter_idc = 0u32;
    let mut slice_alpha_c0_offset_div2 = 0i32;
    let mut slice_beta_offset_div2 = 0i32;
    if pps.deblocking_filter_control_present {
        disable_deblocking_filter_idc = reader.ue()?;
        if disable_deblocking_filter_idc != 1 {
            slice_alpha_c0_offset_div2 = reader.se()?;
            slice_beta_offset_div2 = reader.se()?;
        }
    }

    let bit_offset = reader.bit_pos();
    if bit_offset > u16::MAX as usize {
        bail!("slice header too large");
    }
    // va.h documents slice_data_bit_offset as the number of bits parsed in
    // slice_header() after removal of emulation prevention bytes. With CABAC
    // the slice data starts after cabac_alignment_one_bit padding to the next
    // byte boundary (verified against iHD).
    let slice_data_bit_offset = if pps.entropy_coding_mode {
        bit_offset.div_ceil(8) * 8
    } else {
        bit_offset
    };
    if slice_data_bit_offset > u16::MAX as usize {
        bail!("slice header too large");
    }

    Ok(SliceHeader {
        nal_ref_idc: ref_idc,
        first_mb_in_slice,
        slice_type,
        pps_id,
        frame_num,
        field_pic_flag,
        idr,
        poc_lsb,
        delta_poc_bottom,
        num_ref_idx_l0_active_minus1,
        num_ref_idx_l1_active_minus1,
        cabac_init_idc,
        slice_qp_delta,
        disable_deblocking_filter_idc,
        slice_alpha_c0_offset_div2,
        slice_beta_offset_div2,
        bit_offset: bit_offset as u16,
        slice_data_bit_offset: slice_data_bit_offset as u16,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bit_reader_exp_golomb() {
        // 1 -> ue 0; 010 -> ue 1; 011 -> ue 2; 00100 -> ue 3
        let data = [0b1_010_011_0, 0b0100_0000];
        let mut reader = BitReader::new(&data);
        assert_eq!(reader.ue().unwrap(), 0);
        assert_eq!(reader.ue().unwrap(), 1);
        assert_eq!(reader.ue().unwrap(), 2);
        assert_eq!(reader.ue().unwrap(), 3);
    }

    #[test]
    fn bit_reader_signed_exp_golomb() {
        // se: 1->0; 010->1; 011->-1; 00100->2; 00101->-2
        // bits: 1 010 011 00100 00101 -> 1010_0110 0100_0010 1
        let data = [0b1010_0110, 0b0100_0010, 0b1000_0000];
        let mut reader = BitReader::new(&data);
        assert_eq!(reader.se().unwrap(), 0);
        assert_eq!(reader.se().unwrap(), 1);
        assert_eq!(reader.se().unwrap(), -1);
        assert_eq!(reader.se().unwrap(), 2);
        assert_eq!(reader.se().unwrap(), -2);
    }

    #[test]
    fn epb_removal() {
        let data = [0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x00];
        assert_eq!(remove_epb(&data), vec![0x00, 0x00, 0x01, 0x00, 0x00, 0x00]);
    }

    #[test]
    fn split_nals_mixed_start_codes() {
        let au = [0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC];
        let nals = split_nals(&au);
        assert_eq!(nals.len(), 2);
        assert_eq!(nals[0], [0x67, 0xAA]);
        assert_eq!(nals[1], [0x68, 0xBB, 0xCC]);
    }

    // Captured from the AMD MF encoder (regression: the slice header parser
    // used to skip ref_pic_list_modification_flag_l0 and read
    // modification_of_pic_nums_idc unconditionally, which shifted every field
    // after it; ground truth values verified with ffmpeg's trace_headers).
    const CAPTURED_SPS: &[u8] = &[
        0x67, 0x4d, 0x04, 0x28, 0xe8, 0xa0, 0x3c, 0x01, 0x13, 0xf2, 0xff, 0xe0, 0x00, 0x20, 0x00, 0x28, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00,
        0x03, 0x03, 0xc8, 0xf0, 0x88, 0x46, 0x58,
    ];
    const CAPTURED_PPS: &[u8] = &[0x68, 0xee, 0x3c, 0x80];
    const CAPTURED_SLICE: &[u8] = &[
        0x41, 0x9a, 0x44, 0x1f, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x2d, 0x0a, 0x7d, 0x5e, 0xfb, 0xea, 0xad, 0x9f, 0x0b, 0xad, 0xbc, 0x07, 0x75,
    ];

    #[test]
    fn captured_p_slice_header_parses() {
        let sps = parse_sps(CAPTURED_SPS).unwrap();
        assert_eq!(sps.width, 1920);
        assert_eq!(sps.height, 1080);
        assert_eq!(sps.pic_order_cnt_type, 0);
        assert_eq!(sps.log2_max_frame_num(), 4);
        assert_eq!(sps.log2_max_poc_lsb(), 5);
        let pps = parse_pps(CAPTURED_PPS).unwrap();
        assert!(pps.entropy_coding_mode);
        assert!(!pps.bottom_field_pic_order_in_frame_present);
        assert!(pps.deblocking_filter_control_present);

        let header = parse_slice_header(CAPTURED_SLICE, &sps, &pps).unwrap();
        assert_eq!(header.first_mb_in_slice, 0);
        assert_eq!(header.slice_type, 5);
        assert_eq!(header.frame_num, 2);
        assert_eq!(header.poc_lsb, 4);
        assert_eq!(header.num_ref_idx_l0_active_minus1, 0);
        assert_eq!(header.cabac_init_idc, 0);
        assert_eq!(header.slice_qp_delta, 0);
        assert_eq!(header.disable_deblocking_filter_idc, 0);
        // Header fields end at clean bit 32; the EPBs in this slice start after
        // that, so the wire offsets equal the clean ones and slice data begins
        // at the byte-aligned bit 32.
        assert_eq!(header.bit_offset, 32);
        assert_eq!(header.slice_data_bit_offset, 32);
    }
}
