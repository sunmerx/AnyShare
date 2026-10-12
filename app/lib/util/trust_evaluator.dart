import 'package:localsend_app/model/persistence/favorite_device.dart';

/// AnyShare modification (2026-10-12): outcome of the trust decision chain
/// evaluated for every incoming session (docs/扩展协议设计.md §3.2).
sealed class TrustDecision {
  const TrustDecision();
}

/// Skip the confirmation dialog and receive immediately.
class TrustAutoAccept extends TrustDecision {
  const TrustAutoAccept();
}

/// Fall through to the upstream confirmation flow (ReceivePage / quickSave
/// settings still apply).
class TrustConfirm extends TrustDecision {
  const TrustConfirm();
}

/// Decline the session without bothering the user.
class TrustReject extends TrustDecision {
  final TrustRejectReason reason;

  /// The configured limit, for logging and future UI.
  final int? limit;
  final int? used;

  const TrustReject(this.reason, {this.limit, this.used});
}

enum TrustRejectReason { blocked, fileTooLarge, quotaExceeded }

/// Pure decision chain, keyed by the sender's mTLS certificate fingerprint
/// (the only unforgeable identity). `null` entry = not on the trust list.
class TrustEvaluator {
  const TrustEvaluator._();

  static TrustDecision evaluate({
    required FavoriteDevice? entry,
    required int sessionTotalBytes,
    required List<int> fileSizes,
    required int receivedBytesFromSender,
    int? destinationVolumeTotalBytes,
  }) {
    final FavoriteDevice? device = entry;
    if (device == null) {
      return const TrustConfirm();
    }
    if (device.blocked) {
      return TrustReject(TrustRejectReason.blocked);
    }
    switch (device.trustLevel) {
      case TrustLevel.full:
        return const TrustAutoAccept();
      case TrustLevel.temp:
        return const TrustConfirm();
      case TrustLevel.limited:
        if (device.maxFileSize > 0 && fileSizes.any((s) => s > device.maxFileSize)) {
          return TrustReject(TrustRejectReason.fileTooLarge, limit: device.maxFileSize);
        }
        final int? quotaLimit = switch (device.quotaMode) {
          QuotaMode.none => null,
          QuotaMode.absolute => device.quotaValue,
          QuotaMode.percent =>
            destinationVolumeTotalBytes == null ? null : (destinationVolumeTotalBytes * device.quotaValue) ~/ 10000,
        };
        if (quotaLimit != null && quotaLimit > 0 && receivedBytesFromSender + sessionTotalBytes > quotaLimit) {
          return TrustReject(TrustRejectReason.quotaExceeded, limit: quotaLimit, used: receivedBytesFromSender);
        }
        return const TrustAutoAccept();
    }
  }
}
