import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';

/// Peer-side confirmation for "this is my device": accepting makes both
/// devices share the requester's owner identity.
class OwnerClaimDialog extends StatelessWidget {
  final String alias;
  final Completer<bool> gate;

  const OwnerClaimDialog({super.key, required this.alias, required this.gate});

  void _answer(BuildContext context, bool accepted) {
    if (!gate.isCompleted) {
      gate.complete(accepted);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.devices_other, size: 22),
          const SizedBox(width: 8),
          Text(t.ui2.ownerClaim.title),
        ],
      ),
      content: Text(t.ui2.ownerClaim.body(alias: alias)),
      actions: [
        TextButton(onPressed: () => _answer(context, false), child: Text(t.general.cancel)),
        FilledButton(onPressed: () => _answer(context, true), child: Text(t.general.accept)),
      ],
    );
  }
}
