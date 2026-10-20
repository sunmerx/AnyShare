import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/dir_endpoints.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/qr_pairing_provider.dart';
import 'package:localsend_app/provider/screen/screen_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/sas.dart';
import 'package:localsend_app/widget/dialogs/pairing_dialog.dart';
import 'package:localsend_app/widget/dialogs/screen_offer_dialog.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';

/// AnyShare modification (2026-10-12): the AnyShare extension server (design:
/// docs/扩展协议设计.md §2, as amended — probe-based discovery over plain
/// HTTP, SAS-bound pairing, TLS deferred).
///
/// Endpoints under `/api/anyshare/v1/`:
/// - `GET  /capabilities` → `{ext, sas, fingerprint, alias, ownerName}`
/// - `POST /pair/register` → `{session, code, eph, alias, ownerName, fingerprint}`
/// - `POST /pair/confirm` → `{ok, ownerId, ownerName, alias, fingerprint}`
///
/// Runs on the main isolate: pairing traffic is a few tiny requests, well
/// below the "heavy networking" threshold that requires child isolates.
final _logger = Logger('ExtensionServer');

const int kExtensionPort = 53318;
const int kMaxBodyBytes = 64 * 1024;
const Duration kPendingTtl = Duration(minutes: 5);

class PendingPairing {
  final String sessionId;
  final String code; // SAS shown to the local user
  final String peerFingerprint;
  final String peerAlias;
  final String ip; // initiator address, captured at register time
  final int peerPort; // peer's main protocol port (for the favorite entry)
  final bool peerHttps;
  final SimpleKeyPair ephKeyPair; // local ephemeral key pair
  final DateTime createdAt;
  bool aborted = false;

  /// Completes when the local user taps "codes match" (true) or
  /// "codes differ" / closes (false). The remote confirm request waits on
  /// this gate, so pairing only finishes if BOTH users accepted the SAS
  /// comparison — a one-sided accept cannot complete the pairing.
  final Completer<bool> userGate = Completer<bool>();

  PendingPairing({
    required this.sessionId,
    required this.code,
    required this.peerFingerprint,
    required this.peerAlias,
    required this.ip,
    required this.peerPort,
    required this.peerHttps,
    required this.ephKeyPair,
    required this.createdAt,
  });
}

class ExtensionServerState {
  final HttpServer? server;
  final int? port;

  /// Currently pending incoming pairing (shown as a dialog on this device).
  final PendingPairing? pending;

  const ExtensionServerState({this.server, this.port, this.pending});
}

final extensionServerProvider = ReduxProvider<ExtensionServerService, ExtensionServerState>((ref) {
  return ExtensionServerService(ref);
});

class ExtensionServerService extends ReduxNotifier<ExtensionServerState> {
  final Ref ref;

  ExtensionServerService(this.ref);

  @override
  ExtensionServerState init() {
    // Starting happens via [StartExtensionServerAction] dispatched from
    // preInit — dispatching to this provider from inside init() recurses
    // into init() forever (refena initializes the notifier on dispatch).
    return const ExtensionServerState();
  }

  String get _alias {
    final server = ref.read(serverProvider);
    if (server != null && server.alias.isNotEmpty && server.alias != '-') {
      return server.alias;
    }
    return ref.read(ownerProvider).name; // falls back to '' when unset
  }

  final Map<String, List<DateTime>> _rateWindow = {};
  final Map<String, DateTime> _rateLockedUntil = {};
}

class StartExtensionServerAction extends AsyncReduxAction<ExtensionServerService, ExtensionServerState> {
  StartExtensionServerAction({this.port = kExtensionPort});

  /// Ephemeral port (0) for tests.
  final int port;

  @override
  Future<ExtensionServerState> reduce() async {
    if (state.server != null) {
      return state;
    }
    try {
      // Dual-stack: anyIPv6 with v6Only=false (default) also accepts IPv4,
      // so peers that discovered us via link-local IPv6 can still pair.
      final server = await HttpServer.bind(InternetAddress.anyIPv6, port, shared: true);
      _logger.info('Extension server listening on $kExtensionPort');
      // ignore: discarded_futures
      server.listen((request) async {
        try {
          await notifier._handle(request);
        } catch (e, st) {
          _logger.fine('Extension request error: $e\n$st');
        }
      });
      return ExtensionServerState(server: server, port: server.port, pending: state.pending);
    } catch (e) {
      _logger.warning('Extension server could not bind port $kExtensionPort: $e');
      return state;
    }
  }
}

/// Local user tapped "codes differ" / closed the incoming pairing dialog.
class AbortPendingPairingAction extends ReduxAction<ExtensionServerService, ExtensionServerState> {
  AbortPendingPairingAction();

