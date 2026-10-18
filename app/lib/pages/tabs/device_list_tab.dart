import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/pages/device_details_page.dart';
import 'package:localsend_app/pages/dir_browse_page.dart';
import 'package:localsend_app/pages/qr_scan_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/screen/screen_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/device_groups.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/screen_capabilities.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_app/widget/circular_popup_button.dart';
import 'package:localsend_app/widget/custom_icon_button.dart';
import 'package:localsend_app/widget/device_card.dart';
import 'package:localsend_app/widget/dialogs/pairing_dialog.dart';
import 'package:localsend_app/widget/dialogs/qr_pairing_dialog.dart';
import 'package:localsend_app/widget/dialogs/send_mode_help_dialog.dart';
import 'package:localsend_app/widget/multi_send_info.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/rotating_widget.dart';
import 'package:localsend_app/widget/selection_banner.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): "Devices" — nearby (unpaired) plus
/// paired devices of other owners (UI-1).
class DeviceListTab extends StatefulWidget {
  const DeviceListTab();

  @override
  State<DeviceListTab> createState() => _DeviceListTabState();
}

class _DeviceListTabState extends State<DeviceListTab> with Refena {
  @override
  void initState() {
    super.initState();
    // Auto-scan once when the page opens with no devices (same behavior as
    // the former send tab).
    ensureRef((ref) async {
      if (ref.read(nearbyDevicesProvider).devices.isEmpty) {
        await ref.global.dispatchAsync(StartSmartScan());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final owner = ref.watch(ownerProvider);
    final favorites = ref.watch(favoritesProvider);
    final discovered = ref.watch(nearbyDevicesProvider).allDevices.values.toList();
    final groups = groupDevices(discovered: discovered, favorites: favorites, myOwnerId: owner.id);

    return ResponsiveListView(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 2),
          child: Text(t.ui2.deviceList.title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Row(
          children: [
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                t.ui2.deviceList.subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            const _ScanButton(),
            Tooltip(
              message: t.ui2.deviceList.manualAddress,
              child: CustomIconButton(
                onPressed: () async => await sendViaAddressDialog(context, ref),
                child: const Icon(Icons.ads_click),
              ),
            ),
            const _SendModeButton(),
            Tooltip(
              message: t.ui2.deviceList.qrPairing,
              child: CustomIconButton(
                onPressed: () async {
                  if (checkPlatform([TargetPlatform.android, TargetPlatform.iOS])) {
                    await context.push(() => const QrScanPage());
                  } else {
                    await showQrPairingDialog(context);
                  }
                },
                child: const Icon(Icons.qr_code),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const SelectionBanner(),
        _sectionTitle(context, t.ui2.deviceList.nearby, groups.nearby.length),
        if (groups.nearby.isEmpty)
          _emptyHint(context, t.ui2.deviceList.nearbyEmpty)
        else
          ...groups.nearby.map((device) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MultiSendInfoBuilder(
                device: device,
                builder: (context, info, progress) => DeviceCard(
                  leading: deviceIcon(deviceType: device.deviceType),
                  title: device.alias,
                  subtitle: '${device.deviceModel} · ${device.ip}:${device.port}',
                  status: const DeviceStatusChip(online: true),
                  infoLine: info,
                  progress: progress,
                  onTap: () async => await context.push(() => DeviceDetailsPage(device: device)),
                  actions: [
                    DeviceActionButton(
                      icon: Icons.upload,
                      label: t.ui2.card.sendFiles,
                      primary: true,
                      onTap: () => sendToDeviceAuto(context, ref, device),
                    ),
                    DeviceActionButton(
                      icon: Icons.link,
                      label: t.ui2.card.pair,
                      onTap: () => _pair(context, device),
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 12),
        _sectionTitle(context, t.ui2.deviceList.paired, groups.paired.length),
        if (groups.paired.isEmpty)
          _emptyHint(context, t.ui2.deviceList.pairedEmpty)
        else
          ...groups.paired.map((entry) {
            final device = findDiscovered(discovered, entry);
            final isTemp = entry.trustLevel == TrustLevel.temp;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _pairedCard(context, ref, entry, device, isTemp),
            );
          }),
      ],
    );
  }

  Widget _pairedCard(BuildContext context, Ref ref, FavoriteDevice entry, Device? device, bool isTemp) {
    Widget buildCard(String? info, double? progress) {
      return DeviceCard(
        leading: deviceIcon(deviceType: device?.deviceType),
        title: entry.alias,
        subtitle: '${entry.ownerName.isNotEmpty ? entry.ownerName : '—'} · ${entry.ip}:${entry.port}',
        badges: [
          DeviceBadge(
            switch (entry.trustLevel) {
              TrustLevel.temp => t.ui2.trust.temp,
              TrustLevel.limited => t.ui2.trust.limited,
              TrustLevel.full => t.ui2.trust.full,
            },
            kind: switch (entry.trustLevel) {
              TrustLevel.temp => DeviceBadgeKind.temp,
              TrustLevel.limited => DeviceBadgeKind.limited,
              TrustLevel.full => DeviceBadgeKind.full,
            },
          ),
        ],
        status: DeviceStatusChip(online: device != null),
        infoLine: info,
        progress: progress,
        onTap: () async {
          if (device != null) {
            await context.push(() => DeviceDetailsPage(device: device));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ui2.deviceList.offlineHint)));
          }
        },
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
            onTap: (device != null && device.ip?.isNotEmpty == true && !isTemp && canSendScreenShare())
                ? () => ref
                      .redux(screenProvider)
                      .dispatchAsync(
                        StartScreenShareAction(peerIp: device.ip!, peerAlias: device.alias),
                      )
                : null,
            disabledTooltip: isTemp ? t.ui2.card.tempNoScreen : (!canSendScreenShare() ? t.ui2.screen.unsupportedSend : t.ui2.deviceList.offlineHint),
          ),
          DeviceActionButton(
            icon: Icons.mouse,
            label: t.ui2.card.shareMouse,
            disabledTooltip: '${t.ui2.card.experimental} · ${t.ui2.card.comingSoon}',
          ),
          DeviceActionButton(
            icon: Icons.folder_open,
            label: t.ui2.card.browseDir,
            onTap: (device != null && device.ip?.isNotEmpty == true)
                ? () async => await context.push(() => DirBrowsePage(fingerprint: entry.fingerprint, host: device.ip!, title: entry.alias))
                : null,
            disabledTooltip: t.ui2.deviceList.offlineHint,
          ),
        ],
      );
    }

    if (device == null) {
      return buildCard(null, null);
    }
    return MultiSendInfoBuilder(device: device, builder: (context, info, progress) => buildCard(info, progress));
  }

  Widget _sectionTitle(BuildContext context, String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10, left: 3),
      child: Text.rich(
        TextSpan(
          text: title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          children: [
            TextSpan(
              text: '  $count',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Future<void> _pair(BuildContext context, Device device) async {
    // Prefer an IPv4 channel when pairing (IPv6 link-local needs matching
    // scopes and is more fragile on LANs).
    final pairHost = device.channels.whereType<HttpChannel>().map((c) => c.host).firstWhere((h) => !h.contains(':'), orElse: () => device.ip ?? '');
    if (pairHost.isEmpty) {
      return;
    }
    await showInitiatorPairingDialog(
      context,
      host: pairHost,
      extPort: kExtensionPort,
      onPaired: (_) {},
    );
  }
}

class _ScanButton extends StatelessWidget {
  const _ScanButton();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final (scanningFavorites, scanningIps) = ref.watch(nearbyDevicesProvider.select((s) => (s.runningFavoriteScan, s.runningIps)));
    final animations = ref.watch(animationProvider);
    final ips = ref.watch(localIpProvider).localIps;

    final spinning = (scanningFavorites || scanningIps.isNotEmpty) && animations;
    final iconColor = !animations && scanningIps.isNotEmpty ? Theme.of(context).colorScheme.error : null;

    if (ips.length <= StartSmartScan.maxInterfaces) {
      return Tooltip(
        message: t.ui2.deviceList.rescan,
        child: RotatingWidget(
          duration: const Duration(seconds: 2),
          spinning: spinning,
          reverse: true,
          child: CustomIconButton(
            onPressed: () async {
              context.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
              await context.global.dispatchAsync(StartSmartScan());
            },
            child: Icon(Icons.sync, color: iconColor),
          ),
        ),
      );
    }

    // Too many interfaces for the smart scan: offer a per-subnet scan.
    return CircularPopupButton<String>(
      tooltip: t.ui2.deviceList.rescan,
      onSelected: (ip) async {
        context.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
        await context.global.dispatchAsync(StartLegacySubnetScan(subnets: [ip]));
      },
      itemBuilder: (_) {
        return [
          ...ips.map(
            (ip) => PopupMenuItem(
              value: ip,
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RotatingSyncIcon(ip),
                  const SizedBox(width: 10),
                  Text(ip),
                ],
              ),
            ),
          ),
        ];
      },
      child: RotatingWidget(
        duration: const Duration(seconds: 2),
        spinning: spinning,
        reverse: true,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.sync, color: iconColor),
        ),
      ),
    );
  }
}

/// A separate widget, so it gets the latest data from provider.
class _RotatingSyncIcon extends StatelessWidget {
  final String ip;

  const _RotatingSyncIcon(this.ip);

  @override
  Widget build(BuildContext context) {
    final scanningIps = context.ref.watch(nearbyDevicesProvider.select((s) => s.runningIps));
    return RotatingWidget(
      duration: const Duration(seconds: 2),
      spinning: scanningIps.contains(ip),
      reverse: true,
      child: const Icon(Icons.sync),
    );
  }
}

class _SendModeButton extends StatelessWidget {
  const _SendModeButton();

  @override
  Widget build(BuildContext context) {
    return CircularPopupButton<int>(
      tooltip: t.ui2.deviceList.sendMode,
      onSelected: (mode) async {
        switch (mode) {
          case 0:
            await setSendMode(context.ref, SendMode.single);
            break;
          case 1:
            await setSendMode(context.ref, SendMode.multiple);
            break;
          case 2:
            await startWebShare(context, context.ref);
            break;
          case -1:
            await showDialog(context: context, builder: (_) => const SendModeHelpDialog());
            break;
        }
      },
      itemBuilder: (_) => [
        _modeItem(context, 0, SendMode.single, t.sendTab.sendModes.single),
        _modeItem(context, 1, SendMode.multiple, t.sendTab.sendModes.multiple),
        _modeItem(context, 2, SendMode.link, t.sendTab.sendModes.link, showCheck: false),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: -1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Directionality(textDirection: TextDirection.ltr, child: Icon(Icons.help)),
              const SizedBox(width: 10),
              Text(t.sendTab.sendModeHelp),
            ],
          ),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.settings),
      ),
    );
  }

  PopupMenuItem<int> _modeItem(BuildContext context, int value, SendMode mode, String label, {bool showCheck = true}) {
    return PopupMenuItem(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Consumer(
            builder: (context, ref) {
              final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
              return Visibility(
                visible: showCheck && sendMode == mode,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: const Icon(Icons.check_circle),
              );
            },
          ),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }
}
