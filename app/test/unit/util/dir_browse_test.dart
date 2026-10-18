import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/util/dir_browse.dart';

void main() {
  test('sortDirEntries puts directories first, case-insensitive', () {
    final entries = [
      const DirEntry(name: 'b.txt', isDir: false, isLink: false),
      const DirEntry(name: 'Zeta', isDir: true, isLink: false),
      const DirEntry(name: 'alpha', isDir: true, isLink: false),
      const DirEntry(name: 'A.txt', isDir: false, isLink: false),
    ];
    final sorted = sortDirEntries(entries);
    expect(sorted.map((e) => e.name), ['alpha', 'Zeta', 'A.txt', 'b.txt']);
  });

  test('parentDirPath and joinDirPath', () {
    expect(parentDirPath(''), '');
    expect(parentDirPath('a'), '');
    expect(parentDirPath('a/b'), 'a');
    expect(parentDirPath('a/b/c'), 'a/b');
    expect(joinDirPath('', 'x'), 'x');
    expect(joinDirPath('a', 'x'), 'a/x');
  });

  test('formatDirSize', () {
    expect(formatDirSize(0), '0 B');
    expect(formatDirSize(1023), '1023 B');
    expect(formatDirSize(1024), '1.0 KB');
    expect(formatDirSize(1536), '1.5 KB');
    expect(formatDirSize(10 * 1024 * 1024), '10.0 MB');
    expect(formatDirSize(200 * 1024 * 1024), '200 MB');
    expect(formatDirSize(2 * 1024 * 1024 * 1024), '2.0 GB');
    expect(formatDirSize(-1), '');
  });
}