  @override
  ExtensionServerState reduce() {
    final pending = state.pending;
    if (pending != null) {
      pending.aborted = true;
      if (!pending.userGate.isCompleted) {
        pending.userGate.complete(false);
      }
    }
    // pending is PRESERVED (aborted): the in-flight confirm long-poll reads
    // it to resolve with `not_confirmed` instead of `no_pending`.
    return ExtensionServerState(server: state.server, port: state.port, pending: pending);
  }
}

/// Local user tapped "codes match": persists the peer (temp trust).
class AcceptPendingPairingAction extends AsyncReduxAction<ExtensionServerService, ExtensionServerState> {
  AcceptPendingPairingAction();

  @override
  Future<ExtensionServerState> reduce() async {
    final pending = state.pending;
    if (pending == null || pending.aborted) {
      return state;
    }
    if (!pending.userGate.isCompleted) {
      pending.userGate.complete(true);
    }
    // Persistence happens ONLY in the confirm handler: it is the single
    // place that also knows the initiator's ownerId/ownerName (required by
    // the same-owner rule) — accepting here as well would create a
    // duplicate favorite without the owner link.
    // pending is PRESERVED: the in-flight confirm long-poll still needs it.
    return ExtensionServerState(server: state.server, port: state.port, pending: pending);
  }
}

class _SetPendingAction extends ReduxAction<ExtensionServerService, ExtensionServerState> {
  final PendingPairing? pending;

  _SetPendingAction(this.pending);

  @override
  ExtensionServerState reduce() => ExtensionServerState(server: state.server, port: state.port, pending: pending);
}

class _ClearPendingAction extends ReduxAction<ExtensionServerService, ExtensionServerState> {
  _ClearPendingAction();

  @override
  ExtensionServerState reduce() => ExtensionServerState(server: state.server, port: state.port);
}

