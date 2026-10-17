//! Color conversion helpers. Scalar BGRA -> I420 (BT.601 limited range).
//! SIMD / GPU (Video Processor MFT) paths are future work.

/// Converts a compact BGRA8 image (row stride = width * 4) to I420.
/// Chroma is box-averaged over 2x2 blocks (edge pixels duplicated for odd sizes).
pub fn bgra_to_i420(bgra: &[u8], width: u32, height: u32, out: &mut Vec<u8>) {
    let w = width as usize;
    let h = height as usize;
    assert!(bgra.len() >= w * h * 4, "bgra buffer too small");

    let uv_w = w.div_ceil(2);
    let uv_h = h.div_ceil(2);
    let y_size = w * h;
    let uv_size = uv_w * uv_h;
    out.clear();
    out.resize(y_size + uv_size * 2, 0);

    let (y_plane, rest) = out.split_at_mut(y_size);
    let (u_plane, v_plane) = rest.split_at_mut(uv_size);

    for j in 0..h {
        for i in 0..w {
            let p = &bgra[(j * w + i) * 4..][..4];
            let (r, g, b) = (i32::from(p[2]), i32::from(p[1]), i32::from(p[0]));
            let y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[j * w + i] = y.clamp(0, 255) as u8;
        }
    }

    for jj in 0..uv_h {
        for ii in 0..uv_w {
            let mut sum_r = 0i32;
            let mut sum_g = 0i32;
            let mut sum_b = 0i32;
            for dy in 0..2 {
                for dx in 0..2 {
                    let x = (ii * 2 + dx).min(w - 1);
                    let y = (jj * 2 + dy).min(h - 1);
                    let p = &bgra[(y * w + x) * 4..][..4];
                    sum_b += i32::from(p[0]);
                    sum_g += i32::from(p[1]);
                    sum_r += i32::from(p[2]);
                }
            }
            let (r, g, b) = (sum_r / 4, sum_g / 4, sum_b / 4);
            let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            let idx = jj * uv_w + ii;
            u_plane[idx] = u.clamp(0, 255) as u8;
            v_plane[idx] = v.clamp(0, 255) as u8;
        }
    }
}

/// Converts compact BGRA8 to NV12 (Y plane followed by interleaved UV plane).
pub fn bgra_to_nv12(bgra: &[u8], width: u32, height: u32, out: &mut Vec<u8>) {
    let w = width as usize;
    let h = height as usize;
    assert!(bgra.len() >= w * h * 4, "bgra buffer too small");

    let uv_w = w.div_ceil(2);
    let uv_h = h.div_ceil(2);
    let y_size = w * h;
    out.clear();
    out.resize(y_size + uv_w * uv_h * 2, 0);

    let (y_plane, uv_plane) = out.split_at_mut(y_size);

    for j in 0..h {
        for i in 0..w {
            let p = &bgra[(j * w + i) * 4..][..4];
            let (r, g, b) = (i32::from(p[2]), i32::from(p[1]), i32::from(p[0]));
            let y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            y_plane[j * w + i] = y.clamp(0, 255) as u8;
        }
    }

    for jj in 0..uv_h {
        for ii in 0..uv_w {
            let mut sum_r = 0i32;
            let mut sum_g = 0i32;
            let mut sum_b = 0i32;
            for dy in 0..2 {
                for dx in 0..2 {
                    let x = (ii * 2 + dx).min(w - 1);
                    let y = (jj * 2 + dy).min(h - 1);
                    let p = &bgra[(y * w + x) * 4..][..4];
                    sum_b += i32::from(p[0]);
                    sum_g += i32::from(p[1]);
                    sum_r += i32::from(p[2]);
                }
            }
            let (r, g, b) = (sum_r / 4, sum_g / 4, sum_b / 4);
            let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            let idx = (jj * uv_w + ii) * 2;
            uv_plane[idx] = u.clamp(0, 255) as u8;
            uv_plane[idx + 1] = v.clamp(0, 255) as u8;
        }
    }
}

/// Swaps the U and V planes of an I420 buffer in place, producing YV12.
pub fn i420_to_yv12_in_place(buf: &mut [u8], width: u32, height: u32) {
    let uv_size = (width.div_ceil(2) * height.div_ceil(2)) as usize;
    let y_size = (width * height) as usize;
    for i in 0..uv_size {
        buf.swap(y_size + i, y_size + uv_size + i);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, b: u8, g: u8, r: u8) -> Vec<u8> {
        let mut v = Vec::with_capacity((width * height * 4) as usize);
        for _ in 0..width * height {
            v.extend_from_slice(&[b, g, r, 255]);
        }
        v
    }

    #[test]
    fn nv12_plane_sizes_and_neutral_chroma() {
        let mut out = Vec::new();
        bgra_to_nv12(&solid(2, 2, 128, 128, 128), 2, 2, &mut out);
        assert_eq!(out.len(), 4 + 2);
        assert_eq!(out[0], 126);
        assert_eq!(out[4], 128);
        assert_eq!(out[5], 128);
    }

    #[test]
    fn plane_sizes_for_even_and_odd() {
        let mut out = Vec::new();
        bgra_to_i420(&solid(4, 4, 0, 0, 0), 4, 4, &mut out);
        assert_eq!(out.len(), 16 + 4 + 4);

        bgra_to_i420(&solid(3, 3, 0, 0, 0), 3, 3, &mut out);
        assert_eq!(out.len(), 9 + 4 + 4);
    }

    #[test]
    fn luminance_reference_values() {
        let mut out = Vec::new();
        bgra_to_i420(&solid(2, 2, 255, 255, 255), 2, 2, &mut out);
        assert_eq!(out[0], 235);
        assert_eq!(out[4], 128);
        assert_eq!(out[5], 128);

        bgra_to_i420(&solid(2, 2, 0, 0, 0), 2, 2, &mut out);
        assert_eq!(out[0], 16);

        bgra_to_i420(&solid(2, 2, 128, 128, 128), 2, 2, &mut out);
        assert_eq!(out[0], 126);
        assert_eq!(out[4], 128);
        assert_eq!(out[5], 128);
    }

    #[test]
    fn red_reference_values() {
        let mut out = Vec::new();
        bgra_to_i420(&solid(2, 2, 0, 0, 255), 2, 2, &mut out);
        assert_eq!(out[0], 82);
        assert_eq!(out[4], 90);
        assert_eq!(out[5], 240);
    }

    #[test]
    fn odd_size_chroma_duplicates_edge() {
        let mut bgra = Vec::new();
        for y in 0..3 {
            for x in 0..3 {
                let v = (y * 3 + x) as u8 * 20;
                bgra.extend_from_slice(&[v, v, v, 255]);
            }
        }
        let mut out = Vec::new();
        bgra_to_i420(&bgra, 3, 3, &mut out);
        assert_eq!(out.len(), 9 + 4 + 4);
        assert!(out[9..].iter().all(|&uv| uv == 128), "gray input must yield neutral chroma");
    }
}
