import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

import 'support/recording_canvas.dart';

/// Doc 22 §6 acceptance: tile key math (incl. negatives), LRU eviction order
/// + byte cap, R-tree query ≡ brute force on random fixtures, dirty-set ≤ 4
/// rebakes per commit, and a Picture bake/replay smoke test.
void main() {
  ui.Picture emptyPicture() {
    final ui.PictureRecorder rec = ui.PictureRecorder();
    // Constructing the Canvas starts the recording; a no-op draw keeps the
    // display list non-empty.
    ui.Canvas(rec).drawRect(Rect.zero, ui.Paint());
    return rec.endRecording();
  }

  Rect rectOf(CanvasNodeModel n) =>
      Rect.fromLTRB(n.bbox[0], n.bbox[1], n.bbox[2], n.bbox[3]);

  CanvasNodeModel makeNode(String id, Rect r, {int layer = 0}) =>
      CanvasNodeModel(
        nodeId: id,
        kind: 'STROKE',
        layer: layer,
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

  Set<String> bruteForce(List<CanvasNodeModel> nodes, Rect q) => nodes
      .where((CanvasNodeModel n) => rectOf(n).overlaps(q))
      .map((CanvasNodeModel n) => n.nodeId)
      .toSet();

  Rect randomRect(Random rnd) => Rect.fromLTWH(
        -6000 + rnd.nextDouble() * 12000,
        -6000 + rnd.nextDouble() * 12000,
        1 + rnd.nextDouble() * 600,
        1 + rnd.nextDouble() * 600,
      );

  List<CanvasNodeModel> randomNodes(int count, Random rnd) =>
      List<CanvasNodeModel>.generate(
          count, (int i) => makeNode('n$i', randomRect(rnd)));

  group('TileKey math', () {
    test('forPoint buckets edges and negatives (floor semantics)', () {
      expect(TileKey.forPoint(0, 0), const TileKey(0, 0));
      expect(TileKey.forPoint(1023.9, 1023.9), const TileKey(0, 0));
      expect(TileKey.forPoint(1024, 1024), const TileKey(1, 1));
      expect(TileKey.forPoint(1024, 0), const TileKey(1, 0));
      expect(TileKey.forPoint(-1, -1), const TileKey(-1, -1));
      expect(TileKey.forPoint(-1024, -1024), const TileKey(-1, -1));
      expect(TileKey.forPoint(-1025, 0), const TileKey(-2, 0));
      expect(TileKey.forPoint(-500, 500), const TileKey(-1, 0));
      expect(TileKey.forPoint(2047.999, -0.001), const TileKey(1, -1));
    });

    test('worldRect adjacency is exact', () {
      const TileKey origin = TileKey(0, 0);
      expect(origin.worldRect, const Rect.fromLTWH(0, 0, 1024, 1024));
      expect(const TileKey(-1, -1).worldRect,
          const Rect.fromLTWH(-1024, -1024, 1024, 1024));
      expect(const TileKey(1, 0).worldRect.left, origin.worldRect.right);
      expect(const TileKey(-1, 0).worldRect.right, origin.worldRect.left);
      expect(const TileKey(0, -1).worldRect.bottom, origin.worldRect.top);
      expect(const TileKey(0, 1).worldRect.top, origin.worldRect.bottom);
    });

    test('value equality + hashCode', () {
      expect(const TileKey(2, -3), const TileKey(2, -3));
      expect(const TileKey(2, -3).hashCode, const TileKey(2, -3).hashCode);
      expect(const TileKey(2, -3) == const TileKey(3, -2), isFalse);
    });
  });

  group('zoom bucket', () {
    test('bucket exponent k = round(log2(scale)), factor b = 2^k', () {
      expect(bucketExponentForScale(1.0), 0);
      expect(bucketExponentForScale(2.0), 1);
      expect(bucketExponentForScale(4.0), 2);
      expect(bucketExponentForScale(3.0), 2);
      expect(bucketExponentForScale(0.5), -1);
      expect(bucketExponentForScale(0.7), -1);
      expect(bucketExponentForScale(0.25), -2);
      expect(bucketExponentForScale(20.0), 4);
      expect(bucketExponentForScale(0.05), -4);
      expect(bucketFactorForExponent(0), 1.0);
      expect(bucketFactorForExponent(1), 2.0);
      expect(bucketFactorForExponent(-2), 0.25);
      expect(bucketFactorForExponent(3), 8.0);
    });
  });

  group('TileCache LRU + byte budget', () {
    test('put/get roundtrip keeps the identical picture', () {
      final TileCache cache = TileCache();
      final ui.Picture p = emptyPicture();
      cache.put(const TileKey(0, 0), p);
      expect(cache.approxBytes(), 1048576);
      expect(identical(cache.get(const TileKey(0, 0)), p), isTrue);
      expect(cache.get(const TileKey(9, 9)), isNull);
      expect(cache.contains(const TileKey(0, 0)), isTrue);
    });

    test('overflow evicts LRU-first down to the 96 MB hysteresis floor',
        () {
      final TileCache cache = TileCache();
      for (int i = 0; i < 120; i++) {
        cache.put(TileKey(i, 0), emptyPicture());
      }
      expect(cache.approxBytes(), 120 * 1048576);
      // get promotes the oldest entry to MRU
      expect(cache.get(const TileKey(0, 0)), isNotNull);
      cache.put(const TileKey(120, 0), emptyPicture());
      // 121 MB > 120 MB cap ⇒ evict oldest until <= 96 MB (25 entries)
      expect(cache.approxBytes(), 96 * 1048576);
      expect(cache.get(const TileKey(0, 0)), isNotNull); // promotion held
      expect(cache.get(const TileKey(1, 0)), isNull); // oldest evicted first
      expect(cache.get(const TileKey(25, 0)), isNull);
      expect(cache.get(const TileKey(26, 0)), isNotNull);
      expect(cache.get(const TileKey(119, 0)), isNotNull);
      expect(cache.get(const TileKey(120, 0)), isNotNull); // MRU retained
      expect(cache.approxBytes(), 96 * 1048576);
    });

    test('approxBytes follows 1 MB / 4^L per bucket decimation', () {
      expect(TileCache.bytesForBucket(0), 1048576);
      expect(TileCache.bytesForBucket(2), 1048576);
      expect(TileCache.bytesForBucket(-1), 262144);
      expect(TileCache.bytesForBucket(-2), 65536);
      expect(TileCache.bytesForBucket(-4), 4096);
      final TileCache decimated = TileCache()..bucket = -1;
      decimated.put(const TileKey(0, 0), emptyPicture());
      expect(decimated.approxBytes(), 262144);
    });

    test('invalidate drops one tile; invalidateAll resets to 0', () {
      final TileCache cache = TileCache();
      cache.put(const TileKey(0, 0), emptyPicture());
      cache.put(const TileKey(1, 0), emptyPicture());
      expect(cache.approxBytes(), 2 * 1048576);
      cache.invalidate(const TileKey(0, 0));
      expect(cache.get(const TileKey(0, 0)), isNull);
      expect(cache.approxBytes(), 1048576);
      expect(cache.contains(const TileKey(1, 0)), isTrue);
      cache.invalidateAll();
      expect(cache.approxBytes(), 0);
      expect(cache.contains(const TileKey(1, 0)), isFalse);
    });
  });

  group('SpatialRTree vs brute force', () {
    test('incremental insert: 300 random nodes, 40 queries ≡ brute force',
        () {
      final Random rnd = Random(42);
      final List<CanvasNodeModel> nodes = randomNodes(300, rnd);
      final SpatialRTree tree = SpatialRTree();
      for (final CanvasNodeModel n in nodes) {
        tree.insert(n);
      }
      for (int i = 0; i < 40; i++) {
        final Rect q = randomRect(rnd);
        expect(tree.query(q).map((CanvasNodeModel n) => n.nodeId).toSet(),
            bruteForce(nodes, q),
            reason: 'query #$i');
      }
    });

    test('bulkLoad: same fixtures ≡ brute force (order-insensitive)', () {
      final Random rnd = Random(7);
      final List<CanvasNodeModel> nodes = randomNodes(400, rnd);
      final SpatialRTree tree = SpatialRTree()..bulkLoad(nodes);
      for (int i = 0; i < 40; i++) {
        final Rect q = randomRect(rnd);
        expect(tree.query(q).map((CanvasNodeModel n) => n.nodeId).toSet(),
            bruteForce(nodes, q),
            reason: 'bulk query #$i');
      }
    });

    test('remove keeps queries ≡ brute force; unknown id is a no-op', () {
      final Random rnd = Random(11);
      final List<CanvasNodeModel> nodes = randomNodes(300, rnd);
      final List<CanvasNodeModel> remaining =
          List<CanvasNodeModel>.from(nodes);
      final SpatialRTree tree = SpatialRTree();
      for (final CanvasNodeModel n in nodes) {
        tree.insert(n);
      }
      for (int i = 0; i < nodes.length; i += 3) {
        tree.remove(nodes[i].nodeId);
        remaining.remove(nodes[i]);
      }
      tree.remove('does-not-exist'); // no-op, no throw
      for (int i = 0; i < 30; i++) {
        final Rect q = randomRect(rnd);
        expect(tree.query(q).map((CanvasNodeModel n) => n.nodeId).toSet(),
            bruteForce(remaining, q),
            reason: 'post-remove query #$i');
      }
      // drain everything
      for (final CanvasNodeModel n in remaining) {
        tree.remove(n.nodeId);
      }
      expect(tree.query(const Rect.fromLTWH(-1e6, -1e6, 2e6, 2e6)), isEmpty);
    });

    test('duplicate id inserts replace instead of duplicating', () {
      final SpatialRTree tree = SpatialRTree();
      tree.insert(makeNode('dup', const Rect.fromLTWH(0, 0, 100, 100)));
      tree.insert(makeNode('dup', const Rect.fromLTWH(5000, 5000, 50, 50)));
      expect(tree.query(const Rect.fromLTWH(0, 0, 1000, 1000)), isEmpty);
      expect(tree.query(const Rect.fromLTWH(4000, 4000, 2000, 2000)),
          hasLength(1));
    });

    test('edge-touching query rect matches brute force exactly', () {
      final SpatialRTree tree = SpatialRTree();
      final CanvasNodeModel n =
          makeNode('e', const Rect.fromLTWH(1024, 0, 100, 100));
      tree.insert(n);
      // Rect.overlaps is strict: touching edges do not overlap.
      expect(tree.query(const Rect.fromLTWH(924, 0, 100, 100)),
          bruteForce(<CanvasNodeModel>[n], const Rect.fromLTWH(924, 0, 100, 100)));
      expect(tree.query(const Rect.fromLTWH(1124, 0, 10, 10)),
          bruteForce(<CanvasNodeModel>[n], const Rect.fromLTWH(1124, 0, 10, 10)));
      expect(tree.query(const Rect.fromLTWH(1050, 10, 10, 10)),
          hasLength(1));
    });
  });

  group('TiledCanvasEngine', () {
    test('setDocument indexes elements; queryVisible culls + sorts by layer',
        () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('a', const Rect.fromLTWH(10, 10, 90, 50), layer: 2),
        makeNode('b', const Rect.fromLTWH(5000, 5000, 100, 100), layer: 1),
        makeNode('c', const Rect.fromLTWH(50, 50, 20, 20), layer: 0),
      ]));
      expect(
          engine
              .queryVisible(const Rect.fromLTWH(0, 0, 500, 500))
              .map((CanvasNodeModel n) => n.nodeId),
          <String>['c', 'a']);
      expect(
          engine
              .queryVisible(const Rect.fromLTWH(4000, 4000, 2000, 2000))
              .map((CanvasNodeModel n) => n.nodeId),
          <String>['b']);
      expect(engine.queryVisible(const Rect.fromLTWH(-500, -500, 10, 10)),
          isEmpty);
    });

    test('addCommitted indexes the stroke and rebakes only dirty tiles',
        () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('far', const Rect.fromLTWH(9000, 9000, 50, 50)),
      ]));
      // single-tile commit ⇒ 1 rebake
      engine.addCommitted(_FakeStroke('s1', <double>[10, 10, 50, 50]));
      expect(engine.rebakeCount, 1);
      expect(
          engine
              .queryVisible(const Rect.fromLTWH(0, 0, 100, 100))
              .map((CanvasNodeModel n) => n.nodeId),
          contains('s1'));
      // right edge exactly on the tile boundary ⇒ still one tile
      engine.addCommitted(_FakeStroke('s2', <double>[0, 0, 1024, 50]));
      expect(engine.rebakeCount, 1);
      // crosses one boundary on each axis ⇒ exactly 4 tiles (<= 4 bound)
      engine.addCommitted(_FakeStroke('s3', <double>[1000, 1000, 1100, 1100]));
      expect(engine.rebakeCount, 4);
      // crosses only the x boundary ⇒ 2 tiles
      engine.addCommitted(_FakeStroke('s4', <double>[1000, 100, 1100, 200]));
      expect(engine.rebakeCount, 2);
    });

    test('setDocument full pass, then one commit rebakes <= 4 tiles', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('n0', const Rect.fromLTWH(10, 10, 40, 40)),
        makeNode('n1', const Rect.fromLTWH(10000, 10, 40, 40)),
        makeNode('n2', const Rect.fromLTWH(10, 10000, 40, 40)),
        makeNode('n3', const Rect.fromLTWH(10000, 10000, 40, 40)),
        makeNode('n4', const Rect.fromLTWH(5000, 5000, 40, 40)),
        makeNode('n5', const Rect.fromLTWH(-5000, -5000, 40, 40)),
      ]));
      expect(engine.rebakeCount, greaterThan(4)); // full document pass
      engine.addCommitted(
          _FakeStroke('commit', <double>[1000, 1000, 1100, 1100]));
      expect(engine.rebakeCount, 4); // counter reset at op start
      expect(engine.rebakeCount, lessThanOrEqualTo(4));
    });

    test('a commit never evicts tiles outside its bbox range', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('a', const Rect.fromLTWH(10, 10, 50, 50)),
        makeNode('b', const Rect.fromLTWH(9500, 9500, 50, 50)),
      ]));
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
      expect(engine.cache.contains(const TileKey(9, 9)), isTrue);
      engine.addCommitted(
          _FakeStroke('near-b', <double>[9500, 9500, 9600, 9600]));
      expect(engine.rebakeCount, 1);
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
      expect(engine.cache.contains(const TileKey(9, 9)), isTrue);
    });

    test('getTile bakes synchronously on miss, then serves from cache', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      const TileKey k = TileKey(50, 50);
      expect(engine.cache.contains(k), isFalse);
      final ui.Picture first = engine.getTile(k);
      final ui.Picture second = engine.getTile(k);
      expect(engine.cache.contains(k), isTrue);
      expect(identical(first, second), isTrue);
      expect(engine.bakedBucketOf(k), 0);
    });

    test('bakeVisible eagerly bakes the 5×5 hot window', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.bakeVisible(Rect.fromLTWH(
          5 * 1024 + 10, 5 * 1024 + 10, 100, 100)); // center tile (5,5)
      expect(engine.rebakeCount, 25);
      for (int tx = 3; tx <= 7; tx++) {
        for (int ty = 3; ty <= 7; ty++) {
          expect(engine.cache.contains(TileKey(tx, ty)), isTrue,
              reason: 'tile ($tx,$ty)');
        }
      }
      expect(engine.cache.contains(const TileKey(2, 5)), isFalse);
      expect(engine.cache.contains(const TileKey(8, 5)), isFalse);
      // second pass at the same bucket: nothing to rebake
      engine.bakeVisible(Rect.fromLTWH(5 * 1024 + 10, 5 * 1024 + 10, 100, 100));
      expect(engine.rebakeCount, 0);
    });

    test('onScaleBucketChanged re-bakes the hot window at the new bucket',
        () {
      final _FakeCamera cam = _FakeCamera(1.0);
      final TiledCanvasEngine engine = TiledCanvasEngine(camera: cam);
      expect(engine.currentBucket, 0);
      engine.bakeVisible(const Rect.fromLTWH(10, 10, 100, 100));
      expect(engine.bakedBucketOf(const TileKey(0, 0)), 0);
      cam.scale = 4.0;
      expect(engine.currentBucket, 2);
      engine.onScaleBucketChanged();
      expect(engine.bakedBucketOf(const TileKey(0, 0)), 2);
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
      // decimated buckets shrink the retained-byte estimate
      cam.scale = 0.25;
      expect(engine.currentBucket, -2);
      engine.onScaleBucketChanged();
      expect(engine.bakedBucketOf(const TileKey(0, 0)), -2);
      expect(engine.cache.approxBytes(), 25 * 65536);
    });

    test('tilesCovering excludes degenerate right/bottom boundary touches',
        () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      expect(engine.tilesCovering(const Rect.fromLTWH(0, 0, 1024, 1024)),
          <TileKey>{const TileKey(0, 0)});
      expect(
          engine.tilesCovering(const Rect.fromLTWH(1000, 1000, 100, 100)),
          <TileKey>{
            const TileKey(0, 0),
            const TileKey(1, 0),
            const TileKey(0, 1),
            const TileKey(1, 1),
          });
      expect(engine.tilesCovering(const Rect.fromLTWH(-1, -1, 1, 1)),
          <TileKey>{const TileKey(-1, -1)});
      expect(
          engine.tilesCovering(const Rect.fromLTWH(-1025, -1025, 1, 1)),
          <TileKey>{const TileKey(-2, -2)});
    });
  });

  group('Picture bake/replay smoke', () {
    test('baked tile picture replays onto a PictureRecorder canvas', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('s', const Rect.fromLTWH(0, 0, 200, 200)),
      ]));
      final ui.Picture tile = engine.getTile(const TileKey(0, 0));
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas canvas = Canvas(rec);
      canvas.drawPicture(tile);
      final ui.Picture replayed = rec.endRecording();
      expect(replayed, isNotNull);
      // raw record → replay → record again
      final ui.PictureRecorder raw = ui.PictureRecorder();
      final Canvas rawCanvas = Canvas(raw);
      final Paint paint = Paint()..color = const Color(0xFF0000FF);
      rawCanvas.drawCircle(const Offset(10, 10), 5, paint);
      final ui.Picture rawPicture = raw.endRecording();
      final ui.PictureRecorder replay = ui.PictureRecorder();
      Canvas(replay).drawPicture(rawPicture);
      expect(replay.endRecording(), isNotNull);
    });

    test('StaticTilePainter paints tiles onto a recorder canvas', () {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      engine.setDocument(makeDoc(<CanvasNodeModel>[
        makeNode('p', const Rect.fromLTWH(10, 10, 300, 300)),
      ]));
      final StaticTilePainter painter = StaticTilePainter(
        engine: engine,
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
      );
      final ui.PictureRecorder rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), const Size(800, 600));
      expect(rec.endRecording(), isNotNull);
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
      // shouldRepaint compares engine/tile generations captured per painter
      final StaticTilePainter before = StaticTilePainter(
        engine: engine,
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
      );
      expect(painter.shouldRepaint(painter), isFalse);
      expect(before.shouldRepaint(before), isFalse);
      engine.addCommitted(_FakeStroke('gen', <double>[10, 10, 20, 20]));
      final StaticTilePainter after = StaticTilePainter(
        engine: engine,
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
      );
      expect(after.shouldRepaint(before), isTrue);
    });

    test('ForegroundStrokePainter and combined painter smoke', () {
      final ForegroundStrokePainter fg = ForegroundStrokePainter(
        viewMatrix: Matrix4.identity(),
        points: const <Offset>[Offset(0, 0), Offset(50, 50), Offset(90, 20)],
      );
      final ui.PictureRecorder rec = ui.PictureRecorder();
      fg.paint(Canvas(rec), const Size(100, 100));
      expect(rec.endRecording(), isNotNull);
      expect(fg.shouldRepaint(fg), isFalse);

      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      final TiledCanvasPainter combined = TiledCanvasPainter(
        engine: engine,
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        livePoints: const <Offset>[Offset(1, 1), Offset(2, 2)],
      );
      final ui.PictureRecorder rec2 = ui.PictureRecorder();
      combined.paint(Canvas(rec2), const Size(300, 300));
      expect(rec2.endRecording(), isNotNull);
      expect(combined.shouldRepaint(combined), isFalse);
    });

    testWidgets('TiledCanvasView builds the dual RepaintBoundary split',
        (WidgetTester tester) async {
      final TiledCanvasEngine engine =
          TiledCanvasEngine(camera: _FakeCamera(1.0));
      await tester.pumpWidget(TiledCanvasView(
        engine: engine,
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        livePoints: const <Offset>[Offset(10, 10), Offset(20, 20)],
      ));
      expect(find.byType(RepaintBoundary), findsNWidgets(2));
      expect(find.byType(CustomPaint), findsNWidgets(2));
      expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
    });
  });

  group('CanvasBackgroundPainter (Issue 02 light canvas)', () {
    test('bounded BLANK: soft shadow + white fill + 1 px frame, no pattern',
        () {
      final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'BLANK',
      );
      final RecordingCanvas spy = RecordingCanvas();
      painter.paint(spy, const Size(800, 600));

      expect(spy.didCall('drawRect'), isTrue);
      expect(spy.didCall('drawLine'), isFalse); // BLANK draws no pattern
      expect(spy.didCall('drawCircle'), isFalse);
      // White paper fill (default `background_color` #FFFFFF == strokeCanvas).
      expect(
        spy.paintsOf('drawRect').map((Paint p) => p.color.toARGB32()),
        contains(0xFFFFFFFF),
      );
      // Documented feathered drop shadow (bounded presets only).
      expect(
        spy.paintsOf('drawRect').any((Paint p) => p.maskFilter != null),
        isTrue,
      );
      // Subtle light-gray frame, screen-scaled: 1.0 / scale world units.
      final Paint frame = spy.paintsOf('drawRect').singleWhere(
            (Paint p) => p.color.toARGB32() == kPageBorderColor.toARGB32(),
          );
      expect(frame.style, PaintingStyle.stroke);
      expect(frame.strokeWidth, 1.0);
    });

    test('INFINITE: visible-world fill only — no shadow, no frame', () {
      final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 2.0,
        boundary: null,
        style: 'BLANK',
      );
      final RecordingCanvas spy = RecordingCanvas();
      painter.paint(spy, const Size(400, 300));

      expect(spy.paintsOf('drawRect'), hasLength(1)); // fill only
      final Paint fill = spy.paintsOf('drawRect').single;
      expect(fill.maskFilter, isNull);
      expect(fill.color.toARGB32(), 0xFFFFFFFF);
    });

    test('RULED: light-gray world lines every 32 u at ≈1 screen px', () {
      final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 2.0,
        boundary: const Rect.fromLTWH(0, 0, 400, 400),
        style: 'RULED',
      );
      final RecordingCanvas spy = RecordingCanvas();
      painter.paint(spy, const Size(300, 300));

      expect(spy.didCall('drawLine'), isTrue);
      // y ≡ 0 (mod 32) over the page: 0, 32, …, 384 → 13 lines (Doc 08).
      expect(spy.paintsOf('drawLine'), hasLength(13));
      final Paint line = spy.paintsOf('drawLine').first;
      expect(line.color.toARGB32(), kPagePatternColor.toARGB32());
      expect(line.strokeWidth, 0.5); // 1.0 / scale ⇒ 1 device px
    });

    test('SQUARE_GRID: closed cells from both rule families', () {
      final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 96, 96),
        style: kBackgroundSquareGrid,
        spacing: 32,
      );
      final RecordingCanvas spy = RecordingCanvas();
      painter.paint(spy, const Size(200, 200));

      expect(spy.didCall('drawLine'), isTrue);
      // 4 horizontal (0, 32, 64, 96) + 4 vertical over the page.
      expect(spy.paintsOf('drawLine'), hasLength(8));
      expect(
        spy.paintsOf('drawLine').every(
              (Paint p) => p.color.toARGB32() == kPagePatternColor.toARGB32(),
            ),
        isTrue,
      );
    });

    test('spacing changes the number of drawn rules', () {
      int rulesFor(double spacing) {
        final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
          viewMatrix: Matrix4.identity(),
          scale: 1.0,
          boundary: const Rect.fromLTWH(0, 0, 128, 128),
          style: kBackgroundRuled,
          spacing: spacing,
        );
        final RecordingCanvas spy = RecordingCanvas();
        painter.paint(spy, const Size(200, 200));
        return spy.paintsOf('drawLine').length;
      }

      // Denser spacing ⇒ more lines.
      expect(rulesFor(16), greaterThan(rulesFor(64)));
      // A 128 u tall page with 128 u spacing still draws the two edges.
      expect(rulesFor(128), 2);
    });

    test('retired DOT_GRID / ISO_GRID render nothing (round-9 narrowing)', () {
      for (final String retired in <String>['DOT_GRID', 'ISO_GRID']) {
        final CanvasBackgroundPainter painter = CanvasBackgroundPainter(
          viewMatrix: Matrix4.identity(),
          scale: 1.0,
          boundary: const Rect.fromLTWH(0, 0, 96, 96),
          style: retired,
        );
        final RecordingCanvas spy = RecordingCanvas();
        painter.paint(spy, const Size(200, 200));
        expect(spy.didCall('drawLine'), isFalse, reason: retired);
        expect(spy.didCall('drawCircle'), isFalse, reason: retired);
      }
    });

    test('shouldRepaint reacts to camera, page, style and color changes', () {
      final CanvasBackgroundPainter base = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'BLANK',
      );
      expect(base.shouldRepaint(base), isFalse);

      final CanvasBackgroundPainter zoomed = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 2.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'BLANK',
      );
      expect(zoomed.shouldRepaint(base), isTrue);

      final CanvasBackgroundPainter panned = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity()..setTranslationRaw(40, 20, 0),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'BLANK',
      );
      expect(panned.shouldRepaint(base), isTrue);

      final CanvasBackgroundPainter ruled = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'RULED',
      );
      expect(ruled.shouldRepaint(base), isTrue);

      final CanvasBackgroundPainter resized = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 1748, 2480),
        style: 'BLANK',
      );
      expect(resized.shouldRepaint(base), isTrue);

      final CanvasBackgroundPainter spaced = CanvasBackgroundPainter(
        viewMatrix: Matrix4.identity(),
        scale: 1.0,
        boundary: const Rect.fromLTWH(0, 0, 2480, 3508),
        style: 'BLANK',
        spacing: 64,
      );
      expect(spaced.shouldRepaint(base), isTrue);
    });
  });
}

/// Structural stand-in for Doc 20's `CameraController` (engine only reads
/// `scale`) and Doc 21's `ProcessedStroke` (engine only reads `bbox` +
/// `toRpcPayload()`).
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
          'shape_type': null,
          'graph_config': null,
          'asset_ref': null,
        },
      };
}
