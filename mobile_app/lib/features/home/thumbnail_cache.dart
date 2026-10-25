/// Round-12 issue 08 — gallery thumbnails must show the CURRENT canvas.
///
/// The thumbnail PNG is written on every save already
/// (`local_db.ensureThumbnail` → `saveDocThumbnail`), so the file on disk is
/// correct. What was stale was the picture in memory:
///
/// * the gallery renders `Image.file(File(path))` with a constant widget key
///   (`card_thumb_<id>`);
/// * `Image.file` builds a `FileImage`, whose equality is based on the PATH;
/// * Flutter's global `PaintingBinding.instance.imageCache` therefore returns
///   the previously decoded bitmap for the rewritten file, forever.
///
/// Nothing in `mobile_app/lib` ever called `imageCache.evict`, so the gallery
/// could only refresh by restarting the app.
///
/// The fix is a version stamp: the file's modification time is part of the
/// widget key AND a change evicts the stale `FileImage`. `statSync` is used
/// because a card build is synchronous and the grid holds only a handful of
/// rows; the call replaces the `existsSync` the card already did.
library;

import 'dart:io';

import 'package:flutter/widgets.dart';

/// Version tokens already observed, so an unchanged file is not evicted on
/// every rebuild (an evict per frame would thrash the cache and flicker).
final Map<String, String> _seen = <String, String>{};

/// A stable token for the CURRENT bytes at [path], or `'0'` when missing.
///
/// Uses the modification time plus the byte length: `updated_at` alone is not
/// enough because a save within the same second produces an identical stamp,
/// which is exactly the case that used to look stale.
String thumbnailVersion(String path) {
  if (path.isEmpty) {
    return '0';
  }
  try {
    final File file = File(path);
    if (!file.existsSync()) {
      return '0';
    }
    // FNV-1a over the bytes. mtime and length alone are not enough: two
    // solid-colour thumbnails can share both, which is precisely the case that
    // stayed stale. A thumbnail is ~256², so hashing it on card build is cheap.
    final List<int> bytes = file.readAsBytesSync();
    int hash = 0x811c9dc5;
    for (final int byte in bytes) {
      hash = (hash ^ byte) & 0xffffffff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${bytes.length}_${hash.toRadixString(16)}';
  } on FileSystemException {
    return '0';
  }
}

/// Drops [path] from the image cache when its bytes changed since last seen.
///
/// Returns the current [thumbnailVersion] so the caller can fold it into the
/// widget key, which is what actually makes the widget rebuild.
String refreshThumbnail(String path) {
  final String version = thumbnailVersion(path);
  if (path.isEmpty) {
    return version;
  }
  final String? previous = _seen[path];
  _seen[path] = version;
  if (previous != null && previous != version) {
    evictThumbnail(path);
  }
  return version;
}

/// Removes the decoded bitmap for [path] from Flutter's global image cache.
void evictThumbnail(String path) {
  if (path.isEmpty) {
    return;
  }
  try {
    PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
  } catch (_) {
    // An evict is best-effort: a cache miss is not an error.
  }
}

/// Forgets the remembered versions (tests, or after deleting a canvas).
void forgetThumbnail(String path) {
  _seen.remove(path);
}

/// Clears every remembered version — used when the gallery is disposed.
void forgetAllThumbnails() {
  _seen.clear();
}

/// A widget key that changes whenever the thumbnail bytes change.
///
/// Pair with [refreshThumbnail]: the version must be read AFTER the evict so the
/// rebuilt widget resolves the new bytes.
Key thumbnailKey(String canvasId, String version) =>
    ValueKey<String>('card_thumb_${canvasId}_$version');
