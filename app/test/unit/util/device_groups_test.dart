import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/util/device_groups.dart';
import 'package:localsend_app/util/send_flow.dart';
import 'package:localsend_isolates/model/device.dart';

void main() {
  Device dev({required String fingerprint, String ip = '10.0.0.1', int port = 53317}) {
    return Device(
      signalingId: null,
      ip: ip,
      version: '2.2',
      port: port,
      https: false,
      fingerprint: fingerprint,
      alias: 'D-$fingerprint',
      deviceModel: 'Model',
      deviceType: DeviceType.desktop,
      download: false,
      channels: const [],
    );
  }

  FavoriteDevice fav({
    required String fingerprint,
    String ownerId = '',
    bool blocked = false,
  }) {
    return FavoriteDevice.fromValues(
      fingerprint: fingerprint,
      ip: '10.0.0.1',
      port: 53317,
      alias: 'F-$fingerprint',
    ).copyWith(ownerId: ownerId, blocked: blocked);
  }

  test('same-owner favorites go to myDevices', () {
    final groups = groupDevices(
      discovered: const [],
      favorites: [
        fav(fingerprint: 'A', ownerId: 'me'),
        fav(fingerprint: 'B', ownerId: 'other'),
      ],
      myOwnerId: 'me',
    );
    expect(groups.myDevices.map((f) => f.fingerprint), ['A']);
    expect(groups.paired.map((f) => f.fingerprint), ['B']);
  });

  test('blocked entries only appear in the blocklist', () {
    final groups = groupDevices(
      discovered: [dev(fingerprint: 'A')],
      favorites: [fav(fingerprint: 'A', ownerId: 'me', blocked: true)],
      myOwnerId: 'me',
    );
    expect(groups.blocked.map((f) => f.fingerprint), ['A']);
    expect(groups.myDevices, isEmpty);
    expect(groups.paired, isEmpty);
    expect(groups.nearby, isEmpty, reason: 'blocked devices never show up as nearby');
  });

  test('unpaired discovered devices are nearby, paired ones are not', () {
    final groups = groupDevices(
      discovered: [
        dev(fingerprint: 'A'),
        dev(fingerprint: 'B'),
      ],
      favorites: [fav(fingerprint: 'B')],
      myOwnerId: 'me',
    );
    expect(groups.nearby.map((d) => d.fingerprint), ['A']);
  });

  test('empty owner ids never match', () {
    final groups = groupDevices(
      discovered: const [],
      favorites: [fav(fingerprint: 'A')],
      myOwnerId: '',
    );
    expect(groups.myDevices, isEmpty);
    expect(groups.paired.map((f) => f.fingerprint), ['A']);
  });

  test('discovered same-owner favorite stays out of nearby', () {
    final groups = groupDevices(
      discovered: [dev(fingerprint: 'A')],
      favorites: [fav(fingerprint: 'A', ownerId: 'me')],
      myOwnerId: 'me',
    );
    expect(groups.myDevices.map((f) => f.fingerprint), ['A']);
    expect(groups.nearby, isEmpty);
  });

  test('findDiscovered matches by fingerprint', () {
    expect(findDiscovered([dev(fingerprint: 'A'), dev(fingerprint: 'B')], fav(fingerprint: 'B'))?.fingerprint, 'B');
    expect(findDiscovered([dev(fingerprint: 'A')], fav(fingerprint: 'B')), isNull);
  });
}
