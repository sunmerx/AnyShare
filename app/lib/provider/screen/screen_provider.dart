import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/screen_capabilities.dart';
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

  /// Sender sessions: ask the encoder for an IDR. Receiver sessions and test
  /// doubles treat this as a no-op.
  Future<void> requestKeyframe() async {}

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
  Future<void> requestKeyframe() => _session.requestKeyframe();

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
  Future<void> requestKeyframe() async {
    // Receivers never serve keyframe requests (sender-side feature only).
  }

  @override
  Future<void> stop() => _session.stop();
}

final screenEngineProvider = Provider<ScreenEngine>((ref) => const FrbScreenEngine());

/// E2.0 platform capabilities as providers so tests can override them.
final screenSendSupportedProvider = Provider<bool>((ref) => canSendScreenShare());
final screenReceiveSupportedProvider = Provider<bool>((ref) => canReceiveScreenShare());

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

  /// Guards against overlapping offer handling (auto-accept engine start).
  bool startingOffer = false;

  /// Guards against double-accepting a pending offer (dialog re-entry).
  bool acceptingOffer = false;

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

  /// Attaches an engine session. Stops any previous engine session first so
  /// overlapping paths can never leak a live Rust session, then replaces the
  /// event subscription.
  Future<void> attach(String sessionId, ScreenEngineSession session) async {
    if (_engineSession != null) {
      await stopEngine();
    }
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

  /// Relays a receiver keyframe request to the local sender engine. Ignores
  /// stale session ids and non-sender roles (staleness/spoofing guard) and
  /// throttle one IDR per 500 ms per session (abuse guard: the endpoint is
  /// reachable by any host that knows the session id).
  Future<void> requestKeyframeFor(String sessionId) async {
    final active = state.active;
    if (active == null || active.role != ScreenRole.sender || active.sessionId != sessionId) {
      return;
    }
    final now = DateTime.now();
    final lastAt = _lastKeyframeRelayAt;
    if (_lastKeyframeRelaySession == sessionId && lastAt != null && now.difference(lastAt) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastKeyframeRelaySession = sessionId;
    _lastKeyframeRelayAt = now;
    final session = _engineSession;
    if (session == null) {
      return;
    }
    try {
      await session.requestKeyframe();
    } catch (e) {
      _logger.fine('requesting keyframe failed: $e');
    }
  }

  DateTime? _lastKeyframeRelayAt;
  String? _lastKeyframeRelaySession;

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
      await attach(id, session);
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
      return current.copyWith(clearWaiting: true, lastError: '${t.ui2.screen.errStartSenderFailed}:$e');
    }
  }

  /// Starts a receiver session; returns the new state or `null` on failure.
  /// Arms a watchdog: a session that never receives frames is torn down
  /// instead of leaving an empty window around.
  Future<ScreenState?> startReceiverSession(String peerIp, String peerAlias, String sessionId) async {
    try {
      final session = await ref.read(screenEngineProvider).startReceiver(port: kScreenDataPort);
      cancelTimer();
      await attach(sessionId, session);
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
      return state.copyWith(lastError: t.ui2.screen.errBusy);
    }
    if (peerIp.contains(':')) {
      // The engine's data plane is IPv4-only in E2.0 (callers should pass
      // screenShareHostOf(device), but keep the guard as a last line).
      return state.copyWith(lastError: t.ui2.screen.errIpv6);
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
        return await notifier.startSenderSession(peerIp, peerAlias, port, state.copyWith(clearError: true), sessionId: sessionId) ?? state;
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
        'blocked' => t.ui2.screen.errBlocked,
        'temp_not_allowed' => t.ui2.screen.errTempNotAllowed,
        'busy' => t.ui2.screen.errBusy,
        'rate_limited' => t.ui2.screen.errBusy,
        'receive_unsupported' => t.ui2.screen.errReceiveUnsupported,
        _ => status == null ? t.ui2.screen.errOffline : t.ui2.screen.errRejected(code: '$status'),
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
    // This platform cannot show a screen share (E2.0: Linux only): reject
    // early with a dedicated error instead of failing at engine start.
    if (!notifier.ref.read(screenReceiveSupportedProvider)) {
      return (state, const ScreenOfferResult(403, {'error': 'receive_unsupported'}));
    }
    if (state.active != null || state.pendingOffer != null || state.waiting != null || notifier.startingOffer) {
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
          notifier.ref.redux(screenProvider).dispatchAsync(AbortPendingScreenOfferAction(reason: 'timeout', sessionId: sessionId));
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
        notifier.startingOffer = true;
        try {
          final started = await notifier.startReceiverSession(peerIp, peerAlias, sessionId);
          return started != null
              ? (started, ScreenOfferResult(200, {'ok': true, 'port': kScreenDataPort, 'session': sessionId}))
              : (state, const ScreenOfferResult(500, {'error': 'engine_failed'}));
        } finally {
          notifier.startingOffer = false;
        }
    }
  }
}

