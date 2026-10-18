import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/pages/send_page.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/dialogs/address_input_dialog.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-18): shared send flow for the redesigned
/// home (UI-1). Migrated from the former send tab / send tab VM.

final pickerOptions = FilePickerOption.getOptionsForPlatform();

/// Sends to [device] honoring the current send mode (single vs multiple).
Future<void> sendToDeviceAuto(BuildContext context, Ref ref, Device device) async {
  final mode = ref.read(settingsProvider).sendMode;
  if (mode == SendMode.multiple) {
    await sendToDeviceMulti(context, ref, device);
  } else {
    await sendToDevice(context, ref, device);
  }
}

/// Sends the currently selected files to [device]; opens the file picker when
/// nothing is selected yet.
Future<void> sendToDevice(BuildContext context, Ref ref, Device device) async {
  var files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty) {
    await AddFileDialog.open(context: context, options: pickerOptions);
    files = ref.read(selectedSendingFilesProvider);
  }
  if (files.isEmpty) {
    return;
  }
  await ref.notifier(sendProvider).startSession(target: device, files: files, background: false);
}

/// Multi-send mode variant: reuses/refreshes a background session per device.
Future<void> sendToDeviceMulti(BuildContext context, Ref ref, Device device) async {
  final session = ref.read(sendProvider).values.firstWhereOrNull((s) => s.target.ip == device.ip);
  if (session != null) {
    ref.notifier(sendProvider).setBackground(session.sessionId, false);
    if (!context.mounted) {
      return;
    }
    await context.push(
      () => SendPage(showAppBar: true, closeSessionOnClose: false, sessionId: session.sessionId),
      transition: RouterinoTransition.fade(),
    );
    if (ref.read(sendProvider)[session.sessionId]?.status == SessionStatus.waiting) {
      ref.notifier(sendProvider).setBackground(session.sessionId, true);
    }
    return;
  }

  var files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty) {
    await AddFileDialog.open(context: context, options: pickerOptions);
    files = ref.read(selectedSendingFilesProvider);
  }
  if (files.isEmpty) {
    return;
  }
  await ref.notifier(sendProvider).startSession(target: device, files: files, background: true);
}

/// Manual address entry (F-DISC-06 fallback): ask for address, then send.
Future<void> sendViaAddressDialog(BuildContext context, Ref ref) async {
  var files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty) {
    await AddFileDialog.open(context: context, options: pickerOptions);
  }
  files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty || !context.mounted) {
    return;
  }
  final device = await showDialog<Device?>(context: context, builder: (_) => const AddressInputDialog());
  if (device != null && context.mounted) {
    await ref.notifier(sendProvider).startSession(target: device, files: files, background: false);
  }
}

/// Link (web share) mode entry.
Future<void> startWebShare(BuildContext context, Ref ref) async {
  var files = ref.read(selectedSendingFilesProvider);
  if (files.isEmpty) {
    await AddFileDialog.open(context: context, options: pickerOptions);
    files = ref.read(selectedSendingFilesProvider);
  }
  if (files.isEmpty || !context.mounted) {
    return;
  }
  await context.push(() => WebSharePage(files: files));
}

Future<void> setSendMode(Ref ref, SendMode mode) async {
  await ref.notifier(settingsProvider).setSendMode(mode);
  if (mode != SendMode.multiple) {
    ref.notifier(sendProvider).clearAllSessions();
  }
}

/// Whether [entry] is reachable right now: a discovered device matches it.
Device? findDiscovered(Iterable<Device> discovered, FavoriteDevice entry) {
  return discovered.firstWhereOrNull((d) => d.fingerprint == entry.fingerprint);
}

/// Multi-send mode: live info/progress of the session targeting [device].
/// Callers must watch [sendProvider] and [fileTransferProvider] for rebuilds.
(String?, double?) sessionStatusFor(Ref ref, Device device) {
  final session = ref.read(sendProvider).values.firstWhereOrNull((s) => s.target.ip == device.ip);
  if (session == null) {
    return (null, null);
  }
  final files = session.files.values.where((f) => f.token != null);
  final transferNotifier = ref.read(fileTransferProvider);
  final currBytes = files.fold<int>(
    0,
    (prev, curr) => prev + ((transferNotifier.getProgress(sessionId: session.sessionId, fileId: curr.file.id) * curr.file.size).round()),
  );
  final totalBytes = files.fold<int>(0, (prev, curr) => prev + curr.file.size);
  final progress = totalBytes == 0 ? 0.0 : currBytes / totalBytes;
  final info = session.hashedFileCount < session.files.length
      ? t.sendPage.calculatingChecksum(curr: session.hashedFileCount, n: session.files.length)
      : session.status.humanString;
  return (info, progress);
}

extension SessionStatusHuman on SessionStatus {
  String? get humanString {
    switch (this) {
      case SessionStatus.waiting:
        return t.sendPage.waiting;
      case SessionStatus.recipientBusy:
        return t.sendPage.busy;
      case SessionStatus.declined:
        return t.sendPage.rejected;
      case SessionStatus.tooManyAttempts:
        return t.sendPage.tooManyAttempts;
      case SessionStatus.sending:
        return null;
      case SessionStatus.finished:
        return t.general.finished;
      case SessionStatus.finishedWithErrors:
        return t.progressPage.total.title.finishedError;
      case SessionStatus.canceledBySender:
        return t.progressPage.total.title.canceledSender;
      case SessionStatus.canceledByReceiver:
        return t.progressPage.total.title.canceledReceiver;
    }
  }
}
