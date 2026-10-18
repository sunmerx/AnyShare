import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/shared_dir_config.dart';
import 'package:localsend_app/provider/dir_browse_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/shared_dirs_provider.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late RefenaContainer container;
  late Directory root;

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
    root = Directory.systemTemp.createTempSync('anyshare_dir_browse');
    File(p.join(root.path, 'a.txt')).writeAsStringSync('alpha');
    Directory(p.join(root.path, 'sub')).createSync();
    File(p.join(root.path, 'sub', 'inner.txt')).writeAsStringSync('inner');

    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));
    await container
        .redux(sharedDirsProvider)
        .dispatchAsync(
          AddSharedDirAction(SharedDirConfig(id: 'root1', path: root.path, name: 'Root', writable: true)),
        );
    await container
        .redux(favoritesProvider)
        .dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'TESTHASH123', ip: '127.0.0.1', port: 53317, alias: 'Peer').copyWith(trustLevel: TrustLevel.full),
          ),
        );
    await container.redux(dirWriteGrantsProvider).dispatchAsync(SetDirWriteGrantAction(fingerprint: 'TESTHASH123', granted: true));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    await container.set(dirBrowsePortProvider.overrideWithValue(container.read(extensionServerProvider).port ?? 0));
  });

  tearDown(() async {
    await container.read(extensionServerProvider).server?.close(force: true);
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('open session loads roots and first listing', () async {
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));
    final session = container.read(dirBrowseProvider)['FPPEER']!;
    expect(session.error, isNull);
    expect(session.roots, hasLength(1));
    expect(session.rootId, 'root1');
    expect(session.writable, isTrue);
    expect(session.entries.map((e) => e.name), ['sub', 'a.txt']);
    expect(session.requestId, 1);
  });

  test('load listing navigates into subdirectories and back', () async {
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));
    await container
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: 'FPPEER', rootId: 'root1', path: 'sub', requestId: 2),
        );
    var session = container.read(dirBrowseProvider)['FPPEER']!;
    expect(session.path, 'sub');
    expect(session.entries.map((e) => e.name), ['inner.txt']);

    await container
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: 'FPPEER', rootId: 'root1', path: '', requestId: 3),
        );
    session = container.read(dirBrowseProvider)['FPPEER']!;
    expect(session.entries.map((e) => e.name), ['sub', 'a.txt']);
  });

  test('listing failure stores the error code and resets derived flags', () async {
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));
    await container
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: 'FPPEER', rootId: 'root1', path: 'missing', requestId: 2),
        );
    final session = container.read(dirBrowseProvider)['FPPEER']!;
    expect(session.error, 'not_found');
    expect(session.entries, isEmpty);
    expect(session.path, 'missing');
    expect(session.writable, isFalse);
    expect(session.truncated, isFalse);
  });

  test('permission and transport errors are stored in the session', () async {
    await container.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: 'TESTHASH123'));
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));
    final denied = container.read(dirBrowseProvider)['FPPEER']!;
    expect(denied.error, 'unknown');
    expect(denied.roots, isEmpty);

    await container.set(dirBrowsePortProvider.overrideWithValue(1));
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER2', host: '127.0.0.1', requestId: 1));
    expect(container.read(dirBrowseProvider)['FPPEER2']!.error, 'unreachable');

    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER3', host: '', requestId: 1));
    expect(container.read(dirBrowseProvider)['FPPEER3']!.error, 'unreachable');
  });

  test('close action removes the session', () async {
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));
    expect(container.read(dirBrowseProvider).containsKey('FPPEER'), isTrue);
    container.redux(dirBrowseProvider).dispatch(CloseDirBrowseAction(fingerprint: 'FPPEER'));
    expect(container.read(dirBrowseProvider).containsKey('FPPEER'), isFalse);
  });

  test('stale listing responses never overwrite a newer navigation', () async {
    final stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stub.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final map = jsonDecode(body) as Map<String, dynamic>;
      Map<String, dynamic> payload;
      if (request.uri.path.endsWith('/roots')) {
        payload = {
          'roots': [
            {'id': 'root1', 'name': 'R', 'writable': true},
          ],
        };
      } else {
        final path = map['path'] as String? ?? '';
        if (path == 'slow') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        payload = {
          'entries': [
            {'name': path == 'slow' ? 'SLOW' : (path == 'fast' ? 'FAST' : 'ROOT'), 'isDir': false, 'isLink': false, 'size': 1, 'modified': 0},
          ],
          'writable': true,
          'truncated': false,
        };
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(payload));
      await request.response.close();
    });
    addTearDown(() async => stub.close(force: true));

    await container.set(dirBrowsePortProvider.overrideWithValue(stub.port));
    await container.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: 'FPPEER', host: '127.0.0.1', requestId: 1));

    // Slow request dispatched first, fast request second: the user's last
    // click must win even though the slow response arrives later.
    final slow = container
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: 'FPPEER', rootId: 'root1', path: 'slow', requestId: 2),
        );
    final fast = container
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: 'FPPEER', rootId: 'root1', path: 'fast', requestId: 3),
        );
    await slow;
    await fast;

    final session = container.read(dirBrowseProvider)['FPPEER']!;
    expect(session.path, 'fast');
    expect(session.entries.single.name, 'FAST');
    expect(session.requestId, 3);
  });
}
