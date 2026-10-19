/// Round-6 issue 05 (mobile) — image tool end-to-end.
///
/// Selecting the image tool and TAPPING the canvas opens the page-owned
/// Gallery / Camera popup; a completed pick places an IMAGE node centred at
/// the tap (600-unit long-side planner matching Doc 24's dock math) after
/// streaming `ASSET_START → ASSET_CHUNK* → ASSET_DONE` (≤262144 raw bytes
/// per chunk, base64) and finally `ADD_IMAGE`. Tapping outside the popup
/// cancels with no side effects.
///
/// The picker is injected (never a real platform plugin) and the client is
/// a Doc 25 surface fake.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/canvas/image_source_popup.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

class _FakeSyncClient extends VectorSyncClient {
  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];

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
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sentRpc.add(Map<String, dynamic>.from(envelope));
  }

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _canvasId = 'canvas-image';
const Rect allWorld = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Images',
      preset: 'A4',
      background: 'BLANK',
      canvasId: _canvasId,
      now: 1000,
    );

Future<void> _pumpStudio(
  WidgetTester tester, {
  required _FakeSyncClient client,
  required ImageSourcePickFn pick,
}) async {
  // Taller surface so the 11th dock rail button (image) is on-screen.
  tester.view.physicalSize = const Size(800, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(
        document: _doc(),
        client: client,
        pickImageFromSource: pick,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _disposeStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}

Future<void> _openImagePopup(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('tool-image')));
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(400, 350)); // canvas tap
  await tester.pumpAndSettle();
}

