import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/screen_trust.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// AnyShare modification (2026-10-17): E-2 screen share session state machine
/// (W2: no UI yet — the actions are the API the W3 UI drives).
///
/// Runs on the main isolate: control traffic is a few tiny requests and the
/// Rust side does all the heavy work on native threads.

final _logger = Logger('ScreenShare');

/// Data plane UDP port on the receiver (fixed for E2.0, decision D5).
const int kScreenDataPort = 53319;

/// Control plane port (the extension server, decision D3). Same value as
/// `kExtensionPort`, duplicated here to avoid an import cycle. Tests override
/// [screenControlPortProvider] to point at a stub peer.
const int kScreenControlPort = 53318;

final screenControlPortProvider = Provider<int>((ref) => kScreenControlPort);

/// How long a pending incoming offer waits for the local user, and how long
/// the sender waits for the receiver's accept.
const Duration kScreenOfferTtl = Duration(seconds: 60);

/// Session abstraction so tests can run without the Rust engine.
abstract class ScreenEngine {
  Future<ScreenEngineSession> startSender({required String host, required int port});

  Future<ScreenEngineSession> startReceiver({required int port});
}

abstract class ScreenEngineSession {
  Stream<ScreenSessionEvent> get events;

  Future<ScreenSessionStats?> stats();

  Future<void> stop();
}

/// The production engine: FRB-backed sessions (Rust native threads).
class FrbScreenEngine implements ScreenEngine {
  const FrbScreenEngine();

  @override
  Future<ScreenEngineSession> startSender({required String host, required int port}) async {
    return _SenderAdapter(await ScreenSenderSession.start(host: host, port: port));
  }

  @override
  Future<ScreenEngineSession> startReceiver({required int port}) async {
    return _ReceiverAdapter(await ScreenReceiverSession.start(port: port));
  }
}

class _SenderAdapter implements ScreenEngineSession {
  final ScreenSenderSession _session;

  _SenderAdapter(this._session);

  @override
  Stream<ScreenSessionEvent> get events => _session.events;

  @override
  Future<ScreenSessionStats?> stats() => _session.stats();

  @override
  Future<void> stop() => _session.stop();
}

class _ReceiverAdapter implements ScreenEngineSession {
  final ScreenReceiverSession _session;

  _ReceiverAdapter(this._session);

  @override
  Stream<ScreenSessionEvent> get events => _session.events;

  @override
  Future<ScreenSessionStats?> stats() => _session.stats();

  @override
  Future<void> stop() => _session.stop();
}

final screenEngineProvider = Provider<ScreenEngine>((ref) => const FrbScreenEngine());

enum ScreenRole { sender, receiver }

class ActiveScreenSession {
  final ScreenRole role;

  /// The other side of the session.
  final String peerIp;
  final String peerAlias;

  /// Correlation id (sender: generated locally; receiver: from the offer).
  final String sessionId;
  final DateTime startedAt;

  /// starting / listening / streaming / stopping.
  final String phase;
  final ScreenSessionStats? lastStats;

  const ActiveScreenSession({
    required this.role,
    required this.peerIp,
    required this.peerAlias,
    required this.sessionId,
    required this.startedAt,
    this.phase = 'starting',
    this.lastStats,
  });

  ActiveScreenSession copyWith({String? phase, ScreenSessionStats? lastStats}) {
    return ActiveScreenSession(
      role: role,
      peerIp: peerIp,
      peerAlias: peerAlias,
      sessionId: sessionId,
      startedAt: startedAt,
      phase: phase ?? this.phase,
      lastStats: lastStats ?? this.lastStats,
    );
  }
}

/// Incoming offer waiting for the local user to confirm (D2 limited/unknown).
class PendingScreenOffer {
  final String sessionId;
  final String peerIp;
  final String peerFingerprint;
  final String peerAlias;
  final DateTime createdAt;

  const PendingScreenOffer({
    required this.sessionId,
    required this.peerIp,
    required this.peerFingerprint,
    required this.peerAlias,
    required this.createdAt,
  });
}

/// Outgoing offer answered with `pending`; waiting for the receiver's accept.
class WaitingScreenAccept {
  final String sessionId;
  final String peerIp;
  final String peerAlias;

  const WaitingScreenAccept({
    required this.sessionId,
    required this.peerIp,
    required this.peerAlias,
  });
}

class ScreenState {
  final ActiveScreenSession? active;
  final PendingScreenOffer? pendingOffer;
  final WaitingScreenAccept? waiting;
  final String? lastError;

  const ScreenState({this.active, this.pendingOffer, this.waiting, this.lastError});

