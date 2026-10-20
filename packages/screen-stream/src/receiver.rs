//! Screen receiver: UDP -> reassembly -> H.264 decode -> winit window.
//! Library form of the former ss-view main loop. Requires the `viewer`
//! feature; the window is opened on a dedicated thread so the caller's main
//! thread (e.g. the Flutter engine) is never blocked.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Result;

use crate::events::{EndReason, StreamEvent, StreamState, StreamStats};
use crate::transport::{Delivered, Nack, Packet, Reassembler, FLAG_HEADER, FLAG_KEYFRAME, NACK_ATTEMPTS, NACK_RETRY_INTERVAL};

#[derive(Debug, Clone)]
pub enum ReceiverDecoder {
    /// Linux: VAAPI on `/dev/dri/renderD128`; other platforms: ffmpeg child.
    Auto,
    Vaapi {
        device: String,
    },
    Ffmpeg {
        path: String,
        hwaccel: Option<String>,
        hwaccel_device: Option<String>,
    },
    OpenH264,
}

pub struct ReceiverConfig {
    pub port: u16,
    pub decoder: ReceiverDecoder,
    pub window_title: String,
    pub scale: f32,
    /// `None` runs until [ReceiverHandle::stop] or the window is closed.
    pub duration: Option<Duration>,
    pub verbose: bool,
}

impl Default for ReceiverConfig {
    fn default() -> Self {
        Self {
            port: 53319,
            decoder: ReceiverDecoder::Auto,
            window_title: "AnyShare Viewer".to_string(),
            scale: 1.0,
            duration: None,
            verbose: false,
        }
    }
}

struct Frame {
    width: usize,
    height: usize,
    argb: Vec<u32>,
}

struct Shared {
    generation: AtomicU64,
    frame: Mutex<Option<Arc<Frame>>>,
    decoded: AtomicU64,
    decode_errors: AtomicU64,
    displayed: AtomicU64,
    delivered: AtomicU64,
    lost: AtomicU64,
}

impl Shared {
    fn new() -> Self {
        Self {
            generation: AtomicU64::new(0),
            frame: Mutex::new(None),
            decoded: AtomicU64::new(0),
            decode_errors: AtomicU64::new(0),
            displayed: AtomicU64::new(0),
            delivered: AtomicU64::new(0),
            lost: AtomicU64::new(0),
        }
    }
}

fn publish(shared: &Shared, frame: Frame) {
    *shared.frame.lock().unwrap() = Some(Arc::new(frame));
    shared.generation.fetch_add(1, Ordering::AcqRel);
}

pub struct ReceiverHandle {
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<StreamStats>>,
    joins: Vec<JoinHandle<()>>,
}

impl ReceiverHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    pub fn stats(&self) -> StreamStats {
        *self.stats.lock().unwrap()
    }

    /// Waits for all receiver threads to finish (stops them first).
    pub fn join(mut self) {
        self.stop();
        for join in self.joins.drain(..) {
            let _ = join.join();
        }
    }
}

impl Drop for ReceiverHandle {
    /// Signals the threads to stop but does NOT join them: Drop can run on a
    /// finalizer thread (FRB GC) where blocking is not acceptable. The threads
    /// exit on their own; use [ReceiverHandle::join] to wait for them.
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.joins.clear();
    }
}

fn ffmpeg_available(path: &str) -> bool {
    let candidate = std::path::Path::new(path);
    if path.contains('/') || path.contains('\\') {
        return candidate.is_file();
    }
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(path).is_file()))
        .unwrap_or(false)
}

