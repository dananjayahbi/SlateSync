/// Doc 02 §9 unit suite for the round-5 hub flows of [CanvasSyncBridge]
/// (Issue 04):
///  * stable `device_id` across bridge instances sharing one persisted
///    `slatesync_device.json` (§9.2)
///  * `CANVAS_LIST` publish v2 — exact payload key set + `device_name`
///  * `CANVAS_PUT` receive → LWW (newer applies & persists + row upsert +
///    [CanvasSyncBridge.hubChanged]; older/equal skipped, equal keeps the
///    local copy) with NO navigation
///  * `CANVAS_PULL` receive → `CANVAS_PUT {source:"device"}` reply only
///    when strictly newer, exact payload keys
///  * `CANVAS_LIST (origin:"hub")` → diff pulls exactly the missing ids,
///    sequential with ~100 ms spacing, exactly-once dedupe (no re-pull
///    after the PUT lands or on the next list)
///  * persist-before-switch ordering on remote `OPEN_CANVAS` (§9.3)
///  * malformed `CANVAS_PUT` payloads and non-hub lists are safely ignored
///
/// All I/O runs through an injected fake client; scratch state lives under
/// `test/.sync_hub_tmp/` inside the package (never `/tmp`) and is removed
/// in `tearDown`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/sync/canvas_sync_bridge.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every `sendRpc` envelope (in order, with a send timestamp) and
/// lets tests inject [SyncEvent]s through the public `events` stream.
class _FakeClient extends VectorSyncClient {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final List<DateTime> sentAt = <DateTime>[];

  /// Shared chronological log: `'send:<action>'` entries from [sendRpc]
  /// plus `'save:<id>'` / `'remote'` entries appended by tests — used to
  /// prove persist-before-switch ordering (§9.3).
  final List<String> log = <String>[];

  final StreamController<SyncEvent> _controller =
      StreamController<SyncEvent>.broadcast();

  @override
  Stream<SyncEvent> get events => _controller.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    sent.add(envelope);
    sentAt.add(DateTime.now());
    log.add('send:${envelope['action']}');
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }

  void emitRpc(Map<String, dynamic> msg) =>
      _controller.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: msg));
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

List<Map<String, dynamic>> _actionsOf(_FakeClient client, String action) =>
    client.sent
        .where((Map<String, dynamic> e) => e['action'] == action)
        .toList(growable: false);

final RegExp uuidV4Re = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, dynamic> putEnvelope(CanvasDocumentModel doc,
        {String source = 'hub'}) =>
    <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': 'CANVAS_PUT',
      'canvas_id': doc.canvasId,
      'payload': <String, dynamic>{'canvas': doc.toJson(), 'source': source},
    };

Map<String, dynamic> hubListEnvelope(List<Map<String, dynamic>> canvases) =>
    <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': 'CANVAS_LIST',
      'canvas_id': '',
      'payload': <String, dynamic>{
        'device_id': 'hub-0001',
        'origin': 'hub',
        'canvases': canvases,
      },
    };

