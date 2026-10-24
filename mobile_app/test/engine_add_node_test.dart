import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_app/canvas_engine/tile_chunks.dart';
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Issue R6 — `TiledCanvasEngine.addNode` contract (Doc 02 §10.3 / Doc 22):
/// per-kind rendering into tiles through the setDocument draw path, culling
/// via `queryVisible`, bounded dirty sets (≤ 4 tiles, no full-cache
/// invalidation), and coexistence with chunked stroke bakes in one tile.
///
/// All ink assertions are byte probes: the tile picture is rasterized to
/// raw RGBA and scanned for alpha ≥ 16.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasNodeModel makeShape(
    String id,
    Rect bbox, {
    required String shapeType,
    List<List<double>>? pts,
  }) =>
      CanvasNodeModel(
        nodeId: id,
        kind: 'SHAPE',
        layer: 0,
        bbox: <double>[bbox.left, bbox.top, bbox.right, bbox.bottom],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 4.0,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(
          pts: pts ??
              <List<double>>[
                <double>[bbox.left, bbox.top],
                <double>[bbox.right, bbox.bottom],
              ],
          shapeType: shapeType,
        ),
      );

  CanvasNodeModel makeGraph(
    String id,
    Rect bbox, {
    required String shapeType,
    required Map<String, dynamic> config,
    required List<List<double>> pts,
  }) =>
      CanvasNodeModel(
        nodeId: id,
        kind: 'GRAPH_AXES',
        layer: 0,
        bbox: <double>[bbox.left, bbox.top, bbox.right, bbox.bottom],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 4.0,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(
          pts: pts,
          shapeType: shapeType,
          graphConfig: config,
        ),
      );

  CanvasNodeModel makeKind(
    String id,
    String kind,
    Rect bbox, {
    required List<List<double>> pts,
    String? assetRef,
  }) =>
      CanvasNodeModel(
        nodeId: id,
        kind: kind,
        layer: 0,
        bbox: <double>[bbox.left, bbox.top, bbox.right, bbox.bottom],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 4.0,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(pts: pts, assetRef: assetRef),
      );

  CanvasDocumentModel makeDoc(List<CanvasNodeModel> elements) =>
      CanvasDocumentModel(
        canvasId: 'doc-1',
        title: 'fixture',
        createdAt: 0,
        updatedAt: 0,
        artboard: Artboard.infinite(),
        contentBounds: <String, double>{
          'min_x': 0,
          'min_y': 0,
          'max_x': 1,
          'max_y': 1,
        },
        elements: elements,
      );

  TiledCanvasEngine newEngine() =>
      TiledCanvasEngine(camera: _FakeCamera(1.0));

  const Rect world = Rect.fromLTWH(-1e7, -1e7, 2e7, 2e7);

  List<String> visibleIds(TiledCanvasEngine engine) => engine
      .queryVisible(world)
      .map((CanvasNodeModel n) => n.nodeId)
      .toList();

  group('TiledCanvasEngine.addNode — per-kind tile rendering (§10.3)', () {
    test('RECT SHAPE: indexed, baked into its tile with outline ink', () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'rect',
        const Rect.fromLTWH(100, 100, 200, 160),
        shapeType: 'RECT',
      ));
      expect(visibleIds(engine), <String>['rect']);
      expect(engine.rebakeCount, 1);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(1500));
      expect(r.inkAt(100, 180), isTrue); // left edge
      expect(r.inkAt(200, 100), isTrue); // top edge
    });

    test('CIRCLE SHAPE: oval ring ink inside the baked tile', () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'circle',
        const Rect.fromLTWH(100, 100, 200, 200),
        shapeType: 'CIRCLE',
      ));
      expect(visibleIds(engine), <String>['circle']);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(1200));
      expect(r.inkAt(200, 100), isTrue); // top of the rim
      expect(r.inkAt(100, 200), isTrue); // left of the rim
      expect(r.inkAt(200, 200), isFalse); // hollow center
    });

    test('TRIANGLE SHAPE: closed path through the first three pts', () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'tri',
        const Rect.fromLTWH(100, 100, 200, 160),
        shapeType: 'TRIANGLE',
        pts: const <List<double>>[
          <double>[100, 260], // bottom-left
          <double>[300, 260], // bottom-right
          <double>[200, 100], // top center
        ],
      ));
      expect(visibleIds(engine), <String>['tri']);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(1200));
      expect(r.inkAt(200, 100), isTrue); // apex
      expect(r.inkAt(200, 260), isTrue); // base
    });

    test('ARROW SHAPE: shaft + PC export head barbs at the tip', () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'arrow',
        const Rect.fromLTWH(100, 100, 300, 200),
        shapeType: 'ARROW',
        pts: const <List<double>>[
          <double>[100, 100],
          <double>[400, 300],
        ],
      ));
      expect(visibleIds(engine), <String>['arrow']);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(800));
      expect(r.inkAt(250, 200), isTrue); // shaft midpoint
      // A point on the upper barb (tip (400,300), head 16 at ang−0.4).
      expect(r.inkAt(392, 298), isTrue);
    });

    test(
        'GRAPH_AXES CARTESIAN_2D: axes through origin, gridlines, ticks '
        'and labels from graph_config', () async {
      final TiledCanvasEngine engine = newEngine();
      // Doc 24 dialog defaults around origin (400, 500): page bbox math
      // x = ox + range·step, y = oy + range·step ⇒ (150,250)-(650,750).
      engine.addNode(makeGraph(
        'cart',
        const Rect.fromLTWH(150, 250, 500, 500),
        shapeType: 'CARTESIAN_2D',
        pts: const <List<double>>[
          <double>[400, 500],
        ],
        config: <String, dynamic>{
          'origin': <double>[400, 500],
          'x_range': <int>[-10, 10],
          'y_range': <int>[-10, 10],
          'grid_step': 25.0,
          'show_labels': true,
        },
      ));
      expect(visibleIds(engine), <String>['cart']);
      expect(engine.rebakeCount, 1);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(8000));
      expect(r.inkAt(400, 500), isTrue); // origin — both axes cross here
      expect(r.inkAt(400, 300), isTrue); // vertical axis
      expect(r.inkAt(150, 500), isTrue); // horizontal axis at x_range end
      expect(r.inkAt(175, 352), isTrue); // off-origin gridline column
    });

    test('GRAPH_AXES NUMBER_LINE: horizontal axis + ticks, straddling '
        'tiles both baked and bounded', () async {
      final TiledCanvasEngine engine = newEngine();
      // Page bbox for range [0, 20] · step 10 ⇒ x [0, 200], y [-60, 60]
      // — straddles the y=0 tile boundary ⇒ exactly 2 dirty tiles.
      engine.addNode(makeGraph(
        'nline',
        const Rect.fromLTWH(0, -60, 200, 120),
        shapeType: 'NUMBER_LINE',
        pts: const <List<double>>[
          <double>[0, 0],
        ],
        config: <String, dynamic>{
          'range': <int>[0, 20],
          'step': 10.0,
          'show_labels': true,
        },
      ));
      expect(visibleIds(engine), <String>['nline']);
      expect(engine.rebakeCount, 2);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster top = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(top.inkCount, greaterThan(300));
      expect(top.inkAt(105, 1), isTrue); // axis (between ticks at 100/110)
      expect(top.inkAt(50, 3), isTrue); // tick below the axis
      final _Raster bottom =
          await _rasterOf(engine.getTile(const TileKey(0, -1)));
      expect(bottom.inkCount, greaterThan(100)); // axis below the boundary
    });

    test('IMAGE: no decodable bytes paints NOTHING (round-8 issue 05)', () async {
      // The bug: an IMAGE node drew a filled bbox rect, so a picked photo
      // never appeared and a missing asset looked like a solid block. Now an
      // unresolved asset paints no ink at all.
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeKind(
        'img',
        'IMAGE',
        const Rect.fromLTWH(100, 100, 300, 200),
        pts: const <List<double>>[],
        assetRef: 'assets/pic.png',
      ));
      expect(visibleIds(engine), <String>['img']);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, 0);
    });

    test('IMAGE: decoded bytes paint inside the bbox', () async {
      final TiledCanvasEngine engine = newEngine();
      // A 4×4 opaque red PNG standing in for a photo.
      engine.assets.resolve('assets/pic.png', await _redPngBytes());
      engine.addNode(makeKind(
        'img',
        'IMAGE',
        const Rect.fromLTWH(100, 100, 300, 200),
        pts: const <List<double>>[],
        assetRef: 'assets/pic.png',
      ));
      // Decoding is async; drive it directly rather than via the bake path.
      engine.assets.ensureDecoded(<String>['assets/pic.png']);
      for (int i = 0; i < 50 && !engine.assets.isReady('assets/pic.png'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.assets.isReady('assets/pic.png'), isTrue);
      engine.invalidateAllTiles();
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(2000));
      expect(r.inkAt(250, 200), isTrue); // centre is painted
    });

    test('LINE: straight first→last segment, intermediate anchors ignored',
        () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeKind(
        'line',
        'LINE',
        const Rect.fromLTWH(100, 100, 400, 300),
        pts: const <List<double>>[
          <double>[100, 100],
          <double>[300, 400], // non-collinear middle anchor — must NOT ink
          <double>[500, 100],
        ],
      ));
      expect(visibleIds(engine), <String>['line']);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkCount, greaterThan(800));
      expect(r.inkAt(300, 100), isTrue); // on the straight chord
      expect(r.inkAt(300, 400), isFalse); // polyline vertex absent
    });
  });

  group('TiledCanvasEngine.addNode — dirty set & cache discipline', () {
    test('bbox crossing one boundary per axis bakes exactly 4 tiles', () {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'cross',
        const Rect.fromLTWH(1000, 1000, 100, 100),
        shapeType: 'RECT',
      ));
      expect(engine.rebakeCount, 4);
      expect(engine.bakeStats.fullTileBakes, 4);
      expect(engine.cache.contains(const TileKey(1, 1)), isTrue);
    });

    test('warm current-bucket tile: chunk-append, no full bake, untouched '
        'tiles keep picture identity (no full-cache invalidation)', () {
      final TiledCanvasEngine engine = newEngine();
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeKind(
          'stroke-doc',
          'STROKE',
          const Rect.fromLTWH(50, 50, 150, 100),
          pts: const <List<double>>[
            <double>[50, 50],
            <double>[200, 150],
          ],
        ),
      ]));
      final ui.Picture far = engine.getTile(const TileKey(9, 9));
      expect(engine.cache.contains(const TileKey(9, 9)), isTrue);
      final int fullBakes = engine.bakeStats.fullTileBakes;
      final int appends = engine.bakeStats.chunkAppends;

      engine.addNode(makeShape(
        'warm-rect',
        const Rect.fromLTWH(600, 600, 200, 200),
        shapeType: 'RECT',
      ));
      expect(engine.rebakeCount, 1);
      expect(engine.bakeStats.fullTileBakes, fullBakes); // no full bake
      expect(engine.bakeStats.chunkAppends, appends + 1); // O(1) append
      expect(engine.cache.maxTailLength(), 1);
      // The far tile was neither invalidated nor re-baked.
      expect(identical(engine.getTile(const TileKey(9, 9)), far), isTrue);
    });

    test('addNode reuses setDocument ink: same draw path in one tile',
        () async {
      // The identical node baked by setDocument and by addNode on a fresh
      // engine must produce the same ink footprint in the same tile.
      final CanvasNodeModel shape = makeShape(
        'same',
        const Rect.fromLTWH(100, 100, 200, 160),
        shapeType: 'RECT',
      );
      final TiledCanvasEngine docEngine = newEngine();
      docEngine.setDocument(makeDoc(<CanvasNodeModel>[shape]));
      final _Raster viaDoc =
          await _rasterOf(docEngine.getTile(const TileKey(0, 0)));

      final TiledCanvasEngine addEngine = newEngine();
      addEngine.addNode(shape);
      final _Raster viaAdd =
          await _rasterOf(addEngine.getTile(const TileKey(0, 0)));

      expect(viaAdd.inkCount, greaterThan(1500));
      // Identical recording path ⇒ identical raster footprint.
      expect(viaAdd.inkCount, viaDoc.inkCount);
    });

    test('replacing an existing nodeId drops the old ink (no ghosts)', () async {
      final TiledCanvasEngine engine = newEngine();
      engine.addNode(makeShape(
        'move',
        const Rect.fromLTWH(100, 100, 200, 200),
        shapeType: 'RECT',
      ));
      expect(
        (await _rasterOf(engine.getTile(const TileKey(0, 0)))).inkCount,
        greaterThan(1200),
      );

      // Same id, new position — fully inside tile (4, 4) (5120 edge).
      engine.addNode(makeShape(
        'move',
        const Rect.fromLTWH(5000, 5000, 100, 100),
        shapeType: 'RECT',
      ));
      expect(visibleIds(engine), <String>['move']); // R-tree replaced
      final _Raster oldTile =
          await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(oldTile.inkCount, 0); // force-rebaked without the node
      final _Raster newTile =
          await _rasterOf(engine.getTile(const TileKey(4, 4)));
      expect(newTile.inkCount, greaterThan(1200)); // ink moved with it
    });
  });

  group('TiledCanvasEngine.addNode — coexistence with chunked stroke bakes',
      () {
    test('a stroke commit and a node commit share one tile via chunk tails',
        () async {
      final TiledCanvasEngine engine = newEngine();
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeKind(
          's1',
          'STROKE',
          const Rect.fromLTWH(50, 50, 150, 100),
          pts: const <List<double>>[
            <double>[50, 50],
            <double>[200, 150],
          ],
        ),
      ]));
      final int fullBakes = engine.bakeStats.fullTileBakes;
      final int appends = engine.bakeStats.chunkAppends;

      // Second stroke lands in the already-baked tile (0,0) — chunk append.
      engine.addCommitted(_FakeStroke('s2', <double>[600, 600, 800, 750]));
      expect(engine.bakeStats.chunkAppends, appends + 1);
      expect(engine.rebakeCount, 1);

      // Then a SHAPE into the same tile — another chunk append, no rebake.
      engine.addNode(makeShape(
        'sh',
        const Rect.fromLTWH(300, 300, 200, 150),
        shapeType: 'RECT',
      ));
      expect(engine.bakeStats.chunkAppends, appends + 2);
      expect(engine.bakeStats.fullTileBakes, fullBakes);
      expect(engine.rebakeCount, 1);
      expect(engine.cache.maxTailLength(), 2);

      // Base + two tail pictures — the painter's replay list stays ≤ K+1.
      final List<ui.Picture> pictures = engine.tilePictures(const TileKey(0, 0));
      expect(pictures.length, 3);

      // All three bodies visible in the ONE tile's combined snapshot.
      final _Raster r = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(r.inkAt(125, 100), isTrue); // setDocument stroke s1
      expect(r.inkAt(700, 675), isTrue); // addCommitted stroke s2
      expect(r.inkAt(300, 375), isTrue); // addNode rectangle edge
      expect(r.inkCount, greaterThan(3500));
    });

    test('many addNode appends consolidate at K=32 without a full-cache '
        'invalidation', () {
      final TiledCanvasEngine engine = newEngine();
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeKind(
          'seed',
          'STROKE',
          const Rect.fromLTWH(50, 50, 150, 100),
          pts: const <List<double>>[
            <double>[50, 50],
            <double>[200, 150],
          ],
        ),
      ]));
      final ui.Picture far = engine.getTile(const TileKey(9, 9));
      final int fullBakes = engine.bakeStats.fullTileBakes;

      for (int i = 0; i < TileChunkPolicy.flushThreshold; i++) {
        engine.addNode(makeShape(
          'bulk-$i',
          Rect.fromLTWH(400.0 + i, 400.0, 10, 10),
          shapeType: 'RECT',
        ));
      }
      expect(engine.bakeStats.consolidations, greaterThanOrEqualTo(1));
      expect(
        engine.cache.maxTailLength(),
        lessThan(TileChunkPolicy.flushThreshold),
      ); // folded back down
      expect(engine.bakeStats.fullTileBakes, fullBakes); // appends only
      expect(identical(engine.getTile(const TileKey(9, 9)), far), isTrue);
      expect(visibleIds(engine).length, 33); // seed stroke + 32 shapes
    });
  });
}

