/// Round-6 issue 05 (mobile) — shape & graph tools end-to-end.
///
/// Covers the three root causes reported for this issue:
/// * commits (LINE / RECT / CIRCLE / TRIANGLE / ARROW) land in the ENGINE
///   index — not just the document + RPC — so ink survives pen-lift and
///   zoom (the "vanishes on mobile" bug);
/// * `geometry.pts` follows the Doc 02 §10.3 PC conventions
///   (canvas_shape_conventions.dart);
/// * both Graph Builder dialogs produce GRAPH_AXES nodes that render
///   locally and ship `ADD_GRAPH`.
///
/// The client is a Doc 25 surface fake — no sockets, no `pc_agent`.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient({this.connected = false});

  bool connected;

  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];
  final List<List<double>> frames = <List<double>>[];

  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  void sendLiveFrame(
    int frameType,
    int toolId,
    double f1,
    double f2,
    double f3,
  ) {
    frames.add(<double>[frameType.toDouble(), toolId.toDouble(), f1, f2, f3]);
  }

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    final Map<String, dynamic> out = Map<String, dynamic>.from(envelope);
    out.putIfAbsent('id', uuidV4);
    out.putIfAbsent(
      'timestamp',
      () => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    );
    sentRpc.add(out);
  }

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _canvasId = 'canvas-shapes';
const Rect allWorld = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Shapes',
      preset: 'A4',
      background: 'BLANK',
      canvasId: _canvasId,
      now: 1000,
    );

Future<void> _pumpStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(document: _doc(), client: client),
    ),
  );
  await tester.pump(); // frame 2 applies the §10.5 post-frame fit
}

/// Round-8 issue 04: the tool's config panel opens by pressing and holding the
/// rail button for 500 ms (the expandable column and its toggle are gone).
Future<void> _holdTool(WidgetTester tester, String toolKey) async {
  final Finder button = find.byKey(ValueKey<String>(toolKey));
  final TestGesture gesture = await tester.startGesture(tester.getCenter(button));
  await tester.pump(const Duration(milliseconds: 550));
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _disposeStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}

List<Map<String, dynamic>> _actions(_FakeSyncClient c, String action) =>
    c.sentRpc.where((Map<String, dynamic> e) => e['action'] == action).toList();

Map<String, dynamic> _payload(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload']! as Map);

TiledCanvasEngine _engine(WidgetTester tester) =>
    tester.widget<TiledCanvasView>(find.byType(TiledCanvasView)).engine;

CanvasNodeModel _nodeInEngine(WidgetTester tester, String nodeId) {
  final List<CanvasNodeModel> nodes = _engine(tester).queryVisible(allWorld);
  for (final CanvasNodeModel n in nodes) {
    if (n.nodeId == nodeId) {
      return n;
    }
  }
  return fail('node $nodeId missing from the engine index');
}

Rect _rectOf(Object? bbox) {
  final List<dynamic> b = bbox! as List<dynamic>;
  return Rect.fromLTRB(
    (b[0] as num).toDouble(),
    (b[1] as num).toDouble(),
    (b[2] as num).toDouble(),
    (b[3] as num).toDouble(),
  );
}

/// World point under a GLOBAL [screen] position — gestures deliver
/// canvas-layer-local coordinates to the page, so the layer origin is
/// removed first; the rest mirrors `CameraController.screenToWorld`
/// (same operation order ⇒ bit-close).
Offset _worldOf(WidgetTester tester, TiledCanvasView view, Size vp, Offset screen) {
  final Offset origin = tester.getTopLeft(find.byType(TiledCanvasView));
  final Offset local = screen - origin;
  final List<double> m = view.viewMatrix.storage.toList(growable: false);
  final double s = m[0];
  final Offset center =
      Offset((vp.width / 2 - m[12]) / s, (vp.height / 2 - m[13]) / s);
  return (local - Offset(vp.width / 2, vp.height / 2)) / s + center;
}

/// One-finger drag: down → two half-steps → up (decimation/palm safe).
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final TestGesture g = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 16));
  final Offset half = (to - from) / 2;
  await g.moveBy(half);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(half);
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

