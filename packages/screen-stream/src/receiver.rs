//! Screen receiver: UDP -> reassembly -> H.264 decode -> winit window.
//! Library form of the former ss-view main loop. Requires the `viewer`
//! feature; the window is opened on a dedicated thread so the caller's main
//! thread (e.g. the Flutter engine) is never blocked.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
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
    monitor_width: AtomicU32,
    monitor_height: AtomicU32,
    /// Wakes the viewer thread as soon as a frame is published.
    proxy: Mutex<Option<winit::event_loop::EventLoopProxy<ViewerCommand>>>,
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
            monitor_width: AtomicU32::new(0),
            monitor_height: AtomicU32::new(0),
            proxy: Mutex::new(None),
        }
    }
}

fn publish(shared: &Shared, frame: Frame) {
    *shared.frame.lock().unwrap() = Some(Arc::new(frame));
    shared.generation.fetch_add(1, Ordering::AcqRel);
    // Latency: wake the viewer immediately instead of waiting for its tick.
    if let Some(proxy) = shared.proxy.lock().unwrap().as_ref() {
        let _ = proxy.send_event(ViewerCommand::Frame);
    }
}

pub struct ReceiverHandle {
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<StreamStats>>,
    shared: Arc<Shared>,
    joins: Vec<JoinHandle<()>>,
}

