/// Round-12 issue 05 — regular-polygon geometry for the polygon tool.
///
/// A polygon is stored as a `SHAPE` node with `shape_type: "PATH"` and its
/// vertices in `geometry.pts` (`[[x, y], ...]`). `PATH` already exists in the
/// frozen Doc 03 enum and every renderer already fills/strokes a closed polygon
/// (round 9 added it for rotated shapes and pen-loop fills), so the polygon tool
/// needs **no schema change** — only a way to produce a sensible vertex list
/// from a drag.
///
/// Why a *regular* polygon: the round-12 plan lets the user pick the side count
/// and then drag, which makes the drag a bounding box rather than a vertex
/// sequence. Inscribing an N-gon in that box means the drag extremes are the
/// shape's extremes, so what the user traces is what they get, at any N.
///
/// Everything here is pure `dart:ui` geometry (no canvas, no widgets) so it is
/// unit-testable and so the PC mirror can be checked against the same numbers.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, Rect;

/// Default side count for the polygon tool (a hexagon reads as "polygon"
/// immediately and is still easy to aim with a stylus).
const int kDefaultPolygonSides = 6;

/// A polygon has no meaning below three vertices.
const int kMinPolygonSides = 3;

/// Upper guard: more sides than this is a circle, and `pts` would bloat the
/// document for no visual gain.
const int kMaxPolygonSides = 64;

/// Clamps [sides] into [kMinPolygonSides]..[kMaxPolygonSides].
///
/// Non-finite input cannot arrive through an `int`, but a UI spinner can hand
/// over a huge value, and a 10 000-gon would emit 10 000 vertex pairs.
int clampPolygonSides(int sides) => sides.clamp(kMinPolygonSides, kMaxPolygonSides);

/// Top vertex first, so a hexagon looks like a hexagon rather than a shape
/// tipped onto one corner. The same phase the PC `vector_geometry` ellipse
/// uses (angle 0 ⇒ +x) is deliberately *not* reused here: a flat-topped polygon
/// cannot be inscribed in a box whose width comes from a horizontal drag
/// without one vertex poking outside it.
const double _startAngle = -math.pi / 2;

/// Vertices of a regular [sides]-gon inscribed in [box], starting at the top.
///
/// Returns an empty list for a degenerate or non-finite box: a zero-width drag
/// has no interior to inscribe into, and emitting a collapsed vertex list would
/// give the selector a bbox it cannot resize.
List<Offset> regularPolygonInBox(
  Rect box, {
  int sides = kDefaultPolygonSides,
  double rotation = 0.0,
}) {
  final double width = box.width;
  final double height = box.height;
  if (!width.isFinite || !height.isFinite) {
    return const <Offset>[];
  }
  if (width <= 0 || height <= 0) {
    return const <Offset>[];
  }
  final double radiusX = width / 2;
  final double radiusY = height / 2;
  final Offset centre = box.center;
  return _vertices(
    centre: centre,
    radiusX: radiusX,
    radiusY: radiusY,
    sides: sides,
    rotation: rotation,
  );
}

/// Vertices of a regular [sides]-gon centred on [centre] with [radius].
///
/// The tap-and-place form of the tool: one tap plus a radius (the tool's
/// current size) instead of a drag. A non-positive or non-finite radius yields
/// an empty list, matching [regularPolygonInBox]'s degenerate rule.
List<Offset> regularPolygonAt(
  Offset centre,
  double radius, {
  int sides = kDefaultPolygonSides,
  double rotation = 0.0,
}) {
  if (!radius.isFinite || radius <= 0) {
    return const <Offset>[];
  }
  if (!centre.dx.isFinite || !centre.dy.isFinite) {
    return const <Offset>[];
  }
  return _vertices(
    centre: centre,
    radiusX: radius,
    radiusY: radius,
    sides: sides,
    rotation: rotation,
  );
}

List<Offset> _vertices({
  required Offset centre,
  required double radiusX,
  required double radiusY,
  required int sides,
  required double rotation,
}) {
  final int count = clampPolygonSides(sides);
  // A non-finite rotation would poison every vertex; treat it as "no rotation"
  // rather than silently producing NaN points that the painter then drops.
  final double phase = rotation.isFinite ? rotation : 0.0;
  final List<Offset> out = <Offset>[];
  for (int i = 0; i < count; i++) {
    final double angle = _startAngle + phase + 2 * math.pi * i / count;
    out.add(
      Offset(
        centre.dx + radiusX * math.cos(angle),
        centre.dy + radiusY * math.sin(angle),
      ),
    );
  }
  return out;
}

/// [points] as `geometry.pts` (`[[x, y], ...]`), the wire layout `PATH` uses.
List<List<double>> polygonPts(List<Offset> points) => <List<double>>[
      for (final Offset p in points)
        if (p.dx.isFinite && p.dy.isFinite) <double>[p.dx, p.dy],
    ];

/// `geometry.pts` back to world points, dropping malformed/non-finite pairs.
///
/// Deliberately tolerant: a document written by an older build (or a hand-edited
/// one) may carry a short row or a string, and one bad point must not blank the
/// whole polygon.
List<Offset> polygonFromPts(List<List<double>>? pts) {
  if (pts == null) {
    return const <Offset>[];
  }
  final List<Offset> out = <Offset>[];
  for (final List<double> pair in pts) {
    if (pair.length < 2) {
      continue;
    }
    final double x = pair[0];
    final double y = pair[1];
    if (!x.isFinite || !y.isFinite) {
      continue;
    }
    out.add(Offset(x, y));
  }
  return out;
}

