import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/shared_dir_config.dart';
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
  late int port;
  late Directory root;
  late Directory readOnlyRoot;

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
    root = Directory.systemTemp.createTempSync('anyshare_dir_root');
    readOnlyRoot = Directory.systemTemp.createTempSync('anyshare_dir_ro');
    File(p.join(root.path, 'hello.txt')).writeAsStringSync('hello world');
    Directory(p.join(root.path, 'sub')).createSync();
    Directory(p.join(root.path, '.anyshare_trash')).createSync();

    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));
    await container.redux(sharedDirsProvider).dispatchAsync(AddSharedDirAction(SharedDirConfig(id: 'root1', path: root.path, name: 'Root', writable: true)));
    await container
        .redux(sharedDirsProvider)
        .dispatchAsync(AddSharedDirAction(SharedDirConfig(id: 'ro1', path: readOnlyRoot.path, name: 'ReadOnly', writable: false)));
    await container.redux(favoritesProvider).dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'FPPEER', ip: '127.0.0.1', port: 53317, alias: 'Peer').copyWith(trustLevel: TrustLevel.full),
          ),
        );
    await container.redux(dirWriteGrantsProvider).dispatchAsync(SetDirWriteGrantAction(fingerprint: 'FPPEER', granted: true));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    port = container.read(extensionServerProvider).port ?? 0;
  });

  tearDown(() async {
    await container.read(extensionServerProvider).server?.close(force: true);
    for (final dir in [root, readOnlyRoot]) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  Future<(int, Map<String, dynamic>)> postJson(String endpoint, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/dir/$endpoint'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await response.transform(utf8.decoder).join();
    return (response.statusCode, text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>);
  }

  Future<(int, List<int>)> postQuery(String endpoint, Map<String, String> query, [List<int>? body]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final uri = Uri.parse('http://127.0.0.1:$port/api/anyshare/v1/dir/$endpoint').replace(queryParameters: query);
    final request = await client.postUrl(uri);
    if (body != null) {
      request.add(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return (response.statusCode, bytes);
  }

  Map<String, dynamic> rootReq([String? rootId]) => {'fingerprint': 'FPPEER', 'root': rootId ?? 'root1'};

  Map<String, dynamic> asJson(List<int> bytes) => bytes.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

  test('roots: granted device sees roots with per-root writability', () async {
    final (status, body) = await postJson('roots', {'fingerprint': 'FPPEER'});
    expect(status, 200);
    final roots = body['roots'] as List;
    expect(roots, hasLength(2));
    expect(roots.firstWhere((r) => r['id'] == 'root1')['writable'], isTrue);
    expect(roots.firstWhere((r) => r['id'] == 'ro1')['writable'], isFalse);
  });

  test('access: unknown, ip mismatch and temp are rejected', () async {
    final (s1, b1) = await postJson('roots', {'fingerprint': 'UNKNOWN'});
    expect(s1, 403);
    expect(b1['error'], 'unknown');

    await container.redux(favoritesProvider).dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'FPELSEWHERE', ip: '10.0.0.9', port: 53317, alias: 'Far').copyWith(trustLevel: TrustLevel.full),
          ),
        );
    final (s2, b2) = await postJson('roots', {'fingerprint': 'FPELSEWHERE'});
    expect(s2, 403);
    expect(b2['error'], 'ip_mismatch');

    await container.redux(favoritesProvider).dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'FPTEMP', ip: '127.0.0.1', port: 53317, alias: 'Temp').copyWith(trustLevel: TrustLevel.temp),
          ),
        );
    final (s3, b3) = await postJson('roots', {'fingerprint': 'FPTEMP'});
    expect(s3, 403);
    expect(b3['error'], 'temp_not_allowed');
  });

  test('list: entries with trash hidden, traversal rejected', () async {
    final (status, body) = await postJson('list', rootReq());
    expect(status, 200);
    final names = (body['entries'] as List).map((e) => e['name']).toList();
    expect(names, containsAll(['hello.txt', 'sub']));
    expect(names, isNot(contains('.anyshare_trash')));
    expect(body['writable'], isTrue);

    final (s2, b2) = await postJson('list', {...rootReq(), 'path': '../..'});
    expect(s2, 400);
    expect(b2['error'], 'invalid_path');

    final (s3, b3) = await postJson('list', {'fingerprint': 'FPPEER', 'root': 'missing'});
    expect(s3, 403);
    expect(b3['error'], 'not_found');
  });

  test('download: file bytes roundtrip', () async {
    final (status, bytes) = await postQuery('download', {'fingerprint': 'FPPEER', 'root': 'root1', 'path': 'hello.txt'});
    expect(status, 200);
    expect(utf8.decode(bytes), 'hello world');

    final (s2, _) = await postQuery('download', {'fingerprint': 'FPPEER', 'root': 'root1', 'path': 'sub'});
    expect(s2, 404);
  });

  test('upload: writes, renames on conflict, overwrites on demand', () async {
    final (s1, b1) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '', 'name': 'up.txt', 'onConflict': 'rename'},
      utf8.encode('one'),
    );
    expect(s1, 200);
    expect(asJson(b1)['finalName'], 'up.txt');
    expect(File(p.join(root.path, 'up.txt')).readAsStringSync(), 'one');

    final (s2, b2) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '', 'name': 'up.txt', 'onConflict': 'rename'},
      utf8.encode('two'),
    );
    expect(s2, 200);
    expect(asJson(b2)['finalName'], 'up(1).txt');
    expect(File(p.join(root.path, 'up(1).txt')).readAsStringSync(), 'two');

    final (s3, _) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '', 'name': 'up.txt', 'onConflict': 'overwrite'},
      utf8.encode('three'),
    );
    expect(s3, 200);
    expect(File(p.join(root.path, 'up.txt')).readAsStringSync(), 'three');
  });

  test('write ops on read-only roots are rejected', () async {
    final (s1, b1) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'ro1', 'path': '', 'name': 'x.txt'},
      utf8.encode('x'),
    );
    expect(s1, 403);
    expect(b1, isNotNull);

    final (s2, b2) = await postJson('mkdir', {...rootReq('ro1'), 'path': '', 'name': 'dir'});
    expect(s2, 403);
  });

  test('upload rejects internal names and traversal', () async {
    final (s1, b1) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '', 'name': '.anyshare_tmp_x'},
      utf8.encode('x'),
    );
    expect(s1, 400);

    final (s2, _) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '..', 'name': 'x.txt'},
      utf8.encode('x'),
    );
    expect(s2, 400);
  });

  test('mkdir, rename and delete-to-trash', () async {
    final (s1, _) = await postJson('mkdir', {...rootReq(), 'path': '', 'name': 'newdir'});
    expect(s1, 200);
    expect(Directory(p.join(root.path, 'newdir')).existsSync(), isTrue);

    final (s2, b2) = await postJson('rename', {...rootReq(), 'path': 'newdir', 'newName': 'renamed'});
    expect(s2, 200);
    expect(b2['finalName'], 'renamed');
    expect(Directory(p.join(root.path, 'renamed')).existsSync(), isTrue);

    final (s3, _) = await postJson('delete', {...rootReq(), 'path': 'hello.txt', 'trash': true});
    expect(s3, 200);
    expect(File(p.join(root.path, 'hello.txt')).existsSync(), isFalse);
    final trashEntries = Directory(p.join(root.path, '.anyshare_trash')).listSync();
    expect(trashEntries.where((e) => e.path.endsWith('-hello.txt')), hasLength(1));

    final (s4, _) = await postJson('delete', {...rootReq(), 'path': '', 'trash': true});
    expect(s4, 400, reason: 'the root itself can never be deleted');
  });

  test('root identity is protected for dot paths and aliases', () async {
    final (s1, b1) = await postJson('delete', {...rootReq(), 'path': '.', 'trash': true});
    expect(s1, 400);
    expect(b1['error'], 'invalid_path');

    final (s2, _) = await postJson('delete', {...rootReq(), 'path': 'sub/..', 'trash': false});
    expect(s2, 400);

    final (s3, _) = await postJson('rename', {...rootReq(), 'path': '.', 'newName': 'moved'});
    expect(s3, 400);
    expect(Directory(root.path).existsSync(), isTrue, reason: 'the root must not move');
  });

  test('internal trash is unreachable through the protocol', () async {
    File(p.join(root.path, '.anyshare_trash', 'gone.txt')).writeAsStringSync('secret');
    final (s1, b1) = await postJson('list', {...rootReq(), 'path': '.anyshare_trash'});
    expect(s1, 400);
    expect(b1['error'], 'invalid_path');

    final (s2, _) = await postQuery('download', {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '.anyshare_trash/gone.txt'});
    expect(s2, 400);
  });

  test('permanent delete (trash=false) removes the file', () async {
    final (s1, _) = await postJson('delete', {...rootReq(), 'path': 'hello.txt', 'trash': false});
    expect(s1, 200);
    expect(File(p.join(root.path, 'hello.txt')).existsSync(), isFalse);
  });

  test('limited devices are read-only through the endpoints', () async {
    await container.redux(favoritesProvider).dispatchAsync(
          AddFavoriteAction(
            FavoriteDevice.fromValues(fingerprint: 'FPLIM', ip: '127.0.0.1', port: 53317, alias: 'Lim').copyWith(trustLevel: TrustLevel.limited),
          ),
        );
    final (s1, _) = await postJson('list', {'fingerprint': 'FPLIM', 'root': 'root1'});
    expect(s1, 200);
    final (s2, b2) = await postQuery(
      'upload',
      {'fingerprint': 'FPLIM', 'root': 'root1', 'path': '', 'name': 'nope.txt'},
      utf8.encode('x'),
    );
    expect(s2, 403);
    expect(asJson(b2)['error'], 'read_only');
  });

  test('upload rejects length mismatch and cleans tmp files', () async {
    final (s1, _) = await postQuery(
      'upload',
      {'fingerprint': 'FPPEER', 'root': 'root1', 'path': '', 'name': 'sized.txt', 'size': '10'},
      utf8.encode('short'),
    );
    expect(s1, 400);
    expect(File(p.join(root.path, 'sized.txt')).existsSync(), isFalse);
    // The server cleans tmp files right after responding: poll briefly.
    var leftovers = <FileSystemEntity>[];
    for (var i = 0; i < 40; i++) {
      leftovers = Directory(root.path).listSync().where((e) => p.basename(e.path).startsWith('.anyshare_tmp_')).toList();
      if (leftovers.isEmpty) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(leftovers, isEmpty, reason: 'tmp files must be cleaned up');
  });
}
