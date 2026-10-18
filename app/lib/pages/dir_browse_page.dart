import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/dir_annotation.dart';
import 'package:localsend_app/provider/dir_annotations_provider.dart';
import 'package:localsend_app/provider/dir_browse_provider.dart';
import 'package:localsend_app/provider/dir_clipboard_provider.dart';
import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/provider/network/dir_endpoints.dart' show kDirMaxListEntries;
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/dir_browse.dart';
import 'package:localsend_app/util/dir_transfer.dart';
import 'package:localsend_app/widget/dialogs/dir_annotation_dialog.dart';
import 'package:localsend_app/widget/dir_preview_panel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): shared-directory browser (E3-3c/E3-3d).
/// Single-device page: roots on the left, listing in the middle, preview on
/// the right (wide screens).

enum DirViewMode { list, grid }

class DirBrowsePage extends StatefulWidget {
  final String fingerprint;
  final String host;
  final String title;

  const DirBrowsePage({required this.fingerprint, required this.host, required this.title});

  @override
  State<DirBrowsePage> createState() => _DirBrowsePageState();
}

class _DirBrowsePageState extends State<DirBrowsePage> {
  bool _busy = false;
  bool _loading = false;

  /// Monotonic request id for listing loads: a slow response never overwrites
  /// a directory the user navigated to later (see the provider actions).
  int _requestSeq = 0;

  DirViewMode _viewMode = DirViewMode.list;
  DirSortBy _sortBy = DirSortBy.name;
  bool _sortAsc = true;
  final TextEditingController _searchController = TextEditingController();
  String _search = '';
  final Set<String> _tagFilter = {};

  /// Selected file name in the current directory (drives the preview panel).
  String? _selectedName;

  /// (done, total, currentName) while a cross-device paste runs.
  (int, int, String)? _relayProgress;

  bool _dragActive = false;

