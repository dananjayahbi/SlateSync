/// Round-6 (Doc 02 §10.2) — live mutation relay, receive side.
///
/// The PC re-broadcasts every incoming `ELEMENT_COMMIT` (incl.
/// `CLEAR_CANVAS`) and `ARTBOARD_RESIZE` envelope to the *other*
/// connections; a device applies one only when `msg.canvas_id` equals its
/// currently-open document (else it is ignored silently). The hub excludes
/// the original sender, so normally no echo ever arrives here — the
/// node-id / emptiness guards below are a harmless belt-and-braces layer
/// for misbehaving relays.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart';
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// `ELEMENT_COMMIT` actions that add one node from `payload` (Doc 02 §4.2 /
/// §10.1 action set).
const Set<String> kRemoteAddActions = <String>{
  'ADD_STROKE',
  'ADD_SHAPE',
  'ADD_GRAPH',
  'ADD_IMAGE',
};

/// `content_bounds` union of [current] with [r]; all-zero (empty) bounds
/// adopt [r] directly — same rule the canvas page has always used.
Map<String, double> unionContentBounds(Map<String, double> current, Rect r) {
  final double minX = current['min_x'] ?? 0;
  final double minY = current['min_y'] ?? 0;
  final double maxX = current['max_x'] ?? 0;
  final double maxY = current['max_y'] ?? 0;
  if (minX == 0 && minY == 0 && maxX == 0 && maxY == 0) {
    return <String, double>{
      'min_x': r.left,
      'min_y': r.top,
      'max_x': r.right,
      'max_y': r.bottom,
    };
  }
  return <String, double>{
    'min_x': math.min(minX, r.left),
    'min_y': math.min(minY, r.top),
    'max_x': math.max(maxX, r.right),
    'max_y': math.max(maxY, r.bottom),
  };
}

/// Doc 02 §10.1 wipe: ALL elements leave the document (artboard, background
/// and title preserved); `content_bounds` returns to the empty zeros so the
/// doc counts as empty again for Doc 23's upgrade rule. Shared by the local
/// clear handler and the remote `CLEAR_CANVAS` path.
void wipeDocumentElements({
  required CanvasDocumentModel doc,
  required TiledCanvasEngine engine,
  required ArtboardManager artboard,
}) {
  doc.elements.clear();
  artboard.resetContent();
  doc.contentBounds = <String, double>{
    'min_x': 0,
    'min_y': 0,
    'max_x': 0,
    'max_y': 0,
  };
  engine.clearAll();
}

/// Applies one incoming RPC envelope to the open document's local state
/// (Doc 02 §10.2). Returns `true` when something actually changed — the
/// canvas page then marks the doc dirty and repaints.
class RemoteMutationApplier {
  RemoteMutationApplier({
    required this.doc,
    required this.engine,
    required this.artboard,
  });

  final CanvasDocumentModel doc;
  final TiledCanvasEngine engine;
  final ArtboardManager artboard;

  /// §10.2 device rule: apply only envelopes for the open document.
  bool apply(Map<String, dynamic> msg, {required String openCanvasId}) {
    if (msg['canvas_id'] != openCanvasId) {
      return false; // different document — ignore silently
    }
    final Object? type = msg['type'];
    final Object? action = msg['action'];
    final Map<String, dynamic> payload =
        msg['payload'] is Map
            ? Map<String, dynamic>.from(msg['payload']! as Map)
            : <String, dynamic>{};

    if (type == 'ELEMENT_COMMIT') {
      if (action == 'CLEAR_CANVAS') {
        if (doc.elements.isEmpty) {
          return false; // harmless self-echo guard
        }
        wipeDocumentElements(doc: doc, engine: engine, artboard: artboard);
        return true;
      }
      if (action == 'DELETE_NODE') {
        final Object? rawId = payload['node_id'];
        if (rawId is! String || rawId.isEmpty) {
          return false;
        }
        final int before = doc.elements.length;
        doc.elements.removeWhere((CanvasNodeModel n) => n.nodeId == rawId);
        if (doc.elements.length == before) {
          return false; // unknown/duplicate id — nothing to remove
        }
        engine.removeCommitted(rawId);
        return true;
      }
      if (action is String && kRemoteAddActions.contains(action)) {
        return _addNode(payload);
      }
      return false;
    }

    if (type == 'ARTBOARD_RESIZE' && action == 'UPGRADE_SIZE') {
      final Object? preset = payload['preset'];
      if (preset is! String) {
        return false;
      }
      final UpgradeResult result = artboard.tryUpgrade(preset);
      if (!result.allowed) {
        return false; // Doc 23 clips_content / invalid_target — no change
      }
      doc.artboard = artboard.current;
      return true;
    }

    return false; // EXPORT_JOB / ASSET_UPLOAD / CANVAS_LIFECYCLE …
  }

  bool _addNode(Map<String, dynamic> payload) {
    final CanvasNodeModel node;
    try {
      node = CanvasNodeModel.fromJson(payload);
    } catch (_) {
      return false; // malformed payload — ignore, never crash the stream
    }
    if (node.nodeId.isEmpty) {
      return false;
    }
    if (doc.elements.any((CanvasNodeModel n) => n.nodeId == node.nodeId)) {
      return false; // harmless self-echo guard — already applied
    }
    doc.elements.add(node);
    engine.addNode(node);
    final Rect content = Rect.fromLTRB(
      node.bbox[0],
      node.bbox[1],
      node.bbox[2],
      node.bbox[3],
    );
    artboard.noteContent(content);
    doc.contentBounds = unionContentBounds(doc.contentBounds, content);
    return true;
  }
}
