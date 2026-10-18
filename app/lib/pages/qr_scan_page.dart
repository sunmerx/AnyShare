import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/util/qr_pairing.dart';
import 'package:localsend_app/widget/dialogs/pairing_dialog.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): QR scanner page (F-PAIR-08/13).
/// The scanner is the active joiner: when the scanned code carries an owner
/// identity, the user may adopt it ("join my owner", committed only after the
/// pairing succeeds), then the regular SAS pairing flow runs against the
/// scanned host — the QR fingerprint is verified against the register
/// response. On failure the camera restarts so the user can rescan.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> with Refena, WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  bool _permissionDenied = false;
  String? _invalidHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ensureRef((ref) async {
      final status = await Permission.camera.request();
      if (!mounted) {
        return;
      }
      if (status.isGranted) {
        await _controller.start();
      } else {
        setState(() => _permissionDenied = true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // ignore: discarded_futures
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_permissionDenied || _handled) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        // ignore: discarded_futures
        _controller.start();
        break;
      case AppLifecycleState.inactive || AppLifecycleState.paused:
        // ignore: discarded_futures
        _controller.stop();
        break;
      default:
        break;
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) {
      return;
    }
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null) {
      return;
    }
    final payload = decodeQrPairing(raw);
    if (payload == null) {
      if (_invalidHint != t.ui2.qrPairing.invalidCode) {
        setState(() => _invalidHint = t.ui2.qrPairing.invalidCode);
      }
      return;
    }
    _handled = true;
    await _controller.stop();
    if (!mounted) {
      return;
    }
    await _handlePayload(context.ref, payload);
  }

  Future<void> _handlePayload(Ref ref, QrPairingPayload payload) async {
    // F-PAIR-13: the scanned code may carry an owner identity — offer to join.
    final owner = ref.read(ownerProvider);
    final canJoin = payload.ownerId.isNotEmpty && payload.ownerId != owner.id;
    var join = false;
    if (canJoin) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.ui2.qrPairing.joinOwnerTitle),
          content: Text(t.ui2.qrPairing.joinOwnerBody(name: payload.ownerName.isEmpty ? payload.alias : payload.ownerName)),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.ui2.qrPairing.justPair)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.ui2.qrPairing.join)),
          ],
        ),
      );
      join = confirmed == true;
    }

    if (!mounted) {
      return;
    }
    final paired = await showInitiatorPairingDialog(
      context,
      host: payload.host,
      extPort: payload.extPort,
      qrToken: payload.token,
      expectedFingerprint: payload.fingerprint,
      onPaired: (_) {},
    );

    if (!context.mounted) {
      return;
    }
    if (paired == null) {
      // Cancelled or failed: let the user scan again.
      _handled = false;
      setState(() => _invalidHint = null);
      await _controller.start();
      return;
    }

    // F-PAIR-13: commit the owner change only after a successful pairing.
    if (join) {
      ref
          .redux(ownerProvider)
          .dispatch(
            SetOwnerIdentityAction(
              id: payload.ownerId,
              name: payload.ownerName.isEmpty ? payload.alias : payload.ownerName,
            ),
          );
    }
    // The scanner page is about to be popped: use the app-level messenger.
    ScaffoldMessenger.maybeOf(Routerino.context)?.showSnackBar(
      SnackBar(
        content: Text(
          join ? t.ui2.qrPairing.joinedOwner(name: payload.ownerName) : t.ui2.qrPairing.paired,
        ),
      ),
    );
    if (context.mounted) {
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.ui2.qrPairing.scanTitle)),
      body: Stack(
        children: [
          if (_permissionDenied)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.ui2.qrPairing.permissionDenied, textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () => openAppSettings(),
                      child: Text(t.ui2.qrPairing.openSettings),
                    ),
                  ],
                ),
              ),
            )
          else
            MobileScanner(controller: _controller, onDetect: _onDetect),
          if (!_permissionDenied)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      _invalidHint ?? t.ui2.qrPairing.scanHint,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