  late final Ref _ref;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // ignore: discarded_futures
        _openFresh();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ref = context.ref;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _ref.redux(dirBrowseProvider).dispatch(CloseDirBrowseAction(fingerprint: widget.fingerprint));
    super.dispose();
  }

  DirClient get _client => DirClient(
    host: widget.host,
    extPort: context.ref.read(dirBrowsePortProvider),
    fingerprint: context.ref.read(securityProvider).certificateHash,
  );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      _showMessage(t.ui2.dirBrowse.busyHint);
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on DirClientException catch (e) {
      _showMessage(_errorText(e.code));
    } catch (_) {
      _showMessage(_errorText('unreachable'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _errorText(String code) {
    final t = Translations.of(context);
    return switch (code) {
      'unknown' => t.ui2.dirBrowse.errUnknown,
      'ip_mismatch' => t.ui2.dirBrowse.errIpMismatch,
      'blocked' => t.ui2.dirBrowse.errBlocked,
      'temp_not_allowed' => t.ui2.dirBrowse.errTemp,
      'read_only' => t.ui2.dirBrowse.errReadOnly,
      'not_found' => t.ui2.dirBrowse.errNotFound,
      'conflict' => t.ui2.dirBrowse.errConflict,
      'invalid_path' => t.ui2.dirBrowse.errInvalidPath,
      'too_large' => t.ui2.dirBrowse.errTooLarge,
      'rate_limited' => t.ui2.dirBrowse.errRateLimited,
      'bad_request' => t.ui2.dirBrowse.errBadRequest,
      'protocol' => t.ui2.dirBrowse.errProtocol,
      'source_error' => t.ui2.dirBrowse.errSource,
      'internal' || 'write_failed' || 'aborted' => t.ui2.dirBrowse.errInternal,
      _ => t.ui2.dirBrowse.errUnreachable,
    };
  }

  Future<void> _openFresh() async {
    final id = ++_requestSeq;
    setState(() {
      _loading = true;
      _selectedName = null;
    });
    await _ref.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: widget.fingerprint, host: widget.host, requestId: id));
    if (mounted && id == _requestSeq) {
      setState(() => _loading = false);
    }
  }

  Future<void> _open({required String rootId, required String path}) async {
    final id = ++_requestSeq;
    setState(() {
      _loading = true;
      _selectedName = null;
    });
    await _ref
        .redux(dirBrowseProvider)
        .dispatchAsync(
          LoadDirListingAction(fingerprint: widget.fingerprint, rootId: rootId, path: path, requestId: id),
        );
    if (mounted && id == _requestSeq) {
      setState(() => _loading = false);
    }
  }

  /// Re-fetches whatever the session currently shows (after a mutation).
  Future<void> _reloadLatest() async {
    final latest = _ref.read(dirBrowseProvider)[widget.fingerprint];
    if (latest == null) {
      return;
    }
    if (latest.rootId.isEmpty) {
      await _openFresh();
    } else {
      await _open(rootId: latest.rootId, path: latest.path);
    }
  }

  Future<void> _download(DirBrowseSession session, DirEntry entry) async {
    // The remote name is untrusted: strip any directory components before
    // joining it into a local path (a Linux host may share `..\..\x`).
    final safeName = p.basename(entry.name.replaceAll('\\', '/'));
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      _showMessage(t.ui2.dirBrowse.errInvalidPath);
      return;
    }
    await _run(() async {
      final relPath = joinDirPath(session.path, entry.name);
      File target;
      if (Platform.isAndroid || Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        target = File(p.join(dir.path, 'AnyShare', safeName));
        await target.parent.create(recursive: true);
      } else {
        final location = await file_selector.getSaveLocation(suggestedName: safeName);
        if (location == null) {
          return;
        }
        target = File(location.path);
      }
      await _client.downloadToFile(root: session.rootId, path: relPath, target: target);
      _showMessage(t.ui2.dirBrowse.downloadSaved(path: target.path));
    });
  }

  Future<void> _mkdir(DirBrowseSession session) async {
    final name = await _askName(title: t.ui2.dirBrowse.mkdirTitle, label: t.ui2.dirBrowse.nameLabel, initial: '');
    if (name == null || name.isEmpty) {
      return;
    }
    await _run(() async {
      await _client.mkdir(root: session.rootId, path: session.path, name: name);
      await _reloadLatest();
    });
  }

  Future<void> _rename(DirBrowseSession session, DirEntry entry) async {
    final name = await _askName(title: t.ui2.dirBrowse.renameTitle, label: t.ui2.dirBrowse.nameLabel, initial: entry.name);
    if (name == null || name.isEmpty || name == entry.name) {
      return;
    }
    await _run(() async {
      await _client.rename(root: session.rootId, path: joinDirPath(session.path, entry.name), newName: name);
      await _reloadLatest();
    });
  }

  Future<void> _delete(DirBrowseSession session, DirEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.ui2.dirBrowse.deleteTitle(name: entry.name)),
        content: Text(t.ui2.dirBrowse.deleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.ui2.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.ui2.dirBrowse.delete)),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _run(() async {
      await _client.delete(root: session.rootId, path: joinDirPath(session.path, entry.name));
      await _reloadLatest();
    });
  }

  Future<void> _editAnnotation(DirBrowseSession session, DirEntry entry) async {
    final key = DirAnnotation.key(fingerprint: widget.fingerprint, rootId: session.rootId, path: joinDirPath(session.path, entry.name));
    final current = _ref.read(dirAnnotationsProvider)[key] ?? const DirAnnotation();
    final result = await showDirAnnotationDialog(context, entryName: entry.name, current: current);
    if (result == null) {
      return;
    }
    await _ref.redux(dirAnnotationsProvider).dispatchAsync(SetDirAnnotationAction(key: key, annotation: result));
  }

  Future<void> _upload(DirBrowseSession session) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final files = result?.files ?? [];
    final paths = files.map((f) => f.path).whereType<String>().toList();
    final skipped = files.length - paths.length;
    if (paths.isEmpty) {
      if (skipped > 0) {
        // Content-URI picks without a local path (mobile) cannot be uploaded.
        _showMessage(t.ui2.dirBrowse.errSource);
      }
      return;
    }
    await _uploadPaths(session, paths, skipped: skipped);
  }

  Future<void> _uploadPaths(DirBrowseSession session, List<String> paths, {int skipped = 0}) async {
    await _run(() async {
      var uploaded = 0;
      var failed = skipped;
      for (final path in paths) {
        try {
          await _client.uploadFile(root: session.rootId, path: session.path, source: File(path), name: p.basename(path));
          uploaded++;
        } catch (_) {
          failed++;
        }
      }
      await _reloadLatest();
      if (failed == 0) {
        _showMessage(t.ui2.dirBrowse.uploadDone(n: uploaded));
      } else {
        _showMessage(t.ui2.dirBrowse.uploadDonePartial(n: uploaded, failed: failed));
      }
    });
  }

  Future<String?> _askName({required String title, required String label, required String initial}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.ui2.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: Text(t.general.confirm)),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _showContextMenu(Offset globalPosition, DirBrowseSession session, DirEntry entry) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
    final action = await showMenu<String>(
      context: context,
      position: position,
      items: [
        if (!entry.isDir) PopupMenuItem(value: 'preview', child: Text(t.ui2.dirBrowse.preview)),
        if (!entry.isDir) PopupMenuItem(value: 'download', child: Text(t.ui2.dirBrowse.download)),
        PopupMenuItem(value: 'copy', child: Text(t.ui2.dirBrowse.copy)),
        if (session.writable) PopupMenuItem(value: 'cut', child: Text(t.ui2.dirBrowse.cut)),
        PopupMenuItem(value: 'annotation', child: Text(t.ui2.dirBrowse.annotation)),
        if (session.writable) ...[
          PopupMenuItem(value: 'rename', child: Text(t.ui2.dirBrowse.rename)),
          PopupMenuItem(value: 'delete', child: Text(t.ui2.dirBrowse.delete)),
        ],
      ],
    );
    if (action == null || !mounted) {
      return;
    }
    await _handleEntryAction(action, session, entry);
  }

  Future<void> _handleEntryAction(String action, DirBrowseSession session, DirEntry entry) async {
    switch (action) {
      case 'preview':
        setState(() => _selectedName = entry.name);
      case 'download':
        await _download(session, entry);
      case 'copy':
        _setClipboard(session, entry, move: false);
      case 'cut':
        _setClipboard(session, entry, move: true);
      case 'annotation':
        await _editAnnotation(session, entry);
      case 'rename':
        await _rename(session, entry);
      case 'delete':
        await _delete(session, entry);
    }
  }

  void _setClipboard(DirBrowseSession session, DirEntry entry, {required bool move}) {
    _ref
        .redux(dirClipboardProvider)
        .dispatch(
          SetDirClipboardAction(
            clipboard: DirClipboard(
              sourceFingerprint: session.fingerprint,
              sourceHost: session.host,
              sourceRootId: session.rootId,
              sourcePath: session.path,
              entry: entry,
              move: move,
            ),
          ),
        );
    _showMessage(move ? t.ui2.dirBrowse.cutToClipboard : t.general.copiedToClipboard);
  }

  Future<void> _paste(DirBrowseSession session) async {
    final clipboard = _ref.read(dirClipboardProvider);
    if (clipboard == null) {
      return;
    }
    await _run(() async {
      final sourceClient = DirClient(
        host: clipboard.sourceHost,
        extPort: _ref.read(dirBrowsePortProvider),
        fingerprint: _ref.read(securityProvider).certificateHash,
      );
      setState(() => _relayProgress = (0, 1, clipboard.entry.name));
      DirRelayResult result;
      try {
        result = await relayDirEntries(
          source: sourceClient,
          sourceRoot: clipboard.sourceRootId,
          sourcePath: clipboard.sourcePath,
          target: _client,
          targetRoot: session.rootId,
          targetPath: session.path,
          entries: [clipboard.entry],
          move: clipboard.move,
          onProgress: (done, total, current) {
            if (mounted) {
              setState(() => _relayProgress = (done, total, current));
            }
          },
        );
      } finally {
        if (mounted) {
          setState(() => _relayProgress = null);
        }
      }
      await _reloadLatest();
      if (result.truncated) {
        _showMessage(t.ui2.dirBrowse.pasteLimit(n: result.copied));
      } else if (result.deleteFailed > 0) {
        _showMessage(t.ui2.dirBrowse.pasteMoveDeleteFailed(n: result.copied));
      } else if (result.failed == 0) {
        _showMessage(t.ui2.dirBrowse.pasteDone(n: result.copied));
      } else {
        _showMessage(t.ui2.dirBrowse.pastePartial(n: result.copied, failed: result.failed));
      }
      if (clipboard.move && result.ok) {
        _ref.redux(dirClipboardProvider).dispatch(ClearDirClipboardAction());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final session = ref.watch(dirBrowseProvider)[widget.fingerprint];
    final hasClipboard = ref.watch(dirClipboardProvider) != null;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 700;
    final wide = width >= 1000;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (hasClipboard && session != null && session.rootId.isNotEmpty && session.writable)
            IconButton(
              tooltip: t.ui2.dirBrowse.paste,
              icon: const Icon(Icons.content_paste),
              onPressed: _busy ? null : () => _paste(session),
            ),
          if (session != null && session.rootId.isNotEmpty && session.writable) ...[
            IconButton(
              tooltip: t.ui2.dirBrowse.upload,
              icon: const Icon(Icons.upload_file),
              onPressed: _busy ? null : () => _upload(session),
            ),
            IconButton(
              tooltip: t.ui2.dirBrowse.mkdir,
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _busy ? null : () => _mkdir(session),
            ),
          ],
          if (session != null)
            IconButton(
              tooltip: t.ui2.dirBrowse.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: _busy || _loading ? null : () => _refreshOrOpen(session),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_relayProgress != null)
            Material(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_relayProgress!.$1}/${_relayProgress!.$2}  ${_relayProgress!.$3}',
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(
                        value: _relayProgress!.$2 == 0 ? null : _relayProgress!.$1 / _relayProgress!.$2,
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: _buildBody(context, ref, session, narrow, wide)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, WatchableRef ref, DirBrowseSession? session, bool narrow, bool wide) {
    if (session == null || (_loading && session.roots.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.error != null && session.roots.isEmpty) {
      return _ErrorView(message: _errorText(session.error!), onRetry: () => _refreshOrOpen(session));
    }
    if (session.roots.isEmpty) {
      return _ErrorView(message: t.ui2.dirBrowse.empty, onRetry: () => _refreshOrOpen(session));
    }

    final annotations = ref.watch(dirAnnotationsProvider);
    final rootsPanel = _RootsPanel(
      session: session,
      onSelect: (rootId) {
        // ignore: discarded_futures
        _open(rootId: rootId, path: '');
      },
      compact: narrow,
    );

    final tagsByName = <String, List<String>>{
      for (final entry in session.entries)
        entry.name:
            annotations[DirAnnotation.key(fingerprint: session.fingerprint, rootId: session.rootId, path: joinDirPath(session.path, entry.name))]
                ?.tags ??
            const [],
    };
    final availableTags = <String>{for (final tags in tagsByName.values) ...tags}.toList()..sort();
    final visible = sortDirEntriesBy(
      filterDirEntries(session.entries, query: _search, tagFilter: _tagFilter, tagsByName: tagsByName),
      by: _sortBy,
      ascending: _sortAsc,
    );

    final pane = _DirPane(
      session: session,
      annotations: annotations,
      visible: visible,
      tagsByName: tagsByName,
      availableTags: availableTags,
      tagFilter: _tagFilter,
      searchController: _searchController,
      viewMode: _viewMode,
      sortBy: _sortBy,
      sortAsc: _sortAsc,
      selectedName: _selectedName,
      busy: _busy,
      loading: _loading,
      onSearchChanged: (value) => setState(() => _search = value),
      onToggleTag: (tag) => setState(() {
        if (!_tagFilter.remove(tag)) {
          _tagFilter.add(tag);
        }
      }),
      onViewModeChanged: (mode) => setState(() => _viewMode = mode),
      onSortChanged: (by, asc) => setState(() {
        _sortBy = by;
        _sortAsc = asc;
      }),
      onOpen: _open,
      onSelect: (entry) => setState(() => _selectedName = entry.name),
      onSecondaryTap: (position, entry) {
        // ignore: discarded_futures
        _showContextMenu(position, session, entry);
      },
      onDownload: (entry) => _download(session, entry),
      onRename: (entry) => _rename(session, entry),
      onDelete: (entry) => _delete(session, entry),
      onAnnotate: (entry) => _editAnnotation(session, entry),
      onCopy: (entry) => _setClipboard(session, entry, move: false),
      onCut: (entry) => _setClipboard(session, entry, move: true),
      errorText: _errorText,
    );

    Widget content;
    if (narrow) {
      content = Column(
        children: [
          rootsPanel,
          const Divider(height: 1),
          Expanded(child: pane),
        ],
      );
    } else {
      final selectedEntry = _selectedName == null ? null : session.entries.where((e) => e.name == _selectedName).firstOrNull;
      content = Row(
        children: [
          SizedBox(width: 252, child: rootsPanel),
          const VerticalDivider(width: 1),
          Expanded(child: pane),
          if (wide && selectedEntry != null && !selectedEntry.isDir) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: 320,
              child: DirPreviewPanel(
                client: _client,
                rootId: session.rootId,
                path: session.path,
                entry: selectedEntry,
                annotation:
                    annotations[DirAnnotation.key(
                      fingerprint: session.fingerprint,
                      rootId: session.rootId,
                      path: joinDirPath(session.path, selectedEntry.name),
                    )],
                onEditAnnotation: () => _editAnnotation(session, selectedEntry),
                onDownload: () => _download(session, selectedEntry),
              ),
            ),
          ],
        ],
      );
    }

    // Drop-to-upload (desktop): only meaningful when the host allows writes.
    if (!session.writable) {
      return content;
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragActive = true),
      onDragExited: (_) => setState(() => _dragActive = false),
      onDragDone: (event) {
        setState(() => _dragActive = false);
        final files = <String>[];
        var skipped = 0;
        for (final file in event.files) {
          if (Directory(file.path).existsSync()) {
            skipped++;
          } else {
            files.add(file.path);
          }
        }
        if (files.isEmpty) {
          if (skipped > 0) {
            _showMessage(t.ui2.dirBrowse.uploadDonePartial(n: 0, failed: skipped));
          }
          return;
        }
        // ignore: discarded_futures
        _uploadPaths(session, files, skipped: skipped);
      },
      child: Stack(
        children: [
          content,
          if (_dragActive)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.only(top: 24),
                  child: Chip(
                    avatar: const Icon(Icons.upload_file, size: 18),
                    label: Text(t.ui2.dirBrowse.dropHint),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _refreshOrOpen(DirBrowseSession session) {
    if (session.rootId.isEmpty) {
      // ignore: discarded_futures
      _openFresh();
    } else {
      // ignore: discarded_futures
      _open(rootId: session.rootId, path: session.path);
    }
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: Text(t.ui2.dirBrowse.retry)),
          ],
        ),
      ),
    );
  }
}

class _RootsPanel extends StatelessWidget {
  final DirBrowseSession session;
  final ValueChanged<String> onSelect;
  final bool compact;

  const _RootsPanel({required this.session, required this.onSelect, required this.compact});

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final root in session.roots)
        SizedBox(
          width: compact ? 200 : null,
          child: ListTile(
            dense: compact,
            leading: const Icon(Icons.folder_outlined, size: 20),
            title: Text(root.name.isEmpty ? root.id : root.name, overflow: TextOverflow.ellipsis),
            trailing: root.writable ? null : Tooltip(message: t.ui2.settings.writable, child: const Icon(Icons.lock_outline, size: 16)),
            selected: root.id == session.rootId,
            onTap: () => onSelect(root.id),
          ),
        ),
    ];
    if (compact) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: tiles),
      );
    }
    return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: tiles);
  }
}

