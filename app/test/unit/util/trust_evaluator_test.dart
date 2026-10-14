import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/trust_evaluator.dart';
import 'package:test/test.dart';

void main() {
  FavoriteDevice device({
    TrustLevel trustLevel = TrustLevel.full,
    bool blocked = false,
    int maxFileSize = 0,
    QuotaMode quotaMode = QuotaMode.none,
    int quotaValue = 0,
  }) {
    return FavoriteDevice(
      id: 'id',
      fingerprint: 'fp',
      ip: '192.168.1.2',
      port: 53317,
      alias: 'Test',
      trustLevel: trustLevel,
      blocked: blocked,
      maxFileSize: maxFileSize,
      quotaMode: quotaMode,
      quotaValue: quotaValue,
    );
  }

  group('TrustEvaluator', () {
    test('unknown sender → confirm (upstream default)', () {
      final decision = TrustEvaluator.evaluate(
        entry: null,
        sessionTotalBytes: 100,
        fileSizes: [100],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustConfirm>());
    });

    test('full trust → auto accept regardless of size', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(),
        sessionTotalBytes: 1 << 40,
        fileSizes: [1 << 40],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustAutoAccept>());
    });

    test('temp trust → receiver confirms (sender does nothing)', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(trustLevel: TrustLevel.temp),
        sessionTotalBytes: 1,
        fileSizes: [1],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustConfirm>());
    });

    test('limited within limits → receiver confirms', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(trustLevel: TrustLevel.limited),
        sessionTotalBytes: 10,
        fileSizes: [10],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustConfirm>());
    });

    test('blocked → reject', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(blocked: true),
        sessionTotalBytes: 1,
        fileSizes: [1],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustReject>());
      expect((decision as TrustReject).reason, TrustRejectReason.blocked);
    });

    test('limited: file above maxFileSize → reject', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(trustLevel: TrustLevel.limited, maxFileSize: 100),
        sessionTotalBytes: 150,
        fileSizes: [150],
        receivedBytesFromSender: 0,
      );
      expect(decision, isA<TrustReject>());
      expect((decision as TrustReject).reason, TrustRejectReason.fileTooLarge);
    });

    test('limited: within absolute quota → receiver confirms', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(trustLevel: TrustLevel.limited, quotaMode: QuotaMode.absolute, quotaValue: 1000),
        sessionTotalBytes: 100,
        fileSizes: [100],
        receivedBytesFromSender: 800,
      );
      expect(decision, isA<TrustConfirm>());
    });

    test('limited: exceeding absolute quota → reject', () {
      final decision =
          TrustEvaluator.evaluate(
                entry: device(trustLevel: TrustLevel.limited, quotaMode: QuotaMode.absolute, quotaValue: 1000),
                sessionTotalBytes: 300,
                fileSizes: [100, 200],
                receivedBytesFromSender: 800,
              )
              as TrustReject;
      expect(decision.reason, TrustRejectReason.quotaExceeded);
      expect(decision.limit, 1000);
      expect(decision.used, 800);
    });

    test('limited: percent quota computed against volume size (within → confirm)', () {
      final decision = TrustEvaluator.evaluate(
        entry: device(trustLevel: TrustLevel.limited, quotaMode: QuotaMode.percent, quotaValue: 2000), // 20%
        sessionTotalBytes: 100,
        fileSizes: [100],
        receivedBytesFromSender: 0,
        destinationVolumeTotalBytes: 1 << 30, // 1 GiB → limit ≈ 204.8 MiB
      );
      expect(decision, isA<TrustConfirm>());
    });

    test('limited: percent quota exceeded', () {
      final decision =
          TrustEvaluator.evaluate(
                entry: device(trustLevel: TrustLevel.limited, quotaMode: QuotaMode.percent, quotaValue: 2000),
                sessionTotalBytes: (200 << 20) * 2, // 400 MiB > 20% of 1 GiB (≈204.8 MiB)
                fileSizes: [(200 << 20) * 2],
                receivedBytesFromSender: 0,
                destinationVolumeTotalBytes: 1 << 30,
              )
              as TrustReject;
      expect(decision.reason, TrustRejectReason.quotaExceeded);
      expect(decision.limit, (1 << 30) * 2000 ~/ 10000);
    });

    test('legacy upstream entry (all defaults) deserializes to full trust', () {
      final json = {'id': 'id', 'fingerprint': 'fp', 'ip': '192.168.1.2', 'port': 53317, 'alias': 'Old', 'customAlias': false};
      final entry = FavoriteDevice.fromJson(json);
      expect(entry.trustLevel, TrustLevel.full);
      expect(entry.blocked, false);
      expect(entry.quotaMode, QuotaMode.none);
      expect(entry.ownerId, '');
    });
  });
}
