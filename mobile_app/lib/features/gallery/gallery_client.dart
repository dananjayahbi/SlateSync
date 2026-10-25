/// Round-13 §03 — the tablet side of the image library (Doc 02 §13.1).
///
/// The library is a **shared collection**, so this file is deliberately only the
/// message shapes plus a thin client: the grid widgets stay dumb and the whole
/// request/response dance is testable against a fake `VectorSyncClient`.
///
/// Two decisions shape everything here:
///
/// * **Bytes never get their own carrier.** An upload is the existing
///   `ASSET_START`/`ASSET_CHUNK`/`ASSET_DONE` transfer keyed by the image's
///   `image_id`, and a download is the PC pushing the same three envelopes the
///   other way. One chunked path means one chunk cap, one abort rule and one
///   reassembly implementation for the whole app.
/// * **The index is metadata only.** `GALLERY_LIST` carries no pixels, so a
///   preview or "use as canvas" asks for that single image's bytes with
///   `GALLERY_LIST_REQUEST {image_id}` — cheap for a 200-item library, and it
///   keeps the list message small enough to re-broadcast on every change.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mobile_app/network/vector_sync_client.dart';

/// Envelope key holding the canvas id (spelled out once, like `ocr_client`).
const String galleryCanvasIdKey = 'canvas_id';

/// Raw bytes per `ASSET_CHUNK` from the frozen transport (template §3).
const int kGalleryAssetChunkRawCap = 262144;

/// Where an image came from (Doc 02 §13.1 `source` enum).
enum GallerySource { paste, drop, canvas }

/// Wire string for [GallerySource].
String gallerySourceWire(GallerySource source) => switch (source) {
      GallerySource.paste => 'PASTE',
      GallerySource.drop => 'DROP',
      GallerySource.canvas => 'CANVAS',
    };

/// Tolerant reader for the wire `source`; unknown values become `PASTE`.
GallerySource gallerySourceFromWire(Object? raw) => switch (
      (raw is String ? raw.trim().toUpperCase() : '')) {
      'DROP' => GallerySource.drop,
      'CANVAS' => GallerySource.canvas,
      _ => GallerySource.paste,
    };

/// How a canvas saved back into the library treats the original (Doc 02 §13.1).
///
/// `replace` is destructive and therefore never a default: the sheet asks, and
/// a dialog dismissed without an answer saves a copy.
enum GallerySaveMode { replace, copy }

/// Wire string for [GallerySaveMode].
String gallerySaveModeWire(GallerySaveMode mode) =>
    mode == GallerySaveMode.replace ? 'REPLACE' : 'COPY';

/// One library item as the wire describes it (metadata only, no pixels).
class LibraryImage {
  const LibraryImage({
    required this.imageId,
    required this.title,
    required this.width,
    required this.height,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    required this.mime,
    required this.filename,
  });

  final String imageId;
  final String title;

  /// Real pixel size. The artboard of a "use as canvas" document is exactly
  /// this, so a mismeasured row would produce a page that clips its own image.
  final int width;
  final int height;

  final GallerySource source;
  final int createdAt;
  final int updatedAt;
  final String mime;
  final String filename;

  /// Reference used inside a canvas document (`assets/<file name>`), matching
  /// the `geometry.asset_ref` convention every renderer already resolves.
  String get assetRef => 'assets/$filename';

