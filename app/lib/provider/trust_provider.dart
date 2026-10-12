import 'dart:async';
import 'dart:io';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/trust_evaluator.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-12): trust-model glue.
/// Decision chain: docs/扩展协议设计.md §3.2; limits: PRD F-PAIR-10~12.

/// Received bytes per sender fingerprint.
///
/// Backed by its own persisted ledger (`ls_trust_usage`) instead of the
/// receive history, because the history window rotates at only
/// [_maxHistoryEntries] entries — quota sums over it would silently reset.
/// "Deleting history releases quota" (PRD F-PAIR-12) is therefore replaced by
/// an explicit per-device reset in the device detail page (Stage 2-B).
final trustUsageProvider = ReduxProvider<TrustUsageService, Map<String, int>>((ref) {
  return TrustUsageService(ref.read(persistenceProvider));
});

class TrustUsageService extends ReduxNotifier<Map<String, int>> {
  final PersistenceService _persistence;

  TrustUsageService(this._persistence);

  @override
  Map<String, int> init() => _persistence.getTrustUsage();
}

/// Adds [bytes] to the usage of [fingerprint] (called when a file is saved).
class IncrementTrustUsageAction extends ReduxAction<TrustUsageService, Map<String, int>> {
  final String fingerprint;
  final int bytes;

  IncrementTrustUsageAction({required this.fingerprint, required this.bytes});

  @override
  Map<String, int> reduce() {
    if (fingerprint.isEmpty || bytes <= 0) {
      return state;
    }
    final updated = Map<String, int>.of(state);
    updated[fingerprint] = (updated[fingerprint] ?? 0) + bytes;
    // ignore: discarded_futures
    notifier._persistence.setTrustUsage(updated);
    return updated;
  }
}

/// Resets usage for one device (or all devices when fingerprint is null).
class ResetTrustUsageAction extends ReduxAction<TrustUsageService, Map<String, int>> {
  final String? fingerprint;

  ResetTrustUsageAction({this.fingerprint});

  @override
  Map<String, int> reduce() {
    final updated = Map<String, int>.of(state);
    if (fingerprint == null) {
      updated.clear();
    } else {
      updated.remove(fingerprint);
    }
    // ignore: discarded_futures
    notifier._persistence.setTrustUsage(updated);
    return updated;
  }
}

final _volumeCache = <String, (int, DateTime)>{};

/// Runs the trust decision chain for an incoming session.
Future<TrustDecision> decideTrust({
  required Map<String, int> usage,
  required FavoriteDevice? entry,
  required Iterable<int> fileSizes,
  required String destinationDir,
}) async {
  final int sessionTotal = fileSizes.fold(0, (a, b) => a + b);
  final int? volumeTotal = entry != null && entry.quotaMode == QuotaMode.percent ? await getVolumeTotalBytes(destinationDir) : null;
  return TrustEvaluator.evaluate(
    entry: entry,
    sessionTotalBytes: sessionTotal,
    fileSizes: fileSizes.toList(),
    receivedBytesFromSender: entry == null ? 0 : (usage[entry.fingerprint] ?? 0),
    destinationVolumeTotalBytes: volumeTotal,
  );
}

/// Total size (bytes) of the volume containing [dirPath], cached for 10
/// minutes per volume. Returns null when the platform query fails or times
/// out (the prepare-upload path awaits this).
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
    final Future<ProcessResult> job = switch (os) {
      'windows' => Process.run(
        'powershell',
        ['-NoProfile', '-Command', "(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$key:'\").Size"],
      ),
      _ => Process.run('df', ['-k', dirPath]),
    };
    final ProcessResult result = await job.timeout(const Duration(seconds: 8));
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
  } on TimeoutException {
    return null;
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
