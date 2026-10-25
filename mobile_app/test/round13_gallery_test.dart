/// Round-13 §03 — the tablet half of the image library.
///
/// The PC is faked throughout: what is being pinned here is the wire shapes,
/// the newest-first ordering, the exact-pixel artboard maths and the
/// Replace/Copy semantics — the four things a green build alone cannot prove.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/gallery/gallery_client.dart';
import 'package:mobile_app/features/gallery/gallery_grid.dart';
import 'package:mobile_app/features/gallery/gallery_screen.dart';
import 'package:mobile_app/features/gallery/gallery_snapshot.dart';
import 'package:mobile_app/features/gallery/save_to_gallery_sheet.dart';
import 'package:mobile_app/features/gallery/use_as_canvas.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'
    show HomeCanvasDashboard, buildNewCanvasDocument;
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

class _FakeClient extends VectorSyncClient {
  _FakeClient({this.connected = true});

  bool connected;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool throwOnSend = false;

  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    if (throwOnSend) {
      throw StateError('socket closed');
    }
    for (final String field in const <String>[
      'id',
      'type',
      'action',
      'canvas_id',
      'payload',
      'timestamp',
    ]) {
      if (!envelope.containsKey(field)) {
        throw FormatException('missing envelope field: $field');
      }
    }
    sent.add(envelope);
  }

  void emitRpc(Map<String, dynamic> message) =>
      _ctrl.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: message));

  void emitFile(String transferId, String path) => _ctrl.add(
        SyncEvent(
          kind: SyncEventKind.fileReceived,
          transferId: transferId,
          path: path,
        ),
      );

  Future<void> close() => _ctrl.close();
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

LibraryImage _image({
  String id = 'img-1',
  String title = 'Bug screenshot',
  int width = 1920,
  int height = 1080,
  GallerySource source = GallerySource.paste,
  int createdAt = 100,
  int updatedAt = 100,
  String? filename,
}) =>
    LibraryImage(
      imageId: id,
      title: title,
      width: width,
      height: height,
      source: source,
      createdAt: createdAt,
      updatedAt: updatedAt,
      mime: 'image/png',
      filename: filename ?? '$id.png',
    );

Map<String, dynamic> _wireRow({
  String id = 'img-1',
  String title = 'Bug screenshot',
  Object? width = 1920,
  Object? height = 1080,
  Object? source = 'PASTE',
  Object? updatedAt = 100,
}) =>
    <String, dynamic>{
      'image_id': id,
      'title': title,
      'width': width,
      'height': height,
      'source': source,
      'created_at': 90,
      'updated_at': updatedAt,
      'mime': 'image/png',
      'filename': '$id.png',
    };

Map<String, dynamic> _listMessage(List<Map<String, dynamic>> rows) =>
    <String, dynamic>{
      'id': 'env-1',
      'type': 'GALLERY',
      'action': 'GALLERY_LIST',
      'canvas_id': '',
      'payload': <String, dynamic>{'images': rows},
      'timestamp': 1,
    };

Uint8List _bytes(int length, {int seed = 7}) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => (i + seed) % 256));

