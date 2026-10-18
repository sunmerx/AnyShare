import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/dir_annotation.dart';
import 'package:localsend_app/provider/dir_annotations_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late RefenaContainer container;

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData({});
    container = RefenaContainer();
    final prefs = await SharedPreferences.getInstance();
    await container.set(persistenceProvider.overrideWithValue(PersistenceService.test(prefs)));
  });

  test('annotation codec roundtrip and key format', () {
    final key = DirAnnotation.key(fingerprint: 'FP1', rootId: 'root1', path: 'a/b.txt');
    expect(key, 'FP1:root1:a/b.txt');

    final map = {
      key: const DirAnnotation(tags: ['重要', '待打印'], note: '打印三份'),
      'FP1:root1:empty': const DirAnnotation(),
    };
    final decoded = DirAnnotation.decodeMap(DirAnnotation.encodeMap(map));
    expect(decoded[key]!.tags, ['重要', '待打印']);
    expect(decoded[key]!.note, '打印三份');
    expect(decoded['FP1:root1:empty']!.isEmpty, isTrue);
    expect(DirAnnotation.decodeMap('not json at all'), isEmpty);
  });

  test('set and remove persist through the provider', () async {
    final key = DirAnnotation.key(fingerprint: 'FP1', rootId: 'root1', path: 'x.txt');
    await container.redux(dirAnnotationsProvider).dispatchAsync(
          SetDirAnnotationAction(key: key, annotation: const DirAnnotation(tags: ['t'], note: 'n')),
        );
    expect(container.read(dirAnnotationsProvider)[key]!.note, 'n');

    // An empty annotation removes the entry.
    await container.redux(dirAnnotationsProvider).dispatchAsync(
          SetDirAnnotationAction(key: key, annotation: const DirAnnotation()),
        );
    expect(container.read(dirAnnotationsProvider).containsKey(key), isFalse);

    // Persisted form survives a fresh service instance.
    await container.redux(dirAnnotationsProvider).dispatchAsync(
          SetDirAnnotationAction(key: key, annotation: const DirAnnotation(note: 'kept')),
        );
    final prefs = await SharedPreferences.getInstance();
    final reloaded = PersistenceService.test(prefs).getDirAnnotations();
    expect(reloaded[key]!.note, 'kept');
  });

  test('corrupt persisted data degrades gracefully', () async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.withData({
      'flutter.ls_dir_annotations': '{"broken": 42, "ok": {"tags": ["a"], "note": ""}}',
    });
    final prefs = await SharedPreferences.getInstance();
    final annotations = PersistenceService.test(prefs).getDirAnnotations();
    expect(annotations.keys, ['ok']);
    expect(annotations['ok']!.tags, ['a']);
  });
}
