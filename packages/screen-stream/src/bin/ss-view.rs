//! ss-view: native receiver — UDP -> reassembly -> OpenH264 decode -> minifb window.
//! No external players involved: the whole receiver path is our code.
//!
//! Usage: ss-view [--port N] [--seconds N] [--scale N]
//! Build: cargo build --release --features viewer --bin ss-view

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use minifb::{Key, Scale, Window, WindowOptions};
use openh264::decoder::Decoder;
use openh264::formats::YUVSource;

use screen_stream::transport::{Delivered, Packet, Reassembler, FLAG_HEADER, FLAG_KEYFRAME};

struct Frame {
    width: usize,
    height: usize,
    argb: Vec<u32>,
}

struct Shared {
    generation: AtomicU64,
    frame: Mutex<Option<Arc<Frame>>>,
}

fn publish(shared: &Shared, frame: Frame) {
    *shared.frame.lock().unwrap() = Some(Arc::new(frame));
    shared.generation.fetch_add(1, Ordering::AcqRel);
}

fn main() {
    if let Err(e) = run() {
        eprintln!("ss-view: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    fn next_value(args: &[String], i: &mut usize, name: &str) -> Result<String> {
        *i += 1;
        args.get(*i)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("missing value for {name}"))
    }

    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    let mut port: u16 = 53320;
    let mut seconds: u64 = 0;
    let mut scale: f32 = 1.0;
    let mut verbose = false;
    let mut decoder_kind = "ffmpeg".to_string();
    let mut ffmpeg_path = "ffmpeg".to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--port" => {
                let raw = next_value(&args, &mut i, "--port")?;
                port = raw.parse().map_err(|_| anyhow::anyhow!("invalid --port {raw:?}"))?;
            }
            "--seconds" => {
                let raw = next_value(&args, &mut i, "--seconds")?;
                seconds = raw.parse().map_err(|_| anyhow::anyhow!("invalid --seconds {raw:?}"))?;
            }
            "--scale" => {
                let raw = next_value(&args, &mut i, "--scale")?;
                scale = raw.parse().map_err(|_| anyhow::anyhow!("invalid --scale {raw:?}"))?;
            }
            "--decoder" => decoder_kind = next_value(&args, &mut i, "--decoder")?,
            "--ffmpeg-path" => ffmpeg_path = next_value(&args, &mut i, "--ffmpeg-path")?,
            "--verbose" => verbose = true,
            other => anyhow::bail!(
                "unknown argument {other:?} (usage: ss-view [--port N] [--seconds N] [--scale N] [--decoder ffmpeg|openh264] [--ffmpeg-path PATH] [--verbose])"
            ),
        }
        i += 1;
    }
    if decoder_kind != "ffmpeg" && decoder_kind != "openh264" {
        anyhow::bail!("unknown decoder {decoder_kind:?} (expected ffmpeg or openh264)");
    }

    let shared = Arc::new(Shared {
        generation: AtomicU64::new(0),
        frame: Mutex::new(None),
    });

    {
        let shared = Arc::clone(&shared);
        let decoder_kind = decoder_kind.clone();
        std::thread::spawn(move || {
            if let Err(e) = media_loop(shared, port, verbose, &decoder_kind, &ffmpeg_path) {
                eprintln!("ss-view media thread: {e:#}");
            }
        });
    }

    let mut window = Window::new(
        "AnyShare Viewer",
        1280,
        720,
        WindowOptions {
            resize: true,
            scale: Scale::X1,
            ..WindowOptions::default()
        },
    )?;
    if (scale - 1.0).abs() > f32::EPSILON {
        window.set_target_fps(0);
    }

    let started = Instant::now();
    let mut last_generation = 0u64;
    let blank = vec![0u32; 1280 * 720];
    let mut display_frames = 0u64;
    let mut last_stats = Instant::now();
    let mut scaled_buffer: Vec<u32> = Vec::new();

    while window.is_open() && !window.is_key_down(Key::Escape) {
        if seconds > 0 && started.elapsed() >= Duration::from_secs(seconds) {
            break;
        }

        let frame = shared.frame.lock().unwrap().clone();
        let generation = shared.generation.load(Ordering::Acquire);
        let result = match &frame {
            Some(frame) if (scale - 1.0).abs() <= f32::EPSILON => {
                window.update_with_buffer(&frame.argb, frame.width, frame.height)
            }
            Some(frame) => {
                let width = (frame.width as f32 * scale) as usize;
                let height = (frame.height as f32 * scale) as usize;
                scaled_buffer.clear();
                scaled_buffer.resize(width * height, 0);
                for y in 0..height {
                    let src_y = y * frame.height / height;
                    for x in 0..width {
                        let src_x = x * frame.width / width;
                        scaled_buffer[y * width + x] = frame.argb[src_y * frame.width + src_x];
                    }
                }
                window.update_with_buffer(&scaled_buffer, width, height)
            }
            None => window.update_with_buffer(&blank, 1280, 720),
        };
        if let Err(e) = result {
            eprintln!("ss-view: present failed: {e}");
        }
        if generation != last_generation && frame.is_some() {
            last_generation = generation;
            display_frames += 1;
        }

        if last_stats.elapsed() >= Duration::from_secs(1) {
            eprintln!("viewer: displayed={display_frames} ({} fps window)", display_frames);
            display_frames = 0;
            last_stats = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(16));
    }
    Ok(())
}

