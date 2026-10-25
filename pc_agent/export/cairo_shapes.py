"""Round-9 — shared cairo shape path builder for the three exporters.

The raster, PDF and thumbnail exporters each carried their own copy of
"draw one SHAPE node". They had already drifted once (round-8's arrow
geometry), and round 9 adds three new cases to every one of them — fill
(`style.fill`), rotated polygons (`shape_type == "PATH"`) and tables
(`shape_type == "TABLE"`). Copying that three more times is how the four
renderers stop agreeing with the tablet.

This module owns the **path**: it builds the outline of any shape type into the
cairo context and fills it when the node carries a fill. Each exporter keeps its
own colour/line-width handling (they legitimately differ: the thumbnail scales
the width), calls :func:`apply_fill`, then traces and strokes.

The only thing deliberately left to the callers is the stroke itself, because
``stroke_width == 0`` must still produce a hairline in every renderer rather
than an invisible edge.
"""

from __future__ import annotations

import math

import cairo

from pc_agent.viewport.stroke_fill import stroke_fill_polygon
from pc_agent.viewport.vector_geometry import (
    outline_segments,
    points_of,
    rect_to_triangles,
    table_geometry,
    triangulate,
)

#: Header band tint when a TABLE has no explicit fill (fraction of the stroke
#: colour) — a table with invisible headers defeats the point of the option.
TABLE_HEADER_TINT = 0.12


def set_fill_colour(ctx: cairo.Context, colour: str, opacity: float) -> None:
    """Sets the cairo source to a ``#RRGGBB`` colour at ``opacity``."""
    red, green, blue = hex_to_rgb(colour)
    alpha = max(0.0, min(1.0, float(opacity)))
    ctx.set_source_rgba(red, green, blue, alpha)


def hex_to_rgb(colour: str) -> tuple[float, float, float]:
    """``#RRGGBB`` → three 0..1 floats; malformed values fall back to black."""
    token = colour[1:] if isinstance(colour, str) and colour.startswith("#") else ""
    if len(token) != 6:
        return (0.0, 0.0, 0.0)
    try:
        return (
            int(token[0:2], 16) / 255.0,
            int(token[2:4], 16) / 255.0,
            int(token[4:6], 16) / 255.0,
        )
    except ValueError:
        return (0.0, 0.0, 0.0)


def fill_colour(style: object) -> str | None:
    """The node's interior colour, or ``None`` when it has no fill."""
    colour = getattr(style, "fill", None)
    if not isinstance(colour, str) or len(colour) != 7 or colour[0] != "#":
        return None
    try:
        int(colour[1:], 16)
    except ValueError:
        return None
    return colour


def _polygon_path(ctx: cairo.Context, polygon: list[tuple[float, float]]) -> bool:
    if len(polygon) < 3:
        return False
    ctx.move_to(*polygon[0])
    for point in polygon[1:]:
        ctx.line_to(*point)
    ctx.close_path()
    return True


def ellipse_path(
    ctx: cairo.Context, box: tuple[float, float, float, float]
) -> bool:
    """Cubic-approximated ellipse inscribed in ``box``; ``False`` if degenerate."""
    bx0, by0, bx1, by1 = box
    rx, ry = max(1e-3, (bx1 - bx0) / 2.0), max(1e-3, (by1 - by0) / 2.0)
    cx, cy = (bx0 + bx1) / 2.0, (by0 + by1) / 2.0
    k = 0.5522847498  # circle ⇄ cubic κ
    ctx.move_to(cx + rx, cy)
    ctx.curve_to(cx + rx, cy + ry * k, cx + rx * k, cy + ry, cx, cy + ry)
    ctx.curve_to(cx - rx * k, cy + ry, cx - rx, cy + ry * k, cx - rx, cy)
    ctx.curve_to(cx - rx, cy - ry * k, cx - rx * k, cy - ry, cx, cy - ry)
    ctx.curve_to(cx + rx * k, cy - ry, cx + rx, cy - ry * k, cx + rx, cy)
    ctx.close_path()
    return rx > 0 and ry > 0


