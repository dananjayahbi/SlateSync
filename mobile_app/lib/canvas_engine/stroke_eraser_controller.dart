/// Round-8 issue 03 — the brush eraser's node-splitting brain.
///
/// The canvas page owns gestures and RPC; this class owns the DECISION: given
/// a node and the discs an eraser drag swept, what replaces that node? Keeping
/// it separate means the erase model is unit-testable without a widget tree,
/// an engine, or a socket.
///
/// Erase outcomes per node kind:
///
/// | kind                    | brush mode                          | element mode |
/// |-------------------------|-------------------------------------|--------------|
/// | STROKE/HIGHLIGHT/LINE   | split into surviving fragments      | delete       |
/// | SHAPE/IMAGE/GRAPH_AXES  | delete only if a disc lands on it   | delete       |
library;

import 'dart:ui' show Offset;

import 'package:mobile_app/canvas_engine/stroke_eraser.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Kinds whose geometry is a polyline that a brush pass can split.
const Set<String> kSplittableKinds = <String>{'STROKE', 'HIGHLIGHT', 'LINE'};

/// What to do with one node the eraser touched.
class EraseOutcome {
  const EraseOutcome({
    required this.removed,
    this.fragments = const <List<List<double>>>[],
  });

  /// The original node must be deleted.
  final bool removed;

  /// Replacement point lists, each of which becomes its own node carrying the
  /// original style. Empty when [removed] is false or the node was cleared.
  final List<List<List<double>>> fragments;

  static const EraseOutcome untouched = EraseOutcome(removed: false);
  static const EraseOutcome deleted = EraseOutcome(removed: true);

  bool get changesAnything => removed || fragments.isNotEmpty;
}

/// Resolves erase outcomes for the nodes an eraser drag touched.
class StrokeEraser {
  const StrokeEraser({this.minFragmentPoints = 2});

  /// Fragments shorter than this are dropped — a single leftover point is a
  /// dot a physical eraser would have taken with it.
  final int minFragmentPoints;

  /// Decides what an eraser pass does to [node].
  ///
  /// Returns [EraseOutcome.untouched] when nothing actually changes, so the
  /// caller can skip RPCs entirely for a drag that never engaged anything.
  EraseOutcome apply(CanvasNodeModel node, List<EraseDisc> discs, {required bool elementMode}) {
    if (discs.isEmpty) {
      return EraseOutcome.untouched;
    }
    if (elementMode) {
      // Legacy behaviour: one hit deletes the whole node.
      final bool hit = kSplittableKinds.contains(node.kind)
          ? erasesAnyPoint(_points(node), discs)
          : subtractDiscsFromBox(node.bbox, discs) == BoxErase.cleared;
      return hit ? EraseOutcome.deleted : EraseOutcome.untouched;
    }
    if (!kSplittableKinds.contains(node.kind)) {
      // Shapes/images/graphs have no polyline to split: clear the whole node
      // only when the disc genuinely lands on it.
      return subtractDiscsFromBox(node.bbox, discs) == BoxErase.cleared
          ? EraseOutcome.deleted
          : EraseOutcome.untouched;
    }
    final List<List<Offset>> survivors = splitPolyline(
      _points(node),
      discs,
      minPoints: minFragmentPoints,
    );
    if (survivors.isEmpty) {
      return erasesAnyPoint(_points(node), discs)
          ? EraseOutcome.deleted
          : EraseOutcome.untouched;
    }
    if (survivors.length == 1 && survivors.first.length == _points(node).length) {
      return EraseOutcome.untouched; // the disc missed every vertex
    }
    return EraseOutcome(
      removed: true,
      fragments: survivors
          .map(
            (List<Offset> run) => run
                .map((Offset p) => <double>[p.dx, p.dy])
                .toList(growable: false),
          )
          .toList(growable: false),
    );
  }

  static List<Offset> _points(CanvasNodeModel node) {
    final List<List<double>> pts = node.geometry.pts;
    if (pts.isEmpty) {
      return const <Offset>[];
    }
    final List<Offset> out = <Offset>[];
    for (final List<double> p in pts) {
      if (p.length >= 2) {
        out.add(Offset(p[0], p[1]));
      }
    }
    return out;
  }
}