fn media_loop(shared: Arc<Shared>, port: u16, verbose: bool, decoder_kind: &str, ffmpeg_path: &str) -> Result<()> {
    let (tx, rx) = std::sync::mpsc::sync_channel::<Delivered>(128);

    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            if let Err(e) = receive_loop(tx, port, verbose) {
                eprintln!("ss-view receive thread: {e:#}");
            }
        });
    }

    if decoder_kind == "ffmpeg" {
        return ffmpeg_loop(shared, rx, verbose, ffmpeg_path);
    }
    openh264_loop(shared, rx, verbose)
}

fn ffmpeg_loop(
    shared: Arc<Shared>,
    rx: std::sync::mpsc::Receiver<Delivered>,
    verbose: bool,
    ffmpeg_path: &str,
) -> Result<()> {
    use std::io::Write;

    let mut child = std::process::Command::new(ffmpeg_path)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-fflags",
            "nobuffer",
            "-flags",
            "low_delay",
            "-f",
            "h264",
            "-i",
            "-",
            "-f",
            "mjpeg",
            "-q:v",
            "3",
            "-",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .map_err(|e| anyhow::anyhow!("spawning ffmpeg ({ffmpeg_path}) failed: {e}"))?;

    let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdin missing"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdout missing"))?;

    let reader_shared = Arc::clone(&shared);
    let reader = std::thread::spawn(move || {
        if let Err(e) = mjpeg_reader(stdout, reader_shared, verbose) {
            eprintln!("ss-view decoder thread: {e:#}");
        }
    });

    let mut pipe_error: Option<anyhow::Error> = None;
    loop {
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(frame) => {
                if let Err(e) = stdin.write_all(&frame.payload).and_then(|_| stdin.flush()) {
                    pipe_error = Some(anyhow::anyhow!("piping to ffmpeg failed: {e}"));
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if let Ok(Some(status)) = child.try_wait() {
                    pipe_error = Some(anyhow::anyhow!("ffmpeg exited early: {status}"));
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    let _ = child.kill();
    drop(stdin);
    let _ = child.wait();
    let _ = reader.join();
    match pipe_error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

fn mjpeg_reader(mut stdout: std::process::ChildStdout, shared: Arc<Shared>, _verbose: bool) -> Result<()> {
    use std::io::Read;

    let mut buffer: Vec<u8> = Vec::with_capacity(4 * 1024 * 1024);
    let mut chunk = vec![0u8; 256 * 1024];
    let mut frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut last_stats = Instant::now();

    loop {
        let read = stdout.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > 64 * 1024 * 1024 {
            eprintln!("ss-view: jpeg buffer exceeded 64 MiB, resetting");
            buffer.clear();
        }

        loop {
            let Some(start) = find_marker(&buffer, 0, &[0xFF, 0xD8]) else {
                if buffer.len() > 2 {
                    let keep = buffer.len() - 1;
                    buffer.drain(..keep);
                }
                break;
            };
            let Some(end) = find_marker(&buffer, start + 2, &[0xFF, 0xD9]) else {
                if start > 0 {
                    buffer.drain(..start);
                }
                break;
            };
            let jpeg = &buffer[start..end + 2];
            let t0 = Instant::now();
            match image::load_from_memory_with_format(jpeg, image::ImageFormat::Jpeg) {
                Ok(img) => {
                    let rgb = img.to_rgb8();
                    let (width, height) = (rgb.width() as usize, rgb.height() as usize);
                    let mut argb = Vec::with_capacity(width * height);
                    for pixel in rgb.pixels() {
                        argb.push((u32::from(pixel[0]) << 16) | (u32::from(pixel[1]) << 8) | u32::from(pixel[2]));
                    }
                    publish(
                        &shared,
                        Frame {
                            width,
                            height,
                            argb,
                        },
                    );
                    frames += 1;
                    decode_ms_sum += t0.elapsed().as_secs_f64() * 1000.0;
                }
                Err(e) => eprintln!("ss-view: jpeg decode failed: {e}"),
            }
            buffer.drain(..end + 2);
        }

        if last_stats.elapsed() >= Duration::from_secs(1) {
            let avg_ms = if frames == 0 { 0.0 } else { decode_ms_sum / frames as f64 };
            eprintln!("media: decoded={frames} avg_decode_ms={avg_ms:.1} (ffmpeg pipe)");
            frames = 0;
            decode_ms_sum = 0.0;
            last_stats = Instant::now();
        }
    }
    Ok(())
}

fn find_marker(buffer: &[u8], from: usize, marker: &[u8; 2]) -> Option<usize> {
    if buffer.len() < from + 2 {
        return None;
    }
    buffer[from..]
        .windows(2)
        .position(|w| w == marker)
        .map(|i| i + from)
}

fn openh264_loop(shared: Arc<Shared>, rx: std::sync::mpsc::Receiver<Delivered>, verbose: bool) -> Result<()> {

    let mut decoder = Decoder::new()?;
    let mut sequence_header: Option<Vec<u8>> = None;
    let mut decoder_dirty = false;
    let mut argb: Vec<u32> = Vec::new();
    let mut decoded_frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut decode_errors: u64 = 0;
    let mut last_stats = Instant::now();

    loop {
        let frame = match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(frame) => frame,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if last_stats.elapsed() >= Duration::from_secs(1) {
                    let avg_ms = if decoded_frames == 0 { 0.0 } else { decode_ms_sum / decoded_frames as f64 };
                    eprintln!("media: decoded={decoded_frames} avg_decode_ms={avg_ms:.1} errors={decode_errors}");
                    decoded_frames = 0;
                    decode_ms_sum = 0.0;
                    last_stats = Instant::now();
                }
                continue;
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };

        if frame.flags & FLAG_HEADER != 0 {
            sequence_header = Some(frame.payload.clone());
            if verbose {
                eprintln!("media: sequence header AU ({} bytes)", frame.payload.len());
            }
        }

        let has_idr = openh264::nal_units(&frame.payload).any(|nal| {
            nal.windows(3)
                .position(|w| w == [0, 0, 1])
                .and_then(|i| nal.get(i + 3))
                .map(|b| b & 0x1f == 5)
                .unwrap_or(false)
        });

        if decoder_dirty {
            if frame.flags & FLAG_KEYFRAME == 0 && !has_idr {
                continue;
            }
            decoder = Decoder::new()?;
            if let Some(header) = &sequence_header {
                for nal in openh264::nal_units(header) {
                    let _ = decoder.decode(nal);
                }
            }
            decoder_dirty = false;
            if verbose {
                eprintln!("media: decoder reset at sync point");
            }
        }

        let t0 = Instant::now();
        let mut decoded: Option<(usize, usize)> = None;
        let mut decode_attempts = 0u64;
        if let Some(header) = &sequence_header {
            for nal in openh264::nal_units(header) {
                let _ = decoder.decode(nal);
            }
        }
        for nal in openh264::nal_units(&frame.payload) {
            decode_attempts += 1;
            match decoder.decode(nal) {
                Ok(Some(yuv)) => {
                    let (width, height) = yuv.dimensions();
                    if verbose && decode_attempts <= 6 {
                        eprintln!("decode-detail: nal={}B -> {}x{}", nal.len(), width, height);
                    }
                    if width <= 8192 && height <= 8192 && width > 0 && height > 0 {
                        yuv_to_argb(&yuv, width, height, &mut argb);
                        decoded = Some((width, height));
                    }
                }
                Ok(None) => {
                    if verbose && decode_attempts <= 6 {
                        eprintln!("decode-detail: nal={}B -> None", nal.len());
                    }
                }
                Err(e) => {
                    decode_errors += 1;
                    decoder_dirty = true;
                    if decode_errors <= 10 || decode_errors.is_multiple_of(300) {
                        eprintln!("ss-view: decode error #{decode_errors} (awaiting sync): {e:?}");
                    }
                    break;
                }
            }
        }
        if let Some((width, height)) = decoded {
            publish(
                &shared,
                Frame {
                    width,
                    height,
                    argb: std::mem::take(&mut argb),
                },
            );
            decoded_frames += 1;
            decode_ms_sum += t0.elapsed().as_secs_f64() * 1000.0;
        }
    }
    Ok(())
}

fn receive_loop(tx: std::sync::mpsc::SyncSender<Delivered>, port: u16, verbose: bool) -> Result<()> {
    let socket = {
        let raw = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, None)?;
        raw.set_recv_buffer_size(8 * 1024 * 1024)?;
        raw.bind(&format!("0.0.0.0:{port}").parse::<std::net::SocketAddr>()?.into())?;
        let std_socket: std::net::UdpSocket = raw.into();
        std_socket
    };
    socket.set_read_timeout(Some(Duration::from_millis(20)))?;
    eprintln!("ss-view: listening on udp/{port} (recv buffer 8 MiB)");

    let mut reassembler = Reassembler::new();
    let mut buffer = vec![0u8; 65536];
    let mut last_stats = Instant::now();
    let mut verbose_count = 0u64;
    loop {
        let now = Instant::now();
        match socket.recv_from(&mut buffer) {
            Ok((len, _)) => {
                if let Some(packet) = Packet::decode(&buffer[..len]) {
                    for frame in reassembler.ingest(&packet, now) {
                        if verbose && verbose_count < 15 {
                            verbose_count += 1;
                            let hex: String = frame
                                .payload
                                .iter()
                                .take(24)
                                .map(|b| format!("{b:02x}"))
                                .collect::<Vec<_>>()
                                .join(" ");
                            eprintln!(
                                "recv-detail: frame_id={} flags={:#04x} len={} head=[{hex}]",
                                frame.frame_id,
                                frame.flags,
                                frame.payload.len()
                            );
                        }
                        if tx.send(frame).is_err() {
                            return Ok(());
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                for frame in reassembler.poll(now) {
                    if tx.send(frame).is_err() {
                        return Ok(());
                    }
                }
            }
            Err(e) => return Err(anyhow::anyhow!("recv_from failed: {e}")),
        }
        if last_stats.elapsed() >= Duration::from_secs(5) {
            let stats = reassembler.stats();
            eprintln!(
                "recv: delivered={} lost={} recovered={} dup={} stale={}",
                stats.delivered, stats.lost_frames, stats.recovered_frames, stats.duplicate_packets, stats.stale_packets
            );
            last_stats = Instant::now();
        }
    }
}

fn yuv_to_argb(yuv: &impl YUVSource, width: usize, height: usize, out: &mut Vec<u32>) {
    out.clear();
    out.resize(width * height, 0);
    let (stride_y, stride_u, stride_v) = yuv.strides();
    let (y_plane, u_plane, v_plane) = (yuv.y(), yuv.u(), yuv.v());
    for row in 0..height {
        for col in 0..width {
            let y = i32::from(y_plane[row * stride_y + col]) - 16;
            let u = i32::from(u_plane[(row / 2) * stride_u + (col / 2)]) - 128;
            let v = i32::from(v_plane[(row / 2) * stride_v + (col / 2)]) - 128;
            let y = if y < 0 { 0 } else { y };
            let r = (298 * y + 409 * v + 128) >> 8;
            let g = (298 * y - 100 * u - 208 * v + 128) >> 8;
            let b = (298 * y + 516 * u + 128) >> 8;
            let r = r.clamp(0, 255) as u32;
            let g = g.clamp(0, 255) as u32;
            let b = b.clamp(0, 255) as u32;
            out[row * width + col] = (r << 16) | (g << 8) | b;
        }
    }
}
