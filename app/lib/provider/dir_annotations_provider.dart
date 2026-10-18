import 'package:localsend_app/model/persistence/dir_annotation.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): local tags/notes for shared-directory
/// entries (F-DIR-07). Stored per browsing device + root + path; never
/// uploaded or synced.

final dirAnnotationsProvider = ReduxProvider<DirAnnotationsService, Map<String, DirAnnotation>>((ref) {
  return DirAnnotationsService(ref.read(persistenceProvider));
});

class DirAnnotationsService extends ReduxNotifier<Map<String, DirAnnotation>> {
  final PersistenceService _persistence;

  DirAnnotationsService(this._persistence);

  @override
  Map<String, DirAnnotation> init() => _persistence.getDirAnnotations();
}

class SetDirAnnotationAction extends AsyncReduxAction<DirAnnotationsService, Map<String, DirAnnotation>> {
  final String key;
  final DirAnnotation annotation;

  SetDirAnnotationAction({required this.key, required this.annotation});

  @override
  Future<Map<String, DirAnnotation>> reduce() async {
    final updated = {...state};
    if (annotation.isEmpty) {
      updated.remove(key);
    } else {
      updated[key] = annotation;
    }
    final frozen = Map<String, DirAnnotation>.unmodifiable(updated);
    await notifier._persistence.setDirAnnotations(frozen);
    return frozen;
  }
}