pub fn start_receiver(config: ReceiverConfig, event_tx: Sender<StreamEvent>) -> Result<ReceiverHandle> {
    let decoder = match &config.decoder {
        ReceiverDecoder::Auto => {
            // Decoder selection: the ffmpeg child pipeline is the default on
            // every platform; the native VAAPI decoder is opt-in
            // (ANYSHARE_DECODER=vaapi) until its iHD blank-surface bug is
            // resolved (reproducible offline with ss-vaapidebug; see the
            // development log). ANYSHARE_FFMPEG_PATH overrides the binary.
            match std::env::var("ANYSHARE_DECODER").as_deref() {
                Ok("vaapi") if cfg!(target_os = "linux") => ReceiverDecoder::Vaapi {
                    device: "/dev/dri/renderD128".to_string(),
                },
                _ => ReceiverDecoder::Ffmpeg {
                    path: std::env::var("ANYSHARE_FFMPEG_PATH").unwrap_or_else(|_| "ffmpeg".to_string()),
                    hwaccel: None,
                    hwaccel_device: None,
                },
            }
        }
        other => other.clone(),
    };

    // Preflight the ffmpeg child binary: a missing dependency must fail the
    // start synchronously with a clear message instead of an async session
    // error (packaging bundles ffmpeg; see the packaging checklist).
    if let ReceiverDecoder::Ffmpeg { path, .. } = &decoder {
        if !ffmpeg_available(path) {
            anyhow::bail!("ffmpeg not found ({path}); install ffmpeg or set ANYSHARE_FFMPEG_PATH to its full path");
        }
    }

    let socket = {
        let raw = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, None)?;
        // A quick stop->start cycle must not hit EADDRINUSE.
        raw.set_reuse_address(true)?;
        raw.set_recv_buffer_size(8 * 1024 * 1024)?;
        raw.bind(&format!("0.0.0.0:{}", config.port).parse::<std::net::SocketAddr>()?.into())?;
        let std_socket: std::net::UdpSocket = raw.into();
        std_socket
    };
    socket.set_read_timeout(Some(Duration::from_millis(20)))?;
    eprintln!("receiver: listening on udp/{} (recv buffer 8 MiB)", config.port);

    let shared = Arc::new(Shared::new());
    let stop = Arc::new(AtomicBool::new(false));
    let stats = Arc::new(Mutex::new(StreamStats::default()));
    let reason: Arc<Mutex<Option<EndReason>>> = Arc::new(Mutex::new(None));

    let (tx, rx) = std::sync::mpsc::sync_channel::<Delivered>(128);

    let mut joins = Vec::new();

    // The socket is bound and the state machine is ready: announce listening
    // before any worker can fail (so an immediate Ended is never the first
    // event the caller sees).
    let _ = event_tx.send(StreamEvent::Status(StreamState::Listening));

    {
        let stop = Arc::clone(&stop);
        let shared = Arc::clone(&shared);
        let reason = Arc::clone(&reason);
        let event_tx = event_tx.clone();
        let verbose = config.verbose;
        joins.push(std::thread::spawn(move || {
            if let Err(e) = receive_loop(socket, tx, event_tx.clone(), verbose, Arc::clone(&stop), shared) {
                eprintln!("receiver: receive thread: {e:#}");
                *reason.lock().unwrap() = Some(EndReason::Error);
                let _ = event_tx.send(StreamEvent::Error(format!("{e:#}")));
                stop.store(true, Ordering::Release);
            }
        }));
    }

    {
        let shared = Arc::clone(&shared);
        let stop = Arc::clone(&stop);
        let reason = Arc::clone(&reason);
        let event_tx = event_tx.clone();
        let verbose = config.verbose;
        joins.push(std::thread::spawn(move || {
            if let Err(e) = media_loop(rx, decoder, shared, Arc::clone(&stop), verbose) {
                eprintln!("receiver: media thread: {e:#}");
                *reason.lock().unwrap() = Some(EndReason::Error);
                let _ = event_tx.send(StreamEvent::Error(format!("{e:#}")));
                stop.store(true, Ordering::Release);
            }
        }));
    }

    {
        let shared = Arc::clone(&shared);
        let stop = Arc::clone(&stop);
        let reason = Arc::clone(&reason);
        let stats = Arc::clone(&stats);
        let event_tx = event_tx.clone();
        let title = config.window_title.clone();
        let scale = config.scale;
        let duration = config.duration;
        joins.push(std::thread::spawn(move || {
            if let Err(e) = window_loop(shared, &title, scale, duration, Arc::clone(&stop), stats, reason, &event_tx) {
                eprintln!("receiver: window thread: {e:#}");
                let _ = event_tx.send(StreamEvent::Error(format!("{e:#}")));
                let _ = event_tx.send(StreamEvent::Ended(EndReason::Error));
                stop.store(true, Ordering::Release);
            }
        }));
    }

    Ok(ReceiverHandle { stop, stats, joins })
}

