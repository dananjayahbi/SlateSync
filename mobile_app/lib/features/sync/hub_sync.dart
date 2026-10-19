/// Doc 02 §9 — Round-5 hub sync helpers for `CanvasSyncBridge`:
///
///  * [DeviceIdentity] — the stable per-install `device_id` (§9.2): a
///    uuid-v4 generated once and persisted as `slatesync_device.json`
///    (path_provider app-support by default; injectable file path for
///    tests). Returns `null` when no storage is reachable so callers can
///    publish the spec-sanctioned legacy list (missing `device_id` ⇒
///    `legacy-<conn>` at the hub).
///  * [HubListCache] — merged view of incoming `CANVAS_LIST (origin:hub)`
///    rows plus the pull-dedupe registry (§9.4.1: never re-pull an id that
///    was already requested or is present locally).
///  * Envelope/payload builders for the round-5 actions with the exact
///    §9.1/§9.2 key sets.
///
/// Pure data + file helpers — all wire I/O and store mutation stays in
/// `CanvasSyncBridge`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/network/vector_sync_client.dart' show uuidV4;

// ---------------------------------------------------------------------------
// Device identity (§9.2)
// ---------------------------------------------------------------------------

/// Stable device identity for `CANVAS_LIST` v2 publishes.
class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, this.deviceName});

  /// uuid-v4 generated once per app install (§9.2).
  final String deviceId;

  /// Optional display name published as `device_name` (may be null).
  final String? deviceName;

  /// File name persisted under path_provider app-support.
  static const String fileName = 'slatesync_device.json';

  /// Loads the persisted identity, generating and persisting one on first
  /// use. [filePath] injects the full json path for tests. Returns `null`
  /// only when no storage location is reachable at all — callers then
  /// publish a legacy list without `device_id` (§9.2 `legacy-<conn>`).
  static Future<DeviceIdentity?> load({
    String? filePath,
    String? deviceName,
  }) async {
    try {
      final String path = filePath ?? await _defaultPath();
      final File file = File(path);
      String? storedId;
      String? storedName;
      if (file.existsSync()) {
        try {
          final Object? raw = jsonDecode(await file.readAsString());
          if (raw is Map) {
            final Object? id = raw['device_id'];
            if (id is String && id.isNotEmpty) {
              storedId = id;
              final Object? name = raw['device_name'];
              storedName = name is String ? name : null;
            }
          }
        } catch (_) {
          // Corrupt identity file — regenerate below.
        }
      }
      if (storedId == null) {
        storedId = uuidV4();
        try {
          await file.parent.create(recursive: true);
          await file.writeAsString(
            jsonEncode(<String, dynamic>{
              'device_id': storedId,
              'device_name': deviceName,
            }),
            flush: true,
          );
        } catch (e) {
          // Session-stable even when the file cannot be written; the next
          // cold start would regenerate — log loudly for diagnosis.
          debugPrint('slatesync: could not persist device_id ($e)');
        }
      }
      return DeviceIdentity(
        deviceId: storedId,
        deviceName: deviceName ?? storedName,
      );
    } catch (e) {
      debugPrint('slatesync: device identity unavailable ($e)');
      return null;
    }
  }

  static Future<String> _defaultPath() async {
    final Directory dir = await getApplicationSupportDirectory();
    return '${dir.path}/$fileName';
  }
}

// ---------------------------------------------------------------------------
// Envelope builders (§9.1 / §9.2 — exact payload key sets)
// ---------------------------------------------------------------------------

/// `CANVAS_LIST` payload, v2 (§9.2): `{device_id?, device_name, origin,
/// canvases}`. `device_id` is OMITTED only when [deviceId] is null (no
/// storage — legacy publish); `device_name` is always present and may be
/// null.
Map<String, dynamic> canvasListPayload({
  required String? deviceId,
  required String? deviceName,
  required String origin,
  required List<Map<String, dynamic>> canvases,
}) => <String, dynamic>{
      if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
      'device_name': deviceName,
      'origin': origin,
      'canvases': canvases,
    };

/// Full `CANVAS_LIST` envelope (v2 payload).
Map<String, dynamic> canvasListEnvelope({
  required String? deviceId,
  required String? deviceName,
  required String origin,
  required List<Map<String, dynamic>> canvases,
}) => <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': 'CANVAS_LIST',
      'canvas_id': '',
      'payload': canvasListPayload(
        deviceId: deviceId,
        deviceName: deviceName,
        origin: origin,
        canvases: canvases,
      ),
    };

/// `CANVAS_PUT {canvas, source}` (§9.1) — full Doc 03 body.
Map<String, dynamic> canvasPutEnvelope(
  CanvasDocumentModel doc, {
  required String source,
}) => <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': 'CANVAS_PUT',
      'canvas_id': doc.canvasId,
      'payload': <String, dynamic>{'canvas': doc.toJson(), 'source': source},
    };

/// `CANVAS_PULL {canvas_id, have_updated_at}` (§9.1).
Map<String, dynamic> canvasPullEnvelope(
  String canvasId,
  int haveUpdatedAt,
) => <String, dynamic>{
      'type': 'CANVAS_LIFECYCLE',
      'action': 'CANVAS_PULL',
      'canvas_id': '',
      'payload': <String, dynamic>{
        'canvas_id': canvasId,
        'have_updated_at': haveUpdatedAt,
      },
    };

// ---------------------------------------------------------------------------
// Hub list cache (§9.4.1)
// ---------------------------------------------------------------------------

/// Merged view of the hub's `CANVAS_LIST (origin:hub)` plus the "already
/// asked for" registry that makes pulls exactly-once per session.
class HubListCache {
  final Map<String, Map<String, dynamic>> _rows =
      <String, Map<String, dynamic>>{};
  final Set<String> _requested = <String>{};

  /// Last merged hub rows keyed by canvas id (read-only snapshot).
  Map<String, Map<String, dynamic>> get rows => Map<String, Map<String, dynamic>>.unmodifiable(_rows);

  /// Ids already pulled this session (never re-pulled, §9.4.1).
  Set<String> get requestedIds => Set<String>.unmodifiable(_requested);

  /// Union-merge of a hub `canvases` array (keyed by id). Rows without a
  /// non-empty string `id` are skipped (malformed rows are never fatal).
  /// Returns the number of rows merged.
  int merge(Iterable<Map<String, dynamic>> canvases) {
    int merged = 0;
    for (final Map<String, dynamic> row in canvases) {
      final Object? id = row['id'];
      if (id is String && id.isNotEmpty) {
        _rows[id] = row;
        merged += 1;
      }
    }
    return merged;
  }

  /// Ids the hub knows that the local store lacks and this session never
  /// asked for, in hub order. Returned ids are marked requested
  /// immediately — a second hub list (or a slow PUT) can never trigger the
  /// same pull twice.
  List<String> takeMissing(Set<String> localIds) {
    final List<String> missing = <String>[];
    for (final String id in _rows.keys) {
      if (localIds.contains(id) || _requested.contains(id)) continue;
      _requested.add(id);
      missing.add(id);
    }
    return missing;
  }
}
