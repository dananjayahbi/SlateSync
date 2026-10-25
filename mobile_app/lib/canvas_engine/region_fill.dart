/// Round-9 issue 04 — the paint-bucket fill tool's geometry.
///
/// The rule the user gave is narrow and absolute: *"the object needs to be
/// closed"*. Nothing here does a raster flood fill — a raster bucket leaks
/// through every antialiased gap and cannot decide "this node's interior" from
/// "the space between two nodes". Instead the tap is resolved against the
/// NODES under it:
///
/// 1. **[closedPolygonFor]** turns a node into the closed loop it encloses, or
///    `null` when it encloses nothing. RECT / CIRCLE / TRIANGLE / PATH are
///    their outline; a free-hand STROKE counts only when its own first and last
///    samples meet ([polylineCloses]); ARROW / LINE / IMAGE / GRAPH_AXES never
///    enclose a region.
/// 2. **[findFillTarget]** walks the nodes under the tap topmost-last and
///    returns the smallest-area open polygon containing the point, so tapping
///    inside a small shape nested in a big one fills the small one.
///
/// The fill itself is a style change (`NodeStyleModel.fill`), not new
/// geometry: the node keeps its outline and gains an interior colour, which is
/// why the PC mirror only has to learn one extra style field instead of a new
/// node type.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, Rect;

import 'package:mobile_app/core/models/canvas_models.dart';

/// Shape types whose interior is their bbox outline.
const Set<String> kClosedShapeTypes = <String>{
  'RECT',
  'CIRCLE',
  'TRIANGLE',
  'PATH',
};

/// Kinds that never enclose a fillable region.
const Set<String> kNeverFilledKinds = <String>{
  'IMAGE',
  'GRAPH_AXES',
  'LINE',
};

/// Screen-independent closure tolerance: the pen's endpoints must land within
/// this fraction of the path diagonal (floored, so a small loop still counts).
const double kClosureToleranceRatio = 0.12;
const double kClosureToleranceMin = 6.0;

/// True when a free-hand point list returns to its start.
///
/// The pen samples at pointer-move rate, so "closed" can never be exact. A
/// relative tolerance means the same gesture works at every zoom: draw a
/// circle in one motion and the last sample lands near the first.
///
/// Round-10 issue 03 — the user's rule is "if there is no gap to leak the
/// colour it counts as filled", and the ink has width: two endpoints one
/// [strokeWidth] apart are sealed by the stroke itself. That width is therefore
/// part of the tolerance, which is what makes a quick hand-drawn loop fillable.
///
/// A loop drawn past its own start (the natural way to close a circle) never
/// brings the endpoints together at all — the tail crosses the head. That case
/// is closed when the path crosses itself ([polylineSelfIntersects]), because
/// the crossing point is a real seal: no gap exists for colour to escape.
bool polylineCloses(List<List<double>> pts, {double strokeWidth = 0}) {
  if (pts.length < 3) {
    return false;
  }
  final List<double> first = pts.first;
  final List<double> last = pts.last;
  if (first.length < 2 || last.length < 2) {
    return false;
  }
  final double limit = closureLimit(pts, strokeWidth: strokeWidth);
  final double gap = math.sqrt(
    (last[0] - first[0]) * (last[0] - first[0]) +
        (last[1] - first[1]) * (last[1] - first[1]),
  );
  if (gap <= limit) {
    return true;
  }
  return polylineSelfIntersects(pts);
}

/// True when the path crosses itself — the "overshoot the start" loop.
///
/// Only the segment pairs the gesture actually swept are tested, and a crossing
/// counts only when both segments are long enough to be intentional, so a
/// jittery pen sample cannot fake a closed region.
bool polylineSelfIntersects(List<List<double>> pts) {
  if (pts.length < 5) {
    return false;
  }
  final List<Offset> path = _points(pts);
  final int count = path.length;
  for (int i = 0; i + 1 < count; i++) {
    for (int j = i + 2; j + 1 < count; j++) {
      if (i == 0 && j + 1 == count - 1) {
        continue; // the closure segment itself — adjacency, not a crossing
      }
      if (_segmentsCross(path[i], path[i + 1], path[j], path[j + 1])) {
        return true;
      }
    }
  }
  return false;
}

/// Strict segment intersection (shared endpoints do not count).
bool _segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  final double d1 = _cross(c, d, a);
  final double d2 = _cross(c, d, b);
  final double d3 = _cross(a, b, c);
  final double d4 = _cross(a, b, d);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

/// Distance within which a polyline's two ends count as sealed.
double closureLimit(List<List<double>> pts, {double strokeWidth = 0}) {
  double minX = 0;
  double maxX = 0;
  double minY = 0;
  double maxY = 0;
  bool firstPoint = true;
  for (final List<double> p in pts) {
    if (p.length < 2) {
      continue;
    }
    if (firstPoint) {
      minX = maxX = p[0];
      minY = maxY = p[1];
      firstPoint = false;
      continue;
    }
    if (p[0] < minX) minX = p[0];
    if (p[0] > maxX) maxX = p[0];
    if (p[1] < minY) minY = p[1];
    if (p[1] > maxY) maxY = p[1];
  }
  final double span = math.sqrt(
    (maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY),
  );
  // The stroke is strokeWidth wide, so its own ink bridges half that on each
  // side — a full width is generous and still far below a real leak.
  return math.max(
    math.max(kClosureToleranceMin, span * kClosureToleranceRatio),
    strokeWidth.abs(),
  );
}

