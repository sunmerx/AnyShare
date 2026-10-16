import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:logging/logging.dart';

final _logger = Logger('TransferCompleteNotification');

/// AnyShare modification (2026-10-15): system-level "transfer complete"
/// notification (PRD F-INT-R3).
///
/// Shown when a transfer session ends, on Android via [MainActivity] and on the
/// desktop via the `local_notifier` plugin. Tapping the notification brings the
/// app back to the foreground and opens the destination folder.
class TransferCompleteNotification {
  TransferCompleteNotification._();

  static bool _initialized = false;

  /// Sets up the platform notification facilities. Call once during `preInit`.
  static Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    if (checkPlatformIsDesktop()) {
      try {
        await LocalNotifier.instance.setup(appName: t.appName);
      } catch (e) {
        _logger.warning('Initializing notifications failed', e);
      }
    } else if (checkPlatform([TargetPlatform.android])) {
      android_channel.setTransferCompleteNotificationTapHandler(_onAndroidTap);
      // Replays a tap that arrived while the app was starting.
      await android_channel.flushPendingTransferCompleteTaps();
    }
  }

  /// The number of finished and failed files of a transfer session.
  /// Queued and skipped files are not part of either count.
  static ({int completed, int failed}) summarize(Iterable<FileStatus> statuses) {
    var completed = 0;
    var failed = 0;
    for (final status in statuses) {
      if (status == FileStatus.finished) {
        completed++;
      } else if (status == FileStatus.failed) {
        failed++;
      }
    }
    return (completed: completed, failed: failed);
  }

  /// Shows the completion notification. A tap opens [folderPath] and selects
  /// [fileName] inside it where the platform supports it.
  static Future<void> show({
    required String title,
    required String body,
    String? folderPath,
    String? fileName,
  }) async {
    if (checkPlatformIsDesktop()) {
      try {
        final notification = LocalNotification(title: title, body: body);
        notification.onClick = () {
          unawaited(_openDestination(folderPath: folderPath, fileName: fileName));
        };
        await notification.show();
      } catch (e) {
        _logger.warning('Showing the completion notification failed', e);
      }
    } else if (checkPlatform([TargetPlatform.android])) {
      try {
        await android_channel.showTransferCompleteNotification(
          title: title,
          body: body,
          channelName: t.settingsTab.receive.transferCompleteNotification,
          folderPath: folderPath,
          fileName: fileName,
        );
      } catch (e) {
        _logger.warning('Showing the completion notification failed', e);
      }
    }
  }

  /// Brings the app back to the foreground and opens the destination.
  static Future<void> _openDestination({required String? folderPath, required String? fileName}) async {
    if (checkPlatformIsDesktop()) {
      try {
        await showFromTray();
      } catch (e) {
        _logger.warning('Showing the app from the notification failed', e);
      }
    }

    final folder = folderPath;
    if (folder == null || folder.isEmpty) {
      return;
    }

    try {
      await openFolder(folderPath: folder, fileName: fileName);
    } catch (e) {
      _logger.warning('Opening the destination folder failed', e);
    }
  }

  static void _onAndroidTap(String? folderPath, String? fileName) {
    unawaited(_openDestination(folderPath: folderPath, fileName: fileName));
  }
}