impl ReceiverHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    /// Physical size of the primary monitor (0 timeout: not created yet).
    pub fn monitor_size(&self) -> Option<(u32, u32)> {
        let width = self.shared.monitor_width.load(Ordering::Acquire);
        let height = self.shared.monitor_height.load(Ordering::Acquire);
        (width > 0 && height > 0).then_some((width, height))
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

    // Bounded decode queue: a slow decoder/presenter must NEVER add latency.
    // The old depth (128) allowed ~4 s of backlog; 4 frames caps the added
    // latency near 130 ms and overflowing frames are dropped deliberately.
    let (tx, rx) = std::sync::mpsc::sync_channel::<Delivered>(4);

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

    Ok(ReceiverHandle { stop, stats, shared, joins })
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
    // Let the decode threads wake this window as soon as they publish.
    *shared.proxy.lock().unwrap() = Some(proxy.clone());
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
    /// A new decoded frame is ready: present immediately instead of waiting
    /// for the periodic tick (the tick would add up to a few ms per frame).
    Frame,
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
        // The window (and its screen) is gone: report no monitor size so a
        // late poll cannot hand out a stale viewport.
        active.shared.monitor_width.store(0, Ordering::Release);
        active.shared.monitor_height.store(0, Ordering::Release);
        *active.shared.proxy.lock().unwrap() = None;
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
        active.shared.monitor_width.store(0, Ordering::Release);
        active.shared.monitor_height.store(0, Ordering::Release);
        *active.shared.proxy.lock().unwrap() = None;
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
                            let ox = ((w - dw) / 2) as usize;
                            let oy = ((h - dh) / 2) as usize;
                            scale_bilinear(
                                &frame.argb,
                                frame.width,
                                frame.height,
                                &mut buffer,
                                w as usize,
                                dw as usize,
                                dh as usize,
                                ox,
                                oy,
                            );
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
        let session = match event {
            ViewerCommand::Frame => {
                // A frame was published: present it now, not on the next tick.
                if let Some(window) = &self.window {
                    window.request_redraw();
                }
                return;
            }
            ViewerCommand::Start(session) => session,
        };
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
        // Present the first frame immediately (it may already be published).
        window.request_redraw();
        self.window = Some(window);
        self.present_errors = 0;
        self.active = Some(session);
        // Frame arrivals wake the loop explicitly (ViewerCommand::Frame), so
        // this tick is only a fallback for stats/duration bookkeeping.
        event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(16)));
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
        // Report the primary monitor's physical size so the sender can encode
        // at a resolution that maps 1:1 in fullscreen (no upscaling blur).
        // Track the monitor the window is actually on (the user may move it
        // or toggle fullscreen): encoding must match that screen, not the
        // primary one. Refreshed while a session is active.
        if let Some(window) = &self.window {
            let monitor = window.current_monitor().or_else(|| event_loop.primary_monitor());
            if let Some(monitor) = monitor {
                let size = monitor.size();
                if active.shared.monitor_width.load(Ordering::Acquire) != size.width {
                    active.shared.monitor_width.store(size.width, Ordering::Release);
                }
                if active.shared.monitor_height.load(Ordering::Acquire) != size.height {
                    active.shared.monitor_height.store(size.height, Ordering::Release);
                }
            }
        }
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
        // Frame arrivals wake the loop explicitly (ViewerCommand::Frame), so
        // this tick is only a fallback for stats/duration bookkeeping.
        event_loop.set_control_flow(ControlFlow::WaitUntil(Instant::now() + Duration::from_millis(16)));
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
    // Raw NV12 keeps the pipe 2.7x smaller than BMP (1.5 vs 4 bytes/px) and
    // removes the image2pipe/BMP parsing on the hot path.
    args.extend(["-pix_fmt".into(), "nv12".into(), "-f".into(), "rawvideo".into(), "-".into()]);

    let mut child = std::process::Command::new(ffmpeg_path)
        .args(&args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .map_err(|e| anyhow::anyhow!("spawning ffmpeg ({ffmpeg_path}) failed: {e}"))?;

    let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdin missing"))?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("ffmpeg stdout missing"))?;
    // The raw pipe carries no frame headers: dimensions come from the SPS in
    // the stream (set by the writer before the first frame is piped).
    let dimensions = Arc::new(std::sync::Mutex::new(None::<(usize, usize)>));
    let reader_dimensions = Arc::clone(&dimensions);

    let reader_shared = Arc::clone(&shared);
    let reader = std::thread::spawn(move || {
        if let Err(e) = raw_nv12_reader(stdout, reader_shared, reader_dimensions, verbose) {
            eprintln!("receiver: ffmpeg reader thread: {e:#}");
        }
    });

    let mut pipe_error: Option<anyhow::Error> = None;
    let mut e2e_sum_ms = 0.0f64;
    let mut e2e_max_ms = 0.0f64;
    let mut e2e_count = 0u64;
    let mut queue_ms_sum = 0.0f64;
    let mut queue_ms_max = 0.0f64;
    let mut queue_frames = 0u64;
    let mut last_pipe_stats = Instant::now();
    while !stop.load(Ordering::Acquire) {
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(frame) => {
                let queue_ms = frame.received_at.elapsed().as_secs_f64() * 1000.0;
                let now_epoch_ms = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|value| value.as_secs_f64() * 1000.0)
                    .unwrap_or(0.0);
                let au_epoch_ms = frame.timestamp_100ns as f64 / 10_000.0;
                if au_epoch_ms > 1.0e12 {
                    let e2e_ms = now_epoch_ms - au_epoch_ms;
                    if e2e_ms > e2e_max_ms {
                        e2e_max_ms = e2e_ms;
                    }
                    e2e_sum_ms += e2e_ms;
                    e2e_count += 1;
                }
                queue_ms_sum += queue_ms;
                queue_ms_max = queue_ms_max.max(queue_ms);
                queue_frames += 1;
                if last_pipe_stats.elapsed() >= Duration::from_secs(1) {
                    eprintln!(
                        "decode queue: avg={:.1}ms max={:.1}ms frames={} e2e(pipe) avg={:.1}ms max={:.1}ms",
                        if queue_frames > 0 { queue_ms_sum / queue_frames as f64 } else { 0.0 },
                        queue_ms_max,
                        queue_frames,
                        if e2e_count > 0 { e2e_sum_ms / e2e_count as f64 } else { 0.0 },
                        e2e_max_ms
                    );
                    e2e_sum_ms = 0.0;
                    e2e_max_ms = 0.0;
                    e2e_count = 0;
                    queue_ms_sum = 0.0;
                    queue_ms_max = 0.0;
                    queue_frames = 0;
                    last_pipe_stats = Instant::now();
                }
                if dimensions.lock().unwrap().is_none() {
                    if let Some(size) = h264_dimensions(&frame.payload) {
                        *dimensions.lock().unwrap() = Some(size);
                    }
                }
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

fn raw_nv12_reader(
    mut stdout: std::process::ChildStdout,
    shared: Arc<Shared>,
    dimensions: Arc<std::sync::Mutex<Option<(usize, usize)>>>,
    _verbose: bool,
) -> Result<()> {
    use std::io::Read;

    let mut frame_bytes: Vec<u8> = Vec::new();
    let mut argb: Vec<u32> = Vec::new();
    let mut frames: u64 = 0;
    let mut decode_ms_sum: f64 = 0.0;
    let mut last_stats = Instant::now();
    let dump_path = std::env::var("ANYSHARE_FRAME_DUMP").ok();
    let dump_at: f64 = std::env::var("ANYSHARE_FRAME_DUMP_AT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0.0);
    let dump_started = Instant::now();
    let mut dumped = false;
    loop {
        let Some((width, height)) = *dimensions.lock().unwrap() else {
            std::thread::sleep(Duration::from_millis(2));
            continue;
        };
        let expected = width * height * 3 / 2;
        if width == 0 || height == 0 || expected > 64 * 1024 * 1024 {
            anyhow::bail!("implausible video dimensions {width}x{height}");
        }
        frame_bytes.resize(expected, 0);
        let started = Instant::now();
        match stdout.read_exact(&mut frame_bytes) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(anyhow::anyhow!("reading NV12 frame failed: {e}")),
        }
        nv12_to_argb(&frame_bytes, width, height, &mut argb);
        if !dumped && dump_path.is_some() && dump_started.elapsed().as_secs_f64() >= dump_at {
            dumped = true;
            if let Some(path) = &dump_path {
                let stamp = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|value| value.as_secs_f64())
                    .unwrap_or_default();
                eprintln!("receiver: frame dumped at {stamp:.3}");
                if let Ok(mut file) = std::fs::File::create(path) {
                    use std::io::Write;
                    let _ = write!(&mut file, "P6
{width} {height}
255
");
                    let mut rgb = Vec::with_capacity(width * height * 3);
                    for pixel in &argb {
                        rgb.push((pixel >> 16) as u8);
                        rgb.push((pixel >> 8) as u8);
                        rgb.push(*pixel as u8);
                    }
                    let _ = file.write_all(&rgb);
                }
            }
        }
        publish(
            &shared,
            Frame {
                width,
                height,
                argb: std::mem::take(&mut argb),
            },
        );
        frames += 1;
        shared.decoded.fetch_add(1, Ordering::AcqRel);
        decode_ms_sum += started.elapsed().as_secs_f64() * 1000.0;
        if last_stats.elapsed() >= Duration::from_secs(1) {
            let avg_ms = if frames == 0 { 0.0 } else { decode_ms_sum / frames as f64 };
            eprintln!("media: decoded={frames} avg_decode_ms={avg_ms:.1} (ffmpeg/nv12)");
            frames = 0;
            decode_ms_sum = 0.0;
            last_stats = Instant::now();
        }
    }
    Ok(())
}

/// Frame dimensions from the first SPS in an Annex-B access unit.
fn h264_dimensions(au: &[u8]) -> Option<(usize, usize)> {
    use crate::h264::{nal_type, parse_sps, split_nals};
    for nal in split_nals(au) {
        if nal_type(nal) == 7 {
            if let Ok(sps) = parse_sps(nal) {
                if sps.width > 0 && sps.height > 0 {
                    return Some((sps.width as usize, sps.height as usize));
                }
            }
        }
    }
    None
}

/// BT.601 limited-range NV12 -> ARGB (matches the ffmpeg decoding matrix the
/// sender's encoder targets).
fn nv12_to_argb(nv12: &[u8], width: usize, height: usize, out: &mut Vec<u32>) {
    out.clear();
    out.resize(width * height, 0);
    let y_plane = &nv12[..width * height];
    let uv_plane = &nv12[width * height..];
    let uv_width = width / 2;
    for row in 0..height {
        let uv_row = (row / 2) * uv_width;
        for col in 0..width {
            let y = i32::from(y_plane[row * width + col]) - 16;
            let u = i32::from(uv_plane[(uv_row + col / 2) * 2]) - 128;
            let v = i32::from(uv_plane[(uv_row + col / 2) * 2 + 1]) - 128;
            let y = y.max(0);
            let r = ((298 * y + 409 * v + 128) >> 8).clamp(0, 255) as u32;
            let g = ((298 * y - 100 * u - 208 * v + 128) >> 8).clamp(0, 255) as u32;
            let b = ((298 * y + 516 * u + 128) >> 8).clamp(0, 255) as u32;
            out[row * width + col] = (r << 16) | (g << 8) | b;
        }
    }
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

/// Bilinear 2x2 sampling. Nearest-neighbour was the source of visible text
/// aliasing whenever the window is not an exact integer multiple of the
/// encoded size (e.g. 1728 -> 1920), which is the common case. Downscaling
/// uses a 2x2 box average instead, so shrinking never skips whole pixels.
fn scale_bilinear(
    src: &[u32],
    src_width: usize,
    src_height: usize,
    dst: &mut [u32],
    dst_stride: usize,
    dst_width: usize,
    dst_height: usize,
    ox: usize,
    oy: usize,
) {
    fn lerp(a: u32, b: u32, w: u32) -> u32 {
        let a0 = a & 0xff;
        let b0 = b & 0xff;
        let a1 = (a >> 8) & 0xff;
        let b1 = (b >> 8) & 0xff;
        let a2 = (a >> 16) & 0xff;
        let b2 = (b >> 16) & 0xff;
        let r = (a2 * (256 - w) + b2 * w) >> 8;
        let g = (a1 * (256 - w) + b1 * w) >> 8;
        let bl = (a0 * (256 - w) + b0 * w) >> 8;
        (r << 16) | (g << 8) | bl
    }

    fn avg4(pixels: [u32; 4]) -> u32 {
        let mut r = 0u32;
        let mut g = 0u32;
        let mut b = 0u32;
        for pixel in pixels {
            r += pixel >> 16 & 0xff;
            g += pixel >> 8 & 0xff;
            b += pixel & 0xff;
        }
        ((r / 4) << 16) | ((g / 4) << 8) | (b / 4)
    }

    if src_width == 0 || src_height == 0 || dst_width == 0 || dst_height == 0 || dst_stride < ox + dst_width {
        return;
    }
    // 1:1 fast path (window resized to exactly the encoded size, or the
    // integer-scaled case collapses to the same dimensions per row copy).
    if src_width == dst_width && src_height == dst_height {
        for y in 0..dst_height {
            let src_row = y * src_width;
            let dst_row = (oy + y) * dst_stride + ox;
            dst[dst_row..dst_row + dst_width].copy_from_slice(&src[src_row..src_row + src_width]);
        }
        return;
    }
    let step_x = ((src_width as u64) << 32) / dst_width as u64;
    let step_y = ((src_height as u64) << 32) / dst_height as u64;
    let downscale = src_width > dst_width || src_height > dst_height;
    let mut sy_acc = 0u64;
    for y in 0..dst_height {
        let sy = (sy_acc >> 32) as usize;
        let wy = ((sy_acc >> 24) & 0xff) as u32;
        sy_acc += step_y;
        let row1 = sy.min(src_height - 1) * src_width;
        let row2 = (sy + 1).min(src_height - 1) * src_width;
        let dst_row = (oy + y) * dst_stride + ox;
        let mut sx_acc = 0u64;
        for x in 0..dst_width {
            let sx = (sx_acc >> 32) as usize;
            let wx = ((sx_acc >> 24) & 0xff) as u32;
            sx_acc += step_x;
            let sx1 = sx.min(src_width - 1);
            let sx2 = (sx + 1).min(src_width - 1);
            dst[dst_row + x] = if downscale {
                avg4([src[row1 + sx1], src[row1 + sx2], src[row2 + sx1], src[row2 + sx2]])
            } else {
                let top = lerp(src[row1 + sx1], src[row1 + sx2], wx);
                let bottom = lerp(src[row2 + sx1], src[row2 + sx2], wx);
                lerp(top, bottom, wy)
            };
        }
    }
}

fn yuv_to_argb(yuv: &impl openh264::formats::YUVSource, width: usize, height: usize, out: &mut Vec<u32>) {    out.clear();
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

enum Delivery {
    Ok,
    Dropped,
    Closed,
}

/// Never blocks: when the decoder is behind, frames are dropped so the
/// network/reassembly path cannot accumulate seconds of latency.
fn deliver_frame(tx: &std::sync::mpsc::SyncSender<Delivered>, frame: Delivered) -> Delivery {
    match tx.try_send(frame) {
        Ok(()) => Delivery::Ok,
        Err(std::sync::mpsc::TrySendError::Full(_)) => Delivery::Dropped,
        Err(std::sync::mpsc::TrySendError::Disconnected(_)) => Delivery::Closed,
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
    let nack_enabled = std::env::var("ANYSHARE_NACK").map(|value| value != "0").unwrap_or(true);
    let mut nacks_sent: u64 = 0;
    let mut dropped_frames: u64 = 0;
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
                        match deliver_frame(&tx, frame) {
                            Delivery::Ok => {}
                            Delivery::Dropped => {
                                // The decoder is behind: drop and resync via
                                // the next keyframe instead of queueing latency.
                                dropped_frames += 1;
                                keyframe_request_pending = true;
                            }
                            Delivery::Closed => return Ok(()),
                        }
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                for frame in reassembler.poll(now) {
                    match deliver_frame(&tx, frame) {
                        Delivery::Ok => {}
                        Delivery::Dropped => {
                            dropped_frames += 1;
                            keyframe_request_pending = true;
                        }
                        Delivery::Closed => return Ok(()),
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
        if nack_enabled && peer_addr.is_some() && now.duration_since(last_nack_scan) >= Duration::from_millis(2) {
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
                        if socket.send_to(&nack.encode(), peer).is_ok() {
                            nacks_sent += 1;
                        }
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
                "recv: delivered={} lost={} recovered={} dup={} stale={} nacks={} dropped={}",
                stats.delivered,
                stats.lost_frames,
                stats.recovered_frames,
                stats.duplicate_packets,
                stats.stale_packets,
                nacks_sent,
                dropped_frames
            );
            last_stats = Instant::now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bilinear_upscale_blends_neighbours() {
        let src = [0x0000_0000u32, 0x00ff_ffffu32];
        let mut dst = [0u32; 4];
        scale_bilinear(&src, 2, 1, &mut dst, 4, 4, 1, 0, 0);
        // 2 -> 4 samples at source positions 0, 0.5, 1, 1.5 (clamped).
        assert_eq!(dst[0] & 0xff, 0);
        assert_eq!(dst[1] & 0xff, 127, "halfway between the two pixels");
        assert_eq!(dst[2] & 0xff, 0xff);
        assert_eq!(dst[3] & 0xff, 0xff);
    }

    #[test]
    fn downscale_averages_instead_of_skipping() {
        // Two dark / two bright columns shrink to two mid-grey pixels.
        let src = [0x0000_0000u32, 0x00ff_ffffu32, 0x0000_0000u32, 0x00ff_ffffu32];
        let mut dst = [0u32; 2];
        scale_bilinear(&src, 4, 1, &mut dst, 2, 2, 1, 0, 0);
        for pixel in dst {
            let luma = pixel & 0xff;
            assert!((0x60..=0xa0).contains(&luma), "expected blended grey, got {luma:#x}");
        }
    }

    #[test]
    fn exact_size_copy_and_empty_inputs() {
        let src = [0x0011_2233u32, 0x0044_5566u32, 0x0077_8899u32, 0x00aa_bbccu32];
        let mut dst = [0u32; 4];
        scale_bilinear(&src, 2, 2, &mut dst, 2, 2, 2, 0, 0);
        assert_eq!(dst, src);
        // Degenerate inputs must be no-ops, never panics.
        let mut empty = [0u32; 1];
        scale_bilinear(&[], 0, 0, &mut empty, 1, 1, 1, 0, 0);
        scale_bilinear(&src, 2, 2, &mut empty, 1, 1, 1, 5, 5);
        scale_bilinear(&src, 2, 2, &mut empty, 1, 0, 0, 0, 0);
        assert_eq!(empty[0], 0);
    }

    #[test]
    fn single_pixel_target_does_not_panic() {
        let src = [0x0012_3456u32; 4];
        let mut dst = [0u32; 1];
        scale_bilinear(&src, 2, 2, &mut dst, 1, 1, 1, 0, 0);
        assert_ne!(dst[0], 0);
    }
}