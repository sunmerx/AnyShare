//! ss-send: capture -> VFR gate -> H.264 encode -> packetize + FEC -> UDP.
//! Windows-only (capture/encode layers are Windows for now).
//! Usage: ss-send [--output <index|name>] [--target IP:PORT] [--bitrate BPS]
//!                [--seconds N] [--timeout-ms N]

fn main() {
    #[cfg(not(windows))]
    {
        eprintln!("ss-send: Windows-only tool (capture/encode layers are Windows for now)");
        std::process::exit(2);
    }

    #[cfg(windows)]
    {
        if let Err(e) = run() {
            eprintln!("ss-send: {e:#}");
            std::process::exit(1);
        }
    }
}

#[cfg(windows)]
fn run() -> anyhow::Result<()> {
    use std::net::UdpSocket;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    use screen_stream::transport::{packetize, FLAG_DISCONTINUITY, FLAG_HEADER, FLAG_KEYFRAME};
    use screen_stream::types::{Acquire, FrameMeta};
    use screen_stream::vfr::{EncodeDecision, VfrConfig, VfrGate};
    use screen_stream::{enumerate_outputs, Duplicator};

    fn next_value(args: &[String], i: &mut usize, name: &str) -> anyhow::Result<String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing value for {name}"))
    }

    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let mut want_output: Option<String> = None;
    let mut target = "127.0.0.1:53320".to_string();
    let mut bitrate_bps = 8_000_000u32;
    let mut seconds = 30u64;
    let mut timeout_ms = 500u32;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--output" => want_output = Some(next_value(&args, &mut i, "--output")?),
            "--target" => target = next_value(&args, &mut i, "--target")?,
            "--bitrate" => {
                let raw = next_value(&args, &mut i, "--bitrate")?;
                bitrate_bps = raw.parse().map_err(|_| anyhow::anyhow!("invalid --bitrate {raw:?}"))?;
            }
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw.parse().map_err(|_| anyhow::anyhow!("invalid --seconds {raw:?}"))?;
            }
            "--timeout-ms" => {
                let raw = next_value(&args, &mut i, "--timeout-ms")?;
                timeout_ms = raw.parse().map_err(|_| anyhow::anyhow!("invalid --timeout-ms {raw:?}"))?;
            }
            other => anyhow::bail!(
                "unknown argument {other:?} (usage: ss-send [--output <index|name>] [--target IP:PORT] [--bitrate BPS] [--seconds N] [--timeout-ms N])"
            ),
        }
        i += 1;
    }

    let outputs = enumerate_outputs()?;
    let targets: Vec<_> = outputs.iter().filter(|o| o.attached).cloned().collect();
    let target_output = match &want_output {
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
        None => targets
            .iter()
            .min_by_key(|o| o.desktop_rect.area())
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("no attached output to auto-pick"))?,
    };

    if screen_stream::windows_capture::rotation_name(target_output.rotation) != "identity" {
        anyhow::bail!("capturing rotated outputs is not supported yet");
    }

    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.connect(&target)?;

    let session = (SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() & 0xFFFF_FFFF) as u32 | 1;

    let config = screen_stream::EncoderConfig {
        width: target_output.desktop_rect.width() as u32,
        height: target_output.desktop_rect.height() as u32,
        bitrate_bps,
        fps: 60,
    };
    let mut encoder = screen_stream::create_best_encoder(&config)?;
    println!(
        "encoder: {} (input {}, session {session:#010x}), target {target}",
        encoder.name(),
        encoder.input_format().name()
    );

    let mut dup = Duplicator::new(target_output.index)?;
    let mut gate = VfrGate::new(VfrConfig::default());
    let mut i420: Vec<u8> = Vec::new();

    let mut frame_id: u32 = 1;
    let mut packets_sent: u64 = 0;
    let mut bytes_sent: u64 = 0;
    let mut frames_sent: u64 = 0;
    let mut keyframes_sent: u64 = 0;
    let mut last_enc_time_100ns: i64 = -1;
    let mut last_rebuild_count = dup.rebuild_count();
    let mut last_send_time_100ns: i64 = -1;

    if let Some(header) = encoder.take_sequence_header() {
        let packets = packetize(session, 0, FLAG_HEADER, 0, &header);
        for packet in &packets {
            socket.send(&packet.encode())?;
            packets_sent += 1;
            bytes_sent += packet.payload.len() as u64;
        }
        println!("sequence header sent: {} bytes", header.len());
    }

    let started = Instant::now();
    let mut last_stats = Instant::now();
    let mut window_packets: u64 = 0;
    let mut window_bytes: u64 = 0;

    while started.elapsed() < Duration::from_secs(seconds) {
        match dup.acquire_full(timeout_ms)? {
            None => {
                let _ = gate.decide(&FrameMeta::default(), Instant::now());
            }
            Some((meta, pixels)) => {
                let rebuild_changed = dup.rebuild_count() != last_rebuild_count;
                last_rebuild_count = dup.rebuild_count();

                if let EncodeDecision::Encode { keyframe } = gate.decide(&meta, Instant::now()) {
                    {
                        use screen_stream::windows_encoder::InputPixelFormat;
                        match encoder.input_format() {
                            InputPixelFormat::Nv12 => {
                                screen_stream::convert::bgra_to_nv12(&pixels.bgra, pixels.width, pixels.height, &mut i420)
                            }
                            InputPixelFormat::I420 => {
                                screen_stream::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420)
                            }
                            InputPixelFormat::Yv12 => {
                                screen_stream::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420);
                                screen_stream::convert::i420_to_yv12_in_place(&mut i420, pixels.width, pixels.height);
                            }
                        }
                    }

                    let t100 = started.elapsed().as_nanos() as i64 / 100;
                    let delta = if last_enc_time_100ns >= 0 { t100 - last_enc_time_100ns } else { 10_000_000 / 60 };
                    let duration = delta.clamp(10_000, 5_000_000);
                    let discontinuity = rebuild_changed || delta > 2_000_000;

                    if let Some(header) = encoder.take_sequence_header() {
                        let packets = packetize(session, frame_id, FLAG_HEADER, t100 as u64, &header);
                        for packet in &packets {
                            socket.send(&packet.encode())?;
                            packets_sent += 1;
                            bytes_sent += packet.payload.len() as u64;
                            window_bytes += packet.payload.len() as u64;
                        }
                        frame_id = frame_id.wrapping_add(1);
                    }

                    let outputs = encoder.encode(&i420, t100, duration, discontinuity, keyframe)?;
                    let mut flags = 0u8;
                    if keyframe {
                        flags |= FLAG_KEYFRAME;
                    }
                    if discontinuity {
                        flags |= FLAG_DISCONTINUITY;
                    }
                    let had_output = !outputs.is_empty();
                    for chunk in &outputs {
                        let packets = packetize(session, frame_id, flags, t100 as u64, chunk);
                        for packet in &packets {
                            socket.send(&packet.encode())?;
                            packets_sent += 1;
                            window_packets += 1;
                            bytes_sent += packet.payload.len() as u64;
                            window_bytes += packet.payload.len() as u64;
                        }
                        frame_id = frame_id.wrapping_add(1);
                        frames_sent += 1;
                    }
                    if keyframe && had_output {
                        keyframes_sent += 1;
                    }
                    last_enc_time_100ns = t100;
                    last_send_time_100ns = t100;
                }
                dup.recycle_pixels(pixels);
            }
        }

        if last_stats.elapsed() >= Duration::from_secs(1) {
            let mbps = window_bytes as f64 * 8.0 / 1_000_000.0;
            println!(
                "t={:>3}s frames={frames_sent} kf={keyframes_sent} packets={window_packets} {mbps:.2} Mbps",
                started.elapsed().as_secs()
            );
            window_packets = 0;
            window_bytes = 0;
            last_stats = Instant::now();
        }
    }

    for chunk in encoder.shutdown()? {
        let packets = packetize(session, frame_id, 0, last_send_time_100ns.max(0) as u64, &chunk);
        for packet in &packets {
            socket.send(&packet.encode())?;
            packets_sent += 1;
            bytes_sent += packet.payload.len() as u64;
        }
        frame_id = frame_id.wrapping_add(1);
    }

    println!(
        "summary: frames={frames_sent} keyframes={keyframes_sent} packets={packets_sent} sent={:.2} MiB in {}s",
        bytes_sent as f64 / 1048576.0,
        started.elapsed().as_secs()
    );
    let _ = Acquire::Idle;
    Ok(())
}
