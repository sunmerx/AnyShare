import 'package:localsend_app/model/persistence/shared_dir_config.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): E-3 host-side shared directory config
/// (F-DIR-01) and per-device write grants (F-DIR-08).
final sharedDirsProvider = ReduxProvider<SharedDirsService, List<SharedDirConfig>>((ref) {
  return SharedDirsService(ref.read(persistenceProvider));
});

class SharedDirsService extends ReduxNotifier<List<SharedDirConfig>> {
  final PersistenceService _persistence;

  SharedDirsService(this._persistence);

  @override
  List<SharedDirConfig> init() => _persistence.getSharedDirs();
}

class AddSharedDirAction extends AsyncReduxAction<SharedDirsService, List<SharedDirConfig>> {
  final SharedDirConfig config;

  AddSharedDirAction(this.config);

  @override
  Future<List<SharedDirConfig>> reduce() async {
    final updated = List<SharedDirConfig>.unmodifiable([...state, config]);
    await notifier._persistence.setSharedDirs(updated);
    return updated;
  }
}

class UpdateSharedDirAction extends AsyncReduxAction<SharedDirsService, List<SharedDirConfig>> {
  final SharedDirConfig config;

  UpdateSharedDirAction(this.config);

  @override
  Future<List<SharedDirConfig>> reduce() async {
    final updated = List<SharedDirConfig>.unmodifiable([
      for (final entry in state) entry.id == config.id ? config : entry,
    ]);
    await notifier._persistence.setSharedDirs(updated);
    return updated;
  }
}

class RemoveSharedDirAction extends AsyncReduxAction<SharedDirsService, List<SharedDirConfig>> {
  final String id;

  RemoveSharedDirAction(this.id);

  @override
  Future<List<SharedDirConfig>> reduce() async {
    final updated = List<SharedDirConfig>.unmodifiable(state.where((entry) => entry.id != id));
    await notifier._persistence.setSharedDirs(updated);
    return updated;
  }
}

/// Fingerprints granted write access by the local user (only meaningful for
/// `full`-trust devices; same-owner devices do not need a grant).
final dirWriteGrantsProvider = ReduxProvider<DirWriteGrantsService, Set<String>>((ref) {
  return DirWriteGrantsService(ref.read(persistenceProvider));
});

class DirWriteGrantsService extends ReduxNotifier<Set<String>> {
  final PersistenceService _persistence;

  DirWriteGrantsService(this._persistence);

  @override
  Set<String> init() => _persistence.getDirWriteGrants();
}

class SetDirWriteGrantAction extends AsyncReduxAction<DirWriteGrantsService, Set<String>> {
  final String fingerprint;
  final bool granted;

  SetDirWriteGrantAction({required this.fingerprint, required this.granted});

  @override
  Future<Set<String>> reduce() async {
    final updated = {...state};
    if (granted) {
      updated.add(fingerprint);
    } else {
      updated.remove(fingerprint);
    }
    await notifier._persistence.setDirWriteGrants(updated);
    return updated;
  }
}