  /// Extension of the stored file, without the dot.
  String get extension {
    final int dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) {
      return 'png';
    }
    final String ext = filename.substring(dot + 1).toLowerCase();
    return ext.isEmpty ? 'png' : ext;
  }

  /// `1920 × 1080` for captions.
  String get sizeLabel => '$width × $height';

  /// Parses one `GALLERY_LIST.images[]` row; `null` for anything unusable.
  ///
  /// Tolerant on purpose: one malformed row from a hand-edited index must not
  /// cost the user the other 199 images.
  static LibraryImage? fromWire(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['image_id'];
    if (id is! String || id.trim().isEmpty) {
      return null;
    }
    final int width = _positiveInt(raw['width']);
    final int height = _positiveInt(raw['height']);
    final String filename = _text(raw['filename']) ?? '$id.png';
    return LibraryImage(
      imageId: id.trim(),
      title: _text(raw['title']) ?? filename,
      width: width,
      height: height,
      source: gallerySourceFromWire(raw['source']),
      createdAt: _int(raw['created_at']),
      updatedAt: _int(raw['updated_at']),
      mime: _text(raw['mime']) ?? 'image/png',
      filename: filename,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'image_id': imageId,
        'title': title,
        'width': width,
        'height': height,
        'source': gallerySourceWire(source),
        'created_at': createdAt,
        'updated_at': updatedAt,
        'mime': mime,
        'filename': filename,
      };

  /// Copy with a few fields replaced (the sheet renames a saved canvas).
  LibraryImage copyWith({
    String? title,
    int? updatedAt,
    String? imageId,
    GallerySource? source,
  }) =>
      LibraryImage(
        imageId: imageId ?? this.imageId,
        title: title ?? this.title,
        width: width,
        height: height,
        source: source ?? this.source,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        mime: mime,
        filename: filename,
      );
}

/// Newest first by `updated_at`, ties broken by id so a redraw cannot reshuffle
/// cards under the user's finger.
List<LibraryImage> sortLibraryNewestFirst(Iterable<LibraryImage> images) {
  final List<LibraryImage> sorted = images.toList()
    ..sort((LibraryImage a, LibraryImage b) {
      final int byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0 ? byTime : a.imageId.compareTo(b.imageId);
    });
  return sorted;
}

int unixNowSeconds() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

