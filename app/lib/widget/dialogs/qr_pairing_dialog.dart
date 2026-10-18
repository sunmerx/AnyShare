import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/qr_pairing_provider.dart';
import 'package:localsend_app/util/qr_pairing.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): display-side QR pairing dialog
/// (F-PAIR-08/13). Shows a QR with address/fingerprint/owner/one-time token
/// and regenerates the token before it expires.
Future<void> showQrPairingDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const QrPairingDialog(),
  );
}

class QrPairingDialog extends StatefulWidget {
  const QrPairingDialog({super.key});

  @override
  State<QrPairingDialog> createState() => _QrPairingDialogState();
}

class _QrPairingDialogState extends State<QrPairingDialog> with Refena {
  Timer? _ticker;
  Ref? _ref;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) async {
      if (!mounted) {
        return;
      }
      _ref = ref;
      ref.redux(qrPairingProvider).dispatch(StartQrPairingAction());
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }
        final state = ref.read(qrPairingProvider);
        // Regenerate on expiry, and keep retrying while there is no usable
        // address (the network may come up while the dialog is open).
        if (state.payload == null || (state.createdAt != null && DateTime.now().difference(state.createdAt!) >= kQrPairingTtl)) {
          ref.redux(qrPairingProvider).dispatch(StartQrPairingAction());
        }
        setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ref?.redux(qrPairingProvider).dispatch(StopQrPairingAction());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch(qrPairingProvider);
    final payload = state.payload;
    final remaining = state.createdAt == null
        ? 0
        : (kQrPairingTtl - DateTime.now().difference(state.createdAt!)).inSeconds.clamp(0, kQrPairingTtl.inSeconds);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.qr_code, size: 22),
          const SizedBox(width: 8),
          Text(t.ui2.qrPairing.displayTitle),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.noAddress)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                t.ui2.qrPairing.noAddress,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            )
          else if (payload != null) ...[
            SizedBox(
              width: 220,
              height: 220,
              child: PrettyQrView.data(
                errorCorrectLevel: QrErrorCorrectLevel.Q,
                data: encodeQrPairing(payload),
                decoration: PrettyQrDecoration(
                  shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(payload.alias.isEmpty ? payload.host : '${payload.alias} · ${payload.host}', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              t.ui2.qrPairing.displayHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              t.ui2.qrPairing.expiresIn(n: remaining),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.general.close),
        ),
      ],
    );
  }
}
