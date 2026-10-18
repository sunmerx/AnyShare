import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/dir_access.dart';

void main() {
  FavoriteDevice fav({TrustLevel trust = TrustLevel.full, bool blocked = false, String ip = '10.0.0.5', String ownerId = ''}) {
    return FavoriteDevice.fromValues(fingerprint: 'FP1', ip: ip, port: 53317, alias: 'Peer').copyWith(
      trustLevel: trust,
      blocked: blocked,
      ownerId: ownerId,
    );
  }

  DirAccessResult eval({
    FavoriteDevice? entry,
    String ip = '10.0.0.5',
    String ownerId = '',
    bool writable = false,
    bool grant = false,
  }) {
    return evaluateDirAccess(
      entry: entry,
      requesterIp: ip,
      myOwnerId: 'me',
      writable: writable,
      writeGranted: grant,
    );
  }

  test('unknown devices are rejected', () {
    expect(eval(entry: null).access, DirAccess.none);
    expect(eval(entry: null).reason, 'unknown');
  });

  test('address mismatch is rejected (fail-closed for empty stored ip)', () {
    final r = eval(entry: fav(), ip: '10.0.0.99');
    expect(r.access, DirAccess.none);
    expect(r.reason, 'ip_mismatch');

    final empty = eval(entry: fav(ip: ''));
    expect(empty.access, DirAccess.none);
    expect(empty.reason, 'ip_mismatch');
  });

  test('blocked and temp are rejected', () {
    expect(eval(entry: fav(blocked: true)).reason, 'blocked');
    expect(eval(entry: fav(trust: TrustLevel.temp)).reason, 'temp_not_allowed');
  });

  test('limited devices are read-only even on writable directories', () {
    expect(eval(entry: fav(trust: TrustLevel.limited), writable: true, grant: true).access, DirAccess.readOnly);
  });

  test('full trust needs a write grant', () {
    expect(eval(entry: fav(), writable: true).access, DirAccess.readOnly);
    expect(eval(entry: fav(), writable: true, grant: true).access, DirAccess.readWrite);
  });

  test('same-owner devices write writable directories without a grant', () {
    expect(eval(entry: fav(ownerId: 'me'), writable: true).access, DirAccess.readWrite);
    expect(eval(entry: fav(ownerId: 'me'), writable: false).access, DirAccess.readOnly);
  });

  test('same-owner temp is allowed (owner rule precedes temp)', () {
    expect(eval(entry: fav(trust: TrustLevel.temp, ownerId: 'me'), writable: false).access, DirAccess.readOnly);
  });

  test('read-only directories never grant write', () {
    expect(eval(entry: fav(ownerId: 'me'), writable: false, grant: true).access, DirAccess.readOnly);
  });
}