fn media_loop(
    rx: std::sync::mpsc::Receiver<Delivered>,
    decoder: ReceiverDecoder,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    verbose: bool,
) -> Result<()> {
    match decoder {
        ReceiverDecoder::Vaapi { device } => {
            #[cfg(target_os = "linux")]
            {
                vaapi_loop(rx, shared, stop, verbose, &device)
            }
            #[cfg(not(target_os = "linux"))]
            {
                let _ = (rx, shared, stop, verbose, device);
                anyhow::bail!("the vaapi decoder is Linux-only");
            }
        }
        ReceiverDecoder::Ffmpeg {
            path,
            hwaccel,
            hwaccel_device,
        } => ffmpeg_loop(rx, shared, stop, verbose, &path, hwaccel.as_deref(), hwaccel_device.as_deref()),
        ReceiverDecoder::OpenH264 => openh264_loop(rx, shared, stop, verbose),
        ReceiverDecoder::Auto => unreachable!("Auto is resolved in start_receiver"),
    }
}

use std::num::NonZeroU32;
use winit::application::ApplicationHandler;
use winit::dpi::LogicalSize;
use winit::event::{ElementState, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::keyboard::{Key, NamedKey};
use winit::window::{Fullscreen, Window, WindowId};

fn window_loop(
    shared: Arc<Shared>,
    title: &str,
    scale: f32,
    duration: Option<Duration>,
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<StreamStats>>,
    reason: Arc<Mutex<Option<EndReason>>>,
    event_tx: &Sender<StreamEvent>,
) -> Result<()> {
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    let proxy = viewer_proxy()?;
    proxy
        .send_event(ViewerCommand::Start(ViewerSession {
            shared,
            stop,
            stats,
            reason,
            event_tx: event_tx.clone(),
            title: title.to_string(),
            scale,
            duration,
            started: Instant::now(),
            last_stats: Instant::now(),
            last_presented_generation: 0,
            last_presented_size: (0, 0),
            done: done_tx,
        }))
        .map_err(|_| anyhow::anyhow!("viewer event loop is gone"))?;
    let _ = done_rx.recv();
    Ok(())
}

enum ViewerCommand {
    Start(ViewerSession),
}

struct ViewerSession {
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<StreamStats>>,
    reason: Arc<Mutex<Option<EndReason>>>,
    event_tx: Sender<StreamEvent>,
    title: String,
    scale: f32,
    duration: Option<Duration>,
    started: Instant,
    last_stats: Instant,
    last_presented_generation: u64,
    last_presented_size: (u32, u32),
    done: Sender<()>,
}

/// winit allows exactly one EventLoop per process (the created flag is never
/// reset), so a single daemon loop owns the viewer window for the whole
/// process and hosts one session at a time. Sessions arrive as user events;
/// commands are delivered through the proxy.
fn viewer_proxy() -> Result<&'static winit::event_loop::EventLoopProxy<ViewerCommand>> {
    use std::sync::OnceLock;
    use winit::event_loop::EventLoopProxy;

    static PROXY: OnceLock<EventLoopProxy<ViewerCommand>> = OnceLock::new();
    if let Some(proxy) = PROXY.get() {
        return Ok(proxy);
    }
    let (init_tx, init_rx) = std::sync::mpsc::channel::<Result<EventLoopProxy<ViewerCommand>, String>>();
    std::thread::spawn(move || {
        let mut builder = EventLoop::<ViewerCommand>::with_user_event();
        #[cfg(target_os = "linux")]
        {
            // The daemon thread is not the process main thread.
            use winit::platform::x11::EventLoopBuilderExtX11;
            builder.with_any_thread(true);
        }
        match builder.build() {
            Ok(event_loop) => {
                let proxy = event_loop.create_proxy();
                let _ = init_tx.send(Ok(proxy.clone()));
                let mut host = ViewerHost {
                    active: None,
                    window: None,
                    context: None,
                    surface: None,
                    present_errors: 0,
                };
                if let Err(e) = event_loop.run_app(&mut host) {
                    eprintln!("receiver: viewer event loop ended: {e}");
                }
            }
            Err(e) => {
                let _ = init_tx.send(Err(format!("{e}")));
            }
        }
    });
    match init_rx.recv() {
        Ok(Ok(proxy)) => {
            let _ = PROXY.set(proxy);
            Ok(PROXY.get().expect("proxy just set"))
        }
        Ok(Err(e)) => Err(anyhow::anyhow!("viewer event loop: {e}")),
        Err(_) => Err(anyhow::anyhow!("viewer event loop init failed")),
    }
}

