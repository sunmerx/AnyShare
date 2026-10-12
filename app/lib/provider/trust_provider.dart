import 'dart:io';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/util/trust_evaluator.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-12): trust-model glue.
/// Decision chain: docs/扩展协议设计.md §3.2; limits: PRD F-PAIR-10~12.

/// Received bytes per sender fingerprint, derived from the receive history
/// (deleting history therefore releases quota).
final trustUsageProvider = ViewProvider<Map<String, int>>((ref) {
  final Map<String, int> usage = {};
  for (final entry in ref.watch(receiveHistoryProvider)) {
    final String? fingerprint = entry.senderFingerprint;
    if (fingerprint != null && fingerprint.isNotEmpty) {
      usage[fingerprint] = (usage[fingerprint] ?? 0) + entry.fileSize;
    }
  }
  return usage;
});

final _volumeCache = <String, (int, DateTime)>{};

/// Total size (bytes) of the volume containing [dirPath], cached for 10
/// minutes per volume. Returns null when the platform query fails.
Future<int?> getVolumeTotalBytes(String dirPath) async {
  final String key = switch (Platform.operatingSystem) {
    'windows' => dirPath.substring(0, 1).toUpperCase(),
    _ => '/',
  };
  final (int bytes, DateTime at) = _volumeCache[key] ?? (0, DateTime.fromMillisecondsSinceEpoch(0));
  if (DateTime.now().difference(at) < const Duration(minutes: 10)) {
    return bytes;
  }

  try {
    final String os = Platform.operatingSystem;
    if (os != 'windows' && os != 'macos' && os != 'linux') {
      return null;
    }
    final ProcessResult result = switch (os) {
      'windows' => await Process.run(
          'powershell',
          ['-NoProfile', '-Command', "(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$key:'\").Size"],
        ),
      _ => await Process.run('df', ['-k', dirPath]),
    };
    if (result.exitCode != 0) {
      return null;
    }
    final int? total = switch (os) {
      'windows' => int.tryParse((result.stdout as String).trim()),
      _ => _dfTotal(result.stdout as String, dirPath),
    };
    if (total != null && total > 0) {
      _volumeCache[key] = (total, DateTime.now());
    }
    return total;
  } catch (_) {
    return null;
  }
}

/// `df -k <path>` output: total size is the 2nd column of the line containing
/// the path (values in KiB).
int? _dfTotal(String stdout, String dirPath) {
  for (final line in stdout.split('\n')) {
    if (line.contains(dirPath)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final kib = int.tryParse(parts[1]);
        if (kib != null) {
          return kib * 1024;
        }
      }
    }
  }
  return null;
}

/// Runs the trust decision chain for an incoming session.
Future<TrustDecision> decideTrust({
  required Ref ref,
  required FavoriteDevice? entry,
  required Iterable<int> fileSizes,
  required String destinationDir,
}) async {
  final int sessionTotal = fileSizes.fold(0, (a, b) => a + b);
  final String fingerprint = entry?.fingerprint ?? '';
  final Map<String, int> usage = ref.read(trustUsageProvider);
  final int? volumeTotal = entry != null && entry.quotaMode == QuotaMode.percent ? await getVolumeTotalBytes(destinationDir) : null;
  return TrustEvaluator.evaluate(
    entry: entry,
    sessionTotalBytes: sessionTotal,
    fileSizes: fileSizes.toList(),
    receivedBytesFromSender: usage[fingerprint] ?? 0,
    destinationVolumeTotalBytes: volumeTotal,
  );
}
