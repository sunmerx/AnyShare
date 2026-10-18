import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/screen/screen_provider.dart';
import 'package:localsend_app/util/screen_capabilities.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): receiver-side screen share request
/// dialog (UI-2/W3). Pushed via Routerino from the extension server, mirroring
/// [ResponderPairingDialog].
///
/// The dialog follows the provider: when the offer expires (60s TTL) or is
/// cleared by a remote stop, it pops itself; Accept/Abort carry the session
/// id so a stale dialog can never act on a newer offer.
class ScreenOfferDialog extends StatefulWidget {
  final PendingScreenOffer pending;

  const ScreenOfferDialog({required this.pending, super.key});

  @override
  State<ScreenOfferDialog> createState() => _ScreenOfferDialogState();
}

class _ScreenOfferDialogState extends State<ScreenOfferDialog> with Refena {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final screenState = context.watch(screenProvider);
    final pending = screenState.pendingOffer;
    final stale = pending == null || pending.sessionId != widget.pending.sessionId;
    if (stale) {
      // The offer was answered elsewhere, expired, or was cancelled remotely:
      // close the dialog on the next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          // ignore: discarded_futures
          Navigator.of(context).maybePop();
        }
      });
      return const SizedBox.shrink();
    }

    final ref = context.ref;
    final canReceive = canReceiveScreenShare();
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.screen_share, size: 22),
          const SizedBox(width: 8),
          Text(t.ui2.screen.requestTitle),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.ui2.screen.requestBody(alias: widget.pending.peerAlias)),
          if (!canReceive) ...[
            const SizedBox(height: 10),
            Text(
              t.ui2.screen.unsupportedReceive,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12.5),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  await ref.redux(screenProvider).dispatchAsync(
                        AbortPendingScreenOfferAction(sessionId: widget.pending.sessionId),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: Text(t.ui2.screen.reject),
        ),
        FilledButton(
          onPressed: (!canReceive || _busy)
              ? null
              : () async {
                  setState(() => _busy = true);
                  await ref.redux(screenProvider).dispatchAsync(
                        AcceptPendingScreenOfferAction(sessionId: widget.pending.sessionId),
                      );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
          child: Text(t.ui2.screen.accept),
        ),
      ],
    );
  }
}
