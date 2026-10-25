import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/canvas/selection_overlay.dart';
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

}

const String _canvasId = 'canvas-round10';

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Round 10',
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

Future<void> _flushReal(WidgetTester tester, {int rounds = 6}) async {
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

Future<void> _dragShape(
  WidgetTester tester, {
  Offset from = const Offset(300, 300),
  Offset to = const Offset(430, 400),
}) async {
  final TestGesture g = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveTo(to);
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _lockCurrentShape(WidgetTester tester) async {
  await _pickTool(tester, 'tool-rect');
  await _dragShape(tester);
  await _flushReal(tester);

  await _pickTool(tester, 'tool-select');
  await tester.tapAt(const Offset(365, 350));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byKey(const ValueKey<String>('selection-lock')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.round10_studio_tmp');
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

  group('issue 05 — a locked group blocks every tool', () {
    testWidgets('locking swaps the lock button for an unlock and a badge',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _lockCurrentShape(tester);

      expect(find.byKey(const ValueKey<String>('selection-unlock')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('selection-lock')), findsNothing);
      expect(find.byKey(const ValueKey<String>('group-lock-badge')),
          findsOneWidget);

      await _disposeStudio(tester, client);
    });

    testWidgets('a locked group cannot be deleted',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);
      await _lockCurrentShape(tester);

      final IconButton delete = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('selection-delete')),
      );
      expect(delete.onPressed, isNull,
          reason: 'the delete control is disabled while locked');

      await _disposeStudio(tester, client);
    });

    testWidgets('unlocking restores the delete action',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);
      await _lockCurrentShape(tester);

      await tester.tap(find.byKey(const ValueKey<String>('selection-unlock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final IconButton delete = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('selection-delete')),
      );
      expect(delete.onPressed, isNotNull);

      await _disposeStudio(tester, client);
    });

    testWidgets('a locked shape exposes no resize handles',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-rect');
      await _dragShape(tester);
      await _flushReal(tester);
      await _pickTool(tester, 'tool-select');
      await tester.tapAt(const Offset(365, 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.widget<CanvasSelectionOverlay>(find.byType(CanvasSelectionOverlay)).showHandles,
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey<String>('selection-lock')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.widget<CanvasSelectionOverlay>(find.byType(CanvasSelectionOverlay)).showHandles,
        isFalse,
        reason: 'a locked group must not look resizable',
      );

      await _disposeStudio(tester, client);
    });

    testWidgets('the bucket refuses a locked group instead of filling it',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);
      await _lockCurrentShape(tester);
      client.sentRpc.clear();

      await _pickTool(tester, 'tool-fill');
      await tester.tapAt(const Offset(365, 350));
      await tester.pump();
      await _flushReal(tester);

      final Iterable<Map<String, dynamic>> writes = client.sentRpc.where(
        (Map<String, dynamic> e) =>
            e['action'] == 'DELETE_NODE' || e['action'] == 'ADD_SHAPE',
      );
      expect(writes, isEmpty, reason: 'a locked object is never mutated');
      expect(find.byKey(const ValueKey<String>('studio-hint')), findsOneWidget);

      await _disposeStudio(tester, client);
    });
  });
}