Map<String, dynamic> hubRow(String id, String title, int updatedAt) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'preset': 'A4',
      'background': 'BLANK',
      'updated_at': updatedAt,
    };

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.sync_hub_tmp');
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
      deviceFilePath: deviceFilePath ?? '${tmp.path}/slatesync_device.json',
      deviceName: deviceName,
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

  String cacheDir() => '${tmp.path}/SlateSync';

  CanvasRecord row(String id, String title, int updatedAt, String dir) =>
      CanvasRecord(
        id: id,
        title: title,
        preset: 'A4',
        background: 'BLANK',
        thumbPath: '',
        filePath: '$dir/$id.slatesync',
        updatedAt: updatedAt,
      );

  /// Minimal but fully-valid Doc 03 document (built directly — no other
  /// feature's helpers, so this suite stays inside sync ownership).
  CanvasDocumentModel buildDoc({
    required String id,
    required String title,
    required int now,
  }) =>
      CanvasDocumentModel(
        canvasId: id,
        title: title,
        createdAt: now - 60,
        updatedAt: now,
        artboard: Artboard(
          preset: 'A4',
          width: 595.0,
          height: 842.0,
          isInfinite: false,
          backgroundStyle: 'BLANK',
          backgroundColor: '#FFFFFF',
        ),
        contentBounds: <String, double>{
          'min_x': 0,
          'min_y': 0,
          'max_x': 100,
          'max_y': 50,
        },
        elements: <CanvasNodeModel>[],
      );

  /// Seeds a document + gallery row the way Doc 26/dashboard do.
  Future<void> seedLocal(
    LocalDb db,
    CanvasDocumentModel doc,
    String dir,
  ) async {
    await saveDocument(doc, baseDir: dir);
    await db.insertCanvas(
      row(doc.canvasId, doc.title, doc.updatedAt, dir),
    );
  }

  // -------------------------------------------------------------------------
  // Device identity (§9.2)
  // -------------------------------------------------------------------------

  group('device_id persistence', () {
    test('stable across two bridge instances on the same identity file',
        () async {
      final String identityPath = '${tmp.path}/slatesync_device.json';
      final ( _FakeClient clientA, CanvasSyncBridge bridgeA) = makeBridge(
        deviceFilePath: identityPath,
      );
      await bridgeA.publishList();
      expect(clientA.sent, hasLength(1));
      final Object? idA =
          (clientA.sent.single['payload'] as Map)['device_id'];
      expect(idA, isA<String>());
      expect(idA as String, matches(uuidV4Re));

      // The json exists on disk with that exact id…
      final Map<String, dynamic> fileJson =
          jsonDecode(File(identityPath).readAsStringSync())
              as Map<String, dynamic>;
      expect(fileJson.keys, contains('device_id'));
      expect(fileJson['device_id'], idA);

      // …and a fresh instance (simulated app restart) reuses it verbatim.
      final ( _FakeClient clientB, CanvasSyncBridge bridgeB) = makeBridge(
        deviceFilePath: identityPath,
      );
      await bridgeB.publishList();
      expect(clientB.sent, hasLength(1));
      expect((clientB.sent.single['payload'] as Map)['device_id'], idA);
    });

    test('CANVAS_LIST publish is v2: exact keys, origin device, device_name',
        () async {
      final LocalDb db = await openDb('v2');
      await db.insertCanvas(row('a', 'Alpha', 100, cacheDir()));
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        db: db,
        deviceName: 'Slate A',
      );

      await bridge.publishList();

      final Map<String, dynamic> env = client.sent.single;
      expect(env.keys, <String>['type', 'action', 'canvas_id', 'payload']);
      expect(env['action'], 'CANVAS_LIST');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
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
      expect(payload['device_name'], 'Slate A');
      expect(payload['device_id'], matches(uuidV4Re));
      final List<dynamic> canvases = payload['canvases'] as List<dynamic>;
      expect(canvases, hasLength(1));
      expect((canvases.single as Map)['id'], 'a');
    });
  });

  // -------------------------------------------------------------------------
  // CANVAS_PUT receive — LWW (§9.1)
  // -------------------------------------------------------------------------

  group('CANVAS_PUT receive (LWW)', () {
    test('newer PUT applies, persists (doc + row) and fires hubChanged, '
        'without navigation', () async {
      final LocalDb db = await openDb('put_newer');
      final String dir = cacheDir();
      await seedLocal(db, buildDoc(id: 'c1', title: 'Local', now: 100), dir);
      final (_FakeClient client, CanvasSyncBridge bridge) =
          makeBridge(db: db, baseDir: dir);

      final CanvasDocumentModel incoming = buildDoc(
        id: 'c1',
        title: 'Remote',
        now: 200,
      );
      client.emitRpc(putEnvelope(incoming));

      await waitFor(
        () => bridge.hubChanged.value == 1,
        description: 'hubChanged after applied PUT',
      );

      // LWW win: the document and the gallery row both moved forward.
      final CanvasDocumentModel stored = await loadDocument('c1', baseDir: dir);
      expect(stored.toJson(), equals(incoming.toJson()));
      final CanvasRecord? rec = await db.get('c1');
      expect(rec, isNotNull);
      expect(rec!.title, 'Remote');
      expect(rec.updatedAt, 200);
      expect(rec.preset, 'A4');

      // §9.1: persist silently — NO UI switch, NO echo.
      expect(bridge.remoteOpen.value, isNull);
      expect(client.sent, isEmpty);
      expect(bridge.hubChanged.value, 1);
    });

    test('older and equal PUTs are skipped; equal timestamps keep local',
        () async {
      final LocalDb db = await openDb('put_lww');
      final String dir = cacheDir();
      await seedLocal(db, buildDoc(id: 'c2', title: 'Local', now: 200), dir);
      final (_FakeClient client, CanvasSyncBridge bridge) =
          makeBridge(db: db, baseDir: dir);

      // Strictly older — rejected.
      client.emitRpc(
        putEnvelope(buildDoc(id: 'c2', title: 'Stale', now: 199)),
      );
      await settle();
      // Equal updated_at — §9.1 keeps the local copy (no churn).
      client.emitRpc(
        putEnvelope(buildDoc(id: 'c2', title: 'Echo', now: 200)),
      );
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.hubChanged.value, 0); // no store mutation happened
      final CanvasDocumentModel stored = await loadDocument('c2', baseDir: dir);
      expect(stored.title, 'Local');
      expect(stored.updatedAt, 200);
      final CanvasRecord? rec = await db.get('c2');
      expect(rec!.title, 'Local');
      expect(bridge.remoteOpen.value, isNull); // never navigates
      expect(client.sent, isEmpty);
    });

    test('malformed CANVAS_PUT payloads are ignored safely', () async {
      final LocalDb db = await openDb('put_malformed');
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        db: db,
        baseDir: cacheDir(),
      );

      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PUT',
        'canvas_id': '',
        'payload': <String, dynamic>{'canvas': <String, dynamic>{'bogus': 1}},
      });
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PUT',
        'canvas_id': '',
        'payload': <String, dynamic>{}, // no canvas key at all
      });
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PUT',
        'canvas_id': '',
        'payload': <String, dynamic>{'canvas': 'not-a-map'},
      });
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PUT',
        'payload': 'not-even-a-map',
      });
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bridge.hubChanged.value, 0);
      expect(bridge.remoteOpen.value, isNull);
      expect(client.sent, isEmpty); // nothing crashes, nothing leaks out
    });
  });

  // -------------------------------------------------------------------------
  // CANVAS_PULL receive (§9.1)
  // -------------------------------------------------------------------------

  group('CANVAS_PULL receive', () {
    test('replies CANVAS_PUT {source:"device"} only when strictly newer, '
        'with the exact payload', () async {
      final LocalDb db = await openDb('pull');
      final String dir = cacheDir();
      final CanvasDocumentModel local = buildDoc(
        id: 'c9',
        title: 'Mine',
        now: 500,
      );
      await seedLocal(db, local, dir);
      final (_FakeClient client, CanvasSyncBridge bridge) =
          makeBridge(db: db, baseDir: dir);

      // 499 < 500 ⇒ reply.
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PULL',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'canvas_id': 'c9',
          'have_updated_at': 499,
        },
      });
      await waitFor(
        () => client.sent.isNotEmpty,
        description: 'CANVAS_PUT reply to PULL',
      );

      final Map<String, dynamic> env = client.sent.single;
      expect(env.keys, <String>['type', 'action', 'canvas_id', 'payload']);
      expect(env['action'], 'CANVAS_PUT');
      expect(env['canvas_id'], 'c9');
      final Map<String, dynamic> payload =
          Map<String, dynamic>.from(env['payload'] as Map);
      expect(payload.keys, unorderedEquals(<String>['canvas', 'source']));
      expect(payload['source'], 'device');
      expect(payload['canvas'], equals(local.toJson()));
      expect(bridge.remoteOpen.value, isNull); // replies never switch

      // Equal (500) and newer (501) requesters ⇒ silence.
      client.sent.clear();
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PULL',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'canvas_id': 'c9',
          'have_updated_at': 500,
        },
      });
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PULL',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'canvas_id': 'c9',
          'have_updated_at': 501,
        },
      });
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.sent, isEmpty);

      // Unknown local id ⇒ no reply either.
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_PULL',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'canvas_id': 'nope',
          'have_updated_at': 0,
        },
      });
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.sent, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Hub list → diff pulls (§9.4.1)
  // -------------------------------------------------------------------------

  group('CANVAS_LIST (origin:hub)', () {
    test('pulls exactly the missing ids sequentially and dedupes '
        '(no re-pull after the PUT lands)', () async {
      final LocalDb db = await openDb('hub_list');
      final String dir = cacheDir();
      await seedLocal(db, buildDoc(id: 'a', title: 'A', now: 100), dir);
      final (_FakeClient client, CanvasSyncBridge bridge) =
          makeBridge(db: db, baseDir: dir);

      int changes = 0;
      bridge.hubChanged.addListener(() => changes += 1);

      client.emitRpc(hubListEnvelope(<Map<String, dynamic>>[
        hubRow('a', 'A', 100),
        hubRow('b', 'B', 200),
        hubRow('c', 'C', 300),
      ]));

      await waitFor(
        () => _actionsOf(client, 'CANVAS_PULL').length == 2,
        description: 'two CANVAS_PULLs for missing ids',
      );

      // Exactly b and c (a is local), in hub order, have_updated_at 0.
      final List<Map<String, dynamic>> pulls = _actionsOf(client, 'CANVAS_PULL');
      expect(pulls, hasLength(2));
      expect(
        pulls.map(
          (Map<String, dynamic> e) => (e['payload'] as Map)['canvas_id'],
        ),
        <String>['b', 'c'],
      );
      for (final Map<String, dynamic> pull in pulls) {
        expect(
          pull.keys,
          <String>['type', 'action', 'canvas_id', 'payload'],
        );
        final Map<String, dynamic> payload =
            Map<String, dynamic>.from(pull['payload'] as Map);
        expect(
          payload.keys,
          unorderedEquals(<String>['canvas_id', 'have_updated_at']),
        );
        expect(payload['have_updated_at'], 0);
      }
      // Sequential, not a burst: ~100 ms between the two sends.
      expect(
        client.sentAt[1].difference(client.sentAt[0]).inMilliseconds,
        greaterThanOrEqualTo(80),
      );
      // The merged hub view fired hubChanged (pre-seeded §9 contract).
      expect(changes, greaterThanOrEqualTo(1));

      // The hub answers the first pull — PUT b stores silently.
      final int beforePut = bridge.hubChanged.value;
      final CanvasDocumentModel docB = buildDoc(id: 'b', title: 'B', now: 200);
      client.emitRpc(putEnvelope(docB));
      await waitFor(
        () => bridge.hubChanged.value > beforePut,
        description: 'hubChanged after pulled PUT',
      );
      final CanvasRecord? recB = await db.get('b');
      expect(recB, isNotNull);
      expect(recB!.updatedAt, 200);
      expect(bridge.remoteOpen.value, isNull); // store-only, no navigation

      // The same hub list again: b is now present, c was already
      // requested ⇒ exactly-once dedupe, zero new pulls.
      final int pullsBefore = _actionsOf(client, 'CANVAS_PULL').length;
      client.emitRpc(hubListEnvelope(<Map<String, dynamic>>[
        hubRow('a', 'A', 100),
        hubRow('b', 'B', 200),
        hubRow('c', 'C', 300),
      ]));
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        _actionsOf(client, 'CANVAS_PULL'),
        hasLength(pullsBefore),
      );
      expect(pullsBefore, 2);
    });

    test('non-hub CANVAS_LIST (origin:device / legacy) triggers no pulls',
        () async {
      final LocalDb db = await openDb('device_list');
      final (_FakeClient client, CanvasSyncBridge bridge) = makeBridge(
        db: db,
        baseDir: cacheDir(),
      );

      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_LIST',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'origin': 'device',
          'canvases': <Map<String, dynamic>>[hubRow('ghost', 'G', 10)],
        },
      });
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_LIST',
        'canvas_id': '',
        'payload': <String, dynamic>{
          // legacy round-4 shape — no origin/device_id at all
          'canvases': <Map<String, dynamic>>[hubRow('ghost2', 'G2', 10)],
        },
      });
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(_actionsOf(client, 'CANVAS_PULL'), isEmpty);
      expect(bridge.hubChanged.value, 0);
      expect(bridge.remoteOpen.value, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Persist-on-open ordering (§9.3)
  // -------------------------------------------------------------------------

  group('persist-on-open (§9.3)', () {
    test('remote OPEN_CANVAS saves locally BEFORE firing remoteOpen',
        () async {
      final LocalDb db = await openDb('persist_order');
      final String dir = cacheDir();
      final _FakeClient client = _FakeClient();
      clients.add(client);
      final CanvasSyncBridge bridge = CanvasSyncBridge(
        client: client,
        db: db,
        baseDir: dir,
        deviceFilePath: '${tmp.path}/slatesync_device.json',
        saver: (CanvasDocumentModel doc, {String? baseDir}) async {
          client.log.add('save:${doc.canvasId}');
          return saveDocument(doc, baseDir: baseDir);
        },
      );
      bridges.add(bridge);
      bridge.remoteOpen.addListener(() => client.log.add('remote'));

      final CanvasDocumentModel doc = buildDoc(
        id: 'pc-9',
        title: 'Hub Open',
        now: 900,
      );
      client.emitRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'OPEN_CANVAS',
        'canvas_id': 'pc-9',
        'payload': <String, dynamic>{'canvas': doc.toJson()},
      });

      await waitFor(
        () => bridge.remoteOpen.value != null,
        description: 'remoteOpen after persist',
      );

      // Order proof: the saver ran before the switch was fired.
      expect(client.log, <String>['save:pc-9', 'remote']);
      // …and the persistence is real: zip + row exist (row upsert and
      // hubChanged trail the switch by a beat).
      await waitFor(
        () => bridge.hubChanged.value > 0,
        description: 'hubChanged after row upsert',
      );
      final CanvasDocumentModel stored = await loadDocument(
        'pc-9',
        baseDir: dir,
      );
      expect(stored.toJson(), equals(doc.toJson()));
      final CanvasRecord? rec = await db.get('pc-9');
      expect(rec, isNotNull);
      expect(rec!.updatedAt, 900);
      expect(bridge.remoteOpen.value!.toJson(), equals(doc.toJson()));
      // Persist-on-open never echoes back to the hub.
      expect(client.sent, isEmpty);
    });
  });
}