/// `TileChunkPolicy.flushThreshold` (K = 32) is imported from
/// `tile_chunks.dart` above.

class _FakeCamera {
  _FakeCamera(this.scale);

  double scale;
}

class _FakeStroke {
  _FakeStroke(this.nodeId, this.bbox);

  final String nodeId;
  final List<double> bbox;

  Map<String, dynamic> toRpcPayload() => <String, dynamic>{
        'node_id': nodeId,
        'kind': 'STROKE',
        'layer': 0,
        'bbox': bbox,
        'style': <String, dynamic>{
          'color': '#1E1E1E',
          'stroke_width': 4.0,
          'opacity': 1.0,
          'blend_mode': 'SRC_OVER',
        },
        'geometry': <String, dynamic>{
          'pts': <List<double>>[
            <double>[bbox[0], bbox[1]],
            <double>[bbox[2], bbox[3]],
          ],
        },
      };
}

/// One rasterized 1024×1024 tile picture (bucket 0 ⇒ 1 device px per world
/// unit, tile (0,0) ⇒ device = world).
class _Raster {
  _Raster(this.bytes);

  final Uint8List bytes;

  static const int _minAlpha = 16;

  int get inkCount {
    int count = 0;
    for (int i = 3; i < bytes.length; i += 4) {
      if (bytes[i] >= _minAlpha) {
        count++;
      }
    }
    return count;
  }

  bool inkAt(int x, int y) => bytes[(y * 1024 + x) * 4 + 3] >= _minAlpha;
}

/// A 4×4 opaque red PNG — real encoded bytes so the IMAGE branch decodes
/// instead of falling back to "no ink" (round-8 issue 05).
Future<Uint8List> _redPngBytes() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFFCC2222),
  );
  final ui.Image image = await recorder.endRecording().toImage(4, 4);
  final ByteData? png =
      await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
}

Future<_Raster> _rasterOf(ui.Picture picture) async {
  final ui.Image image = await picture.toImage(1024, 1024);
  final ByteData? data =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) {
    fail('toByteData returned null');
  }
  return _Raster(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}
