import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/pages/send_history_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/send_history_provider.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_app/util/transfer_overview.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): global transfer panel (UI-3, F-XFER-16).
/// Desktop: section pinned under the navigation rail. Mobile: floating pill.
/// Both open [showTransfersDialog] for the full list.

List<ActiveTransferView> _active(WatchableRef ref) {
  ref.watch(sendProvider);
  ref.watch(serverProvider);
  final sessions = ref.read(sendProvider);
  final server = ref.read(serverProvider);
  // Progress notifications arrive per chunk: only subscribe while something
  // is actually active (the rail section lives for the whole app lifetime).
  final receiveStatus = server?.session?.status;
  final hasActive =
      sessions.values.any((s) => s.status == SessionStatus.waiting || s.status == SessionStatus.sending) ||
      receiveStatus == SessionStatus.waiting ||
      receiveStatus == SessionStatus.sending;
  if (!hasActive) {
    return const [];
  }
  ref.watch(fileTransferProvider);
  final transfer = ref.read(fileTransferProvider);
  return activeTransfers(
    sendSessions: sessions,
    server: server,
    progressOf: (sessionId, fileId) => transfer.getProgress(sessionId: sessionId, fileId: fileId),
  );
}

void _cancel(WatchableRef ref, ActiveTransferView view) {
  if (view.outgoing) {
    ref.notifier(sendProvider).cancelSession(view.sessionId);
  } else {
    // Same path as the receive page: cancels the Rust session, notifies the
    // sender and clears the server-side session state.
    if (ref.read(serverProvider)?.session?.sessionId == view.sessionId) {
      ref.notifier(serverProvider).cancelSession();
    }
  }
}

class TransferRailSection extends StatelessWidget {
  /// Compact mode (non-extended rail): a single icon button with badge.
  final bool compact;

  const TransferRailSection({required this.compact, super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final views = _active(ref);
    final theme = Theme.of(context);

    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: IconButton(
          tooltip: t.ui2.transfers.title,
          onPressed: () => showTransfersDialog(context),
          icon: Badge(
            isLabelVisible: views.isNotEmpty,
            label: Text('${views.length}'),
            child: const Icon(Icons.swap_vert),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(t.ui2.transfers.title, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
              if (views.isNotEmpty) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(999)),
                  child: Text(
                    '${views.length}',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: theme.colorScheme.onPrimary),
                  ),
                ),
              ],
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: () => showTransfersDialog(context),
                child: Text(t.ui2.transfers.viewAll, style: const TextStyle(fontSize: 11.5)),
              ),
            ],
          ),
          if (views.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2),
              child: Text(
                t.ui2.transfers.none,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            ...views.take(3).map((view) => _ActiveTransferRow(view: view, dense: true)),
        ],
      ),
    );
  }
}

class TransferPill extends StatelessWidget {
  const TransferPill({super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final views = _active(ref);
    if (views.isEmpty) {
      return const SizedBox.shrink();
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.inverseSurface,
        foregroundColor: Theme.of(context).colorScheme.onInverseSurface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: const StadiumBorder(),
      ),
      onPressed: () => showTransfersDialog(context),
      icon: const Icon(Icons.swap_vert, size: 16),
      label: Text(t.ui2.transfers.pill(n: views.length), style: const TextStyle(fontSize: 12.5)),
    );
  }
}

class _ActiveTransferRow extends StatelessWidget {
  final ActiveTransferView view;
  final bool dense;

  const _ActiveTransferRow({required this.view, required this.dense});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final theme = Theme.of(context);
    final title = view.fileCount > 1 ? t.sendTab.selection.files(files: view.fileCount) : view.firstName;
    final subtitle = view.outgoing ? t.ui2.transfers.toPeer(alias: view.peerAlias) : t.ui2.transfers.fromPeer(alias: view.peerAlias);
    final status = view.status.humanString;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
      child: Row(
        children: [
          Icon(view.outgoing ? Icons.upload : Icons.download, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelSmall, overflow: TextOverflow.ellipsis),
                Text(
                  status == null ? subtitle : '$subtitle · $status',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 10.5),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(value: view.progress, minHeight: 3),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: t.ui2.cancel,
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            onPressed: () => _cancel(ref, view),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Full list: active transfers + merged history + links to both history pages.
Future<void> showTransfersDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const _TransfersDialog(),
  );
}

class _TransfersDialog extends StatelessWidget {
  const _TransfersDialog();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final views = _active(ref);
    final history = mergedHistory(
      sendHistory: ref.watch(sendHistoryProvider),
      receiveHistory: ref.watch(receiveHistoryProvider),
    );
    final theme = Theme.of(context);

    String timeLabel(int ms) {
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final now = DateTime.now();
      final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final hhmm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      if (sameDay) {
        return hhmm;
      }
      final date = dt.year == now.year ? '${dt.month}-${dt.day}' : '${dt.year}-${dt.month}-${dt.day}';
      return '$date $hhmm';
    }

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.swap_vert, size: 22),
          const SizedBox(width: 8),
          Text(t.ui2.transfers.title),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: ListView(
            shrinkWrap: true,
            children: [
              if (views.isNotEmpty) ...[
                Text(t.ui2.transfers.active, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                ...views.map((view) => _ActiveTransferRow(view: view, dense: false)),
                const SizedBox(height: 10),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    t.ui2.transfers.none,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              if (history.isNotEmpty) ...[
                Text(t.ui2.transfers.history, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                ...history.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          entry.outgoing ? Icons.upload : Icons.download,
                          size: 15,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.fileName, style: theme.textTheme.labelSmall, overflow: TextOverflow.ellipsis),
                              Text(
                                '${entry.outgoing ? t.ui2.transfers.toPeer(alias: entry.peerAlias) : t.ui2.transfers.fromPeer(alias: entry.peerAlias)} · ${timeLabel(entry.timestampMs)}',
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontSize: 10.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          entry.success ? Icons.check : Icons.close,
                          size: 15,
                          color: entry.success ? Colors.green.shade600 : theme.colorScheme.error,
                          semanticLabel: entry.success ? null : t.ui2.transfers.failed,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await context.push(() => const SendHistoryPage());
          },
          child: Text(t.sendHistoryPage.title),
        ),
        TextButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await context.push(() => const ReceiveHistoryPage());
          },
          child: Text(t.receiveHistoryPage.title),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.general.close),
        ),
      ],
    );
  }
}
