/// Round 12 — issue 08: gallery thumbnails must reflect the CURRENT canvas.
///
/// The PNG is already rewritten on every save (`local_db.ensureThumbnail` →
/// `saveDocThumbnail`), so the file on disk was correct. What went stale was the
/// picture in memory:
///
/// * the gallery renders `Image.file(File(path))` with a constant widget key;
/// * `Image.file` builds a `FileImage`, whose equality is based on the PATH;
/// * Flutter's global `imageCache` therefore hands back the previously decoded
///   bitmap for the rewritten file — forever, because nothing evicted it.
///
/// `thumbnail_cache.dart` fixes that with a version token derived from the file
/// itself, folded into the widget key, plus an evict when the token changes.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/features/home/thumbnail_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('round12_thumb_');
    forgetAllThumbnails();
  });

  tearDown(() {
    forgetAllThumbnails();
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  File write(String name, List<int> bytes) {
    final File f = File('${tmp.path}/$name');
    f.writeAsBytesSync(bytes);
    return f;
  }

  group('thumbnailVersion', () {
    test('a missing file reports version 0', () {
      expect(thumbnailVersion('${tmp.path}/nope.png'), '0');
    });

    test('an empty path reports version 0', () {
      expect(thumbnailVersion(''), '0');
    });

    test('a directory is not a thumbnail', () {
      final Directory dir = Directory('${tmp.path}/adir')..createSync();
      expect(thumbnailVersion(dir.path), '0');
    });    test('the same bytes report a stable version', () {
      final File f = write('a.png', <int>[1, 2, 3, 4]);
      expect(thumbnailVersion(f.path), thumbnailVersion(f.path));
    });

    test('different bytes report a different version', () {
      final File f = write('a.png', <int>[1, 2, 3, 4]);
      final String before = thumbnailVersion(f.path);
      f.writeAsBytesSync(<int>[9, 9, 9, 9, 9]);
      expect(thumbnailVersion(f.path), isNot(before));
    });

    test('two files with identical bytes share a version', () {
      final File a = write('one.png', <int>[7, 7, 7]);
      final File b = write('two.png', <int>[7, 7, 7]);
      expect(thumbnailVersion(a.path), thumbnailVersion(b.path),
          reason: 'the token is a pure content hash, so it is name-independent');
    });

    test('same length but different bytes gives a different version', () {
      final File a = write('x.png', <int>[1, 2, 3, 4]);
      final File b = write('y.png', <int>[4, 3, 2, 1]);
      expect(thumbnailVersion(a.path), isNot(thumbnailVersion(b.path)),
          reason: 'the length alone cannot distinguish the two bitmaps');
    });
  });

  group('refreshThumbnail', () {
    test('returns the current version', () {
      final File f = write('a.png', <int>[1, 2, 3]);
      expect(refreshThumbnail(f.path), thumbnailVersion(f.path));
    });

    test('a missing file is reported as 0 without throwing', () {
      expect(refreshThumbnail('${tmp.path}/ghost.png'), '0');
    });

    test('rewriting the file yields a NEW version', () {
      final File f = write('a.png', <int>[1, 2, 3]);
      final String first = refreshThumbnail(f.path);
      f.writeAsBytesSync(<int>[4, 5, 6, 7]);
      final String second = refreshThumbnail(f.path);
      expect(second, isNot(first));
    });

    test('an unchanged file keeps the same version across rebuilds', () {
      final File f = write('a.png', <int>[1, 2, 3]);
      final String first = refreshThumbnail(f.path);
      final String second = refreshThumbnail(f.path);
      expect(second, first,
          reason: 'an unchanged file must not churn the widget key');
    });

    test('an empty path is a no-op', () {
      expect(refreshThumbnail(''), '0');
    });
  });

  group('evictThumbnail', () {
    test('evicting an unknown path is harmless', () {
      evictThumbnail('${tmp.path}/never-loaded.png');
    });

    test('evicting an empty path is harmless', () {
      evictThumbnail('');
    });
  });

  group('thumbnailKey', () {
    test('the key changes with the version', () {
      expect(thumbnailKey('c1', 'v1'), isNot(thumbnailKey('c1', 'v2')));
    });

    test('the key changes with the canvas', () {
      expect(thumbnailKey('c1', 'v1'), isNot(thumbnailKey('c2', 'v1')));
    });

    test('the same inputs give an equal key', () {
      expect(thumbnailKey('c1', 'v1'), thumbnailKey('c1', 'v1'));
    });
  });

  group('forget', () {
    test('forgetting one path drops only that memory', () {
      final File a = write('a.png', <int>[1]);
      final File b = write('b.png', <int>[2]);
      refreshThumbnail(a.path);
      refreshThumbnail(b.path);
      forgetThumbnail(a.path);
      // Re-refreshing a is treated as a first sighting again (no evict), while
      // b keeps its history. Both simply must not throw.
      expect(refreshThumbnail(a.path), isNotEmpty);
      expect(refreshThumbnail(b.path), isNotEmpty);
    });

    test('forgetAll clears every remembered version', () {
      final File a = write('a.png', <int>[1]);
      refreshThumbnail(a.path);
      forgetAllThumbnails();
      expect(refreshThumbnail(a.path), isNotEmpty);
    });
  });
}
