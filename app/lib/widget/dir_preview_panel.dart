import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/dir_annotation.dart';
import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/util/dir_browse.dart';

/// AnyShare modification (2026-10-18): file preview panel for the shared
/// directory browser (E3-3d). Images, markdown and plain text are rendered;
/// everything else shows metadata. Downloads are capped per kind, and remote
/// content never triggers network requests (markdown images are blocked).

class DirPreviewPanel extends StatefulWidget {
  final DirClient client;
  final String rootId;
  final String path;
  final DirEntry entry;
  final DirAnnotation? annotation;
  final VoidCallback onEditAnnotation;
  final VoidCallback onDownload;

  const DirPreviewPanel({
    super.key,
    required this.client,
    required this.rootId,
    required this.path,
    required this.entry,
    required this.annotation,
    required this.onEditAnnotation,
    required this.onDownload,
  });

  @override
  State<DirPreviewPanel> createState() => _DirPreviewPanelState();
}

class _DirPreviewPanelState extends State<DirPreviewPanel> {
  Uint8List? _bytes;
  bool _loading = false;
  String? _error;
  bool _tooLarge = false;

  DirPreviewKind get _kind => dirPreviewKindOf(widget.entry.name);

  String get _relPath => joinDirPath(widget.path, widget.entry.name);

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _load();
  }

  @override
  void didUpdateWidget(DirPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.name != widget.entry.name ||
        oldWidget.path != widget.path ||
        oldWidget.rootId != widget.rootId ||
        oldWidget.entry.size != widget.entry.size ||
        oldWidget.entry.modified != widget.entry.modified) {
      // ignore: discarded_futures
      _load();
    }
  }

  Future<void> _load() async {
    final kind = _kind;
    final requestedPath = _relPath;
    if (kind == DirPreviewKind.unsupported) {
      setState(() {
        _bytes = null;
        _error = null;
        _tooLarge = false;
        _loading = false;
      });
      return;
    }
    final size = widget.entry.size;
    if (size != null && size > dirPreviewCapOf(kind)) {
      setState(() {
        _bytes = null;
        _error = null;
        _tooLarge = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _tooLarge = false;
    });
    try {
      // maxBytes also covers entries whose size metadata is null (symlinks):
      // the transfer aborts server-side-invisible once the cap is exceeded.
      final bytes = await widget.client.downloadBytes(root: widget.rootId, path: requestedPath, maxBytes: dirPreviewCapOf(kind));
      if (!mounted || _relPath != requestedPath) {
        // A newer entry was selected while this response was in flight.
        return;
      }
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } on DirClientException catch (e) {
      if (!mounted || _relPath != requestedPath) {
        return;
      }
      setState(() {
        _loading = false;
        if (e.code == 'too_large') {
          _tooLarge = true;
        } else {
          _error = e.code;
        }
      });
    } catch (_) {
      if (mounted && _relPath == requestedPath) {
        setState(() {
          _loading = false;
          _error = 'unreachable';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(entry.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: t.ui2.dirBrowse.annotation,
                icon: const Icon(Icons.sell_outlined, size: 20),
                onPressed: widget.onEditAnnotation,
              ),
              IconButton(
                tooltip: t.ui2.dirBrowse.download,
                icon: const Icon(Icons.download_outlined, size: 20),
                onPressed: widget.onDownload,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            entry.size == null ? '' : formatDirSize(entry.size!),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        if ((widget.annotation?.tags.isNotEmpty ?? false) || (widget.annotation?.note.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.annotation!.tags.isNotEmpty)
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final tag in widget.annotation!.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(tag, style: TextStyle(fontSize: 10.5, color: theme.colorScheme.onSecondaryContainer)),
                        ),
                    ],
                  ),
                if (widget.annotation!.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(widget.annotation!.note, style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        const Divider(height: 20),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_tooLarge) {
      return _hint(theme, Icons.sd_storage_outlined, t.ui2.dirBrowse.previewTooLarge);
    }
    if (_error != null) {
      return _hint(theme, Icons.error_outline, t.ui2.dirBrowse.previewError);
    }
    final bytes = _bytes;
    if (bytes == null) {
      return _hint(theme, Icons.insert_drive_file_outlined, t.ui2.dirBrowse.previewUnsupported);
    }
    return switch (_kind) {
      DirPreviewKind.image => InteractiveViewer(
        child: Center(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            cacheWidth: 640,
            errorBuilder: (_, _, _) => _hint(theme, Icons.broken_image_outlined, t.ui2.dirBrowse.previewError),
          ),
        ),
      ),
      DirPreviewKind.markdown => Markdown(
        data: const Utf8Decoder(allowMalformed: true).convert(bytes),
        // Remote content must never trigger outbound requests: block all
        // images and link taps in the preview.
        sizedImageBuilder: (config) => const SizedBox.shrink(),
        onTapLink: (text, href, title) {},
      ),
      DirPreviewKind.text => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          const Utf8Decoder(allowMalformed: true).convert(bytes),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        ),
      ),
      DirPreviewKind.unsupported => _hint(theme, Icons.insert_drive_file_outlined, t.ui2.dirBrowse.previewUnsupported),
    };
  }

  Widget _hint(ThemeData theme, IconData icon, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