int _timestamp(DateTime? now) => (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;

String? _text(Object? value) {
  if (value is! String) {
    return null;
  }
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _int(Object? value) => value is num && value.isFinite ? value.toInt() : 0;

int _positiveInt(Object? value) {
  final int parsed = _int(value);
  return parsed >= 1 ? parsed : 1;
}

// ---------------------------------------------------------------------------
// Envelope builders (§13.1 — exact payload key sets)
// ---------------------------------------------------------------------------

/// `GALLERY_LIST_REQUEST` — ask for the index.
///
/// [imageId] is the additive "and please stream this one's bytes" form: the
/// request stays a *list* request (so the reply is the authoritative index) while
/// the pixels for one item arrive as a normal `ASSET_*` transfer. Without it a
/// preview or "use as canvas" would need a fifth action.
Map<String, dynamic> buildGalleryListRequest({
  String? imageId,
  String? id,
  DateTime? now,
}) =>
    <String, dynamic>{
      'id': id ?? uuidV4(),
      'type': 'GALLERY',
      'action': 'GALLERY_LIST_REQUEST',
      galleryCanvasIdKey: '',
      'payload': <String, dynamic>{
        if (imageId != null && imageId.isNotEmpty) 'image_id': imageId,
      },
      'timestamp': _timestamp(now),
    };

/// `GALLERY_ADD` — register an image whose bytes are being streamed.
Map<String, dynamic> buildGalleryAdd({
  required LibraryImage image,
  String? id,
  DateTime? now,
}) =>
    <String, dynamic>{
      'id': id ?? uuidV4(),
      'type': 'GALLERY',
      'action': 'GALLERY_ADD',
      galleryCanvasIdKey: '',
      'payload': <String, dynamic>{
        'image_id': image.imageId,
        'title': image.title,
        'width': image.width,
        'height': image.height,
        'source': gallerySourceWire(image.source),
        'filename': image.filename,
        'mime': image.mime,
      },
      'timestamp': _timestamp(now),
    };

/// `GALLERY_SAVE` — upload a rendered canvas back into the library.
Map<String, dynamic> buildGallerySave({
  required String imageId,
  required String title,
  required int width,
  required int height,
  required String filename,
  required String mime,
  GallerySaveMode mode = GallerySaveMode.copy,
  String? id,
  DateTime? now,
}) =>
    <String, dynamic>{
      'id': id ?? uuidV4(),
      'type': 'GALLERY',
      'action': 'GALLERY_SAVE',
      galleryCanvasIdKey: '',
      'payload': <String, dynamic>{
        'image_id': imageId,
        'title': title,
        'width': width,
        'height': height,
        'filename': filename,
        'mime': mime,
        'mode': gallerySaveModeWire(mode),
      },
      'timestamp': _timestamp(now),
    };

/// The three-envelope chunked upload for [bytes], keyed by [transferId].
///
/// Built as a pure list so the chunk arithmetic (cap, count, base64 content,
/// last-chunk size) is unit-testable without a socket, and so an empty payload
/// produces NO envelopes rather than a START/DONE pair the receiver would abort.
List<Map<String, dynamic>> buildAssetTransfer({
  required String transferId,
  required Uint8List bytes,
  required String filename,
  String? canvasId,
  int chunkRawCap = kGalleryAssetChunkRawCap,
  String? idSeed,
  DateTime? now,
}) {
  if (bytes.isEmpty) {
    return const <Map<String, dynamic>>[];
  }
  final String target = canvasId ?? '';
  final int cap = chunkRawCap < 1 ? kGalleryAssetChunkRawCap : chunkRawCap;
  final int total = (bytes.length + cap - 1) ~/ cap;
  final int stamp = _timestamp(now);
  int counter = 0;
  String nextId() => '${idSeed ?? transferId}-$counter';

  final List<Map<String, dynamic>> envelopes = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': nextId(),
      'type': 'ASSET_UPLOAD',
      'action': 'ASSET_START',
      galleryCanvasIdKey: target,
      'payload': <String, dynamic>{
        'transfer_id': transferId,
        'filename': filename,
        'total_chunks': total,
        'size_bytes': bytes.length,
      },
      'timestamp': stamp,
    },
  ];
  counter += 1;
  for (int index = 0; index < total; index++) {
    final int start = index * cap;
    final int end = start + cap > bytes.length ? bytes.length : start + cap;
    envelopes.add(<String, dynamic>{
      'id': nextId(),
      'type': 'ASSET_UPLOAD',
      'action': 'ASSET_CHUNK',
      galleryCanvasIdKey: target,
      'payload': <String, dynamic>{
        'transfer_id': transferId,
        'index': index,
        'data_b64': base64Encode(Uint8List.sublistView(bytes, start, end)),
      },
      'timestamp': stamp,
    });
    counter += 1;
  }
  envelopes.add(<String, dynamic>{
    'id': nextId(),
    'type': 'ASSET_UPLOAD',
    'action': 'ASSET_DONE',
    galleryCanvasIdKey: target,
    'payload': <String, dynamic>{
      'transfer_id': transferId,
      'total_chunks': total,
      'size_bytes': bytes.length,
    },
    'timestamp': stamp,
  });
  return envelopes;
}

/// Number of chunks an upload of [byteCount] needs (0 for empty bytes).
int assetChunkCount(int byteCount, {int chunkRawCap = kGalleryAssetChunkRawCap}) {
  if (byteCount <= 0) {
    return 0;
  }
  final int cap = chunkRawCap < 1 ? kGalleryAssetChunkRawCap : chunkRawCap;
  return (byteCount + cap - 1) ~/ cap;
}

/// Parses a `GALLERY_LIST` payload into newest-first rows.
List<LibraryImage> parseGalleryList(Map<String, dynamic> payload) {
  final Object? raw = payload['images'];
  if (raw is! List) {
    return const <LibraryImage>[];
  }
  final List<LibraryImage> images = <LibraryImage>[];
  for (final Object? entry in raw) {
    final LibraryImage? image = LibraryImage.fromWire(entry);
    if (image != null) {
      images.add(image);
    }
  }
  return sortLibraryNewestFirst(images);
}

/// Thrown when a library action cannot be requested at all.
class GalleryRequestError implements Exception {
  const GalleryRequestError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Requests the library index, uploads images, and fetches individual pixels.
///
/// Kept free of widgets so the whole flow can be driven by a fake client in
/// tests. Every public method is safe to call while offline — it throws
/// [GalleryRequestError] rather than silently doing nothing, because a gallery
/// that appears to work but never reaches the PC is worse than a clear message.
class GalleryClient {
  GalleryClient({required this.client});