  ScreenState copyWith({
    ActiveScreenSession? active,
    PendingScreenOffer? pendingOffer,
    WaitingScreenAccept? waiting,
    String? lastError,
    bool clearActive = false,
    bool clearPendingOffer = false,
    bool clearWaiting = false,
    bool clearError = false,
  }) {
    return ScreenState(
      active: clearActive ? null : (active ?? this.active),
      pendingOffer: clearPendingOffer ? null : (pendingOffer ?? this.pendingOffer),
      waiting: clearWaiting ? null : (waiting ?? this.waiting),
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

final screenProvider = ReduxProvider<ScreenService, ScreenState>((ref) {
  return ScreenService(ref);
});

class ScreenService extends ReduxNotifier<ScreenState> {
  final Ref ref;

  ScreenService(this.ref);

  StreamSubscription<ScreenSessionEvent>? _subscription;
  ScreenEngineSession? _engineSession;
  Timer? _timer;

  /// Guards against double-tap starting two offers in flight.
  bool startingShare = false;

  @override
  ScreenState init() => const ScreenState();

  String get alias {
    final server = ref.read(serverProvider);
    if (server != null && server.alias.isNotEmpty && server.alias != '-') {
      return server.alias;
    }
    return ref.read(ownerProvider).name;
  }

  int get controlPort => ref.read(screenControlPortProvider);

  FavoriteDevice? lookupFavorite(String fingerprint) {
    for (final entry in ref.read(favoritesProvider)) {
      if (entry.fingerprint == fingerprint) {
        return entry;
      }
    }
    return null;
  }

  /// Attaches an engine session: replaces any previous subscription.
  void attach(String sessionId, ScreenEngineSession session) {
    unawaited(_subscription?.cancel());
    _engineSession = session;
    _subscription = session.events.listen(
      (event) {
        // ignore: discarded_futures
        ref.redux(screenProvider).dispatchAsync(_ScreenSessionEventAction(sessionId, event));
      },
      // Second line of defense: a Rust worker panic closes the stream without
      // an Ended event; the state must not stay stuck on an active session.
      onDone: () {
        // ignore: discarded_futures
        ref.redux(screenProvider).dispatchAsync(_ScreenStreamClosedAction(sessionId));
      },
    );
  }

  /// Drops the engine session without stopping it (it already ended).
  void detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _engineSession = null;
  }

  /// Stops the engine session (if any) and drops it.
  Future<void> stopEngine() async {
    final session = _engineSession;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _engineSession = null;
    if (session != null) {
      try {
        await session.stop();
      } catch (e) {
        _logger.fine('stopping engine session failed: $e');
      }
    }
  }

  void startTimer(Duration duration, void Function() onFire) {
    _timer?.cancel();
    _timer = Timer(duration, onFire);
  }

  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Starts a sender session; returns the new state or `null` on failure.
  /// [sessionId] comes from the receiver on auto-accept (so both sides
  /// correlate stops); generated locally otherwise.
  Future<ScreenState?> startSenderSession(
    String peerIp,
    String peerAlias,
    int port,
    ScreenState current, {
    String? sessionId,
  }) async {
    try {
      final session = await ref.read(screenEngineProvider).startSender(host: peerIp, port: port);
      final id = sessionId ?? const Uuid().v4();
      cancelTimer();
      attach(id, session);
      return current.copyWith(
        active: ActiveScreenSession(
          role: ScreenRole.sender,
          peerIp: peerIp,
          peerAlias: peerAlias,
          sessionId: id,
          startedAt: DateTime.now(),
        ),
        clearWaiting: true,
        clearError: true,
      );
    } catch (e) {
      _logger.warning('failed to start screen sender: $e');
      return current.copyWith(clearWaiting: true, lastError: '启动屏幕共享失败:$e');
    }
  }

  /// Starts a receiver session; returns the new state or `null` on failure.
  /// Arms a watchdog: a session that never receives frames is torn down
  /// instead of leaving an empty window around.
  Future<ScreenState?> startReceiverSession(String peerIp, String peerAlias, String sessionId) async {
    try {
      final session = await ref.read(screenEngineProvider).startReceiver(port: kScreenDataPort);
      cancelTimer();
      attach(sessionId, session);
      startTimer(const Duration(seconds: 15), () {
        // ignore: discarded_futures
        ref.redux(screenProvider).dispatchAsync(_ReceiverNoStreamWatchdogAction(sessionId));
      });
      return state.copyWith(
        active: ActiveScreenSession(
          role: ScreenRole.receiver,
          peerIp: peerIp,
          peerAlias: peerAlias,
          sessionId: sessionId,
          startedAt: DateTime.now(),
        ),
        clearPendingOffer: true,
        clearError: true,
      );
    } catch (e) {
      _logger.warning('failed to start screen receiver: $e');
      return null;
    }
  }
}

/// Best-effort control-plane POST; failures are logged and ignored.
Future<(int?, Map<String, dynamic>?)> postScreenControl(String ip, int port, String path, Map<String, dynamic> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final host = ip.contains(':') ? '[${ip.replaceAll('%', '%25')}]' : ip;
    final request = await client.postUrl(Uri.parse('http://$host:$port/api/anyshare/v1/$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>);
  } catch (e) {
    _logger.fine('screen control request $path to $ip:$port failed: $e');
    return (null, null);
  } finally {
    client.close(force: true);
  }
}

/// The receiver's decision, returned to the extension server endpoint.
class ScreenOfferResult {
  final int status;
  final Map<String, dynamic> body;

  const ScreenOfferResult(this.status, this.body);
}

/// Sender side: POST the offer, then either start streaming immediately
/// (auto-accept) or wait for the receiver's accept (pending).
class StartScreenShareAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String peerIp;
  final String peerAlias;

  StartScreenShareAction({required this.peerIp, required this.peerAlias});

  @override
  Future<ScreenState> reduce() async {
    if (state.active != null || state.waiting != null || notifier.startingShare) {
      return state.copyWith(lastError: 'busy');
    }
    if (peerIp.contains(':')) {
      // The engine's data plane is IPv4-only in E2.0.
      return state.copyWith(lastError: '对方地址为 IPv6,暂不支持屏幕共享');
    }
    notifier.startingShare = true;
    try {
      final (status, body) = await postScreenControl(peerIp, notifier.controlPort, 'screen/offer', {
        'fingerprint': notifier.ref.read(securityProvider).certificateHash,
        'ownerId': notifier.ref.read(ownerProvider).id,
        'ownerName': notifier.ref.read(ownerProvider).name,
        'alias': notifier.alias,
      });

      if (status == 200 && body?['ok'] == true) {
        final port = (body?['port'] as num?)?.toInt() ?? kScreenDataPort;
        final sessionId = body?['session'] as String?;
        return await notifier.startSenderSession(peerIp, peerAlias, port, state.copyWith(clearError: true), sessionId: sessionId) ??
            state;
      }
      if (status == 409 && body?['pending'] == true) {
        final sessionId = (body?['session'] as String?) ?? const Uuid().v4();
        notifier.startTimer(kScreenOfferTtl, () {
          // ignore: discarded_futures
          notifier.ref.redux(screenProvider).dispatchAsync(_ScreenWaitingTimeoutAction(sessionId));
        });
        return state.copyWith(
          waiting: WaitingScreenAccept(sessionId: sessionId, peerIp: peerIp, peerAlias: peerAlias),
          clearError: true,
        );
      }
      final error = switch (body?['error']) {
        'blocked' => '对方已拉黑本设备',
        'temp_not_allowed' => '对方不允许临时设备共享屏幕',
        'busy' => '对方正忙',
        'rate_limited' => '对方请求过于频繁,稍后再试',
        _ => status == null ? '无法连接对方(离线或未开启)' : '对方拒绝了屏幕共享($status)',
      };
      return state.copyWith(lastError: error);
    } finally {
      notifier.startingShare = false;
    }
  }
}

/// Receiver side: an offer arrived. Decides via the trust chain (D2), starts
/// the receiver immediately on auto-accept, or parks it as pending.
class HandleScreenOfferAction extends AsyncReduxActionWithResult<ScreenService, ScreenState, ScreenOfferResult> {
  final String peerIp;
  final String peerFingerprint;
  final String peerAlias;

  HandleScreenOfferAction({
    required this.peerIp,
    required this.peerFingerprint,
    required this.peerAlias,
  });

  @override
  Future<(ScreenState, ScreenOfferResult)> reduce() async {
    if (state.active != null || state.pendingOffer != null) {
      return (state, const ScreenOfferResult(409, {'error': 'busy'}));
    }
    final entry = notifier.lookupFavorite(peerFingerprint);
    final decision = evaluateScreenOffer(entry: entry, localOwnerId: notifier.ref.read(ownerProvider).id, peerIp: peerIp);

    switch (decision) {
      case ScreenOfferDecision.rejectBlocked:
        return (state, const ScreenOfferResult(403, {'error': 'blocked'}));
      case ScreenOfferDecision.rejectTemp:
        return (state, const ScreenOfferResult(403, {'error': 'temp_not_allowed'}));
      case ScreenOfferDecision.confirm:
        final sessionId = const Uuid().v4();
        notifier.startTimer(kScreenOfferTtl, () {
          // ignore: discarded_futures
          notifier.ref.redux(screenProvider).dispatchAsync(AbortPendingScreenOfferAction(reason: 'timeout'));
        });
        final next = state.copyWith(
          pendingOffer: PendingScreenOffer(
            sessionId: sessionId,
            peerIp: peerIp,
            peerFingerprint: peerFingerprint,
            peerAlias: peerAlias,
            createdAt: DateTime.now(),
          ),
          clearError: true,
        );
        return (next, ScreenOfferResult(409, {'pending': true, 'session': sessionId}));
      case ScreenOfferDecision.autoAccept:
        final sessionId = const Uuid().v4();
        final started = await notifier.startReceiverSession(peerIp, peerAlias, sessionId);
        return started != null
            ? (started, ScreenOfferResult(200, {'ok': true, 'port': kScreenDataPort, 'session': sessionId}))
            : (state, const ScreenOfferResult(500, {'error': 'engine_failed'}));
    }
  }
}

/// Local user (or W3 dialog) accepted a pending offer: start the receiver and
/// tell the sender to begin.
class AcceptPendingScreenOfferAction extends AsyncReduxAction<ScreenService, ScreenState> {
  @override
  Future<ScreenState> reduce() async {
    final pending = state.pendingOffer;
    if (pending == null) {
      return state;
    }
    final started = await notifier.startReceiverSession(pending.peerIp, pending.peerAlias, pending.sessionId);
    if (started == null) {
      return state.copyWith(clearPendingOffer: true, lastError: '启动接收失败');
    }
    // A stop may have arrived while the engine was starting: do not resurrect
    // the session in that case.
    if (notifier.state.pendingOffer?.sessionId != pending.sessionId) {
      await notifier.stopEngine();
      return notifier.state;
    }
    // The sender must learn that we are listening; retry once, then give up.
    var (status, _) = await postScreenControl(pending.peerIp, notifier.controlPort, 'screen/accept', {
      'session': pending.sessionId,
      'port': kScreenDataPort,
    });
    if (status == null) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      (status, _) = await postScreenControl(pending.peerIp, notifier.controlPort, 'screen/accept', {
        'session': pending.sessionId,
        'port': kScreenDataPort,
      });
    }
    if (status == null) {
      await notifier.stopEngine();
      return state.copyWith(clearPendingOffer: true, lastError: '无法通知对方开始共享');
    }
    // A stop may also have arrived during the accept POST.
    if (notifier.state.pendingOffer?.sessionId != pending.sessionId) {
      await notifier.stopEngine();
      return notifier.state;
    }
    return started;
  }
}

/// Local user (or timeout) declined a pending offer.
class AbortPendingScreenOfferAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String reason;

