//! Screen sender: capture -> VFR gate -> H.264 encode -> packetize + FEC -> UDP.
//! Library form of the former ss-send main loop; Windows-only.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Result;

use crate::events::{EndReason, StreamEvent, StreamState, StreamStats};

pub struct SenderConfig {
    /// `ip:port` of the receiver's data plane.
    pub target: String,
    /// Output index (as string) or device-name substring; `None` auto-picks.
    pub output: Option<String>,
    pub bitrate_bps: u32,
    pub fps: u32,
    pub timeout_ms: u32,
    /// `None` runs until [SenderHandle::stop].
    pub duration: Option<Duration>,
}

impl Default for SenderConfig {
    fn default() -> Self {
        Self {
            target: String::new(),
            output: None,
            bitrate_bps: 8_000_000,
            fps: 60,
            timeout_ms: 500,
            duration: None,
        }
    }
}

pub struct SenderHandle {
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<StreamStats>>,
    join: Option<JoinHandle<()>>,
}

impl SenderHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    pub fn stats(&self) -> StreamStats {
        *self.stats.lock().unwrap()
    }

    /// Waits for the sender thread to finish (stops it first).
    pub fn join(mut self) {
        self.stop();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for SenderHandle {
    /// Signals the thread to stop but does NOT join it: Drop can run on a
    /// finalizer thread (FRB GC) where blocking is not acceptable. The thread
    /// exits on its own; use [SenderHandle::join] to wait for it.
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.join.take();
    }
}

pub fn start_sender(config: SenderConfig, event_tx: Sender<StreamEvent>) -> Result<SenderHandle> {
    #[cfg(not(windows))]
    {
        let _ = (config, event_tx);
        anyhow::bail!("screen sending is Windows-only (capture/encode layers)");
    }

    #[cfg(windows)]
    {
        imp::start(config, event_tx)
    }
}

#[cfg(windows)]
mod imp {
    use super::*;

    use std::net::UdpSocket;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::transport::{packetize, FLAG_DISCONTINUITY, FLAG_HEADER, FLAG_KEYFRAME};
    use crate::types::{Acquire, FrameMeta};
    use crate::vfr::{EncodeDecision, VfrConfig, VfrGate};
    use crate::{create_best_encoder, enumerate_outputs, windows_capture, Duplicator};

    fn send_event(event_tx: &Sender<StreamEvent>, event: StreamEvent) {
        let _ = event_tx.send(event);
    }

    pub fn start(config: SenderConfig, event_tx: Sender<StreamEvent>) -> Result<SenderHandle> {
        let stop = Arc::new(AtomicBool::new(false));
        let stats = Arc::new(Mutex::new(StreamStats::default()));

        let thread_stop = Arc::clone(&stop);
        let thread_stats = Arc::clone(&stats);
        // Everything COM/DXGI/MF related (output enumeration, duplicator,
        // encoder) is created and used on this one worker thread: the objects
        // are not Send, and MF wants a stable apartment per object.
        let join = std::thread::spawn(move || {
            send_event(&event_tx, StreamEvent::Status(StreamState::Starting));
            if let Err(e) = run(config, thread_stop, Arc::clone(&thread_stats), &event_tx) {
                send_event(&event_tx, StreamEvent::Error(format!("{e:#}")));
                send_event(&event_tx, StreamEvent::Ended(EndReason::Error));
                return;
            }
            send_event(&event_tx, StreamEvent::Ended(EndReason::Stopped));
        });

        Ok(SenderHandle {
            stop,
            stats,
            join: Some(join),
        })
    }

    fn run(config: SenderConfig, stop: Arc<AtomicBool>, stats: Arc<Mutex<StreamStats>>, event_tx: &Sender<StreamEvent>) -> Result<()> {
        let outputs = enumerate_outputs()?;
        let attached: Vec<_> = outputs.iter().filter(|o| o.attached).cloned().collect();
        let target_output = match &config.output {
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
            None => attached
                .iter()
                .min_by_key(|o| o.desktop_rect.area())
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("no attached output to auto-pick"))?,
        };

        if windows_capture::rotation_name(target_output.rotation) != "identity" {
            anyhow::bail!("capturing rotated outputs is not supported yet");
        }