void main() {
  // -------------------------------------------------------------------------
  // Wire envelopes (Doc 02 §13.1 — exact payload key sets)
  // -------------------------------------------------------------------------

  group('wire envelopes', () {
    test('GALLERY_LIST_REQUEST carries an empty payload and no canvas', () {
      final Map<String, dynamic> env = buildGalleryListRequest(id: 'e-1');
      expect(env['type'], 'GALLERY');
      expect(env['action'], 'GALLERY_LIST_REQUEST');
      expect(env['canvas_id'], '');
      expect(env['payload'], isEmpty);
      expect(env['id'], 'e-1');
      expect(env['timestamp'], isA<int>());
    });

    test('GALLERY_LIST_REQUEST may name one image to stream', () {
      final Map<String, dynamic> env =
          buildGalleryListRequest(imageId: 'img-9', id: 'e-2');
      expect(env['payload'], <String, dynamic>{'image_id': 'img-9'});
      expect(env['action'], 'GALLERY_LIST_REQUEST');
    });

    test('an empty image id is dropped rather than sent blank', () {
      expect(buildGalleryListRequest(imageId: '')['payload'], isEmpty);
    });

    test('GALLERY_ADD carries exactly the eight required keys', () {
      final Map<String, dynamic> env = buildGalleryAdd(image: _image(), id: 'e-3');
      expect(env['action'], 'GALLERY_ADD');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      expect(
        payload.keys.toSet(),
        <String>{
          'image_id',
          'title',
          'width',
          'height',
          'source',
          'filename',
          'mime',
        },
      );
      expect(payload['image_id'], 'img-1');
      expect(payload['width'], 1920);
      expect(payload['source'], 'PASTE');
    });

    test('GALLERY_ADD spells the source enum the schema allows', () {
      for (final GallerySource source in GallerySource.values) {
        final Map<String, dynamic> env =
            buildGalleryAdd(image: _image(source: source));
        expect(
          (env['payload'] as Map)['source'],
          isIn(<String>['PASTE', 'DROP', 'CANVAS']),
        );
      }
    });

    test('GALLERY_SAVE carries mode and never a source', () {
      final Map<String, dynamic> env = buildGallerySave(
        imageId: 'img-1',
        title: 'Annotated',
        width: 800,
        height: 600,
        filename: 'a.png',
        mime: 'image/png',
        mode: GallerySaveMode.replace,
        id: 'e-4',
      );
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      expect(env['action'], 'GALLERY_SAVE');
      expect(payload['mode'], 'REPLACE');
      expect(payload.containsKey('source'), isFalse);
      expect(
        payload.keys.toSet(),
        <String>{
          'image_id',
          'title',
          'width',
          'height',
          'filename',
          'mime',
          'mode',
        },
      );
    });

    test('copy is the wire spelling for the default save mode', () {
      final Map<String, dynamic> env = buildGallerySave(
        imageId: 'x',
        title: 't',
        width: 1,
        height: 1,
        filename: 'x.png',
        mime: 'image/png',
      );
      expect((env['payload'] as Map)['mode'], 'COPY');
    });

    test('every gallery envelope is a complete Doc 02 envelope', () {
      final List<Map<String, dynamic>> envelopes = <Map<String, dynamic>>[
        buildGalleryListRequest(),
        buildGalleryAdd(image: _image()),
        buildGallerySave(
          imageId: 'i',
          title: 't',
          width: 2,
          height: 3,
          filename: 'f.png',
          mime: 'image/png',
        ),
      ];
      for (final Map<String, dynamic> env in envelopes) {
        expect(env.keys.toSet(), <String>{
          'id',
          'type',
          'action',
          'canvas_id',
          'payload',
          'timestamp',
        });
        expect(env['type'], 'GALLERY');
      }
    });

    test('envelope ids are unique across builds', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 20; i++) buildGalleryListRequest()['id'] as String,
      };
      expect(ids.length, 20);
    });

    test('a pinned clock makes the timestamp deterministic', () {
      final Map<String, dynamic> env = buildGalleryListRequest(
        now: DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
      );
      expect(env['timestamp'], 1700000000);
    });
  });

  // -------------------------------------------------------------------------
  // Chunked upload reuse (no new byte transport)
  // -------------------------------------------------------------------------

  group('asset transfer', () {
    test('a small image is one start, one chunk, one done', () {
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 'img-1',
        bytes: _bytes(100),
        filename: 'img-1.png',
      );
      expect(env.length, 3);
      expect(env[0]['action'], 'ASSET_START');
      expect(env[1]['action'], 'ASSET_CHUNK');
      expect(env[2]['action'], 'ASSET_DONE');
      for (final Map<String, dynamic> e in env) {
        expect(e['type'], 'ASSET_UPLOAD');
        expect((e['payload'] as Map)['transfer_id'], 'img-1');
      }
    });

    test('a large image is split at the 262144-byte raw cap', () {
      final int raw = kGalleryAssetChunkRawCap * 2 + 10;
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 'big',
        bytes: _bytes(raw),
        filename: 'big.png',
      );
      final List<Map<String, dynamic>> chunks = env
          .where((Map<String, dynamic> e) => e['action'] == 'ASSET_CHUNK')
          .toList();
      expect(chunks.length, 3);
      expect((env.first['payload'] as Map)['total_chunks'], 3);
      expect((env.last['payload'] as Map)['size_bytes'], raw);
      for (final Map<String, dynamic> chunk in chunks) {
        final String b64 = (chunk['payload'] as Map)['data_b64'] as String;
        expect(base64Decode(b64).length, lessThanOrEqualTo(kGalleryAssetChunkRawCap));
      }
    });

    test('the reassembled chunks equal the source bytes in order', () {
      final Uint8List bytes = _bytes(kGalleryAssetChunkRawCap + 500);
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 't',
        bytes: bytes,
        filename: 't.png',
      );
      final BytesBuilder rebuilt = BytesBuilder();
      for (final Map<String, dynamic> e in env) {
        if (e['action'] == 'ASSET_CHUNK') {
          rebuilt.add(base64Decode((e['payload'] as Map)['data_b64'] as String));
        }
      }
      expect(rebuilt.toBytes(), bytes);
    });

    test('the chunk index is dense and zero-based', () {
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 't',
        bytes: _bytes(kGalleryAssetChunkRawCap * 3),
        filename: 't.png',
      );
      final List<int> indexes = env
          .where((Map<String, dynamic> e) => e['action'] == 'ASSET_CHUNK')
          .map((Map<String, dynamic> e) => (e['payload'] as Map)['index'] as int)
          .toList();
      expect(indexes, <int>[0, 1, 2]);
    });

    test('empty bytes produce no envelopes at all', () {
      expect(
        buildAssetTransfer(
          transferId: 't',
          bytes: Uint8List(0),
          filename: 't.png',
        ),
        isEmpty,
      );
    });

    test('the chunk count helper agrees with the envelopes it predicts', () {
      for (final int raw in <int>[1, 1000, kGalleryAssetChunkRawCap, kGalleryAssetChunkRawCap + 1]) {
        final int predicted = assetChunkCount(raw);
        final int actual = buildAssetTransfer(
          transferId: 't',
          bytes: _bytes(raw),
          filename: 't.png',
        ).where((Map<String, dynamic> e) => e['action'] == 'ASSET_CHUNK').length;
        expect(predicted, actual, reason: '$raw bytes');
      }
      expect(assetChunkCount(0), 0);
    });

    test('an overridden cap is honoured (used by the tests only)', () {
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 't',
        bytes: _bytes(10),
        filename: 't.png',
        chunkRawCap: 4,
      );
      expect(env.where((Map<String, dynamic> e) => e['action'] == 'ASSET_CHUNK').length, 3);
    });

    test('a degenerate cap falls back instead of dividing by zero', () {
      final List<Map<String, dynamic>> env = buildAssetTransfer(
        transferId: 't',
        bytes: _bytes(8),
        filename: 't.png',
        chunkRawCap: 0,
      );
      expect(env.where((Map<String, dynamic> e) => e['action'] == 'ASSET_CHUNK').length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Row parsing and ordering
  // -------------------------------------------------------------------------

  group('list parsing', () {
    test('a full row maps every field', () {
      final LibraryImage? image = LibraryImage.fromWire(_wireRow());
      expect(image, isNotNull);
      expect(image!.imageId, 'img-1');
      expect(image.title, 'Bug screenshot');
      expect(image.width, 1920);
      expect(image.height, 1080);
      expect(image.source, GallerySource.paste);
      expect(image.createdAt, 90);
      expect(image.updatedAt, 100);
      expect(image.mime, 'image/png');
    });

    test('rows without an image_id are dropped, not invented', () {
      expect(LibraryImage.fromWire(<String, dynamic>{'title': 'x'}), isNull);
      expect(LibraryImage.fromWire(<String, dynamic>{'image_id': '   '}), isNull);
      expect(LibraryImage.fromWire('not a map'), isNull);
      expect(LibraryImage.fromWire(null), isNull);
    });

    test('a bad width cannot produce a zero-sized artboard', () {
      final LibraryImage? image = LibraryImage.fromWire(
        _wireRow(width: 0, height: -5),
      );
      expect(image!.width, 1);
      expect(image.height, 1);
    });

    test('missing width/height fall back to a 1px page, never null', () {
      final LibraryImage? image = LibraryImage.fromWire(
        <String, dynamic>{'image_id': 'a'},
      );
      expect(image!.width, 1);
      expect(image.height, 1);
      expect(image.filename, 'a.png');
    });

    test('a missing title falls back to the file name', () {
      final LibraryImage? image = LibraryImage.fromWire(
        <String, dynamic>{'image_id': 'a', 'filename': 'holiday.png'},
      );
      expect(image!.title, 'holiday.png');
    });

    test('unknown sources degrade to PASTE rather than throwing', () {
      expect(gallerySourceFromWire('MICROWAVE'), GallerySource.paste);
      expect(gallerySourceFromWire(null), GallerySource.paste);
      expect(gallerySourceFromWire('canvas'), GallerySource.canvas);
      expect(gallerySourceFromWire(' DROP '), GallerySource.drop);
    });

    test('a malformed row does not cost the whole list', () {
      final List<LibraryImage> images = parseGalleryList(<String, dynamic>{
        'images': <Object?>[
          _wireRow(id: 'a'),
          <String, dynamic>{'nope': 1},
          _wireRow(id: 'b'),
        ],
      });
      expect(images.map((LibraryImage i) => i.imageId), <String>['a', 'b']);
    });

    test('a payload without images is an empty library, not an error', () {
      expect(parseGalleryList(<String, dynamic>{}), isEmpty);
      expect(parseGalleryList(<String, dynamic>{'images': 'x'}), isEmpty);
    });

    test('the list is sorted newest-first', () {
      final List<LibraryImage> sorted = parseGalleryList(<String, dynamic>{
        'images': <Object?>[
          _wireRow(id: 'old', updatedAt: 10),
          _wireRow(id: 'new', updatedAt: 30),
          _wireRow(id: 'mid', updatedAt: 20),
        ],
      });
      expect(
        sorted.map((LibraryImage i) => i.imageId),
        <String>['new', 'mid', 'old'],
      );
    });

    test('equal timestamps break on id so a refresh cannot reshuffle', () {
      final List<LibraryImage> sorted = sortLibraryNewestFirst(<LibraryImage>[
        _image(id: 'b', updatedAt: 5),
        _image(id: 'a', updatedAt: 5),
      ]);
      expect(sorted.map((LibraryImage i) => i.imageId), <String>['a', 'b']);
    });

    test('sorting is stable for an already-sorted list', () {
      final List<LibraryImage> sorted = sortLibraryNewestFirst(<LibraryImage>[
        _image(id: 'a', updatedAt: 9),
        _image(id: 'b', updatedAt: 8),
      ]);
      expect(sorted.map((LibraryImage i) => i.imageId), <String>['a', 'b']);
    });

    test('a row round-trips through toJson unchanged', () {
      final LibraryImage image = _image();
      final LibraryImage again = LibraryImage.fromWire(image.toJson())!;
      expect(again.toJson(), image.toJson());
    });
  });

  // -------------------------------------------------------------------------
  // Model helpers
  // -------------------------------------------------------------------------

  group('model', () {
    test('assetRef is the studio spelling', () {
      expect(_image(filename: 'shot.png').assetRef, 'assets/shot.png');
    });

    test('extension is lower-cased and defaults to png', () {
      expect(_image(filename: 'A.JPEG').extension, 'jpeg');
      expect(_image(filename: 'noext').extension, 'png');
      expect(_image(filename: 'trailing.').extension, 'png');
    });

    test('sizeLabel uses the multiplication sign', () {
      expect(_image().sizeLabel, '1920 × 1080');
    });

    test('copyWith keeps the untouched fields', () {
      final LibraryImage image = _image();
      final LibraryImage edited = image.copyWith(title: 'New', updatedAt: 500);
      expect(edited.title, 'New');
      expect(edited.updatedAt, 500);
      expect(edited.imageId, image.imageId);
      expect(edited.width, image.width);
      expect(edited.createdAt, image.createdAt);
    });
  });

  // -------------------------------------------------------------------------
  // Client behaviour
  // -------------------------------------------------------------------------

  group('client', () {
    test('an offline client refuses instead of pretending', () async {
      final _FakeClient fake = _FakeClient(connected: false);
      final GalleryClient client = GalleryClient(client: fake);
      await expectLater(
        client.fetchList(),
        throwsA(isA<GalleryRequestError>()),
      );
      expect(fake.sent, isEmpty);
      await client.dispose();
      await fake.close();
    });

    test('fetchList sends a request and resolves the reply', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<List<LibraryImage>> pending = client.fetchList();
      await Future<void>.delayed(Duration.zero);
      expect(fake.sent.single['action'], 'GALLERY_LIST_REQUEST');
      fake.emitRpc(_listMessage(<Map<String, dynamic>>[_wireRow()]));
      final List<LibraryImage> images = await pending;
      expect(images.single.imageId, 'img-1');
      await client.dispose();
      await fake.close();
    });

    test('fetchList times out with a readable message', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      await expectLater(
        client.fetchList(timeout: const Duration(milliseconds: 20)),
        throwsA(
          isA<GalleryRequestError>().having(
            (GalleryRequestError e) => e.message,
            'message',
            contains('did not send'),
          ),
        ),
      );
      await client.dispose();
      await fake.close();
    });

    test('fetchImageBytes returns a cached path without re-requesting', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<String?> first = client.fetchImageBytes('img-1');
      await Future<void>.delayed(Duration.zero);
      expect((fake.sent.single['payload'] as Map)['image_id'], 'img-1');
      fake.emitFile('img-1', 'C:/tmp/img-1.png');
      expect(await first, 'C:/tmp/img-1.png');
      final int before = fake.sent.length;
      expect(await client.fetchImageBytes('img-1'), 'C:/tmp/img-1.png');
      expect(fake.sent.length, before, reason: 'a cached fetch must not re-ask');
      await client.dispose();
      await fake.close();
    });

    test('force re-fetches even when a path is cached', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<String?> first = client.fetchImageBytes('img-1');
      await Future<void>.delayed(Duration.zero);
      fake.emitFile('img-1', 'C:/tmp/a.png');
      await first;
      final Future<String?> second =
          client.fetchImageBytes('img-1', force: true);
      await Future<void>.delayed(Duration.zero);
      expect(fake.sent.length, 2);
      fake.emitFile('img-1', 'C:/tmp/b.png');
      expect(await second, 'C:/tmp/b.png');
      await client.dispose();
      await fake.close();
    });

    test('add streams the bytes then announces them', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<LibraryImage> pending = client.add(
        _bytes(10),
        title: 'Pasted',
        width: 10,
        height: 20,
        filename: 'p.png',
        imageId: 'img-7',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        fake.sent.map((Map<String, dynamic> e) => e['action']),
        <String>['ASSET_START', 'ASSET_CHUNK', 'ASSET_DONE', 'GALLERY_ADD'],
      );
      fake.emitRpc(_listMessage(<Map<String, dynamic>>[_wireRow(id: 'img-7')]));
      final LibraryImage image = await pending;
      expect(image.imageId, 'img-7');
      expect(image.width, 10);
      await client.dispose();
      await fake.close();
    });

    test('add times out rather than reporting a false success', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      await expectLater(
        client.add(
          _bytes(4),
          title: 'x',
          width: 1,
          height: 1,
          filename: 'x.png',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<GalleryRequestError>()),
      );
      await client.dispose();
      await fake.close();
    });

    test('save sends the chosen mode last, after the bytes', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<void> pending = client.save(
        imageId: 'img-3',
        bytes: _bytes(5),
        title: 'Annotated',
        width: 5,
        height: 5,
        filename: 'a.png',
        mode: GallerySaveMode.replace,
      );
      await Future<void>.delayed(Duration.zero);
      final Map<String, dynamic> last = fake.sent.last;
      expect(last['action'], 'GALLERY_SAVE');
      expect((last['payload'] as Map)['mode'], 'REPLACE');
      fake.emitRpc(_listMessage(<Map<String, dynamic>>[_wireRow(id: 'img-3')]));
      await pending;
      await client.dispose();
      await fake.close();
    });

    test('dispose fails pending waiters instead of leaking them', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<List<LibraryImage>> pending = client.fetchList();
      await Future<void>.delayed(Duration.zero);
      await client.dispose();
      await expectLater(pending, throwsA(isA<GalleryRequestError>()));
      await fake.close();
    });

    test('dispose is idempotent', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      await client.dispose();
      await client.dispose();
      await fake.close();
    });

    test('a non-gallery message is ignored', () async {
      final _FakeClient fake = _FakeClient();
      final GalleryClient client = GalleryClient(client: fake);
      final Future<List<LibraryImage>> pending = client.fetchList();
      await Future<void>.delayed(Duration.zero);
      fake.emitRpc(<String, dynamic>{
        'type': 'OCR_JOB',
        'action': 'OCR_RESULT',
        'payload': <String, dynamic>{},
      });
      fake.emitRpc(_listMessage(<Map<String, dynamic>>[_wireRow()]));
      expect((await pending).length, 1);
      await client.dispose();
      await fake.close();
    });
  });

  // -------------------------------------------------------------------------
  // "Use as canvas" — the exact-pixel rule
  // -------------------------------------------------------------------------

  group('use as canvas', () {
    test('the artboard is exactly the image pixel size', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 1920, height: 1080));
      expect(doc.artboard.width, 1920);
      expect(doc.artboard.height, 1080);
      expect(doc.artboard.isInfinite, isFalse);
    });

    test('a portrait image keeps its exact proportions', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 750, height: 1334));
      expect(doc.artboard.width, 750);
      expect(doc.artboard.height, 1334);
      expect(doc.artboard.height! / doc.artboard.width!, closeTo(1334 / 750, 1e-9));
    });

    test('a square image is not rounded through a preset', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 512, height: 512));
      expect(doc.artboard.width, 512);
      expect(doc.artboard.height, 512);
    });

    test('a 1 × 1 image is legal (the schema minimum)', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 1, height: 1));
      expect(doc.artboard.width, 1);
      expect(doc.artboard.height, 1);
    });

    test('the document has exactly one element and it is the image', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(filename: 'shot.png'));
      expect(doc.elements, hasLength(1));
      final CanvasNodeModel node = doc.elements.single;
      expect(node.kind, 'IMAGE');
      expect(node.geometry.assetRef, 'assets/shot.png');
    });

    test('the element sits at (0,0) and fills the page', () {
      final CanvasNodeModel node = buildGalleryImageNode(
        image: _image(width: 800, height: 400),
      );
      expect(node.bbox, <double>[0, 0, 800, 400]);
    });

    test('the element carries no stray points (it is a bitmap)', () {
      final CanvasNodeModel node = buildGalleryImageNode(image: _image());
      expect(node.geometry.pts, isEmpty);
      expect(node.geometry.shapeType, isNull);
    });

    test('content bounds match the page', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 640, height: 480));
      expect(doc.contentBounds['max_x'], 640);
      expect(doc.contentBounds['max_y'], 480);
      expect(doc.contentBounds['min_x'], 0);
      expect(doc.contentBounds['min_y'], 0);
    });

    test('the title comes from the library item', () {
      final CanvasDocumentModel doc = buildCanvasFromGalleryImage(
        image: _image(title: 'Login bug'),
      );
      expect(doc.title, 'Login bug');
    });

    test('a blank title still yields a usable canvas name', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(title: '   '));
      expect(doc.title, 'Library image');
    });

    test('the builder inherits the shared document defaults', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(), now: 1234);
      expect(doc.createdAt, 1234);
      expect(doc.updatedAt, 1234);
      expect(doc.artboard.backgroundColor, '#FFFFFF');
      expect(doc.artboard.backgroundStyle, kBackgroundBlank);
    });

    test('an explicit canvas id is used verbatim', () {
      final CanvasDocumentModel doc = buildCanvasFromGalleryImage(
        image: _image(),
        canvasId: 'canvas-fixed',
      );
      expect(doc.canvasId, 'canvas-fixed');
    });

    test('two documents from one image get different ids', () {
      final CanvasDocumentModel a =
          buildCanvasFromGalleryImage(image: _image());
      final CanvasDocumentModel b =
          buildCanvasFromGalleryImage(image: _image());
      expect(a.canvasId, isNot(b.canvasId));
      expect(a.elements.single.nodeId, isNot(b.elements.single.nodeId));
    });

    test('galleryArtboardSize matches the image exactly', () {
      final ({double width, double height}) size =
          galleryArtboardSize(_image(width: 300, height: 700));
      expect(size.width, 300);
      expect(size.height, 700);
    });

    test('the document round-trips through JSON unchanged', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 320, height: 200));
      final CanvasDocumentModel again =
          CanvasDocumentModel.fromJson(doc.toJson());
      expect(again.artboard.width, 320);
      expect(again.artboard.height, 200);
      expect(again.elements.single.bbox, <double>[0, 0, 320, 200]);
      expect(again.elements.single.geometry.assetRef, doc.elements.single.geometry.assetRef);
    });

    test('canvasMatchesImage is exact, not approximate', () {
      final LibraryImage image = _image(width: 100, height: 50);
      final CanvasDocumentModel doc = buildCanvasFromGalleryImage(image: image);
      expect(canvasMatchesImage(doc, image), isTrue);
      doc.artboard.width = 101;
      expect(canvasMatchesImage(doc, image), isFalse);
    });

    test('an infinite canvas never matches an image', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'x',
        preset: 'INFINITE',
        background: kBackgroundBlank,
      );
      expect(canvasMatchesImage(doc, _image()), isFalse);
    });

    test('preview scale never upscales a small image', () {
      expect(galleryPreviewScale(40, 40, 200), 1);
      expect(galleryPreviewScale(400, 200, 200), closeTo(0.5, 1e-9));
      expect(galleryPreviewScale(200, 400, 200), closeTo(0.5, 1e-9));
    });

    test('preview scale tolerates degenerate inputs', () {
      expect(galleryPreviewScale(0, 0, 200), 1);
      expect(galleryPreviewScale(100, 100, 0), 1);
    });

    test('the size label is the multiplication sign, not an x', () {
      expect(gallerySizeLabel(1920, 1080), '1920 × 1080');
    });
  });

  // -------------------------------------------------------------------------
  // Save back: Replace vs Copy
  // -------------------------------------------------------------------------

  group('save to gallery', () {
    final LibraryImage source = _image(id: 'img-origin', title: 'Origin');

    test('replace keeps the source image_id', () {
      expect(
        resolveSaveImageId(mode: GallerySaveMode.replace, source: source),
        'img-origin',
      );
    });

    test('copy always mints a new image_id', () {
      final String id = resolveSaveImageId(
        mode: GallerySaveMode.copy,
        source: source,
      );
      expect(id, isNot('img-origin'));
      expect(id, isNotEmpty);
    });

    test('replace without a source still mints an id', () {
      final String id = resolveSaveImageId(mode: GallerySaveMode.replace);
      expect(id, isNotEmpty);
      expect(id, isNot('img-origin'));
    });

    test('two copies of the same canvas never share an id', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 10; i++)
          resolveSaveImageId(mode: GallerySaveMode.copy, source: source),
      };
      expect(ids.length, 10);
    });

    test('a seeded id is honoured for a copy', () {
      expect(
        resolveSaveImageId(
          mode: GallerySaveMode.copy,
          source: source,
          seedId: 'fixed',
        ),
        'fixed',
      );
    });

    test('replace prefers the canvas title when the user renamed it', () {
      expect(
        resolveSaveTitle(
          mode: GallerySaveMode.replace,
          source: source,
          canvasTitle: 'Marked up',
        ),
        'Marked up',
      );
    });

    test('a blank canvas title falls back instead of writing empty', () {
      expect(
        resolveSaveTitle(
          mode: GallerySaveMode.copy,
          canvasTitle: '  ',
        ),
        'Library image',
      );
    });

    test('the snapshot size is the page at native pixels', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 900, height: 600));
      final ({int width, int height}) size = gallerySnapshotSize(doc);
      expect(size.width, 900);
      expect(size.height, 600);
    });

    test('an oversized page is bounded by the max side, keeping the ratio', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'huge',
        preset: 'A4',
        background: kBackgroundBlank,
      );
      final ({int width, int height}) size = gallerySnapshotSize(doc, maxSide: 1000);
      // A4 is portrait, so the HEIGHT is the side that gets clamped.
      expect(size.height, 1000);
      expect(size.width, lessThan(1000));
      expect(
        size.width / size.height,
        closeTo(doc.artboard.width! / doc.artboard.height!, 1e-3),
      );
    });

    test('a page already under the cap is left at native size', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'a4',
        preset: 'A4',
        background: kBackgroundBlank,
      );
      final ({int width, int height}) size = gallerySnapshotSize(doc);
      expect(size.width, 2480);
      expect(size.height, 3508);
    });

    test('the snapshot rect is the artboard, from the origin', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(width: 30, height: 40));
      final ({double x, double y, double w, double h}) rect =
          gallerySnapshotRect(doc);
      expect(rect.x, 0);
      expect(rect.y, 0);
      expect(rect.w, 30);
      expect(rect.h, 40);
    });

    test('an empty infinite canvas still yields a usable rect', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'x',
        preset: 'INFINITE',
        background: kBackgroundBlank,
      );
      final ({double x, double y, double w, double h}) rect =
          gallerySnapshotRect(doc);
      expect(rect.w, greaterThan(0));
      expect(rect.h, greaterThan(0));
    });

    test('the save filename is sanitised and stable per canvas', () {
      final String name = gallerySaveFilename('Bug: shot/1', 'abcdef1234567890');
      expect(name, 'Bug- shot-1-abcdef12.png');
      expect(gallerySaveFilename('Bug: shot/1', 'abcdef1234567890'), name);
    });

    test('a blank title still produces a filename', () {
      expect(gallerySaveFilename('   ', 'abcdef12'), 'abcdef12.png');
      expect(gallerySaveFilename('', ''), 'canvas.png');
    });

    test('sanitise strips separators and control characters', () {
      expect(sanitiseGalleryName('a\\b/c:d*e?f"g<h>i|j'), 'a-b-c-d-e-f-g-h-i-j');
      expect(sanitiseGalleryName('  spaced   out  '), 'spaced out');
      expect(sanitiseGalleryName('line\nbreak'), 'line-break');
    });

    test('the plan carries the mode, size and filename', () {
      final CanvasDocumentModel doc =
          buildCanvasFromGalleryImage(image: _image(title: 'Origin'));
      final GallerySavePlan plan = planGallerySave(
        doc: doc,
        mode: GallerySaveMode.replace,
        source: source,
      );
      expect(plan.mode, GallerySaveMode.replace);
      expect(plan.imageId, 'img-origin');
      expect(plan.width, 1920);
      expect(plan.height, 1080);
      expect(plan.filename, endsWith('.png'));
      expect(plan.title, 'Origin');
    });

    test('the plan envelope is a valid GALLERY_SAVE', () {
      final CanvasDocumentModel doc = buildCanvasFromGalleryImage(image: _image());
      final GallerySavePlan plan = planGallerySave(
        doc: doc,
        mode: GallerySaveMode.copy,
        source: source,
        imageId: 'img-new',
      );
      final Map<String, dynamic> env = buildGallerySaveRequest(plan, id: 'e-9');
      expect(env['action'], 'GALLERY_SAVE');
      expect((env['payload'] as Map)['image_id'], 'img-new');
      expect((env['payload'] as Map)['mode'], 'COPY');
      expect(env['id'], 'e-9');
    });

    test('replace and copy of the same canvas target different ids', () {
      final CanvasDocumentModel doc = buildCanvasFromGalleryImage(image: source);
      final GallerySavePlan replace =
          planGallerySave(doc: doc, mode: GallerySaveMode.replace, source: source);
      final GallerySavePlan copy =
          planGallerySave(doc: doc, mode: GallerySaveMode.copy, source: source);
      expect(replace.imageId, 'img-origin');
      expect(copy.imageId, isNot(replace.imageId));
    });
  });

  // -------------------------------------------------------------------------
  // Grid helpers
  // -------------------------------------------------------------------------

  group('grid helpers', () {
    test('columns grow with width and never collapse to zero', () {
      expect(galleryGridColumns(320), 2);
      expect(galleryGridColumns(600), 3);
      expect(galleryGridColumns(900), 4);
      expect(galleryGridColumns(1600), 5);
    });

    test('source labels are human', () {
      expect(gallerySourceLabel(GallerySource.paste), 'Pasted');
      expect(gallerySourceLabel(GallerySource.drop), 'Dropped');
      expect(gallerySourceLabel(GallerySource.canvas), 'Canvas');
    });

    test('every source has an icon', () {
      for (final GallerySource source in GallerySource.values) {
        expect(gallerySourceIcon(source), isNotNull);
      }
    });
  });

  // -------------------------------------------------------------------------
  // Widgets
  // -------------------------------------------------------------------------

  group('widgets', () {
    Widget wrap(Widget child) => MaterialApp(home: child);

    /// Real event-loop windows interleaved with frame pumps: `testWidgets` runs
    /// on a fake clock, so sqflite/file futures parked from that zone only
    /// progress while `runAsync` gives them real time.
    Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('the empty state explains what to do', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const Scaffold(body: GalleryEmptyState())));
      expect(find.byKey(const Key('gallery_empty_state')), findsOneWidget);
      expect(find.textContaining('Paste or drop'), findsOneWidget);
    });

    testWidgets('the offline empty state says so', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(const Scaffold(body: GalleryEmptyState(offline: true))),
      );
      expect(find.textContaining('connect'), findsOneWidget);
    });

    testWidgets('a card shows the title, size and source', (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: SizedBox(
              width: 300,
              height: 260,
              child: GalleryGridCard(
                image: _image(title: 'Shot'),
                onTap: () {},
                onUseAsCanvas: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('gallery_card_img-1')), findsOneWidget);
      expect(find.text('Shot'), findsOneWidget);
      expect(find.textContaining('1920 × 1080'), findsOneWidget);
      expect(find.byKey(const Key('gallery_thumb_placeholder')), findsOneWidget);
    });

    testWidgets('tapping the card previews and the arrow uses it', (WidgetTester tester) async {
      int previews = 0;
      int uses = 0;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: SizedBox(
              width: 300,
              height: 260,
              child: GalleryGridCard(
                image: _image(),
                onTap: () => previews++,
                onUseAsCanvas: () => uses++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('gallery_card_img-1')));
      await tester.tap(find.byKey(const Key('gallery_use_img-1')));
      expect(previews, 1);
      expect(uses, 1);
    });

    testWidgets('the preview dialog names the image and offers the canvas',
        (WidgetTester tester) async {
      int uses = 0;
      await tester.pumpWidget(
        wrap(
          GalleryPreviewDialog(
            image: _image(title: 'Preview me'),
            onUseAsCanvas: () => uses++,
          ),
        ),
      );
      expect(find.byKey(const Key('gallery_preview_dialog')), findsOneWidget);
      expect(find.text('Preview me'), findsOneWidget);
      expect(find.textContaining('1920 × 1080'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gallery_preview_use')));
      expect(uses, 1);
    });

    testWidgets('the save sheet offers Replace and Copy for a library canvas',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: SaveToGallerySheet(
              source: _image(title: 'Origin'),
              canvasTitle: 'Origin',
              sizeLabel: '1920 × 1080',
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('save_to_gallery_replace')), findsOneWidget);
      expect(find.byKey(const Key('save_to_gallery_copy')), findsOneWidget);
      expect(find.textContaining('Overwrite'), findsOneWidget);
    });

    testWidgets('the save sheet hides Replace without a library origin',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: SaveToGallerySheet(
              source: null,
              canvasTitle: 'Fresh',
              sizeLabel: '800 × 600',
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('save_to_gallery_replace')), findsNothing);
      expect(find.byKey(const Key('save_to_gallery_copy')), findsOneWidget);
    });

    testWidgets('tapping Replace resolves the choice', (WidgetTester tester) async {
      GallerySaveChoice? choice;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  choice = await showSaveToGallerySheet(
                    context,
                    source: _image(),
                    canvasTitle: 'x',
                    sizeLabel: '1 × 1',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save_to_gallery_replace')));
      await tester.pumpAndSettle();
      expect(choice, GallerySaveChoice.replace);
    });

    testWidgets('dismissing the sheet cancels, never replaces',
        (WidgetTester tester) async {
      GallerySaveChoice? choice;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  choice = await showSaveToGallerySheet(
                    context,
                    source: _image(),
                    canvasTitle: 'x',
                    sizeLabel: '1 × 1',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10)); // barrier
      await tester.pumpAndSettle();
      expect(choice, GallerySaveChoice.cancel);
    });

    testWidgets('the screen renders the library newest-first',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          GalleryScreen(
            loadImages: () async => <LibraryImage>[
              _image(id: 'old', updatedAt: 10),
              _image(id: 'new', updatedAt: 30),
            ],
            loadBytes: (String id) async => null,
            onUseAsCanvas: (LibraryImage _, String? _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery_grid')), findsOneWidget);
      expect(find.byKey(const Key('gallery_card_new')), findsOneWidget);
      expect(find.byKey(const Key('gallery_card_old')), findsOneWidget);
    });

    testWidgets('an empty library shows the empty state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          GalleryScreen(
            loadImages: () async => const <LibraryImage>[],
            loadBytes: (String id) async => null,
            onUseAsCanvas: (LibraryImage _, String? _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery_empty_state')), findsOneWidget);
    });

    testWidgets('an offline library explains itself and offers a retry',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        wrap(
          GalleryScreen(
            loadImages: () async =>
                throw const GalleryRequestError('Connect to your PC'),
            loadBytes: (String id) async => null,
            onUseAsCanvas: (LibraryImage _, String? _) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery_error')), findsOneWidget);
      expect(find.byKey(const Key('gallery_retry')), findsOneWidget);
    });

    testWidgets('the card arrow hands the image to the shell',
        (WidgetTester tester) async {
      LibraryImage? chosen;
      String? chosenPath;
      await tester.pumpWidget(
        wrap(
          GalleryScreen(
            loadImages: () async => <LibraryImage>[_image()],
            loadBytes: (String id) async => 'C:/tmp/img-1.png',
            onUseAsCanvas: (LibraryImage image, String? path) {
              chosen = image;
              chosenPath = path;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gallery_use_img-1')));
      await tester.pumpAndSettle();
      expect(chosen?.imageId, 'img-1');
      expect(chosenPath, 'C:/tmp/img-1.png');
    });

    testWidgets('a byte-fetch failure still allows the canvas',
        (WidgetTester tester) async {
      LibraryImage? chosen;
      String? chosenPath;
      await tester.pumpWidget(
        wrap(
          GalleryScreen(
            loadImages: () async => <LibraryImage>[_image()],
            loadBytes: (String id) async => throw StateError('nope'),
            onUseAsCanvas: (LibraryImage image, String? path) {
              chosen = image;
              chosenPath = path;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gallery_use_img-1')));
      await tester.pumpAndSettle();
      expect(chosen?.imageId, 'img-1');
      expect(chosenPath, isNull);
    });

    testWidgets('the home dashboard shows the gallery entry point',
        (WidgetTester tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final Directory tmp = Directory('test/.round13_gallery_tmp');
      tmp.createSync(recursive: true);
      // sqflite is REAL I/O: opening it inside the fake test clock would park
      // forever, so it must happen inside a real-event-loop window.
      late final LocalDb db;
      await tester.runAsync(() async {
        db = await LocalDb.open(
          pathOverride:
              '${tmp.path}/entry_${DateTime.now().microsecondsSinceEpoch}.db',
        );
      });
      int opened = 0;
      await tester.pumpWidget(
        wrap(
          HomeCanvasDashboard(
            // The dashboard owns its own DB unless one is injected; passing a
            // real sqflite-ffi file keeps this test honest without a fake.
            db: db,
            baseDir: tmp.path,
            onOpenDocument: (CanvasDocumentModel _) {},
            onOpenGallery: () => opened++,
          ),
        ),
      );
      await flushReal(tester);
      expect(find.byKey(const Key('home-open-gallery')), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-open-gallery')));
      expect(opened, 1);
      await tester.pumpWidget(const SizedBox());
      await flushReal(tester);
      await tester.runAsync(db.close);
      tmp.deleteSync(recursive: true);
    });

    testWidgets('the entry point is absent when not wired',
        (WidgetTester tester) async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final Directory tmp = Directory('test/.round13_gallery_tmp');
      tmp.createSync(recursive: true);
      late final LocalDb db;
      await tester.runAsync(() async {
        db = await LocalDb.open(
          pathOverride:
              '${tmp.path}/absent_${DateTime.now().microsecondsSinceEpoch}.db',
        );
      });
      await tester.pumpWidget(
        wrap(
          HomeCanvasDashboard(
            db: db,
            baseDir: tmp.path,
            onOpenDocument: (CanvasDocumentModel _) {},
          ),
        ),
      );
      await flushReal(tester);
      expect(find.byKey(const Key('home-open-gallery')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await flushReal(tester);
      await tester.runAsync(db.close);
      tmp.deleteSync(recursive: true);
    });
  });

  // -------------------------------------------------------------------------
  // Contract awareness
  // -------------------------------------------------------------------------

  group('contract', () {
    test('the gallery actions used here are the frozen four', () {
      final Set<String> actions = <String>{
        buildGalleryListRequest()['action'] as String,
        buildGalleryAdd(image: _image())['action'] as String,
        buildGallerySave(
          imageId: 'i',
          title: 't',
          width: 1,
          height: 1,
          filename: 'f.png',
          mime: 'image/png',
        )['action'] as String,
        'GALLERY_LIST',
      };
      expect(actions, <String>{
        'GALLERY_LIST_REQUEST',
        'GALLERY_ADD',
        'GALLERY_SAVE',
        'GALLERY_LIST',
      });
    });

    test('the transfer reuses the frozen ASSET actions', () {
      final Set<String> actions = buildAssetTransfer(
        transferId: 't',
        bytes: _bytes(4),
        filename: 't.png',
      ).map((Map<String, dynamic> e) => e['action'] as String).toSet();
      expect(actions, <String>{'ASSET_START', 'ASSET_CHUNK', 'ASSET_DONE'});
    });

    test('the chunk cap matches the frozen transport limit', () {
      expect(kGalleryAssetChunkRawCap, 262144);
    });

    test('the source enum matches the schema enum', () {
      expect(
        GallerySource.values.map(gallerySourceWire).toSet(),
        <String>{'PASTE', 'DROP', 'CANVAS'},
      );
    });

    test('the save mode enum matches the schema enum', () {
      expect(
        GallerySaveMode.values.map(gallerySaveModeWire).toSet(),
        <String>{'REPLACE', 'COPY'},
      );
    });
  });
}
