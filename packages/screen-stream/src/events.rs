//! Session events shared by the sender and receiver handles.

use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamState {
    Starting,
    Listening,
    Streaming,
    Stopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    /// The session was ended by a stop request (app or timer).
    Stopped,
    /// The viewer window was closed by the user (receiver only).
    WindowClosed,
    /// The session ended because of an error (an `Error` event precedes it).
    Error,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct StreamStats {
    /// Sender: frames encoded and sent in the last window.
    /// Receiver: frames decoded in the last window.
    pub frames: u64,
    /// Sender: keyframes sent in the last window.
    pub keyframes: u64,
    /// Sender: encoded frames per second (last window).
    /// Receiver: frames displayed per second (last window).
    pub fps: f64,
    /// Sender: payload bitrate in the last window.
    pub mbps: f64,
    /// Sender: packets sent in the last window.
    /// Receiver: frames delivered in total.
    pub packets: u64,
    /// Receiver: frames lost (never recovered) in total.
    pub lost: u64,
    /// Receiver: decode errors in total.
    pub decode_errors: u64,
}

#[derive(Debug, Clone)]
pub enum StreamEvent {
    Status(StreamState),
    Stats(StreamStats),
    Ended(EndReason),
    Error(String),
}

/// A session runs until stopped, or for [Self::duration] when set.
pub type SessionDuration = Option<Duration>;
