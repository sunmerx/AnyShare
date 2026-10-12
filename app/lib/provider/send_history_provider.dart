import 'package:localsend_app/model/persistence/send_history_entry.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-12): completed outgoing transfers
/// (PRD F-INT-R5). Same rotation policy as the receive history.
final sendHistoryProvider = ReduxProvider<SendHistoryService, List<SendHistoryEntry>>((ref) {
  return SendHistoryService(ref.read(persistenceProvider));
});

class SendHistoryService extends ReduxNotifier<List<SendHistoryEntry>> {
  final PersistenceService _persistence;

  SendHistoryService(this._persistence);

  @override
  List<SendHistoryEntry> init() => _persistence.getSendHistory();
}

/// Records one finished outgoing file. Successful files get one entry each;
/// a failed/canceled/declined session is summarized as a single entry
/// (file name = first file, success = false).
class AddSendHistoryEntryAction extends AsyncReduxAction<SendHistoryService, List<SendHistoryEntry>> {
  final SendHistoryEntry entry;

  AddSendHistoryEntryAction(this.entry);

  @override
  Future<List<SendHistoryEntry>> reduce() async {
    final updated = List<SendHistoryEntry>.unmodifiable(
      [
        entry,
        ...state,
      ].take(_maxSendHistoryEntries).toList(),
    );
    await notifier._persistence.setSendHistory(updated);
    return updated;
  }
}

/// Removes one entry.
class RemoveSendHistoryEntryAction extends AsyncReduxAction<SendHistoryService, List<SendHistoryEntry>> {
  final String entryId;

  RemoveSendHistoryEntryAction(this.entryId);

  @override
  Future<List<SendHistoryEntry>> reduce() async {
    final updated = List<SendHistoryEntry>.unmodifiable(
      state.where((e) => e.id != entryId).toList(),
    );
    await notifier._persistence.setSendHistory(updated);
    return updated;
  }
}

/// Clears all entries.
class RemoveAllSendHistoryEntriesAction extends AsyncReduxAction<SendHistoryService, List<SendHistoryEntry>> {
  @override
  Future<List<SendHistoryEntry>> reduce() async {
    await notifier._persistence.setSendHistory(const []);
    return const [];
  }
}

const _maxSendHistoryEntries = 100;
