/// Wave 3.A wiring suite for [CanvasStudioPage] (Infinite Canvas Studio).
///
/// Covers the master-wiring charter: shell composition (Doc 22 view + Doc 24
/// dock + Doc 26/27 chrome), one-finger stroke commit → Doc 22 engine + Doc 25
/// `ELEMENT_COMMIT/ADD_STROKE` + Doc 24 live-frame streaming, highlighter
/// kind/blend, Doc 24 eraser → Doc 22 `queryVisible` hit-test → Doc 25
/// `DELETE_NODE`, zoom readout, the Doc 27 export sheet entry point, Doc 26
/// back-save (`saveDocument` + `LocalDb.update`) and the UpgradeDialog
/// preset flow.
///
/// The client is a Doc 25 surface fake — no sockets, no mDNS, no `pc_agent`
/// imports. Scratch state lives under `test/.canvas_studio_tmp/` inside the
/// package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fake (Doc 25 surface — widget tests never touch the network)
// ---------------------------------------------------------------------------

class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient({this.connected = false});

  /// Backing store for [isConnected].
  bool connected;

  /// Envelopes accepted by [sendRpc], in arrival order (Doc 25 fills `id`
  /// and `timestamp` — mirrored here so assertions match production).
  final List<Map<String, dynamic>> sentRpc = <Map<String, dynamic>>[];

  /// Live frames as `[frameType, toolId, f1, f2, f3]`.
  final List<List<double>> frames = <List<double>>[];

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
  ) {
    frames.add(<double>[
      frameType.toDouble(),
      toolId.toDouble(),
      f1,
      f2,
      f3,
    ]);
  }

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    for (final String field in const <String>[
      'type',
      'action',
      'canvas_id',
      'payload',
    ]) {
      if (!envelope.containsKey(field)) {
        throw FormatException('missing envelope field: $field');
      }
    }
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

int _counter = 0;

const String _canvasId = 'canvas-test';

CanvasDocumentModel _doc() => buildNewCanvasDocument(
      title: 'Studio',
      preset: 'A4',
      background: 'BLANK',
      canvasId: _canvasId,
      now: 1000,
    );

Future<void> _pumpStudio(
  WidgetTester tester, {
  required _FakeSyncClient client,
  LocalDb? db,
  String? baseDir,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(
        document: _doc(),
        client: client,
        db: db,
        baseDir: baseDir,
      ),
    ),
  );
  await tester.pump();
}

/// Unmounts the route (cancels the Doc 25 subscription, autosave timer and
/// notifiers) and closes the fake — keeps teardown free of pending timers.
Future<void> _disposeStudio(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}

/// One-finger stroke: down → three decimation-safe moves → up.
Future<void> _draw(
  WidgetTester tester, {
  Offset start = const Offset(300, 300),
}) async {
  final TestGesture g = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(30, 10));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(30, 10));
  await tester.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(20, 20));
  await tester.pump(const Duration(milliseconds: 16));
  await g.up();
  await tester.pump(const Duration(milliseconds: 16));
}

List<Map<String, dynamic>> _actions(_FakeSyncClient c, String action) =>
    c.sentRpc.where((Map<String, dynamic> e) => e['action'] == action).toList();

