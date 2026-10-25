/// Round-6 (Doc 02 §10.3) — shape/line geometry conventions for the canvas
/// page's commit path and live preview.
///
/// `geometry.pts` layouts mirror the normative PC implementations (read
/// read-only for this issue):
///
/// | tool       | kind     | shape_type    | pts                              |
/// |------------|----------|---------------|----------------------------------|
/// | line       | `LINE`   | `null`        | `[[sx,sy],[ex,ey]]`              |
/// | rect       | `SHAPE`  | `RECT`        | `[[l,t],[r,b]]`                  |
/// | circle     | `SHAPE`  | `CIRCLE`      | `[]` (bbox convention — below)   |
/// | triangle   | `SHAPE`  | `TRIANGLE`    | `[lb, rb, center-top]`           |
/// | arrow      | `SHAPE`  | `ARROW`       | `[[sx,sy],[ex,ey]]` (shaft)      |
///
/// * `pc_agent/viewport/primitive_renderer.py` — `rect_corners` reads
///   `pts[0]/pts[1]` as the two bbox corners, `triangle_points` takes the
///   first three `pts`, `_arrow_frame` takes `pts[0]`/`pts[-1]` as the
///   shaft ends.
/// * `pc_agent/export/tiled_raster_exporter.py` / `vector_pdf_exporter.py`
///   `_draw_shape` — TRIANGLE/ARROW as above; RECT falls back to the bbox;
///   **CIRCLE always renders from the bbox** (the exporters ignore circle
///   pts entirely, and their own fixtures carry `pts=[]` for CIRCLE).
/// * LINE is a straight segment `pts[0] → pts[-1]` on every renderer (PC
///   `_draw_stroke` `kind == "LINE"`, mobile `_drawLine`), and `shape_type`
///   has no `LINE` value in the Doc 03 schema — so the line tool commits
///   `kind: LINE` with `shape_type: null` under `ADD_SHAPE`.
///
/// CIRCLE deviation from the orchestrator's shorthand "RECT/CIRCLE =
/// `[[l,t],[r,b]]`": PC `_circle_frame` interprets two `pts` as
/// **center/rim** (`cx,cy = pts[0]`, `radius = |pts[1]-pts[0]|`) — corner
/// pts would render a huge wrong circle on the GL viewport (center at the
/// bbox corner, radius = bbox diagonal). Empty `pts` selects the bbox
/// fallback on the viewport while matching the exporters and the mobile
/// engine's bbox oval — the one layout all three renderers agree on
/// (Doc 08 §4(4): "center/radius from `pts[0..1]`/bbox").
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:mobile_app/features/tools/tool_palette_dock.dart';

/// Node `kind` for [tool] under `ELEMENT_COMMIT/ADD_SHAPE` (Doc 03 kind
/// enum: `LINE` for the line tool, `SHAPE` for every geometric shape).
///
/// Round-9 issue 06 — the table tool is a `SHAPE` too: `shape_type: "TABLE"`
/// plus its grid in `graph_config` (see [shapeTypeForTool]).
String shapeKindForTool(StudioTool tool) =>
    tool == StudioTool.line ? 'LINE' : 'SHAPE';

/// `geometry.shape_type` for [tool]; `null` for the line tool (the Doc 03
/// `shape_type` enum has no `LINE` value) and for non-shape tools.
///
/// The table's `pts` are only its two bbox corners (the grid is config-driven),
/// which is the same layout RECT uses, so a table selection/resize behaves like
/// a rectangle.
String? shapeTypeForTool(StudioTool tool) => switch (tool) {
      StudioTool.rect => 'RECT',
      StudioTool.circle => 'CIRCLE',
      StudioTool.triangle => 'TRIANGLE',
      StudioTool.arrow => 'ARROW',
      StudioTool.table => 'TABLE',
      _ => null,
    };

/// Committed `geometry.pts` for a drag from [start] to [end] (WORLD
/// anchors — see the library doc for the per-tool table).
List<List<double>> shapePtsForTool(
  StudioTool tool, {
  required Offset start,
  required Offset end,
}) {
  final Rect rect = Rect.fromPoints(start, end);
  return switch (tool) {
    StudioTool.line || StudioTool.arrow => <List<double>>[
        <double>[start.dx, start.dy],
        <double>[end.dx, end.dy],
      ],
    StudioTool.triangle => <List<double>>[
        <double>[rect.left, rect.bottom], // bottom-left
        <double>[rect.right, rect.bottom], // bottom-right
        <double>[rect.center.dx, rect.top], // top center
      ],
    StudioTool.circle => const <List<double>>[
        // Bbox convention — see the library doc.
      ],
    _ => <List<double>>[
        <double>[rect.left, rect.top],
        <double>[rect.right, rect.bottom],
      ],
  };
}

/// Live-preview polyline (WORLD) for an in-flight drag: the rubber-band
/// outline of the shape being drawn, so the local preview shows the actual
/// shape (not a bare line) while `ToolId.shapePreview` frames mirror the
/// drag corner to the PC.
List<Offset> shapePreviewPoints(
  StudioTool tool,
  Offset start,
  Offset end,
) {
  final Rect rect = Rect.fromPoints(start, end);
  return switch (tool) {
    // Round-9 issue 06 — a table drag previews its outer rectangle, exactly
    // like a RECT (the grid appears once it is committed).
    StudioTool.rect || StudioTool.table => <Offset>[
        rect.topLeft,
        rect.topRight,
        rect.bottomRight,
        rect.bottomLeft,
        rect.topLeft,
      ],
    StudioTool.circle => _ellipseRing(rect),
    StudioTool.triangle => <Offset>[
        rect.bottomLeft,
        rect.bottomRight,
        Offset(rect.center.dx, rect.top),
        rect.bottomLeft,
      ],
    _ => <Offset>[start, end], // line + arrow: bare shaft/segment
  };
}

/// Closed 16-segment ring around [r] (matches the exporters' ellipse from
/// the same bbox).
List<Offset> _ellipseRing(Rect r) {
  const int segments = 16;
  final double cx = r.center.dx;
  final double cy = r.center.dy;
  final double rx = r.width / 2;
  final double ry = r.height / 2;
  return List<Offset>.generate(segments + 1, (int i) {
    final double a = 2 * math.pi * i / segments;
    return Offset(cx + rx * math.cos(a), cy + ry * math.sin(a));
  });
}
