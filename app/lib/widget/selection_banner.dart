import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/selected_files_page.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/widget/dialogs/send_target_dialog.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): shows the current file selection on the
/// device pages, with edit/clear (UI-1).
class SelectionBanner extends StatelessWidget {
  const SelectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final files = ref.watch(selectedSendingFilesProvider);
    if (files.isEmpty) {
      return const SizedBox.shrink();
    }
    final total = files.fold<int>(0, (prev, curr) => prev + curr.size);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.attach_file, size: 18, color: Theme.of(context).colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${t.sendTab.selection.files(files: files.length)} · ${total.asReadableFileSize}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSecondaryContainer),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () async => await context.push(() => const SelectedFilesPage()),
                child: Text(t.general.edit),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => showSendTargetDialog(context),
                child: Text(t.ui2.transfers.sendTo),
              ),
              IconButton(
                tooltip: t.general.close,
                onPressed: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
