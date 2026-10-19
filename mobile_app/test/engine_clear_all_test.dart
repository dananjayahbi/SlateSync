import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Issue R6 — `TiledCanvasEngine.clearAll` contract (Doc 02 §10.1 engine
/// half): wipes index, tile pictures/chunks and dirty state; cache
/// invalidated for all tiles in ONE generation bump with every picture
/// DISPOSED (no leak, no byte growth); subsequent addCommitted / addNode /
/// setDocument work normally; the full setDocument → addNode → clearAll
/// sequence stays coherent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasNodeModel makeStroke(String id, Rect r) => CanvasNodeModel(
        nodeId: id,
        kind: 'STROKE',
        layer: 0,
        bbox: <double>[r.left, r.top, r.right, r.bottom],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 4.0,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(pts: <List<double>>[
          <double>[r.left, r.top],
          <double>[r.right, r.bottom],
        ]),
      );

  CanvasNodeModel makeRect(String id, Rect bbox) => CanvasNodeModel(
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
          pts: <List<double>>[
            <double>[bbox.left, bbox.top],
            <double>[bbox.right, bbox.bottom],
          ],
          shapeType: 'RECT',
        ),
      );

  CanvasNodeModel makeCartGraph() => CanvasNodeModel(
        nodeId: 'cart',
        kind: 'GRAPH_AXES',
        layer: 0,
        bbox: const <double>[150, 250, 650, 750],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 4.0,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(
          pts: const <List<double>>[
            <double>[400, 500],
          ],
          shapeType: 'CARTESIAN_2D',
          graphConfig: <String, dynamic>{
            'origin': <double>[400, 500],
            'x_range': <int>[-10, 10],
            'y_range': <int>[-10, 10],
            'grid_step': 25.0,
            'show_labels': false,
          },
        ),
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

  /// Populate an engine with a doc stroke, a committed stroke (chunk tail)
  /// and an addNode shape/graph (chunk tail) — the full three-way state.
  void populate(TiledCanvasEngine engine) {
    engine.setDocument(makeDoc(<CanvasNodeModel>[
      makeStroke('s1', const Rect.fromLTWH(50, 50, 150, 100)),
    ]));
    engine.addCommitted(_FakeStroke('s2', <double>[600, 600, 800, 750]));
    engine.addNode(makeRect('shape', const Rect.fromLTWH(300, 300, 200, 150)));
  }

  group('TiledCanvasEngine.clearAll', () {
    test('wipes index, tiles, buckets and dirty state; counters sane and '
        'every captured picture disposed', () {
      final TiledCanvasEngine engine = newEngine();
      populate(engine);
      expect(visibleIds(engine),
          containsAll(<String>['s1', 's2', 'shape']));

      final List<ui.Picture> originPictures =
          engine.tilePictures(const TileKey(0, 0));
      expect(originPictures.length, 3); // base + two chunk tails
      final List<ui.Picture> windowPictures =
          engine.tilePictures(const TileKey(2, 2));
      expect(windowPictures, isNotEmpty); // setDocument hot-window tile
      final int bytesBefore = engine.cache.approxBytes();
      expect(bytesBefore, greaterThan(0));
      final int generationBefore = engine.cache.generation;

      engine.clearAll();

      // Index + dirty + bucket state empty.
      expect(engine.queryVisible(world), isEmpty);
      expect(engine.rebakeCount, 0);
      expect(engine.bakedBucketOf(const TileKey(0, 0)), isNull);
      expect(engine.cache.contains(const TileKey(0, 0)), isFalse);
      expect(engine.cache.contains(const TileKey(2, 2)), isFalse);
      // Cache counters sane: one structural bump, zero bytes, empty tails.
      expect(engine.cache.generation, generationBefore + 1);
      expect(engine.cache.approxBytes(), 0);
      expect(engine.cache.maxTailLength(), 0);
      // No leak: base, chunk tails and window pictures are all disposed.
      for (final ui.Picture p in originPictures) {
        expect(p.debugDisposed, isTrue);
      }
      for (final ui.Picture p in windowPictures) {
        expect(p.debugDisposed, isTrue);
      }
    });

    test('re-add works after clearAll: addNode, addCommitted, setDocument',
        () async {
      final TiledCanvasEngine engine = newEngine();
      populate(engine);
      engine.clearAll();
      expect(engine.cache.approxBytes(), 0);

      // addNode on the cleared engine — miss ⇒ synchronous full bake.
      engine.addNode(makeRect('after', const Rect.fromLTWH(100, 100, 200, 160)));
      expect(visibleIds(engine), <String>['after']);
      expect(engine.rebakeCount, 1);
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
      final _Raster shapeInk =
          await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(shapeInk.inkCount, greaterThan(1500));

      // addCommitted lands in the now-warm tile via chunk append.
      engine.addCommitted(_FakeStroke('fresh', <double>[600, 600, 800, 750]));
      expect(visibleIds(engine),
          containsAll(<String>['after', 'fresh']));
      expect(engine.bakeStats.chunkAppends, greaterThanOrEqualTo(1));
      final _Raster both = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(both.inkAt(100, 180), isTrue); // rect edge
      expect(both.inkAt(700, 675), isTrue); // stroke midpoint

      // setDocument replaces the whole index again.
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeStroke('only-doc', const Rect.fromLTWH(50, 50, 150, 100)),
      ]));
      expect(visibleIds(engine), <String>['only-doc']);
      final _Raster docInk =
          await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(docInk.inkAt(125, 100), isTrue);
    });

    test('setDocument → addNode → clearAll sequence stays coherent',
        () async {
      final TiledCanvasEngine engine = newEngine();

      // 1. Document load renders its stroke.
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeStroke('s1', const Rect.fromLTWH(50, 50, 150, 100)),
      ]));
      expect(visibleIds(engine), <String>['s1']);
      final _Raster docInk =
          await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(docInk.inkAt(125, 100), isTrue);

      // 2. addNode coexists with the loaded document — graph axes inked
      //    into the same tile via chunk append.
      engine.addNode(makeCartGraph());
      expect(visibleIds(engine), containsAll(<String>['s1', 'cart']));
      expect(engine.rebakeCount, 1);
      final _Raster both = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(both.inkAt(125, 100), isTrue); // original stroke
      expect(both.inkAt(400, 500), isTrue); // graph origin — both axes
      expect(both.inkCount, greaterThan(6000));

      // 3. clearAll empties everything.
      engine.clearAll();
      expect(engine.queryVisible(world), isEmpty);
      expect(engine.cache.approxBytes(), 0);

      // 4. The engine is fully usable again.
      engine.addNode(makeRect('post', const Rect.fromLTWH(100, 100, 200, 160)));
      expect(visibleIds(engine), <String>['post']);
      final _Raster post = await _rasterOf(engine.getTile(const TileKey(0, 0)));
      expect(post.inkCount, greaterThan(1500));
    });

    test('repeated populate/clearAll cycles never grow the cache (no '
        'picture growth, every retired picture disposed)', () {
      final TiledCanvasEngine engine = newEngine();
      final List<ui.Picture> retired = <ui.Picture>[];
      int? cycleBytes;

      for (int cycle = 0; cycle < 3; cycle++) {
        populate(engine);
        final int bytes = engine.cache.approxBytes();
        retired.addAll(engine.tilePictures(const TileKey(0, 0)));
        cycleBytes ??= bytes;
        expect(bytes, cycleBytes, reason: 'cycle $cycle must not grow');
        engine.clearAll();
        expect(engine.cache.approxBytes(), 0, reason: 'cycle $cycle leaks');
      }

      expect(retired.length, greaterThanOrEqualTo(9)); // ≥3 per cycle
      for (final ui.Picture p in retired) {
        expect(p.debugDisposed, isTrue);
      }
      // Re-add after the final clear still bakes normally.
      final int fullBakes = engine.bakeStats.fullTileBakes;
      engine.addNode(makeRect('last', const Rect.fromLTWH(100, 100, 50, 50)));
      expect(engine.bakeStats.fullTileBakes, fullBakes + 1);
      expect(engine.cache.approxBytes(), greaterThan(0));
    });

    test('clearAll does not disturb camera/viewport state or cumulative '
        'bakeStats (tests snapshot deltas)', () {
      final TiledCanvasEngine engine = newEngine();
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeStroke('s1', const Rect.fromLTWH(50, 50, 150, 100)),
      ]));
      final int fullBakes = engine.bakeStats.fullTileBakes;
      final int replays = engine.bakeStats.strokeReplays;
      expect(fullBakes, greaterThan(0));

      engine.clearAll();

      // Cumulative instrumentation survives (by design).
      expect(engine.bakeStats.fullTileBakes, fullBakes);
      expect(engine.bakeStats.strokeReplays, replays);
      // The viewport hot-window survived: a bucket change backfills the
      // SAME 5×5 window (with empty tiles now), proving `_lastViewport` is
      // preserved while document state stays empty.
      engine.onScaleBucketChanged();
      expect(engine.rebakeCount, 25);
      expect(engine.queryVisible(world), isEmpty);
    });
  });
}

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
