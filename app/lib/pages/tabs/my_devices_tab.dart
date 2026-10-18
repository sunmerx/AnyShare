import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/pages/device_details_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/device_groups.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_app/widget/device_card.dart';
import 'package:localsend_app/widget/multi_send_info.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/selection_banner.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): "My devices" — the local device plus
/// all paired devices of the same owner (UI-1).
class MyDevicesTab extends StatelessWidget {
  const MyDevicesTab();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final owner = ref.watch(ownerProvider);
    final favorites = ref.watch(favoritesProvider);
    final discovered = ref.watch(nearbyDevicesProvider).allDevices.values.toList();
    final serverState = ref.watch(serverProvider);
    final alias = ref.watch(settingsProvider.select((s) => s.alias));
    final groups = groupDevices(discovered: discovered, favorites: favorites, myOwnerId: owner.id);

    return ResponsiveListView(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 2),
          child: Text(t.ui2.myDevices.title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Text(
          t.ui2.myDevices.subtitle(owner: owner.name.isEmpty ? '—' : owner.name),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        const SelectionBanner(),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DeviceCard(
            leading: deviceIcon(deviceType: null, self: true),
            title: alias.isEmpty ? '—' : alias,
            subtitle: serverState != null ? '${t.ui2.myDevices.receiving} · :${serverState.port}' : t.ui2.offline,
            badges: [DeviceBadge(t.ui2.myDevices.self, kind: DeviceBadgeKind.self)],
            status: DeviceStatusChip(online: serverState != null),
          ),
        ),
        ...groups.myDevices.map((entry) {
          final device = findDiscovered(discovered, entry);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _myDeviceCard(context, ref, entry, device, owner.name),
          );
        }),
        if (groups.myDevices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
            child: Text(
              t.ui2.myDevices.empty(owner: owner.name.isEmpty ? '—' : owner.name),
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _myDeviceCard(BuildContext context, Ref ref, FavoriteDevice entry, Device? device, String ownerName) {
    Widget buildCard(String? info, double? progress) {
      return DeviceCard(
        leading: deviceIcon(deviceType: device?.deviceType),
        title: entry.alias,
        subtitle: '${entry.ownerName.isNotEmpty ? entry.ownerName : ownerName} · ${entry.ip}:${entry.port}',
        badges: [
          DeviceBadge(t.ui2.myDevices.mine, kind: DeviceBadgeKind.mine),
          if (entry.trustLevel != TrustLevel.full)
            DeviceBadge(
              switch (entry.trustLevel) {
                TrustLevel.temp => t.ui2.trust.temp,
                TrustLevel.limited => t.ui2.trust.limited,
                TrustLevel.full => t.ui2.trust.full,
              },
              kind: entry.trustLevel == TrustLevel.temp ? DeviceBadgeKind.temp : DeviceBadgeKind.limited,
            ),
        ],
        status: DeviceStatusChip(online: device != null),
        infoLine: info,
        progress: progress,
        onTap: device != null ? () async => await context.push(() => DeviceDetailsPage(device: device)) : null,
        actions: [
          DeviceActionButton(
            icon: Icons.upload,
            label: t.ui2.card.sendFiles,
            primary: true,
            onTap: device != null ? () => sendToDeviceAuto(context, ref, device) : null,
            disabledTooltip: t.ui2.deviceList.offlineHint,
          ),
          DeviceActionButton(
            icon: Icons.screen_share,
            label: t.ui2.card.shareScreen,
            disabledTooltip: t.ui2.card.comingSoon,
          ),
          DeviceActionButton(
            icon: Icons.mouse,
            label: t.ui2.card.shareMouse,
            disabledTooltip: '${t.ui2.card.experimental} · ${t.ui2.card.comingSoon}',
          ),
          DeviceActionButton(
            icon: Icons.folder_open,
            label: t.ui2.card.browseDir,
            disabledTooltip: t.ui2.card.comingSoon,
          ),
        ],
      );
    }

    if (device == null) {
      return buildCard(null, null);
    }
    return MultiSendInfoBuilder(device: device, builder: (context, info, progress) => buildCard(info, progress));
  }
}