struct ViewerHost {
    active: Option<ViewerSession>,
    window: Option<Arc<Window>>,
    context: Option<softbuffer::Context<Arc<Window>>>,
    surface: Option<softbuffer::Surface<Arc<Window>, Arc<Window>>>,
    present_errors: u64,
}

impl ViewerHost {
    fn toggle_fullscreen(&self) {
        let Some(window) = &self.window else { return };
        if window.fullscreen().is_some() {
            window.set_fullscreen(None);
        } else if let Some(monitor) = window.current_monitor() {
            window.set_fullscreen(Some(Fullscreen::Borderless(Some(monitor))));
        }
    }

    /// Ends the active session: reports the end reason, stops the pipeline,
    /// releases the window and idles the loop.
    fn finish(&mut self, event_loop: &ActiveEventLoop, active: ViewerSession, ended_by_stop: bool) {
        let end = active
            .reason
            .lock()
            .unwrap()
            .unwrap_or(if ended_by_stop { EndReason::Stopped } else { EndReason::WindowClosed });
        let _ = active.event_tx.send(StreamEvent::Ended(end));
        active.stop.store(true, Ordering::Release);
        let _ = active.done.send(());
        self.window = None;
        self.surface = None;
        self.context = None;
        event_loop.set_control_flow(ControlFlow::Wait);
    }

    fn fail(&mut self, active: ViewerSession, message: String) {
        let _ = active.event_tx.send(StreamEvent::Error(message));
        let _ = active.event_tx.send(StreamEvent::Ended(EndReason::Error));
        active.stop.store(true, Ordering::Release);
        let _ = active.done.send(());
    }

    fn present(&mut self) {
        let failure = {
            let (Some(window), Some(surface), Some(active)) = (self.window.as_ref(), self.surface.as_mut(), self.active.as_mut()) else {
                return;
            };
            let size = window.inner_size();
            let (w, h) = (size.width.max(1), size.height.max(1));
            let generation = active.shared.generation.load(Ordering::Acquire);
            // Idle skip: re-presenting an unchanged frame at tick rate burned
            // CPU (and fans) for a static screen.
            if generation == active.last_presented_generation && (w, h) == active.last_presented_size {
                return;
            }
            let (Some(nw), Some(nh)) = (NonZeroU32::new(w), NonZeroU32::new(h)) else {
                return;
            };
            if let Err(e) = surface.resize(nw, nh) {
                Some(format!("resize failed: {e}"))
            } else {
                match surface.buffer_mut() {
                    Err(e) => Some(format!("buffer failed: {e}")),
                    Ok(mut buffer) => {
                        let frame = active.shared.frame.lock().unwrap().clone();
                        buffer.fill(0);
                        if let Some(frame) = &frame {
                            // Letterbox: scale the frame to fit, keep aspect,
                            // center. Fixed-point stepping avoids a float
                            // division per pixel.
                            let scale = (w as f32 / frame.width as f32).min(h as f32 / frame.height as f32);
                            let dw = ((frame.width as f32 * scale) as u32).clamp(1, w);
                            let dh = ((frame.height as f32 * scale) as u32).clamp(1, h);
                            let ox = (w - dw) / 2;
                            let oy = (h - dh) / 2;
                            let step_x = ((frame.width as u64) << 32) / dw as u64;
                            let step_y = ((frame.height as u64) << 32) / dh as u64;
                            let mut sy_acc = 0u64;
                            for y in 0..dh {
                                let sy = ((sy_acc >> 32) as usize).min(frame.height - 1);
                                sy_acc += step_y;
                                let src_row = sy * frame.width;
                                let dst_row = (oy + y) as usize * w as usize + ox as usize;
                                let mut sx_acc = 0u64;
                                for x in 0..dw {
                                    let sx = ((sx_acc >> 32) as usize).min(frame.width - 1);
                                    sx_acc += step_x;
                                    buffer[dst_row + x as usize] = frame.argb[src_row + sx];
                                }
                            }
                            active.shared.displayed.fetch_add(1, Ordering::AcqRel);
                        }
                        match buffer.present() {
                            Ok(()) => {
                                active.last_presented_generation = generation;
                                active.last_presented_size = (w, h);
                                None
                            }
                            Err(e) => Some(format!("present failed: {e}")),
                        }
                    }
                }
            }
        };
        if let Some(message) = failure {
            self.log_present_error(message);
        }
    }

