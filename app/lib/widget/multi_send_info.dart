import 'package:flutter/material.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): in multiple-send mode, provides the
/// live session info/progress for a device card (UI-1).
class MultiSendInfoBuilder extends StatelessWidget {
  final Device device;
  final Widget Function(BuildContext context, String? info, double? progress) builder;

  const MultiSendInfoBuilder({required this.device, required this.builder, super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
    if (sendMode != SendMode.multiple) {
      return builder(context, null, null);
    }
    ref.watch(sendProvider);
    ref.watch(fileTransferProvider);
    final (info, progress) = sessionStatusFor(ref, device);
    return builder(context, info, progress);
  }
}
