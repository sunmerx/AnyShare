import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/pairing_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Initiator-side pairing flow dialog: probe → register → show SAS code →
/// user verifies on both screens → confirm.
///
/// [onPaired] is called with the finished favorite entry so the details page
/// can refresh.
Future<void> showInitiatorPairingDialog(BuildContext context, {required String host, required int extPort, required void Function(FavoriteDevice) onPaired}) async {
  await showDialog(
    context: context,
    builder: (_) => _InitiatorPairingDialog(host: host, extPort: extPort, onPaired: onPaired),
  );
}

class _InitiatorPairingDialog extends StatefulWidget {
  final String host;
  final int extPort;
  final void Function(FavoriteDevice) onPaired;

  const _InitiatorPairingDialog({required this.host, required this.extPort, required this.onPaired});

  @override
  State<_InitiatorPairingDialog> createState() => _InitiatorPairingDialogState();
}

enum _Phase { probing, code, done, failed }

class _InitiatorPairingDialogState extends State<_InitiatorPairingDialog> with Refena {
  _Phase _phase = _Phase.probing;
  String? _code;
  PairingSession? _session;
  String? _error;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) => _run(ref));
  }

  Future<void> _run(Ref ref) async {
    try {
      final session = await ref.pairRegister(host: widget.host, extPort: widget.extPort, peerFingerprint: '');
      final code = await ref.deriveLocalCode(session: session);
      if (!mounted) {
        return;
      }
      setState(() {
        _session = session;
        _code = code;
        _phase = _Phase.code;
      });
      // AnyShare ruling (2026-10-12): only the responder confirms the SAS
      // comparison — the initiator just displays the code and waits. The
      // confirm request blocks server-side until the responder accepts.
      await _confirm();
    } on PairingException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.error == PairingError.unreachable ? t.deviceDetailsPage.pairing.notSupported : pairingErrorMessage(e.error);
        _phase = _Phase.failed;
      });
    }
  }

  Future<void> _confirm() async {
    final session = _session;
    if (session == null) {
      return;
    }
    try {
      final result = await ref.pairConfirm(host: widget.host, extPort: widget.extPort, session: session, peerIp: widget.host);
      await finishPairing(ref, result);
      widget.onPaired(result.device);
      if (!mounted) {
        return;
      }
      setState(() => _phase = _Phase.done);
    } on PairingException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = pairingErrorMessage(e.error);
        _phase = _Phase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tp = t.deviceDetailsPage.pairing;
    return AlertDialog(
      title: Text(tp.start),
      content: switch (_phase) {
        _Phase.probing => Row(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(width: 15), Text(tp.probing)]),
        _Phase.code => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tp.codeTitle),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  _code ?? '',
                  style: Theme.of(context).textTheme.displayMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 8),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: Text(tp.waitingPeer, style: const TextStyle(color: Colors.grey, fontSize: 12))),
            ],
          ),
        _Phase.done => Text(tp.done(name: _session?.peerAlias ?? '')),
        _Phase.failed => Text(_error ?? '', style: TextStyle(color: Theme.of(context).colorScheme.error)),
      },
      actions: [
        if (_phase == _Phase.code)
          // Initiator cannot complete the pairing themselves; closing here
          // aborts on their side (the responder's gate then times out).
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tp.mismatch),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.general.close),
          ),
      ],
    );
  }
}

/// Responder-side dialog: shows the incoming pairing code. Wired to
/// [extensionServerProvider] state by the home page listener.
class ResponderPairingDialog extends StatelessWidget {
  final PendingPairing pending;

  const ResponderPairingDialog({required this.pending, super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final tp = t.pairingIncoming;
    return AlertDialog(
      title: Text(tp.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tp.body(name: pending.peerAlias)),
          const SizedBox(height: 12),
          Center(
            child: Text(
              pending.code,
              style: Theme.of(context).textTheme.displayMedium?.copyWith(fontFamily: 'monospace', letterSpacing: 8),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            ref.redux(extensionServerProvider).dispatch(AbortPendingPairingAction());
            Navigator.of(context).pop();
          },
          child: Text(tp.mismatch),
        ),
        FilledButton(
          onPressed: () async {
            await ref.redux(extensionServerProvider).dispatchAsync(AcceptPendingPairingAction());
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: Text(tp.match),
        ),
      ],
    );
  }
}
