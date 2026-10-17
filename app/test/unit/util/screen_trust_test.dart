import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/screen_trust.dart';

void main() {
  const localOwner = 'owner-local';
  const peerIp = '10.0.0.5';

  FavoriteDevice device({
    required TrustLevel trustLevel,
    bool blocked = false,
    String ownerId = '',
    String ip = peerIp,
  }) {
    return FavoriteDevice.fromValues(
      fingerprint: 'FP1',
      ip: ip,
      port: 53317,
      alias: 'Peer',
    ).copyWith(trustLevel: trustLevel, blocked: blocked, ownerId: ownerId);
  }

  test('unknown device is asked (confirm)', () {
    expect(
      evaluateScreenOffer(entry: null, localOwnerId: localOwner, peerIp: peerIp),
      ScreenOfferDecision.confirm,
    );
  });

  test('blocked wins over everything', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.full, blocked: true, ownerId: localOwner),
        localOwnerId: localOwner,
        peerIp: peerIp,
      ),
      ScreenOfferDecision.rejectBlocked,
    );
  });

  test('same owner from the stored address is accepted without prompt', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.temp, ownerId: localOwner),
        localOwnerId: localOwner,
        peerIp: peerIp,
      ),
      ScreenOfferDecision.autoAccept,
    );
  });

  test('same owner from a different address is downgraded to confirm', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.temp, ownerId: localOwner),
        localOwnerId: localOwner,
        peerIp: '10.0.0.77',
      ),
      ScreenOfferDecision.confirm,
    );
  });

  test('temp trust is rejected (D2)', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.temp),
        localOwnerId: localOwner,
        peerIp: peerIp,
      ),
      ScreenOfferDecision.rejectTemp,
    );
  });

  test('limited trust is asked', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.limited),
        localOwnerId: localOwner,
        peerIp: peerIp,
      ),
      ScreenOfferDecision.confirm,
    );
  });

  test('full trust from the stored address is accepted without prompt', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.full),
        localOwnerId: localOwner,
        peerIp: peerIp,
      ),
      ScreenOfferDecision.autoAccept,
    );
  });

  test('full trust from a different address is downgraded to confirm', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.full),
        localOwnerId: localOwner,
        peerIp: '192.168.1.99',
      ),
      ScreenOfferDecision.confirm,
    );
  });

  test('empty owner ids never match', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.limited, ownerId: ''),
        localOwnerId: '',
        peerIp: peerIp,
      ),
      ScreenOfferDecision.confirm,
    );
  });

  test('empty stored address is never trusted for auto-accept', () {
    expect(
      evaluateScreenOffer(
        entry: device(trustLevel: TrustLevel.full, ip: ''),
        localOwnerId: localOwner,
        peerIp: '',
      ),
      ScreenOfferDecision.confirm,
    );
  });
}
