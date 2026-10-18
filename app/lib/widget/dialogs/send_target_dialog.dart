import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/util/device_groups.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_app/widget/device_card.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): "Send to…" device picker (UI-3) —
/// used by the selection banner. Offline paired devices are shown disabled
/// (F-SYS-03: explicit offline hint instead of silent failure).
Future<void> showSendTargetDialog(BuildContext context) async {
  final device = await showDialog<Device>(context: context, builder: (_) => const SendTargetDialog());
  if (device != null && context.mounted) {
    await sendToDeviceAuto(context, context.ref, device);
  }
}

class SendTargetDialog extends StatelessWidget {
  const SendTargetDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final owner = ref.watch(ownerProvider);
    final favorites = ref.watch(favoritesProvider);
    final discovered = ref.watch(nearbyDevicesProvider).allDevices.values.toList();
    final groups = groupDevices(discovered: discovered, favorites: favorites, myOwnerId: owner.id);
    final theme = Theme.of(context);

    final onlineEntries = <(Device, bool)>[
      for (final device in groups.nearby)
        if (device.ip?.isNotEmpty == true) (device, false),
      for (final entry in [...groups.myDevices, ...groups.paired])
        if (findDiscovered(discovered, entry) case final device? when device.ip?.isNotEmpty == true) (device, true),
    ];
    final offlineEntries = [
      for (final entry in [...groups.myDevices, ...groups.paired])
        if (findDiscovered(discovered, entry) == null) entry,
    ];

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.send, size: 22),
          const SizedBox(width: 8),
          Text(t.ui2.transfers.pickTarget),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: onlineEntries.isEmpty && offlineEntries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    t.ui2.transfers.noTargets,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (device, isPaired) in onlineEntries)
                      ListTile(
                        dense: true,
                        leading: deviceIcon(deviceType: device.deviceType),
                        title: Text(device.alias, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${device.deviceModel} · ${device.ip}${isPaired ? ' · ${t.ui2.deviceList.paired}' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.of(context).pop(device),
                      ),
                    for (final entry in offlineEntries)
                      ListTile(
                        dense: true,
                        enabled: false,
                        leading: deviceIcon(deviceType: null),
                        title: Text(entry.alias, overflow: TextOverflow.ellipsis),
                        subtitle: Text(t.ui2.deviceList.offlineHint),
                      ),
                  ],
                ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.ui2.cancel)),
      ],
    );
  }
}
