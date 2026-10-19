/// Doc 02 §8 — Canvas Sync bridge (Issue 04, round 4): the tablet side of
/// bidirectional canvas synchronization over the injected Doc 25
/// [VectorSyncClient].
///
/// Round-4 action set (§8.1) handled here:
///  * [publishList] sends `CANVAS_LIST` built from [LocalDb] rows
///    (`{canvases:[{id,title,preset,background,updated_at}]}` sorted
///    `updated_at DESC`). Pushed automatically when the client reaches
///    [SyncState.online], in reply to every `CANVAS_LIST_REQUEST`, and
///    callable directly — the home dashboard wires create/rename/delete
///    into it.
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
import 'package:mobile_app/network/vector_sync_client.dart';

class CanvasSyncBridge {
  CanvasSyncBridge({
    required this.client,
    this.db,
    String? baseDir,
    Future<CanvasDocumentModel> Function(String id)? loader,
    this.onRemoteOpen,
  }) : _loader = loader ?? ((String id) => loadDocument(id, baseDir: baseDir)) {
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

  /// Optional push-style navigator callback (see library docs).
  final void Function(CanvasDocumentModel doc)? onRemoteOpen;

  /// Single-shot hand-off for consumers that listen instead (main.dart).
  final ValueNotifier<CanvasDocumentModel?> remoteOpen =
      ValueNotifier<CanvasDocumentModel?>(null);

  late final StreamSubscription<SyncEvent> _subscription;
  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Send side (Doc 02 §8.1 / §8.3)
  // -------------------------------------------------------------------------

  /// Sends `CANVAS_LIST` with the current [LocalDb] rows (already ordered
  /// `updated_at DESC`); may be EMPTY. Errors are swallowed: the push is
  /// best-effort and the local store may be mid-shutdown.
  Future<void> publishList() async {
    if (_disposed) return;
    try {
      final LocalDb source = db ?? await LocalDb.open();
      final List<CanvasRecord> rows = await source.list();
      if (_disposed) return;
      await client.sendRpc(<String, dynamic>{
        'type': 'CANVAS_LIFECYCLE',
        'action': 'CANVAS_LIST',
        'canvas_id': '',
        'payload': <String, dynamic>{
          'canvases': rows
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
        },
      });
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
      case 'OPEN_CANVAS': // §8.2 — `canvas` dialect only; `path` ignored
        final Object? raw = msg['payload'];
        final Object? canvas = raw is Map ? raw['canvas'] : null;
        if (canvas is Map) {
          try {
            _fireRemote(
              CanvasDocumentModel.fromJson(Map<String, dynamic>.from(canvas)),
            );
          } catch (_) {
            // Malformed document body — never crash the sync pipeline.
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

  /// Cancels the event subscription and invalidates [remoteOpen]. Safe to
  /// call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    remoteOpen.dispose();
  }
}
