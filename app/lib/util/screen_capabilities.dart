import 'dart:io';

/// AnyShare modification (2026-10-18): E2.0 screen-share platform capability
/// (UI-2). Windows sends its screen; desktop Linux receives it.
bool canSendScreenShare() => Platform.isWindows;

bool canReceiveScreenShare() => Platform.isLinux;
