/// Issue 05 — "with a lot of lines the mobile app slows down (low memory);
/// we need a more reliable approach."
///
/// Reliability package proofs (all RED/GREEN against the chunked-bake
/// engine in `lib/canvas_engine/`):
///
/// 1. **Bounded rebuilds (§1):** the old dirty-tile rebake re-recorded
///    EVERY stroke in the tile on every commit (quadratic: 1+2+…+500 ≈
///    125 250 stroke records for 500 commits in one tile). Chunked bakes
///    record exactly ONE stroke picture per commit (O(1)) plus an O(K)
///    `drawPicture`-only fold when the tail hits K=32 — asserted
///    `strokeReplays < 3×500` with `fullTileBakes == 0`.
/// 2. **Replay bound (§1):** the painter replays ≤ K+1 pictures per tile.
/// 3. **Memory (§3):** 10 000 commits → cache bytes ≤ cap (LRU eviction
///    engaged), tails ≤ K.
/// 4. **Selective bucket eviction (§3):** `onScaleBucketChanged` evicts
///    non-current zoom buckets wholesale while CURRENT-bucket tiles are
///    retained (a repeat event re-bakes nothing — the old full wipe would
///    re-bake all 25 hot tiles).
/// 5. **Incremental eraser (§2):** `removeCommitted` dirties exactly the
///    affected tiles (1 full-tile record here) instead of a `setDocument`
///    reindex (≥26 bakes for this fixture), and untouched tiles keep their
///    cache entries.
/// 6. **Memory pressure (§4):** engine-level trim to the 64 MB watermark
///    + offscreen invalidation, and the widget-level
///    `WidgetsBindingObserver.didHaveMemoryPressure` wiring through
///    `tester.binding.handleMemoryPressure()`.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tile_chunks.dart';
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes (structural stand-ins; duplicated per test file by design)
// ---------------------------------------------------------------------------

/// Doc 20 camera — engine reads `scale` only.
class _Cam {
  _Cam(this.scale);
  double scale;
}

/// Doc 21 `ProcessedStroke` — engine reads `bbox` + `toRpcPayload()`.
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

/// Doc 25 surface fake — widget tests never touch the network.
class _FakeSyncClient extends VectorSyncClient {
  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];

  @override
  bool get isConnected => false;

  @override
  Stream<SyncEvent> get events => const Stream<SyncEvent>.empty();

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sentRpc.add(envelope);
  }

  @override
  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const Rect _a4Page = Rect.fromLTWH(0, 0, 2480, 3508);

CanvasDocumentModel _a4Doc() => buildNewCanvasDocument(
      title: 'Issue05',
      preset: 'A4',
      background: 'BLANK',
      canvasId: 'issue05-reliability',
      now: 1000,
    );

Future<void> _pumpStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(document: _a4Doc(), client: client),
    ),
  );
  await tester.pump();
}

Future<void> _disposeStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}

CanvasNodeModel _makeNode(String id, Rect r) => CanvasNodeModel(
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

CanvasDocumentModel _docWith(List<CanvasNodeModel> elements) =>
    CanvasDocumentModel(
      canvasId: 'issue05-engine',
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

const Rect _everything = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

// ---------------------------------------------------------------------------
// Page-level drawing helpers (same geometry as the Issue 02 suite)
// ---------------------------------------------------------------------------

/// Fit-to-A4 zoom applied by `_ensureInitialFit` (48-unit padding ⇒ +96).
double _fitScale(Size canvas) => math.min(
      canvas.width / (_a4Page.width + 96),
      canvas.height / (_a4Page.height + 96),
    );

/// World → GLOBAL pen coordinate for a camera at [scale] centred on the A4
/// page (canvas layer top-left offset included).
Offset _penFor(
  Offset world,
  Size canvas,
  Offset canvasTopLeft,
  double scale,
) =>
    canvasTopLeft +
    Offset(
      (world.dx - _a4Page.center.dx) * scale + canvas.width / 2,
      (world.dy - _a4Page.center.dy) * scale + canvas.height / 2,
    );

ForegroundStrokePainter _foreground(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is ForegroundStrokePainter,
    ),
  );
  return paint.painter! as ForegroundStrokePainter;
}