extension ExtensionServerHandler on ExtensionServerService {
  String get alias => _alias;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'GET' && path == '/api/anyshare/v1/capabilities') {
      await writeJson(request, {
        'ext': 1,
        'sas': true,
        'fingerprint': ref.read(securityProvider).certificateHash,
        'alias': alias,
        'ownerName': ref.read(ownerProvider).name,
      });
      return;
    }

    // AnyShare modification (2026-10-18): E-3 shared directory endpoints
    // (own rate limiter; JSON and binary).
    if (await handleDirRequest(request)) {
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/screen/accept') {
      // The receiver confirmed a pending offer and is listening now.
      // Exempt from the shared rate limiter: session callbacks are bursty and
      // a 429 here would silently break an accepted session.
      try {
        final body = await readJsonBody(request);
        if (body == null || body['session'] is! String) {
          await writeJson(request, {'error': 'bad_request'}, status: 400);
          return;
        }
        await ref
            .redux(screenProvider)
            .dispatchAsync(
              IncomingScreenAcceptAction(
                sessionId: body['session'] as String,
                port: (body['port'] as num?)?.toInt() ?? kScreenDataPort,
              ),
            );
        await writeJson(request, {'ok': true});
      } catch (e, st) {
        _logger.warning('screen/accept failed: $e\n$st');
        await writeJson(request, {'error': 'internal'}, status: 500);
      }
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/screen/keyframe') {
      // The receiver detected unrecovered loss and asks us to emit an IDR.
      // Exempt from the rate limiter (see accept); the app throttles to one
      // IDR per 500 ms per session and the request must come from the peer
      // that owns the active sender session.
      try {
        final body = await readJsonBody(request);
        if (body == null || body['session'] is! String) {
          await writeJson(request, {'error': 'bad_request'}, status: 400);
          return;
        }
        final active = ref.read(screenProvider).active;
        if (active == null || active.role != ScreenRole.sender) {
          await writeJson(request, {'error': 'no_session'}, status: 409);
          return;
        }
        final remote = request.connectionInfo?.remoteAddress.address;
        if (remote != null && _normalizedIp(remote) != _normalizedIp(active.peerIp)) {
          await writeJson(request, {'error': 'forbidden'}, status: 403);
          return;
        }
        await ref.redux(screenProvider).dispatchAsync(IncomingScreenKeyframeAction(sessionId: body['session'] as String));
        await writeJson(request, {'ok': true});
      } catch (e, st) {
        _logger.warning('screen/keyframe failed: $e\n$st');
        await writeJson(request, {'error': 'internal'}, status: 500);
      }
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/screen/stop') {
      // Either side ends the session (user stop, denial, window closed, ...).
      // Also exempt from the rate limiter (see accept).
      try {
        final body = await readJsonBody(request);
        await ref
            .redux(screenProvider)
            .dispatchAsync(
              IncomingScreenStopAction(
                reason: (body?['reason'] as String?) ?? 'remote_stop',
                session: body?['session'] as String?,
              ),
            );
        await writeJson(request, {'ok': true});
      } catch (e, st) {
        _logger.warning('screen/stop failed: $e\n$st');
        await writeJson(request, {'error': 'internal'}, status: 500);
      }
      return;
    }

    if (_rateLimited(request)) {
      await writeJson(request, {'error': 'rate_limited'}, status: 429);
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/pair/register') {
      final body = await readJsonBody(request);
      if (body == null || body['eph'] is! String) {
        await writeJson(request, {'error': 'bad_request'}, status: 400);
        return;
      }
      // F-PAIR-08: QR-originated registrations must carry the displayer's
      // current one-time token. This is replay protection for honest scanners,
      // not an auth gate — token-less manual pairing keeps working (SAS
      // confirmation still gates every pairing).
      final qrToken = body['qrToken'];
      if (qrToken != null) {
        final qrState = ref.read(qrPairingProvider);
        if (qrToken is! String || !qrState.isValidToken(qrToken)) {
          await writeJson(request, {'error': 'invalid_token'}, status: 403);
          return;
        }
        // Rotate immediately: the used token must not be replayable.
        ref.redux(qrPairingProvider).dispatch(StartQrPairingAction());
      }
      final pending = ref.read(extensionServerProvider).pending;
      if (pending != null && !pending.aborted && DateTime.now().difference(pending.createdAt) < kPendingTtl) {
        await writeJson(request, {'error': 'busy'}, status: 409);
        return;
      }

      final String peerEphB64 = body['eph'] as String;
      final localFingerprint = ref.read(securityProvider).certificateHash;
      final keyPair = await SasCrypto.generateKeyPair();
      final localPub = await keyPair.extractPublicKey();
      final sessionId = const Uuid().v4();
      final code = await SasCrypto.deriveCode(
        sharedSecret: await SasCrypto.deriveSharedSecret(keyPair: keyPair, peerPublicKey: base64Decode(peerEphB64)),
        sessionId: sessionId,
        fingerprintA: (body['fingerprint'] as String?) ?? '',
        fingerprintB: localFingerprint,
      );

      final newPending = PendingPairing(
        sessionId: sessionId,
        code: code,
        peerFingerprint: (body['fingerprint'] as String?) ?? '',
        peerAlias: (body['alias'] as String?) ?? '???',
        ip: request.connectionInfo!.remoteAddress.address.replaceAll('::ffff:', ''),
        peerPort: (body['port'] as num?)?.toInt() ?? 53317,
        peerHttps: body['https'] == true,
        ephKeyPair: keyPair,
        createdAt: DateTime.now(),
      );
      ref.redux(extensionServerProvider).dispatch(_SetPendingAction(newPending));

      await writeJson(request, {
        'session': sessionId,
        'eph': base64Encode(localPub.bytes),
        'code': code,
        'alias': alias,
        'ownerName': ref.read(ownerProvider).name,
        'fingerprint': localFingerprint,
      });

      // Show the SAS dialog on this device (responder side). Same pattern as
      // upstream's ProgressPage push from a background event.
      // ignore: use_build_context_synchronously, unawaited_futures
      Routerino.context.pushImmediately(() => ResponderPairingDialog(pending: newPending));
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/trust/query') {
      // Lets the SENDER check how the receiver would treat them before a
      // transfer (auto-accept / limited / blocked). Reveals only the policy
      // toward the queried fingerprint — never ownerId/ownerName.
      final body = await readJsonBody(request);
      if (body == null || body['fingerprint'] is! String) {
        await writeJson(request, {'error': 'bad_request'}, status: 400);
        return;
      }
      FavoriteDevice? entry;
      for (final e in ref.read(favoritesProvider)) {
        if (e.fingerprint == body['fingerprint']) {
          entry = e;
          break;
        }
      }
      if (entry == null) {
        await writeJson(request, {'known': false});
        return;
      }
      await writeJson(request, {
        'known': true,
        'trustLevel': entry.trustLevel.name,
        'blocked': entry.blocked,
        'maxFileSize': entry.maxFileSize,
        'quotaMode': entry.quotaMode.name,
        'quotaValue': entry.quotaValue,
      });
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/screen/offer') {
      // E-2 screen share: the sender offers to stream its screen to us.
      // The trust chain (D2) decides; the response is immediate (auto-accept)
      // or `pending` while the local user is asked (W3 dialog).
      final body = await readJsonBody(request);
      if (body == null || body['fingerprint'] is! String) {
        await writeJson(request, {'error': 'bad_request'}, status: 400);
        return;
      }
      final action = HandleScreenOfferAction(
        peerIp: request.connectionInfo!.remoteAddress.address.replaceAll('::ffff:', ''),
        peerFingerprint: body['fingerprint'] as String,
        peerAlias: (body['alias'] as String?) ?? '???',
      );
      try {
        final (_, result) = await ref.redux(screenProvider).dispatchAsyncWithResult(action);
        await writeJson(request, result.body, status: result.status);
        // Pending offers ask the local user (UI-2/W3): show the dialog like
        // the pairing responder flow does.
        if (result.status == 409 && result.body['pending'] == true) {
          final pending = ref.read(screenProvider).pendingOffer;
          if (pending != null) {
            // ignore: use_build_context_synchronously, unawaited_futures
            Routerino.context.pushImmediately(() => ScreenOfferDialog(pending: pending));
          }
        }
      } catch (e, st) {
        _logger.warning('screen/offer failed: $e\n$st');
        await writeJson(request, {'error': 'internal'}, status: 500);
      }
      return;
    }

    if (request.method == 'POST' && path == '/api/anyshare/v1/pair/confirm') {
      final body = await readJsonBody(request);
      final pending = ref.read(extensionServerProvider).pending;
      // Note: pending.aborted is NOT rejected here — the gate below resolves
      // to false in that case, yielding a distinct `not_confirmed` error.
      if (body == null || pending == null || body['session'] != pending.sessionId) {
        await writeJson(request, {'error': 'no_pending'}, status: 409);
        return;
      }
      if (DateTime.now().difference(pending.createdAt) > kPendingTtl) {
        ref.redux(extensionServerProvider).dispatch(_ClearPendingAction());
        await writeJson(request, {'error': 'no_pending'}, status: 409);
        return;
      }

      // Wait for the LOCAL user to accept the SAS comparison (60s so the
      // responder has time to compare both screens; the initiator's confirm
      // request long-polls here).
      final bool accepted;
      try {
        accepted = await pending.userGate.future.timeout(const Duration(seconds: 60));
      } on TimeoutException {
        await writeJson(request, {'error': 'not_confirmed'}, status: 409);
        return;
      }
      if (!accepted || pending.aborted) {
        await writeJson(request, {'error': 'not_confirmed'}, status: 409);
        return;
      }

      final localOwner = ref.read(ownerProvider);
      await writeJson(request, {
        'ok': true,
        'ownerId': localOwner.id,
        'ownerName': localOwner.name,
        'alias': alias,
        'fingerprint': ref.read(securityProvider).certificateHash,
      });
      // Persist the peer with temp trust and the initiator's owner identity
      // (required by the same-owner rule, PRD F-PAIR-09).
      await ref
          .redux(favoritesProvider)
          .dispatchAsync(
            AddFavoriteAction(
              FavoriteDevice.fromValues(
                fingerprint: pending.peerFingerprint,
                ip: pending.ip,
                port: pending.peerPort,
                alias: pending.peerAlias,
              ).copyWith(
                // Product decision (2026-10-14): pairing IS the receiver's
                // confirmation — no per-transfer prompts even at `temp`.
                trustLevel: TrustLevel.temp,
                ownerId: (body['ownerId'] as String?) ?? '',
                ownerName: (body['ownerName'] as String?) ?? '',
              ),
            ),
          );
      ref.redux(extensionServerProvider).dispatch(_ClearPendingAction());
      return;
    }

    await writeJson(request, {'error': 'not_found'}, status: 404);
  }

  bool _rateLimited(HttpRequest request) {
    final ip = request.connectionInfo!.remoteAddress.address;
    final now = DateTime.now();
    final lockedUntil = _rateLockedUntil[ip];
    if (lockedUntil != null && now.isBefore(lockedUntil)) {
      return true;
    }
    final window = _rateWindow.putIfAbsent(ip, () => [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    window.add(now);
    if (window.length > 5) {
      _rateLockedUntil[ip] = now.add(const Duration(seconds: 60));
      return true;
    }
    return false;
  }

  Future<Map<String, dynamic>?> readJsonBody(HttpRequest request) async {
    try {
      final body = await request.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        if (acc.length > kMaxBodyBytes) {
          throw Exception('body too large');
        }
        return acc;
      });
      final decoded = jsonDecode(utf8.decode(body));
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(HttpRequest request, Map<String, dynamic> data, {int status = 200}) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    await request.response.close();
  }
}

/// Compares IPs ignoring the IPv6 scope suffix (`fe80::1%3` vs `fe80::1`) and
/// the IPv4-mapped IPv6 form reported by dual-stack listeners
/// (`::ffff:127.0.0.1` vs `127.0.0.1`).
String _normalizedIp(String ip) {
  var value = ip;
  final scope = value.indexOf('%');
  if (scope >= 0) {
    value = value.substring(0, scope);
  }
  const mappedPrefix = '::ffff:';
  if (value.startsWith(mappedPrefix)) {
    final tail = value.substring(mappedPrefix.length);
    if (!tail.contains(':')) {
      return tail;
    }
  }
  return value;
}
