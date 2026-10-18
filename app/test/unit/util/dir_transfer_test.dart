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
import 'package:localsend_app/util/dir_transfer.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Relay tests run two extension servers (device A and device B) in one test
/// process; each side favorites the other's fingerprint so the access gates
/// pass.
void main() {
  Map<String, Object> seed() => {
    'flutter.ls_security_context': jsonEncode({
      'privateKey': 'TEST',
      'publicKey': 'TEST',
      'certificate': 'TEST',
      'certificateHash': 'TESTHASH123',
    }),
  };

  late RefenaContainer containerA;
  late RefenaContainer containerB;
  late Directory rootA;
  late Directory rootB;
  late int portA;
  late int portB;
  late DirClient clientToA;
  late DirClient clientToB;

  Future<RefenaContainer> startDevice({required Directory root, required String peerFingerprint, required SharedPreferences prefs}) async {
    final container = RefenaContainer();
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
            FavoriteDevice.fromValues(
              fingerprint: peerFingerprint,
              ip: '127.0.0.1',
              port: 53317,
              alias: 'Peer',
            ).copyWith(trustLevel: TrustLevel.full),
          ),
        );
    await container.redux(dirWriteGrantsProvider).dispatchAsync(SetDirWriteGrantAction(fingerprint: peerFingerprint, granted: true));
    await container.redux(extensionServerProvider).dispatchAsync(StartExtensionServerAction(port: 0));
    return container;
  }

  setUp(() async {
    rootA = Directory.systemTemp.createTempSync('anyshare_relay_a');
    rootB = Directory.systemTemp.createTempSync('anyshare_relay_b');
    File(p.join(rootA.path, 'f1.txt')).writeAsStringSync('one');
    Directory(p.join(rootA.path, 'sub')).createSync();
    File(p.join(rootA.path, 'sub', 'f2.txt')).writeAsStringSync('two');

    // Each simulated device gets its own preferences store: sharing one store
    // would leak the first device's shared-dir config into the second.
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData(seed());
    containerA = await startDevice(root: rootA, peerFingerprint: 'FPLOCAL', prefs: await SharedPreferences.getInstance());
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData(seed());
    containerB = await startDevice(root: rootB, peerFingerprint: 'FPLOCAL', prefs: await SharedPreferences.getInstance());
    portA = containerA.read(extensionServerProvider).port ?? 0;
    portB = containerB.read(extensionServerProvider).port ?? 0;
    // Both hosts favorite the local browser device 'FPLOCAL' (as a real single
    // browsing device would appear to both peers).
    clientToA = DirClient(host: '127.0.0.1', extPort: portA, fingerprint: 'FPLOCAL');
    clientToB = DirClient(host: '127.0.0.1', extPort: portB, fingerprint: 'FPLOCAL');
  });

  tearDown(() async {
    await containerA.read(extensionServerProvider).server?.close(force: true);
    await containerB.read(extensionServerProvider).server?.close(force: true);
    for (final dir in [rootA, rootB]) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  Future<List<DirEntry>> listA() async => (await clientToA.list(root: 'root1', path: '')).entries;

  test('copy relays files and directories between devices', () async {
    final entries = await listA();
    final progress = <int>[];
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: entries,
      move: false,
      onProgress: (done, total, current) => progress.add(done),
    );
    expect(result.copied, 2);
    expect(result.failed, 0);
    expect(progress, isNotEmpty);
    expect(progress.last, 2);

    expect(File(p.join(rootB.path, 'f1.txt')).readAsStringSync(), 'one');
    expect(File(p.join(rootB.path, 'sub', 'f2.txt')).readAsStringSync(), 'two');
    // Source untouched by copy.
    expect(File(p.join(rootA.path, 'f1.txt')).existsSync(), isTrue);
    expect(File(p.join(rootA.path, 'sub', 'f2.txt')).existsSync(), isTrue);
  });

  test('move deletes the source after transfer', () async {
    final entries = await listA();
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: entries,
      move: true,
    );
    expect(result.copied, 2);
    expect(result.ok, isTrue);
    expect(File(p.join(rootB.path, 'f1.txt')).readAsStringSync(), 'one');
    expect(File(p.join(rootB.path, 'sub', 'f2.txt')).readAsStringSync(), 'two');
    expect(File(p.join(rootA.path, 'f1.txt')).existsSync(), isFalse);
    expect(Directory(p.join(rootA.path, 'sub')).existsSync(), isFalse);
  });

  test('conflicts are renamed, not overwritten', () async {
    File(p.join(rootB.path, 'f1.txt')).writeAsStringSync('existing');
    final entries = await listA();
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [entries.firstWhere((e) => e.name == 'f1.txt')],
      move: false,
    );
    expect(result.ok, isTrue);
    expect(File(p.join(rootB.path, 'f1.txt')).readAsStringSync(), 'existing');
    expect(File(p.join(rootB.path, 'f1(1).txt')).readAsStringSync(), 'one');
  });

  test('per-entry failures are collected without aborting the batch', () async {
    final entries = await listA();
    final ghost = const DirEntry(name: 'ghost.txt', isDir: false, isLink: false);
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [ghost, entries.firstWhere((e) => e.name == 'f1.txt')],
      move: false,
    );
    expect(result.copied, 1);
    expect(result.failed, 1);
    expect(result.errors, contains('not_found'));
    expect(File(p.join(rootB.path, 'f1.txt')).existsSync(), isTrue);
  });

  test('entry cap truncates the batch and reports it', () async {
    final entries = await listA();
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: entries,
      move: false,
      maxEntries: 1,
    );
    expect(result.truncated, isTrue);
    expect(result.errors, contains('limit'));
    expect(result.copied + result.failed, 2);
  });

  test('pasting a directory into itself is refused', () async {
    final entries = await listA();
    final sub = entries.firstWhere((e) => e.name == 'sub');
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToA,
      targetRoot: 'root1',
      targetPath: 'sub',
      entries: [sub],
      move: false,
    );
    expect(result.failed, 1);
    expect(result.errors, contains('invalid_path'));
    expect(Directory(p.join(rootA.path, 'sub', 'sub')).existsSync(), isFalse);
  });

  test('directory name conflicts are disambiguated', () async {
    Directory(p.join(rootB.path, 'sub')).createSync();
    final entries = await listA();
    final sub = entries.firstWhere((e) => e.name == 'sub');
    // Directories always keep both; `overwrite` only applies to files.
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [sub],
      move: false,
      onConflict: 'overwrite',
    );
    expect(result.ok, isTrue);
    expect(File(p.join(rootB.path, 'sub(1)', 'f2.txt')).readAsStringSync(), 'two');
    expect(Directory(p.join(rootB.path, 'sub')).existsSync(), isTrue);
  });

  test('pasting a file into its own directory is refused', () async {
    final entries = await listA();
    final f1 = entries.firstWhere((e) => e.name == 'f1.txt');
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToA,
      targetRoot: 'root1',
      targetPath: '',
      entries: [f1],
      move: true,
      onConflict: 'overwrite',
    );
    expect(result.failed, 1);
    expect(result.errors, contains('conflict'));
    expect(File(p.join(rootA.path, 'f1.txt')).readAsStringSync(), 'one');
  });

  test('move reports a failed source deletion separately and keeps the copy', () async {
    // Make the source read-only: the upload succeeds, the source delete fails.
    await containerA
        .redux(sharedDirsProvider)
        .dispatchAsync(
          UpdateSharedDirAction(SharedDirConfig(id: 'root1', path: rootA.path, name: 'Root', writable: false)),
        );
    final entries = await listA();
    final f1 = entries.firstWhere((e) => e.name == 'f1.txt');
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [f1],
      move: true,
    );
    expect(result.copied, 1);
    expect(result.deleteFailed, 1);
    expect(result.ok, isFalse);
    expect(result.errors, contains('move_delete_failed'));
    expect(File(p.join(rootB.path, 'f1.txt')).readAsStringSync(), 'one');
    expect(File(p.join(rootA.path, 'f1.txt')).existsSync(), isTrue);
  });

  test('depth cap stops deep recursion', () async {
    final entries = await listA();
    final sub = entries.firstWhere((e) => e.name == 'sub');
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [sub],
      move: false,
      maxDepth: 1,
    );
    expect(result.truncated, isTrue);
    expect(result.errors, contains('limit'));
    // The directory itself was created; the child beyond the depth cap was not.
    expect(Directory(p.join(rootB.path, 'sub')).existsSync(), isTrue);
    expect(File(p.join(rootB.path, 'sub', 'f2.txt')).existsSync(), isFalse);
  });

  test('overwrite policy replaces the target file', () async {
    File(p.join(rootB.path, 'f1.txt')).writeAsStringSync('existing');
    final entries = await listA();
    final f1 = entries.firstWhere((e) => e.name == 'f1.txt');
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [f1],
      move: false,
      onConflict: 'overwrite',
    );
    expect(result.ok, isTrue);
    expect(File(p.join(rootB.path, 'f1.txt')).readAsStringSync(), 'one');
    expect(File(p.join(rootB.path, 'f1(1).txt')).existsSync(), isFalse);
  });

  test('byte progress is reported monotonically for files', () async {
    final entries = await listA();
    final f1 = entries.firstWhere((e) => e.name == 'f1.txt');
    final fractions = <double>[];
    final result = await relayDirEntries(
      source: clientToA,
      sourceRoot: 'root1',
      sourcePath: '',
      target: clientToB,
      targetRoot: 'root1',
      targetPath: '',
      entries: [f1],
      move: false,
      onFileProgress: fractions.add,
    );
    expect(result.ok, isTrue);
    expect(fractions, isNotEmpty);
    final sorted = [...fractions]..sort();
    expect(fractions, orderedEquals(sorted));
    expect(fractions.last, closeTo(1.0, 0.001));
  });
}
