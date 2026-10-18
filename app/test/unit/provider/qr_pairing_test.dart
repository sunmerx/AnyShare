import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/qr_pairing_provider.dart';
import 'package:localsend_app/util/qr_pairing.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  group('qr payload codec', () {
    const payload = QrPairingPayload(
      host: '192.168.1.5',
      extPort: 53318,
      fingerprint: 'FP123',
      alias: 'Desktop',
      ownerId: 'owner-1',
      ownerName: 'sunmerx',
      token: 'tok-1',
    );

    test('roundtrip', () {
      final decoded = decodeQrPairing(encodeQrPairing(payload))!;
      expect(decoded.host, payload.host);
      expect(decoded.extPort, payload.extPort);
      expect(decoded.fingerprint, payload.fingerprint);
      expect(decoded.alias, payload.alias);
      expect(decoded.ownerId, payload.ownerId);
      expect(decoded.ownerName, payload.ownerName);
      expect(decoded.token, payload.token);
    });

    test('rejects garbage and missing fields', () {
      expect(decodeQrPairing('not json'), isNull);
      expect(decodeQrPairing('[]'), isNull);
      expect(decodeQrPairing(jsonEncode({'v': 2, 'host': 'a', 'port': 1, 'token': 't'})), isNull);
      expect(decodeQrPairing(jsonEncode({'v': 1, 'host': '', 'port': 1, 'token': 't'})), isNull);
      expect(decodeQrPairing(jsonEncode({'v': 1, 'host': 'a', 'port': 0, 'token': 't'})), isNull);
      expect(decodeQrPairing(jsonEncode({'v': 1, 'host': 'a', 'port': 53318})), isNull);
    });

    test('non-string optional fields never throw', () {
      final decoded = decodeQrPairing(jsonEncode({'v': 1, 'host': 'a', 'port': 53318, 'token': 't', 'alias': 5, 'fp': [], 'ownerId': 7}));
      expect(decoded, isNotNull);
      expect(decoded!.alias, '???');
      expect(decoded.fingerprint, '');
      expect(decoded.ownerId, '');
    });
  });

  group('qr token validation', () {
    final now = DateTime.now();

    test('valid within TTL, invalid when stale or mismatched', () {
      final state = QrPairingState(
        payload: const QrPairingPayload(
          host: '192.168.1.5',
          extPort: 53318,
          fingerprint: 'FP',
          alias: 'a',
          ownerId: 'o',
          ownerName: 'n',
          token: 'tok-1',
        ),
        createdAt: now,
      );
      expect(state.isValidToken('tok-1'), isTrue);
      expect(state.isValidToken('other'), isFalse);
      expect(const QrPairingState().isValidToken('tok-1'), isFalse);

      final stale = QrPairingState(payload: state.payload, createdAt: now.subtract(kQrPairingTtl + const Duration(seconds: 1)));
      expect(stale.isValidToken('tok-1'), isFalse);
    });
  });

  group('extension server pair/register qr token', () {
    late RefenaContainer container;
    late int port;
    late QrPairingState qrState;

    setUp(() async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData({
        'flutter.ls_security_context': jsonEncode({
          'privateKey': 'TEST',
          'publicKey': 'TEST',
          'certificate': 'TEST',
          'certificateHash': 'TESTHASH123',
        }),
      });
      container = RefenaContainer();
      final prefs = await SharedPreferences.getInstance();
      await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));
    });

    // The QR override must be registered AFTER the desired state is set:
    // refena instantiates the notifier when the override is registered.
    Future<void> startServer() async {
      await container.set(qrPairingProvider.overrideWithNotifier((ref) => _FixedQrPairingService(ref, () => qrState)));
      await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
      port = container.read(extensionServerProvider).port ?? 0;
    }

    QrPairingState freshQrState() {
      return QrPairingState(
        payload: const QrPairingPayload(
          host: '192.168.1.5',
          extPort: 53318,
          fingerprint: 'FP',
          alias: 'a',
          ownerId: 'o',
          ownerName: 'n',
          token: 'tok-1',
        ),
        createdAt: DateTime.now(),
      );
    }

    tearDown(() async {
      await container.read(extensionServerProvider).server?.close(force: true);
    });

    Future<(int, Map<String, dynamic>)> register({String? qrToken}) async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/pair/register'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'alias': 'Peer',
        'fingerprint': 'FPPEER',
        'eph': base64Encode(List<int>.filled(32, 7)),
        'port': 53317,
        'https': false,
        'qrToken': ?qrToken,
      }));
      final response = await request.close().timeout(const Duration(seconds: 5));
      final text = await response.transform(utf8.decoder).join();
      return (response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
    }

    test('valid token passes, wrong token is rejected', () async {
      qrState = freshQrState();
      await startServer();
      final (s1, _) = await register(qrToken: 'tok-1');
      expect(s1, 200);
      // clean the pending pairing for the next attempt
      container.redux(extensionServerProvider).dispatch(AbortPendingPairingAction());

      final (s2, b2) = await register(qrToken: 'wrong');
      expect(s2, 403);
      expect(b2['error'], 'invalid_token');
    });

    test('expired token is rejected, token-less (manual) register is unaffected', () async {
      qrState = QrPairingState(
        payload: freshQrState().payload,
        createdAt: DateTime.now().subtract(kQrPairingTtl + const Duration(seconds: 5)),
      );
      await startServer();
      final (s1, b1) = await register(qrToken: 'tok-1');
      expect(s1, 403);
      expect(b1['error'], 'invalid_token');

      final (s2, _) = await register();
      expect(s2, 200);
    });
  });
}

/// Fixed-state QR service so the register endpoint can be exercised without
/// real network/identity providers.
class _FixedQrPairingService extends QrPairingService {
  final QrPairingState Function() stateOf;

  _FixedQrPairingService(super.ref, this.stateOf);

  @override
  QrPairingState init() => stateOf();

  @override
  QrPairingState build() => stateOf();
}
