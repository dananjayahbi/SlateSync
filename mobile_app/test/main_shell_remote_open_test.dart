/// Round-4 (Issue 04) shell suite driving the REAL `SlateSyncApp` from
/// `lib/main.dart` with an injected fake [VectorSyncClient] (seam added for
/// tests; `const SlateSyncApp()` keeps its old no-arg shape):
///
///  * simulated remote `OPEN_CANVAS {payload.canvas}` (§8.2) makes the
///    shell navigate — through the `navigatorKey`, never `Navigator.of`
///    from a context above `MaterialApp` — to [CanvasStudioPage] showing
///    that document's title, without echoing the open back to the PC
///  * a local create pushes `CANVAS_LIST` (dashboard `onListChanged` →
///    `bridge.publishList`, §8.1) and a local open broadcasts
///    `OPEN_CANVAS {canvas: <full doc>}` (§8.3.1) — the PC follows
///
/// Mocking mirrors `open_canvas_regression_test.dart`: path_provider via a
/// mock MethodChannel, sqflite via `sqflite_common_ffi`. All scratch state
/// lives under `test/.main_shell_remote_open_tmp/` (never `/tmp`) and is
/// removed in `tearDownAll`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'
    show HomeCanvasDashboard, buildNewCanvasDocument;
import 'package:mobile_app/main.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake client (records sends; injects incoming SyncEvents)
// ---------------------------------------------------------------------------

class _FakeClient extends VectorSyncClient {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final StreamController<SyncEvent> _controller =
      StreamController<SyncEvent>.broadcast();

  @override
  Stream<SyncEvent> get events => _controller.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sent.add(envelope);
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void emitRpc(Map<String, dynamic> msg) =>
      _controller.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: msg));
}

