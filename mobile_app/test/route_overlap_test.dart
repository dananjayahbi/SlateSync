/// Issue 03 round 5 — single-studio navigation invariant (USER BUG: "open a
/// new canvas, go back, open another → they overlap / the old one is still
/// alive"). Drives the REAL shell (`SlateSyncApp` from `lib/main.dart`) and
/// proves that EVERY studio entry path (local gallery open, create-new flow,
/// remote/bridge open — incl. while a dialog covers the studio — and rapid
/// double-open) leaves EXACTLY ONE [CanvasStudioPage] alive in the whole
/// element tree, with home as the root route.
///
/// Counting uses `skipOffstage: false` on purpose: a stacked stale studio
/// sits BELOW an opaque route, so the default onstage-only finder would
/// happily report `findsOneWidget` while two studios are really alive.
///
/// Also covers Doc 02 §8/§9 shell wiring: local open still announces
/// (`announceOpen`), dashboard create still fires `onListChanged`, main
/// passes a non-null `refreshListenable` (bridge `hubChanged`) into the
/// dashboard, and returning to the gallery deterministically refreshes it.
///
/// Mocking mirrors `open_canvas_regression_test.dart` / the round-4 shell
/// suite: path_provider via a mock MethodChannel, sqflite via
/// `sqflite_common_ffi` on an isolated databases path. All scratch state
/// lives under `test/.route_overlap_tmp/` (never `/tmp`) and is removed in
/// `tearDownAll`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'
    show HomeCanvasDashboard, UpgradeDialog, buildNewCanvasDocument;
