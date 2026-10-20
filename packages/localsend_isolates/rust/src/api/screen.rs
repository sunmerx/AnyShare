//! Screen sharing bridge (E-2). The heavy pipeline runs inside the
//! screen-stream crate on native threads; this layer only starts/stops
//! sessions and forwards events to Dart.
//!
//! The API surface is identical on every platform; on non-desktop targets
//! starting a session fails with a "not supported" error at runtime.

#[cfg(desktop)]
use std::sync::Mutex;

use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

/// Lifecycle event of a screen session.
#[derive(Debug, Clone)]
pub enum RsScreenEvent {
    /// `state`: starting / listening / streaming / stopping.
    Status { state: String },
    /// Per-second statistics (fields that do not apply are 0).
    Stats {
        frames: u64,
        keyframes: u64,
        fps: f64,
        mbps: f64,
        packets: u64,
        lost: u64,
        decode_errors: u64,
    },
    /// `reason`: stopped / windowclosed / error.
    Ended { reason: String },
    Error { message: String },
    /// Receiver only: unrecovered loss detected; the app relays this to the
    /// sender's `/screen/keyframe` endpoint (Rust debounces to 500 ms).
    RequestKeyframe,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct RsScreenStats {
    pub frames: u64,
    pub keyframes: u64,
    pub fps: f64,
    pub mbps: f64,
    pub packets: u64,
    pub lost: u64,
    pub decode_errors: u64,
}

#[frb(opaque)]
pub struct RsScreenSender {
    #[cfg(target_os = "windows")]
    inner: Mutex<SenderInner>,
    #[cfg(not(target_os = "windows"))]
    _unsupported: (),
}

#[cfg(target_os = "windows")]
struct SenderInner {
    handle: Option<screen_stream::sender::SenderHandle>,
    events: Option<std::sync::mpsc::Receiver<screen_stream::events::StreamEvent>>,
}

#[frb(opaque)]
pub struct RsScreenReceiver {
    #[cfg(desktop)]
    inner: Mutex<ReceiverInner>,
    #[cfg(not(desktop))]
    _unsupported: (),
}

#[cfg(desktop)]
struct ReceiverInner {
    handle: Option<screen_stream::receiver::ReceiverHandle>,
    events: Option<std::sync::mpsc::Receiver<screen_stream::events::StreamEvent>>,
}

/// Starts sending this device's screen to `host:port` (the receiver's data
/// plane). The screen is auto-picked (smallest attached output) until output
/// selection is exposed; fixed 1080p60/8Mbps per the E2.0 decision.
pub fn start_screen_sender(host: String, port: u16) -> anyhow::Result<RsScreenSender> {
    #[cfg(target_os = "windows")]
    {
        let (tx, rx) = std::sync::mpsc::channel();
        let config = screen_stream::sender::SenderConfig {
            target: format!("{host}:{port}"),
            ..Default::default()
        };
        let handle = screen_stream::sender::start_sender(config, tx)?;
        Ok(RsScreenSender {
            inner: Mutex::new(SenderInner {
                handle: Some(handle),
                events: Some(rx),
            }),
        })
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (host, port);
        anyhow::bail!("screen sending requires Windows (E2.0)")
    }
}

/// Starts listening for an incoming screen stream on `port` and shows it in a
/// dedicated native window. Linux uses the native VAAPI decoder.
pub fn start_screen_receiver(port: u16) -> anyhow::Result<RsScreenReceiver> {
    #[cfg(desktop)]
    {
        // The minifb window is created on a worker thread; that is validated
        // on Linux/Windows only (AppKit wants the main thread).
        if cfg!(target_os = "macos") {
            anyhow::bail!("screen receiving is not supported on macOS yet");
        }
        let (tx, rx) = std::sync::mpsc::channel();
        let config = screen_stream::receiver::ReceiverConfig {
            port,
            ..Default::default()
        };
        let handle = screen_stream::receiver::start_receiver(config, tx)?;
        Ok(RsScreenReceiver {
            inner: Mutex::new(ReceiverInner {
                handle: Some(handle),
                events: Some(rx),
            }),
        })
    }
    #[cfg(not(desktop))]
    {
        let _ = port;
        anyhow::bail!("screen receiving is not supported on this platform yet")
    }
}

#[cfg(desktop)]
fn map_event(event: screen_stream::events::StreamEvent) -> Option<RsScreenEvent> {
    use screen_stream::events::StreamEvent;
    match event {
        StreamEvent::RequestKeyframe => Some(RsScreenEvent::RequestKeyframe),
        StreamEvent::Status(state) => Some(RsScreenEvent::Status {
            state: format!("{state:?}").to_lowercase(),
        }),
        StreamEvent::Stats(stats) => Some(RsScreenEvent::Stats {
            frames: stats.frames,
            keyframes: stats.keyframes,
            fps: stats.fps,
            mbps: stats.mbps,
            packets: stats.packets,
            lost: stats.lost,
            decode_errors: stats.decode_errors,
        }),
        StreamEvent::Ended(reason) => Some(RsScreenEvent::Ended {
            reason: format!("{reason:?}").to_lowercase(),
        }),
        StreamEvent::Error(message) => Some(RsScreenEvent::Error { message }),
    }
}

impl RsScreenSender {
    /// Emits session events until the session ends. Can only be listened to
    /// once.
    ///
    /// Note: this holds the opaque object's read guard for the whole session;
    /// do not add `&mut self` methods to this type (they would deadlock until
    /// the session ends).
    pub async fn listen(&self, sink: StreamSink<RsScreenEvent>) {
        #[cfg(target_os = "windows")]
        {
            let rx = self.inner.lock().unwrap().events.take();
            let Some(rx) = rx else {
                let _ = sink.add_error(anyhow::anyhow!("Sender events already listened to"));
                return;
            };
            let _ = tokio::task::spawn_blocking(move || {
                while let Ok(event) = rx.recv() {
                    let Some(event) = map_event(event) else { continue };
                    if sink.add(event).is_err() {
                        break;
                    }
                }
            })
            .await;
        }
        #[cfg(not(target_os = "windows"))]
        {
            let _ = sink.add_error(anyhow::anyhow!("screen sending requires Windows (E2.0)"));
        }
    }

