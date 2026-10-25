/// Round-11 issue 02 — undo/redo must reach the PC mirror.
///
/// An undo step rewrites `doc.elements` wholesale, but the frozen wire schema
/// (Doc 02) has no "replace the document" action: a device tells the PC about
/// a canvas one node at a time (`ADD_STROKE` / `ADD_SHAPE` / `ADD_GRAPH` /
/// `ADD_IMAGE` / `DELETE_NODE` / `CLEAR_CANVAS`). So a history step is
/// replayed as a MINIMAL DIFF between the document before the step and the
/// document after it:
///
/// * node ids that disappeared → `DELETE_NODE`;
/// * node ids that are new or whose JSON changed → `DELETE_NODE` then the
///   per-kind `ADD_*` (delete-then-add is the only update primitive available,
///   and it is exactly what the transform paths already use);
/// * nothing else is sent, so an undo that only touched one object does not
///   re-upload the whole canvas.
///
/// `layer` is not part of the wire payload semantics for a re-added node
/// (the PC appends in arrival order), so ordering is preserved by emitting the
/// added nodes sorted by layer — which is how the array is stored anyway.
library;

import 'dart:convert';

import 'package:mobile_app/core/models/canvas_models.dart';

/// One RPC a history step has to replay on the mirror.
class HistoryRpc {
  const HistoryRpc(this.action, this.payload);

  final String action;
  final Map<String, dynamic> payload;

  @override
  String toString() => '$action($payload)';
}

/// The frozen Doc 02 action that re-creates a node of [kind].
String addActionForKind(String kind) => switch (kind) {
      'STROKE' || 'HIGHLIGHT' || 'LINE' => 'ADD_STROKE',
      'SHAPE' => 'ADD_SHAPE',
      'GRAPH_AXES' => 'ADD_GRAPH',
      'IMAGE' => 'ADD_IMAGE',
      _ => 'ADD_STROKE',
    };

/// Stable key for "did this node really change?".
String nodeSignature(CanvasNodeModel node) => jsonEncode(node.toJson());

/// Diff two node lists into the RPCs that turn [before] into [after].
///
/// Returns an empty list when the two lists are equal, so a no-op undo never
/// touches the socket. A `null` [before] means "we have no baseline" and the
/// whole of [after] is re-sent.
List<HistoryRpc> diffNodes({
  required List<CanvasNodeModel>? before,
  required List<CanvasNodeModel> after,
}) {
  final Map<String, String> previous = <String, String>{
    if (before != null)
      for (final CanvasNodeModel n in before) n.nodeId: nodeSignature(n),
  };
  final Map<String, String> next = <String, String>{
    for (final CanvasNodeModel n in after) n.nodeId: nodeSignature(n),
  };
  final List<HistoryRpc> rpcs = <HistoryRpc>[];

  for (final String id in previous.keys) {
    if (!next.containsKey(id)) {
      rpcs.add(HistoryRpc('DELETE_NODE', <String, dynamic>{'node_id': id}));
    }
  }

  final List<CanvasNodeModel> ordered = after.toList()
    ..sort((CanvasNodeModel a, CanvasNodeModel b) => a.layer.compareTo(b.layer));
  for (final CanvasNodeModel node in ordered) {
    final String? was = previous[node.nodeId];
    if (was == next[node.nodeId]) {
      continue; // unchanged — nothing to replay
    }
    if (was != null) {
      rpcs.add(
        HistoryRpc('DELETE_NODE', <String, dynamic>{'node_id': node.nodeId}),
      );
    }
    rpcs.add(HistoryRpc(addActionForKind(node.kind), node.toJson()));
  }
  return rpcs;
}

/// Diff two lock-group maps. `groups` travel inside the document, not in an
/// element commit, so a change can only be published with a full `CANVAS_PUT`.
bool groupsDiffer(Map<String, List<String>> before, Map<String, List<String>> after) =>
    _groupsSignature(before) != _groupsSignature(after);

String _groupsSignature(Map<String, List<String>> groups) {
  final List<String> keys = groups.keys.toList()..sort();
  return keys
      .map((String k) => '$k:${(groups[k] ?? const <String>[]).join(',')}')
      .join('|');
}
