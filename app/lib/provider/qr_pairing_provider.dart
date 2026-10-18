import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/qr_pairing.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// AnyShare modification (2026-10-18): display-side state of QR pairing
/// (F-PAIR-08/13). The extension server validates the one-time token against
/// this state; the dialog regenerates it before it expires.

const Duration kQrPairingTtl = Duration(seconds: 60);

class QrPairingState {
  final QrPairingPayload? payload;
  final DateTime? createdAt;

  /// No usable LAN address (QR pairing unavailable).
  final bool noAddress;

  const QrPairingState({this.payload, this.createdAt, this.noAddress = false});

  bool get isActive => payload != null && createdAt != null;

  bool isValidToken(String token) {
    if (!isActive || payload!.token != token) {
      return false;
    }
    return DateTime.now().difference(createdAt!) <= kQrPairingTtl;
  }
}

final qrPairingProvider = ReduxProvider<QrPairingService, QrPairingState>((ref) {
  return QrPairingService(ref);
});

class QrPairingService extends ReduxNotifier<QrPairingState> {
  final Ref ref;

  QrPairingService(this.ref);

  @override
  QrPairingState init() => const QrPairingState();

  /// Builds a fresh payload from the current network/identity state.
  QrPairingState build() {
    final host = _pickHost();
    final server = ref.read(serverProvider);
    if (host == null || server == null) {
      // No usable LAN address or the extension server did not bind: the QR
      // would point at a dead endpoint.
      return const QrPairingState(noAddress: true);
    }
    final owner = ref.read(ownerProvider);
    return QrPairingState(
      payload: QrPairingPayload(
        host: host,
        extPort: kExtensionPort,
        fingerprint: ref.read(securityProvider).certificateHash,
        alias: server.alias,
        ownerId: owner.id,
        ownerName: owner.name,
        token: const Uuid().v4(),
      ),
      createdAt: DateTime.now(),
    );
  }

  String? _pickHost() {
    final ips = ref.read(localIpProvider).localIps;
    for (final ip in ips) {
      if (ip.contains('.') && !ip.startsWith('127.')) {
        return ip;
      }
    }
    return null;
  }
}

/// (Re)generates the QR payload; called when the dialog opens and on expiry.
class StartQrPairingAction extends ReduxAction<QrPairingService, QrPairingState> {
  @override
  QrPairingState reduce() => notifier.build();
}

/// Invalidates the current QR payload (dialog closed).
class StopQrPairingAction extends ReduxAction<QrPairingService, QrPairingState> {
  @override
  QrPairingState reduce() => const QrPairingState();
}
