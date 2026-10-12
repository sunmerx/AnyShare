import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/send_history_provider.dart';
import 'package:localsend_app/widget/dialogs/history_clear_dialog.dart';
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-12): browse outgoing transfers (PRD F-INT-R5).
class SendHistoryPage extends StatelessWidget {
  const SendHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = context.watch(sendHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.sendHistoryPage.title),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              onPressed: () async {
                final result = await showDialog(
                  context: context,
                  builder: (_) => const HistoryClearDialog(),
                );
                if (context.mounted && result == true) {
                  await context.redux(sendHistoryProvider).dispatchAsync(RemoveAllSendHistoryEntriesAction());
                }
              },
              icon: const Icon(Icons.delete),
            ),
        ],
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(vertical: 20),
        children: [
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 100),
              child: Center(child: Text(t.sendHistoryPage.empty, style: Theme.of(context).textTheme.headlineMedium)),
            )
          else
            ...entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FilePathThumbnail(
                      path: null,
                      fileType: entry.fileType,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 3),
                          Text(
                            entry.fileName,
                            style: const TextStyle(fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                          ),
                          Text(
                            '${entry.timestampString(context)} - ${entry.receiverAlias}',
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: TextStyle(color: entry.success ? Colors.grey : Theme.of(context).colorScheme.error),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(
                      entry.success ? Icons.check_circle : Icons.error,
                      color: entry.success ? Colors.green : Theme.of(context).colorScheme.error,
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
