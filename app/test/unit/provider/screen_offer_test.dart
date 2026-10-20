import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/screen/screen_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FakeScreenSession implements ScreenEngineSession {
  final _controller = StreamController<ScreenSessionEvent>.broadcast();
  bool stopped = false;

  @override
  Stream<ScreenSessionEvent> get events => _controller.stream;

  @override
  Future<ScreenSessionStats?> stats() async => null;

  @override
  Future<void> requestKeyframe() async {
    keyframeRequests++;
  }

  int keyframeRequests = 0;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  void emit(ScreenSessionEvent event) => _controller.add(event);
}

class FakeScreenEngine implements ScreenEngine {
  final List<String> startedSenders = [];
  final List<int> startedReceivers = [];
  final List<FakeScreenSession> sessions = [];

  @override
  Future<ScreenEngineSession> startSender({required String host, required int port}) async {
    startedSenders.add('$host:$port');
    final session = FakeScreenSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<ScreenEngineSession> startReceiver({required int port}) async {
    startedReceivers.add(port);
    final session = FakeScreenSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  const localFingerprint = 'TESTHASH123';

  late RefenaContainer container;
  late FakeScreenEngine engine;
  late int port;
  late HttpServer peerServer;
  late List<String> peerRequests;
  late List<(String, String)> peerBodies;

  setUp(() async {
    // SharedPreferences caches its instance statically; without the reset the
    // favorites written by one test leak into the next one.
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData({
      'flutter.ls_security_context': jsonEncode({
        'privateKey': 'TEST',
        'publicKey': 'TEST',
        'certificate': 'TEST',
        'certificateHash': localFingerprint,
      }),
    });
    // Stub peer: acts as the remote side's extension server (accepts all
    // control posts with 200).
    peerServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peerRequests = [];
    peerBodies = [];
    unawaited(
      peerServer.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        peerRequests.add(request.uri.path);
        peerBodies.add((request.uri.path, body));
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
      }).asFuture<void>(),
    );
    engine = FakeScreenEngine();
    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    final persistence = PersistenceService.test(prefs);
    await container.set(persistenceProvider.overrideWithValue(persistence));
    await container.set(screenEngineProvider.overrideWithValue(engine));
    // The test host is not Linux; pretend we can receive screen shares.
    await container.set(screenReceiveSupportedProvider.overrideWithValue(true));
    await container.set(screenControlPortProvider.overrideWithValue(peerServer.port));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    port = container.read(extensionServerProvider).port ?? 0;
  });

  tearDown(() async {
    // Stop any engine session (also cancels the watchdog timer) and release
    // the server ports.
    await container.redux(screenProvider).dispatchAsync(StopScreenShareAction());
    await container.read(extensionServerProvider).server?.close(force: true);
    await peerServer.close(force: true);
  });