class _DirPane extends StatelessWidget {
  final DirBrowseSession session;
  final Map<String, DirAnnotation> annotations;
  final List<DirEntry> visible;
  final Map<String, List<String>> tagsByName;
  final List<String> availableTags;
  final Set<String> tagFilter;
  final TextEditingController searchController;
  final DirViewMode viewMode;
  final DirSortBy sortBy;
  final bool sortAsc;
  final String? selectedName;
  final bool busy;
  final bool loading;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onToggleTag;
  final ValueChanged<DirViewMode> onViewModeChanged;
  final void Function(DirSortBy by, bool asc) onSortChanged;
  final Future<void> Function({required String rootId, required String path}) onOpen;
  final ValueChanged<DirEntry> onSelect;
  final void Function(Offset position, DirEntry entry) onSecondaryTap;
  final ValueChanged<DirEntry> onDownload;
  final ValueChanged<DirEntry> onRename;
  final ValueChanged<DirEntry> onDelete;
  final ValueChanged<DirEntry> onAnnotate;
  final ValueChanged<DirEntry> onCopy;
  final ValueChanged<DirEntry> onCut;
  final String Function(String code) errorText;

  const _DirPane({
    required this.session,
    required this.annotations,
    required this.visible,
    required this.tagsByName,
    required this.availableTags,
    required this.tagFilter,
    required this.searchController,
    required this.viewMode,
    required this.sortBy,
    required this.sortAsc,
    required this.selectedName,
    required this.busy,
    required this.loading,
    required this.onSearchChanged,
    required this.onToggleTag,
    required this.onViewModeChanged,
    required this.onSortChanged,
    required this.onOpen,
    required this.onSelect,
    required this.onSecondaryTap,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
    required this.onAnnotate,
    required this.onCopy,
    required this.onCut,
    required this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = session.path.isEmpty ? const <String>[] : session.path.split('/');
    final crumbs = <Widget>[
      InkWell(
        onTap: () {
          // ignore: discarded_futures
          onOpen(rootId: session.rootId, path: '');
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(session.currentRoot?.name ?? session.rootId, style: theme.textTheme.bodyMedium),
        ),
      ),
      for (var i = 0; i < segments.length; i++) ...[
        const Icon(Icons.chevron_right, size: 16),
        InkWell(
          onTap: () {
            // ignore: discarded_futures
            onOpen(rootId: session.rootId, path: segments.take(i + 1).join('/'));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(segments[i], style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: t.ui2.dirBrowse.up,
              icon: const Icon(Icons.arrow_upward),
              onPressed: session.path.isEmpty
                  ? null
                  : () {
                      // ignore: discarded_futures
                      onOpen(rootId: session.rootId, path: parentDirPath(session.path));
                    },
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: crumbs),
              ),
            ),
            if (!session.writable)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.lock_outline, size: 14),
                  label: Text(t.ui2.dirBrowse.readOnly, style: const TextStyle(fontSize: 11.5)),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: searchController,
                    onChanged: onSearchChanged,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: t.ui2.dirBrowse.searchHint,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () {
                                searchController.clear();
                                onSearchChanged('');
                              },
                            ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                      filled: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: t.ui2.dirBrowse.sortBy,
                icon: const Icon(Icons.sort, size: 20),
                onSelected: (value) {
                  switch (value) {
                    case 'name':
                      onSortChanged(DirSortBy.name, sortAsc);
                    case 'size':
                      onSortChanged(DirSortBy.size, sortAsc);
                    case 'modified':
                      onSortChanged(DirSortBy.modified, sortAsc);
                    case 'asc':
                      onSortChanged(sortBy, true);
                    case 'desc':
                      onSortChanged(sortBy, false);
                  }
                },
                itemBuilder: (context) => [
                  CheckedPopupMenuItem(value: 'name', checked: sortBy == DirSortBy.name, child: Text(t.ui2.dirBrowse.sortName)),
                  CheckedPopupMenuItem(value: 'size', checked: sortBy == DirSortBy.size, child: Text(t.ui2.dirBrowse.sortSize)),
                  CheckedPopupMenuItem(value: 'modified', checked: sortBy == DirSortBy.modified, child: Text(t.ui2.dirBrowse.sortModified)),
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(value: 'asc', checked: sortAsc, child: Text(t.ui2.dirBrowse.sortAscending)),
                  CheckedPopupMenuItem(value: 'desc', checked: !sortAsc, child: Text(t.ui2.dirBrowse.sortDescending)),
                ],
              ),
              IconButton(
                tooltip: viewMode == DirViewMode.list ? t.ui2.dirBrowse.viewGrid : t.ui2.dirBrowse.viewList,
                icon: Icon(viewMode == DirViewMode.list ? Icons.grid_view : Icons.view_list, size: 20),
                onPressed: () => onViewModeChanged(viewMode == DirViewMode.list ? DirViewMode.grid : DirViewMode.list),
              ),
            ],
          ),
        ),
        if (availableTags.isNotEmpty || tagFilter.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                // Selected tags stay visible even when the current folder has
                // no entries carrying them (otherwise the filter is a dead end).
                for (final tag in ({...availableTags, ...tagFilter}.toList()..sort()))
                  FilterChip(
                    label: Text(tag, style: const TextStyle(fontSize: 11.5)),
                    visualDensity: VisualDensity.compact,
                    selected: tagFilter.contains(tag),
                    onSelected: (_) => onToggleTag(tag),
                  ),
              ],
            ),
          ),
        if (loading) const LinearProgressIndicator(minHeight: 2),
        if (session.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              t.ui2.dirBrowse.truncated(n: kDirMaxListEntries),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        if (session.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(errorText(session.error!), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        Expanded(
          child: visible.isEmpty && !loading
              ? Center(
                  child: Text(t.ui2.dirBrowse.emptyFolder, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                )
              : viewMode == DirViewMode.list
              ? _buildList(context)
              : _buildGrid(context),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        return _DirEntryTile(
          entry: entry,
          annotation:
              annotations[DirAnnotation.key(fingerprint: session.fingerprint, rootId: session.rootId, path: joinDirPath(session.path, entry.name))],
          writable: session.writable,
          busy: busy,
          selected: entry.name == selectedName,
          onTap: entry.isDir
              ? () {
                  // ignore: discarded_futures
                  onOpen(rootId: session.rootId, path: joinDirPath(session.path, entry.name));
                }
              : () => onSelect(entry),
          onSecondaryTap: (position) => onSecondaryTap(position, entry),
          onPreview: entry.isDir ? null : () => onSelect(entry),
          onDownload: entry.isDir ? null : () => onDownload(entry),
          onRename: () => onRename(entry),
          onDelete: () => onDelete(entry),
          onAnnotate: () => onAnnotate(entry),
          onCopy: () => onCopy(entry),
          onCut: () => onCut(entry),
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context) {
    final theme = Theme.of(context);
    // Cell height must follow the accessibility text scale: a fixed
    // childAspectRatio would clip the icon+name+size column at large font
    // scales (Android "largest", Windows text scaling 200%+).
    final textScale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 3.0);
    final cellHeight = 118 + 48 * (textScale - 1);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: cellHeight,
      ),
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final entry = visible[index];
        final annotation =
            annotations[DirAnnotation.key(fingerprint: session.fingerprint, rootId: session.rootId, path: joinDirPath(session.path, entry.name))];
        final selected = entry.name == selectedName;
        return GestureDetector(
          onLongPressStart: (details) => onSecondaryTap(details.globalPosition, entry),
          child: InkWell(
            onTap: entry.isDir
                ? () {
                    // ignore: discarded_futures
                    onOpen(rootId: session.rootId, path: joinDirPath(session.path, entry.name));
                  }
                : () => onSelect(entry),
            onSecondaryTapDown: (details) => onSecondaryTap(details.globalPosition, entry),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 1.5),
                color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35) : null,
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    entry.isDir
                        ? Icons.folder
                        : entry.isLink
                        ? Icons.link
                        : Icons.insert_drive_file_outlined,
                    size: 36,
                    color: entry.isDir ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                  if (!entry.isDir && entry.size != null)
                    Text(
                      formatDirSize(entry.size!),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 10.5, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  if (annotation != null && (annotation.tags.isNotEmpty || annotation.note.isNotEmpty))
                    const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.sell_outlined, size: 12)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DirEntryTile extends StatelessWidget {
  final DirEntry entry;
  final DirAnnotation? annotation;
  final bool writable;
  final bool busy;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<Offset> onSecondaryTap;
  final VoidCallback? onPreview;
  final VoidCallback? onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onAnnotate;
  final VoidCallback onCopy;
  final VoidCallback onCut;

  const _DirEntryTile({
    required this.entry,
    required this.annotation,
    required this.writable,
    required this.busy,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTap,
    required this.onPreview,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
    required this.onAnnotate,
    required this.onCopy,
    required this.onCut,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = annotation?.tags ?? const <String>[];
    final note = annotation?.note ?? '';
    return GestureDetector(
      onSecondaryTapDown: (details) => onSecondaryTap(details.globalPosition),
      child: ListTile(
        selected: selected,
        leading: Icon(
          entry.isDir
              ? Icons.folder
              : entry.isLink
              ? Icons.link
              : Icons.insert_drive_file_outlined,
          color: entry.isDir ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        ),
        title: Row(
          children: [
            Flexible(child: Text(entry.name, overflow: TextOverflow.ellipsis)),
            if (tags.isNotEmpty) ...[
              const SizedBox(width: 8),
              for (final tag in tags.take(3))
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: theme.colorScheme.onSecondaryContainer),
                      ),
                    ),
                  ),
                ),
            ],
            if (note.isNotEmpty)
              Tooltip(
                message: note,
                child: Icon(Icons.sticky_note_2_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        subtitle: entry.isDir
            ? null
            : Text(
                entry.size == null ? '' : formatDirSize(entry.size!),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
        onTap: onTap,
        trailing: PopupMenuButton<String>(
          enabled: !busy,
          tooltip: t.ui2.dirBrowse.actions,
          onSelected: (value) {
            switch (value) {
              case 'preview':
                onPreview?.call();
              case 'download':
                onDownload?.call();
              case 'annotation':
                onAnnotate();
              case 'copy':
                onCopy();
              case 'cut':
                onCut();
              case 'rename':
                onRename();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (context) => [
            if (onPreview != null) PopupMenuItem(value: 'preview', child: Text(t.ui2.dirBrowse.preview)),
            if (onDownload != null) PopupMenuItem(value: 'download', child: Text(t.ui2.dirBrowse.download)),
            PopupMenuItem(value: 'copy', child: Text(t.ui2.dirBrowse.copy)),
            if (writable) PopupMenuItem(value: 'cut', child: Text(t.ui2.dirBrowse.cut)),
            PopupMenuItem(value: 'annotation', child: Text(t.ui2.dirBrowse.annotation)),
            if (writable) ...[
              PopupMenuItem(value: 'rename', child: Text(t.ui2.dirBrowse.rename)),
              PopupMenuItem(value: 'delete', child: Text(t.ui2.dirBrowse.delete)),
            ],
          ],
        ),
      ),
    );
  }
}