Map<String, dynamic> _payload(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload']! as Map);

/// Real event-loop windows interleaved with frame pumps — `testWidgets` runs
/// on a fake clock, so sqflite/file futures parked from the fake zone only
/// progress while `runAsync` gives them real time (same seam as the Doc 26
/// suite).
Future<void> _flushReal(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _settleIo(WidgetTester tester, {int rounds = 16}) async {
  await _flushReal(tester, rounds: rounds);
  await tester.pump(const Duration(milliseconds: 500));
  await _flushReal(tester, rounds: 2);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.canvas_studio_tmp');
  late Directory tmp;
  late String cacheDir;
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    tmp = Directory('${root.path}/${DateTime.now().microsecondsSinceEpoch}_$_counter');
    _counter += 1;
    tmp.createSync(recursive: true);
    cacheDir = '${tmp.path}/SlateSync';
    openDbs.clear();
  });

  tearDown(() async {
    for (final LocalDb db in openDbs) {
      try {
        await db.close();
      } catch (_) {
        // already closed
      }
    }
    openDbs.clear();
    try {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort — never fail a test on cleanup
    }
  });

  tearDownAll(() {
    try {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort
    }
  });

  Future<LocalDb> openDbInTester(WidgetTester tester) async {
    final LocalDb? db = await tester.runAsync(
      () => LocalDb.open(pathOverride: '${tmp.path}/studio.db'),
    );
    final LocalDb opened = db!;
    openDbs.add(opened);
    return opened;
  }

  Future<void> seedRecord(LocalDb db) => db.insertCanvas(
        CanvasRecord(
          id: _canvasId,
          title: 'Studio',
          preset: 'A4',
          background: 'BLANK',
          thumbPath: '',
          filePath: '$cacheDir/$_canvasId.slatesync',
          updatedAt: 1000,
        ),
      );

  testWidgets('studio shell wires canvas, dock, top bar and offline banner',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client: client);

    expect(find.byType(TiledCanvasView), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('studio-back')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('studio-zoom-level')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('studio-zoom-in')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('studio-preset')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('studio-connect')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('studio-export')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('dock-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('studio-banner')), findsOneWidget);
    expect(find.textContaining('Not paired'), findsOneWidget);

    final Text level =
        tester.widget<Text>(find.byKey(const ValueKey<String>('studio-zoom-level')));
    expect(level.data, matches(RegExp(r'^\d+%$')));

    await _disposeStudio(tester, client);
  });

  testWidgets('one-finger drag commits ADD_STROKE and streams live frames',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client: client);

    await _draw(tester);

    final List<Map<String, dynamic>> commits = _actions(client, 'ADD_STROKE');
    expect(commits, hasLength(1));
    final Map<String, dynamic> env = commits.single;
    expect(env['type'], 'ELEMENT_COMMIT');
    expect(env['canvas_id'], _canvasId);
    expect(env['id'], isA<String>());
    expect(env['timestamp'], isA<int>());

    final Map<String, dynamic> payload = _payload(env);
    expect(payload['node_id'], isA<String>());
    expect(payload['kind'], 'STROKE');
    expect(payload['style']['blend_mode'], 'SRC_OVER');
    expect(payload['bbox'], hasLength(4));
    final List<dynamic> pts = payload['geometry']['pts'] as List<dynamic>;
    expect(pts.length, greaterThanOrEqualTo(2));

    // Doc 24 streaming: ≥1 LIVE_POINT tagged pen (0x01) + LIVE_END (0x02).
    expect(
      client.frames.where((List<double> f) => f[0] == 1 && f[1] == 1),
      isNotEmpty,
    );
    expect(client.frames.where((List<double> f) => f[0] == 2), isNotEmpty);

    await _disposeStudio(tester, client);
  });

  testWidgets('highlighter commits HIGHLIGHT/MULTIPLY with toolId 0x02',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('tool-highlighter')));
    await tester.pumpAndSettle();
    await _draw(tester);

    final Map<String, dynamic> payload =
        _payload(_actions(client, 'ADD_STROKE').single);
    expect(payload['kind'], 'HIGHLIGHT');
    expect(payload['style']['blend_mode'], 'MULTIPLY');
    expect(
      client.frames.where((List<double> f) => f[0] == 1 && f[1] == 2),
      isNotEmpty,
    );

    await _disposeStudio(tester, client);
  });

  testWidgets('eraser precision tap hit-tests the stroke → DELETE_NODE',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient(connected: true);
    await _pumpStudio(tester, client: client);

    await _draw(tester); // screen path (300,300) → (380,340)
    final String strokeId =
        _payload(_actions(client, 'ADD_STROKE').single)['node_id'] as String;

    await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
    await tester.pumpAndSettle();

    final TestGesture tap = await tester.startGesture(const Offset(340, 320));
    await tester.pump(const Duration(milliseconds: 16));
    await tap.up();
    await tester.pump(const Duration(milliseconds: 16));

    final List<Map<String, dynamic>> deletes = _actions(client, 'DELETE_NODE');
    expect(deletes, hasLength(1));
    expect(_payload(deletes.single)['node_id'], strokeId);
    expect(_actions(client, 'ADD_STROKE'), hasLength(1)); // no stray commit

    await _disposeStudio(tester, client);
  });

  testWidgets('zoom controls update the camera readout', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client: client);

    final Finder levelFinder = find.byKey(const ValueKey<String>('studio-zoom-level'));
    final String before = tester.widget<Text>(levelFinder).data!;

    await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-in')));
    await tester.pump();
    final String after = tester.widget<Text>(levelFinder).data!;
    expect(after, isNot(before));
    expect(after, matches(RegExp(r'^\d+%$')));

    await tester.tap(find.byKey(const ValueKey<String>('studio-zoom-fit')));
    await tester.pump();
    expect(tester.widget<Text>(levelFinder).data, matches(RegExp(r'^\d+%$')));

    await _disposeStudio(tester, client);
  });

  testWidgets('Export button opens the Doc 27 export sheet',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client: client);

    await tester.tap(find.byKey(const ValueKey<String>('studio-export')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('format-png')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('export-start')), findsOneWidget);

    await _disposeStudio(tester, client);
  });

  testWidgets('back from studio saves the document and pops to Home',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    final LocalDb db = await openDbInTester(tester);
    await tester.runAsync(() => seedRecord(db));

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) => Scaffold(
            key: const ValueKey<String>('home-screen'),
            body: Center(
              child: ElevatedButton(
                key: const ValueKey<String>('open-studio'),
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => CanvasStudioPage(
                      document: _doc(),
                      client: client,
                      db: db,
                      baseDir: cacheDir,
                    ),
                  ),
                ),
                child: const Text('Open studio'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('open-studio')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('studio-back')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('studio-back')));
    await _settleIo(tester);

    expect(find.byKey(const ValueKey<String>('home-screen')), findsOneWidget);
    expect(File('$cacheDir/$_canvasId.slatesync').existsSync(), isTrue);

    final CanvasRecord? record =
        await tester.runAsync<CanvasRecord?>(() => db.get(_canvasId));
    expect(record, isNotNull);
    expect(record!.updatedAt, greaterThan(1000));
    expect(record.preset, 'A4');

    await _disposeStudio(tester, client);
  });

  testWidgets('preset chip opens Doc 26 UpgradeDialog and applies Letter',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    final LocalDb db = await openDbInTester(tester);
    await tester.runAsync(() => seedRecord(db));

    await _pumpStudio(tester, client: client, db: db, baseDir: cacheDir);

    await tester.tap(find.byKey(const ValueKey<String>('studio-preset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('upgrade_title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('upgrade_target_LETTER')));
    await _settleIo(tester);

    expect(find.byKey(const Key('upgrade_title')), findsNothing);
    expect(find.text('Letter'), findsWidgets); // top bar preset label

    final CanvasRecord? record =
        await tester.runAsync<CanvasRecord?>(() => db.get(_canvasId));
    expect(record, isNotNull);
    expect(record!.preset, 'LETTER');

    await _disposeStudio(tester, client);
  });
}