  Future<(int, Map<String, dynamic>)> post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
  }

  Future<void> addFavorite({
    required String fingerprint,
    required TrustLevel trustLevel,
    bool blocked = false,
    String ownerId = '',
    String ip = '127.0.0.1',
  }) async {
    await container
        .redux(favoritesProvider)
        .dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(
              fingerprint: fingerprint,
              ip: ip,
              port: 53317,
              alias: 'Peer',
            ).copyWith(trustLevel: trustLevel, blocked: blocked, ownerId: ownerId),
          ),
        );
  }

  Future<(int, Map<String, dynamic>)> offer({String fingerprint = 'FPPEER01'}) {
    return post('screen/offer', {
      'fingerprint': fingerprint,
      'ownerId': 'peer-owner',
      'ownerName': 'Peer Owner',
      'alias': 'PeerDevice',
    });
  }

  test('offer from unknown device: pending, engine not started', () async {
    final (status, body) = await offer();
    expect(status, 409);
    expect(body['pending'], true);
    expect(body['session'], isA<String>());
    expect(engine.startedReceivers, isEmpty);
    final state = container.read(screenProvider);
    expect(state.pendingOffer, isNotNull);
    expect(state.pendingOffer!.sessionId, body['session']);
    expect(state.active, isNull);
  });

  test('offer from blocked device: 403 blocked', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full, blocked: true);
    final (status, body) = await offer();
    expect(status, 403);
    expect(body['error'], 'blocked');
    expect(container.read(screenProvider).pendingOffer, isNull);
  });

  test('offer from temp device: 403 temp_not_allowed (D2)', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.temp);
    final (status, body) = await offer();
    expect(status, 403);
    expect(body['error'], 'temp_not_allowed');
  });

  test('offer from full device: auto-accept with session id, receiver on 53319', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    final (status, body) = await offer();
    expect(status, 200);
    expect(body['ok'], true);
    expect(body['port'], kScreenDataPort);
    expect(body['session'], isA<String>());
    expect(engine.startedReceivers, [kScreenDataPort]);
    final state = container.read(screenProvider);
    expect(state.active, isNotNull);
    expect(state.active!.role, ScreenRole.receiver);
    expect(state.active!.sessionId, body['session']);
    expect(state.pendingOffer, isNull);
  });

  test('offer from full device at a different address: pending, not auto-accept', () async {
    // Fingerprints travel over plain HTTP; a different source address must
    // downgrade to asking the local user.
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full, ip: '10.0.0.9');
    final (status, body) = await offer();
    expect(status, 409);
    expect(body['pending'], true);
    expect(engine.startedReceivers, isEmpty);
  });

  test('offer from same-owner device: auto-accept (stored owner id)', () async {
    final localOwnerId = container.read(ownerProvider).id;
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.limited, ownerId: localOwnerId);
    final (status, body) = await offer();
    expect(status, 200);
    expect(body['ok'], true);
    expect(engine.startedReceivers, [kScreenDataPort]);
  });

  test('second offer while active: 409 busy', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    final (s1, _) = await offer();
    expect(s1, 200);
    final (s2, b2) = await offer(fingerprint: 'FPOTHER');
    expect(s2, 409);
    expect(b2['error'], 'busy');
  });

  test('accept pending offer: receiver starts with the offer session id', () async {
    final (_, body) = await offer();
    final sessionId = body['session'] as String;

    await container.redux(screenProvider).dispatchAsync(AcceptPendingScreenOfferAction());

    expect(engine.startedReceivers, [kScreenDataPort]);
    final state = container.read(screenProvider);
    expect(state.pendingOffer, isNull);
    expect(state.active, isNotNull);
    expect(state.active!.sessionId, sessionId);
    expect(state.active!.role, ScreenRole.receiver);
  });

  test('abort pending offer clears the pending state', () async {
    await offer();
    expect(container.read(screenProvider).pendingOffer, isNotNull);

    await container.redux(screenProvider).dispatchAsync(AbortPendingScreenOfferAction());

    expect(container.read(screenProvider).pendingOffer, isNull);
  });

  test('stop endpoint with the matching session clears pending', () async {
    final (_, body) = await offer();
    final sessionId = body['session'] as String;

    final (status, _) = await post('screen/stop', {'session': sessionId, 'reason': 'denied'});

    expect(status, 200);
    expect(container.read(screenProvider).pendingOffer, isNull);
  });

  test('stop endpoint with a stale session leaves pending untouched', () async {
    final (_, body) = await offer();
    final sessionId = body['session'] as String;

    final (status, _) = await post('screen/stop', {'session': 'stale-session', 'reason': 'denied'});

    expect(status, 200);
    expect(container.read(screenProvider).pendingOffer?.sessionId, sessionId);
  });

  test('incoming stop ends the active session and stops the engine', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    final (status, body) = await offer();
    expect(status, 200);
    final sessionId = body['session'] as String;
    expect(container.read(screenProvider).active, isNotNull);

    await container.redux(screenProvider).dispatchAsync(IncomingScreenStopAction(reason: 'user_stop', session: sessionId));

    expect(container.read(screenProvider).active, isNull);
    expect(engine.sessions.single.stopped, true);
  });

  test('incoming stop with a stale session leaves the active session alone', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    final (status, _) = await offer();
    expect(status, 200);

    await container.redux(screenProvider).dispatchAsync(IncomingScreenStopAction(reason: 'user_stop', session: 'stale-session'));

    expect(container.read(screenProvider).active, isNotNull);
  });

  test('stop endpoint ends the active session', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    final (_, body) = await offer();

    final (status, resp) = await post('screen/stop', {'session': body['session'], 'reason': 'user_stop'});

    expect(status, 200);
    expect(resp['ok'], true);
    expect(container.read(screenProvider).active, isNull);
  });

  test('receiver window closed tells the peer and clears the session', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    await offer();
    expect(container.read(screenProvider).active, isNotNull);

    engine.sessions.single.emit(const ScreenSessionEnded('windowclosed'));
    for (var i = 0; i < 40 && container.read(screenProvider).active != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(container.read(screenProvider).active, isNull);
  });

  test('start share to a reachable peer starts a sender session', () async {
    await container
        .redux(screenProvider)
        .dispatchAsync(
          StartScreenShareAction(peerIp: '127.0.0.1', peerAlias: 'Peer'),
        );

    expect(engine.startedSenders, ['127.0.0.1:$kScreenDataPort']);
    final state = container.read(screenProvider);
    expect(state.active, isNotNull);
    expect(state.active!.role, ScreenRole.sender);
    expect(state.waiting, isNull);
  });

  test('offer is rejected when the platform cannot receive', () async {
    await container.set(screenReceiveSupportedProvider.overrideWithValue(false));
    final (status, body) = await offer();
    expect(status, 403);
    expect(body['error'], 'receive_unsupported');
    expect(engine.startedReceivers, isEmpty);
  });

  test('incoming keyframe request reaches the sender engine', () async {
    await container.redux(screenProvider).dispatchAsync(StartScreenShareAction(peerIp: '127.0.0.1', peerAlias: 'Peer'));
    final active = container.read(screenProvider).active!;
    final session = engine.sessions.last;

    final (status, body) = await post('screen/keyframe', {'session': active.sessionId});

    expect(status, 200);
    expect(body['ok'], true);
    expect(session.keyframeRequests, 1);
    // The sender must not relay the request back out.
    expect(peerBodies.where((entry) => entry.$1.endsWith('/screen/keyframe')), isEmpty);
  });

  test('incoming keyframe request with a stale session is ignored', () async {
    await container.redux(screenProvider).dispatchAsync(StartScreenShareAction(peerIp: '127.0.0.1', peerAlias: 'Peer'));
    final session = engine.sessions.last;

    final (status, _) = await post('screen/keyframe', {'session': 'stale'});

    expect(status, 200);
    expect(session.keyframeRequests, 0);
  });

  test('receiver loss event asks the peer for a keyframe', () async {
    await addFavorite(fingerprint: 'FPPEER01', trustLevel: TrustLevel.full);
    await offer();
    final active = container.read(screenProvider).active!;
    expect(active.role, ScreenRole.receiver);

    engine.sessions.single.emit(const ScreenSessionRequestKeyframe());
    for (var i = 0; i < 40 && !peerRequests.any((path) => path.endsWith('/screen/keyframe')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final relayed = peerBodies.where((entry) => entry.$1.endsWith('/screen/keyframe')).toList();
    expect(relayed, hasLength(1));
    expect((jsonDecode(relayed.single.$2) as Map<String, dynamic>)['session'], active.sessionId);
  });

  test('clear error action resets the banner error', () async {
    await container
        .redux(screenProvider)
        .dispatchAsync(
          StartScreenShareAction(peerIp: 'fe80::1', peerAlias: 'Peer'),
        );
    expect(container.read(screenProvider).lastError, isNotNull);

    container.redux(screenProvider).dispatch(ClearScreenErrorAction());

    expect(container.read(screenProvider).lastError, isNull);
  });
}