  AbortPendingScreenOfferAction({this.reason = 'denied'});

  @override
  Future<ScreenState> reduce() async {
    final pending = state.pendingOffer;
    notifier.cancelTimer();
    if (pending == null) {
      return state;
    }
    // Fire-and-forget: clearing the pending state must not wait on the peer.
    unawaited(postScreenControl(pending.peerIp, notifier.controlPort, 'screen/stop', {
      'session': pending.sessionId,
      'reason': reason,
    }));
    return state.copyWith(clearPendingOffer: true);
  }
}

/// Local user stops the active session (either role), or cancels a pending
/// outgoing offer; tells the peer.
class StopScreenShareAction extends AsyncReduxAction<ScreenService, ScreenState> {
  @override
  Future<ScreenState> reduce() async {
    final active = state.active;
    if (active == null) {
      final waiting = state.waiting;
      if (waiting == null) {
        return state;
      }
      notifier.cancelTimer();
      // Fire-and-forget: the receiver will time the offer out otherwise.
      unawaited(postScreenControl(waiting.peerIp, notifier.controlPort, 'screen/stop', {
        'session': waiting.sessionId,
        'reason': 'user_stop',
      }));
      return state.copyWith(clearWaiting: true);
    }
    notifier.cancelTimer();
    await notifier.stopEngine();
    // Fire-and-forget: local teardown is already done.
    unawaited(postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
      'session': active.sessionId,
      'reason': 'user_stop',
    }));
    return state.copyWith(clearActive: true);
  }
}

