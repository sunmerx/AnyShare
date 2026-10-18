import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/shared_dir_config.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/shared_dirs_provider.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late RefenaContainer container;
  late int port;
  late Directory root;
  late DirClient client;

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
    root = Directory.systemTemp.createTempSync('anyshare_dir_client');
    File(p.join(root.path, 'a.txt')).writeAsStringSync('alpha');

    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));
    await container
        .redux(sharedDirsProvider)
        .dispatchAsync(
          AddSharedDirAction(SharedDirConfig(id: 'root1', path: root.path, name: 'Root', writable: true)),
        );
    await container
        .redux(sharedDirsProvider)
        .dispatchAsync(
          AddSharedDirAction(SharedDirConfig(id: 'ro', path: root.path, name: 'ReadOnly', writable: false)),
        );
    await container
        .redux(favoritesProvider)
        .dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'FPPEER', ip: '127.0.0.1', port: 53317, alias: 'Peer').copyWith(trustLevel: TrustLevel.full),
          ),
        );
    await container.redux(dirWriteGrantsProvider).dispatchAsync(SetDirWriteGrantAction(fingerprint: 'FPPEER', granted: true));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    port = container.read(extensionServerProvider).port ?? 0;
    client = DirClient(host: '127.0.0.1', extPort: port, fingerprint: 'FPPEER');
  });

  tearDown(() async {
    await container.read(extensionServerProvider).server?.close(force: true);
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('client round trip: roots, list, download, upload', () async {
    final roots = await client.roots();
    expect(roots, hasLength(2));
    final root1 = roots.firstWhere((r) => r.id == 'root1');
    expect(root1.writable, isTrue);
    expect(roots.firstWhere((r) => r.id == 'ro').writable, isFalse);

    final listing = await client.list(root: 'root1', path: '');
    expect(listing.entries.map((e) => e.name), contains('a.txt'));
    expect(listing.writable, isTrue);

    final bytes = await client.downloadBytes(root: 'root1', path: 'a.txt');
    expect(utf8.decode(bytes), 'alpha');

    final source = File(p.join(root.path, '..', 'upload_src.txt'));
    source.writeAsStringSync('bravo');
    try {
      final finalName = await client.uploadFile(root: 'root1', path: '', source: source, name: 'upload_src.txt');
      expect(finalName, 'upload_src.txt');
      expect(File(p.join(root.path, 'upload_src.txt')).readAsStringSync(), 'bravo');

      // Conflict rename policy.
      final second = await client.uploadFile(root: 'root1', path: '', source: source, name: 'upload_src.txt');
      expect(second, 'upload_src(1).txt');
    } finally {
      source.deleteSync();
    }
  });

  test('empty file upload round trips', () async {
    final empty = File(p.join(root.path, '..', 'empty_src.bin'));
    empty.writeAsBytesSync([]);
    try {
      final finalName = await client.uploadFile(root: 'root1', path: '', source: empty, name: 'empty_src.bin');
      expect(finalName, 'empty_src.bin');
      expect(File(p.join(root.path, 'empty_src.bin')).lengthSync(), 0);
    } finally {
      empty.deleteSync();
    }
  });

  test('missing source file maps to source_error', () async {
    final missing = File(p.join(root.path, '..', 'does_not_exist.bin'));
    await expectLater(
      client.uploadFile(root: 'root1', path: '', source: missing, name: 'x.bin'),
      throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'source_error')),
    );
  });

  test('client mutations: mkdir, rename, delete-to-trash, download-to-file', () async {
    await client.mkdir(root: 'root1', path: '', name: 'dir1');
    expect(Directory(p.join(root.path, 'dir1')).existsSync(), isTrue);

    final renamed = await client.rename(root: 'root1', path: 'dir1', newName: 'dir2');
    expect(renamed, 'dir2');

    await client.delete(root: 'root1', path: 'dir2');
    expect(Directory(p.join(root.path, 'dir2')).existsSync(), isFalse);

    final target = File(p.join(root.path, '..', 'downloaded.txt'));
    try {
      await client.downloadToFile(root: 'root1', path: 'a.txt', target: target);
      expect(target.readAsStringSync(), 'alpha');
      expect(File('${target.path}.part').existsSync(), isFalse);
    } finally {
      if (target.existsSync()) {
        target.deleteSync();
      }
    }
  });

  test('failed downloadToFile leaves no residue', () async {
    final target = File(p.join(root.path, '..', 'residue.txt'));
    await expectLater(
      client.downloadToFile(root: 'root1', path: 'missing.txt', target: target),
      throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'not_found')),
    );
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('download and upload report byte progress', () async {
    final received = <int>[];
    final target = File(p.join(root.path, '..', 'progress.txt'));
    try {
      await client.downloadToFile(
        root: 'root1',
        path: 'a.txt',
        target: target,
        onProgress: (r, total) {
          received.add(r);
          expect(total, 5);
        },
      );
      expect(received, isNotEmpty);
      expect(received.last, 5);
      final sorted = [...received]..sort();
      expect(received, orderedEquals(sorted));
    } finally {
      if (target.existsSync()) {
        target.deleteSync();
      }
    }

    final sent = <int>[];
    final source = File(p.join(root.path, '..', 'progress_src.txt'));
    source.writeAsStringSync('bravo');
    try {
      await client.uploadFile(
        root: 'root1',
        path: '',
        source: source,
        name: 'progress_src.txt',
        onProgress: (s, total) {
          sent.add(s);
          expect(total, 5);
        },
      );
      expect(sent, isNotEmpty);
      expect(sent.last, 5);
    } finally {
      source.deleteSync();
    }
  });

  test('read-only root rejects writes', () async {
    final listing = await client.list(root: 'ro', path: '');
    expect(listing.writable, isFalse);
    await expectLater(
      client.mkdir(root: 'ro', path: '', name: 'nope'),
      throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'read_only')),
    );
  });

  test('malformed server payload maps to protocol error', () async {
    final stub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stub.listen((request) async {
      request.response
        ..statusCode = 200
        ..write('this is not json');
      await request.response.close();
    });
    try {
      final broken = DirClient(host: '127.0.0.1', extPort: stub.port, fingerprint: 'FPPEER');
      await expectLater(broken.roots(), throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'protocol')));
    } finally {
      await stub.close(force: true);
    }
  });

  test('server errors map to typed client exceptions', () async {
    final stranger = DirClient(host: '127.0.0.1', extPort: port, fingerprint: 'WRONG');
    await expectLater(stranger.roots(), throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'unknown')));

    await expectLater(
      client.downloadBytes(root: 'root1', path: '../escape'),
      throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'invalid_path')),
    );

    await expectLater(
      client.list(root: 'missing', path: ''),
      throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'not_found')),
    );

    final unreachable = DirClient(host: '127.0.0.1', extPort: 1, fingerprint: 'FPPEER', timeout: const Duration(seconds: 2));
    await expectLater(unreachable.roots(), throwsA(isA<DirClientException>().having((e) => e.code, 'code', 'unreachable')));
  });
}