List<Map<String, dynamic>> _actionsOf(_FakeClient client, String action) =>
    client.sent
        .where((Map<String, dynamic> e) => e['action'] == action)
        .toList(growable: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmpRoot;
  late String dbBasePath;

  setUpAll(() async {
    tmpRoot = Directory(
      'test/.main_shell_remote_open_tmp/'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    tmpRoot.createSync(recursive: true);
    // Isolate this file's `LocalDb.open()` default path: `flutter test`
    // runs test files in parallel, and `open_canvas_regression_test.dart`
    // also uses the default `slatesync.db` — sharing it would race.
    dbBasePath = '${tmpRoot.path}/databases';
    Directory(dbBasePath).createSync(recursive: true);
    await databaseFactory.setDatabasesPath(dbBasePath);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getTemporaryDirectory':
          return tmpRoot.path;
      }
      return null;
    });
  });

  setUp(() async {
    // The real shell opens `slatesync.db` through the default databases
    // path; wipe it so leftovers cannot skew gallery/list assertions.
    await deleteDatabase('$dbBasePath${Platform.pathSeparator}slatesync.db');
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    try {
      await deleteDatabase(
        '$dbBasePath${Platform.pathSeparator}slatesync.db',
      );
    } catch (_) {
      // best effort
    }
    try {
      if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
    } catch (_) {
      // best effort
    }
  });

  /// Real event-loop windows interleaved with frame pumps (see
  /// `open_canvas_regression_test.dart`): sqflite/file futures parked from
  /// the fake zone only progress inside `runAsync`.
  Future<void> flushReal(WidgetTester tester, {int rounds = 6}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Pumps real-event-loop windows until [condition] holds (or a safety
  /// cap — the assertion afterwards then fails). Needed because Doc 02
  /// §9.3's persist-before-switch chain (db probe + archive save + row
  /// upsert) completes in real time of unknown depth under load.
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() condition, {
    int maxRounds = 50,
  }) async {
    for (int i = 0; i < maxRounds && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'remote OPEN_CANVAS {canvas} navigates the real shell to the studio',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);

      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Remote Switch',
        preset: 'A4',
        background: 'RULED',
        canvasId: 'remote-1',
        now: 1760763600,
      );

      // PC-initiated open: payload.canvas dialect (§8.2).
      fake.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'OPEN_CANVAS',
        'canvas_id': 'remote-1',
        'payload': <String, dynamic>{'canvas': doc.toJson()},
      });
      await flushReal(tester);
      await tester.pumpAndSettle();

      // §9.3 (round 5): the bridge persists the incoming document (db
      // probe + archive save + row upsert — real IO) BEFORE firing
      // remoteOpen, so wait for the driven navigation instead of a fixed
      // window count.
      await waitUntil(
        tester,
        () => find.byType(CanvasStudioPage).evaluate().isNotEmpty,
      );
      expect(find.byType(CanvasStudioPage), findsOneWidget);
      final CanvasStudioPage studio =
          tester.widget<CanvasStudioPage>(find.byType(CanvasStudioPage));
      expect(studio.document.canvasId, 'remote-1');
      expect(studio.document.title, 'Remote Switch');
      expect(studio.document.toJson(), equals(doc.toJson()));
      // The tablet follows the PC — it must NOT announce the same open
      // back (§8.3.3: no broadcast echo on remote-driven switches).
      expect(fake.sent, isEmpty);

      // Back from the studio returns to the home gallery (the remote
      // open pushed onto the home stack instead of stacking stale
      // routes). `_onBack` awaits a full `_save()` (file + sqflite real
      // IO) before popping — wait for the studio to leave the tree.
      await tester.tap(find.byKey(const Key('studio-back')));
      await waitUntil(
        tester,
        () => find.byType(CanvasStudioPage).evaluate().isEmpty,
      );
      expect(find.byType(CanvasStudioPage), findsNothing);
      expect(find.byType(HomeCanvasDashboard), findsOneWidget);

      // Unmount so studio timers/subscriptions are cancelled; give the
      // dashboard's unawaited `LocalDb.close()` real-time windows before
      // the next test's setUp deletes the database file (Windows locks).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await flushReal(tester, rounds: 3);
    },
  );

  testWidgets(
    'local create pushes CANVAS_LIST; local open broadcasts OPEN_CANVAS',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);

      // Create through the New Canvas modal (retry loop copied from the
      // Issue 02 regression test: the first ffi `LocalDb.open()` may still
      // be in flight while the modal is up).
      await tester.tap(find.byKey(const Key('new_canvas_fab')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('new_title_field')),
        'Shell Local',
      );
      for (int i = 0; i < 40; i++) {
        await tester.tap(
          find.byKey(const Key('create_canvas')),
          warnIfMissed: false,
        );
        await flushReal(tester, rounds: 3);
        if (find.byType(AlertDialog).evaluate().isEmpty) break;
      }
      await flushReal(tester, rounds: 6);
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Shell Local'), findsOneWidget);

      // §8.1: dashboard create → onListChanged → bridge.publishList.
      await flushReal(tester, rounds: 4);
      final List<Map<String, dynamic>> lists = _actionsOf(fake, 'CANVAS_LIST');
      expect(lists, isNotEmpty, reason: 'create must push CANVAS_LIST');
      final List<dynamic> canvases =
          (lists.first['payload'] as Map)['canvases'] as List<dynamic>;
      expect(
        canvases.map((dynamic c) => (c as Map)['title']),
        contains('Shell Local'),
      );

      // §8.3.1: local open → bridge.announceOpen broadcasts the full doc.
      await tester.tap(find.text('Shell Local'));
      await flushReal(tester); // loadDocument + push + announce
      await tester.pumpAndSettle();
      expect(find.byType(CanvasStudioPage), findsOneWidget);

      final List<Map<String, dynamic>> opens =
          _actionsOf(fake, 'OPEN_CANVAS');
      expect(opens, isNotEmpty, reason: 'local open must announce');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(opens.first['payload'] as Map);
      expect(payload.keys, <String>['canvas']);
      final Map<String, dynamic> canvas =
          Map<String, dynamic>.from(payload['canvas'] as Map);
      expect(canvas['title'], 'Shell Local');
      expect(canvas['canvas_id'], opens.first['canvas_id']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await flushReal(tester, rounds: 3);
    },
  );
}
