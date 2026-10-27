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

/// Box-averages a compact BGRA image down to (dw, dh). Downscaling at the
/// sender is the E2.0 decision (1080p cap): it cuts the CPU conversion,
/// encode, transport, decode and present costs by the pixel ratio, and the
/// fixed bitrate then buys much sharper pixels.
pub fn bgra_box_scale(src: &[u8], sw: u32, sh: u32, dw: u32, dh: u32, out: &mut Vec<u8>) {
    let sw = sw as usize;
    let sh = sh as usize;
    let dw = dw as usize;
    let dh = dh as usize;
    assert!(src.len() >= sw * sh * 4, "bgra buffer too small");
    out.clear();
    out.resize(dw * dh * 4, 0);
    for dy in 0..dh {
        let sy0 = dy * sh / dh;
        let sy1 = (((dy + 1) * sh) / dh).max(sy0 + 1).min(sh);
        for dx in 0..dw {
            let sx0 = dx * sw / dw;
            let sx1 = (((dx + 1) * sw) / dw).max(sx0 + 1).min(sw);
            let (mut b, mut g, mut r, mut a, mut n) = (0u32, 0u32, 0u32, 0u32, 0u32);
            for sy in sy0..sy1 {
                let row = sy * sw * 4;
                for sx in sx0..sx1 {
                    let i = row + sx * 4;
                    b += src[i] as u32;
                    g += src[i + 1] as u32;
                    r += src[i + 2] as u32;
                    a += src[i + 3] as u32;
                    n += 1;
                }
            }
            let o = (dy * dw + dx) * 4;
            out[o] = (b / n) as u8;
            out[o + 1] = (g / n) as u8;
            out[o + 2] = (r / n) as u8;
            out[o + 3] = (a / n) as u8;
        }
    }
}

/// Unsharp mask on the luma plane only (chroma untouched, so colours cannot
/// fringe). Screen content is mostly text and thin lines, which the downscale,
/// 4:2:0 conversion and quantization soften; a mild 3x3 unsharp restores edge
/// contrast. `strength` is the percentage of the high-pass added back.
pub fn sharpen_nv12_luma(y: &mut [u8], width: u32, height: u32, strength: u32) {
    let (w, h) = (width as usize, height as usize);
    if strength == 0 || w < 3 || h < 3 || y.len() < w * h {
        return;
    }
    let mut blur = vec![0u8; w * h];
    for row in 0..h {
        let row0 = row.saturating_sub(1) * w;
        let row1 = row * w;
        let row2 = (row + 1).min(h - 1) * w;
        for col in 0..w {
            let c0 = col.saturating_sub(1);
            let c2 = (col + 1).min(w - 1);
            let sum = u32::from(y[row0 + c0])
                + u32::from(y[row0 + col])
                + u32::from(y[row0 + c2])
                + u32::from(y[row1 + c0])
                + u32::from(y[row1 + col])
                + u32::from(y[row1 + c2])
                + u32::from(y[row2 + c0])
                + u32::from(y[row2 + col])
                + u32::from(y[row2 + c2]);
            blur[row1 + col] = (sum / 9) as u8;
        }
    }
    for index in 0..w * h {
        let original = i32::from(y[index]);
        let diff = original - i32::from(blur[index]);
        y[index] = (original + diff * strength as i32 / 100).clamp(0, 255) as u8;
    }
}
/// Cheap blank-frame check: samples every 4096th pixel (used to drop the
/// driver's blank first frame after a duplication session starts).
pub fn bgra_looks_blank(bgra: &[u8]) -> bool {
    bgra.chunks_exact(4).step_by(4096).all(|px| px[0] < 8 && px[1] < 8 && px[2] < 8)
}

/// Cheap blank check for an NV12 frame (samples the Y plane).
pub fn nv12_looks_blank(nv12: &[u8], width: u32, height: u32) -> bool {
    let y_size = (width * height) as usize;
    if nv12.len() < y_size {
        return false;
    }
    // BT.601 limited range: black is Y=16 (not 0). Dark UI content sits
    // above ~20, so this still distinguishes "blank" from "dark screen".
    nv12[..y_size].chunks(4096).all(|chunk| chunk[0] < 20)
}

/// Scales (w, h) down so it fits into (max_w, max_h), preserving the aspect
/// ratio, with even dimensions (NV12/I420 require them).
pub fn scale_to_fit(w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32) {
    if w <= max_w && h <= max_h {
        return (w & !1, h & !1);
    }
    let scale = f64::min(max_w as f64 / w as f64, max_h as f64 / h as f64);
    let dw = ((w as f64 * scale).round() as u32).max(2) & !1;
    let dh = ((h as f64 * scale).round() as u32).max(2) & !1;
    (dw, dh)
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
    fn sharpen_boosts_edges_and_leaves_flat_areas_alone() {
        let (w, h) = (8u32, 8u32);
        // A flat image has no high-pass content: it must be unchanged.
        let flat = vec![90u8; (w * h) as usize];
        let mut sharpened_flat = flat.clone();
        sharpen_nv12_luma(&mut sharpened_flat, w, h, 50);
        assert_eq!(sharpened_flat, flat);

        // A lone bright pixel is pure high frequency: it must get brighter.
        let mut bump = vec![100u8; (w * h) as usize];
        bump[3 * 8 + 3] = 140;
        let mut sharpened = bump.clone();
        sharpen_nv12_luma(&mut sharpened, w, h, 50);
        assert!(sharpened[3 * 8 + 3] > bump[3 * 8 + 3], "edge pixel is boosted");

        // Neutral operations.
        let mut untouched = bump.clone();
        sharpen_nv12_luma(&mut untouched, w, h, 0);
        assert_eq!(untouched, bump);
        let mut tiny = vec![10u8, 20, 30, 40];
        sharpen_nv12_luma(&mut tiny, 2, 2, 100);
        assert_eq!(tiny, vec![10, 20, 30, 40], "images smaller than 3x3 are a no-op");
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
