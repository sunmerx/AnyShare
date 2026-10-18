import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/persistence/shared_dir_config.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/shared_dirs_provider.dart';
import 'package:localsend_app/util/dir_access.dart';
import 'package:localsend_app/util/dir_paths.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// AnyShare modification (2026-10-18): E-3 shared directory endpoints
/// (docs/E3-1-设计-共享目录协议.md §3).
///
/// - JSON endpoints: `/dir/roots|list|meta|mkdir|rename|delete`
/// - Binary endpoints (metadata via query string, body/response raw):
///   `/dir/upload`, `/dir/download`
/// - Access gate: favorite lookup by self-reported fingerprint + stored-IP
///   match (fail-closed); writes additionally require a writable directory
///   and (same-owner or full trust + per-device grant).

final _logger = Logger('DirEndpoints');
const _uuid = Uuid();

const _trashDirName = '.anyshare_trash';
const _tmpPrefix = '.anyshare_tmp_';

/// Listing cap shared with the browse UI (truncation hint).
const kDirMaxListEntries = 5000;

/// Upload cap (v1): larger files are rejected up front (507 would need a
/// cross-platform free-space probe; documented limitation).
const int _maxUploadBytes = 64 * 1024 * 1024 * 1024;

// Single extension server per app: top-level rate-limit state is fine.
// Browsing is chatty (a multi-select download is one request per file), so
// the budget is generous; idle entries are pruned while checking.
final Map<String, List<DateTime>> _dirRateWindow = {};
final Map<String, DateTime> _dirRateLockedUntil = {};

bool _dirRateLimited(String ip) {
  final now = DateTime.now();
  final lockedUntil = _dirRateLockedUntil[ip];
  if (lockedUntil != null) {
    if (now.isBefore(lockedUntil)) {
      return true;
    }
    _dirRateLockedUntil.remove(ip);
  }
  _dirRateWindow.removeWhere((key, times) => times.isEmpty || now.difference(times.last) > const Duration(minutes: 5));
  final window = _dirRateWindow.putIfAbsent(ip, () => [])..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
  window.add(now);
  if (window.length > 600) {
    _dirRateLockedUntil[ip] = now.add(const Duration(seconds: 30));
    return true;
  }
  return false;
}

extension DirEndpoints on ExtensionServerService {
  /// Returns true when the request was a `/dir/*` request (handled here).
  Future<bool> handleDirRequest(HttpRequest request) async {
    const prefix = '/api/anyshare/v1/dir/';
    final path = request.uri.path;
    if (!path.startsWith(prefix) || request.method != 'POST') {
      return false;
    }
    final endpoint = path.substring(prefix.length);
    final ip = request.connectionInfo!.remoteAddress.address.replaceAll('::ffff:', '');

    if (_dirRateLimited(ip)) {
      await writeJson(request, {'error': 'rate_limited'}, status: 429);
      return true;
    }

    try {
      switch (endpoint) {
        case 'roots':
          await _dirRoots(request, ip);
          break;
        case 'list':
          await _dirList(request, ip);
          break;
        case 'meta':
          await _dirMeta(request, ip);
          break;
        case 'download':
          await _dirDownload(request, ip);
          break;
        case 'upload':
          await _dirUpload(request, ip);
          break;
        case 'mkdir':
          await _dirMkdir(request, ip);
          break;
        case 'rename':
          await _dirRename(request, ip);
          break;
        case 'delete':
          await _dirDelete(request, ip);
          break;
        default:
          await writeJson(request, {'error': 'not_found'}, status: 404);
      }
    } catch (e, st) {
      _logger.warning('dir/$endpoint failed: $e\n$st');
      try {
        await writeJson(request, {'error': 'internal'}, status: 500);
      } catch (_) {}
    }
    return true;
  }

  // ---------- access helpers ----------

  ({DirAccessResult access, SharedDirConfig? root}) _access(
    String fingerprint,
    String? rootId,
    String requesterIp,
  ) {
    final entry = _mostRestrictiveEntry(fingerprint);
    final roots = ref.read(sharedDirsProvider);
    final root = rootId == null ? null : roots.where((r) => r.id == rootId).firstOrNull;
    if (rootId != null && root == null) {
      return (access: const DirAccessResult(DirAccess.none, 'not_found'), root: null);
    }
    final access = evaluateDirAccess(
      entry: entry,
      requesterIp: requesterIp,
      myOwnerId: ref.read(ownerProvider).id,
      writable: root?.writable ?? false,
      writeGranted: ref.read(dirWriteGrantsProvider).contains(fingerprint),
    );
    return (access: access, root: root);
  }

