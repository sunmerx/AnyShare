import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/widget/device_card.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): blocklist page (UI-1).
class BlocklistTab extends StatelessWidget {
  const BlocklistTab();

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final blocked = ref.watch(favoritesProvider).where((f) => f.blocked).toList();

    return ResponsiveListView(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 3, bottom: 2),
          child: Text(t.ui2.blocklist.title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Text(
          t.ui2.blocklist.subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        if (blocked.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 20),
            child: Column(
              children: [
                Icon(Icons.block, size: 46, color: Theme.of(context).colorScheme.outlineVariant),
                const SizedBox(height: 12),
                Text(t.ui2.blocklist.empty, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          )
        else
          ...blocked.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DeviceCard(
                leading: deviceIcon(deviceType: null),
                title: entry.alias,
                subtitle: '${entry.ip}:${entry.port} · ${_shortFingerprint(entry.fingerprint)}',
                actions: [
                  DeviceActionButton(
                    icon: Icons.lock_open,
                    label: t.ui2.blocklist.unblock,
                    onTap: () => _unblock(context, ref, entry),
                  ),
                  DeviceActionButton(
                    icon: Icons.delete_outline,
                    label: t.ui2.blocklist.remove,
                    onTap: () => _remove(context, ref, entry),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  String _shortFingerprint(String fingerprint) {
    if (fingerprint.length <= 10) {
      return fingerprint;
    }
    return '${fingerprint.substring(0, 6)}…${fingerprint.substring(fingerprint.length - 4)}';
  }

  Future<void> _unblock(BuildContext context, Ref ref, FavoriteDevice entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.ui2.blocklist.unblockTitle(alias: entry.alias)),
        content: Text(t.ui2.blocklist.unblockBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.ui2.cancel)),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.ui2.blocklist.unblock)),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.redux(favoritesProvider).dispatchAsync(UpdateFavoriteAction(entry.copyWith(blocked: false, trustLevel: TrustLevel.limited)));
    }
  }

  Future<void> _remove(BuildContext context, Ref ref, FavoriteDevice entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.ui2.blocklist.removeTitle(alias: entry.alias)),
        content: Text(t.ui2.blocklist.removeBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.ui2.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.ui2.blocklist.remove),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.redux(favoritesProvider).dispatchAsync(RemoveFavoriteAction(deviceFingerprint: entry.fingerprint));
    }
  }
}
