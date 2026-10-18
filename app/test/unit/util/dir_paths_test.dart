import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/dir_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('anyshare_dir_test');
  });

  tearDown(() {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  test('resolves a path inside the root', () async {
    File(p.join(tmp.path, 'a.txt')).writeAsStringSync('x');
    final result = await resolveDirPath(tmp.path, 'a.txt');
    expect(result.error, isNull);
    expect(result.absolute, p.normalize(p.join(tmp.path, 'a.txt')));
  });

  test('resolves nested non-existing paths for creation', () async {
    final result = await resolveDirPath(tmp.path, 'new/dir/file.txt');
    expect(result.error, isNull);
  });

  test('rejects traversal and absolute paths', () async {
    expect((await resolveDirPath(tmp.path, '..')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, '../outside.txt')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, 'a/../../outside')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, '/etc/passwd')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, r'C:\Windows')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, 'a\\..\\..\\b')).error, 'invalid_path');
  });

  test('allows the root itself', () async {
    final result = await resolveDirPath(tmp.path, '');
    expect(result.error, isNull);
  });

  test('rejects symlink escapes', () async {
    final outside = Directory.systemTemp.createTempSync('anyshare_outside');
    try {
      final link = Link(p.join(tmp.path, 'escape'));
      try {
        link.createSync(outside.path);
      } on FileSystemException {
        // Windows without developer mode cannot create symlinks: skip.
        return;
      }
      final result = await resolveDirPath(tmp.path, 'escape/secret.txt');
      expect(result.error, 'invalid_path');
    } finally {
      outside.deleteSync(recursive: true);
    }
  });

  test('rejects internal .anyshare_ segments', () async {
    expect((await resolveDirPath(tmp.path, '.anyshare_trash')).error, 'invalid_path');
    expect((await resolveDirPath(tmp.path, 'sub/.anyshare_tmp_x')).error, 'invalid_path');
  });

  test('entry name validation', () {
    expect(isValidDirEntryName('photo.jpg'), isTrue);
    expect(isValidDirEntryName('my dir'), isTrue);
    expect(isValidDirEntryName(''), isFalse);
    expect(isValidDirEntryName('.'), isFalse);
    expect(isValidDirEntryName('..'), isFalse);
    expect(isValidDirEntryName('a/b'), isFalse);
    expect(isValidDirEntryName(r'a\b'), isFalse);
    expect(isValidDirEntryName('.anyshare_trash'), isFalse);
    expect(isValidDirEntryName('.anyshare_tmp_x'), isFalse);
    expect(isValidDirEntryName('name:stream'), isFalse);
    expect(isValidDirEntryName('a<b>c'), isFalse);
    expect(isValidDirEntryName('trailing.'), isFalse);
    expect(isValidDirEntryName('trailing '), isFalse);
    expect(isValidDirEntryName('CON'), isFalse);
    expect(isValidDirEntryName('con.txt'), isFalse);
    expect(isValidDirEntryName('COM1'), isFalse);
    expect(isValidDirEntryName('LPT9.log'), isFalse);
    expect(isValidDirEntryName('CONSOLE'), isTrue);
  });
}
