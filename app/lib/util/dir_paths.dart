import 'dart:io';

import 'package:path/path.dart' as p;

/// AnyShare modification (2026-10-18): E-3 path resolution and traversal
/// protection (docs/E3-1-设计-共享目录协议.md §6).
///
/// [resolveDirPath] normalizes a client-supplied relative path under a shared
/// root and verifies it stays inside the root — including via symlinks
/// (realpath of the deepest existing ancestor is checked against the root's
/// realpath). Returns an error code string on rejection.
class DirPathResult {
  final String? absolute;

  /// `invalid_path` when the relative path escapes the root or is malformed.
  final String? error;

  const DirPathResult.ok(this.absolute) : error = null;
  const DirPathResult.err(this.error) : absolute = null;
}

Future<DirPathResult> resolveDirPath(String rootPath, String relative) async {
  final rel = relative.replaceAll('\\', '/');
  if (rel.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(rel)) {
    return const DirPathResult.err('invalid_path');
  }
  // Internal directories (.anyshare_trash, .anyshare_tmp_*) are never
  // reachable through the client protocol.
  final segments = p.split(p.normalize(rel));
  if (segments.any((s) => s.startsWith('.anyshare_'))) {
    return const DirPathResult.err('invalid_path');
  }
  final normalized = p.normalize(p.join(rootPath, rel));
  final root = p.normalize(rootPath);
  if (normalized != root && !p.isWithin(root, normalized)) {
    return const DirPathResult.err('invalid_path');
  }

  // Symlink escape check: resolve the deepest existing ancestor of the
  // target and require it to live inside the resolved root.
  try {
    final rootReal = await Directory(root).resolveSymbolicLinks();
    var probe = normalized;
    while (true) {
      final type = await FileSystemEntity.type(probe);
      if (type != FileSystemEntityType.notFound) {
        break;
      }
      final parent = p.dirname(probe);
      if (parent == probe) {
        // Reached the filesystem root without finding anything.
        return const DirPathResult.err('invalid_path');
      }
      probe = parent;
    }
    final probeReal = await File(probe).resolveSymbolicLinks();
    if (probeReal != rootReal && !p.isWithin(rootReal, probeReal)) {
      return const DirPathResult.err('invalid_path');
    }
  } on FileSystemException {
    return const DirPathResult.err('invalid_path');
  }
  return DirPathResult.ok(normalized);
}

/// Validates a client-supplied single path segment (file/directory name).
/// Rejects separators, traversal, empty names, the internal trash/tmp
/// prefixes, Windows-invalid characters/reserved device names and
/// trailing dot/space aliases.
bool isValidDirEntryName(String name) {
  if (name.isEmpty || name == '.' || name == '..') {
    return false;
  }
  if (name.contains('/') || name.contains('\\')) {
    return false;
  }
  if (name.startsWith('.anyshare_')) {
    return false;
  }
  // Windows: forbidden characters, control chars, trailing dot/space.
  if (RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(name)) {
    return false;
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    return false;
  }
  // Windows: reserved device names (with or without extension).
  final base = name.split('.').first.toUpperCase();
  const reserved = {'CON', 'PRN', 'AUX', 'NUL'};
  if (reserved.contains(base) || RegExp(r'^(COM|LPT)[1-9]$').hasMatch(base)) {
    return false;
  }
  return true;
}
