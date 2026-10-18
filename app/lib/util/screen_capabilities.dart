import 'dart:io';

import 'package:localsend_isolates/model/device.dart';

/// AnyShare modification (2026-10-18): E2.0 screen-share platform capability
/// (UI-2). Windows sends its screen; desktop Linux receives it.
bool canSendScreenShare() => Platform.isWindows;

bool canReceiveScreenShare() => Platform.isLinux;

/// IPv4 host for screen share control/data (the E2.0 engine is IPv4-only).
/// Prefers an IPv4 HTTP channel (devices often announce an IPv6 primary
/// address); falls back to [Device.ip] when that is IPv4. Null when the
/// device has no IPv4 address at all.
String? screenShareHostOf(Device device) {
  for (final channel in device.channels.whereType<HttpChannel>()) {
    if (channel.host.isNotEmpty && !channel.host.contains(':')) {
      return channel.host;
    }
  }
  final ip = device.ip;
  if (ip != null && ip.isNotEmpty && !ip.contains(':')) {
    return ip;
  }
  return null;
}
