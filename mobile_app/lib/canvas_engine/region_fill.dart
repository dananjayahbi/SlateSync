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
bool polylineCloses(List<List<double>> pts) {
  if (pts.length < 3) {
    return false;
  }
  final List<double> first = pts.first;
  final List<double> last = pts.last;
  if (first.length < 2 || last.length < 2) {
    return false;
  }
  double minX = pts.first[0];
  double maxX = minX;
  double minY = pts.first[1];
  double maxY = minY;
  for (final List<double> p in pts) {
    if (p.length < 2) {
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
  final double gap = math.sqrt(
    (last[0] - first[0]) * (last[0] - first[0]) +
        (last[1] - first[1]) * (last[1] - first[1]),
  );
  final double limit = math.max(kClosureToleranceMin, span * kClosureToleranceRatio);
  return gap <= limit;
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
  if (!polylineCloses(node.geometry.pts)) {
    return null;
  }
  return _points(node.geometry.pts);
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
