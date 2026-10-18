import 'dart:io';

import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/util/dir_browse.dart';
import 'package:path/path.dart' as p;

/// AnyShare modification (2026-10-18): cross-device relay for the shared
/// directory browser (E3-4). Copies/moves entries between two devices by
/// staging files through a local temp file (never fully buffered in memory).

class DirRelayResult {
  final int copied;
  final int failed;

  /// Transferred successfully but the source copy could not be removed
  /// (move only). The clipboard must be kept in that case.
  final int deleteFailed;
  final bool truncated;
  final List<String> errors;

  const DirRelayResult({
    required this.copied,
    required this.failed,
    this.deleteFailed = 0,
    required this.truncated,
    required this.errors,
  });

  bool get ok => failed == 0 && deleteFailed == 0 && !truncated;
}

const int kDirRelayMaxEntries = 2000;
const int kDirRelayMaxDepth = 32;

/// Staging folders older than this are swept on the next relay start.
const Duration _kStagingMaxAge = Duration(hours: 24);

class _RelayLimitException implements Exception {}

/// Relays [entries] from the source (root [sourceRoot], dir [sourcePath]) into
/// the target (root [targetRoot], dir [targetPath]). With [move] the source
/// entries are deleted after their transfer succeeded (directories are
/// emptied child by child, then removed).
///
/// [onProgress] reports (done, total, currentName); `total` counts top-level
/// entries only. Failures are collected per top-level entry, never thrown.
Future<DirRelayResult> relayDirEntries({
  required DirClient source,
  required String sourceRoot,
  required String sourcePath,
  required DirClient target,
  required String targetRoot,
  required String targetPath,
  required List<DirEntry> entries,
  required bool move,
  void Function(int done, int total, String current)? onProgress,
  int maxEntries = kDirRelayMaxEntries,
  int maxDepth = kDirRelayMaxDepth,
}) async {
  _sweepStaleStaging();
  final staging = Directory.systemTemp.createTempSync('anyshare_relay_');
  var visited = 0;
  var copied = 0;
  var failed = 0;
  var deleteFailed = 0;
  var truncated = false;
  final errors = <String>[];
  final total = entries.length;

  // Same physical host when both dialers address the same endpoint identity:
  // a directory must never be pasted into itself or a descendant of itself.
  final sameDevice = source.host == target.host && source.extPort == target.extPort && source.fingerprint == target.fingerprint;

  String errorCode(Object e) => e is DirClientException ? e.code : 'unreachable';

  Future<void> deleteSource(String srcRel) async {
    try {
      await source.delete(root: sourceRoot, path: srcRel);
    } catch (e) {
      deleteFailed++;
      errors.add('move_delete_failed');
    }
  }

  Future<void> relayOne(DirEntry entry, String srcRel, String tgtDir, int depth) async {
    if (depth > maxDepth) {
      throw _RelayLimitException();
    }
    visited++;
    if (visited > maxEntries) {
      throw _RelayLimitException();
    }
    if (entry.isDir) {
      if (sameDevice && (tgtDir == srcRel || tgtDir.startsWith('$srcRel/'))) {
        throw const DirClientException('invalid_path');
      }
      // Create the directory on the target, disambiguating conflicts the same
      // way uploads do (`name(1)`).
      var targetName = entry.name;
      var created = false;
      for (var attempt = 0; attempt < 50 && !created; attempt++) {
        try {
          await target.mkdir(root: targetRoot, path: tgtDir, name: targetName);
          created = true;
        } on DirClientException catch (e) {
          if (e.code != 'conflict') {
            rethrow;
          }
          targetName = _suffixed(entry.name, attempt + 1);
        }
      }
      if (!created) {
        throw const DirClientException('conflict');
      }
      final listing = await source.list(root: sourceRoot, path: srcRel);
      if (listing.truncated) {
        // The listing is capped server-side; relaying it partially and then
        // deleting the source (move) would silently lose entries.
        throw const DirClientException('too_large');
      }
      for (final child in listing.entries) {
        await relayOne(child, joinDirPath(srcRel, child.name), joinDirPath(tgtDir, targetName), depth + 1);
      }
      if (move) {
        await deleteSource(srcRel);
      }
    } else {
      final temp = File(p.join(staging.path, 'stage_$visited'));
      try {
        await source.downloadToFile(root: sourceRoot, path: srcRel, target: temp);
        await target.uploadFile(root: targetRoot, path: tgtDir, source: temp, name: entry.name, onConflict: 'rename');
      } finally {
        try {
          if (temp.existsSync()) {
            temp.deleteSync();
          }
        } catch (_) {}
      }
      if (move) {
        await deleteSource(srcRel);
      }
    }
  }

  try {
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      onProgress?.call(i, total, entry.name);
      try {
        await relayOne(entry, joinDirPath(sourcePath, entry.name), targetPath, 1);
        copied++;
      } on _RelayLimitException {
        truncated = true;
        failed += entries.length - i;
        errors.add('limit');
        onProgress?.call(i + 1, total, entry.name);
        break;
      } catch (e) {
        failed++;
        errors.add(errorCode(e));
      }
      onProgress?.call(i + 1, total, entry.name);
    }
  } finally {
    try {
      staging.deleteSync(recursive: true);
    } catch (_) {}
  }
  return DirRelayResult(copied: copied, failed: failed, deleteFailed: deleteFailed, truncated: truncated, errors: errors);
}

/// Removes leftover staging folders from crashed relays. Only touches folders
/// older than [_kStagingMaxAge] so a concurrently running relay (possibly in
/// another app instance) is never disturbed.
void _sweepStaleStaging() {
  try {
    final now = DateTime.now();
    for (final entity in Directory.systemTemp.listSync()) {
      final name = p.basename(entity.path);
      if (name.startsWith('anyshare_relay_') && entity is Directory) {
        try {
          if (now.difference(entity.statSync().modified) > _kStagingMaxAge) {
            entity.deleteSync(recursive: true);
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
}

String _suffixed(String name, int n) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) {
    return '$name($n)';
  }
  return '${name.substring(0, dot)}($n)${name.substring(dot)}';
}
