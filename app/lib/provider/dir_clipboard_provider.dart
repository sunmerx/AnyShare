import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): global cross-device clipboard for the
/// shared-directory browser (E3-4). Lives in a provider (not page state) so a
/// copy on one device can be pasted while browsing another.

class DirClipboard {
  /// Session key of the source device (the browsed device's fingerprint).
  final String sourceFingerprint;
  final String sourceHost;
  final String sourceRootId;
  final String sourcePath;
  final DirEntry entry;
  final bool move;

  const DirClipboard({
    required this.sourceFingerprint,
    required this.sourceHost,
    required this.sourceRootId,
    required this.sourcePath,
    required this.entry,
    required this.move,
  });
}

final dirClipboardProvider = ReduxProvider<DirClipboardService, DirClipboard?>((ref) => DirClipboardService());

class DirClipboardService extends ReduxNotifier<DirClipboard?> {
  @override
  DirClipboard? init() => null;
}

class SetDirClipboardAction extends ReduxAction<DirClipboardService, DirClipboard?> {
  final DirClipboard clipboard;

  SetDirClipboardAction({required this.clipboard});

  @override
  DirClipboard? reduce() => clipboard;
}

class ClearDirClipboardAction extends ReduxAction<DirClipboardService, DirClipboard?> {
  @override
  DirClipboard? reduce() => null;
}
