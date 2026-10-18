import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/favorites.dart';
import 'package:localsend_isolates/model/device.dart';

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
