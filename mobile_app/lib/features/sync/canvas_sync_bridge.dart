/// Doc 02 §8 + §9 — Canvas Sync bridge (Issue 04, rounds 4+5): the tablet
/// side of bidirectional canvas synchronization over the injected Doc 25
/// [VectorSyncClient].
///
/// Round-4 action set (§8.1) handled here:
///  * [publishList] sends `CANVAS_LIST` built from [LocalDb] rows sorted
///    `updated_at DESC` (round-5 v2 wrapper below). Pushed automatically
///    when the client reaches [SyncState.online], in reply to every
///    `CANVAS_LIST_REQUEST`, and callable directly — the home dashboard
///    wires create/rename/delete into it.
///  * `CANVAS_OPEN_REQUEST {payload.canvas_id}` → load the document from
///    the tablet store (Doc 26 [loadDocument], same `baseDir` default),
///    broadcast `OPEN_CANVAS {canvas: <full Doc 03 body>}` and fire
///    [remoteOpen] so the tablet switches its own UI too (§8.3.3).
///  * `OPEN_CANVAS` with `payload.canvas` → parse the full
///    [CanvasDocumentModel] and fire [remoteOpen] — how the tablet follows
///    PC-initiated opens. The legacy `payload.path` dialect (§8.2,
///    PC-internal only) is never a tablet input and is IGNORED.
///  * [announceOpen] broadcasts `OPEN_CANVAS {canvas: doc.toJson()}` for
///    mobile-driven open/create/switch (§8.3.1 — the PC follows).
///
/// Round-5 hub action set (§9) handled here:
///  * `CANVAS_LIST` publish is now **v2** (§9.2): `{device_id, device_name,
///    origin: "device", canvases}` with the stable [DeviceIdentity] uuid
///    persisted to `slatesync_device.json` (see `hub_sync.dart`).
///  * `CANVAS_PUT {canvas, source}` → **LWW** apply (only when
///    `updated_at` is strictly newer; equal ⇒ keep local, §9.1) →
///    persist via `saveDocument` + `LocalDb` row upsert → fire
///    [hubChanged] → **never navigates**.
///  * `CANVAS_PULL {canvas_id, have_updated_at}` → reply `CANVAS_PUT
///    {source: "device"}` only when the local document's `updated_at` is
///    strictly greater than `have_updated_at` (§9.1).
///  * `CANVAS_LIST (origin: "hub")` → merge into the internal
///    [HubListCache], fire [hubChanged], diff ids the local store lacks →
///    send `CANVAS_PULL {canvas_id, have_updated_at: 0}` sequentially
///    (~100 ms apart) with exactly-once dedupe (§9.4.1).
///  * Persist-on-open (§9.3): remote `OPEN_CANVAS {canvas}` stores the
///    document (LWW) **before** firing [remoteOpen].
///  * Malformed payloads log + ignore; unknown actions fall through
///    untouched (§8.5 receive tolerance).
///
/// Navigator hand-off: main.dart listens on [remoteOpen], navigates
/// through its `navigatorKey`, then clears the value (single-shot). The
/// optional [onRemoteOpen] constructor callback is an equivalent
/// push-style seam for embedders that prefer it; consumers use one of the
/// two, not both.
///
/// Incoming actions are NEVER rejected: unknown/round-4 actions fall
/// through the default branch untouched (§8.5 receive tolerance).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/sync/hub_sync.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class CanvasSyncBridge {
  CanvasSyncBridge({
    required this.client,
    this.db,
    String? baseDir,
    Future<CanvasDocumentModel> Function(String id)? loader,
    Future<String> Function(CanvasDocumentModel doc, {String? baseDir})?
        saver,
    this.deviceFilePath,
    this.deviceName,
    this.onRemoteOpen,
  }) : _loader = loader ?? ((String id) => loadDocument(id, baseDir: baseDir)),
       _saver = saver ??
           ((CanvasDocumentModel doc, {String? baseDir}) =>
               saveDocument(doc, baseDir: baseDir)),
       _baseDir = baseDir {
    _subscription = client.events.listen(_onSyncEvent);
  }

  /// Doc 25 client the bridge rides: events in, `CANVAS_LIST` /
  /// `OPEN_CANVAS` envelopes out.
  final VectorSyncClient client;

  /// Rows source for [publishList]. `null` ⇒ opened on demand: sqflite's
  /// single-instance semantics share the dashboard's connection for the
  /// same path, and a fresh one is picked up after the owner closes — so
  /// the bridge never closes a connection it does not own.
  final LocalDb? db;

  /// Doc 26 document loader; default reuses [loadDocument] with its
  /// standard `baseDir` default (path_provider app-documents/SlateSync).
  final Future<CanvasDocumentModel> Function(String id) _loader;

  /// Doc 26 document saver; default reuses [saveDocument] against [_baseDir].
  /// Injectable so tests can observe persist-before-switch ordering (§9.3).
  final Future<String> Function(CanvasDocumentModel doc, {String? baseDir})
      _saver;

  /// Document-directory seam shared by loader and saver defaults.
  final String? _baseDir;

  /// Full path of the persisted device-identity json (§9.2). `null` ⇒
  /// path_provider app-support `slatesync_device.json`; injected by tests.
  final String? deviceFilePath;

  /// Optional published `device_name` (§9.2); defaults to null.
  final String? deviceName;

  /// Optional push-style navigator callback (see library docs).
  final void Function(CanvasDocumentModel doc)? onRemoteOpen;

  /// Single-shot hand-off for consumers that listen instead (main.dart).
  final ValueNotifier<CanvasDocumentModel?> remoteOpen =
      ValueNotifier<CanvasDocumentModel?>(null);

  /// Round-5 hub contract (Doc 02 §9): fired after ANY remote store mutation
  /// (CANVAS_PUT applied, hub list merged, pulls completed). main.dart wires
  /// this to the gallery refresh. Never removed — hub agent must keep it.
  final ValueNotifier<int> hubChanged = ValueNotifier<int>(0);

  late final StreamSubscription<SyncEvent> _subscription;
  bool _disposed = false;

  /// Lazily loaded, cached device identity (§9.2); `null` result (no
  /// storage reachable) is cached too — later publishes fall back to the
  /// legacy payload without `device_id`.
  Future<DeviceIdentity?>? _identityFuture;

  /// Merged hub list + pull-dedupe registry (§9.4.1).
  final HubListCache _hubList = HubListCache();

  /// Serializes hub-list processing so concurrent lists can never double
  /// pull the same id (dedupe happens inside [HubListCache.takeMissing]).
  Future<void> _hubChain = Future<void>.value();

  Future<DeviceIdentity?> _identity() => _identityFuture ??=
      DeviceIdentity.load(filePath: deviceFilePath, deviceName: deviceName);

  // -------------------------------------------------------------------------
  // Send side (Doc 02 §8.1 / §8.3)
  // -------------------------------------------------------------------------

  /// Sends `CANVAS_LIST` **v2** (§9.2) with the current [LocalDb] rows
  /// (already ordered `updated_at DESC`); may be EMPTY. Payload:
  /// `{device_id, device_name, origin: "device", canvases}` — `device_id`
  /// comes from the persisted [DeviceIdentity]; when no identity storage
  /// is reachable the key is omitted (legacy publish, §9.2). Errors are
  /// swallowed: the push is best-effort and the local store may be
  /// mid-shutdown.
  Future<void> publishList() async {
    if (_disposed) return;
    try {
      final LocalDb source = db ?? await LocalDb.open();
      final List<CanvasRecord> rows = await source.list();
      if (_disposed) return;
      final DeviceIdentity? identity = await _identity();
      if (_disposed) return;
      await client.sendRpc(
        canvasListEnvelope(
          deviceId: identity?.deviceId,
          deviceName: identity?.deviceName,
          origin: 'device',
          canvases: rows
              .map(
                (CanvasRecord r) => <String, dynamic>{
                  'id': r.id,
                  'title': r.title,
                  'preset': r.preset,
                  'background': r.background,
                  'updated_at': r.updatedAt,
                },
              )
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // Local store unavailable (widget test / teardown) — skip this push.
    }
  }

  /// Broadcasts `OPEN_CANVAS {canvas: <full Doc 03 body>}` for a
  /// tablet-driven open/create/switch so the PC mirrors it (§8.3.1).
  Future<void> announceOpen(CanvasDocumentModel doc) async {
    if (_disposed) return;
    await client.sendRpc(_openEnvelope(doc));
  }

  /// §8.2 cross-device dialect: `payload.canvas` carries the complete
  /// snake_case document body; top-level `canvas_id` mirrors the open id.
  Map<String, dynamic> _openEnvelope(CanvasDocumentModel doc) =>
      <String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'OPEN_CANVAS',
        'canvas_id': doc.canvasId,
        'payload': <String, dynamic>{'canvas': doc.toJson()},
      };

  // -------------------------------------------------------------------------
  // Receive side (Doc 02 §8.2–§8.3; unknown actions tolerated)
  // -------------------------------------------------------------------------

  void _onSyncEvent(SyncEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case SyncEventKind.stateChanged:
        if (event.state == SyncState.online) {
          unawaited(publishList()); // §8.3.2 handshake push
        }
      case SyncEventKind.rpcReceived:
        _handleRpc(event.msg ?? const <String, dynamic>{});
      default:
        break; // progress / file transfer events belong to Doc 25 flows
    }
  }

  void _handleRpc(Map<String, dynamic> msg) {
    final Object? action = msg['action'];
    switch (action) {
      case 'CANVAS_LIST_REQUEST': // §8.1 — reply with the current rows
        unawaited(publishList());
      case 'CANVAS_OPEN_REQUEST': // §8.1 — load, broadcast, switch both
        final Object? raw = msg['payload'];
        final Object? id = raw is Map ? raw['canvas_id'] : null;
        if (id is String && id.isNotEmpty) {
          unawaited(_handleOpenRequest(id));
        }
      case 'OPEN_CANVAS': // §8.2 canvas dialect + §9.3 persist-on-open
        final Object? raw = msg['payload'];
        final Object? canvas = raw is Map ? raw['canvas'] : null;
        if (canvas is Map) {
          try {
            unawaited(
              _persistThenOpen(
                CanvasDocumentModel.fromJson(
                  Map<String, dynamic>.from(canvas),
                ),
              ),
            );
          } catch (e) {
            // Malformed document body — never crash the sync pipeline.
            debugPrint('slatesync: ignoring malformed OPEN_CANVAS ($e)');
          }
        }
      case 'CANVAS_PUT': // §9.1 — LWW store, never navigates
        final Object? raw = msg['payload'];
        final Object? canvas = raw is Map ? raw['canvas'] : null;
        if (canvas is Map) {
          try {
            unawaited(
              _applyRemotePut(
                CanvasDocumentModel.fromJson(
                  Map<String, dynamic>.from(canvas),
                ),
              ),
            );
          } catch (e) {
            debugPrint('slatesync: ignoring malformed CANVAS_PUT ($e)');
          }
        }
      case 'CANVAS_PULL': // §9.1 — reply only when strictly newer
        final Object? raw = msg['payload'];
        if (raw is Map) {
          final Object? id = raw['canvas_id'];
          if (id is String && id.isNotEmpty) {
            final Object? have = raw['have_updated_at'];
            unawaited(
              _handleRemotePull(id, have is num ? have.toInt() : 0),
            );
          }
        }
      case 'CANVAS_LIST': // §9.2 — only origin:"hub" lists drive pulls
        final Object? raw = msg['payload'];
        if (raw is Map) {
          final Object? origin = raw['origin'];
          final Object? list = raw['canvases'];
          if (origin == 'hub' && list is List) {
            final List<Map<String, dynamic>> canvases = list
                .whereType<Map<dynamic, dynamic>>()
                .map(Map<String, dynamic>.from)
                .toList(growable: false);
            unawaited(_enqueueHubList(canvases));
          }
        }
      default:
        break; // unknown incoming actions are never rejected (§8.5)
    }
  }

  /// §8.3.3: load from the tablet store → broadcast the full document →
  /// switch the tablet UI as well.
  Future<void> _handleOpenRequest(String canvasId) async {
    if (_disposed) return;
    try {
      final CanvasDocumentModel doc = await _loader(canvasId);
      await client.sendRpc(_openEnvelope(doc));
      _fireRemote(doc);
    } catch (_) {
      // No local cache for that id — nothing to broadcast or switch to.
    }
  }

  void _fireRemote(CanvasDocumentModel doc) {
    if (_disposed) return;
    remoteOpen.value = doc;
    onRemoteOpen?.call(doc);
  }

  // -------------------------------------------------------------------------
  // Round-5 hub flows (Doc 02 §9)
  // -------------------------------------------------------------------------

  /// §9.3 persist-on-open: store the incoming document first (LWW per
  /// §9.1), THEN switch the tablet UI. Persistence failures are logged and
  /// never block the switch — the hub told us to open this document.
  /// §9.3 persist-on-open: store the incoming document first (LWW per
  /// §9.1), THEN switch the tablet UI — the switch fires from inside
  /// [afterSave] as soon as the document is on disk; gallery-row upsert
  /// trails it. When LWW keeps the local copy (or storage is unavailable)
  /// the switch still happens — the hub directed this open either way.
  Future<void> _persistThenOpen(CanvasDocumentModel doc) async {
    bool fired = false;
    await _applyRemotePut(
      doc,
      afterSave: () {
        fired = true;
        _fireRemote(doc);
      },
    );
    if (!fired) _fireRemote(doc);
  }

  /// §9.1 LWW apply of a remote document: run only when its `updated_at`
  /// is strictly greater than the **local document's** (equal ⇒ keep
  /// local, no churn — which also drops echoes of our own publishes).
  ///
  /// Latency shape matters: widget tests give async chains only a handful
  /// of real-event-loop windows, so everything that can overlap does —
  /// the local-document probe (LWW authority), the database warm-up and
  /// the row read all start together; the serial tail is exactly the
  /// document save. [afterSave] (§9.3 switch) runs immediately after the
  /// save; the `LocalDb` row upsert and [hubChanged] follow. Never throws
  /// (malformed/unavailable storage is logged + ignored).
  Future<bool> _applyRemotePut(
    CanvasDocumentModel incoming, {
    void Function()? afterSave,
  }) async {
    if (_disposed) return false;
    try {
      final Future<CanvasDocumentModel?> localDoc = _loader(incoming.canvasId)
          .then<CanvasDocumentModel?>((CanvasDocumentModel d) => d)
          .catchError((Object _) => null);
      final Future<LocalDb> dbReady = db != null
          ? Future<LocalDb>.value(db)
          : LocalDb.open();
      final Future<CanvasRecord?> rowReady = dbReady
          .then((LocalDb source) => source.get(incoming.canvasId))
          .catchError((Object _) => null);

      final CanvasDocumentModel? local = await localDoc;
      final int localUpdatedAt = local?.updatedAt ?? -1;
      // §9.1: apply only if incoming.updated_at > local (equal ⇒ skip).
      if (incoming.updatedAt <= localUpdatedAt) return false;

      final String path = await _saver(incoming, baseDir: _baseDir);
      if (!_disposed) afterSave?.call(); // §9.3: switch after the save

      final LocalDb source = await dbReady;
      final CanvasRecord? row = await rowReady;
      if (row == null) {
        await source.insertCanvas(
          CanvasRecord(
            id: incoming.canvasId,
            title: incoming.title,
            preset: incoming.artboard.preset,
            background: incoming.artboard.backgroundStyle,
            thumbPath: '',
            filePath: path,
            updatedAt: incoming.updatedAt,
          ),
        );
      } else {
        await source.update(
          CanvasRecord(
            id: incoming.canvasId,
            title: incoming.title,
            preset: incoming.artboard.preset,
            background: incoming.artboard.backgroundStyle,
            thumbPath: row.thumbPath,
            filePath: path,
            updatedAt: incoming.updatedAt,
          ),
        );
      }
      if (!_disposed) hubChanged.value += 1; // remote store mutation (§9)
      return true;
    } catch (e) {
      debugPrint('slatesync: CANVAS_PUT apply failed ($e)');
      return false;
    }
  }

  /// §9.1 PULL: reply `CANVAS_PUT {source: "device"}` only when the local
  /// document is strictly newer than what the requester already has.
  Future<void> _handleRemotePull(String canvasId, int haveUpdatedAt) async {
    if (_disposed) return;
    try {
      final CanvasDocumentModel doc = await _loader(canvasId);
      if (_disposed) return;
      if (doc.updatedAt > haveUpdatedAt) {
        await client.sendRpc(canvasPutEnvelope(doc, source: 'device'));
      }
    } catch (_) {
      // Unknown local canvas — reply nothing (§9.1).
    }
  }

  /// Chains hub-list processing so overlapping lists never race the pull
  /// dedupe.
  Future<void> _enqueueHubList(List<Map<String, dynamic>> canvases) {
    _hubChain = _hubChain
        .then((_) => _processHubList(canvases))
        .catchError((Object e) {
          debugPrint('slatesync: hub list processing failed ($e)');
        });
    return _hubChain;
  }

  /// §9.4.1: merge the hub list into the cached view (fires [hubChanged]),
  /// diff ids the local store lacks and send `CANVAS_PULL` sequentially
  /// (~100 ms apart to avoid bursts). [HubListCache] guarantees each id is
  /// pulled at most once per session and never when already present.
  Future<void> _processHubList(List<Map<String, dynamic>> canvases) async {
    if (_disposed) return;
    _hubList.merge(canvases);
    if (!_disposed) hubChanged.value += 1; // cached hub view changed (§9)
    try {
      final LocalDb source = db ?? await LocalDb.open();
      final List<CanvasRecord> rows = await source.list();
      final Set<String> localIds =
          rows.map((CanvasRecord r) => r.id).toSet();
      final List<String> missing = _hubList.takeMissing(localIds);
      for (int i = 0; i < missing.length; i++) {
        if (_disposed) return;
        if (i > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await client.sendRpc(canvasPullEnvelope(missing[i], 0));
      }
    } catch (e) {
      debugPrint('slatesync: hub list processing failed ($e)');
    }
  }

  // -------------------------------------------------------------------------

  /// Cancels the event subscription and invalidates [remoteOpen]. Safe to
  /// call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    remoteOpen.dispose();
  }
}