/// Sender side: the receiver accepted a pending offer.
class IncomingScreenAcceptAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;
  final int port;

  IncomingScreenAcceptAction({required this.sessionId, required this.port});

  @override
  Future<ScreenState> reduce() async {
    final waiting = state.waiting;
    if (waiting == null || waiting.sessionId != sessionId) {
      return state;
    }
    final started = await notifier.startSenderSession(
      waiting.peerIp,
      waiting.peerAlias,
      port,
      state.copyWith(clearWaiting: true, clearError: true),
    );
    if (started == null) {
      return state;
    }
    // A stop may have arrived while the engine was starting: do not resurrect
    // the session in that case.
    if (notifier.state.waiting?.sessionId != sessionId) {
      await notifier.stopEngine();
      return notifier.state;
    }
    return started;
  }
}

/// Either side: the peer stopped (or declined) the session. Only acts when the
/// `session` id matches (or is absent), so stale stops cannot kill a newer
/// session.
class IncomingScreenStopAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String reason;
  final String? session;

  IncomingScreenStopAction({this.reason = 'remote_stop', this.session});

  bool _matches(String id) => session == null || session == id;

  @override
  Future<ScreenState> reduce() async {
    final active = state.active;
    if (active != null) {
      if (!_matches(active.sessionId)) {
        return state;
      }
      notifier.cancelTimer();
      await notifier.stopEngine();
      return state.copyWith(clearActive: true);
    }
    final pending = state.pendingOffer;
    if (pending != null) {
      if (!_matches(pending.sessionId)) {
        return state;
      }
      notifier.cancelTimer();
      return state.copyWith(clearPendingOffer: true);
    }
    final waiting = state.waiting;
    if (waiting != null) {
      if (!_matches(waiting.sessionId)) {
        return state;
      }
      notifier.cancelTimer();
      return state.copyWith(clearWaiting: true, lastError: '对方取消了屏幕共享');
    }
    return state;
  }
}

