/// AnyShare modification (2026-10-17): E-2 screen sharing — Dart-facing
/// wrapper around the FRB screen session API (rust/api/screen.dart).
///
/// The whole pipeline (capture/encode/send on Windows, receive/decode/window
/// on desktop Linux) runs in Rust native threads. This wrapper only exposes
/// start/stop, a typed event stream and the latest statistics.
library;

import 'package:localsend_isolates/rust/api/screen.dart' as rust;

/// Dart-side session statistics (mirrors [rust.RsScreenStats]).
class ScreenSessionStats {
  /// Sender: encoded frames (last window). Receiver: decoded frames (last window).
  final int frames;

  /// Sender: keyframes sent (last window).
  final int keyframes;

  /// Sender: encoded fps. Receiver: displayed fps.
  final double fps;

  /// Sender: payload bitrate of the last window.
  final double mbps;

  /// Sender: packets sent (last window). Receiver: frames delivered (total).
  final int packets;

  /// Receiver: frames lost (total).
  final int lost;

  /// Receiver: decode errors (total).
  final int decodeErrors;

  const ScreenSessionStats({
    required this.frames,
    required this.keyframes,
    required this.fps,
    required this.mbps,
    required this.packets,
    required this.lost,
    required this.decodeErrors,
  });
}

/// Physical size of the local monitor (receiver side).
class ScreenSize {
  final int width;
  final int height;

  const ScreenSize(this.width, this.height);

  @override
  String toString() => "${width}x$height";
}

sealed class ScreenSessionEvent {
  const ScreenSessionEvent();
}

/// Lifecycle: starting / listening / streaming / stopping.
class ScreenSessionStatus extends ScreenSessionEvent {
  final String state;

  const ScreenSessionStatus(this.state);
}

class ScreenSessionStatsEvent extends ScreenSessionEvent {
  final ScreenSessionStats stats;

  const ScreenSessionStatsEvent(this.stats);
}

/// reason: stopped / windowclosed / error.
class ScreenSessionEnded extends ScreenSessionEvent {
  final String reason;

  const ScreenSessionEnded(this.reason);
}

class ScreenSessionError extends ScreenSessionEvent {
  final String message;

  const ScreenSessionError(this.message);
}

/// Receiver only: unrecovered loss detected. The app relays this to the
/// sender's control plane so it emits an IDR.
class ScreenSessionRequestKeyframe extends ScreenSessionEvent {
  const ScreenSessionRequestKeyframe();
}

ScreenSessionEvent _convert(rust.RsScreenEvent event) {
  return switch (event) {
    rust.RsScreenEvent_RequestKeyframe() => const ScreenSessionRequestKeyframe(),
    rust.RsScreenEvent_Status(:final state) => ScreenSessionStatus(state),
    rust.RsScreenEvent_Stats(:final frames, :final keyframes, :final fps, :final mbps, :final packets, :final lost, :final decodeErrors) =>
      ScreenSessionStatsEvent(
        ScreenSessionStats(
          frames: frames.toInt(),
          keyframes: keyframes.toInt(),
          fps: fps,
          mbps: mbps,
          packets: packets.toInt(),
          lost: lost.toInt(),
          decodeErrors: decodeErrors.toInt(),
        ),
      ),
    rust.RsScreenEvent_Ended(:final reason) => ScreenSessionEnded(reason),
    rust.RsScreenEvent_Error(:final message) => ScreenSessionError(message),
  };
}

ScreenSessionStats? _convertStats(rust.RsScreenStats? stats) {
  if (stats == null) {
    return null;
  }
  return ScreenSessionStats(
    frames: stats.frames.toInt(),
    keyframes: stats.keyframes.toInt(),
    fps: stats.fps,
    mbps: stats.mbps,
    packets: stats.packets.toInt(),
    lost: stats.lost.toInt(),
    decodeErrors: stats.decodeErrors.toInt(),
  );
}

/// Sends this device's screen to a remote receiver (Windows in E2.0).
class ScreenSenderSession {
  final rust.RsScreenSender _inner;

  ScreenSenderSession._(this._inner);

  static Future<ScreenSenderSession> start({required String host, required int port, int? maxWidth, int? maxHeight}) async {
    return ScreenSenderSession._(
      await rust.startScreenSender(host: host, port: port, maxWidth: maxWidth ?? 0, maxHeight: maxHeight ?? 0),
    );
  }

  /// Emits events until the session ends (can only be listened to once).
  Stream<ScreenSessionEvent> get events => _inner.listen().map(_convert);

  Future<ScreenSessionStats?> stats() async => _convertStats(await _inner.stats());

  /// Asks the encoder for an IDR (receiver loss recovery).
  Future<void> requestKeyframe() => _inner.requestKeyframe();

  /// Requests a new encoder bitrate (adaptive quality feedback).
  Future<void> setBitrate(int bitrateBps) => _inner.setBitrate(bitrateBps: bitrateBps);

  /// Caps the encoder frame rate (the receiver reports what it can decode).
  Future<void> setMaxFps(int fps) => _inner.setMaxFps(fps: fps);

  Future<void> stop() => _inner.stop();
}

/// Receives and displays a remote screen in a native window (desktop Linux in
/// E2.0; VAAPI decoder).
class ScreenReceiverSession {
  final rust.RsScreenReceiver _inner;

  ScreenReceiverSession._(this._inner);

  static Future<ScreenReceiverSession> start({required int port}) async {
    return ScreenReceiverSession._(await rust.startScreenReceiver(port: port));
  }

  /// Emits events until the session ends (window closed, stopped or failed;
  /// can only be listened to once).
  Stream<ScreenSessionEvent> get events => _inner.listen().map(_convert);

  Future<ScreenSessionStats?> stats() async => _convertStats(await _inner.stats());

  /// Physical size of the local monitor, once the window exists. The app
  /// reports it to the sender so the encode resolution can match 1:1.
  Future<ScreenSize?> monitorSize() async {
    final size = await _inner.monitorSize();
    return size == null ? null : ScreenSize(size.width.toInt(), size.height.toInt());
  }

  Future<void> stop() => _inner.stop();
}
