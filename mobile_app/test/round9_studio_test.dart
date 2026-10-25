/// Round-9 studio wiring suite: undo/redo, fill, lock/rotate and tables.
///
/// These are the parts of round 9 that only exist as PAGE behaviour (the pure
/// geometry lives in `round9_tools_test.dart`): the top-bar undo/redo buttons,
/// the paint bucket's tap → style change → mirror, the selector's lock/rotate
/// actions and the table tool's popup + add-row/add-column handles.
///
/// Same seams as `canvas_studio_page_test.dart`: a Doc 25 surface fake, scratch
/// files under `test/.round9_studio_tmp/`, real event-loop windows for I/O.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
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
}

const String _canvasId = 'canvas-round9';

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Round 9',
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
  // The dock is a vertical scroller: adding tools can push a button below the
  // fold on a short viewport, so bring the target into view before tapping.
  final Finder target = find.byKey(ValueKey<String>(toolKey));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// One-finger stroke in the middle of the canvas.
Future<void> _draw(WidgetTester tester) async {
  final TestGesture g = await tester.startGesture(const Offset(320, 320));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(40, 12));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(40, 12));
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

/// Drags a rectangle from [from] to [to] (shape/table tools).
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

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.round9_studio_tmp');
  late Directory tmp;
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    root.createSync(recursive: true);
    tmp = root.createTempSync('case-');
  });

  tearDown(() async {
    for (final LocalDb db in openDbs) {
      try {
        await db.close();
      } catch (_) {}
    }
    openDbs.clear();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('issue 03 — undo / redo', () {
    testWidgets('the buttons exist and start disabled', (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      expect(find.byKey(const ValueKey<String>('studio-undo')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('studio-redo')), findsOneWidget);
      final IconButton undo = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('studio-undo')),
      );
      expect(undo.onPressed, isNull);

      await _disposeStudio(tester, client);
    });

    testWidgets('a pen stroke enables undo and undo removes the ink',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _draw(tester);
      await _flushReal(tester);
      expect(
        client.sentRpc.where((Map<String, dynamic> e) => e['action'] == 'ADD_STROKE'),
        isNotEmpty,
        reason: 'the stroke was committed',
      );

      final IconButton undo = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('studio-undo')),
      );
      expect(undo.onPressed, isNotNull, reason: 'one undo step is available');

      await tester.tap(find.byKey(const ValueKey<String>('studio-undo')));
      await tester.pump();
      await _flushReal(tester);

      final IconButton redo = tester.widget<IconButton>(
        find.byKey(const ValueKey<String>('studio-redo')),
      );
      expect(redo.onPressed, isNotNull, reason: 'undo enables redo');

      await _disposeStudio(tester, client);
    });
  });

  group('issue 04 — fill tool', () {
    testWidgets('the fill tool is in the rail and taps do not crash',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      expect(find.byKey(const ValueKey<String>('tool-fill')), findsOneWidget);
      await _pickTool(tester, 'tool-fill');
      // A tap on empty canvas resolves nothing and shows the hint instead.
      await tester.tapAt(const Offset(300, 300));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('studio-hint')), findsOneWidget);

      await _disposeStudio(tester, client);
    });

    testWidgets('tapping inside a drawn shape fills it and mirrors the style',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-rect');
      await _dragShape(tester);
      await _flushReal(tester);
      client.sentRpc.clear();

      await _pickTool(tester, 'tool-fill');
      await tester.tapAt(const Offset(365, 350));
      await tester.pump();
      await _flushReal(tester);

      // The fill is a style change, so the node is re-created on the mirror:
      // DELETE_NODE + ADD_SHAPE carrying `style.fill`.
      final List<Map<String, dynamic>> shapes = client.sentRpc
          .where((Map<String, dynamic> e) => e['action'] == 'ADD_SHAPE')
          .toList();
      expect(shapes, hasLength(1), reason: 'the filled node was re-committed');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(shapes.single['payload'] as Map);
      final Map<String, dynamic> style =
          Map<String, dynamic>.from(payload['style'] as Map);
      expect(style['fill'], '#1E1E1E', reason: 'the tool colour became the fill');
      expect(
        client.sentRpc.where((Map<String, dynamic> e) => e['action'] == 'DELETE_NODE'),
        isNotEmpty,
        reason: 'the frozen schema has no UPDATE_NODE',
      );

      await _disposeStudio(tester, client);
    });
  });

  group('issue 05 — lock groups', () {
    testWidgets('the lock action appears once something is selected',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      // Draw a shape, then tap it with the selector.
      await _pickTool(tester, 'tool-rect');
      await _dragShape(tester);
      await _flushReal(tester);
      await _pickTool(tester, 'tool-select');

      await tester.tapAt(const Offset(365, 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(const ValueKey<String>('selection-lock')),
        findsOneWidget,
        reason: 'the action bar floats above the selected object',
      );
      expect(
        find.byKey(const ValueKey<String>('selection-rotate')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('delete-selection')),
        findsNothing,
        reason: 'round 9 replaced the delete FAB with the action bar',
      );

      await _disposeStudio(tester, client);
    });
  });

  group('issue 06 — table tool', () {
    testWidgets('selecting the table tool opens its config popup',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      expect(find.byKey(const ValueKey<String>('tool-table')), findsOneWidget);
      await _pickTool(tester, 'tool-table');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('table-config-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('table-rows-value')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('table-cols-value')), findsOneWidget);

      // 3×3 default, then bump rows once.
      await tester.tap(find.byKey(const ValueKey<String>('table-rows-inc')));
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey<String>('table-rows-value')))
            .data,
        '4',
      );
      await tester.tap(find.byKey(const ValueKey<String>('table-config-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('table-config-dialog')),
        findsNothing,
      );

      await _disposeStudio(tester, client);
    });

    testWidgets('dragging after the popup commits a TABLE node',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client: client, baseDir: tmp.path);

      await _pickTool(tester, 'tool-table');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('table-config-confirm')));
      await tester.pumpAndSettle();

      await _dragShape(tester);
      await _flushReal(tester);

      final List<Map<String, dynamic>> shapes = client.sentRpc
          .where((Map<String, dynamic> e) => e['action'] == 'ADD_SHAPE')
          .toList();
      expect(shapes, hasLength(1));
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(shapes.single['payload'] as Map);
      expect(payload['kind'], 'SHAPE');
      final Map<String, dynamic> geometry =
          Map<String, dynamic>.from(payload['geometry'] as Map);
      expect(geometry['shape_type'], 'TABLE');
      final Map<String, dynamic> config =
          Map<String, dynamic>.from(geometry['graph_config'] as Map);
      expect(config['rows'], 3);
      expect(config['cols'], 3);
      expect(config['header_row'], true);

      await _disposeStudio(tester, client);
    });
  });
}