/// Sender waiting for accept timed out.
class _ScreenWaitingTimeoutAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;

  _ScreenWaitingTimeoutAction(this.sessionId);

  @override
  Future<ScreenState> reduce() async {
    final waiting = state.waiting;
    if (waiting == null || waiting.sessionId != sessionId) {
      return state;
    }
    notifier.cancelTimer();
    // The receiver may still be listening (e.g. its accept was lost).
    unawaited(postScreenControl(waiting.peerIp, notifier.controlPort, 'screen/stop', {
      'session': sessionId,
      'reason': 'timeout',
    }));
    return state.copyWith(clearWaiting: true, lastError: '对方未响应');
  }
}

/// The engine event stream closed without an Ended event (worker panic): do
/// not leave a stuck active session behind.
class _ScreenStreamClosedAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;

  _ScreenStreamClosedAction(this.sessionId);

  @override
  Future<ScreenState> reduce() async {
    final active = state.active;
    if (active == null || active.sessionId != sessionId) {
      return state;
    }
    notifier.detach();
    return state.copyWith(clearActive: true, lastError: '屏幕共享会话意外结束');
  }
}

/// Receiver watchdog: no frame arrived within the grace period -> tear the
/// session down instead of leaving an empty window around.
class _ReceiverNoStreamWatchdogAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;

  _ReceiverNoStreamWatchdogAction(this.sessionId);

  @override
  Future<ScreenState> reduce() async {
    final active = state.active;
    if (active == null || active.sessionId != sessionId || active.lastStats != null) {
      return state;
    }
    await notifier.stopEngine();
    unawaited(postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
      'session': sessionId,
      'reason': 'no_stream',
    }));
    return state.copyWith(clearActive: true, lastError: '对方未开始传输画面');
  }
}

/// Session event from the Rust engine.
class _ScreenSessionEventAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;
  final ScreenSessionEvent event;

  _ScreenSessionEventAction(this.sessionId, this.event);

  @override
  Future<ScreenState> reduce() async {
    final active = state.active;
    if (active == null || active.sessionId != sessionId) {
      return state;
    }
    switch (event) {
      case ScreenSessionStatus(state: final phase):
        return state.copyWith(active: active.copyWith(phase: phase));
      case ScreenSessionStatsEvent(:final stats):
        // Frames are flowing: disarm the receiver watchdog.
        notifier.cancelTimer();
        return state.copyWith(active: active.copyWith(lastStats: stats));
      case ScreenSessionError(:final message):
        _logger.warning('screen session error: $message');
        return state.copyWith(lastError: message);
      case ScreenSessionEnded(:final reason):
        notifier.detach();
        notifier.cancelTimer();
        // Tell the peer (e.g. receiver window closed -> sender must stop).
        // Fire-and-forget: the local state must clear immediately.
        if (reason == 'windowclosed' || reason == 'error') {
          unawaited(postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
            'session': active.sessionId,
            'reason': reason,
          }));
        }
        return state.copyWith(clearActive: true);
    }
  }
}
