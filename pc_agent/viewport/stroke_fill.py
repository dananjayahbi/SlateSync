"""Round-11 issue 04 — fill a free-hand pen loop on the PC mirror.

The paint bucket can fill a *free-hand* stroke: if the pen returns to its own
start (or overshoots it and crosses itself) there is no gap for colour to leak
through, so the loop encloses a region. The tablet implements that rule in
``mobile_app/lib/canvas_engine/region_fill.dart`` and paints the interior with
``paintNodeFill``.

The PC could not: a filled ``STROKE`` node still arrives with
``kind == "STROKE"``, and the mirror renders strokes through the ink
tessellator (``gl_canvas_host._commit_node``) which knows nothing about
``style.fill`` — ``PrimitiveRenderer`` only ever sees ``SHAPE`` / ``LINE``
nodes. So a filled pen loop appeared on the tablet and stayed an outline on the
PC (round-11 issue 04).

This module is the PC twin of ``region_fill.dart``'s stroke branch: it answers
"does this STROKE enclose a region, and if so what is its polygon". Every PC
renderer (viewport fill pass, tiled raster exporter, vector PDF exporter) and
the thumbnail renderer call it, so the four cannot drift apart.

Pure geometry — no moderngl, no cairo, no PIL.
"""

from __future__ import annotations

import math

from pc_agent.viewport.vector_geometry import Point, points_of

#: The pen's endpoints must land within this fraction of the path diagonal...
CLOSURE_RATIO = 0.12
#: ...floored at this many world units so a tiny loop still counts.
#: Matches ``kClosureToleranceMin`` in ``region_fill.dart``.
CLOSURE_MIN = 6.0
#: Fewest segments before a self-crossing can be taken seriously.
MIN_CROSSING_POINTS = 5


def _bbox_span(points: list[Point]) -> float:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return math.hypot(max(xs) - min(xs), max(ys) - min(ys))


def closure_limit(points: list[Point], stroke_width: float = 0.0) -> float:
    """Distance within which the two ends of a polyline count as sealed.

    The ink is ``stroke_width`` wide, so its own body bridges the last gap — a
    full width is generous and still far below a real leak.
    """
    if not points:
        return CLOSURE_MIN
    return max(CLOSURE_MIN, _bbox_span(points) * CLOSURE_RATIO, abs(stroke_width))


def _cross(o: Point, a: Point, b: Point) -> float:
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _segments_cross(a: Point, b: Point, c: Point, d: Point) -> bool:
    d1 = _cross(c, d, a)
    d2 = _cross(c, d, b)
    d3 = _cross(a, b, c)
    d4 = _cross(a, b, d)
    return (
        ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0))
        and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
    )


def polyline_self_intersects(points: list[Point]) -> bool:
    """``True`` when the path crosses itself — the "overshoot the start" loop."""
    if len(points) < MIN_CROSSING_POINTS:
        return False
    count = len(points)
    for i in range(count - 1):
        for j in range(i + 2, count - 1):
            if i == 0 and j + 1 == count - 1:
                continue  # the closure segment itself — adjacency, not a crossing
            if _segments_cross(points[i], points[i + 1], points[j], points[j + 1]):
                return True
    return False


def polyline_closes(points: list[Point], stroke_width: float = 0.0) -> bool:
    """``True`` when a free-hand polyline encloses a region.

    Closed means *either* the ends meet (within :func:`closure_limit`, which
    includes the ink width) *or* the path crosses itself — the natural way to
    close a circle is to draw past the start, and the crossing point is a real
    seal because no gap exists for colour to escape.
    """
    if len(points) < 3:
        return False
    first, last = points[0], points[-1]
    gap = math.hypot(last[0] - first[0], last[1] - first[1])
    if gap <= closure_limit(points, stroke_width):
        return True
    return polyline_self_intersects(points)


def stroke_fill_polygon(
    pts: object, stroke_width: float = 0.0
) -> list[Point] | None:
    """The region a free-hand stroke encloses, or ``None`` when it encloses none."""
    points = points_of(pts)
    if not polyline_closes(points, stroke_width):
        return None
    return points


def stroke_fill_polygon_of(node: object) -> list[Point] | None:
    """Same, straight from a ``CanvasNode``-shaped object."""
    geometry = getattr(node, "geometry", None)
    style = getattr(node, "style", None)
    return stroke_fill_polygon(
        getattr(geometry, "pts", None) or [],
        float(getattr(style, "stroke_width", 0.0) or 0.0),
    )