    fn log_present_error(&mut self, message: String) {
        self.present_errors += 1;
        if self.present_errors <= 5 || self.present_errors.is_multiple_of(300) {
            eprintln!("receiver: window {message} (#{})", self.present_errors);
        }
    }
}

impl ApplicationHandler<ViewerCommand> for ViewerHost {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: ViewerCommand) {
        let ViewerCommand::Start(session) = event;
        if let Some(existing) = self.active.take() {
            // One viewer at a time: finish the previous session synchronously
            // (a quick stop→start must not lose the new session).
            self.finish(event_loop, existing, true);
        }
        let attributes = Window::default_attributes()
            .with_title(session.title.clone())
            .with_inner_size(LogicalSize::new(1280.0 * session.scale as f64, 720.0 * session.scale as f64));
        let window = match event_loop.create_window(attributes) {
            Ok(window) => Arc::new(window),
            Err(e) => {
                self.fail(session, format!("creating the viewer window failed: {e}"));
                return;
            }
        };
        // Fullscreen on the current monitor: a shared screen is watched, not
        // decorated. F11 toggles, Esc ends the session.
        if let Some(monitor) = window.current_monitor() {
            window.set_fullscreen(Some(Fullscreen::Borderless(Some(monitor))));
        }
        let context = softbuffer::Context::new(window.clone()).ok();
        let surface = context
            .as_ref()
            .and_then(|context| softbuffer::Surface::new(context, window.clone()).ok());
        eprintln!(
            "receiver: viewer window {}x{} context={} surface={}",
            window.inner_size().width,
            window.inner_size().height,
            context.is_some(),
            surface.is_some()
        );
        if context.is_none() || surface.is_none() {
            self.fail(session, "creating the viewer surface failed".to_string());
            return;
        }
        self.context = context;
        self.surface = surface;
        self.window = Some(window);
        self.present_errors = 0;
        self.active = Some(session);
        event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(8)));
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => {
                if let Some(active) = self.active.take() {
                    self.finish(event_loop, active, false);
                }
            }
            WindowEvent::RedrawRequested => self.present(),
            WindowEvent::KeyboardInput { event, .. } => {
                if event.state == ElementState::Pressed {
                    match event.logical_key {
                        Key::Named(NamedKey::Escape) => {
                            if let Some(active) = self.active.take() {
                                self.finish(event_loop, active, false);
                            }
                        }
                        Key::Named(NamedKey::F11) => self.toggle_fullscreen(),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let Some(mut active) = self.active.take() else {
            return;
        };
        if active.stop.load(Ordering::Acquire) {
            self.finish(event_loop, active, true);
            return;
        }
        if let Some(duration) = active.duration {
            if active.started.elapsed() >= duration {
                self.finish(event_loop, active, true);
                return;
            }
        }
        if active.last_stats.elapsed() >= Duration::from_secs(1) {
            let displayed = active.shared.displayed.swap(0, Ordering::AcqRel);
            let decoded = active.shared.decoded.swap(0, Ordering::AcqRel);
            let decode_errors = active.shared.decode_errors.load(Ordering::Acquire);
            let delivered = active.shared.delivered.load(Ordering::Acquire);
            let lost = active.shared.lost.load(Ordering::Acquire);
            {
                let mut shared_stats = active.stats.lock().unwrap();
                shared_stats.frames = decoded;
                shared_stats.fps = displayed as f64;
                shared_stats.packets = delivered;
                shared_stats.lost = lost;
                shared_stats.decode_errors = decode_errors;
            }
            let _ = active.event_tx.send(StreamEvent::Stats(StreamStats {
                frames: decoded,
                fps: displayed as f64,
                packets: delivered,
                lost,
                decode_errors,
                ..Default::default()
            }));
            active.last_stats = Instant::now();
        }
        if let Some(window) = &self.window {
            window.request_redraw();
        }
        // Tick at ~125 Hz instead of busy-polling: cheap when the screen is
        // static, responsive enough for 60 fps content.
        event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(8)));
        self.active = Some(active);
    }
}

