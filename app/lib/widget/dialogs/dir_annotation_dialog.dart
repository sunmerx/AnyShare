import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/dir_annotation.dart';

/// AnyShare modification (2026-10-18): local tags/notes editor for a shared
/// directory entry (F-DIR-07, E3-3d). Returns the new annotation or null.
Future<DirAnnotation?> showDirAnnotationDialog(BuildContext context, {required String entryName, required DirAnnotation current}) async {
  return await showDialog<DirAnnotation>(
    context: context,
    builder: (context) => _DirAnnotationDialog(entryName: entryName, current: current),
  );
}

class _DirAnnotationDialog extends StatefulWidget {
  final String entryName;
  final DirAnnotation current;

  const _DirAnnotationDialog({required this.entryName, required this.current});

  @override
  State<_DirAnnotationDialog> createState() => _DirAnnotationDialogState();
}

class _DirAnnotationDialogState extends State<_DirAnnotationDialog> {
  late final List<String> _tags = [...widget.current.tags];
  late final TextEditingController _tagController = TextEditingController();
  late final TextEditingController _noteController = TextEditingController(text: widget.current.note);

  @override
  void dispose() {
    _tagController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _addTag(String raw) {
    final tag = raw.trim();
    if (tag.isEmpty || _tags.contains(tag)) {
      _tagController.clear();
      return;
    }
    setState(() => _tags.add(tag));
    _tagController.clear();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.ui2.dirBrowse.tagsTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.entryName, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            if (_tags.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    Chip(
                      label: Text(tag),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => setState(() => _tags.remove(tag)),
                    ),
                ],
              ),
            TextField(
              controller: _tagController,
              decoration: InputDecoration(
                labelText: t.ui2.dirBrowse.addTag,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addTag(_tagController.text),
                ),
              ),
              onSubmitted: _addTag,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              decoration: InputDecoration(labelText: t.ui2.dirBrowse.noteLabel),
              maxLines: 3,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.ui2.cancel)),
        FilledButton(
          onPressed: () {
            // Include a tag that was typed but not submitted.
            final pending = _tagController.text.trim();
            final tags = [..._tags];
            if (pending.isNotEmpty && !tags.contains(pending)) {
              tags.add(pending);
            }
            Navigator.of(context).pop(DirAnnotation(tags: tags, note: _noteController.text.trim()));
          },
          child: Text(t.general.save),
        ),
      ],
    );
  }
}