def _triangles_path(
    ctx: cairo.Context, flat: list[float]
) -> None:
    """Adds a flat ``[x, y, ...]`` triangle list to the current path."""
    for index in range(0, len(flat) - 5, 6):
        ctx.move_to(flat[index], flat[index + 1])
        ctx.line_to(flat[index + 2], flat[index + 3])
        ctx.line_to(flat[index + 4], flat[index + 5])
        ctx.close_path()


def apply_fill(
    ctx: cairo.Context,
    style: object,
    shape: str | None,
    box: tuple[float, float, float, float],
    pts: object,
    config: object = None,
) -> bool:
    """Fills the node's interior when it has a fill; ``True`` when it painted.

    Honours both spellings (explicit ``style.fill``, and legacy
    ``stroke_width == 0`` ⇒ solid in ``color``) so the exporters agree with the
    viewport and with the tablet.
    """
    legacy = float(getattr(style, "stroke_width", 0.0) or 0.0) <= 1e-6
    colour = fill_colour(style)
    if colour is None and not legacy:
        return False
    if colour is None:
        colour = getattr(style, "color", "#1E1E1E")
    opacity = getattr(style, "opacity", 1.0)
    if shape in ("CARTESIAN_2D", "NUMBER_LINE"):
        return False  # graph axes are line work
    if shape == "ARROW":
        return False  # always stroked, never a filled wedge
    set_fill_colour(ctx, colour, opacity)
    ctx.new_path()
    if shape == "CIRCLE":
        if not ellipse_path(ctx, box):
            return False
    elif shape == "TRIANGLE":
        triangle = points_of(pts)
        if len(triangle) >= 3:
            _polygon_path(ctx, triangle[:3])
        else:
            bx0, by0, bx1, by1 = box
            _polygon_path(
                ctx,
                [
                    ((bx0 + bx1) / 2.0, by0),
                    (bx1, by1),
                    (bx0, by1),
                ],
            )
    elif shape == "PATH":
        polygon = points_of(pts)
        if len(polygon) < 3:
            return False
        _polygon_path(ctx, polygon)
    elif shape == "TABLE":
        geo = table_geometry(box, config)
        if not geo.is_valid or not geo.header_rects:
            return False
        for band in geo.header_rects:
            ctx.rectangle(band[0], band[1], band[2] - band[0], band[3] - band[1])
    else:
        bx0, by0, bx1, by1 = box
        ctx.rectangle(bx0, by0, bx1 - bx0, by1 - by0)
    ctx.fill()
    return True


def apply_stroke_fill(ctx: cairo.Context, node: object) -> bool:
    """Round-11 issue 04 — fills a CLOSED free-hand pen loop.

    The paint bucket can fill a free-hand stroke when the pen returns to its
    own start, and the tablet paints that interior (``paintNodeFill``). The
    cairo exporters used to trace only the ink, so the exported PNG/PDF showed
    the outline of a loop the user had filled.

    Returns ``True`` when an interior was painted. ``False`` for an open stroke
    (it encloses nothing — filling it would flood the page) and for a stroke
    with no fill colour.
    """
    kind = str(getattr(node, "kind", "") or "")
    if kind not in ("STROKE", "HIGHLIGHT"):
        return False
    style = getattr(node, "style", None)
    colour = fill_colour(style)
    if colour is None:
        return False
    geometry = getattr(node, "geometry", None)
    polygon = stroke_fill_polygon(
        getattr(geometry, "pts", None) or [],
        float(getattr(style, "stroke_width", 0.0) or 0.0),
    )
    if polygon is None or len(polygon) < 3:
        return False
    set_fill_colour(ctx, colour, getattr(style, "opacity", 1.0))
    ctx.new_path()
    if not _polygon_path(ctx, polygon):
        return False
    ctx.fill()
    return True


