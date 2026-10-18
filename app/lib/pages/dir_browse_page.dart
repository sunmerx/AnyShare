import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/dir_annotation.dart';
import 'package:localsend_app/provider/dir_annotations_provider.dart';
import 'package:localsend_app/provider/dir_browse_provider.dart';
import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/provider/network/dir_endpoints.dart' show kDirMaxListEntries;
import 'package:localsend_app/util/dir_browse.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): shared-directory browser (E3-3c).
/// Single-device page: roots on the left, listing on the right.
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
    _ref.redux(dirBrowseProvider).dispatch(CloseDirBrowseAction(fingerprint: widget.fingerprint));
    super.dispose();
  }

  DirClient get _client => DirClient(host: widget.host, extPort: context.ref.read(dirBrowsePortProvider), fingerprint: widget.fingerprint);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
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
    setState(() => _loading = true);
    await _ref.redux(dirBrowseProvider).dispatchAsync(OpenDirBrowseAction(fingerprint: widget.fingerprint, host: widget.host, requestId: id));
    if (mounted && id == _requestSeq) {
      setState(() => _loading = false);
    }
  }

  Future<void> _open({required String rootId, required String path}) async {
    final id = ++_requestSeq;
    setState(() => _loading = true);
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

  Future<void> _upload(DirBrowseSession session) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    final files = result?.files ?? [];
    final paths = files.map((f) => f.path).whereType<String>().toList();
    var skipped = files.length - paths.length;
    if (paths.isEmpty) {
      if (skipped > 0) {
        // Content-URI picks without a local path (mobile) cannot be uploaded.
        _showMessage(t.ui2.dirBrowse.errSource);
      }
      return;
    }
    await _run(() async {
      var uploaded = 0;
      var failed = 0;
      for (final path in paths) {
        try {
          await _client.uploadFile(root: session.rootId, path: session.path, source: File(path), name: p.basename(path));
          uploaded++;
        } catch (_) {
          failed++;
        }
      }
      failed += skipped;
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

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final session = ref.watch(dirBrowseProvider)[widget.fingerprint];
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
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
      body: _buildBody(context, ref, session, narrow),
    );
  }

  Widget _buildBody(BuildContext context, WatchableRef ref, DirBrowseSession? session, bool narrow) {
    if (session == null || (_loading && session.roots.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.error != null && session.roots.isEmpty) {
      return _ErrorView(message: _errorText(session.error!), onRetry: () => _refreshOrOpen(session));
    }
    if (session.roots.isEmpty) {
      return _ErrorView(message: t.ui2.dirBrowse.empty, onRetry: () => _refreshOrOpen(session));
    }

    final rootsPanel = _RootsPanel(
      session: session,
      onSelect: (rootId) {
        // ignore: discarded_futures
        _open(rootId: rootId, path: '');
      },
      compact: narrow,
    );
    final pane = _DirPane(
      session: session,
      annotations: ref.watch(dirAnnotationsProvider),
      busy: _busy,
      loading: _loading,
      onOpen: _open,
      onDownload: (entry) => _download(session, entry),
      onRename: (entry) => _rename(session, entry),
      onDelete: (entry) => _delete(session, entry),
      errorText: _errorText,
    );

    if (narrow) {
      return Column(
        children: [
          rootsPanel,
          const Divider(height: 1),
          Expanded(child: pane),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 252, child: rootsPanel),
        const VerticalDivider(width: 1),
        Expanded(child: pane),
      ],
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
  final bool busy;
  final bool loading;
  final Future<void> Function({required String rootId, required String path}) onOpen;
  final ValueChanged<DirEntry> onDownload;
  final ValueChanged<DirEntry> onRename;
  final ValueChanged<DirEntry> onDelete;
  final String Function(String code) errorText;

  const _DirPane({
    required this.session,
    required this.annotations,
    required this.busy,
    required this.loading,
    required this.onOpen,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
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
          child: session.entries.isEmpty && !loading
              ? Center(
                  child: Text(t.ui2.dirBrowse.emptyFolder, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                )
              : ListView.builder(
                  itemCount: session.entries.length,
                  itemBuilder: (context, index) {
                    final entry = session.entries[index];
                    return _DirEntryTile(
                      entry: entry,
                      annotation:
                          annotations[DirAnnotation.key(
                            fingerprint: session.fingerprint,
                            rootId: session.rootId,
                            path: joinDirPath(session.path, entry.name),
                          )],
                      writable: session.writable,
                      busy: busy,
                      onTap: entry.isDir
                          ? () {
                              // ignore: discarded_futures
                              onOpen(rootId: session.rootId, path: joinDirPath(session.path, entry.name));
                            }
                          : null,
                      onDownload: entry.isDir ? null : () => onDownload(entry),
                      onRename: () => onRename(entry),
                      onDelete: () => onDelete(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DirEntryTile extends StatelessWidget {
  final DirEntry entry;
  final DirAnnotation? annotation;
  final bool writable;
  final bool busy;
  final VoidCallback? onTap;
  final VoidCallback? onDownload;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _DirEntryTile({
    required this.entry,
    required this.annotation,
    required this.writable,
    required this.busy,
    required this.onTap,
    required this.onDownload,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = annotation?.tags ?? const <String>[];
    final note = annotation?.note ?? '';
    return ListTile(
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
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(tag, style: TextStyle(fontSize: 10.5, color: theme.colorScheme.onSecondaryContainer)),
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
            case 'download':
              onDownload?.call();
            case 'rename':
              onRename();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (context) => [
          if (onDownload != null) PopupMenuItem(value: 'download', child: Text(t.ui2.dirBrowse.download)),
          if (writable) ...[
            PopupMenuItem(value: 'rename', child: Text(t.ui2.dirBrowse.rename)),
            PopupMenuItem(value: 'delete', child: Text(t.ui2.dirBrowse.delete)),
          ],
        ],
      ),
    );
  }
}
