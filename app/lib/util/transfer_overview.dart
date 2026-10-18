import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/persistence/send_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_isolates/model/session_status.dart';

/// AnyShare modification (2026-10-18): transfer overview aggregation for the
/// transfer panel (UI-3, F-XFER-16).

class ActiveTransferView {
  final String sessionId;
  final bool outgoing;
  final String peerAlias;
  final int fileCount;
  final String firstName;
  final double progress;
  final SessionStatus status;

  const ActiveTransferView({
    required this.sessionId,
    required this.outgoing,
    required this.peerAlias,
    required this.fileCount,
    required this.firstName,
    required this.progress,
    required this.status,
  });
}

class HistoryEntryView {
  final int timestampMs;
  final bool outgoing;
  final String fileName;
  final String peerAlias;
  final bool success;

  const HistoryEntryView({
    required this.timestampMs,
    required this.outgoing,
    required this.fileName,
    required this.peerAlias,
    required this.success,
  });
}

/// `recipientBusy` is terminal (the session is dead and only closable).
bool _isActive(SessionStatus status) {
  return switch (status) {
    SessionStatus.waiting || SessionStatus.sending => true,
    _ => false,
  };
}

double _aggregateProgress(
  Iterable<(String fileId, int size)> files,
  String sessionId,
  double Function(String sessionId, String fileId) progressOf,
) {
  var current = 0.0;
  var total = 0;
  for (final (fileId, size) in files) {
    current += progressOf(sessionId, fileId) * size;
    total += size;
  }
  return total == 0 ? 0 : current / total;
}

List<ActiveTransferView> activeTransfers({
  required Map<String, SendSessionState> sendSessions,
  required ServerState? server,
  required double Function(String sessionId, String fileId) progressOf,
}) {
  final views = <ActiveTransferView>[];

  for (final session in sendSessions.values) {
    if (!_isActive(session.status)) {
      continue;
    }
    final transferable = session.files.values.where((f) => f.token != null);
    // While checksums are still being computed, show that phase as progress.
    final double progress;
    if (session.hashedFileCount < session.files.length) {
      progress = session.files.isEmpty ? 0 : session.hashedFileCount / session.files.length;
    } else {
      progress = _aggregateProgress(
        transferable.map((f) => (f.file.id, f.file.size)),
        session.sessionId,
        progressOf,
      );
    }
    views.add(
      ActiveTransferView(
        sessionId: session.sessionId,
        outgoing: true,
        peerAlias: session.target.alias,
        fileCount: transferable.length,
        firstName: session.files.values.isEmpty ? '' : session.files.values.first.file.fileName,
        progress: progress,
        status: session.status,
      ),
    );
  }

  final receive = server?.session;
  if (receive != null && _isActive(receive.status)) {
    // The receive side never sets tokens; accepted files carry a desiredName.
    final accepted = receive.files.values.where((f) => f.desiredName != null);
    views.add(
      ActiveTransferView(
        sessionId: receive.sessionId,
        outgoing: false,
        peerAlias: receive.senderAlias,
        fileCount: accepted.length,
        firstName: receive.files.values.isEmpty ? '' : receive.files.values.first.file.fileName,
        progress: _aggregateProgress(
          accepted.map((f) => (f.file.id, f.file.size)),
          receive.sessionId,
          progressOf,
        ),
        status: receive.status,
      ),
    );
  }

  return views;
}

/// Merged send+receive history, newest first.
List<HistoryEntryView> mergedHistory({
  required List<SendHistoryEntry> sendHistory,
  required List<ReceiveHistoryEntry> receiveHistory,
  int limit = 30,
}) {
  final views = <HistoryEntryView>[
    for (final entry in sendHistory)
      HistoryEntryView(
        timestampMs: entry.timestamp,
        outgoing: true,
        fileName: entry.fileName,
        peerAlias: entry.receiverAlias,
        success: entry.success,
      ),
    for (final entry in receiveHistory)
      HistoryEntryView(
        timestampMs: entry.timestamp.millisecondsSinceEpoch,
        outgoing: false,
        fileName: entry.fileName,
        peerAlias: entry.senderAlias,
        success: true,
      ),
  ]..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
  return views.length <= limit ? views : views.sublist(0, limit);
}
