//! ss-vaapidebug: offline VaapiDecoder harness for acceptance debugging.
//! Feeds an Annex-B H.264 file (SPS/PPS + one slice per frame, as produced by
//! our sender) and dumps a decoded frame as PPM.

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ss-vaapidebug: Linux-only tool");
}

#[cfg(target_os = "linux")]
fn main() {
    use anyhow::{Context, Result};
    use screen_stream::vaapi::VaapiDecoder;
    use std::io::Write;

    fn run() -> Result<()> {
        let path = std::env::args().nth(1).context("usage: ss-vaapidebug <file.h264> <out.ppm> [max_frames]")?;
        let out_path = std::env::args().nth(2).context("usage: ss-vaapidebug <file.h264> <out.ppm> [max_frames]")?;
        let max_frames: usize = std::env::args().nth(3).and_then(|s| s.parse().ok()).unwrap_or(30);
        let data = std::fs::read(&path)?;

        // Split Annex-B NALs and group them into access units: a new AU starts
        // when a VCL NAL appears after another VCL NAL or after a non-VCL run.
        let mut nals: Vec<&[u8]> = Vec::new();
        let mut i = 0;
        while i + 3 < data.len() {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                let start = i + 3;
                let mut end = start;
                while end + 2 < data.len() && !(data[end] == 0 && data[end + 1] == 0 && data[end + 2] == 1) {
                    end += 1;
                }
                let end = if end + 2 >= data.len() { data.len() } else { end };
                if end > start {
                    nals.push(&data[start..end]);
                }
                i = end;
            } else {
                i += 1;
            }
        }

        let mut aus: Vec<Vec<u8>> = Vec::new();
        let mut current: Vec<u8> = Vec::new();
        let mut has_vcl = false;
        for nal in nals {
            let nal_type = nal[0] & 0x1F;
            let is_vcl = nal_type == 1 || nal_type == 5;
            if is_vcl && has_vcl {
                aus.push(std::mem::take(&mut current));
                has_vcl = false;
            }
            current.extend_from_slice(&[0, 0, 0, 1]);
            current.extend_from_slice(nal);
            if is_vcl {
                has_vcl = true;
            }
        }
        if !current.is_empty() {
            aus.push(current);
        }
        println!("access units: {}", aus.len());

        let mut decoder = VaapiDecoder::new("/dev/dri/renderD128")?;
        let mut decoded = 0usize;
        let mut dumped = false;
        for (idx, au) in aus.iter().enumerate().take(max_frames) {
            match decoder.decode(au) {
                Ok(Some((width, height, argb))) => {
                    decoded += 1;
                    if !dumped || idx + 1 == max_frames.min(aus.len()) {
                        let mut colors = std::collections::HashMap::new();
                        for y in (0..height as usize).step_by((height as usize / 40).max(1)) {
                            for x in (0..width as usize).step_by((width as usize / 60).max(1)) {
                                let px = argb[y * width as usize + x];
                                *colors.entry(px & 0xFFFFFF).or_insert(0usize) += 1;
                            }
                        }
                        let mut top: Vec<_> = colors.iter().collect();
                        top.sort_by(|a, b| b.1.cmp(a.1));
                        println!(
                            "frame {}: {}x{} distinct={} top={:?}",
                            idx,
                            width,
                            height,
                            colors.len(),
                            top.iter().take(5).map(|(c, n)| (format!("{c:06X}"), **n)).collect::<Vec<_>>()
                        );
                        let mut file = std::fs::File::create(&out_path)?;
                        write!(file, "P6\n{} {}\n255\n", width, height)?;
                        let mut bytes = Vec::with_capacity(argb.len() * 3);
                        for px in &argb {
                            bytes.push((px >> 16) as u8);
                            bytes.push((px >> 8) as u8);
                            bytes.push(*px as u8);
                        }
                        file.write_all(&bytes)?;
                        dumped = true;
                    }
                }
                Ok(None) => {}
                Err(e) => eprintln!("frame {idx}: decode error: {e:#}"),
            }
        }
        println!("decoded {decoded} frames");
        Ok(())
    }

    if let Err(e) = run() {
        eprintln!("ss-vaapidebug: {e:#}");
        std::process::exit(1);
    }
}