    /// Stops the session; the join happens on a background thread so the
    /// caller is never blocked.
    pub fn stop(&self) {
        #[cfg(target_os = "windows")]
        {
            let handle = self.inner.lock().unwrap().handle.take();
            if let Some(handle) = handle {
                std::thread::spawn(move || handle.join());
            }
        }
    }

    pub fn stats(&self) -> Option<RsScreenStats> {
        #[cfg(target_os = "windows")]
        {
            let inner = self.inner.lock().unwrap();
            return inner.handle.as_ref().map(|handle| {
                let stats = handle.stats();
                RsScreenStats {
                    frames: stats.frames,
                    keyframes: stats.keyframes,
                    fps: stats.fps,
                    mbps: stats.mbps,
                    packets: stats.packets,
                    lost: stats.lost,
                    decode_errors: stats.decode_errors,
                }
            });
        }
        #[cfg(not(target_os = "windows"))]
        {
            None
        }
    }

    /// Asks the encoder for an IDR on the next frame (the receiver's loss
    /// recovery request, relayed by the app control plane). Safe to call while
    /// `listen` is running: it only touches the handle.
    pub fn request_keyframe(&self) {
        #[cfg(target_os = "windows")]
        {
            let inner = self.inner.lock().unwrap();
            if let Some(handle) = inner.handle.as_ref() {
                handle.request_keyframe();
            }
        }
    }

    /// Requests a new encoder bitrate (the receiver's adaptive-quality
    /// feedback, relayed by the app control plane). Safe to call while
    /// `listen` runs.
    pub fn set_bitrate(&self, bitrate_bps: u32) {
        #[cfg(target_os = "windows")]
        {
            let inner = self.inner.lock().unwrap();
            if let Some(handle) = inner.handle.as_ref() {
                handle.set_bitrate(bitrate_bps);
            }
        }
        #[cfg(not(target_os = "windows"))]
        {
            let _ = bitrate_bps;
        }
    }
}

impl RsScreenReceiver {
    /// Emits session events until the session ends (window closed, stopped or
    /// failed). Can only be listened to once.
    ///
    /// Note: this holds the opaque object's read guard for the whole session;
    /// do not add `&mut self` methods to this type (they would deadlock until
    /// the session ends).
    pub async fn listen(&self, sink: StreamSink<RsScreenEvent>) {
        #[cfg(desktop)]
        {
            let rx = self.inner.lock().unwrap().events.take();
            let Some(rx) = rx else {
                let _ = sink.add_error(anyhow::anyhow!("Receiver events already listened to"));
                return;
            };
            let _ = tokio::task::spawn_blocking(move || {
                while let Ok(event) = rx.recv() {
                    let Some(event) = map_event(event) else { continue };
                    if sink.add(event).is_err() {
                        break;
                    }
                }
            })
            .await;
        }
        #[cfg(not(desktop))]
        {
            let _ = sink.add_error(anyhow::anyhow!("screen receiving is not supported on this platform yet"));
        }
    }

    /// Stops the session (closes the window); the join happens on a background
    /// thread so the caller is never blocked.
    pub fn stop(&self) {
        #[cfg(desktop)]
        {
            let handle = self.inner.lock().unwrap().handle.take();
            if let Some(handle) = handle {
                std::thread::spawn(move || handle.join());
            }
        }
    }

    pub fn stats(&self) -> Option<RsScreenStats> {
        #[cfg(desktop)]
        {
            let inner = self.inner.lock().unwrap();
            return inner.handle.as_ref().map(|handle| {
                let stats = handle.stats();
                RsScreenStats {
                    frames: stats.frames,
                    keyframes: stats.keyframes,
                    fps: stats.fps,
                    mbps: stats.mbps,
                    packets: stats.packets,
                    lost: stats.lost,
                    decode_errors: stats.decode_errors,
                }
            });
        }
        #[cfg(not(desktop))]
        {
            None
        }
    }
}