/// One-finger stroke from [worldA] to [worldB] at camera [scale]; returns
/// the live (pen-down) points. Caller lifts with the returned gesture.
Future<(TestGesture, List<Offset>)> _startWorldDrag(
  WidgetTester tester, {
  required Offset worldA,
  required Offset worldB,
  required Size canvas,
  required Offset canvasTopLeft,
  required double scale,
}) async {
  final Offset a = _penFor(worldA, canvas, canvasTopLeft, scale);
  final Offset delta = _penFor(worldB, canvas, canvasTopLeft, scale) - a;
  final TestGesture g = await tester.startGesture(a);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(delta / 3);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(delta / 3);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(delta - delta / 3 - delta / 3);
  await tester.pump(const Duration(milliseconds: 16));
  return (g, List<Offset>.of(_foreground(tester).points));
}

Future<void> _lift(TestGesture g, WidgetTester tester) async {
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // §1 — chunked bakes: bounded (not quadratic) rebuilds
  // -------------------------------------------------------------------------

  test(
      '500 commits in ONE tile replay < 3×500 strokes '
      '(bounded, not quadratic)', () {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(1.0));
    engine.setDocument(
      _docWith(<CanvasNodeModel>[
        _makeNode('seed', const Rect.fromLTWH(20, 20, 40, 40)),
      ]),
    );
    // Measure only the commit stream (setDocument's bulk bake excluded).
    final int replays0 = engine.bakeStats.strokeReplays;
    final int full0 = engine.bakeStats.fullTileBakes;
    final int appends0 = engine.bakeStats.chunkAppends;
    final int folds0 = engine.bakeStats.consolidations;

    for (int i = 0; i < 500; i++) {
      engine.addCommitted(_FakeStroke('n$i', <double>[30, 30, 90, 70]));
    }

    final int replays = engine.bakeStats.strokeReplays - replays0;
    // Old rebake: commit i re-recorded all i strokes in the tile ⇒
    // 1+2+…+500 ≈ 125 250 (quadratic). Chunked: 1 record/commit + 15 folds
    // that record ONLY drawPicture ops (0 stroke replays) ⇒ < 1500.
    expect(replays, lessThan(3 * 500));
    expect(replays, greaterThanOrEqualTo(500));
    expect(
      engine.bakeStats.fullTileBakes - full0,
      0,
      reason: 'chunk append never re-bakes the whole tile',
    );
    expect(engine.bakeStats.chunkAppends - appends0, 500);
    expect(
      engine.bakeStats.consolidations - folds0,
      15,
      reason: 'tail folds exactly at 32, 64, … 480 (500/32 = 15)',
    );
    expect(
      engine.cache.maxTailLength(),
      lessThanOrEqualTo(TileChunkPolicy.flushThreshold),
      reason: 'tail never exceeds K',
    );
    expect(
      engine.rebakeCount,
      1,
      reason: 'per-op hook: each commit dirties exactly ONE tile',
    );
  });

  test('painter replay list stays ≤ K+1 pictures per tile', () {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(1.0));
    engine.setDocument(
      _docWith(<CanvasNodeModel>[
        _makeNode('seed', const Rect.fromLTWH(10, 10, 30, 30)),
      ]),
    );

    for (int i = 0; i < 31; i++) {
      engine.addCommitted(_FakeStroke('t$i', <double>[100, 100, 140, 140]));
    }
    List<ui.Picture> pictures = engine.tilePictures(const TileKey(0, 0));
    expect(pictures.length, 32, reason: 'base + 31 tail (flush at K=32)');
    expect(
      pictures.length,
      lessThanOrEqualTo(TileChunkPolicy.flushThreshold + 1),
    );

    // Push past the flush point: the tail folds into the base picture and
    // the replay list shrinks again.
    for (int i = 0; i < 10; i++) {
      engine.addCommitted(_FakeStroke('u$i', <double>[200, 200, 240, 240]));
    }
    pictures = engine.tilePictures(const TileKey(0, 0));
    expect(pictures.length, 10, reason: 'base + 9 tail after one fold');
    expect(engine.cache.maxTailLength(), 9);
    expect(engine.bakeStats.consolidations, 1);
    // Replay pictures are all distinct objects (each is a real recording).
    expect(pictures.toSet().length, pictures.length);
  });

  // -------------------------------------------------------------------------
  // §3 — memory: cap, tails, eviction under a 10 000-commit flood
  // -------------------------------------------------------------------------

  test('10 000 addCommitted: bytes ≤ cap, tails ≤ K, LRU eviction works', () {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(1.0));
    engine.setDocument(_docWith(const <CanvasNodeModel>[]));

    for (int i = 0; i < 10000; i++) {
      final int tx = i % 100;
      final int ty = (i ~/ 100) % 100;
      final double x = (tx * 1024 + 300).toDouble();
      final double y = (ty * 1024 + 300).toDouble();
      engine.addCommitted(_FakeStroke('g$i', <double>[x, y, x + 60, y + 60]));
    }

    final int bytes = engine.cache.approxBytes();
    expect(
      bytes,
      lessThanOrEqualTo(engine.cache.maxBytes),
      reason: 'LRU high watermark enforced during the flood',
    );
    // Demand was ≈ 10 000 × 1 MB (bucket-0 base estimate ≈ 10 GB): a
    // bounded cache must have evicted rather than retained it.
    expect(bytes, lessThan(200 * 1048576));
    expect(
      engine.cache.maxTailLength(),
      lessThanOrEqualTo(TileChunkPolicy.flushThreshold),
    );
    // Newest tiles survived as MRU and the get-path still serves them.
    expect(engine.cache.get(const TileKey(99, 99)), isNotNull);
    expect(engine.tilePictures(const TileKey(99, 99)), isNotEmpty);
  });

  test(
      'onScaleBucketChanged evicts non-current buckets wholesale but '
      'keeps current-bucket tiles', () {
    final _Cam cam = _Cam(1.0);
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: cam);
    engine.setDocument(
      _docWith(<CanvasNodeModel>[
        _makeNode('a', const Rect.fromLTWH(10, 10, 50, 50)),
      ]),
    );
    engine.getTile(const TileKey(50, 50)); // far tile baked at bucket 0
    expect(engine.bakedBucketOf(const TileKey(50, 50)), 0);

    cam.scale = 2.0; // bucket +1, factor 2
    engine.onScaleBucketChanged();
    expect(
      engine.cache.contains(const TileKey(50, 50)),
      isFalse,
      reason: 'stale zoom bucket evicted wholesale',
    );
    expect(engine.bakedBucketOf(const TileKey(50, 50)), isNull);
    expect(engine.rebakeCount, 25, reason: 'hot window backfilled at +1');

    // A repeat event at the SAME bucket must be a no-op: current-bucket
    // tiles are retained (the old invalidateAll wiped + re-baked all 25).
    engine.onScaleBucketChanged();
    expect(
      engine.rebakeCount,
      0,
      reason: 'current-bucket tiles survive — zero re-bakes',
    );
    expect(engine.cache.contains(const TileKey(0, 0)), isTrue);
  });

  // -------------------------------------------------------------------------
  // §2 — incremental eraser
  // -------------------------------------------------------------------------

  test('removeCommitted dirties only affected tiles — no full reindex', () {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(1.0));
    engine.setDocument(
      _docWith(<CanvasNodeModel>[
        _makeNode('victim', const Rect.fromLTWH(30, 30, 40, 40)), // tile (0,0)
        _makeNode('keep', const Rect.fromLTWH(200, 200, 50, 50)), // (0,0)
        _makeNode('far1', const Rect.fromLTWH(5000, 5000, 60, 60)), // (4,4)
        _makeNode('far2', const Rect.fromLTWH(9500, 1500, 60, 60)), // (9,1)
      ]),
    );
    expect(
      engine.queryVisible(_everything)
          .map((CanvasNodeModel n) => n.nodeId)
          .toList(),
      containsAll(<String>['victim', 'keep', 'far1', 'far2']),
    );

    final int full0 = engine.bakeStats.fullTileBakes;
    final int replays0 = engine.bakeStats.strokeReplays;

    engine.removeCommitted('victim');
    expect(engine.rebakeCount, 1, reason: 'victim touches exactly one tile');
    expect(
      engine.bakeStats.fullTileBakes - full0,
      1,
      reason: 'ONLY the affected tile re-records (setDocument = ≥26 here)',
    );
    expect(
      engine.bakeStats.strokeReplays - replays0,
      1,
      reason: 'tile (0,0) re-records its one SURVIVOR — not the doc\'s 4 '
          'strokes, not the 2 far tiles (no full reindex)',
    );
    expect(
      engine.queryVisible(_everything)
          .map((CanvasNodeModel n) => n.nodeId)
          .toList(),
      allOf(isNot(contains('victim')), containsAll(<String>['keep', 'far1', 'far2'])),
    );

    // Untouched tiles keep their cache entries — no wholesale wipe.
    const TileKey farTile = TileKey(4, 4);
    expect(engine.cache.contains(farTile), isTrue);
    expect(engine.bakedBucketOf(farTile), 0);

    // Unknown ids are no-ops (nothing dirty, nothing rebaked).
    engine.removeCommitted('ghost');
    expect(engine.rebakeCount, 0);
  });

  // -------------------------------------------------------------------------
  // §4 — OS memory pressure
  // -------------------------------------------------------------------------

  test(
      'handleMemoryPressure trims to the 64 MB watermark and drops '
      'offscreen tiles', () {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(1.0));
    engine.setDocument(
      _docWith(<CanvasNodeModel>[
        _makeNode('a', const Rect.fromLTWH(10, 10, 50, 50)),
      ]),
    );
    // Flood the cache with far tiles, then re-promote the hot window back
    // to MRU (the paint order a live page produces).
    for (int i = 0; i < 70; i++) {
      engine.getTile(TileKey(200 + i, 0));
    }
    engine.bakeVisible(const Rect.fromLTWH(0, 0, 2048, 2048));
    expect(
      engine.cache.approxBytes(),
      greaterThan(defaultCachePressureBytes),
      reason: 'setup: >64 MB resident (≈70 far + hot tiles at 1 MB each)',
    );

    engine.handleMemoryPressure();

    expect(
      engine.cache.approxBytes(),
      lessThanOrEqualTo(defaultCachePressureBytes),
      reason: 'aggressive trim to the pressure watermark',
    );
    expect(
      engine.cache.contains(const TileKey(200, 0)),
      isFalse,
      reason: 'offscreen tile invalidated',
    );
    expect(
      engine.cache.contains(const TileKey(0, 0)),
      isTrue,
      reason: 'hot-window tile retained (MRU)',
    );
    expect(engine.rebakeCount, 0, reason: 'pressure trims — it never bakes');
  });

  testWidgets(
      'binding memory pressure → page observer trims the engine cache '
      'and drawing still works', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final TiledCanvasEngine engine = view.engine;

    // Seed a far/offscreen tile and leave a non-zero rebake count behind.
    engine.getTile(const TileKey(50, 50));
    expect(engine.cache.contains(const TileKey(50, 50)), isTrue);
    expect(engine.rebakeCount, greaterThan(0));

    // OS pressure: WidgetsBinding dispatches to the page's
    // WidgetsBindingObserver.didHaveMemoryPressure (synchronously).
    tester.binding.handleMemoryPressure();

    expect(
      engine.rebakeCount,
      0,
      reason: 'didHaveMemoryPressure ran engine.handleMemoryPressure',
    );
    expect(
      engine.cache.contains(const TileKey(50, 50)),
      isFalse,
      reason: 'offscreen tile invalidated under pressure',
    );
    expect(
      engine.cache.approxBytes(),
      lessThanOrEqualTo(defaultCachePressureBytes),
    );

    await tester.pump();

    // The page keeps drawing + committing after pressure.
    final Size canvas = tester.getSize(find.byType(TiledCanvasView));
    final Offset topLeft = tester.getTopLeft(find.byType(TiledCanvasView));
    final (TestGesture g, List<Offset> live) = await _startWorldDrag(
      tester,
      worldA: const Offset(600, 800),
      worldB: const Offset(1400, 900),
      canvas: canvas,
      canvasTopLeft: topLeft,
      scale: _fitScale(canvas),
    );
    await _lift(g, tester);

    expect(live, isNotEmpty, reason: 'foreground still tracks while drawing');
    final List<CanvasNodeModel> strokes = engine
        .queryVisible(_everything)
        .where((CanvasNodeModel n) =>
            n.kind == 'STROKE' && n.bbox.length == 4 && n.bbox[2] >= 1390)
        .toList();
    expect(
      strokes,
      isNotEmpty,
      reason: 'committed stroke renders from the trimmed cache afterwards',
    );
    expect(client.sentRpc, isNotEmpty, reason: 'commit still reaches RPC');

    await _disposeStudio(tester, client);
  });
}
