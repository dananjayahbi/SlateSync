/// Round-6 issue 05/01 (mobile) — destructive flows: stroke-mode eraser and
/// canvas clear.
///
/// * Stroke-mode erase: ONE continuous drag crossing three strokes deletes
///   all three — exactly one `DELETE_NODE` per node (dedupe within the
///   drag), with the hit radius from `ToolConfig.width`.
/// * Precision tap still hit-tests exactly one node (unchanged Doc 24 §4).
/// * `ToolDock.onClearRequested` (§10.7) → page handler: `engine.clearAll()`
///   + a byte-exact `ELEMENT_COMMIT/CLEAR_CANVAS` envelope with payload `{}`.
///   The confirm dialog is dock-owned, so the test drives the callback
///   directly — as the issue instructs.
///
/// The client is a Doc 25 surface fake — no sockets, no `pc_agent`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient({this.connected = false});

  bool connected;

  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];

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
  ) {}

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

const String _canvasId = 'canvas-destructive';
const Rect allWorld = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Destructive',
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
  await tester.pump();
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

/// Straight horizontal stroke: down → two half-steps → up.
Future<void> _stroke(WidgetTester tester, Offset start, Offset by) async {
  final TestGesture g = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(by / 2);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(by / 2);
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _selectStrokeEraser(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('dock-toggle')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('stroke'));
  await tester.pumpAndSettle();
  // Collapse again: the expanded panel overlays the canvas (x ≈ 54–314)
  // and would swallow the erase drag's pointer events.
  await tester.tap(find.byKey(const ValueKey<String>('dock-toggle')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'stroke-mode eraser: one drag across three strokes deletes all three '
      '(exactly 3 DELETE_NODE, dedupe inside the drag)',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client);

    // Three straight strokes on one horizontal band: x ≈ 200–260, 320–380,
    // 440–500 at y = 300 (screen).
    await _stroke(tester, const Offset(200, 300), const Offset(60, 0));
    await _stroke(tester, const Offset(320, 300), const Offset(60, 0));
    await _stroke(tester, const Offset(440, 300), const Offset(60, 0));
    expect(_actions(client, 'ADD_STROKE'), hasLength(3));
    expect(_engine(tester).queryVisible(allWorld), hasLength(3));

    await _selectStrokeEraser(tester);

    // One continuous drag: 11 × 30 px steps from x = 180 → 510. Steps land
    // inside each stroke's bbox (windows ≈ 60 px wide) while the gaps are
    // missed; repeated crossings of the same node must NOT re-delete.
    final TestGesture drag = await tester.startGesture(const Offset(180, 300));
    await tester.pump(const Duration(milliseconds: 16));
    for (int i = 0; i < 11; i++) {
      await drag.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pump(const Duration(milliseconds: 16));

    final List<Map<String, dynamic>> deletes = _actions(client, 'DELETE_NODE');
    expect(deletes, hasLength(3));
    final Set<String> ids = deletes
        .map((Map<String, dynamic> e) => _payload(e)['node_id']! as String)
        .toSet();
    expect(ids, hasLength(3)); // dedupe ⇒ unique victims, count == 3
    expect(_actions(client, 'ADD_STROKE'), hasLength(3)); // erase never commits
    expect(_engine(tester).queryVisible(allWorld), isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets('precision tap still deletes exactly the hit-tested node',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client);

    await _stroke(tester, const Offset(200, 300), const Offset(60, 0));
    expect(_actions(client, 'ADD_STROKE'), hasLength(1));

    // Default eraser mode is precision (fresh ToolConfig).
    await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
    await tester.pumpAndSettle();

    TestGesture tap = await tester.startGesture(const Offset(230, 300));
    await tester.pump(const Duration(milliseconds: 16));
    await tap.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_actions(client, 'DELETE_NODE'), hasLength(1));

    // Second tap on the (now empty) spot adds nothing.
    tap = await tester.startGesture(const Offset(230, 300));
    await tester.pump(const Duration(milliseconds: 16));
    await tap.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(_actions(client, 'DELETE_NODE'), hasLength(1));
    expect(_engine(tester).queryVisible(allWorld), isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets(
      'onClearRequested wipes engine + document and ships a byte-exact '
      'CLEAR_CANVAS envelope; the engine keeps working afterwards',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client);

    await _stroke(tester, const Offset(200, 300), const Offset(60, 0));
    expect(_engine(tester).queryVisible(allWorld), hasLength(1));
    expect(_actions(client, 'CLEAR_CANVAS'), isEmpty);

    // §10.7 — the dock owns the confirm dialog; drive the seeded callback
    // directly, exactly as the issue prescribes.
    final ToolDock dock = tester.widget<ToolDock>(find.byType(ToolDock));
    expect(dock.onClearRequested, isNotNull);
    dock.onClearRequested!();
    await tester.pump();

    expect(_engine(tester).queryVisible(allWorld), isEmpty);
    final List<Map<String, dynamic>> clears = _actions(client, 'CLEAR_CANVAS');
    expect(clears, hasLength(1));
    final Map<String, dynamic> env = clears.single;
    expect(env['type'], 'ELEMENT_COMMIT');
    expect(env['action'], 'CLEAR_CANVAS');
    expect(env['canvas_id'], _canvasId);
    expect(env['payload'], isA<Map<String, dynamic>>());
    expect((env['payload']! as Map).isEmpty, isTrue); // §10.1 EMPTY payload
    expect(env['id'], isA<String>());
    expect(env['timestamp'], isA<int>());

    // clearAll leaves a fully functional engine (Doc 22 §5).
    await _stroke(tester, const Offset(300, 400), const Offset(60, 0));
    expect(_actions(client, 'ADD_STROKE'), hasLength(2));
    expect(_engine(tester).queryVisible(allWorld), hasLength(1));

    await _disposeStudio(tester, client);
  });
}
