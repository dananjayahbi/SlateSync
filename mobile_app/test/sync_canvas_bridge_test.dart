/// Doc 02 §8 + §9 unit suite for [CanvasSyncBridge] (Issue 04, rounds 4+5):
///  * `CANVAS_LIST` push on [SyncState.online], on direct [publishList]
///    calls and in reply to `CANVAS_LIST_REQUEST` — rows sorted
///    `updated_at DESC` inside the **§9.2 v2 payload**
///    `{device_id, device_name, origin, canvases}` (may be EMPTY)
///  * `CANVAS_OPEN_REQUEST` → load local doc → broadcast full-doc
///    `OPEN_CANVAS` → fire `remoteOpen` (send-before-fire order), with a
///    full save→load→toJson roundtrip equality check
///  * remote `OPEN_CANVAS {payload.canvas}` persists the document first
///    (§9.3 persist-on-open) and then fires `remoteOpen` WITHOUT echoing
///    back (no feedback loop)
///  * `payload.path` dialect (§8.2, PC-internal) is IGNORED; unknown
///    incoming actions are tolerated, never rejected (§8.5)
///  * [CanvasSyncBridge.announceOpen] envelope/payload exact keys (§8.3.1)
///  * `dispose()` stops all handling
///
/// All I/O runs through an injected fake client; scratch state lives under
/// `test/.sync_bridge_tmp/` inside the package (never `/tmp`) and is
/// removed in `tearDown`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'
    show buildNewCanvasDocument;
import 'package:mobile_app/features/sync/canvas_sync_bridge.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every `sendRpc` envelope (in order) and lets tests inject
/// [SyncEvent]s through the public `events` stream.
class _FakeClient extends VectorSyncClient {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// Shared chronological log: `'send:<action>'` entries from [sendRpc]
  /// plus `'remote'` entries appended by tests on `remoteOpen` changes —
  /// used to prove load → broadcast → local switch ordering.
  final List<String> log = <String>[];

  final StreamController<SyncEvent> _controller =
      StreamController<SyncEvent>.broadcast();

