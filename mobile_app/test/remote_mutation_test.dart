/// Round-6 (Doc 02 §10.2) — live mutation relay, mobile receive side.
///
/// The page subscribes to `client.events` `rpcReceived`: envelopes whose
/// `canvas_id` equals the OPEN document are applied locally (node add /
/// delete / wipe / artboard upgrade); everything else is ignored silently.
/// The server excludes the original sender from the relay, but the applier
/// still guards self-echoes (duplicate node ids are not re-applied).
///
/// The client is a Doc 25 surface fake with an `emit` seam standing in for
/// the server relay — no sockets, no `pc_agent`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 25 surface + server-relay seam)
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

  /// Server relay: what `WsStreamServer.broadcast_json` (excluding the
  /// sender) would deliver to this device.
  void emit(Map<String, dynamic> msg) =>
      _ctrl.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: msg));

  @override
  Future<void> dispose() async {
    await _ctrl.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _canvasId = 'canvas-remote';
const Rect allWorld = Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9);

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Remote',
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

TiledCanvasEngine _engine(WidgetTester tester) =>
    tester.widget<TiledCanvasView>(find.byType(TiledCanvasView)).engine;

Set<String> _ids(WidgetTester tester) => _engine(tester)
    .queryVisible(allWorld)
    .map((CanvasNodeModel n) => n.nodeId)
    .toSet();

Map<String, dynamic> _shapeEnvelope({
  required String nodeId,
  String canvasId = _canvasId,
  String action = 'ADD_SHAPE',
}) =>
    <String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': action,
      'canvas_id': canvasId,
      'payload': <String, dynamic>{
        'node_id': nodeId,
        'kind': 'SHAPE',
        'layer': 0,
        'bbox': <double>[100, 100, 300, 260],
        'style': <String, dynamic>{
          'color': '#1E1E1E',
          'stroke_width': 2.5,
          'opacity': 1.0,
          'blend_mode': 'SRC_OVER',
        },
        'geometry': <String, dynamic>{
          'pts': <List<double>>[
            <double>[100, 100],
            <double>[300, 260],
          ],
          'shape_type': 'RECT',
          'graph_config': null,
          'asset_ref': null,
        },
      },
    };

Future<void> _drawStroke(WidgetTester tester) async {
  final TestGesture g = await tester.startGesture(const Offset(300, 300));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(30, 10));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(30, 20));
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets('foreign ADD_SHAPE for the open canvas appears in the engine '
      '(no rebroadcast from the device)',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    expect(_ids(tester), isEmpty);

    client.emit(_shapeEnvelope(nodeId: 'peer-shape'));
    await tester.pump();

    expect(_ids(tester), <String>{'peer-shape'});
    final CanvasNodeModel node =
        _engine(tester).queryVisible(allWorld).single;
    expect(node.kind, 'SHAPE');
    expect(node.geometry.shapeType, 'RECT');
    expect(node.bbox, <double>[100, 100, 300, 260]);
    expect(client.sentRpc, isEmpty); // receive-only: no echo/rebroadcast

    await _disposeStudio(tester, client);
  });

  testWidgets('a different canvas_id is ignored silently',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    client.emit(_shapeEnvelope(nodeId: 'other-canvas', canvasId: 'someone-else'));
    await tester.pump();
    expect(_ids(tester), isEmpty);
    expect(client.sentRpc, isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets('DELETE_NODE from a peer removes the node locally',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    client.emit(_shapeEnvelope(nodeId: 'peer-shape'));
    await tester.pump();
    expect(_ids(tester), <String>{'peer-shape'});

    client.emit(<String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': 'DELETE_NODE',
      'canvas_id': _canvasId,
      'payload': <String, dynamic>{'node_id': 'peer-shape'},
    });
    await tester.pump();
    expect(_ids(tester), isEmpty);

    // Deleting an unknown id (double relay) changes nothing.
    client.emit(<String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': 'DELETE_NODE',
      'canvas_id': _canvasId,
      'payload': <String, dynamic>{'node_id': 'peer-shape'},
    });
    await tester.pump();
    expect(client.sentRpc, isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets('CLEAR_CANVAS from a peer empties the open document',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    client.emit(_shapeEnvelope(nodeId: 'peer-a'));
    client.emit(_shapeEnvelope(nodeId: 'peer-b'));
    await tester.pump();
    expect(_ids(tester).length, 2);

    client.emit(<String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': 'CLEAR_CANVAS',
      'canvas_id': _canvasId,
      'payload': <String, dynamic>{},
    });
    await tester.pump();
    expect(_ids(tester), isEmpty);
    expect(client.sentRpc, isEmpty); // never re-sent to the hub

    await _disposeStudio(tester, client);
  });

  testWidgets('self-echo guard: a relayed duplicate of a local node is not '
      'applied twice', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    await _drawStroke(tester);
    expect(_actionsOf(client, 'ADD_STROKE'), hasLength(1));
    final Map<String, dynamic> localPayload = Map<String, dynamic>.from(
      _actionsOf(client, 'ADD_STROKE').single['payload']! as Map,
    );
    expect(_ids(tester), hasLength(1));

    // A misbehaving relay echoes OUR OWN commit back — must be a no-op.
    client.emit(<String, dynamic>{
      'type': 'ELEMENT_COMMIT',
      'action': 'ADD_STROKE',
      'canvas_id': _canvasId,
      'payload': localPayload,
    });
    await tester.pump();
    expect(_ids(tester), hasLength(1));

    await _disposeStudio(tester, client);
  });

  testWidgets('ARTBOARD_RESIZE/UPGRADE_SIZE applies only for the open canvas',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    expect(find.text('A4'), findsOneWidget);

    client.emit(<String, dynamic>{
      'type': 'ARTBOARD_RESIZE',
      'action': 'UPGRADE_SIZE',
      'canvas_id': 'someone-else',
      'payload': <String, dynamic>{'preset': 'LETTER'},
    });
    await tester.pump();
    expect(find.text('A4'), findsOneWidget); // ignored
    expect(find.text('Letter'), findsNothing);

    client.emit(<String, dynamic>{
      'type': 'ARTBOARD_RESIZE',
      'action': 'UPGRADE_SIZE',
      'canvas_id': _canvasId,
      'payload': <String, dynamic>{'preset': 'LETTER'},
    });
    await tester.pumpAndSettle();
    expect(find.text('Letter'), findsOneWidget); // applied → top-bar chip
    expect(find.text('A4'), findsNothing);

    await _disposeStudio(tester, client);
  });
}

List<Map<String, dynamic>> _actionsOf(_FakeSyncClient c, String action) =>
    c.sentRpc.where((Map<String, dynamic> e) => e['action'] == action).toList();