  /// Duplicate favorites can exist (pairing/manual add append); pick the most
  /// restrictive matching entry so a stale permissive duplicate cannot shadow
  /// a newer blocked/limited one.
  FavoriteDevice? _mostRestrictiveEntry(String fingerprint) {
    final matches = ref.read(favoritesProvider).where((f) => f.fingerprint == fingerprint).toList();
    if (matches.isEmpty) {
      return null;
    }
    matches.sort((a, b) {
      int rank(FavoriteDevice f) {
        if (f.blocked) return 0;
        return switch (f.trustLevel) {
          TrustLevel.temp => 1,
          TrustLevel.limited => 2,
          TrustLevel.full => 3,
        };
      }

      return rank(a).compareTo(rank(b));
    });
    return matches.first;
  }

  /// Parses the JSON body, then applies the access gate.
  Future<({DirAccessResult access, SharedDirConfig root, Map<String, dynamic> body})?> _gateJson(
    HttpRequest request,
    String ip, {
    bool needsWrite = false,
  }) async {
    final body = await readJsonBody(request);
    final fingerprint = body?['fingerprint'];
    final rootId = body?['root'];
    if (body == null || fingerprint is! String || fingerprint.isEmpty || rootId is! String || rootId.isEmpty) {
      await writeJson(request, {'error': 'bad_request'}, status: 400);
      return null;
    }
    final result = _access(fingerprint, rootId, ip);
    if (result.access.denied || result.root == null) {
      await writeJson(request, {'error': result.access.reason ?? 'not_found'}, status: 403);
      return null;
    }
    if (needsWrite && result.access.access != DirAccess.readWrite) {
      await writeJson(request, {'error': 'read_only'}, status: 403);
      return null;
    }
    return (access: result.access, root: result.root!, body: body);
  }

  /// Applies the access gate for binary endpoints (metadata via query string).
  Future<({DirAccessResult access, SharedDirConfig root, Map<String, String> query})?> _gateQuery(
    HttpRequest request,
    String ip, {
    bool needsWrite = false,
  }) async {
    final q = request.uri.queryParameters;
    final fingerprint = q['fingerprint'];
    final rootId = q['root'];
    if (fingerprint == null || fingerprint.isEmpty || rootId == null || rootId.isEmpty) {
      await writeJson(request, {'error': 'bad_request'}, status: 400);
      return null;
    }
    final result = _access(fingerprint, rootId, ip);
    if (result.access.denied || result.root == null) {
      await writeJson(request, {'error': result.access.reason ?? 'not_found'}, status: 403);
      return null;
    }
    if (needsWrite && result.access.access != DirAccess.readWrite) {
      await writeJson(request, {'error': 'read_only'}, status: 403);
      return null;
    }
    return (access: result.access, root: result.root!, query: q);
  }

  String _strField(Map<String, dynamic> body, String key) {
    final value = body[key];
    return value is String ? value : '';
  }

  /// True when the (existing) resolved path IS the shared root itself
  /// (canonical comparison; guards against `.`, `sub/..` and path aliases).
  Future<bool> _isRootItself(String resolvedAbs, SharedDirConfig root) async {
    if (p.equals(resolvedAbs, p.normalize(root.path))) {
      return true;
    }
    try {
      final a = await File(resolvedAbs).resolveSymbolicLinks();
      final b = await Directory(root.path).resolveSymbolicLinks();
      return p.equals(a, b);
    } on FileSystemException {
      return false;
    }
  }

  // ---------- endpoints ----------

  Future<void> _dirRoots(HttpRequest request, String ip) async {
    final body = await readJsonBody(request);
    final fingerprint = body?['fingerprint'];
    if (body == null || fingerprint is! String || fingerprint.isEmpty) {
      await writeJson(request, {'error': 'bad_request'}, status: 400);
      return;
    }
    final result = _access(fingerprint, null, ip);
    if (result.access.denied) {
      await writeJson(request, {'error': result.access.reason}, status: 403);
      return;
    }
    final grants = ref.read(dirWriteGrantsProvider);
    final entry = _mostRestrictiveEntry(fingerprint);
    final myOwnerId = ref.read(ownerProvider).id;
    await writeJson(request, {
      'roots': [
        for (final root in ref.read(sharedDirsProvider))
          {
            'id': root.id,
            'name': root.name.isEmpty ? p.basename(root.path) : root.name,
            'writable':
                evaluateDirAccess(
                  entry: entry,
                  requesterIp: ip,
                  myOwnerId: myOwnerId,
                  writable: root.writable,
                  writeGranted: grants.contains(fingerprint),
                ).access ==
                DirAccess.readWrite,
          },
      ],
    });
  }

