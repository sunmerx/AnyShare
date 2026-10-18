import 'package:localsend_app/provider/network/dir_client.dart';

/// AnyShare modification (2026-10-18): pure helpers for the shared-directory
/// browser (E3-3c/E3-3d).

enum DirSortBy { name, size, modified }

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

/// Directories first, then by [by]/[ascending]; ties fall back to name.
List<DirEntry> sortDirEntriesBy(List<DirEntry> entries, {required DirSortBy by, required bool ascending}) {
  final sorted = [...entries];
  int nameCompare(DirEntry a, DirEntry b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
  sorted.sort((a, b) {
    if (a.isDir != b.isDir) {
      return a.isDir ? -1 : 1;
    }
    var cmp = switch (by) {
      DirSortBy.name => nameCompare(a, b),
      DirSortBy.size => (a.size ?? 0).compareTo(b.size ?? 0),
      DirSortBy.modified => (a.modified ?? 0).compareTo(b.modified ?? 0),
    };
    if (cmp == 0 && by != DirSortBy.name) {
      cmp = nameCompare(a, b);
    }
    return ascending ? cmp : -cmp;
  });
  return sorted;
}

/// Name search (case-insensitive substring) and tag filter (entry matches if
/// any of its tags is selected). [tagsByName] maps entry name -> tags.
List<DirEntry> filterDirEntries(
  List<DirEntry> entries, {
  required String query,
  required Set<String> tagFilter,
  required Map<String, List<String>> tagsByName,
}) {
  final q = query.trim().toLowerCase();
  return [
    for (final entry in entries)
      if ((q.isEmpty || entry.name.toLowerCase().contains(q)) && (tagFilter.isEmpty || (tagsByName[entry.name] ?? const []).any(tagFilter.contains)))
        entry,
  ];
}

/// Preview classification and byte caps (E3-3d). Kept here so the widget and
/// tests share one source of truth.
enum DirPreviewKind { image, markdown, text, unsupported }

const kDirPreviewImageMaxBytes = 10 * 1024 * 1024;
const kDirPreviewMarkdownMaxBytes = 2 * 1024 * 1024;
const kDirPreviewTextMaxBytes = 1024 * 1024;

const _kImageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
const _kTextExts = {
  'txt',
  'log',
  'json',
  'yaml',
  'yml',
  'xml',
  'ini',
  'conf',
  'cfg',
  'csv',
  'tsv',
  'dart',
  'py',
  'js',
  'ts',
  'html',
  'css',
  'sh',
  'bat',
  'ps1',
  'sql',
  'c',
  'h',
  'cpp',
  'hpp',
  'rs',
  'go',
  'java',
  'kt',
  'swift',
  'toml',
  'env',
};

int dirPreviewCapOf(DirPreviewKind kind) => switch (kind) {
  DirPreviewKind.image => kDirPreviewImageMaxBytes,
  DirPreviewKind.markdown => kDirPreviewMarkdownMaxBytes,
  DirPreviewKind.text => kDirPreviewTextMaxBytes,
  DirPreviewKind.unsupported => 0,
};

DirPreviewKind dirPreviewKindOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) {
    // No extension or a dotfile like `.bashrc`/`a.` -> not previewable.
    return DirPreviewKind.unsupported;
  }
  final ext = name.substring(dot + 1).toLowerCase();
  if (_kImageExts.contains(ext)) {
    return DirPreviewKind.image;
  }
  if (ext == 'md' || ext == 'markdown') {
    return DirPreviewKind.markdown;
  }
  if (_kTextExts.contains(ext)) {
    return DirPreviewKind.text;
  }
  return DirPreviewKind.unsupported;
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
