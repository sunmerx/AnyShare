import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/favorites.dart';
import 'package:localsend_isolates/model/device.dart';

/// Returns the favorite updated to the address the device was just
/// discovered on, or null when the address is unchanged.
///
/// A paired device that changes its IP (DHCP lease, WiFi instead of Ethernet)
/// must stay reachable: keeping the stale address in the favorite leaves the
/// UI showing the old IP and every connection to that device fails.
FavoriteDevice? favoriteWithRefreshedAddress(FavoriteDevice favorite, Device device) {
  if (favorite.ip == device.ip && favorite.port == device.port) {
    return null;
  }
  return favorite.copyWith(
    ip: device.ip,
    port: device.port,
    alias: favorite.customAlias ? favorite.alias : device.alias,
  );
}

/// AnyShare modification (2026-10-18): home redesign (UI-1) device grouping.
///
/// - [myDevices]: paired devices belonging to the local owner (same ownerId).
/// - [paired]: paired devices of other owners (not blocked).
/// - [blocked]: blocklisted entries.
/// - [nearby]: discovered devices that are not paired yet (blocked devices
///   never appear here).
class DeviceGroups {
  final List<FavoriteDevice> myDevices;
  final List<FavoriteDevice> paired;
  final List<FavoriteDevice> blocked;
  final List<Device> nearby;

  const DeviceGroups({
    required this.myDevices,
    required this.paired,
    required this.blocked,
    required this.nearby,
  });
}

DeviceGroups groupDevices({
  required Iterable<Device> discovered,
  required List<FavoriteDevice> favorites,
  required String myOwnerId,
}) {
  bool isMine(FavoriteDevice f) => f.ownerId.isNotEmpty && myOwnerId.isNotEmpty && f.ownerId == myOwnerId;

  final blocked = favorites.where((f) => f.blocked).toList();
  final active = favorites.where((f) => !f.blocked).toList();
  return DeviceGroups(
    myDevices: active.where(isMine).toList(),
    paired: active.where((f) => !isMine(f)).toList(),
    blocked: blocked,
    nearby: discovered.where((d) => favorites.findDevice(d) == null).toList(),
  );
}
