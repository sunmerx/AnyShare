import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/owner_claim_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  const localFingerprint = 'TESTHASH123';

  late RefenaContainer container;
  late HttpServer peer;
  late List<Map<String, dynamic>> received;

  setUp(() async {
    received = [];
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
    await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));

    // Stand-in for the peer that receives the claim.
    peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peer.listen((request) async {
      final body = await utf8.decodeStream(request);
      received.add(jsonDecode(body) as Map<String, dynamic>);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true, 'ownerId': 'peer-owner', 'ownerName': 'Peer Owner'}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await peer.close(force: true);
  });

  test('claim sends this device identity and adopts the peer owner on success', () async {
    final entry = FavoriteDevice(
      id: 'favorite-1',
      fingerprint: 'FPPEER01',
      alias: 'Peer device',
      ip: '127.0.0.1',
      port: 53317,
      ownerId: 'previous-owner',
      ownerName: 'Previous',
    );
    await container.redux(favoritesProvider).dispatchAsync(AddFavoriteAction(entry));

    final error = await claimDeviceOwner(container, entry, '127.0.0.1', port: peer.port);

    expect(error, isNull);
    // The claimer publishes its own owner identity; the peer adopts it, and the
    // favorite records the same identity locally so the same-owner rule matches.
    final localOwner = container.read(ownerProvider);
    final sent = received.single;
    expect(sent['fingerprint'], localFingerprint);
    expect(sent['ownerId'], localOwner.id);
    final updated = container.read(favoritesProvider).singleWhere((e) => e.fingerprint == 'FPPEER01');
    expect(updated.ownerId, localOwner.id);
    expect(updated.ownerName, localOwner.name);
  });

  test('claim reports the peer error code without touching the favorite', () async {
    await peer.close(force: true);
    peer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    peer.listen((request) async {
      request.response.statusCode = 409;
      request.response.write(jsonEncode({'error': 'not_confirmed'}));
      await request.response.close();
    });

    final entry = FavoriteDevice(
      id: 'favorite-2',
      fingerprint: 'FPPEER02',
      alias: 'Peer device',
      ip: '127.0.0.1',
      port: 53317,
      ownerId: 'previous-owner',
      ownerName: 'Previous',
    );
    await container.redux(favoritesProvider).dispatchAsync(AddFavoriteAction(entry));

    final error = await claimDeviceOwner(container, entry, '127.0.0.1', port: peer.port);

    expect(error, 'not_confirmed');
    final unchanged = container.read(favoritesProvider).singleWhere((e) => e.fingerprint == 'FPPEER02');
    expect(unchanged.ownerId, 'previous-owner');
  });
}
