import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/sas.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  const localFingerprint = 'TESTHASH123';
  const peerFingerprint = 'FPPEER01';

  late RefenaContainer container;
  late int port;

  setUp(() async {
    // In-memory platform store: no flutter_test binding (its HttpOverrides
    // would intercept our localhost HTTP client with 400s).
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData({
      'flutter.ls_security_context': jsonEncode({
        'privateKey': 'TEST',
        'publicKey': 'TEST',
        'certificate': 'TEST',
        'certificateHash': localFingerprint,
      }),
    });
    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    final persistence = PersistenceService.test(prefs);
    await container.set(persistenceProvider.overrideWithValue(persistence));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    port = container.read(extensionServerProvider).port ?? 0;
  });

  Future<(int, Map<String, dynamic>?)> get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/$path'));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>);
  }

  Future<(int, Map<String, dynamic>)> post(String path, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/$path'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
  }

  Future<(SimpleKeyPair, Map<String, dynamic>)> register(String alias) async {
    final keyPair = await SasCrypto.generateKeyPair();
    final pub = await keyPair.extractPublicKey();
    final (status, body) = await post('pair/register', {
      'alias': alias,
      'fingerprint': peerFingerprint,
      'eph': base64Encode(pub.bytes),
      'port': 53317,
      'https': false,
    });
    return (keyPair, body);
  }

  test('capabilities reports extension info', () async {
    final (status, body) = await get('capabilities');
    expect(status, 200);
    expect(body!['ext'], 1);
    expect(body['sas'], true);
    expect(body['fingerprint'], localFingerprint);
  });

  test('pairing: SAS code matches, gate semantics, persistence on confirm', () async {
    // --- register: responder derives the same SAS code (cross-check) ---
    final (initiatorKeyPair, reg1) = await register('TestPeer');
    expect(reg1['session'], isA<String>());
    expect(reg1['code'], matches(RegExp(r'^\d{6}$')));
    final shared = await SasCrypto.deriveSharedSecret(
      keyPair: initiatorKeyPair,
      peerPublicKey: base64Decode(reg1['eph'] as String),
    );
    final derived = await SasCrypto.deriveCode(
      sharedSecret: shared,
      sessionId: reg1['session'] as String,
      fingerprintA: peerFingerprint,
      fingerprintB: localFingerprint,
    );
    expect(derived, reg1['code']);

    // --- confirm while the local user has NOT accepted: abort → 409, nothing persisted ---
    container.redux(extensionServerProvider).dispatch(AbortPendingPairingAction());
    final (s1, b1) = await post('pair/confirm', {
      'session': reg1['session'],
      'ownerId': 'initiator-owner-1',
      'ownerName': 'Initiator',
      'alias': 'InitiatorDevice',
    });
    expect(s1, 409);
    expect(b1['error'], 'not_confirmed');
    expect(container.read(favoritesProvider), isEmpty);

    // --- happy path: accept (gate) → confirm → 200 + persisted favorite ---
    final (_, reg2) = await register('TestPeer'); // aborted pending is not busy
    expect(reg2['session'], isNot(reg1['session']));
    final sessionId2 = reg2['session'] as String;
    await container.redux(extensionServerProvider).dispatchAsync(AcceptPendingPairingAction());

    final (s2, b2) = await post('pair/confirm', {
      'session': sessionId2,
      'ownerId': 'initiator-owner-1',
      'ownerName': 'Initiator',
      'alias': 'InitiatorDevice',
    });
    expect(s2, 200);
    expect(b2['ok'], true);
    expect((b2['ownerId'] as String?) ?? '', isNotEmpty);

    // The server persists the favorite AFTER writing the HTTP response.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final favorites = container.read(favoritesProvider);
    expect(favorites, hasLength(1));
    expect(favorites.single.fingerprint, peerFingerprint);
    expect(favorites.single.alias, 'TestPeer');
    expect(favorites.single.trustLevel, TrustLevel.temp);
    expect(favorites.single.ownerId, 'initiator-owner-1');

    // pending cleared after success
    expect(container.read(extensionServerProvider).pending, isNull);
  });

  test('trust/query reveals the policy toward the sender only', () async {
    // unknown fingerprint
    final (s0, b0) = await post('trust/query', {'fingerprint': 'UNKNOWN'});
    expect(s0, 200);
    expect(b0['known'], false);

    // after pairing, the policy is known (temp, not blocked, no limits)
    await register('TestPeer');
    await container.redux(extensionServerProvider).dispatchAsync(AcceptPendingPairingAction());
    final (s1, b1) = await post('trust/query', {'fingerprint': peerFingerprint});
    expect(s1, 200);
    expect(b1['known'], true);
    expect(b1['trustLevel'], 'temp');
    expect(b1['blocked'], false);
    expect(b1['maxFileSize'], 0);
    expect(b1['quotaMode'], 'none');
    expect(b1.containsKey('ownerId'), false, reason: 'owner identity must not leak');
  });

  test('rate limit: 6th /pair request from one IP is throttled', () async {
    // Fresh server per test: requests 1-5 pass, the 6th is throttled.
    final statuses = <int>[];
    for (var i = 0; i < 7; i++) {
      final keyPair = await SasCrypto.generateKeyPair();
      final pub = await keyPair.extractPublicKey();
      final (status, body) = await post('pair/register', {
        'alias': 'RateLimitPeer',
        'fingerprint': peerFingerprint,
        'eph': base64Encode(pub.bytes),
        'port': 53317,
        'https': false,
      });
      statuses.add(status);
      if (status == 200) {
        container.redux(extensionServerProvider).dispatch(AbortPendingPairingAction());
      }
    }
    expect(statuses, [200, 200, 200, 200, 200, 429, 429]);
  });
}