fn ffmpeg_loop(
    rx: std::sync::mpsc::Receiver<Delivered>,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    verbose: bool,
    ffmpeg_path: &str,
    hwaccel: Option<&str>,
    hwaccel_device: Option<&str>,
) -> Result<()> {
    use std::io::Write;

    let mut args: Vec<String> = vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-fflags".into(),
        "nobuffer".into(),
        "-flags".into(),
        "low_delay".into(),
    ];
    if let Some(name) = hwaccel {
        args.push("-hwaccel".into());
        args.push(name.into());
        if let Some(device) = hwaccel_device {
            args.push("-hwaccel_device".into());
            args.push(device.into());
        }
    }
    args.extend(["-f".into(), "h264".into(), "-i".into(), "-".into()]);
    args.extend(["-c:v".into(), "bmp".into(), "-f".into(), "image2pipe".into(), "-".into()]);

    let mut child = std::process::Command::new(ffmpeg_path)
        .args(&args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .map_err(|e| anyhow::anyhow!("spawning ffmpeg ({ffmpeg_path}) failed: {e}"))?;

    let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdin missing"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdout missing"))?;

    let reader_shared = Arc::clone(&shared);
    let reader = std::thread::spawn(move || {
        if let Err(e) = bmp_reader(stdout, reader_shared, verbose) {
            eprintln!("receiver: ffmpeg reader thread: {e:#}");
        }
    });

    let mut pipe_error: Option<anyhow::Error> = None;
    while !stop.load(Ordering::Acquire) {
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

fn bmp_reader(mut stdout: std::process::ChildStdout, shared: Arc<Shared>, _verbose: bool) -> Result<()> {
    use std::io::Read;

    let mut buffer: Vec<u8> = Vec::with_capacity(4 * 1024 * 1024);
    let mut chunk = vec![0u8; 1024 * 1024];
    let mut frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut last_stats = Instant::now();

    loop {
        let read = stdout.read(&mut chunk)?;
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > 256 * 1024 * 1024 {
            eprintln!("receiver: bmp buffer exceeded 256 MiB, resetting");
            buffer.clear();
        }

        loop {
            let Some(start) = find_bmp(&buffer) else {
                if buffer.len() > 2 {
                    let keep = buffer.len() - 2;
                    buffer.drain(..keep);
                }
                break;
            };
            if start > 0 {
                buffer.drain(..start);
            }
            if buffer.len() < 54 {
                break;
            }
            let total = u32::from_le_bytes(buffer[2..6].try_into().unwrap()) as usize;
            if !(54..=64 * 1024 * 1024).contains(&total) {
                buffer.drain(..2);
                continue;
            }
            if buffer.len() < total {
                break;
            }
            let pixel_offset = u32::from_le_bytes(buffer[10..14].try_into().unwrap()) as usize;
            let width = i32::from_le_bytes(buffer[18..22].try_into().unwrap());
            let height = i32::from_le_bytes(buffer[22..26].try_into().unwrap());
            let bpp = u16::from_le_bytes(buffer[28..30].try_into().unwrap());
            let (width, height, bottom_up) = (width as usize, height.unsigned_abs() as usize, height > 0);
            let row_bytes = width * (bpp as usize / 8);
            let row_stride = (row_bytes + 3) & !3;
            let data_end = pixel_offset.saturating_add(height.saturating_mul(row_stride));
            if width == 0
                || height == 0
                || width > 8192
                || height > 8192
                || (bpp != 24 && bpp != 32)
                || pixel_offset < 54
                || data_end > total
            {
                buffer.drain(..2);
                continue;
            }

            let t0 = Instant::now();
            let mut argb = Vec::with_capacity(width * height);
            for row in 0..height {
                let src_row = if bottom_up { height - 1 - row } else { row };
                let row_start = pixel_offset + src_row * row_stride;
                let row_slice = &buffer[row_start..row_start + row_bytes];
                for x in 0..width {
                    let px = &row_slice[x * (bpp as usize / 8)..];
                    let (b, g, r) = (px[0], px[1], px[2]);
                    argb.push((u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b));
                }
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
            shared.decoded.fetch_add(1, Ordering::AcqRel);
            decode_ms_sum += t0.elapsed().as_secs_f64() * 1000.0;
            buffer.drain(..total);
        }

        if last_stats.elapsed() >= Duration::from_secs(1) {
            let avg_ms = if frames == 0 { 0.0 } else { decode_ms_sum / frames as f64 };
            eprintln!("media: decoded={frames} avg_parse_ms={avg_ms:.1} (ffmpeg bmp pipe)");
            frames = 0;
            decode_ms_sum = 0.0;
            last_stats = Instant::now();
        }
    }
    Ok(())
}

fn find_bmp(buffer: &[u8]) -> Option<usize> {
    let mut i = 0;
    while i + 54 <= buffer.len() {
        if buffer[i] == b'B' && buffer[i + 1] == b'M' {
            let total = u32::from_le_bytes(buffer[i + 2..i + 6].try_into().unwrap()) as usize;
            let dib = u32::from_le_bytes(buffer[i + 14..i + 18].try_into().unwrap());
            if (54..=64 * 1024 * 1024).contains(&total) && dib >= 40 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

#[cfg(target_os = "linux")]
fn vaapi_loop(
    rx: std::sync::mpsc::Receiver<Delivered>,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    _verbose: bool,
    device: &str,
) -> Result<()> {
    use crate::vaapi::VaapiDecoder;

    let mut decoder = VaapiDecoder::new(device)?;
    eprintln!("receiver: vaapi decoder ready ({device})");
    let mut frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut errors: u64 = 0;
    let mut last_stats = Instant::now();

    loop {
        if stop.load(Ordering::Acquire) {
            break;
        }
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(frame) => {
                let t0 = Instant::now();
                match decoder.decode(&frame.payload) {
                    Ok(Some((width, height, argb))) => {
                        // Diagnostic: dump the first decoded frame as PPM when
                        // ANYSHARE_FRAME_DUMP is set (acceptance debugging).
                        if let Ok(path) = std::env::var("ANYSHARE_FRAME_DUMP") {
                            // Keep overwriting for the first ~10s so the file
                            // holds the LAST frame (what the window shows).
                            static DUMP_COUNT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
                            if DUMP_COUNT.fetch_add(1, Ordering::AcqRel) < 600 {
                                use std::io::Write;
                                if let Ok(mut file) = std::fs::File::create(&path) {
                                    let _ = write!(file, "P6\n{} {}\n255\n", width, height);
                                    let mut bytes = Vec::with_capacity((width * height * 3) as usize);
                                    for pixel in &argb {
                                        bytes.extend_from_slice(&[(pixel >> 16) as u8, (pixel >> 8) as u8, *pixel as u8]);
                                    }
                                    let _ = file.write_all(&bytes);
                                }
                            }
                        }
                        publish(
                            &shared,
                            Frame {
                                width: width as usize,
                                height: height as usize,
                                argb,
                            },
                        );
                        frames += 1;
                        shared.decoded.fetch_add(1, Ordering::AcqRel);
                        decode_ms_sum += t0.elapsed().as_secs_f64() * 1000.0;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        errors += 1;
                        shared.decode_errors.fetch_add(1, Ordering::AcqRel);
                        if errors <= 10 || errors.is_multiple_of(300) {
                            eprintln!("receiver: vaapi decode error #{errors}: {e:#}");
                        }
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
        if last_stats.elapsed() >= Duration::from_secs(1) {
            let avg_ms = if frames == 0 { 0.0 } else { decode_ms_sum / frames as f64 };
            eprintln!("media: decoded={frames} avg_decode_ms={avg_ms:.1} (vaapi) errors={errors}");
            frames = 0;
            decode_ms_sum = 0.0;
            last_stats = Instant::now();
        }
    }
    Ok(())
}

fn openh264_loop(
    rx: std::sync::mpsc::Receiver<Delivered>,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    verbose: bool,
) -> Result<()> {
    use openh264::decoder::Decoder;
    use openh264::formats::YUVSource;

    let mut decoder = Decoder::new()?;
    let mut sequence_header: Option<Vec<u8>> = None;
    let mut decoder_dirty = false;
    let mut argb: Vec<u32> = Vec::new();
    let mut decoded_frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut decode_errors: u64 = 0;
    let mut last_stats = Instant::now();

    loop {
        if stop.load(Ordering::Acquire) {
            break;
        }
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
                    shared.decode_errors.fetch_add(1, Ordering::AcqRel);
                    decoder_dirty = true;
                    if decode_errors <= 10 || decode_errors.is_multiple_of(300) {
                        eprintln!("receiver: decode error #{decode_errors} (awaiting sync): {e:?}");
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
            shared.decoded.fetch_add(1, Ordering::AcqRel);
            decode_ms_sum += t0.elapsed().as_secs_f64() * 1000.0;
        }
    }
    Ok(())
}

fn yuv_to_argb(yuv: &impl openh264::formats::YUVSource, width: usize, height: usize, out: &mut Vec<u32>) {
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

fn receive_loop(
    socket: std::net::UdpSocket,
    tx: std::sync::mpsc::SyncSender<Delivered>,
    events: Sender<StreamEvent>,
    verbose: bool,
    stop: Arc<AtomicBool>,
    shared: Arc<Shared>,
) -> Result<()> {
    let mut reassembler = Reassembler::new();
    let mut buffer = vec![0u8; 65536];
    let mut last_stats = Instant::now();
    let mut verbose_count = 0u64;
    let mut peer_addr: Option<std::net::SocketAddr> = None;
    let mut nack_state: std::collections::HashMap<u32, (u8, Instant)> = std::collections::HashMap::new();
    let mut last_nack_scan = Instant::now();
    let mut last_counter_publish = Instant::now();
    let mut last_lost = 0u64;
    let mut keyframe_request_pending = false;
    let mut last_keyframe_request: Option<Instant> = None;
    loop {
        if stop.load(Ordering::Acquire) {
            return Ok(());
        }
        let now = Instant::now();
        match socket.recv_from(&mut buffer) {
            Ok((len, from)) => {
                if let Some(packet) = Packet::decode(&buffer[..len]) {
                    // Only the current session's peer may redirect NACKs: a
                    // stray datagram must not turn us into a reflector.
                    if reassembler.session().is_none_or(|session| session == packet.session) {
                        peer_addr = Some(from);
                    }
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
        // Selective retransmission: NACK missing data packets of frames that
        // stopped making progress (two attempts, 8 ms apart). FEC already
        // covers single losses; NACKs cover the rest before the 300 ms frame
        // timeout. The scan itself is gated to 2 ms: building candidates per
        // received packet would allocate far too much on large frames.
        if peer_addr.is_some() && now.duration_since(last_nack_scan) >= Duration::from_millis(2) {
            last_nack_scan = now;
            if let (Some(peer), Some(session)) = (peer_addr, reassembler.session()) {
                let candidates = reassembler.missing_candidates(now);
                for (frame_id, count, missing) in &candidates {
                    let entry = nack_state.entry(*frame_id).or_insert((0, now));
                    let due = entry.0 < NACK_ATTEMPTS && (entry.0 == 0 || now.duration_since(entry.1) >= NACK_RETRY_INTERVAL);
                    if due {
                        entry.0 += 1;
                        entry.1 = now;
                        let nack = Nack {
                            session,
                            frame_id: *frame_id,
                            count: *count,
                            missing: missing.clone(),
                        };
                        let _ = socket.send_to(&nack.encode(), peer);
                    }
                }
                // Drop attempts for frames that completed or timed out.
                if nack_state.len() > 32 {
                    nack_state.retain(|frame_id, _| candidates.iter().any(|(candidate, _, _)| candidate == frame_id));
                }
            }
        }

        // Loss recovery: an unrecovered frame drop leaves the decoder with a
        // missing reference until the next IDR, visible as smearing/stutter.
        // Report it so the control plane can ask the sender for a keyframe.
        // Debounced: one request per 500 ms is plenty (an IDR is expensive),
        // but losses inside the debounce window stay pending so they are sent
        // when the window opens instead of being swallowed.
        let lost = reassembler.stats().lost_frames;
        if lost > last_lost {
            last_lost = lost;
            keyframe_request_pending = true;
        }
        if keyframe_request_pending
            && last_keyframe_request.map_or(true, |at| now.duration_since(at) >= Duration::from_millis(500))
        {
            keyframe_request_pending = false;
            last_keyframe_request = Some(now);
            let _ = events.send(StreamEvent::RequestKeyframe);
        }
        // Publish counters every second: the app uses the cumulative loss
        // delta against the per-second window frames for adaptive bitrate, so
        // a coarse (5 s) refresh would break the feedback math.
        if last_counter_publish.elapsed() >= Duration::from_secs(1) {
            let stats = reassembler.stats();
            shared.delivered.store(stats.delivered, Ordering::Release);
            shared.lost.store(stats.lost_frames, Ordering::Release);
            last_counter_publish = Instant::now();
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
