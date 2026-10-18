import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/screen_capabilities.dart';
import 'package:localsend_isolates/model/device.dart';

Device _device({String? ip, List<DeviceChannel> channels = const []}) {
  return Device(
    signalingId: null,
    ip: ip,
    version: '2.2',
    port: 53317,
    https: true,
    fingerprint: 'FP',
    alias: 'Peer',
    deviceModel: null,
    deviceType: DeviceType.desktop,
    download: false,
    channels: channels,
  );
}

void main() {
  test('screenShareHostOf prefers an IPv4 channel over an IPv6 ip', () {
    final device = _device(
      ip: 'fe80::1%3',
      channels: [
        HttpChannel(host: 'fe80::1%3', port: 53317, https: true),
        HttpChannel(host: '192.168.1.180', port: 53317, https: true),
      ],
    );
    expect(screenShareHostOf(device), '192.168.1.180');
  });

  test('screenShareHostOf falls back to an IPv4 ip', () {
    expect(screenShareHostOf(_device(ip: '192.168.1.10')), '192.168.1.10');
  });

  test('screenShareHostOf returns null when only IPv6 is available', () {
    expect(screenShareHostOf(_device(ip: 'fe80::1%3')), isNull);
    expect(
      screenShareHostOf(_device(ip: null, channels: [HttpChannel(host: 'fe80::2%4', port: 53317, https: true)])),
      isNull,
    );
  });
}
