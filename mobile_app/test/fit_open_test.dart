/// Round-6 issue 03 (mobile) — view-fit-on-open, Doc 02 §10.5.
///
/// After the first layout frame the camera zooms to fit:
/// * bounded preset ⇒ target `(0, 0, width, height)`;
/// * infinite with empty `content_bounds` ⇒ fallback `(-500,-500,1000,1000)`;
/// * 48 world units padding per side (`+96` per axis, Doc 20 `zoomToFit`),
///   centred via the §3 transform.
///
/// The assertions work in screen space: the A4 page rect must land inside
/// the viewport and centred on it (±2 px tolerance).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class _FakeSyncClient extends VectorSyncClient {
  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => false;

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
  Future<void> sendRpc(Map<String, dynamic> envelope) async {}

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}

Future<void> _disposeStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}

/// Screen rect of [world] under the page's view matrix
/// (`screen = world·scale + t`, axis-aligned).
Rect _screenRectOf(TiledCanvasView view, Rect world) {
  final List<double> m = view.viewMatrix.storage.toList(growable: false);
  return Rect.fromLTRB(
    m[0] * world.left + m[12],
    m[5] * world.top + m[13],
    m[0] * world.right + m[12],
    m[5] * world.bottom + m[13],
  );
}

void main() {
  testWidgets(
      'A4 document: page rect fits inside the viewport and is centred '
      '±2 px after pumpAndSettle (48u pad)', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasStudioPage(
          document: buildNewCanvasDocument(
            title: 'Fit',
            preset: 'A4',
            background: 'BLANK',
            canvasId: 'canvas-fit',
            now: 1000,
          ),
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final Size vp = tester.getSize(find.byType(TiledCanvasView));
    const Rect page = Rect.fromLTWH(0, 0, 2480, 3508);
    final Rect screen = _screenRectOf(view, page);

    // Fits within the viewport (±2 px) …
    expect(screen.left, greaterThanOrEqualTo(-2));
    expect(screen.top, greaterThanOrEqualTo(-2));
    expect(screen.right, lessThanOrEqualTo(vp.width + 2));
    expect(screen.bottom, lessThanOrEqualTo(vp.height + 2));
    // … and is centred on it (±2 px).
    expect(screen.center.dx, closeTo(vp.width / 2, 2));
    expect(screen.center.dy, closeTo(vp.height / 2, 2));
    // The taller axis pins the scale: (height + 96) of padding.
    expect(
      view.scale,
      closeTo(vp.height / (3508 + 96), 1e-6),
    );

    await _disposeStudio(tester, client);
  });

  testWidgets(
      'INFINITE doc with empty content_bounds fits the (-500,-500,1000,1000) '
      'fallback rect', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasStudioPage(
          document: buildNewCanvasDocument(
            title: 'Infinite',
            preset: 'INFINITE',
            background: 'BLANK',
            canvasId: 'canvas-fit-infinite',
            now: 1000,
          ),
          client: client,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final TiledCanvasView view =
        tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
    final Size vp = tester.getSize(find.byType(TiledCanvasView));
    const Rect fallback = Rect.fromLTWH(-500, -500, 1000, 1000);
    final Rect screen = _screenRectOf(view, fallback);

    expect(screen.left, greaterThanOrEqualTo(-2));
    expect(screen.top, greaterThanOrEqualTo(-2));
    expect(screen.right, lessThanOrEqualTo(vp.width + 2));
    expect(screen.bottom, lessThanOrEqualTo(vp.height + 2));
    expect(screen.center.dx, closeTo(vp.width / 2, 2));
    expect(screen.center.dy, closeTo(vp.height / 2, 2));
    // Square target: the shorter viewport axis pins the scale.
    final double expected = vp.width < vp.height
        ? vp.width / (1000 + 96)
        : vp.height / (1000 + 96);
    expect(view.scale, closeTo(expected, 1e-6));

    await _disposeStudio(tester, client);
  });
}