  final VectorSyncClient client;

  /// Waiting time for the PC's answer. The library index is small; anything
  /// slower is a dead link, not a normal slow operation.
  static const Duration defaultTimeout = Duration(seconds: 20);

  /// Reassembled library files land here as `fileReceived` events keyed by
  /// `transfer_id`, which for a library transfer IS the `image_id`.
  final Map<String, String> _receivedPaths = <String, String>{};

  StreamSubscription<SyncEvent>? _sub;
  Completer<List<LibraryImage>>? _listWaiter;
  final Map<String, Completer<void>> _uploadWaiters = <String, Completer<void>>{};
  final Map<String, Completer<String?>> _fetchWaiters = <String, Completer<String?>>{};

  /// Paths of images whose bytes have already been reassembled.
  Map<String, String> get receivedPaths => Map<String, String>.unmodifiable(_receivedPaths);

  void _ensureListening() {
    _sub ??= client.events.listen(_onEvent);
  }

  void _onEvent(SyncEvent event) {
    if (event.kind == SyncEventKind.rpcReceived) {
      final Map<String, dynamic>? msg = event.msg;
      if (msg == null || msg['type'] != 'GALLERY' || msg['action'] != 'GALLERY_LIST') {
        return;
      }
      final Object? payload = msg['payload'];
      if (payload is! Map) {
        return;
      }
      final List<LibraryImage> images =
          parseGalleryList(Map<String, dynamic>.from(payload));
      final Completer<List<LibraryImage>>? listWaiter = _listWaiter;
      _listWaiter = null;
      if (listWaiter != null && !listWaiter.isCompleted) {
        listWaiter.complete(images);
      }
      // Every add/save is answered by a refreshed index, so an arriving list is
      // also how an upload learns it landed.
      _completeUploads();
      return;
    }
    if (event.kind == SyncEventKind.fileReceived) {
      final String transferId = event.transferId ?? '';
      final String? path = event.path;
      if (transferId.isEmpty || path == null) {
        return;
      }
      _receivedPaths[transferId] = path;
      final Completer<String?>? waiter = _fetchWaiters.remove(transferId);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(path);
      }
    }
  }

  /// Sends `GALLERY_LIST_REQUEST` and waits for the `GALLERY_LIST` reply.
  Future<List<LibraryImage>> fetchList({Duration timeout = defaultTimeout}) async {
    _requireConnection();
    _ensureListening();
    final Completer<List<LibraryImage>> waiter = Completer<List<LibraryImage>>();
    _listWaiter = waiter;
    try {
      await client.sendRpc(buildGalleryListRequest());
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw const GalleryRequestError('The PC did not send the image library.');
    } finally {
      if (identical(_listWaiter, waiter)) {
        _listWaiter = null;
      }
      // A timed-out waiter is completed with a benign value rather than left
      // pending: an abandoned pending completer that later fails would surface
      // as an unhandled async error nobody is listening for.
      if (!waiter.isCompleted) {
        waiter.complete(const <LibraryImage>[]);
      }
    }
  }

  /// Asks the PC to stream one image's bytes and returns the reassembled path.
  ///
  /// Returns a cached path when the bytes are already on the tablet, so tapping
  /// preview twice does not re-download the same screenshot.
  Future<String?> fetchImageBytes(
    String imageId, {
    Duration timeout = defaultTimeout,
    bool force = false,
  }) async {
    if (!force && _receivedPaths.containsKey(imageId)) {
      return _receivedPaths[imageId];
    }
    _requireConnection();
    _ensureListening();
    final Completer<String?> waiter = Completer<String?>();
    _fetchWaiters[imageId] = waiter;
    try {
      await client.sendRpc(buildGalleryListRequest(imageId: imageId));
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw GalleryRequestError('The PC did not send "$imageId".');
    } finally {
      _fetchWaiters.remove(imageId);
      if (!waiter.isCompleted) {
        waiter.complete(null);
      }
    }
  }