/// Local user (or W3 dialog) accepted a pending offer: start the receiver and
/// tell the sender to begin.
class AcceptPendingScreenOfferAction extends AsyncReduxAction<ScreenService, ScreenState> {
  /// The offer session id the dialog was opened for; null accepts whatever is
  /// pending. A mismatch is a stale dialog and does nothing.
  final String? sessionId;

  AcceptPendingScreenOfferAction({this.sessionId});

  @override
  Future<ScreenState> reduce() async {
    final pending = state.pendingOffer;
    if (pending == null || (sessionId != null && pending.sessionId != sessionId) || notifier.acceptingOffer) {
      return state;
    }
    notifier.acceptingOffer = true;
    try {
      final started = await notifier.startReceiverSession(pending.peerIp, pending.peerAlias, pending.sessionId);
      if (started == null) {
        return state.copyWith(clearPendingOffer: true, lastError: t.ui2.screen.errStartReceiverFailed);
      }
      // A stop may have arrived while the engine was starting: do not
      // resurrect the session in that case.
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
        return state.copyWith(clearPendingOffer: true, lastError: t.ui2.screen.errNotifyFailed);
      }
      // A stop may also have arrived during the accept POST.
      if (notifier.state.pendingOffer?.sessionId != pending.sessionId) {
        await notifier.stopEngine();
        return notifier.state;
      }
      return started;
    } finally {
      notifier.acceptingOffer = false;
    }
  }
}

/// Local user (or timeout) declined a pending offer.
class AbortPendingScreenOfferAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String reason;

  /// The offer session id this abort belongs to; null aborts whatever is
  /// pending. A mismatch (stale dialog/timeout) does nothing.
  final String? sessionId;

  AbortPendingScreenOfferAction({this.reason = 'denied', this.sessionId});

  @override
  Future<ScreenState> reduce() async {
    final pending = state.pendingOffer;
    if (pending == null || (sessionId != null && pending.sessionId != sessionId)) {
      return state;
    }
    notifier.cancelTimer();
    // Fire-and-forget: clearing the pending state must not wait on the peer.
    unawaited(
      postScreenControl(pending.peerIp, notifier.controlPort, 'screen/stop', {
        'session': pending.sessionId,
        'reason': reason,
      }),
    );
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
      unawaited(
        postScreenControl(waiting.peerIp, notifier.controlPort, 'screen/stop', {
          'session': waiting.sessionId,
          'reason': 'user_stop',
        }),
      );
      return state.copyWith(clearWaiting: true);
    }
    notifier.cancelTimer();
    await notifier.stopEngine();
    // Fire-and-forget: local teardown is already done.
    unawaited(
      postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
        'session': active.sessionId,
        'reason': 'user_stop',
      }),
    );
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
/// Receiver asked the sender for an IDR after unrecovered loss.
class IncomingScreenKeyframeAction extends AsyncReduxAction<ScreenService, ScreenState> {
  final String sessionId;

  IncomingScreenKeyframeAction({required this.sessionId});

  @override
  Future<ScreenState> reduce() async {
    await notifier.requestKeyframeFor(sessionId);
    return state;
  }
}

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
      return state.copyWith(clearWaiting: true, lastError: t.ui2.screen.errCancelledByPeer);
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
    unawaited(
      postScreenControl(waiting.peerIp, notifier.controlPort, 'screen/stop', {
        'session': sessionId,
        'reason': 'timeout',
      }),
    );
    return state.copyWith(clearWaiting: true, lastError: t.ui2.screen.errNoResponse);
  }
}

/// Clears the last error shown in the UI banner (UI-2).
class ClearScreenErrorAction extends ReduxAction<ScreenService, ScreenState> {
  @override
  ScreenState reduce() => state.copyWith(clearError: true);
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
    return state.copyWith(clearActive: true, lastError: t.ui2.screen.errStreamEnded);
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
    unawaited(
      postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
        'session': sessionId,
        'reason': 'no_stream',
      }),
    );
    return state.copyWith(clearActive: true, lastError: t.ui2.screen.errNoStream);
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
      case ScreenSessionRequestKeyframe():
        // Receiver detected unrecovered loss: ask the sender for an IDR.
        // The Rust receiver already debounces (one per 500 ms), so this is
        // fire-and-forget.
        if (active.role == ScreenRole.receiver) {
          unawaited(
            postScreenControl(active.peerIp, notifier.controlPort, 'screen/keyframe', {
              'session': active.sessionId,
            }),
          );
        }
        return state;
      case ScreenSessionError(:final message):
        _logger.warning('screen session error: $message');
        return state.copyWith(lastError: message);
      case ScreenSessionEnded(:final reason):
        notifier.detach();
        notifier.cancelTimer();
        // Tell the peer (e.g. receiver window closed -> sender must stop).
        // Fire-and-forget: the local state must clear immediately.
        if (reason == 'windowclosed' || reason == 'error') {
          unawaited(
            postScreenControl(active.peerIp, notifier.controlPort, 'screen/stop', {
              'session': active.sessionId,
              'reason': reason,
            }),
          );
        }
        return state.copyWith(clearActive: true);
    }
  }
}