def trace_shape(
    ctx: cairo.Context,
    node: object,
    box: tuple[float, float, float, float],
    shape: str | None,
) -> None:
    """Builds the OUTLINE path of [node] into [ctx] (no fill, no stroke).

    ``box`` is the node's normalised bbox. The caller sets the colour and the
    line width first, because those legitimately differ per exporter.
    """
    geometry = getattr(node, "geometry", None)
    pts = getattr(geometry, "pts", None) or []
    style = getattr(node, "style", None)
    bx0, by0, bx1, by1 = box
    if shape == "CIRCLE":
        ellipse_path(ctx, box)
        return
    if shape == "TRIANGLE":
        triangle = points_of(pts)
        if len(triangle) >= 3:
            _polygon_path(ctx, triangle[:3])
        else:
            _polygon_path(
                ctx,
                [((bx0 + bx1) / 2.0, by0), (bx1, by1), (bx0, by1)],
            )
        return
    if shape == "ARROW":
        _trace_arrow(ctx, node, box, style)
        return
    if shape == "PATH":
        polygon = points_of(pts)
        if _polygon_path(ctx, polygon):
            return
        # A 2-point PATH is a degenerate polygon — draw it as the open segment
        # it is instead of dropping the node from the export entirely.
        for ax, ay, bx, by in _open_segments(points_of(pts)):
            ctx.move_to(ax, ay)
            ctx.line_to(bx, by)
        return
    if shape == "TABLE":
        _trace_table(ctx, box, getattr(geometry, "graph_config", None))
        return
    # RECT and unknown types fall back to the bbox rectangle (Doc 08 §4).
    ctx.rectangle(bx0, by0, bx1 - bx0, by1 - by0)


def _open_segments(
    points: list[tuple[float, float]],
) -> list[tuple[float, float, float, float]]:
    return [
        (points[i][0], points[i][1], points[i + 1][0], points[i + 1][1])
        for i in range(len(points) - 1)
    ]


def _trace_arrow(
    ctx: cairo.Context, node: object, box: tuple[float, float, float, float], style: object
) -> None:
    """ARROW shaft plus its two ±0.4 rad barbs (the tablet's `_drawArrow`)."""
    bx0, by0, bx1, by1 = box
    coords = points_of(getattr(getattr(node, "geometry", None), "pts", None) or [])
    if len(coords) >= 2:
        ax, ay = coords[0]
        tx, ty = coords[-1]
    else:
        ax, ay = bx0, (by0 + by1) / 2.0
        tx, ty = bx1, (by0 + by1) / 2.0
    ctx.move_to(ax, ay)
    ctx.line_to(tx, ty)
    angle = math.atan2(ty - ay, tx - ax)
    head = max(12.0, float(getattr(style, "stroke_width", 2.5) or 2.5) * 4.0)
    for delta in (-0.4, 0.4):
        ctx.move_to(tx, ty)
        ctx.line_to(
            tx - head * math.cos(angle + delta),
            ty - head * math.sin(angle + delta),
        )


def _trace_table(
    ctx: cairo.Context, box: tuple[float, float, float, float], config: object
) -> None:
    geo = table_geometry(box, config)
    if not geo.is_valid:
        return
    for ax, ay, bx, by in geo.lines:
        ctx.move_to(ax, ay)
        ctx.line_to(bx, by)


def trace_polygon_fill(
    ctx: cairo.Context,
    pts: object,
    colour: str,
    opacity: float,
) -> bool:
    """Fills an arbitrary closed polygon (used for pen-loop fills).

    Triangulated rather than ``ctx.fill()``-ed directly so a self-intersecting
    loop cannot punch a hole via the even-odd rule — the same choice the GL
    viewport makes, which keeps the export and the mirror identical.
    """
    polygon = points_of(pts)
    if len(polygon) < 3:
        return False
    flat = triangulate(polygon)
    if not flat:
        return False
    set_fill_colour(ctx, colour, opacity)
    ctx.new_path()
    _triangles_path(ctx, flat)
    ctx.fill()
    return True


__all__ = [
    "TABLE_HEADER_TINT",
    "apply_fill",
    "fill_colour",
    "hex_to_rgb",
    "set_fill_colour",
    "trace_shape",
    "trace_polygon_fill",
    "rect_to_triangles",
    "outline_segments",
]
