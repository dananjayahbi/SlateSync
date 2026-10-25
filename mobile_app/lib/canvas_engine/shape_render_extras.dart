/// Round-9 issues 04/05/06 — fill, rotated paths and tables for the painter.
///
/// [tiled_canvas_painter] paints one node per `kind`. Round 9 added three
/// things it has to understand, and rather than growing that already-large
/// file each of them lives here as a pure "paint this node" function that the
/// painter dispatches to:
///
/// * **fill** (issue 04) — a `NodeStyleModel.fill` colour paints the interior
///   UNDER the outline. The old `stroke_width == 0` spelling still means
///   "solid in `color`", so both routes are honoured.
/// * **PATH** (issue 05) — a rotated RECT/CIRCLE/TRIANGLE is re-emitted as a
///   closed polygon (see `rotationPolygon`) because the bbox contract is
///   axis-aligned. PATH also renders any other arbitrary closed polygon.
/// * **TABLE** (issue 06) — a grid of `graph_config` rows/columns with filled
///   header bands.
///
/// Everything here takes a prepared `Paint` (or builds a fill paint) and works
/// in WORLD units, because the painter already applied the camera matrix.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/region_fill.dart';
import 'package:mobile_app/canvas_engine/table_geometry.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// A `Paint` for a node's interior fill, or `null` when it has none.
///
/// Honours the two spellings: an explicit `style.fill`, and the legacy
/// `stroke_width == 0` (which means "no outline, therefore solid in `color`" —
/// the same rule the PC mirror applies in `shape_fill.py`, so the two sides can
/// never disagree about whether a shape is filled).
Paint? fillPaintFor(CanvasNodeModel n) {
  final String? fill = n.style.fill;
  final bool legacy = n.style.strokeWidth <= 0;
  if (!legacy && fill == null) {
    return null;
  }
  final Color colour = legacy
      ? _colorFromHex(n.style.color, n.style.opacity)
      : _colorFromHex(fill!, n.style.opacity);
  return Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.fill
    ..blendMode = n.style.blendMode == 'MULTIPLY'
        ? BlendMode.multiply
        : BlendMode.srcOver
    ..color = colour;
}

/// Paints the interior of [n] when it has one; a no-op otherwise.
///
/// Called BEFORE the outline so the stroke sits on top of its own fill, which
/// is what makes a filled shape keep a crisp edge at any zoom.
void paintNodeFill(Canvas canvas, CanvasNodeModel n) {
  final Paint? fill = fillPaintFor(n);
  if (fill == null) {
    return;
  }
  final String? shapeType = n.geometry.shapeType;
  if (shapeType == 'CARTESIAN_2D' || shapeType == 'NUMBER_LINE') {
    return; // graph axes are line work; no interior to paint
  }
  if (n.kind == 'STROKE' || n.kind == 'HIGHLIGHT') {
    // Only a deliberately closed pen loop encloses a region.
    final List<Offset>? polygon = closedPolygonFor(n);
    if (polygon != null && polygon.length >= 3) {
      canvas.drawPath(_closedPath(polygon), fill);
    }
    return;
  }
  final Rect box = nodeRect(n);
  switch (shapeType) {
    case 'CIRCLE':
      canvas.drawOval(box, fill);
    case 'TRIANGLE':
      canvas.drawPath(_trianglePath(n, box), fill);
    case 'PATH':
      final List<Offset> pts = polygonPointsOf(n);
      if (pts.length >= 3) {
        canvas.drawPath(_closedPath(pts), fill);
      }
    case 'TABLE':
      // The grid itself is the outline; the bands are painted by [paintTable].
      break;
    case 'TEXT':
      // The glyphs are the content; a filled box would hide them. Fill still
      // works as a background (it is painted before the text), so this only
      // skips the generic rect.
      break;
    default:
      canvas.drawRect(box, fill);
  }
}

/// Shell for `shape_type == 'PATH'` — a closed polygon.
void paintPath(Canvas canvas, CanvasNodeModel n, Paint stroke) {
  final List<Offset> pts = polygonPointsOf(n);
  if (pts.length < 2) {
    return;
  }
  canvas.drawPath(_closedPath(pts), stroke);
}

/// Shell for `shape_type == 'TABLE'`.
///
/// The grid lines use the node's stroke paint; header bands are filled with the
/// node's fill colour when it has one, else a light tint of the stroke so the
/// header is always visible (a table without a visible header band is unusable,
/// and the user explicitly asked for the option to mean something).
void paintTable(Canvas canvas, CanvasNodeModel n, Paint stroke) {
  final TableGrid grid = tableGridOf(nodeRect(n), n.geometry.graphConfig);
  if (!grid.box.width.isFinite ||
      grid.box.width <= 0 ||
      grid.box.height <= 0) {
    return;
  }
  final Paint? fill = fillPaintFor(n);
  final Color band = fill?.color ??
      _colorFromHex(n.style.color, n.style.opacity).withValues(alpha: 0.12);
  final Paint bandPaint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.fill
    ..color = band;
  for (final Rect r in grid.headerRects) {
    canvas.drawRect(r, bandPaint);
  }
  // Faint interior lines, then the same grid again with the node stroke so the
  // outer border reads heavier than the internal divisions.
  final Paint gridPaint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeWidth = stroke.strokeWidth
    ..color = stroke.color;
  for (final (Offset a, Offset b) in grid.lines) {
    canvas.drawLine(a, b, gridPaint);
  }
  canvas.drawRect(grid.box, gridPaint);
}

/// Closed polygon of [n] in world units (empty when it encloses nothing).
List<Offset> polygonPointsOf(CanvasNodeModel n) {
  final List<Offset> pts = <Offset>[
    for (final List<double> p in n.geometry.pts)
      if (p.length >= 2) Offset(p[0], p[1]),
  ];
  return pts;
}

/// The node's bbox as a normalised `Rect` (empty when the bbox is malformed).
Rect nodeRect(CanvasNodeModel n) {
  final List<double> b = n.bbox;
  if (b.length < 4) {
    return Rect.zero;
  }
  return Rect.fromLTRB(
    b[0] < b[2] ? b[0] : b[2],
    b[1] < b[3] ? b[1] : b[3],
    b[0] < b[2] ? b[2] : b[0],
    b[1] < b[3] ? b[3] : b[1],
  );
}

Path _closedPath(List<Offset> pts) {
  final Path path = Path()..moveTo(pts.first.dx, pts.first.dy);
  for (int i = 1; i < pts.length; i++) {
    path.lineTo(pts[i].dx, pts[i].dy);
  }
  path.close();
  return path;
}

Path _trianglePath(CanvasNodeModel n, Rect box) {
  final List<Offset> tri = polygonPointsOf(n);
  if (tri.length >= 3) {
    return _closedPath(tri.sublist(0, 3));
  }
  return _closedPath(<Offset>[
    Offset(box.center.dx, box.top),
    box.bottomRight,
    box.bottomLeft,
  ]);
}

Color _colorFromHex(String hex, double opacity) {
  int argb;
  if (hex.length == 7 && hex.startsWith('#')) {
    argb = int.parse(hex.substring(1), radix: 16) | 0xFF000000;
  } else {
    argb = 0xFF1E1E1E;
  }
  final double o = opacity.clamp(0.0, 1.0).toDouble();
  final int alpha = (((argb >> 24) & 0xFF) * o).round().clamp(0, 255).toInt();
  return Color((alpha << 24) | (argb & 0x00FFFFFF));
}