/// The closed polygon [node] encloses, or `null` when it encloses nothing.
///
/// Answers are in WORLD units and ordered so consecutive points are adjacent —
/// needed both for the point-in-polygon test and for the fill painting.
List<Offset>? closedPolygonFor(CanvasNodeModel node) {
  if (kNeverFilledKinds.contains(node.kind)) {
    return null;
  }
  final String? shapeType = node.geometry.shapeType;
  if (node.kind == 'SHAPE' || node.kind == 'PATH') {
    if (shapeType == 'PATH') {
      final List<Offset> path = _points(node.geometry.pts);
      return path.length >= 3 ? path : null;
    }
    if (shapeType == 'CIRCLE') {
      return _ellipse(_rectOf(node));
    }
    if (shapeType == 'TRIANGLE') {
      final List<Offset> tri = _points(node.geometry.pts);
      if (tri.length >= 3) {
        return tri.sublist(0, 3);
      }
      return _triangleFromRect(_rectOf(node));
    }
    if (shapeType == 'RECT') {
      final List<Offset> pts = _points(node.geometry.pts);
      if (pts.length >= 2) {
        return _rectPolygon(
          Rect.fromPoints(pts[0], pts[1]),
        );
      }
      return _rectPolygon(_rectOf(node));
    }
    if (shapeType == 'CARTESIAN_2D' || shapeType == 'NUMBER_LINE') {
      return null; // graph axes are line work, not regions
    }
    final List<Offset> pts = _points(node.geometry.pts);
    return pts.length >= 3 ? pts : null;
  }
  // STROKE / HIGHLIGHT: only a deliberately closed loop is a region.
  //
  // Round-10 issue 03: "closed" includes a loop whose ends are sealed by the
  // ink width and one that overshoots its own start — see [polylineCloses].
  if (!polylineCloses(node.geometry.pts, strokeWidth: node.style.strokeWidth)) {
    return null;
  }
  final List<Offset> loop = _points(node.geometry.pts);
  return loop.length >= 3 ? loop : null;
}

/// Even-odd ray cast; correct for the concave loops a pen produces.
bool pointInPolygon(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) {
    return false;
  }
  bool inside = false;
  int j = polygon.length - 1;
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy)) {
      final double denom = b.dy - a.dy;
      if (denom != 0) {
        final double cross =
            a.dx + (point.dy - a.dy) * (b.dx - a.dx) / denom;
        if (point.dx < cross) {
          inside = !inside;
        }
      }
    }
    j = i;
  }
  return inside;
}

/// Shoelace area (always positive) — the tie-breaker that makes a nested shape
/// win over the larger shape containing it.
double polygonArea(List<Offset> polygon) {
  if (polygon.length < 3) {
    return 0;
  }
  double total = 0;
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[(i + 1) % polygon.length];
    total += a.dx * b.dy - b.dx * a.dy;
  }
  return total.abs() / 2;
}

/// Result of resolving a bucket tap.
class FillTarget {
  const FillTarget(this.node, this.polygon);

  final CanvasNodeModel node;
  final List<Offset> polygon;
}

/// The node whose enclosed region contains [world], or `null`.
///
/// [candidates] should be the nodes near the tap (`queryVisible`). The
/// SMALLEST enclosing polygon wins so nested shapes behave; ties go to the
/// later candidate, which is the higher layer (the query returns ascending
/// layer order).
FillTarget? findFillTarget(Offset world, Iterable<CanvasNodeModel> candidates) {
  FillTarget? best;
  double bestArea = double.infinity;
  for (final CanvasNodeModel node in candidates) {
    final List<Offset>? polygon = closedPolygonFor(node);
    if (polygon == null || !pointInPolygon(world, polygon)) {
      continue;
    }
    final double area = polygonArea(polygon);
    if (area <= 0) {
      continue;
    }
    if (area <= bestArea) {
      bestArea = area;
      best = FillTarget(node, polygon);
    }
  }
  return best;
}

/// True when [node] already carries a fill.
bool isFilled(CanvasNodeModel node) =>
    node.style.fill != null && node.style.strokeWidth > 0;

/// True when [node] can be filled at all (drives the tool's affordance).
bool canFill(CanvasNodeModel node) => closedPolygonFor(node) != null;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

List<Offset> _points(List<List<double>> pts) => <Offset>[
      for (final List<double> p in pts)
        if (p.length >= 2) Offset(p[0], p[1]),
    ];

Rect _rectOf(CanvasNodeModel n) {
  final List<double> b = n.bbox;
  if (b.length < 4) {
    return Rect.zero;
  }
  return Rect.fromLTRB(
    math.min(b[0], b[2]),
    math.min(b[1], b[3]),
    math.max(b[0], b[2]),
    math.max(b[1], b[3]),
  );
}

List<Offset> _rectPolygon(Rect r) => <Offset>[
      r.topLeft,
      r.topRight,
      r.bottomRight,
      r.bottomLeft,
    ];

List<Offset> _ellipse(Rect r) {
  const int segments = 48;
  final double cx = r.center.dx;
  final double cy = r.center.dy;
  final double rx = r.width / 2;
  final double ry = r.height / 2;
  if (rx <= 0 || ry <= 0) {
    return const <Offset>[];
  }
  return <Offset>[
    for (int i = 0; i < segments; i++)
      Offset(
        cx + rx * math.cos(2 * math.pi * i / segments),
        cy + ry * math.sin(2 * math.pi * i / segments),
      ),
  ];
}

List<Offset> _triangleFromRect(Rect r) => <Offset>[
      Offset(r.center.dx, r.top),
      r.bottomRight,
      r.bottomLeft,
    ];
