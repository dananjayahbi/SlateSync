/// Issue 02 — "on A4/Letter the live stroke looks right, but the moment I
/// lift the pen it CAPS THE CONTENT."
///
/// Commit (pen-up) moves the stroke from the unclipped foreground layer into
/// the baked static tile layer. Root cause (proved RED-first by test 1):
/// `_bakeTile` recorded `clipRect(Rect.fromLTWH(0, 0, tileSize, tileSize))`
/// AFTER `scale · translate(−origin)`. A canvas clip rect is expressed in
/// the same USER space the draw coordinates use — and node geometry is
/// WORLD space; `translate/scale` map world→device for drawing *and*
/// clipping equally, so they do NOT re-anchor the clip. Every baked tile was
/// therefore clipped to the FIXED world rect `(0,0,1024,1024)` — the origin
/// tile — regardless of which tile is baked or the zoom bucket. On commit,
/// any stroke content outside world `[0,1024]²` was cut from the static
/// layer (only the part inside survived, "capped" at the 1024 lines), while
/// the live layer (no clip) and the background page painter (separate,
/// unclipped) rendered correctly.
///
/// Required behavior pinned here:
///
/// 1. Engine-level: a tile bake keeps content across its WHOLE world rect —
///    tested on a NON-origin tile (the bug hides on tile (0,0), where the
///    erroneous rect coincides with the tile).
/// 2. Page-level: pump the real [CanvasStudioPage] with an A4 doc, drag a
///    path fully inside the page near the edge (case A) and a path crossing
///    the page boundary (case B); capture the foreground geometry pre-commit
///    and the static-layer raster/cache contents post-commit; the committed
///    path must equal the drawn path (bounds + endpoints, no truncation)
///    and survive zoom.
/// 3. Page-level regression: strokes drawn at fit zoom and at zoom-in
///    buckets must render fully after lift.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

import 'support/recording_canvas.dart';

// ---------------------------------------------------------------------------
// Fake client (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

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

/// A4 at 300 DPI (template §3 preset matrix).
const Rect _a4Page = Rect.fromLTWH(0, 0, 2480, 3508);

