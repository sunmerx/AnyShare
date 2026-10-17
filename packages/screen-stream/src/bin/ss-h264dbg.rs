//! ss-h264dbg: parse an Annex-B H.264 file with the same parser the VAAPI
//! decoder uses and print per-slice header fields (debug tool, Linux-only).

fn main() {
    #[cfg(all(target_os = "linux", feature = "viewer"))]
    {
        if let Err(e) = run() {
            eprintln!("ss-h264dbg: {e:#}");
            std::process::exit(1);
        }
    }
    #[cfg(not(all(target_os = "linux", feature = "viewer")))]
    {
        eprintln!("ss-h264dbg: Linux + viewer feature only");
        std::process::exit(2);
    }
}

#[cfg(all(target_os = "linux", feature = "viewer"))]
fn run() -> anyhow::Result<()> {
    use screen_stream::vaapi::h264::{nal_type, parse_pps, parse_slice_header, parse_sps, split_nals};

    let path = std::env::args().nth(1).expect("usage: ss-h264dbg <file.h264> [max_slices]");
    let max_slices: usize = std::env::args().nth(2).and_then(|s| s.parse().ok()).unwrap_or(40);
    let data = std::fs::read(&path)?;
    println!("file {path}: {} bytes", data.len());

    let mut sps = None;
    let mut pps = None;
    let mut slices = 0usize;
    let mut sps_count = 0usize;
    let mut pps_count = 0usize;

    for nal in split_nals(&data) {
        match nal_type(nal) {
            7 => {
                sps_count += 1;
                match parse_sps(nal) {
                    Ok(parsed) => {
                        println!(
                            "SPS #{sps_count}: {}x{} profile={} poc_type={} log2_frame_num={} log2_poc={} refs={}",
                            parsed.width,
                            parsed.height,
                            parsed.profile_idc,
                            parsed.pic_order_cnt_type,
                            parsed.log2_max_frame_num(),
                            parsed.log2_max_poc_lsb(),
                            parsed.max_num_ref_frames
                        );
                        sps = Some(parsed);
                    }
                    Err(e) => println!("SPS #{sps_count}: PARSE ERR {e:#}"),
                }
            }
            8 => {
                pps_count += 1;
                match parse_pps(nal) {
                    Ok(parsed) => {
                        println!(
                            "PPS #{pps_count}: entropy={} bottom_poc_present={} deblock_present={} weighted_pred={}",
                            parsed.entropy_coding_mode,
                            parsed.bottom_field_pic_order_in_frame_present,
                            parsed.deblocking_filter_control_present,
                            parsed.weighted_pred
                        );
                        pps = Some(parsed);
                    }
                    Err(e) => println!("PPS #{pps_count}: PARSE ERR {e:#}"),
                }
            }
            1 | 5 => {
                slices += 1;
                if slices > max_slices {
                    continue;
                }
                let (Some(sps), Some(pps)) = (&sps, &pps) else {
                    println!("slice #{slices}: no SPS/PPS yet");
                    continue;
                };
                match parse_slice_header(nal, sps, pps) {
                    Ok(h) => {
                        let head: Vec<String> = nal.iter().take(12).map(|b| format!("{b:02x}")).collect();
                        println!(
                            "slice #{slices}: nal_type={} ref_idc={} type={} first_mb={} frame_num={} poc_lsb={} override_refs(l0)={} bit_offset={} len={} | {}",
                            nal_type(nal),
                            h.nal_ref_idc,
                            h.slice_type,
                            h.first_mb_in_slice,
                            h.frame_num,
                            h.poc_lsb,
                            h.num_ref_idx_l0_active_minus1,
                            h.bit_offset,
                            nal.len(),
                            head.join(" ")
                        );
                    }
                    Err(e) => {
                        let head: Vec<String> = nal.iter().take(24).map(|b| format!("{b:02x}")).collect();
                        println!("slice #{slices}: PARSE ERR {e:#} | head: {}", head.join(" "));
                    }
                }
            }
            _ => {}
        }
    }
    println!("done: {sps_count} SPS, {pps_count} PPS, {slices} slices");
    Ok(())
}
