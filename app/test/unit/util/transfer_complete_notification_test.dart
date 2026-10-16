import 'package:localsend_app/util/native/transfer_complete_notification.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:test/test.dart';

void main() {
  group('TransferCompleteNotification.summarize', () {
    test('counts finished files as completed', () {
      final summary = TransferCompleteNotification.summarize([FileStatus.finished, FileStatus.finished]);
      expect(summary.completed, 2);
      expect(summary.failed, 0);
    });

    test('counts failed files separately', () {
      final summary = TransferCompleteNotification.summarize([FileStatus.finished, FileStatus.failed, FileStatus.failed]);
      expect(summary.completed, 1);
      expect(summary.failed, 2);
    });

    test('ignores queued and skipped files', () {
      final summary = TransferCompleteNotification.summarize([FileStatus.queue, FileStatus.skipped, FileStatus.finished]);
      expect(summary.completed, 1);
      expect(summary.failed, 0);
    });

    test('returns zeros for an empty session', () {
      final summary = TransferCompleteNotification.summarize(const []);
      expect(summary.completed, 0);
      expect(summary.failed, 0);
    });
  });
}
