import 'package:localsend_app/model/persistence/favorite_device.dart';

/// AnyShare modification (2026-10-18): E-3 directory access evaluation
/// (docs/E3-1-设计-共享目录协议.md §2). Pure function; the caller supplies
/// the requester's favorite entry (null when unknown), the request source IP,
/// the local owner id, the directory-level writability and whether the
/// requester holds a per-device write grant.

enum DirAccess { none, readOnly, readWrite }

class DirAccessResult {
  final DirAccess access;

  /// 403 error code when [access] is none (unknown / ip_mismatch / blocked /
  /// temp_not_allowed).
  final String? reason;

  const DirAccessResult(this.access, [this.reason]);

  bool get denied => access == DirAccess.none;
}

DirAccessResult evaluateDirAccess({
  required FavoriteDevice? entry,
  required String requesterIp,
  required String myOwnerId,
  required bool writable,
  required bool writeGranted,
}) {
  if (entry == null) {
    return const DirAccessResult(DirAccess.none, 'unknown');
  }
  // The favorite's stored address is the anchor: fingerprints are
  // self-reported over plain HTTP (same hardening as screen share).
  // Fail closed: an entry without a stored address is never trusted.
  if (entry.ip.isEmpty || entry.ip != requesterIp) {
    return const DirAccessResult(DirAccess.none, 'ip_mismatch');
  }
  if (entry.blocked) {
    return const DirAccessResult(DirAccess.none, 'blocked');
  }
  final sameOwner = entry.ownerId.isNotEmpty && myOwnerId.isNotEmpty && entry.ownerId == myOwnerId;
  if (!sameOwner && entry.trustLevel == TrustLevel.temp) {
    return const DirAccessResult(DirAccess.none, 'temp_not_allowed');
  }
  // Same-owner devices may write any writable directory; full-trust devices
  // need the per-device grant; limited devices are read-only (E3-D2).
  final canWrite = writable && (sameOwner || (entry.trustLevel == TrustLevel.full && writeGranted));
  return DirAccessResult(canWrite ? DirAccess.readWrite : DirAccess.readOnly);
}