/// Polygon vertices for a drag from [start] to [end] (WORLD anchors).
///
/// The drag rectangle is normalised, so a drag in any of the four directions
/// produces the same polygon — the same rule `Rect.fromPoints` applies to every
/// other shape tool.
List<Offset> polygonFromDrag(
  Offset start,
  Offset end, {
  int sides = kDefaultPolygonSides,
  double rotation = 0.0,
}) =>
    regularPolygonInBox(
      Rect.fromPoints(start, end),
      sides: sides,
      rotation: rotation,
    );

/// Distance below which a point counts as lying ON a polygon edge, in world
/// units. Hit-testing uses it so a tap on the outline of a thin polygon still
/// selects it (the even-odd test alone reports "outside" for the boundary).
const double kPolygonEdgeTolerance = 0.75;

/// Point-in-polygon test — boundary-inclusive.
///
/// Even-odd ray casting (the same algorithm as the PC `vector_geometry`
/// implementation) so concave polygons behave; the explicit edge test on top of
/// it is what makes a tap on the outline count as a hit, which is how the
/// selector and the fill tool both want to behave.
bool pointInPolygon(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) {
    return false;
  }
  if (!point.dx.isFinite || !point.dy.isFinite) {
    return false;
  }
  if (_onAnyEdge(point, polygon, kPolygonEdgeTolerance)) {
    return true;
  }
  bool inside = false;
  int j = polygon.length - 1;
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[j];
    if ((a.dy > point.dy) != (b.dy > point.dy)) {
      final double dy = b.dy - a.dy;
      if (dy != 0) {
        final double crossX = a.dx + (point.dy - a.dy) * (b.dx - a.dx) / dy;
        if (point.dx < crossX) {
          inside = !inside;
        }
      }
    }
    j = i;
  }
  return inside;
}

bool _onAnyEdge(Offset p, List<Offset> polygon, double tolerance) {
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[(i + 1) % polygon.length];
    if (_distanceToSegment(p, a, b) <= tolerance) {
      return true;
    }
  }
  return false;
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final double dx = b.dx - a.dx;
  final double dy = b.dy - a.dy;
  final double lengthSquared = dx * dx + dy * dy;
  if (lengthSquared <= 0) {
    return (p - a).distance;
  }
  double t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  return (p - Offset(a.dx + dx * t, a.dy + dy * t)).distance;
}

/// Axis-aligned bounds of [polygon]; `Rect.zero` when it has no points.
///
/// Used to compute the node bbox (which the Doc 03 contract keeps
/// axis-aligned) without depending on a canvas.
Rect polygonBounds(List<Offset> polygon) {
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;
  for (final Offset p in polygon) {
    if (p.dx < minX) {
      minX = p.dx;
    }
    if (p.dy < minY) {
      minY = p.dy;
    }
    if (p.dx > maxX) {
      maxX = p.dx;
    }
    if (p.dy > maxY) {
      maxY = p.dy;
    }
  }
  if (!minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite) {
    return Rect.zero;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Area centroid (the centre of mass of the filled region).
///
/// The vertex average is NOT used: for a hand-built polygon with unevenly
/// spaced vertices it drifts off the visual centre, and the text box / label
/// anchor placed there would look wrong. A degenerate (zero-area) polygon falls
/// back to the vertex average, which is the best answer available.
Offset polygonCentroid(List<Offset> polygon) {
  if (polygon.isEmpty) {
    return Offset.zero;
  }
  double twiceArea = 0;
  double cx = 0;
  double cy = 0;
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[(i + 1) % polygon.length];
    final double cross = a.dx * b.dy - b.dx * a.dy;
    twiceArea += cross;
    cx += (a.dx + b.dx) * cross;
    cy += (a.dy + b.dy) * cross;
  }
  if (twiceArea.abs() <= 1e-9) {
    return _vertexAverage(polygon);
  }
  return Offset(cx / (3 * twiceArea), cy / (3 * twiceArea));
}

Offset _vertexAverage(List<Offset> polygon) {
  double sx = 0;
  double sy = 0;
  for (final Offset p in polygon) {
    sx += p.dx;
    sy += p.dy;
  }
  return Offset(sx / polygon.length, sy / polygon.length);
}

/// Signed area (shoelace); positive when the winding is clockwise in Flutter's
/// y-down screen space, negative when counter-clockwise.
double polygonSignedArea(List<Offset> polygon) {
  if (polygon.length < 3) {
    return 0;
  }
  double total = 0;
  for (int i = 0; i < polygon.length; i++) {
    final Offset a = polygon[i];
    final Offset b = polygon[(i + 1) % polygon.length];
    total += a.dx * b.dy - b.dx * a.dy;
  }
  return total / 2;
}

/// `true` when [polygon] encloses a non-zero area — the guard every commit path
/// needs before it emits a `PATH` node that would render as nothing.
bool polygonIsUsable(List<Offset> polygon) =>
    polygon.length >= 3 && polygonSignedArea(polygon).abs() > 1e-6;