import 'package:mobile_app/main.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake client (records sends; injects incoming SyncEvents) — same seam as
// `main_shell_remote_open_test.dart`.
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
      'test/.route_overlap_tmp/${DateTime.now().microsecondsSinceEpoch}',
    );
    tmpRoot.createSync(recursive: true);
    // Isolate this file's `LocalDb.open()` default path: `flutter test`
    // runs test files in parallel and other suites share the default
    // `slatesync.db` — sharing it would race.
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
    // Wipe so leftovers from earlier tests cannot skew gallery assertions.
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

  /// Real event-loop windows interleaved with frame pumps — `testWidgets`
  /// runs on a fake clock, so sqflite/file futures (ffi isolate ports)
  /// parked from the fake zone only progress while `runAsync` gives them
  /// real time.
  Future<void> flushReal(WidgetTester tester, {int rounds = 6}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Pumps real-event-loop windows until [condition] holds (or a safety cap
  /// — the assertion afterwards then fails with a clear message). Used for
  /// IO chains of unknown depth, e.g. Doc 02 §9.3's persist-before-switch
  /// (db probe + archive save + row upsert) before `remoteOpen` fires.
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

  /// Pre-seeds a fully openable canvas row + `.slatesync` archive through
  /// the same defaults the shell uses (mocked path_provider + isolated
  /// databases path). Runs OUTSIDE the fake test zone via `runAsync`.
  Future<void> seedCanvas(
    String id,
    String title, {
    required int now,
  }) async {
    final CanvasDocumentModel doc = buildNewCanvasDocument(
      title: title,
      preset: 'A4',
      background: 'BLANK',
      canvasId: id,
      now: now,
    );
    final String path = await saveDocument(doc);
    final LocalDb db = await LocalDb.open();
    await db.insertCanvas(
      CanvasRecord(
        id: id,
        title: title,
        preset: 'A4',
        background: 'BLANK',
        thumbPath: '',
        filePath: path,
        updatedAt: now,
      ),
    );
    await db.close(); // shell reopens fresh (sqflite single-instance)
  }

  /// Every [CanvasStudioPage] really alive in the tree — including stale
  /// ones buried beneath an opaque route (the reported overlap).
  List<CanvasStudioPage> allStudios(WidgetTester tester) =>
      tester
          .widgetList<CanvasStudioPage>(
            find.byType(CanvasStudioPage, skipOffstage: false),
          )
          .toList(growable: false);

  Future<void> openStudio(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await flushReal(tester); // loadDocument + push + first studio frame
    await tester.pumpAndSettle();
  }

  /// Studio back → home root, asserting the invariant on the way out.
  Future<void> backToHome(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('studio-back')));
    // `_onBack` awaits a full `_save()` (file + sqflite real IO) before
    // popping, and the pushed route's future completes only after the exit
    // animation — wait for the studio to actually leave the tree, then let
    // the debounced gallery refresh kicked off by the pop land too.
    await waitUntil(
      tester,
      () =>
          find.byType(CanvasStudioPage, skipOffstage: false).evaluate().isEmpty,
    );
    await flushReal(tester, rounds: 4);
    await tester.pumpAndSettle();
    expect(find.byType(CanvasStudioPage, skipOffstage: false), findsNothing);
    expect(find.byType(HomeCanvasDashboard), findsOneWidget);
  }

  /// Unmount so studio timers/subscriptions are cancelled and the
  /// dashboard's `LocalDb.close()` runs before the next test's
  /// `deleteDatabase` (Windows file locks).
  Future<void> unmountShell(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await flushReal(tester, rounds: 3);
  }

  /// New Canvas modal create with the Issue-02 regression retry loop (the
  /// first ffi `LocalDb.open()` may still be in flight while the modal is
  /// up).
  Future<void> createViaModal(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('new_canvas_fab')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('new_title_field')), title);
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
    expect(find.text(title), findsOneWidget);
  }

  // -------------------------------------------------------------------------
  // (a) open A → back → open B
  // -------------------------------------------------------------------------

  testWidgets(
    'local open A, back, open B: exactly one studio (B), no A studio left',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () async {
          await seedCanvas('a-alpha', 'Canvas Alpha', now: 1000);
          await seedCanvas('b-beta', 'Canvas Beta', now: 2000);
        },
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);
      expect(find.byKey(const Key('canvas_grid')), findsOneWidget);

      await openStudio(tester, 'Canvas Alpha');
      expect(allStudios(tester), hasLength(1));
      expect(allStudios(tester).single.document.canvasId, 'a-alpha');

      await backToHome(tester);

      await openStudio(tester, 'Canvas Beta');
      final List<CanvasStudioPage> studios = allStudios(tester);
      expect(
        studios,
        hasLength(1),
        reason: 'A must be gone — exactly one studio route may be alive',
      );
      expect(studios.single.document.canvasId, 'b-beta');
      expect(studios.single.document.title, 'Canvas Beta');
      // Nothing of canvas A is visible onstage while B is open (A's gallery
      // card lives on the covered home route; no A studio exists at all).
      expect(find.text('Canvas Alpha'), findsNothing);

      await unmountShell(tester);
    },
  );

  // -------------------------------------------------------------------------
  // (b) create new → back → open existing
  // -------------------------------------------------------------------------

  testWidgets(
    'create-new studio, back, open existing: exactly one studio (existing)',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () => seedCanvas('e-existing', 'Existing Canvas', now: 1000),
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);

      await createViaModal(tester, 'Fresh Canvas');

      // The create-new flow opens the new document (studio entry #2).
      await openStudio(tester, 'Fresh Canvas');
      expect(allStudios(tester), hasLength(1));
      expect(allStudios(tester).single.document.title, 'Fresh Canvas');

      await backToHome(tester);

      await openStudio(tester, 'Existing Canvas');
      final List<CanvasStudioPage> studios = allStudios(tester);
      expect(studios, hasLength(1));
      expect(studios.single.document.canvasId, 'e-existing');
      expect(studios.single.document.title, 'Existing Canvas');
      expect(find.text('Fresh Canvas'), findsNothing);

      await unmountShell(tester);
    },
  );

  // -------------------------------------------------------------------------
  // (c) remote/bridge open while a studio is showing an old doc
  // -------------------------------------------------------------------------

  testWidgets(
    'remote OPEN_CANVAS while studio shows an old doc replaces it (1 route)',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () => seedCanvas('old-doc', 'Old Local Doc', now: 1000),
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);

      await openStudio(tester, 'Old Local Doc');
      expect(allStudios(tester), hasLength(1));

      final CanvasDocumentModel pcDoc = buildNewCanvasDocument(
        title: 'PC Switch',
        preset: 'A4',
        background: 'RULED',
        canvasId: 'pc-switch',
        now: 1760763600,
      );
      fake.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'OPEN_CANVAS',
        'canvas_id': 'pc-switch',
        'payload': <String, dynamic>{'canvas': pcDoc.toJson()},
      });
      // The bridge persists first (Doc 02 §9.3: LocalDb probe + archive
      // save + row upsert over real IO) before firing remoteOpen — wait for
      // the driven navigation instead of guessing window counts.
      await waitUntil(
        tester,
        () => allStudios(
          tester,
        ).any((CanvasStudioPage s) => s.document.canvasId == 'pc-switch'),
      );

      final List<CanvasStudioPage> studios = allStudios(tester);
      expect(studios, hasLength(1), reason: 'remote open must REPLACE, not stack');
      expect(studios.single.document.canvasId, 'pc-switch');
      expect(studios.single.document.title, 'PC Switch');
      // Remote-driven switches never echo the open back to the PC
      // (§8.3.3): the only OPEN_CANVAS broadcast is the earlier LOCAL open
      // of `old-doc`, never the PC-initiated `pc-switch`.
      expect(
        _actionsOf(fake, 'OPEN_CANVAS')
            .map((Map<String, dynamic> e) => e['canvas_id']),
        isNot(contains('pc-switch')),
      );

      await backToHome(tester);
      await unmountShell(tester);
    },
  );

  testWidgets(
    'remote OPEN_CANVAS while a dialog covers the studio collapses to 1 route',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () => seedCanvas('old-doc2', 'Buried Studio Doc', now: 1000),
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);

      await openStudio(tester, 'Buried Studio Doc');
      expect(allStudios(tester), hasLength(1));

      // Upgrade dialog ON TOP of the studio — a route stack where a naive
      // `pushReplacement` (top-only) would leave the old studio alive
      // beneath the remote-driven one.
      await tester.tap(find.byKey(const Key('studio-preset')));
      await tester.pumpAndSettle();
      expect(find.byType(UpgradeDialog), findsOneWidget);

      final CanvasDocumentModel pcDoc = buildNewCanvasDocument(
        title: 'PC Overtake',
        preset: 'A4',
        background: 'BLANK',
        canvasId: 'pc-overtake',
        now: 1760763700,
      );
      fake.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'OPEN_CANVAS',
        'canvas_id': 'pc-overtake',
        'payload': <String, dynamic>{'canvas': pcDoc.toJson()},
      });
      // §9.3 persist-before-switch chain: wait for the driven navigation.
      await waitUntil(
        tester,
        () => allStudios(
          tester,
        ).any((CanvasStudioPage s) => s.document.canvasId == 'pc-overtake'),
      );

      expect(find.byType(UpgradeDialog), findsNothing);
      final List<CanvasStudioPage> studios = allStudios(tester);
      expect(
        studios,
        hasLength(1),
        reason: 'the buried old studio must not survive a remote switch',
      );
      expect(studios.single.document.canvasId, 'pc-overtake');

      // Back lands on home (root) — not on the stale studio, not on a dialog.
      await backToHome(tester);
      await unmountShell(tester);
    },
  );

  // -------------------------------------------------------------------------
  // (d) rapid double-open of the same canvas
  // -------------------------------------------------------------------------

  testWidgets(
    'rapid double-open of the same canvas keeps exactly one studio route',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () => seedCanvas('dbl-1', 'Double Tap', now: 1000),
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);

      // Two taps before `loadDocument` can resolve (it needs REAL event
      // loop time; a zero/`pump()`-only gap keeps both pending) ⇒ two
      // `_open()` invocations race into the navigator.
      await tester.tap(find.text('Double Tap'));
      await tester.pump();
      await tester.tap(find.text('Double Tap'), warnIfMissed: false);
      await flushReal(tester);
      await tester.pumpAndSettle();

      final List<CanvasStudioPage> studios = allStudios(tester);
      expect(
        studios,
        hasLength(1),
        reason: 'double-open must not stack two studios',
      );
      expect(studios.single.document.canvasId, 'dbl-1');

      await backToHome(tester);
      await unmountShell(tester);
    },
  );

  // -------------------------------------------------------------------------
  // (e) §8 wiring still intact: announceOpen on local open, onListChanged
  // on create; §9: main passes bridge.hubChanged as refreshListenable.
  // -------------------------------------------------------------------------

  testWidgets(
    'local open announces OPEN_CANVAS; create fires onListChanged (CANVAS_LIST)',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);

      // §9 wiring: the shell hands the dashboard a refresh listenable
      // (bridge.hubChanged merged with the return-to-gallery refresh).
      final HomeCanvasDashboard dashboard = tester.widget<HomeCanvasDashboard>(
        find.byType(HomeCanvasDashboard),
      );
      expect(dashboard.refreshListenable, isNotNull);

      await createViaModal(tester, 'Announce Me');

      // §8.1 — create → onListChanged → bridge.publishList.
      await flushReal(tester, rounds: 4);
      final List<Map<String, dynamic>> lists = _actionsOf(fake, 'CANVAS_LIST');
      expect(lists, isNotEmpty, reason: 'create must push CANVAS_LIST');
      final List<dynamic> canvases =
          (lists.first['payload'] as Map)['canvases'] as List<dynamic>;
      expect(
        canvases.map((dynamic c) => (c as Map)['title']),
        contains('Announce Me'),
      );

      // §8.3.1 — local open → bridge.announceOpen broadcasts the full doc.
      await openStudio(tester, 'Announce Me');
      expect(allStudios(tester), hasLength(1));
      final List<Map<String, dynamic>> opens =
          _actionsOf(fake, 'OPEN_CANVAS');
      expect(opens, isNotEmpty, reason: 'local open must announce');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(opens.first['payload'] as Map);
      expect(payload.keys, <String>['canvas']);
      final Map<String, dynamic> canvas =
          Map<String, dynamic>.from(payload['canvas'] as Map);
      expect(canvas['title'], 'Announce Me');
      expect(canvas['canvas_id'], opens.first['canvas_id']);

      await unmountShell(tester);
    },
  );

  // -------------------------------------------------------------------------
  // Return to home: gallery state refresh is deterministic
  // -------------------------------------------------------------------------

  testWidgets(
    'back from studio deterministically refreshes the home gallery rows',
    (WidgetTester tester) async {
      final _FakeClient fake = _FakeClient();
      addTearDown(fake.dispose);
      await tester.runAsync(
        () => seedCanvas('first-1', 'First Canvas', now: 1000),
      );
      await tester.pumpWidget(SlateSyncApp(client: fake));
      await flushReal(tester);
      expect(find.text('First Canvas'), findsOneWidget);

      await openStudio(tester, 'First Canvas');
      expect(allStudios(tester), hasLength(1));

      // A hub/peer row lands while the studio covers the gallery (Doc 02
      // §9.4 — CANVAS_PUT persists silently). Shares the dashboard's live
      // sqflite single-instance connection; NEVER closed here (the owning
      // dashboard closes it on unmount).
      await tester.runAsync(
        () async {
          final LocalDb db = await LocalDb.open();
          await db.insertCanvas(
            CanvasRecord(
              id: 'late-1',
              title: 'Late Arrival',
              preset: 'A4',
              background: 'BLANK',
              thumbPath: '',
              filePath: '${tmpRoot.path}/late-1.slatesync',
              updatedAt: 2000,
            ),
          );
        },
      );
      await flushReal(tester);
      // The gallery only re-reads rows on an explicit refresh trigger —
      // the silent store write must not have painted itself yet.
      expect(find.text('Late Arrival', skipOffstage: false), findsNothing);

      await backToHome(tester);
      // Deterministic refresh-on-return: the new row is now listed (first —
      // `updated_at DESC`), proving `_refresh()` ran after the pop. The
      // refresh itself is debounced (100 ms) after the route future
      // completes, so wait for the row rather than guessing windows.
      await waitUntil(
        tester,
        () => find.text('Late Arrival').evaluate().isNotEmpty,
      );
      expect(find.text('Late Arrival'), findsOneWidget);
      expect(find.text('First Canvas'), findsOneWidget);

      await unmountShell(tester);
    },
  );
}