void _expectPts(Object? actual, List<List<double>> expected) {
  final List<dynamic> pts = actual! as List<dynamic>;
  expect(pts, hasLength(expected.length));
  for (int i = 0; i < expected.length; i++) {
    final List<dynamic> p = pts[i] as List<dynamic>;
    expect(p, hasLength(expected[i].length));
    for (int j = 0; j < expected[i].length; j++) {
      expect(p[j] as num, closeTo(expected[i][j], 1e-6), reason: 'pts[$i][$j]');
    }
  }
}

void _expectBbox(Object? actual, List<double> expected) {
  final List<dynamic> b = actual! as List<dynamic>;
  expect(b, hasLength(4));
  for (int i = 0; i < 4; i++) {
    expect(b[i] as num, closeTo(expected[i], 1e-6), reason: 'bbox[$i]');
  }
}

List<double> _normalizedBbox(Offset a, Offset b) => <double>[
      math.min(a.dx, b.dx),
      math.min(a.dy, b.dy),
      math.max(a.dx, b.dx),
      math.max(a.dy, b.dy),
    ];

/// Ink proof: the tile holding the shape's guaranteed-ink anchor must record
/// strictly more bytes than a far, never-used tile.
void _expectInk(TiledCanvasEngine engine, Offset anchor, Rect nodeRect) {
  final TileKey inked = TileKey.forPoint(anchor.dx, anchor.dy);
  expect(engine.cache.contains(inked), isTrue,
      reason: 'anchor tile must be baked at commit');
  final TileKey far =
      TileKey.forPoint(nodeRect.left + 500000, nodeRect.top + 500000);
  expect(
    engine.getTile(inked).approximateBytesUsed,
    greaterThan(engine.getTile(far).approximateBytesUsed),
  );
}

