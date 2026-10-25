/// Round 11 — issue 02: undo/redo must be visible on the PC mirror.
///
/// Round 9 added the buttons and round 10 kept them working locally, but a
/// history step only rewrote `doc.elements`: the tablet rewound while the PC
/// kept showing the pre-undo canvas (round-11 issue 02).
///
/// The frozen wire schema has no document-replace action, so the page now
/// replays the step as a minimal node diff. These tests drive the real
/// `CanvasStudioPage` and assert on what actually leaves the socket.
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

  /// Element commits only — `CANVAS_PUT`/list traffic is not under test here.
  List<Map<String, dynamic>> get commits => sentRpc
      .where((Map<String, dynamic> m) => m['type'] == 'ELEMENT_COMMIT')
      .toList();

  List<String> get actions =>
      commits.map((Map<String, dynamic> m) => '${m['action']}').toList();
}

const String _canvasId = 'canvas-round11';

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Round 11',
      preset: 'A4',
      background: 'BLANK',
      canvasId: _canvasId,
      now: 1000,
    );

Future<void> _pumpStudio(
  WidgetTester tester, {
  required _FakeSyncClient client,
  required String baseDir,
}) async {
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

Future<void> _flushReal(WidgetTester tester, {int rounds = 4}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _pickTool(WidgetTester tester, String toolKey) async {
  await tester.tap(find.byKey(ValueKey<String>(toolKey)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _dragShape(WidgetTester tester) async {
  final TestGesture g = await tester.startGesture(const Offset(300, 300));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveTo(const Offset(430, 400));
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.round11_studio_tmp');
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

  group('issue 02 — a history step reaches the mirror', () {
    testWidgets('undoing a shape sends DELETE_NODE for it',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-rect');
      await _dragShape(tester);
      await _flushReal(tester);

      final List<String> beforeUndo = client.actions;
      expect(beforeUndo, contains('ADD_SHAPE'));

      client.sentRpc.clear();
      await tester.tap(find.byKey(const ValueKey<String>('studio-undo')));
      await tester.pump();
      await _flushReal(tester);

      expect(client.actions, <String>['DELETE_NODE'],
          reason: 'the shape the undo removed must be deleted on the PC');
      expect(
        client.commits.single['payload'],
        containsPair('node_id', isA<String>()),
      );
      expect(client.commits.single['canvas_id'], _canvasId);

      await _disposeStudio(tester, client);
    });

    testWidgets('redoing re-creates the shape with ADD_SHAPE',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-rect');
      await _dragShape(tester);
      await _flushReal(tester);

      await tester.tap(find.byKey(const ValueKey<String>('studio-undo')));
      await tester.pump();
      await _flushReal(tester);

      client.sentRpc.clear();
      await tester.tap(find.byKey(const ValueKey<String>('studio-redo')));
      await tester.pump();
      await _flushReal(tester);

      expect(client.actions, <String>['ADD_SHAPE']);
      expect(client.commits.single['payload'], containsPair('kind', 'SHAPE'));

      await _disposeStudio(tester, client);
    });

    testWidgets('an undo with nothing to undo sends no RPC',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);
      await _flushReal(tester);

      final IconButton undo = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('studio-undo')),
      );
      expect(undo.onPressed, isNull,
          reason: 'the button is disabled, and a disabled tap is silent');

      await _disposeStudio(tester, client);
    });

    testWidgets('undo then redo of a pen stroke round-trips ADD_STROKE',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-pen');
      final TestGesture pen = await tester.startGesture(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 16));
      for (int i = 1; i <= 5; i++) {
        await pen.moveTo(Offset(200 + i * 20.0, 200 + i * 12.0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pen.up();
      await tester.pump(const Duration(milliseconds: 16));
      await _flushReal(tester);

      client.sentRpc.clear();
      await tester.tap(find.byKey(const ValueKey<String>('studio-undo')));
      await tester.pump();
      await _flushReal(tester);
      expect(client.actions, <String>['DELETE_NODE']);

      client.sentRpc.clear();
      await tester.tap(find.byKey(const ValueKey<String>('studio-redo')));
      await tester.pump();
      await _flushReal(tester);
      expect(client.actions, <String>['ADD_STROKE']);

      await _disposeStudio(tester, client);
    });
  });
}
