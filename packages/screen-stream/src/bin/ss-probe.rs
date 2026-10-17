//! ss-probe: enumerate display outputs and run a Desktop Duplication session,
//! reporting frame / idle / dirty-rect statistics once per second.
//! With --encode: full chain capture -> VFR gate -> BGRA->I420 -> H.264 (MF),
//! optionally dumping the Annex-B bitstream to a file.
//!
//! Usage:
//!   ss-probe [--list] [--vfr] [--encode [--dump FILE]] [--bitrate BPS]
//!            [--output <index|name-substr>] [--seconds N] [--timeout-ms N]

use std::time::{Duration, Instant};

fn main() {
    #[cfg(not(windows))]
    {
        let _ = (Duration::from_secs(1), Instant::now());
        eprintln!("ss-probe: Windows-only tool (capture layer is Windows for now)");
        std::process::exit(2);
    }

    #[cfg(windows)]
    {
        if let Err(e) = run() {
            eprintln!("ss-probe: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    use screen_stream::types::Acquire;
    use screen_stream::vfr::{EncodeDecision, VfrConfig, VfrGate};
    use screen_stream::{enumerate_outputs, Duplicator};

    fn next_value(args: &[String], i: &mut usize, name: &str) -> anyhow::Result<String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing value for {name}"))
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut list_only = false;
    let mut vfr_enabled = false;
    let mut encode_enabled = false;
    let mut dump_path: Option<String> = None;
    let mut bitrate_bps = 8_000_000u32;
    let mut want_output: Option<String> = None;
    let mut seconds = 10u64;
    let mut timeout_ms = 500u32;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--list" => list_only = true,
            "--vfr" => vfr_enabled = true,
            "--encode" => encode_enabled = true,
            "--dump" => dump_path = Some(next_value(&args, &mut i, "--dump")?),
            "--bitrate" => {
                let raw = next_value(&args, &mut i, "--bitrate")?;
                bitrate_bps = raw
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --bitrate value {raw:?}"))?;
            }
            "--output" => want_output = Some(next_value(&args, &mut i, "--output")?),
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --seconds value {raw:?}"))?;
            }
            "--timeout-ms" => {
                let raw = next_value(&args, &mut i, "--timeout-ms")?;
                timeout_ms = raw
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --timeout-ms value {raw:?}"))?;
            }
            other => anyhow::bail!("unknown argument {other:?} (usage: ss-probe [--list] [--vfr] [--encode [--dump FILE]] [--bitrate BPS] [--output <index|name>] [--seconds N] [--timeout-ms N])"),
        }
        i += 1;
    }
    if encode_enabled {
        vfr_enabled = true;
    }

    let outputs = enumerate_outputs()?;
    if outputs.is_empty() {
        anyhow::bail!("no display outputs found");
    }

    println!("outputs ({}):", outputs.len());
    for o in &outputs {
        println!(
            "  [{}] {} {} {}x{} at ({},{}) rotation={} attached={}",
            o.index,
            o.device_name,
            o.adapter_name,
            o.desktop_rect.width(),
            o.desktop_rect.height(),
            o.desktop_rect.left,
            o.desktop_rect.top,
            screen_stream::windows_capture::rotation_name(o.rotation),
            o.attached
        );
    }

    if list_only {
        return Ok(());
    }

    let target = match &want_output {
        Some(spec) => {
            if let Ok(idx) = spec.parse::<usize>() {
                outputs
                    .iter()
                    .find(|o| o.index == idx)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("output index {idx} not found"))?
            } else {
                outputs
                    .iter()
                    .find(|o| o.device_name.to_ascii_lowercase().contains(&spec.to_ascii_lowercase()))
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("no output name matches {spec:?}"))?
            }
        }
        None => outputs
            .iter()
            .filter(|o| o.attached)
            .min_by_key(|o| o.desktop_rect.area())
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no attached output to auto-pick"))?,
    };

    println!();
    println!(
        "capturing output [{}] {} {}x{} for {seconds}s (auto-pick = smallest attached output; override with --output)",
        target.index,
        target.device_name,
        target.desktop_rect.width(),
        target.desktop_rect.height()
    );

    let mut dup = Duplicator::new(target.index)?;
    let area = target.desktop_rect.area().max(1);

    if encode_enabled && screen_stream::windows_capture::rotation_name(target.rotation) != "identity" {
        anyhow::bail!(
            "--encode requires an unrotated output; this output reports rotation={}",
            screen_stream::windows_capture::rotation_name(target.rotation)
        );
    }

    let mut gate = if vfr_enabled {
        Some(VfrGate::new(VfrConfig::default()))
    } else {
        None
    };

    let mut encoder = if encode_enabled {
        let config = screen_stream::EncoderConfig {
            width: target.desktop_rect.width() as u32,
            height: target.desktop_rect.height() as u32,
            bitrate_bps,
            fps: 60,
        };
        let encoder = screen_stream::create_best_encoder(&config)?;
        println!(
            "encoder selected: {} (input {}, bitrate {} kbit/s, keyframe-force supported: {})",
            encoder.name(),
            encoder.input_format().name(),
            bitrate_bps / 1000,
            encoder.keyframe_force_supported()
        );
        Some(encoder)
    } else {
        None
    };
    let mut dump_file = match &dump_path {
        Some(path) => {
            println!("dumping Annex-B bitstream to {path}");
            Some(std::fs::File::create(path)?)
        }
        None => None,
    };
    if let Some(header) = encoder.as_mut().and_then(|e| e.take_sequence_header()) {
        println!("encoder sequence header: {} bytes (prepended to dump)", header.len());
        if let Some(file) = dump_file.as_mut() {
            use std::io::Write;
            file.write_all(&header)?;
        }
    }

    #[derive(Default)]
    struct Counters {
        frames: u64,
        idle: u64,
        dirty_rects: u64,
        dirty_area: i64,
        moved: u64,
        pointer: u64,
        present_zero: u64,
        vfr_enc: u64,
        vfr_kf: u64,
        enc_frames: u64,
        enc_ms_sum: f64,
        enc_bytes: u64,
        enc_kf: u64,
    }

    impl Counters {
        fn record(&mut self, meta: &screen_stream::types::FrameMeta) {
            self.frames += 1;
            self.dirty_rects += meta.dirty.len() as u64;
            self.dirty_area += meta.dirty.iter().map(|r| r.area()).sum::<i64>();
            self.moved += meta.moved.len() as u64;
            if meta.pointer_shape_updated {
                self.pointer += 1;
            }
            if meta.last_present_time == 0 {
                self.present_zero += 1;
            }
        }

        fn reset(&mut self) {
            *self = Self::default();
        }
    }

    let mut win = Counters::default();
    let mut tot = Counters::default();
    let mut i420: Vec<u8> = Vec::new();
    let mut last_enc_time_100ns: i64 = -1;
    let mut last_rebuild_count = dup.rebuild_count();

    let started = Instant::now();
    let mut window_start = Instant::now();

    while started.elapsed() < Duration::from_secs(seconds) {
        if encode_enabled {
            match dup.acquire_full(timeout_ms)? {
                None => {
                    win.idle += 1;
                    tot.idle += 1;
                    if let Some(gate) = gate.as_mut() {
                        let _ = gate.decide(&screen_stream::types::FrameMeta::default(), Instant::now());
                    }
                }
                Some((meta, pixels)) => {
                    win.record(&meta);
                    tot.record(&meta);

                    let rebuild_changed = dup.rebuild_count() != last_rebuild_count;
                    last_rebuild_count = dup.rebuild_count();

                    let decision = gate
                        .as_mut()
                        .map(|gate| gate.decide(&meta, Instant::now()))
                        .unwrap_or(EncodeDecision::Skip);
                    if let EncodeDecision::Encode { keyframe } = decision {
                        win.vfr_enc += 1;
                        tot.vfr_enc += 1;
                        if keyframe {
                            win.vfr_kf += 1;
                            tot.vfr_kf += 1;
                        }

                        let t0 = Instant::now();
                        {
                            use screen_stream::windows_encoder::InputPixelFormat;
                            let encoder = encoder.as_mut().ok_or_else(|| anyhow::anyhow!("encoder missing"))?;
                            match encoder.input_format() {
                                InputPixelFormat::Nv12 => {
                                    screen_stream::convert::bgra_to_nv12(&pixels.bgra, pixels.width, pixels.height, &mut i420);
                                }
                                InputPixelFormat::I420 => {
                                    screen_stream::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420);
                                }
                                InputPixelFormat::Yv12 => {
                                    screen_stream::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420);
                                    screen_stream::convert::i420_to_yv12_in_place(&mut i420, pixels.width, pixels.height);
                                }
                            }
                        }
                        let t100 = started.elapsed().as_nanos() as i64 / 100;
                        let delta = if last_enc_time_100ns >= 0 {
                            t100 - last_enc_time_100ns
                        } else {
                            10_000_000 / 60
                        };
                        let duration_100ns = delta.clamp(10_000, 5_000_000);
                        let discontinuity = rebuild_changed || delta > 2_000_000;

                        let encoder = encoder.as_mut().ok_or_else(|| anyhow::anyhow!("encoder missing"))?;
                        let outputs = encoder.encode(&i420, t100, duration_100ns, discontinuity, keyframe)?;
                        let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
                        let keyframe_confirmed = keyframe && encoder.keyframe_force_supported();

                        if let Some(header) = encoder.take_sequence_header() {
                            if let Some(file) = dump_file.as_mut() {
                                use std::io::Write;
                                file.write_all(&header)?;
                            }
                        }

                        win.enc_frames += 1;
                        win.enc_ms_sum += elapsed_ms;
                        tot.enc_frames += 1;
                        tot.enc_ms_sum += elapsed_ms;
                        if keyframe_confirmed {
                            win.enc_kf += 1;
                            tot.enc_kf += 1;
                        }
                        for chunk in &outputs {
                            win.enc_bytes += chunk.len() as u64;
                            tot.enc_bytes += chunk.len() as u64;
                            if let Some(file) = dump_file.as_mut() {
                                use std::io::Write;
                                file.write_all(chunk)?;
                            }
                        }
                        last_enc_time_100ns = t100;
                    }
                    dup.recycle_pixels(pixels);
                }
            }
        } else {
            match dup.acquire(timeout_ms)? {
                Acquire::Idle => {
                    win.idle += 1;
                    tot.idle += 1;
                    if let Some(gate) = gate.as_mut() {
                        let _ = gate.decide(&screen_stream::types::FrameMeta::default(), Instant::now());
                    }
                }
                Acquire::Frame(meta) => {
                    win.record(&meta);
                    tot.record(&meta);
                    if let Some(gate) = gate.as_mut() {
                        if let EncodeDecision::Encode { keyframe } = gate.decide(&meta, Instant::now()) {
                            win.vfr_enc += 1;
                            tot.vfr_enc += 1;
                            if keyframe {
                                win.vfr_kf += 1;
                                tot.vfr_kf += 1;
                            }
                        }
                    }
                }
            }
        }

        if window_start.elapsed() >= Duration::from_secs(1) {
            let dirty_pct = (win.dirty_area as f64) / (area as f64) * 100.0;
            let vfr_part = if gate.is_some() {
                format!(" vfr_enc={:<4} kf={}", win.vfr_enc, win.vfr_kf)
            } else {
                String::new()
            };
            let enc_part = if encoder.is_some() && win.enc_frames > 0 {
                let avg_ms = win.enc_ms_sum / win.enc_frames as f64;
                let kbps = (win.enc_bytes * 8) / 1000;
                format!(" enc={} avg_ms={avg_ms:.1} kbps={kbps} enc_kf={}", win.enc_frames, win.enc_kf)
            } else if encoder.is_some() {
                " enc=0".to_string()
            } else {
                String::new()
            };
            println!(
                "t={:>3}s frames={:<4} idle={:<4} dirty={:<4}({:>5.1}% area) moved={:<3} pointer_upd={:<3} zero_present={}{vfr_part}{enc_part}",
                started.elapsed().as_secs(),
                win.frames,
                win.idle,
                win.dirty_rects,
                dirty_pct,
                win.moved,
                win.pointer,
                win.present_zero
            );
            window_start = Instant::now();
            win.reset();
        }
    }

    if let Some(encoder) = encoder.as_mut() {
        let tail = encoder.shutdown().unwrap_or_default();
        for chunk in &tail {
            tot.enc_bytes += chunk.len() as u64;
            if let Some(file) = dump_file.as_mut() {
                use std::io::Write;
                file.write_all(chunk)?;
            }
        }
    }

    let total = tot.frames + tot.idle;
    println!();
    println!(
        "summary: {total} acquire iterations, frames={} idle={} ({:.1}% idle), access_lost_rebuilds={}",
        tot.frames,
        tot.idle,
        if total == 0 { 0.0 } else { (tot.idle as f64) / (total as f64) * 100.0 },
        dup.rebuild_count()
    );
    if let Some(gate) = gate.as_ref() {
        let stats = gate.stats();
        println!(
            "vfr summary: encoded={} keyframes={} skipped={} (static={}, rate_limited={})",
            stats.encoded, stats.keyframes, stats.skipped, stats.skipped_static, stats.skipped_rate_limited
        );
    }
    if let Some(encoder) = encoder.as_ref() {
        let avg_ms = if tot.enc_frames == 0 {
            0.0
        } else {
            tot.enc_ms_sum / tot.enc_frames as f64
        };
        println!(
            "encode summary: encoder={} frames={} keyframes={} avg_encode_ms={avg_ms:.2} total_out={:.2} MiB",
            encoder.name(),
            tot.enc_frames,
            tot.enc_kf,
            tot.enc_bytes as f64 / 1048576.0
        );
    }
    Ok(())
}
