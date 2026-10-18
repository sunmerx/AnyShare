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

  test('sortDirEntriesBy: size, modified, direction and name tiebreak', () {
    final entries = [
      const DirEntry(name: 'big', isDir: false, isLink: false, size: 100, modified: 1),
      const DirEntry(name: 'small', isDir: false, isLink: false, size: 10, modified: 3),
      const DirEntry(name: 'mid', isDir: false, isLink: false, size: 50, modified: 2),
      const DirEntry(name: 'zzz', isDir: true, isLink: false, size: 999, modified: 9),
      const DirEntry(name: 'aaa', isDir: true, isLink: false, size: 1, modified: 0),
    ];
    expect(
      sortDirEntriesBy(entries, by: DirSortBy.size, ascending: true).map((e) => e.name),
      ['aaa', 'zzz', 'small', 'mid', 'big'],
    );
    expect(
      sortDirEntriesBy(entries, by: DirSortBy.size, ascending: false).map((e) => e.name),
      ['zzz', 'aaa', 'big', 'mid', 'small'],
    );
    expect(
      sortDirEntriesBy(entries, by: DirSortBy.modified, ascending: false).map((e) => e.name),
      ['zzz', 'aaa', 'small', 'mid', 'big'],
    );
    // Missing size/modified sorts as 0; name breaks the tie.
    final ties = [
      const DirEntry(name: 'b', isDir: false, isLink: false),
      const DirEntry(name: 'a', isDir: false, isLink: false),
    ];
    expect(sortDirEntriesBy(ties, by: DirSortBy.size, ascending: true).map((e) => e.name), ['a', 'b']);
  });

  test('filterDirEntries: query and tags', () {
    final entries = [
      const DirEntry(name: 'Report.PDF', isDir: false, isLink: false),
      const DirEntry(name: 'notes.txt', isDir: false, isLink: false),
      const DirEntry(name: 'photos', isDir: true, isLink: false),
    ];
    final tags = {
      'Report.PDF': ['重要'],
      'notes.txt': ['草稿', '重要'],
    };
    expect(
      filterDirEntries(entries, query: 'port', tagFilter: const {}, tagsByName: tags).map((e) => e.name),
      ['Report.PDF'],
    );
    expect(
      filterDirEntries(entries, query: '', tagFilter: const {'重要'}, tagsByName: tags).map((e) => e.name),
      ['Report.PDF', 'notes.txt'],
    );
    expect(
      filterDirEntries(entries, query: 'o', tagFilter: const {'草稿'}, tagsByName: tags).map((e) => e.name),
      ['notes.txt'],
    );
    expect(filterDirEntries(entries, query: 'zzz', tagFilter: const {}, tagsByName: tags), isEmpty);
    // Trim + case-insensitive; empty inputs are safe.
    expect(filterDirEntries(entries, query: '  PORT  ', tagFilter: const {}, tagsByName: tags).map((e) => e.name), ['Report.PDF']);
    expect(filterDirEntries(const [], query: 'x', tagFilter: const {'t'}, tagsByName: const {}), isEmpty);
  });

  test('sortDirEntriesBy handles empty input and name descending', () {
    expect(sortDirEntriesBy(const [], by: DirSortBy.name, ascending: true), isEmpty);
    final entries = [
      const DirEntry(name: 'b', isDir: false, isLink: false),
      const DirEntry(name: 'a', isDir: false, isLink: false),
      const DirEntry(name: 'd', isDir: true, isLink: false),
      const DirEntry(name: 'c', isDir: true, isLink: false),
    ];
    expect(
      sortDirEntriesBy(entries, by: DirSortBy.name, ascending: false).map((e) => e.name),
      ['d', 'c', 'b', 'a'],
    );
  });

  test('dirPreviewKindOf classifies extensions', () {
    expect(dirPreviewKindOf('photo.PNG'), DirPreviewKind.image);
    expect(dirPreviewKindOf('readme.md'), DirPreviewKind.markdown);
    expect(dirPreviewKindOf('notes.MARKDOWN'), DirPreviewKind.markdown);
    expect(dirPreviewKindOf('script.py'), DirPreviewKind.text);
    expect(dirPreviewKindOf('archive.tar.gz'), DirPreviewKind.unsupported);
    expect(dirPreviewKindOf('.bashrc'), DirPreviewKind.unsupported);
    expect(dirPreviewKindOf('noext'), DirPreviewKind.unsupported);
    expect(dirPreviewKindOf('trailing.'), DirPreviewKind.unsupported);
    expect(dirPreviewCapOf(DirPreviewKind.image), kDirPreviewImageMaxBytes);
    expect(dirPreviewCapOf(DirPreviewKind.unsupported), 0);
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