  /// Uploads [bytes] as a NEW library image (`GALLERY_ADD`).
  Future<LibraryImage> add(
    Uint8List bytes, {
    required String title,
    required int width,
    required int height,
    required String filename,
    String mime = 'image/png',
    GallerySource source = GallerySource.paste,
    String? imageId,
    Duration timeout = defaultTimeout,
  }) async {
    _requireConnection();
    _ensureListening();
    final String id = imageId ?? uuidV4();
    final LibraryImage image = LibraryImage(
      imageId: id,
      title: title,
      width: width,
      height: height,
      source: source,
      createdAt: unixNowSeconds(),
      updatedAt: unixNowSeconds(),
      mime: mime,
      filename: filename,
    );
    await _sendTransfer(id, bytes, filename);
    await _sendAndWait(buildGalleryAdd(image: image), id, timeout);
    return image;
  }

  /// Uploads [bytes] as a canvas saved back over an existing library item.
  ///
  /// [mode] is carried on the wire rather than inferred, because "replace" is
  /// destructive: the PC must be told explicitly that overwriting is intended.
  Future<void> save({
    required String imageId,
    required Uint8List bytes,
    required String title,
    required int width,
    required int height,
    required String filename,
    String mime = 'image/png',
    GallerySaveMode mode = GallerySaveMode.copy,
    Duration timeout = defaultTimeout,
  }) async {
    _requireConnection();
    _ensureListening();
    await _sendTransfer(imageId, bytes, filename);
    await _sendAndWait(
      buildGallerySave(
        imageId: imageId,
        title: title,
        width: width,
        height: height,
        filename: filename,
        mime: mime,
        mode: mode,
      ),
      imageId,
      timeout,
    );
  }

  Future<void> _sendTransfer(String transferId, Uint8List bytes, String filename) async {
    final List<Map<String, dynamic>> envelopes = buildAssetTransfer(
      transferId: transferId,
      bytes: bytes,
      filename: filename,
    );
    for (final Map<String, dynamic> envelope in envelopes) {
      await client.sendRpc(envelope);
    }
  }

  /// Sends the metadata envelope and waits for the PC's refreshed index.
  ///
  /// The PC answers every add/save with `GALLERY_LIST`, so awaiting it is the
  /// only honest way to know the image landed — resolving on send alone would
  /// report success for an upload the PC rejected as unreadable.
  Future<void> _sendAndWait(
    Map<String, dynamic> envelope,
    String transferId,
    Duration timeout,
  ) async {
    final Completer<void> waiter = Completer<void>();
    _uploadWaiters[transferId] = waiter;
    try {
      await client.sendRpc(envelope);
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw GalleryRequestError(
        'The PC did not confirm the upload — is the image library window open?',
      );
    } finally {
      _uploadWaiters.remove(transferId);
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _completeUploads() {
    for (final Completer<void> waiter in _uploadWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  void _requireConnection() {
    if (!client.isConnected) {
      throw const GalleryRequestError(
        'Connect to your PC — the image library lives there.',
      );
    }
  }

  /// Stops listening; safe to call twice.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    const GalleryRequestError closed = GalleryRequestError('Gallery closed.');
    final Completer<List<LibraryImage>>? listWaiter = _listWaiter;
    _listWaiter = null;
    if (listWaiter != null && !listWaiter.isCompleted) {
      listWaiter.completeError(closed);
    }
    final List<Completer<void>> uploads = _uploadWaiters.values.toList();
    _uploadWaiters.clear();
    for (final Completer<void> waiter in uploads) {
      if (!waiter.isCompleted) {
        waiter.completeError(closed);
      }
    }
    final List<Completer<String?>> fetches = _fetchWaiters.values.toList();
    _fetchWaiters.clear();
    for (final Completer<String?> waiter in fetches) {
      if (!waiter.isCompleted) {
        waiter.completeError(closed);
      }
    }
  }

  /// Reads reassembled bytes for [imageId], or `null` when not fetched yet.
  Future<Uint8List?> readBytes(String imageId) async {
    final String? path = _receivedPaths[imageId];
    if (path == null) {
      return null;
    }
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
}