        let socket = {
            let raw = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, None)?;
            raw.set_send_buffer_size(8 * 1024 * 1024)?;
            raw.connect(&config.target.parse::<std::net::SocketAddr>()?.into())?;
            let std_socket: UdpSocket = raw.into();
            std_socket
        };

        let session = (SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos() & 0xFFFF_FFFF) as u32 | 1;

        let encoder_config = crate::EncoderConfig {
            width: target_output.desktop_rect.width() as u32,
            height: target_output.desktop_rect.height() as u32,
            bitrate_bps: config.bitrate_bps,
            fps: config.fps,
        };
        let encoder = create_best_encoder(&encoder_config)?;
        eprintln!("sender: encoder {} (input {})", encoder.name(), encoder.input_format().name());

        let dup = Duplicator::new(target_output.index)?;

        run_loop(config, socket, session, encoder, dup, stop, stats, event_tx)
    }

    #[allow(clippy::too_many_arguments)]
    fn run_loop(
        config: SenderConfig,
        socket: UdpSocket,
        session: u32,
        mut encoder: crate::windows_encoder::H264Encoder,
        mut dup: Duplicator,
        stop: Arc<AtomicBool>,
        stats: Arc<Mutex<StreamStats>>,
        event_tx: &Sender<StreamEvent>,
    ) -> Result<()> {
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

        let mut sequence_header: Option<Vec<u8>> = encoder.take_sequence_header();
        if let Some(header) = &sequence_header {
            let packets = packetize(session, 0, FLAG_HEADER, 0, header);
            for packet in &packets {
                socket.send(&packet.encode())?;
                packets_sent += 1;
                bytes_sent += packet.payload.len() as u64;
            }
        }

        let started = Instant::now();
        let mut last_stats = Instant::now();
        let mut window_packets: u64 = 0;
        let mut window_bytes: u64 = 0;
        let mut window_frames: u64 = 0;
        let mut window_keyframes: u64 = 0;

        while !stop.load(Ordering::Acquire) {
            if let Some(duration) = config.duration {
                if started.elapsed() >= duration {
                    break;
                }
            }

            match dup.acquire_full(config.timeout_ms)? {
                None => {
                    let _ = gate.decide(&FrameMeta::default(), Instant::now());
                }
                Some((meta, pixels)) => {
                    let rebuild_changed = dup.rebuild_count() != last_rebuild_count;
                    last_rebuild_count = dup.rebuild_count();

                    if let EncodeDecision::Encode { keyframe } = gate.decide(&meta, Instant::now()) {
                        {
                            use crate::windows_encoder::InputPixelFormat;
                            match encoder.input_format() {
                                InputPixelFormat::Nv12 => {
                                    crate::convert::bgra_to_nv12(&pixels.bgra, pixels.width, pixels.height, &mut i420)
                                }
                                InputPixelFormat::I420 => {
                                    crate::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420)
                                }
                                InputPixelFormat::Yv12 => {
                                    crate::convert::bgra_to_i420(&pixels.bgra, pixels.width, pixels.height, &mut i420);
                                    crate::convert::i420_to_yv12_in_place(&mut i420, pixels.width, pixels.height);
                                }
                            }
                        }

                        let t100 = started.elapsed().as_nanos() as i64 / 100;
                        let delta = if last_enc_time_100ns >= 0 {
                            t100 - last_enc_time_100ns
                        } else {
                            10_000_000 / i64::from(config.fps.max(1))
                        };
                        let duration = delta.clamp(10_000, 5_000_000);
                        let discontinuity = rebuild_changed || delta > 2_000_000;

                        if let Some(header) = encoder.take_sequence_header() {
                            let packets = packetize(session, frame_id, FLAG_HEADER, t100 as u64, &header);
                            for packet in &packets {
                                socket.send(&packet.encode())?;
                                packets_sent += 1;
                                window_packets += 1;
                                bytes_sent += packet.payload.len() as u64;
                                window_bytes += packet.payload.len() as u64;
                            }
                            frame_id = frame_id.wrapping_add(1);
                            sequence_header = Some(header);
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
                            let with_header;
                            let payload: &[u8] = if keyframe {
                                match &sequence_header {
                                    Some(header) => {
                                        let mut combined = Vec::with_capacity(header.len() + chunk.len());
                                        combined.extend_from_slice(header);
                                        combined.extend_from_slice(chunk);
                                        with_header = combined;
                                        &with_header
                                    }
                                    None => chunk,
                                }
                            } else {
                                chunk
                            };
                            let packets = packetize(session, frame_id, flags, t100 as u64, payload);
                            for packet in &packets {
                                socket.send(&packet.encode())?;
                                packets_sent += 1;
                                window_packets += 1;
                                bytes_sent += packet.payload.len() as u64;
                                window_bytes += packet.payload.len() as u64;
                            }
                            frame_id = frame_id.wrapping_add(1);
                            frames_sent += 1;
                            window_frames += 1;
                            if frames_sent == 1 {
                                send_event(event_tx, StreamEvent::Status(StreamState::Streaming));
                            }
                        }
                        if keyframe && had_output {
                            keyframes_sent += 1;
                            window_keyframes += 1;
                        }
                        if last_enc_time_100ns < 0 && started.elapsed() > Duration::from_secs(5) {
                            anyhow::bail!("encoder produced no output within 5s (activating-but-mute MFT?)");
                        }
                        last_enc_time_100ns = t100;
                        last_send_time_100ns = t100;
                    }
                    dup.recycle_pixels(pixels);
                }
            }

            if last_stats.elapsed() >= Duration::from_secs(1) {
                let mbps = window_bytes as f64 * 8.0 / 1_000_000.0;
                {
                    let mut shared = stats.lock().unwrap();
                    shared.frames = window_frames;
                    shared.keyframes = window_keyframes;
                    shared.fps = window_frames as f64;
                    shared.mbps = mbps;
                    shared.packets = window_packets;
                }
                send_event(
                    event_tx,
                    StreamEvent::Stats(StreamStats {
                        frames: window_frames,
                        keyframes: window_keyframes,
                        fps: window_frames as f64,
                        mbps,
                        packets: window_packets,
                        ..Default::default()
                    }),
                );
                window_packets = 0;
                window_bytes = 0;
                window_frames = 0;
                window_keyframes = 0;
                last_stats = Instant::now();
            }
        }

        send_event(event_tx, StreamEvent::Status(StreamState::Stopping));
        for chunk in encoder.shutdown()? {
            let packets = packetize(session, frame_id, 0, last_send_time_100ns.max(0) as u64, &chunk);
            for packet in &packets {
                socket.send(&packet.encode())?;
                packets_sent += 1;
                bytes_sent += packet.payload.len() as u64;
            }
            frame_id = frame_id.wrapping_add(1);
        }

        eprintln!(
            "sender: frames={frames_sent} keyframes={keyframes_sent} packets={packets_sent} sent={:.2} MiB in {}s",
            bytes_sent as f64 / 1048576.0,
            started.elapsed().as_secs()
        );
        let _ = Acquire::Idle;
        Ok(())
    }
}