Map<String, dynamic> _payload(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload']! as Map);

/// World point under a GLOBAL [screen] position: gestures deliver
/// canvas-layer-local coordinates to the page (the layer sits below the
/// AppBar + banner), so the layer origin is removed first. The math then
/// mirrors `CameraController.screenToWorld` (same operation order ⇒
/// bit-close).
Offset _worldOf(WidgetTester tester, Offset screen) {
  final TiledCanvasView view =
      tester.widget<TiledCanvasView>(find.byType(TiledCanvasView));
  final Size vp = tester.getSize(find.byType(TiledCanvasView));
  final Offset origin = tester.getTopLeft(find.byType(TiledCanvasView));
  final Offset local = screen - origin;
  final List<double> m = view.viewMatrix.storage.toList(growable: false);
  final double s = m[0];
  final Offset center =
      Offset((vp.width / 2 - m[12]) / s, (vp.height / 2 - m[13]) / s);
  return (local - Offset(vp.width / 2, vp.height / 2)) / s + center;
}

void main() {
  testWidgets(
      'image tool tap opens a popup with Gallery and Camera; tapping '
      'outside cancels with no picker call and no envelopes',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    final List<ImageSource> sources = <ImageSource>[];
    await _pumpStudio(
      tester,
      client: client,
      pick: (ImageSource s) async {
        sources.add(s);
        return null;
      },
    );

    await _openImagePopup(tester);
    expect(
      find.byKey(const ValueKey<String>('image-source-gallery')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('image-source-camera')),
      findsOneWidget,
    );
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);

    // Tap outside the dialog ⇒ barrier dismissal ⇒ cancel.
    await tester.tapAt(const Offset(770, 770));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('image-source-gallery')),
      findsNothing,
    );
    expect(sources, isEmpty);
    expect(client.sentRpc, isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets(
      'Gallery pick streams ASSET_START/CHUNK*/DONE (≤262144 raw) then '
      'ADD_IMAGE and places the node at the tap',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    final List<ImageSource> sources = <ImageSource>[];
    final Uint8List data = Uint8List(300000); // ⇒ 2 chunks
    await _pumpStudio(
      tester,
      client: client,
      pick: (ImageSource s) async {
        sources.add(s);
        return PickedImage(
          bytes: data,
          filename: 'pic.png',
          widthPx: 200,
          heightPx: 100,
        );
      },
    );

    await _openImagePopup(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('image-source-gallery')),
    );
    await tester.pumpAndSettle();

    expect(sources, <ImageSource>[ImageSource.gallery]);

    // Exact envelope sequence (Doc 02 §8 asset flow → element commit).
    expect(
      client.sentRpc.map((Map<String, dynamic> e) => e['action']).toList(),
      <String>[
        'ASSET_START',
        'ASSET_CHUNK',
        'ASSET_CHUNK',
        'ASSET_DONE',
        'ADD_IMAGE',
      ],
    );
    expect(
      client.sentRpc.take(4).map((Map<String, dynamic> e) => e['type']).toSet(),
      <String>{'ASSET_UPLOAD'},
    );
    expect(client.sentRpc.last['type'], 'ELEMENT_COMMIT');
    expect(client.sentRpc.last['canvas_id'], _canvasId);

    final Map<String, dynamic> start =
        _payload(client.sentRpc[0]); // payload carries the transfer fields
    expect(start['filename'], 'pic.png');
    expect(start['total_chunks'], 2);
    expect(start['size_bytes'], 300000);
    final String transferId = start['transfer_id']! as String;
    expect(transferId, isNotEmpty);

    final Map<String, dynamic> chunk0 = _payload(client.sentRpc[1]);
    final Map<String, dynamic> chunk1 = _payload(client.sentRpc[2]);
    expect(chunk0['transfer_id'], transferId);
    expect(chunk1['transfer_id'], transferId);
    expect(chunk0['index'], 0);
    expect(chunk1['index'], 1);
    final Uint8List raw0 = base64Decode(chunk0['data_b64']! as String);
    final Uint8List raw1 = base64Decode(chunk1['data_b64']! as String);
    expect(raw0, hasLength(262144)); // raw cap per chunk (template §3)
    expect(raw1, hasLength(300000 - 262144));
    expect(
      <int>[...raw0, ...raw1].length,
      300000, // contiguous — index order preserved
    );

    final Map<String, dynamic> done = _payload(client.sentRpc[3]);
    expect(done['transfer_id'], transferId);
    expect(done['total_chunks'], 2);

    // ADD_IMAGE: kind IMAGE, asset_ref, 600-unit long side centred at tap.
    final Map<String, dynamic> payload = _payload(client.sentRpc[4]);
    expect(payload['kind'], 'IMAGE');
    expect(payload['geometry']['asset_ref'], 'assets/pic.png');
    expect(payload['geometry']['pts'], isEmpty);

    final Offset tapWorld = _worldOf(tester, const Offset(400, 350));
    final List<dynamic> bbox = payload['bbox']! as List<dynamic>;
    final double w = (bbox[2] as num).toDouble() - (bbox[0] as num).toDouble();
    final double h = (bbox[3] as num).toDouble() - (bbox[1] as num).toDouble();
    expect(w, closeTo(600, 1e-6)); // 200×100 → long side 600 ⇒ 600×300
    expect(h, closeTo(300, 1e-6));
    expect(
      ((bbox[0] as num).toDouble() + (bbox[2] as num).toDouble()) / 2,
      closeTo(tapWorld.dx, 1e-6),
    );
    expect(
      ((bbox[1] as num).toDouble() + (bbox[3] as num).toDouble()) / 2,
      closeTo(tapWorld.dy, 1e-6),
    );

    // The node is in the engine (locally rendered), same id as the payload.
    final List<CanvasNodeModel> nodes = tester
        .widget<TiledCanvasView>(find.byType(TiledCanvasView))
        .engine
        .queryVisible(allWorld);
    expect(
      nodes.map((CanvasNodeModel n) => n.nodeId),
      contains(payload['node_id']),
    );
    final CanvasNodeModel node =
        nodes.firstWhere((CanvasNodeModel n) => n.nodeId == payload['node_id']);
    expect(node.kind, 'IMAGE');
    expect(node.geometry.assetRef, 'assets/pic.png');

    await _disposeStudio(tester, client);
  });

  testWidgets('Camera choice passes ImageSource.camera to the picker',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    final List<ImageSource> sources = <ImageSource>[];
    await _pumpStudio(
      tester,
      client: client,
      pick: (ImageSource s) async {
        sources.add(s);
        return PickedImage(
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
          filename: 'shot.png',
          widthPx: 50,
          heightPx: 100,
        );
      },
    );

    await _openImagePopup(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('image-source-camera')),
    );
    await tester.pumpAndSettle();

    expect(sources, <ImageSource>[ImageSource.camera]);
    expect(
      client.sentRpc.map((Map<String, dynamic> e) => e['action']).toList(),
      <String>['ASSET_START', 'ASSET_CHUNK', 'ASSET_DONE', 'ADD_IMAGE'],
    );
    final Map<String, dynamic> payload = _payload(client.sentRpc.last);
    expect(payload['kind'], 'IMAGE');
    expect(payload['geometry']['asset_ref'], 'assets/shot.png');
    // 50×100 → long side 600 ⇒ 300×600 at the tap.
    final List<dynamic> bbox = payload['bbox']! as List<dynamic>;
    expect(
      (bbox[2] as num).toDouble() - (bbox[0] as num).toDouble(),
      closeTo(300, 1e-6),
    );
    expect(
      (bbox[3] as num).toDouble() - (bbox[1] as num).toDouble(),
      closeTo(600, 1e-6),
    );

    await _disposeStudio(tester, client);
  });
}