CanvasDocumentModel _a4Doc() => buildNewCanvasDocument(
      title: 'Issue02',
      preset: 'A4',
      background: 'BLANK',
      canvasId: 'issue02-clip',
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

/// Structural camera stand-in (engine reads `scale` only).
class _Cam {
  _Cam(this.scale);
  double scale;
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
      canvasId: 'issue02-engine',
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

// ---------------------------------------------------------------------------
// Raster helpers
// ---------------------------------------------------------------------------

/// Rasterizes [picture] (picture device space = q-space of the bake) and
/// returns the ink bounding box in pixel coordinates, or `null` when the
/// picture painted nothing above [minAlpha] coverage.
Future<Rect?> _inkBoundsPx(
  ui.Picture picture,
  int w,
  int h, {
  int minAlpha = 16,
}) async {
  final ui.Image img = await picture.toImage(w, h);
  final ByteData? data =
      await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  img.dispose();
  if (data == null) {
    return null;
  }
  final Uint8List bytes =
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  int minX = w, minY = h, maxX = -1, maxY = -1;
  for (int y = 0; y < h; y++) {
    final int row = y * w * 4;
    for (int x = 0; x < w; x++) {
      if (bytes[row + x * 4 + 3] >= minAlpha) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) {
    return null;
  }
  return Rect.fromLTRB(
    minX.toDouble(),
    minY.toDouble(),
    (maxX + 1).toDouble(),
    (maxY + 1).toDouble(),
  );
}

/// Converts a q-space (record-space) rect of tile [k] baked at [bucket] to
/// world units: `world = origin + q / b`.
Rect _qToWorld(TileKey k, int bucket, Rect q) {
  final double b = bucketFactorForExponent(bucket);
  final Offset origin = k.worldRect.topLeft;
  return Rect.fromLTWH(
    origin.dx + q.left / b,
    origin.dy + q.top / b,
    q.width / b,
    q.height / b,
  );
}

// ---------------------------------------------------------------------------
// Page-level drawing helpers
// ---------------------------------------------------------------------------

/// Fit-to-A4 zoom applied by `_ensureInitialFit` (48-unit padding ⇒ +96).
double _fitScale(Size canvas) => math.min(
      canvas.width / (_a4Page.width + 96),
      canvas.height / (_a4Page.height + 96),
    );

/// World → GLOBAL pen coordinate for a camera at [scale] centred on the A4
/// page. The page converts `e.localPosition` (canvas-local) back through
/// `CameraController.screenToWorld`, so the global point must offset by the
/// canvas layer's top-left.
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

/// Starts a one-finger stroke from [worldA] to [worldB] at camera [scale],
/// pumps the moves, and returns the LIVE (pre-commit, world) points while
/// the pen is still down. Caller lifts with the returned [TestGesture].
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

/// The committed STROKE nodes whose world bbox equals [want] within [tol].
List<CanvasNodeModel> _commitMatching(
  TiledCanvasEngine engine,
  Rect want, {
  double tol = 1e-6,
}) =>
    engine
        .queryVisible(const Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9))
        .where((CanvasNodeModel n) {
          if (n.kind != 'STROKE' || n.bbox.length != 4) {
            return false;
          }
          final Rect got = Rect.fromLTRB(
            n.bbox[0],
            n.bbox[1],
            n.bbox[2],
            n.bbox[3],
          );
          return (got.left - want.left).abs() <= tol &&
              (got.top - want.top).abs() <= tol &&
              (got.right - want.right).abs() <= tol &&
              (got.bottom - want.bottom).abs() <= tol;
        })
        .toList();

Rect _boundsOf(List<Offset> pts) {
  double minX = pts.first.dx;
  double minY = pts.first.dy;
  double maxX = minX;
  double maxY = minY;
  for (final Offset p in pts.skip(1)) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

double _viewScale(WidgetTester tester) =>
    tester.widget<TiledCanvasView>(find.byType(TiledCanvasView)).viewMatrix
        .storage[0];

/// Raster-union of every tile covering [want] in world coords, or `null`
/// when no covering tile painted any ink.
Future<Rect?> _inkUnionWorld(
  TiledCanvasEngine engine,
  Rect want, {
  required int bucket,
}) async {
  final int extent = (tileSize * bucketFactorForExponent(bucket)).round();
  Rect union = Rect.zero;
  bool any = false;
  for (final TileKey k in engine.tilesCovering(want)) {
    final Rect? inkQ = await _inkBoundsPx(engine.getTile(k), extent, extent);
    if (inkQ == null) {
      continue;
    }
    final Rect inkWorld = _qToWorld(k, bucket, inkQ);
    union = any ? union.expandToInclude(inkWorld) : inkWorld;
    any = true;
  }
  return any ? union : null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -------------------------------------------------------------------------
  // 1. Engine root cause: every tile keeps its WHOLE world rect — the bake
  //    clip must be the tile's rect, not the fixed origin-tile rect. (Tile
  //    (2,1) on purpose: on tile (0,0) the buggy rect coincides with the
  //    tile and hides the defect.)
  // -------------------------------------------------------------------------

  test('bake clip follows the tile world rect — non-origin tiles keep '
      'their content', () async {
    final TiledCanvasEngine engine = TiledCanvasEngine(camera: _Cam(2.0));
    expect(engine.currentBucket, 1); // round(log2(2)) ⇒ b = 2
    engine.setDocument(_docWith(<CanvasNodeModel>[
      _makeNode('off-origin', const Rect.fromLTRB(2200, 1300, 2400, 1500)),
    ]));
    const TileKey k21 = TileKey(2, 1);
    final ui.Picture tile = engine.getTile(k21);

    // World (2200…2400, 1300…1500) ⇒ local (152…354, 276…478) ⇒
    // q-space (300…708, 548…956) at b = 2 (incl. half stroke width).
    final Rect? ink = await _inkBoundsPx(tile, 2048, 2048);
    expect(
      ink,
      isNotNull,
      reason: 'baked tile dropped content outside the FIXED world rect '
          '(0,0,tileSize,tileSize) — the clip rect is in world/user space, '
          'so translate(-origin) never re-anchored it',
    );
    expect(ink!.left, lessThan(340));
    expect(ink.top, lessThan(590));
    expect(ink.right, greaterThan(660));
    expect(ink.bottom, greaterThan(912));

    // Sanity: the origin tile keeps its content too (bug hides there).
    final TiledCanvasEngine e2 = TiledCanvasEngine(camera: _Cam(2.0));
    e2.setDocument(_docWith(<CanvasNodeModel>[
      _makeNode('near-origin', const Rect.fromLTRB(100, 100, 200, 200)),
    ]));
    final Rect? near =
        await _inkBoundsPx(e2.getTile(const TileKey(0, 0)), 2048, 2048);
    expect(near, isNotNull);
    expect(near!.left, lessThan(220));
    expect(near.right, greaterThan(180));
  });

  // -------------------------------------------------------------------------
  // 2. Page level: near-edge (inside) + boundary-crossing commits at fit
  //    zoom, plus survival across a zoom step.
  // -------------------------------------------------------------------------

  testWidgets(
      'A4 page: strokes near and across the boundary commit unclipped '
      'and survive zoom', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final TiledCanvasEngine engine = view.engine;
    final Size canvas = tester.getSize(find.byType(TiledCanvasView));
    final Offset canvasTopLeft =
        tester.getTopLeft(find.byType(TiledCanvasView));
    final double fit = _fitScale(canvas);

    // --- Case A: fully inside the page, near the right edge ---------------
    const Offset a0 = Offset(2200, 1754);
    const Offset a1 = Offset(2368, 1754);
    const Rect wantA = Rect.fromLTRB(2200, 1754, 2368, 1754);
    expect(wantA.right, lessThan(_a4Page.right)); // inside page
    expect(_a4Page.right - wantA.right, lessThan(300)); // near edge

    final (TestGesture aDrag, List<Offset> liveA) = await _startWorldDrag(
      tester,
      worldA: a0,
      worldB: a1,
      canvas: canvas,
      canvasTopLeft: canvasTopLeft,
      scale: fit,
    );
    // Foreground spy: in-flight path is non-empty, starts at the raw first
    // point and never exceeds the drawn segment.
    expect(liveA, hasLength(greaterThan(1)));
    expect(liveA.first.dx, closeTo(a0.dx, 1e-6));
    expect(liveA.first.dy, closeTo(a0.dy, 1e-6));
    expect(_boundsOf(liveA).left, greaterThanOrEqualTo(wantA.left - 1e-6));
    expect(_boundsOf(liveA).right, lessThanOrEqualTo(wantA.right + 1e-6));
    await _lift(aDrag, tester);

    List<CanvasNodeModel> matches = _commitMatching(engine, wantA);
    expect(matches, hasLength(1),
        reason: 'committed node must carry the drawn path bounds exactly');
    final CanvasNodeModel nodeA = matches.single;
    final List<List<double>> ptsA = nodeA.geometry.pts;
    expect(ptsA, hasLength(greaterThanOrEqualTo(2)));
    // Endpoints preserved exactly (Doc 21 pins terminals to the raw input).
    expect(ptsA.first[0], closeTo(a0.dx, 1e-6));
    expect(ptsA.first[1], closeTo(a0.dy, 1e-6));
    expect(ptsA.last[0], closeTo(a1.dx, 1e-6));
    expect(ptsA.last[1], closeTo(a1.dy, 1e-6));
    // Commit covers the whole pre-commit live path — no truncation.
    final Rect liveBounds = _boundsOf(liveA);
    expect(liveBounds.left, greaterThanOrEqualTo(wantA.left - 1e-6));
    expect(liveBounds.right, lessThanOrEqualTo(wantA.right + 1e-6));
    // Every covering tile is baked/cached (static layer can replay it).
    for (final TileKey k in engine.tilesCovering(wantA)) {
      expect(engine.cache.contains(k), isTrue, reason: 'tile $k cached');
      expect(engine.bakedBucketOf(k), isNotNull, reason: 'tile $k baked');
    }

    // --- Case B: crosses the page boundary (content outside the page must
    //     persist — the page is a guide, never a clip) ---------------------
    const Offset b0 = Offset(2200, 1754);
    const Offset b1 = Offset(2642, 1754);
    const Rect wantB = Rect.fromLTRB(2200, 1754, 2642, 1754);
    expect(wantB.right, greaterThan(_a4Page.right)); // crosses!

    final (TestGesture bDrag, List<Offset> liveB) = await _startWorldDrag(
      tester,
      worldA: b0,
      worldB: b1,
      canvas: canvas,
      canvasTopLeft: canvasTopLeft,
      scale: fit,
    );
    expect(_boundsOf(liveB).right, greaterThanOrEqualTo(b0.dx));
    await _lift(bDrag, tester);

    matches = _commitMatching(engine, wantB);
    expect(matches, hasLength(1));
    final CanvasNodeModel nodeB = matches.single;
    expect(nodeB.bbox[2], greaterThan(_a4Page.right),
        reason: 'committed content beyond the page must never be clipped');

    // Static-layer spy: the tiled painter replays baked pictures.
    final CustomPaint staticWidget = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter is StaticTilePainter,
      ),
    );
    final RecordingCanvas staticSpy = RecordingCanvas();
    (staticWidget.painter! as StaticTilePainter)
        .paint(staticSpy, const Size(800, 600));
    expect(staticSpy.didCall('drawPicture'), isTrue);

    // Raster proof at fit zoom: both strokes paint into their tiles (these
    // live outside world [0,1024]² — the region the historic origin-tile
    // clip used to cut away).
    final Rect? fitUnion = await tester.runAsync<Rect?>(
      () => _inkUnionWorld(
        engine,
        wantA,
        bucket: engine.currentBucket,
      ),
    );
    expect(fitUnion, isNotNull,
        reason: 'stroke A missing from the static layer at fit zoom');
    expect(fitUnion!.left, lessThanOrEqualTo(wantA.left + 8));
    expect(fitUnion.right, greaterThanOrEqualTo(wantA.right - 8));

    // --- Survives zoom: step the bucket, both strokes still render --------
    await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-in')));
    await tester.pump();
    final double zoomed = _viewScale(tester);
    expect(bucketExponentForScale(zoomed),
        isNot(bucketExponentForScale(fit)), reason: 'bucket must change');
    expect(
      engine
          .queryVisible(const Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9))
          .where((CanvasNodeModel n) => n.kind == 'STROKE'),
      hasLength(2),
    );
    // Raster proof at the new bucket: ink must span stroke A end to end.
    final Rect? union = await tester.runAsync<Rect?>(
      () => _inkUnionWorld(
        engine,
        wantA,
        bucket: engine.currentBucket,
      ),
    );
    expect(union, isNotNull, reason: 'stroke vanished from the static layer');
    expect(union!.left, lessThanOrEqualTo(wantA.left + 4));
    expect(union.right, greaterThanOrEqualTo(wantA.right - 4));
    expect(union.top, lessThanOrEqualTo(wantA.top + 4));
    expect(union.bottom, greaterThanOrEqualTo(wantA.bottom - 4));

    await _disposeStudio(tester, client);
  });

  // -------------------------------------------------------------------------
  // 3. Page-level Issue 02 regression: drawing while zoomed into a zoom-in
  //    bucket must render fully the moment the pen lifts.
  // -------------------------------------------------------------------------

  testWidgets(
      'A4 page: stroke drawn at zoom-in bucket renders fully after lift',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final TiledCanvasEngine engine = view.engine;
    final Size canvas = tester.getSize(find.byType(TiledCanvasView));
    final Offset canvasTopLeft =
        tester.getTopLeft(find.byType(TiledCanvasView));

    // Zoom into bucket ≥ 1 (scale ≥ √2): tap zoom-in until b = 2^k, k ≥ 1.
    int taps = 0;
    while (_viewScale(tester) < 1.45 && taps < 16) {
      await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-in')));
      await tester.pump();
      taps++;
    }
    final double scale = _viewScale(tester);
    expect(scale, greaterThanOrEqualTo(1.4));
    expect(engine.currentBucket, greaterThanOrEqualTo(1));

    // Draw a short horizontal stroke around the viewport centre — the page
    // centre (1240, 1754) sits in tile (1,1), far outside the fixed
    // origin-tile clip rect the buggy bake used.
    const Offset w0 = Offset(1240, 1754);
    const Offset w1 = Offset(1300, 1754);
    const Rect want = Rect.fromLTRB(1240, 1754, 1300, 1754);
    final (TestGesture drag, List<Offset> live) = await _startWorldDrag(
      tester,
      worldA: w0,
      worldB: w1,
      canvas: canvas,
      canvasTopLeft: canvasTopLeft,
      scale: scale,
    );
    expect(live, hasLength(greaterThan(1)));
    await _lift(drag, tester);

    // Index-level: the node is committed with the drawn bounds.
    final List<CanvasNodeModel> matches = _commitMatching(engine, want);
    expect(matches, hasLength(1));
    final CanvasNodeModel node = matches.single;
    expect(node.geometry.pts.first[0], closeTo(w0.dx, 1e-6));
    expect(node.geometry.pts.last[0], closeTo(w1.dx, 1e-6));

    // Raster-level (THE regression assertion): the static tile pictures must
    // actually paint the full stroke — pre-fix the bake clipped everything
    // outside the fixed world rect (0,0,1024,1024).
    expect(engine.currentBucket, greaterThanOrEqualTo(1));
    final Rect? union = await tester.runAsync<Rect?>(
      () => _inkUnionWorld(
        engine,
        want,
        bucket: engine.currentBucket,
      ),
    );
    expect(
      union,
      isNotNull,
      reason: 'committed stroke is missing from the static layer entirely '
          '(bake clip cut it to the origin-tile world rect)',
    );
    // Full coverage: painted bounds must span the drawn path.
    expect(union!.left, lessThanOrEqualTo(want.left + 4),
        reason: 'stroke left end truncated after commit');
    expect(union.right, greaterThanOrEqualTo(want.right - 4),
        reason: 'stroke right end truncated after commit');
    expect(union.top, lessThanOrEqualTo(want.top + 4),
        reason: 'stroke top truncated after commit');
    expect(union.bottom, greaterThanOrEqualTo(want.bottom - 4),
        reason: 'stroke bottom truncated after commit');

    // Zoom back out — the stroke must survive (bucket change rebakes it).
    await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-fit')));
    await tester.pump();
    expect(
      engine
          .queryVisible(const Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9))
          .where((CanvasNodeModel n) => n.kind == 'STROKE'),
      hasLength(1),
    );
    final Rect? fitInk = await tester.runAsync<Rect?>(
      () => _inkUnionWorld(
        engine,
        want,
        bucket: engine.currentBucket,
      ),
    );
    expect(fitInk, isNotNull, reason: 'stroke lost after zooming back out');
    expect(fitInk!.left, lessThanOrEqualTo(want.left + 8));
    expect(fitInk.right, greaterThanOrEqualTo(want.right - 8));

    await _disposeStudio(tester, client);
  });
}
