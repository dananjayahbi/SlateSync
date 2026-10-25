/// Round 12 — issue 04: the Number Line and Cartesian Graph tools "do not work".
///
/// The commit path was never broken: `_onGraphCommitted` builds a valid
/// `GRAPH_AXES` node, `_commitElement` sends `ADD_GRAPH`, and both the tablet
/// painter and the PC mirror render it.
///
/// The real defect was reachability. A graph has no drag-to-draw gesture
/// (`shape_type` is null for both, so the canvas dispatch ignores the drag),
/// and selecting the tool only flipped `StudioTool`. The builder dialog was
/// reachable ONLY through the press-and-hold property panel, so a normal tap
/// looked like a dead button.
///
/// Round 9 already solved exactly this for the table (its config popup opens
/// WITH the tool). These tests pin the same behaviour for the graph tools.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient();

  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];
  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => false;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  void sendLiveFrame(int t, int tool, double a, double b, double c) {}

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sentRpc.add(<String, dynamic>{
      'id': 'fake-${sentRpc.length}',
      'timestamp': 0,
      ...envelope,
    });
  }

  @override
  Future<void> dispose() async => _ctrl.close();

  List<Map<String, dynamic>> actions(String action) => sentRpc
      .where((Map<String, dynamic> m) =>
          m['type'] == 'ELEMENT_COMMIT' && m['action'] == action)
      .toList();
}

const String _canvasId = 'canvas-round12-graph';

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Round 12 graphs',
      preset: 'A4',
      background: 'BLANK',
      canvasId: _canvasId,
      now: 1000,
    );

Future<void> _pumpStudio(WidgetTester tester, _FakeSyncClient client,
    String baseDir) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(
        document: _doc(),
        client: client,
        baseDir: baseDir,
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

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.round12_graph_tmp');
  late Directory tmp;

  setUp(() {
    root.createSync(recursive: true);
    tmp = root.createTempSync('case-');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  testWidgets('a plain TAP on Cartesian Graph opens the builder dialog',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client, tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('tool-cartesianGraph')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('graph-confirm')),
      findsOneWidget,
      reason: 'selecting the tool must open its builder — a tap used to do '
          'nothing, which is what the user reported as "not working"',
    );

    await _disposeStudio(tester, client);
  });

  testWidgets('a plain TAP on Number Line opens the builder dialog',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client, tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('tool-numberLine')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('graph-confirm')), findsOneWidget);

    await _disposeStudio(tester, client);
  });

  testWidgets('confirming from a tap commits exactly one ADD_GRAPH',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client, tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('tool-cartesianGraph')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
    await tester.pumpAndSettle();

    final List<Map<String, dynamic>> commits = client.actions('ADD_GRAPH');
    expect(commits, hasLength(1));
    final Map<String, dynamic> payload =
        Map<String, dynamic>.from(commits.single['payload']! as Map);
    expect(payload['kind'], 'GRAPH_AXES');
    final Map<String, dynamic> geometry =
        Map<String, dynamic>.from(payload['geometry']! as Map);
    expect(geometry['shape_type'], 'CARTESIAN_2D');
    expect(geometry['graph_config'], isA<Map>());

    await _disposeStudio(tester, client);
  });

  testWidgets('cancelling the builder commits nothing',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client, tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('tool-cartesianGraph')));
    await tester.pumpAndSettle();

    final Finder cancel = find.byKey(const ValueKey<String>('graph-cancel'));
    if (cancel.evaluate().isNotEmpty) {
      await tester.tap(cancel);
      await tester.pumpAndSettle();
    }
    expect(client.actions('ADD_GRAPH'), isEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets('a non-graph tool does NOT pop a dialog on tap',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client, tmp.path);

    await tester.tap(find.byKey(const ValueKey<String>('tool-pen')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('graph-confirm')), findsNothing,
        reason: 'the pen draws by dragging; it must not open a modal');

    await _disposeStudio(tester, client);
  });
}
