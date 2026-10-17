import 'package:localsend_app/model/persistence/favorite_device.dart';

/// AnyShare modification (2026-10-17): screen share permission decision
/// (Step 8 decision D2).
///
/// Rules, in precedence order:
/// 1. blocked device -> reject (explicit user action wins).
/// 2. same owner -> accept without prompt. The owner id used here is the one
///    persisted at pairing time ([FavoriteDevice.ownerId]), never a value the
///    sender claims in the request (that one is forgeable).
/// 3. temp trust -> reject (temporary transfers may not screen-share).
/// 4. full trust -> accept without prompt.
/// 5. limited trust / unknown device -> ask the local user.
///
/// Auto-accept additionally requires the offer to come from the stored
/// address ([FavoriteDevice.ip]): the fingerprint travels over plain HTTP and
/// a LAN peer could otherwise replay a trusted fingerprint to force a stream.
/// A mismatch downgrades to asking the local user.
enum ScreenOfferDecision {
  autoAccept,
  confirm,
  rejectBlocked,
  rejectTemp,
}

ScreenOfferDecision evaluateScreenOffer({
  required FavoriteDevice? entry,
  required String localOwnerId,
  required String peerIp,
}) {
  if (entry != null && entry.blocked) {
    return ScreenOfferDecision.rejectBlocked;
  }
  if (entry != null && entry.ownerId.isNotEmpty && localOwnerId.isNotEmpty && entry.ownerId == localOwnerId) {
    return _addressMatches(entry, peerIp) ? ScreenOfferDecision.autoAccept : ScreenOfferDecision.confirm;
  }
  if (entry == null) {
    return ScreenOfferDecision.confirm;
  }
  return switch (entry.trustLevel) {
    TrustLevel.temp => ScreenOfferDecision.rejectTemp,
    TrustLevel.limited => ScreenOfferDecision.confirm,
    TrustLevel.full => _addressMatches(entry, peerIp) ? ScreenOfferDecision.autoAccept : ScreenOfferDecision.confirm,
  };
}

bool _addressMatches(FavoriteDevice entry, String peerIp) {
  return entry.ip.isNotEmpty && entry.ip == peerIp;
}