void main() {
  testWidgets(
      'line drag → lift commits ADD_SHAPE(kind LINE) into the engine, it '
      'stays after zoom, and shapePreview frames mirror the drag',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client);
    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final Size vp = tester.getSize(find.byType(TiledCanvasView));

    await tester.tap(find.byKey(const ValueKey<String>('tool-line')));
    await tester.pumpAndSettle();

    // Horizontal drag ⇒ the 15° snap maps the corner onto itself, so the
    // committed anchors are exactly the two world ends of the segment.
    const Offset from = Offset(250, 350);
    const Offset to = Offset(520, 350);
    await _drag(tester, from, to);

    final List<Map<String, dynamic>> commits = _actions(client, 'ADD_SHAPE');
    expect(commits, hasLength(1));
    final Map<String, dynamic> env = commits.single;
    expect(env['type'], 'ELEMENT_COMMIT');
    expect(env['canvas_id'], _canvasId);
    final Map<String, dynamic> payload = _payload(env);
    expect(payload['kind'], 'LINE');
    expect(payload['geometry']['shape_type'], isNull);

    final Offset w0 = _worldOf(tester, view, vp, from);
    final Offset w1 = _worldOf(tester, view, vp, to);
    _expectPts(payload['geometry']['pts'], <List<double>>[
      <double>[w0.dx, w0.dy],
      <double>[w1.dx, w1.dy],
    ]);
    _expectBbox(payload['bbox'], _normalizedBbox(w0, w1));

    // Root-cause regression: the node is in the ENGINE after pen-lift …
    final CanvasNodeModel node =
        _nodeInEngine(tester, payload['node_id']! as String);
    expect(node.kind, 'LINE');
    _expectInk(_engine(tester), w0, _rectOf(payload['bbox']));

    // … and stays there after zoom.
    await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-in')));
    await tester.pump();
    expect(
      _engine(tester)
          .queryVisible(allWorld)
          .map((CanvasNodeModel n) => n.nodeId),
      contains(payload['node_id']),
    );

    // PC mirror: ToolId.shapePreview (0x04) live point + live end frames.
    expect(
      client.frames.where((List<double> f) => f[0] == 1 && f[1] == 4),
      isNotEmpty,
    );
    expect(client.frames.where((List<double> f) => f[0] == 2), isNotEmpty);

    await _disposeStudio(tester, client);
  });

  group('shape tools commit §10.3 pts conventions', () {
    const Offset from = Offset(300, 300);
    const Offset to = Offset(460, 420);

    Future<void> runShapeCase(
      WidgetTester tester, {
      required String toolKey,
      required String shapeType,
      required List<List<double>> Function(Offset w0, Offset w1) ptsOf,
      required Offset Function(Offset w0, Offset w1) inkAnchor,
    }) async {
      final _FakeSyncClient client = _FakeSyncClient(connected: true);
      await _pumpStudio(tester, client);
      final TiledCanvasView view =
          tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
      final Size vp = tester.getSize(find.byType(TiledCanvasView));

      await tester.tap(find.byKey(ValueKey<String>('tool-$toolKey')));
      await tester.pumpAndSettle();
      await _drag(tester, from, to);

      expect(_actions(client, 'ADD_SHAPE'), hasLength(1));
      final Map<String, dynamic> payload =
          _payload(_actions(client, 'ADD_SHAPE').single);
      expect(payload['kind'], 'SHAPE');
      expect(payload['geometry']['shape_type'], shapeType);

      final Offset w0 = _worldOf(tester, view, vp, from);
      final Offset w1 = _worldOf(tester, view, vp, to);
      _expectPts(payload['geometry']['pts'], ptsOf(w0, w1));
      _expectBbox(payload['bbox'], _normalizedBbox(w0, w1));

      final CanvasNodeModel node =
          _nodeInEngine(tester, payload['node_id']! as String);
      expect(node.kind, 'SHAPE');
      expect(node.geometry.shapeType, shapeType);
      _expectInk(_engine(tester), inkAnchor(w0, w1), _rectOf(payload['bbox']));

      await _disposeStudio(tester, client);
    }

    testWidgets('RECT — pts = [[l,t],[r,b]]', (WidgetTester tester) async {
      await runShapeCase(
        tester,
        toolKey: 'rect',
        shapeType: 'RECT',
        ptsOf: (Offset a, Offset b) => <List<double>>[
          <double>[math.min(a.dx, b.dx), math.min(a.dy, b.dy)],
          <double>[math.max(a.dx, b.dx), math.max(a.dy, b.dy)],
        ],
        // Top-left corner vertex.
        inkAnchor: (Offset a, Offset b) => Offset(
          math.min(a.dx, b.dx),
          math.min(a.dy, b.dy),
        ),
      );
    });

    testWidgets(
        'CIRCLE — bbox convention pts = [] (PC exporters ignore circle pts; '
        'the viewport bbox fallback — see canvas_shape_conventions.dart)',
        (WidgetTester tester) async {
      await runShapeCase(
        tester,
        toolKey: 'circle',
        shapeType: 'CIRCLE',
        ptsOf: (Offset a, Offset b) => const <List<double>>[],
        // Top of the ellipse rim — sits on the node bbox edge.
        inkAnchor: (Offset a, Offset b) => Offset(
          (a.dx + b.dx) / 2,
          math.min(a.dy, b.dy),
        ),
      );
    });

    testWidgets('TRIANGLE — pts = [lb, rb, center-top]',
        (WidgetTester tester) async {
      await runShapeCase(
        tester,
        toolKey: 'triangle',
        shapeType: 'TRIANGLE',
        ptsOf: (Offset a, Offset b) {
          final double l = math.min(a.dx, b.dx);
          final double r = math.max(a.dx, b.dx);
          final double t = math.min(a.dy, b.dy);
          final double bo = math.max(a.dy, b.dy);
          return <List<double>>[
            <double>[l, bo],
            <double>[r, bo],
            <double>[(l + r) / 2, t],
          ];
        },
        // Bottom-left vertex.
        inkAnchor: (Offset a, Offset b) => Offset(
          math.min(a.dx, b.dx),
          math.max(a.dy, b.dy),
        ),
      );
    });

    testWidgets('ARROW — pts = shaft [start, end]',
        (WidgetTester tester) async {
      await runShapeCase(
        tester,
        toolKey: 'arrow',
        shapeType: 'ARROW',
        ptsOf: (Offset a, Offset b) => <List<double>>[
          <double>[a.dx, a.dy],
          <double>[b.dx, b.dy],
        ],
        // Shaft start — round-cap ink.
        inkAnchor: (Offset a, Offset b) => a,
      );
    });
  });

  testWidgets(
      'Cartesian Graph Builder commits GRAPH_AXES + ADD_GRAPH into the engine',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    // Round-12 issue 04: selecting the graph tool opens its builder directly —
    // the press-and-hold → "Open Graph Builder…" detour is gone.
    await tester.tap(find.byKey(const ValueKey<String>('tool-cartesianGraph')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('graph-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
    await tester.pumpAndSettle();

    final List<Map<String, dynamic>> commits = _actions(client, 'ADD_GRAPH');
    expect(commits, hasLength(1));
    final Map<String, dynamic> env = commits.single;
    expect(env['type'], 'ELEMENT_COMMIT');
    expect(env['canvas_id'], _canvasId);
    final Map<String, dynamic> payload = _payload(env);
    expect(payload['kind'], 'GRAPH_AXES');
    expect(payload['geometry']['shape_type'], 'CARTESIAN_2D');
    final Map<String, dynamic> cfg =
        Map<String, dynamic>.from(payload['geometry']['graph_config']! as Map);
    expect(cfg.keys.toSet(), <String>{
      'origin',
      'x_range',
      'y_range',
      'grid_step',
      'show_labels',
    });
    expect((cfg['origin']! as List).cast<num>(), <num>[250.0, 450.0]);
    expect(cfg['grid_step'], 25.0);
    expect(cfg['show_labels'], isTrue);

    // Local render: origin (250,450) — both axes cross there.
    final CanvasNodeModel node =
        _nodeInEngine(tester, payload['node_id']! as String);
    expect(node.kind, 'GRAPH_AXES');
    expect(node.geometry.graphConfig, isNotNull);
    _expectInk(
      _engine(tester),
      const Offset(250, 450),
      _rectOf(payload['bbox']),
    );

    await _disposeStudio(tester, client);
  });

  testWidgets('Number Line Builder commits GRAPH_AXES + ADD_GRAPH into the '
      'engine', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    // Round-12 issue 04: selecting the graph tool opens its builder directly.
    await tester.tap(find.byKey(const ValueKey<String>('tool-numberLine')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
    await tester.pumpAndSettle();

    final List<Map<String, dynamic>> commits = _actions(client, 'ADD_GRAPH');
    expect(commits, hasLength(1));
    final Map<String, dynamic> payload = _payload(commits.single);
    expect(payload['kind'], 'GRAPH_AXES');
    expect(payload['geometry']['shape_type'], 'NUMBER_LINE');
    final Map<String, dynamic> cfg =
        Map<String, dynamic>.from(payload['geometry']['graph_config']! as Map);
    expect(cfg.keys.toSet(), <String>{'range', 'step', 'show_labels'});
    expect((cfg['range']! as List).cast<num>(), <num>[-10, 10]);
    expect(cfg['step'], 1.0);

    final CanvasNodeModel node =
        _nodeInEngine(tester, payload['node_id']! as String);
    expect(node.kind, 'GRAPH_AXES');
    // Axis at y = 0 straddles the default range — ink at (0,0).
    _expectInk(_engine(tester), const Offset(0, 0), _rectOf(payload['bbox']));

    await _disposeStudio(tester, client);
  });
}
