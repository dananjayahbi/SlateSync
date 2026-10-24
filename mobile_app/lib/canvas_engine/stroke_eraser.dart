/// Round-8 issue 03 — geometric stroke splitting for the brush eraser.
///
/// The eraser used to have two modes, and BOTH deleted whole elements: a tap
/// removed the topmost node whose bbox contained the point, and a drag
/// removed every node it crossed. That is a "clear this object" tool, not an
/// eraser — the user expects a brush that takes a bite out of a stroke.
///
/// A brush eraser cannot delete a node, because the node IS the stroke. The
/// only correct model is to replace the stroke with the fragments that remain
/// outside the eraser's circular sweep. This module is that pure geometry: no
/// widgets, no engine, no I/O, so it is cheap to test exhaustively.
///
/// Two strategies, chosen per node kind:
///
/// * **Stroke fragments** ([splitPolyline]) — STROKE / HIGHLIGHT / LINE. Walk
///   the polyline, drop every vertex that falls inside an erase disc, and cut
///   the polyline into the contiguous runs that survive. Each run becomes its
///   own node, so the erased gap is real geometry, not a clip mask.
/// * **Bbox subtraction** ([subtractDiscsFromBox]) — SHAPE / IMAGE /
///   GRAPH_AXES. These have no meaningful polyline to split, so a disc that
///   lands inside the shape clears it entirely; a disc that only clips an edge
///   leaves the shape untouched. Partial shape erasure is out of scope.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

/// One erased disc in world units.
class EraseDisc {
  const EraseDisc(this.center, this.radius);

  final Offset center;
  final double radius;

  /// Squared distance test — avoids a sqrt per vertex.
  bool contains(Offset p) {
    final double dx = p.dx - center.dx;
    final double dy = p.dy - center.dy;
    return dx * dx + dy * dy <= radius * radius;
  }
}

/// Splits `points` into the contiguous runs that survive [discs].
///
/// A vertex inside any disc is removed. When a vertex is removed the run
/// breaks, so the two neighbours on either side of the gap become the ends of
/// separate fragments — exactly what a physical eraser pass leaves behind.
///
/// Returns fragments in original order. Each fragment has at least
/// [minPoints] vertices; shorter spans are dropped (a single leftover point
/// is a dot, which a real eraser would have removed anyway).
List<List<Offset>> splitPolyline(
  List<Offset> points,
  List<EraseDisc> discs, {
  int minPoints = 2,
}) {
  if (points.isEmpty) {
    return <List<Offset>>[];
  }
  if (discs.isEmpty) {
    return points.length >= minPoints
        ? <List<Offset>>[List<Offset>.of(points)]
        : <List<Offset>>[];
  }
  final List<List<Offset>> fragments = <List<Offset>>[];
  List<Offset> current = <Offset>[];
  for (final Offset point in points) {
    if (discs.any((EraseDisc d) => d.contains(point))) {
      if (current.length >= minPoints) {
        fragments.add(current);
      }
      current = <Offset>[];
      continue;
    }
    current.add(point);
  }
  if (current.length >= minPoints) {
    fragments.add(current);
  }
  return fragments;
}

/// `true` when at least one disc removes something from [points].
///
/// Callers use this to skip work (and skip emitting RPCs) for an eraser pass
/// that touched nothing.
bool erasesAnyPoint(List<Offset> points, List<EraseDisc> discs) =>
    discs.any((EraseDisc d) => points.any(d.contains));

/// Result of erasing a closed shape/box.
enum BoxErase {
  /// No disc engaged the element — leave the node alone.
  untouched,

  /// A disc cleared the element — it must be removed.
  cleared,
}

/// Decides whether an eraser disc clears a bbox-based element.
///
/// A disc clears the element when its centre is inside the box (the user
/// aimed at the shape) or when it is large enough to swallow the box whole.
/// A disc that merely clips an edge does nothing, so dragging an eraser past
/// a rectangle never destroys it by accident.
BoxErase subtractDiscsFromBox(
  List<double> bbox,
  List<EraseDisc> discs,
) {
  if (bbox.length < 4) {
    return BoxErase.untouched;
  }
  final double left = math.min(bbox[0], bbox[2]);
  final double top = math.min(bbox[1], bbox[3]);
  final double right = math.max(bbox[0], bbox[2]);
  final double bottom = math.max(bbox[1], bbox[3]);
  for (final EraseDisc disc in discs) {
    final Offset c = disc.center;
    final bool inside =
        c.dx >= left && c.dx <= right && c.dy >= top && c.dy <= bottom;
    if (inside) {
      return BoxErase.cleared;
    }
    final bool covers =
        c.dx - disc.radius <= left &&
        c.dx + disc.radius >= right &&
        c.dy - disc.radius <= top &&
        c.dy + disc.radius >= bottom;
    if (covers) {
      return BoxErase.cleared;
    }
  }
  return BoxErase.untouched;
}

/// Axis-aligned bbox of [points] as `[min_x, min_y, max_x, max_y]`, widened
/// by [padding] on every side. Empty input returns the degenerate origin box.
List<double> polylineBounds(List<Offset> points, {double padding = 0.0}) {
  if (points.isEmpty) {
    return <double>[-padding, -padding, padding, padding];
  }
  double minX = points.first.dx;
  double maxX = minX;
  double minY = points.first.dy;
  double maxY = minY;
  for (final Offset p in points) {
    if (p.dx < minX) minX = p.dx;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dy > maxY) maxY = p.dy;
  }
  return <double>[
    minX - padding,
    minY - padding,
    maxX + padding,
    maxY + padding,
  ];
}