  @override
  Stream<SyncEvent> get events => _controller.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sent.add(envelope);
    log.add('send:${envelope['action']}');
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void emitRpc(Map<String, dynamic> msg) =>
      _controller.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: msg));

  void emitState(SyncState state) =>
      _controller.add(SyncEvent(kind: SyncEventKind.stateChanged, state: state));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Polls [condition] on the real event loop (plain `test()` bodies are not
/// on a fake clock, so sqflite/file futures settle normally).
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) {
      throw StateError('timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets pending microtask chains (event dispatch → handler) run.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> envelopeFor(String action) => <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': action,
      'canvas_id': '',
      'payload': <String, dynamic>{},
    };

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.sync_bridge_tmp');
  late Directory tmp;
  int counter = 0;
  final List<CanvasSyncBridge> bridges = <CanvasSyncBridge>[];
  final List<_FakeClient> clients = <_FakeClient>[];
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    tmp = Directory(
      '${root.path}/${DateTime.now().microsecondsSinceEpoch}_$counter',
    );
    counter += 1;
    tmp.createSync(recursive: true);
    bridges.clear();
    clients.clear();
    openDbs.clear();
  });

  tearDown(() async {
    for (final CanvasSyncBridge bridge in bridges) {
      try {
        await bridge.dispose();
      } catch (_) {
        // already disposed by the test
      }
    }
    for (final _FakeClient client in clients) {
      try {
        await client.dispose();
      } catch (_) {
        // already disposed
      }
    }
    for (final LocalDb db in openDbs) {
      try {
        await db.close();
      } catch (_) {
        // already closed
      }
    }
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // best effort — never fail a test on cleanup
    }
  });

  tearDownAll(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // best effort
    }
  });

  (_FakeClient, CanvasSyncBridge) makeBridge({
    LocalDb? db,
    String? baseDir,
    void Function(CanvasDocumentModel doc)? onRemoteOpen,
    String? deviceFilePath,
    String? deviceName,
    Future<String> Function(CanvasDocumentModel doc, {String? baseDir})?
        saver,
  }) {
    final _FakeClient client = _FakeClient();
    clients.add(client);
    final CanvasSyncBridge bridge = CanvasSyncBridge(
      client: client,
      db: db,
      baseDir: baseDir,
      onRemoteOpen: onRemoteOpen,
      deviceName: deviceName,
      // §9.2 identity file lives under this test's scratch dir — no
      // path_provider in unit tests, deterministic per-test device_id.
      deviceFilePath: deviceFilePath ?? '${tmp.path}/slatesync_device.json',
      saver: saver,
    );
    bridges.add(bridge);
    return (client, bridge);
  }

  Future<LocalDb> openDb(String name) async {
    final LocalDb db = await LocalDb.open(
      pathOverride: '${tmp.path}/$name.db',
    );
    openDbs.add(db);
    return db;
  }

  CanvasRecord row(String id, String title, int updatedAt) => CanvasRecord(
        id: id,
        title: title,
        preset: 'A4',
        background: 'BLANK',
        thumbPath: '',
        filePath: '${tmp.path}/$id.slatesync',
        updatedAt: updatedAt,
      );

  /// Doc with a real element + bounds so the full-doc roundtrip is
  /// non-trivial.
  CanvasDocumentModel buildDoc({
    required String id,
    required String title,
    int now = 1760763600,
  }) {
    final CanvasDocumentModel doc = buildNewCanvasDocument(
      title: title,
      preset: 'LETTER',
      background: 'SQUARE_GRID',
      canvasId: id,
      now: now,
    );
    doc.contentBounds = <String, double>{
      'min_x': 0,
      'min_y': 0,
      'max_x': 120,
      'max_y': 80,
    };
    doc.elements.add(
      CanvasNodeModel(
        nodeId: 'n-1',
        kind: 'STROKE',
        layer: 0,
        bbox: <double>[0, 0, 120, 80],
        style: NodeStyleModel(
          color: '#FF0000',
          strokeWidth: 4,
          opacity: 1,
          blendMode: 'NORMAL',
        ),
        geometry: NodeGeometryModel(
          pts: <List<double>>[
            <double>[0, 0],
            <double>[60, 40],
            <double>[120, 80],
          ],
        ),
      ),
    );
    return doc;
  }

  // -------------------------------------------------------------------------
  // CANVAS_LIST (§8.1)
  // -------------------------------------------------------------------------

  group('CANVAS_LIST publish', () {
    test('online transition pushes the list; direct call pushes again',
        () async {
      final LocalDb db = await openDb('list');
      await db.insertCanvas(row('a', 'Alpha', 100));
      await db.insertCanvas(row('b', 'Beta', 300));
      await db.insertCanvas(row('c', 'Gamma', 200));
      final ( _FakeClient client, CanvasSyncBridge bridge) = makeBridge(db: db);

      client.emitState(SyncState.online);
      await waitFor(
        () => client.sent.isNotEmpty,
        description: 'CANVAS_LIST after online',
      );

      final Map<String, dynamic> env = client.sent.single;
      expect(env.keys, unorderedEquals(<String>[
        'type',
        'action',
        'canvas_id',
        'payload',
      ]));
      expect(env['type'], 'CANVAS_LIFECYCLE');
      expect(env['action'], 'CANVAS_LIST');
      expect(env['canvas_id'], '');

      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      // §9.2 v2 payload: exact key set, stable uuid, device origin.
      expect(
        payload.keys,
        unorderedEquals(<String>[
          'device_id',
          'device_name',
          'origin',
          'canvases',
        ]),
      );
      expect(payload['origin'], 'device');
      expect(payload['device_name'], isNull);
      expect(
        payload['device_id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final List<dynamic> canvases = payload['canvases'] as List<dynamic>;
      expect(
        canvases.map((dynamic c) => (c as Map)['id']),
        <String>['b', 'c', 'a'], // updated_at DESC
      );
      expect(
        canvases.map((dynamic c) => (c as Map)['updated_at']),
        <int>[300, 200, 100],
      );
      expect(
        (canvases.first as Map).keys,
        unorderedEquals(<String>[
          'id',
          'title',
          'preset',
          'background',
          'updated_at',
        ]),
      );
      expect((canvases.first as Map)['title'], 'Beta');

      // Exposed for callers (dashboard onListChanged wiring).
      client.sent.clear();
      await bridge.publishList();
      expect(client.sent, hasLength(1));
      expect(client.sent.single['action'], 'CANVAS_LIST');
      expect(
        ((client.sent.single['payload'] as Map)['canvases'] as List),
        hasLength(3),
      );
    });

    test('reply to CANVAS_LIST_REQUEST publishes the current rows',
        () async {
      final LocalDb db = await openDb('list_req');
      await db.insertCanvas(row('x', 'Only', 42));
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(db: db);

      client.emitRpc(
        envelopeFor('CANVAS_LIST_REQUEST')
          ..['payload'] = <String, dynamic>{},
      );
      await waitFor(
        () => client.sent.isNotEmpty,
        description: 'CANVAS_LIST reply',
      );

      expect(client.sent.single['action'], 'CANVAS_LIST');
      final List<dynamic> canvases =
          (client.sent.single['payload'] as Map)['canvases'] as List<dynamic>;
      expect(canvases, hasLength(1));
      expect((canvases.single as Map)['id'], 'x');
      expect((canvases.single as Map)['updated_at'], 42);
      expect(bridge.remoteOpen.value, isNull); // list replies never switch
    });

    test('empty store publishes an EMPTY canvases array', () async {
      final LocalDb db = await openDb('empty');
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(db: db);

      await bridge.publishList();
      expect(client.sent, hasLength(1));
      expect(
        (client.sent.single['payload'] as Map)['canvases'],
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // CANVAS_OPEN_REQUEST (§8.1 / §8.3.3)
  // -------------------------------------------------------------------------

  group('CANVAS_OPEN_REQUEST', () {
    test('loads local doc, broadcasts full doc, fires remoteOpen in order',
        () async {
      final String cacheDir = '${tmp.path}/SlateSync';
      final CanvasDocumentModel doc = buildDoc(
        id: 'c-pick',
        title: 'PC Pick',
      );
      await saveDocument(doc, baseDir: cacheDir);

      CanvasDocumentModel? viaCallback;
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        baseDir: cacheDir,
        onRemoteOpen: (CanvasDocumentModel d) => viaCallback = d,
      );
      bridge.remoteOpen.addListener(() => client.log.add('remote'));

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'CANVAS_OPEN_REQUEST',
          'canvas_id': '',
          'payload': <String, dynamic>{'canvas_id': 'c-pick'},
        },
      );
      await waitFor(
        () => client.sent.isNotEmpty,
        description: 'OPEN_CANVAS broadcast',
      );
      await settle(); // let the fireRemote continuation run

      // Order: broadcast first, then the local switch (§8.3.3).
      expect(client.log, <String>['send:OPEN_CANVAS', 'remote']);

      final Map<String, dynamic> env = client.sent.single;
      expect(env['action'], 'OPEN_CANVAS');
      expect(env['canvas_id'], 'c-pick');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      expect(
        payload.keys,
        unorderedEquals(<String>['canvas', 'device_id', 'device_name']),
      );

      // Full-doc roundtrip: save → load → toJson equals the source doc.
      final Map<String, dynamic> sentCanvas =
          Map<String, dynamic>.from(payload['canvas'] as Map);
      expect(sentCanvas, equals(doc.toJson()));
      expect(
        sentCanvas,
        equals(
          CanvasDocumentModel.fromJson(
            jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>,
          ).toJson(),
        ),
      );

      // The tablet switches its own UI too, both hand-off styles.
      expect(bridge.remoteOpen.value, isNotNull);
      expect(bridge.remoteOpen.value!.canvasId, 'c-pick');
      expect(bridge.remoteOpen.value!.title, 'PC Pick');
      expect(bridge.remoteOpen.value!.toJson(), equals(doc.toJson()));
      expect(viaCallback?.canvasId, 'c-pick');
      expect(viaCallback?.toJson(), equals(doc.toJson()));
    });

    test('unknown canvas id loads nothing and stays silent', () async {
      final String cacheDir = '${tmp.path}/SlateSync';
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        baseDir: cacheDir,
      );

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'CANVAS_OPEN_REQUEST',
          'canvas_id': '',
          'payload': <String, dynamic>{'canvas_id': 'missing'},
        },
      );
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(client.sent, isEmpty);
      expect(bridge.remoteOpen.value, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // OPEN_CANVAS dual dialect (§8.2)
  // -------------------------------------------------------------------------

  group('OPEN_CANVAS dialects', () {
    test('payload.canvas persists first (§9.3), fires remoteOpen, no echo',
        () async {
      final LocalDb db = await openDb('remote_open');
      final String cacheDir = '${tmp.path}/SlateSync';
      final CanvasDocumentModel doc = buildDoc(
        id: 'pc-open',
        title: 'From PC',
      );
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        db: db,
        baseDir: cacheDir,
        onRemoteOpen: (_) {},
      );

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'OPEN_CANVAS',
          'canvas_id': 'pc-open',
          'payload': <String, dynamic>{'canvas': doc.toJson()},
        },
      );
      await waitFor(
        () => bridge.remoteOpen.value != null,
        description: 'remoteOpen after persist-on-open',
      );

      expect(bridge.remoteOpen.value!.canvasId, 'pc-open');
      expect(bridge.remoteOpen.value!.title, 'From PC');
      expect(bridge.remoteOpen.value!.toJson(), equals(doc.toJson()));
      // PC-initiated opens are NEVER echoed back (no loop).
      expect(client.sent, isEmpty);

      // §9.3: the document hit the local store before the switch — zip and
      // gallery row both exist for the newly received canvas (row upsert +
      // hubChanged trail the switch by a beat).
      await waitFor(
        () => bridge.hubChanged.value > 0,
        description: 'row upsert after persist-on-open',
      );
      final CanvasDocumentModel stored = await loadDocument(
        'pc-open',
        baseDir: cacheDir,
      );
      expect(stored.toJson(), equals(doc.toJson()));
      final CanvasRecord? row = await db.get('pc-open');
      expect(row, isNotNull);
      expect(row!.updatedAt, doc.updatedAt);
      expect(row.title, doc.title);
    });

    test('payload.path dialect (PC-internal) is IGNORED', () async {
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge();

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'OPEN_CANVAS',
          'canvas_id': 'c-path',
          'payload': <String, dynamic>{
            'path': r'C:\PC\Documents\notes.slatesync',
          },
        },
      );
      await settle();

      expect(bridge.remoteOpen.value, isNull);
      expect(client.sent, isEmpty);
    });

    test('unknown incoming actions are tolerated, never rejected', () async {
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge();

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'SOME_FUTURE_ACTION',
          'canvas_id': '',
          'payload': <String, dynamic>{'whatever': true},
        },
      );
      await settle();

      expect(bridge.remoteOpen.value, isNull);
      expect(client.sent, isEmpty); // silently ignored, nothing thrown
    });
  });

  // -------------------------------------------------------------------------
  // announceOpen (§8.3.1) + dispose
  // -------------------------------------------------------------------------

  group('announceOpen & dispose', () {
    test('sends OPEN_CANVAS with the §8.2 keys plus device identity',
        () async {
      final CanvasDocumentModel doc = buildDoc(
        id: 'local-1',
        title: 'Tablet Draw',
      );
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge();

      await bridge.announceOpen(doc);

      final Map<String, dynamic> env = client.sent.single;
      expect(
        env.keys,
        unorderedEquals(<String>['type', 'action', 'canvas_id', 'payload']),
      );
      expect(env['type'], 'CANVAS_LIFECYCLE');
      expect(env['action'], 'OPEN_CANVAS');
      expect(env['canvas_id'], 'local-1');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      // §8.2 keys unchanged; the persisted identity rides along so the PC
      // hub can attribute the open to a device.
      expect(
        payload.keys,
        unorderedEquals(<String>['canvas', 'device_id', 'device_name']),
      );
      expect(payload['canvas'], equals(doc.toJson()));
      expect(payload['device_id'], isA<String>());
      expect((payload['device_id'] as String).isNotEmpty, isTrue);
    });

    test('OPEN_CANVAS keeps the §8.2 canvas body byte-identical', () async {
      final CanvasDocumentModel doc = buildDoc(
        id: 'local-2',
        title: 'Named Device',
      );
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        deviceName: 'Slate A',
      );

      await bridge.announceOpen(doc);

      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(client.sent.single['payload'] as Map);
      expect(payload['canvas'], equals(doc.toJson()));
      expect(payload['device_name'], 'Slate A');
    });

    test('dispose stops publishing, handling and announcing', () async {
      final LocalDb db = await openDb('dispose');
      await db.insertCanvas(row('d', 'Doomed', 7));
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(db: db);

      await bridge.dispose();
      client.emitState(SyncState.online);
      client.emitRpc(envelopeFor('CANVAS_LIST_REQUEST'));
      await settle();
      expect(client.sent, isEmpty);

      await bridge.announceOpen(buildDoc(id: 'after', title: 'After'));
      expect(client.sent, isEmpty);

      client.emitRpc(
        <String, dynamic>{
          'type': 'CANVAS_LIFECYCLE',
          'action': 'OPEN_CANVAS',
          'canvas_id': 'x',
          'payload': <String, dynamic>{
            'canvas': buildDoc(id: 'x', title: 'X').toJson(),
          },
        },
      );
      await settle();
      expect(client.sent, isEmpty);
    });
  });
}
