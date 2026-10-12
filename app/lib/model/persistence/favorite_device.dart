import 'package:dart_mappable/dart_mappable.dart';
import 'package:uuid/uuid.dart';

part 'favorite_device.mapper.dart';

const _uuid = Uuid();

/// AnyShare modification (2026-10-12): trust levels on top of upstream favorites.
/// [full] equals upstream's quickSaveFromFavorites behavior (auto-accept, no
/// limits); missing fields in old persisted entries deserialize to [full] for
/// behavior continuity. See docs/扩展协议设计.md §3.
@MappableEnum()
enum TrustLevel {
  /// Not on the trust list: every transfer asks the user (upstream default).
  temp,

  /// Trusted with limits (max file size / receive quota).
  limited,

  /// Fully trusted: auto-accept without limits.
  full,
}

/// AnyShare modification (2026-10-12): receive-quota modes for [TrustLevel.limited].
@MappableEnum()
enum QuotaMode {
  none,

  /// [FavoriteDevice.quotaValue] is an absolute number of bytes.
  absolute,

  /// [FavoriteDevice.quotaValue] is a fraction of the destination volume in
  /// ten-thousandths (2000 = 20%).
  percent,
}

@MappableClass()
class FavoriteDevice with FavoriteDeviceMappable {
  final String id;
  final String fingerprint;
  final String ip;
  final int port;
  final String alias;

  /// If true, the alias was set by the user.
  /// If false, the alias is derived from the original device alias and
  /// should be updated when the original device alias changes.
  final bool customAlias;

  /// AnyShare modification: self-reported owner of the device (exchanged via
  /// the AnyShare extension, see docs/扩展协议设计.md). Empty until first
  /// extension contact.
  final String ownerId;

  /// AnyShare modification: display name of the owner.
  final String ownerName;

  /// AnyShare modification: trust level. Defaults to [TrustLevel.full] so that
  /// entries persisted by upstream (plain favorites) keep auto-accepting.
  final TrustLevel trustLevel;

  /// AnyShare modification: blocked devices are rejected without a prompt.
  final bool blocked;

  /// AnyShare modification: [TrustLevel.limited] only — maximum size of a
  /// single file in bytes; 0 = unlimited.
  final int maxFileSize;

  /// AnyShare modification: [TrustLevel.limited] only — quota mode.
  final QuotaMode quotaMode;

  /// AnyShare modification: [TrustLevel.limited] only — quota amount; meaning
  /// depends on [quotaMode] (bytes or ten-thousandths of the volume).
  final int quotaValue;

  const FavoriteDevice({
    required this.id,
    required this.fingerprint,
    required this.ip,
    required this.port,
    required this.alias,
    this.customAlias = false,
    this.ownerId = '',
    this.ownerName = '',
    this.trustLevel = TrustLevel.full,
    this.blocked = false,
    this.maxFileSize = 0,
    this.quotaMode = QuotaMode.none,
    this.quotaValue = 0,
  });

  factory FavoriteDevice.fromValues({
    required String fingerprint,
    required String ip,
    required int port,
    required String alias,
  }) {
    return FavoriteDevice(
      id: _uuid.v1(),
      fingerprint: fingerprint,
      ip: ip,
      port: port,
      alias: alias,
      customAlias: false,
    );
  }

  static const fromJson = FavoriteDeviceMapper.fromJson;
}
