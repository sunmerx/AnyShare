import 'package:localsend_app/provider/network/dir_client.dart';

/// AnyShare modification (2026-10-18): pure helpers for the shared-directory
/// browser (E3-3c).

/// Directories first, then files, case-insensitive by name.
List<DirEntry> sortDirEntries(List<DirEntry> entries) {
  final sorted = [...entries];
  sorted.sort((a, b) {
    if (a.isDir != b.isDir) {
      return a.isDir ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return sorted;
}

/// Parent of a relative directory path (`''` is the root; `a/b` -> `a`).
String parentDirPath(String path) {
  if (path.isEmpty) {
    return '';
  }
  final index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}

/// Joins a relative path with a child name.
String joinDirPath(String path, String name) {
  return path.isEmpty ? name : '$path/$name';
}

/// Human-readable byte size (binary units, one decimal above KB).
String formatDirSize(int bytes) {
  if (bytes < 0) {
    return '';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