  Future<void> _dirList(HttpRequest request, String ip) async {
    final gate = await _gateJson(request, ip);
    if (gate == null) {
      return;
    }
    final relative = _strField(gate.body, 'path');
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final dir = Directory(resolved.absolute!);
    if (!await dir.exists()) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }

    final entries = <Map<String, dynamic>>[];
    var truncated = false;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.anyshare_')) {
        continue;
      }
      if (entries.length >= kDirMaxListEntries) {
        truncated = true;
        break;
      }
      final isLink = entity is Link;
      final isDir = entity is Directory;
      int? size;
      int? modified;
      if (!isLink) {
        try {
          final stat = await entity.stat();
          size = isDir ? null : stat.size;
          modified = stat.modified.millisecondsSinceEpoch;
        } on FileSystemException {
          // Unreadable entry: still list it.
        }
      }
      entries.add({
        'name': name,
        'isDir': isDir,
        'isLink': isLink,
        'size': size,
        'modified': modified,
      });
    }
    entries.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    await writeJson(request, {
      'entries': entries,
      'writable': gate.access.access == DirAccess.readWrite,
      'truncated': truncated,
    });
  }

  Future<void> _dirMeta(HttpRequest request, String ip) async {
    final gate = await _gateJson(request, ip);
    if (gate == null) {
      return;
    }
    final relative = _strField(gate.body, 'path');
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final type = await FileSystemEntity.type(resolved.absolute!, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }
    if (type == FileSystemEntityType.directory) {
      await writeJson(request, {'isDir': true, 'size': null, 'modified': null});
      return;
    }
    if (type == FileSystemEntityType.link) {
      // Symlinks are reported as file-like; download follows them.
      await writeJson(request, {'isDir': false, 'isLink': true, 'size': null, 'modified': null});
      return;
    }
    final stat = await File(resolved.absolute!).stat();
    await writeJson(request, {'isDir': false, 'size': stat.size, 'modified': stat.modified.millisecondsSinceEpoch});
  }

  Future<void> _dirDownload(HttpRequest request, String ip) async {
    final gate = await _gateQuery(request, ip);
    if (gate == null) {
      return;
    }
    final relative = gate.query['path'] ?? '';
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final file = File(resolved.absolute!);
    if (!await file.exists()) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }
    final length = await file.length();
    final response = request.response;
    response.statusCode = 200;
    response.headers.contentType = ContentType.binary;
    response.contentLength = length;
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _dirUpload(HttpRequest request, String ip) async {
    final gate = await _gateQuery(request, ip, needsWrite: true);
    if (gate == null) {
      return;
    }
    final relative = gate.query['path'] ?? '';
    final name = gate.query['name'] ?? '';
    final onConflict = gate.query['onConflict'] ?? 'rename';
    if (!isValidDirEntryName(name)) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }
    final expected = int.tryParse(gate.query['size'] ?? '') ?? request.contentLength;
    if (expected > _maxUploadBytes) {
      await writeJson(request, {'error': 'too_large'}, status: 413);
      return;
    }
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final targetDir = Directory(resolved.absolute!);
    if (!await targetDir.exists()) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }

    var finalName = name;
    var target = File(p.join(targetDir.path, finalName));
    if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
      if (onConflict == 'overwrite') {
        // Write through the tmp file and replace below.
      } else {
        finalName = _uniqueName(targetDir.path, name);
        target = File(p.join(targetDir.path, finalName));
      }
    }

    final tmp = File(p.join(targetDir.path, '$_tmpPrefix${_uuid.v4()}'));
    var written = 0;
    var ok = false;
    try {
      final sink = tmp.openWrite();
      // addStream applies backpressure (pauses the request when the disk
      // is slower than the network).
      await sink.addStream(request);
      await sink.close();
      written = await tmp.length();
      if (expected >= 0 && written != expected) {
        await writeJson(request, {'error': 'bad_request'}, status: 400);
        return;
      }

      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        if (onConflict == 'overwrite') {
          // Windows cannot rename onto an existing file.
          try {
            await target.delete();
            await tmp.rename(target.path);
          } on FileSystemException catch (e) {
            _logger.warning('overwrite rename failed: $e');
            await writeJson(request, {'error': 'write_failed'}, status: 500);
            return;
          }
        } else {
          // Lost the race with a concurrent upload: pick a fresh name.
          finalName = _uniqueName(targetDir.path, name);
          target = File(p.join(targetDir.path, finalName));
          try {
            await tmp.rename(target.path);
          } on FileSystemException catch (e) {
            _logger.warning('rename-mode retry failed: $e');
            await writeJson(request, {'error': 'conflict'}, status: 409);
            return;
          }
        }
      }
      ok = true;
      await writeJson(request, {'ok': true, 'finalName': finalName});
    } on HttpException catch (e) {
      // Client aborted mid-upload.
      _logger.fine('upload aborted: $e');
      try {
        await writeJson(request, {'error': 'aborted'}, status: 400);
      } catch (_) {}
    } finally {
      if (!ok) {
        try {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        } catch (e) {
          _logger.warning('tmp cleanup failed: $e');
        }
      }
    }
  }

  Future<void> _dirMkdir(HttpRequest request, String ip) async {
    final gate = await _gateJson(request, ip, needsWrite: true);
    if (gate == null) {
      return;
    }
    final relative = _strField(gate.body, 'path');
    final name = _strField(gate.body, 'name');
    if (!isValidDirEntryName(name)) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final parent = Directory(resolved.absolute!);
    if (!await parent.exists()) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }
    final target = p.join(parent.path, name);
    if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      await writeJson(request, {'error': 'conflict'}, status: 409);
      return;
    }
    try {
      await Directory(target).create();
    } on FileSystemException {
      await writeJson(request, {'error': 'conflict'}, status: 409);
      return;
    }
    await writeJson(request, {'ok': true});
  }

  Future<void> _dirRename(HttpRequest request, String ip) async {
    final gate = await _gateJson(request, ip, needsWrite: true);
    if (gate == null) {
      return;
    }
    final relative = _strField(gate.body, 'path');
    final newName = _strField(gate.body, 'newName');
    if (!isValidDirEntryName(newName) || relative.isEmpty) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final source = resolved.absolute!;
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }
    if (await _isRootItself(source, gate.root)) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }
    final target = p.join(p.dirname(source), newName);
    if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      await writeJson(request, {'error': 'conflict'}, status: 409);
      return;
    }
    try {
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(source).rename(target);
          break;
        case FileSystemEntityType.link:
          await Link(source).rename(target);
          break;
        default:
          await File(source).rename(target);
      }
    } on FileSystemException {
      await writeJson(request, {'error': 'write_failed'}, status: 500);
      return;
    }
    await writeJson(request, {'ok': true, 'finalName': newName});
  }

  Future<void> _dirDelete(HttpRequest request, String ip) async {
    final gate = await _gateJson(request, ip, needsWrite: true);
    if (gate == null) {
      return;
    }
    final relative = _strField(gate.body, 'path');
    if (relative.isEmpty) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }
    final trash = gate.body['trash'] != false; // default: trash
    final resolved = await resolveDirPath(gate.root.path, relative);
    if (resolved.error != null) {
      await writeJson(request, {'error': resolved.error}, status: 400);
      return;
    }
    final source = resolved.absolute!;
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await writeJson(request, {'error': 'not_found'}, status: 404);
      return;
    }
    // `.` / `sub/..` / aliases must never delete the shared root itself.
    if (await _isRootItself(source, gate.root)) {
      await writeJson(request, {'error': 'invalid_path'}, status: 400);
      return;
    }

    if (trash) {
      final trashDir = Directory(p.join(gate.root.path, _trashDirName));
      await trashDir.create(recursive: true);
      final base = p.basename(source);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final trashName = '$stamp-${_uuid.v4().substring(0, 8)}-$base';
      final target = p.join(trashDir.path, trashName);
      try {
        switch (type) {
          case FileSystemEntityType.directory:
            await Directory(source).rename(target);
            break;
          case FileSystemEntityType.link:
            await Link(source).rename(target);
            break;
          default:
            await File(source).rename(target);
        }
      } on FileSystemException {
        await writeJson(request, {'error': 'write_failed'}, status: 500);
        return;
      }
      // Meta written atomically next to the trashed item.
      final metaTmp = File('$target.meta.json.tmp');
      await metaTmp.writeAsString(
        jsonEncode({
          'originalPath': relative,
          'deletedAt': stamp,
        }),
      );
      await metaTmp.rename('$target.meta.json');
      await writeJson(request, {'ok': true});
      return;
    }

    try {
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(source).delete(recursive: true);
          break;
        case FileSystemEntityType.link:
          await Link(source).delete();
          break;
        default:
          await File(source).delete();
      }
    } on FileSystemException {
      await writeJson(request, {'error': 'write_failed'}, status: 500);
      return;
    }
    await writeJson(request, {'ok': true});
  }
}

/// Picks `name(1).ext`, `name(2).ext`, ... when [name] already exists in
/// [dirPath].
String _uniqueName(String dirPath, String name) {
  final ext = p.extension(name);
  final base = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  for (var i = 1; i < 1000; i++) {
    final candidate = '$base($i)$ext';
    final joined = p.join(dirPath, candidate);
    if (FileSystemEntity.typeSync(joined, followLinks: false) == FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return '$base(${DateTime.now().millisecondsSinceEpoch})$ext';
}
