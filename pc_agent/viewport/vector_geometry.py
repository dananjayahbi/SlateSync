"""Round-9 issues 04/05/06 — polygon, path and table geometry.

Three round-9 features need the same primitive: *turn a node into a closed
polygon*, and two of them also need a *triangulation* of that polygon so the
GL viewport can fill it with the existing TRIANGLES batch.

* **Fill tool (issue 04)** — the tablet paints an interior colour onto a node
  whose geometry encloses the tapped point. The mirror has to paint the same
  interior, so a RECT / CIRCLE / TRIANGLE / closed STROKE / PATH all reduce to
  "outline polygon → fill triangles".
* **Rotation (issue 05)** — a rotated shape cannot stay a RECT (its bbox is
  axis-aligned by contract), so the tablet re-emits it as ``shape_type:
  "PATH"`` with the four rotated corners. PATH is therefore just "a polygon".
* **Table (issue 06)** — a table is a rectangle of rows/columns; every renderer
  needs the same grid lines and the same header bands, and a header band is a
  filled rectangle, so it reuses the same triangle helpers.

Pure geometry: no moderngl, no cairo, no PIL. The viewport, all three
exporters and the tests share it, which is what keeps the four renderers from
drifting apart (the round-8 shape/arrow divergence came from each renderer
owning its own copy of this maths).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

Point = tuple[float, float]

#: Screen/world ratio of a closed free-hand loop: the pen's first and last
#: sample must be this close (relative to the path diagonal) to count as a
#: closed region. A real "circle drawn by hand" typically closes to within a
#: few percent; an open arc does not.
CLOSE_TOLERANCE_RATIO = 0.12
#: Absolute floor for the same test, in world units (300-DPI page units), so a
#: tiny hand-drawn loop still closes.
CLOSE_TOLERANCE_MIN = 12.0
#: Segment count for an ellipse polygon (matches ``CIRCLE_SEGMENTS`` cheaply;
#: the fill triangulator consumes it, so a coarse rim is invisible under ink).
ELLIPSE_SEGMENTS = 48


def points_of(pts: object) -> list[Point]:
    """``geometry.pts`` → ``[(x, y), ...]``, dropping malformed entries."""
    out: list[Point] = []
    if not isinstance(pts, (list, tuple)):
        return out
    for item in pts:
        if not isinstance(item, (list, tuple)) or len(item) < 2:
            continue
        try:
            out.append((float(item[0]), float(item[1])))
        except (TypeError, ValueError):
            continue
    return out


def _bbox_of(bbox: object) -> tuple[float, float, float, float] | None:
    if not isinstance(bbox, (list, tuple)) or len(bbox) < 4:
        return None
    try:
        x0, y0, x1, y1 = (float(v) for v in bbox[:4])
    except (TypeError, ValueError):
        return None
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def rect_polygon(bbox: object) -> list[Point]:
    """Closed 4-point rectangle from a node bbox (empty when degenerate)."""
    box = _bbox_of(bbox)
    if box is None or box[0] == box[2] or box[1] == box[3]:
        return []
    x0, y0, x1, y1 = box
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def ellipse_polygon(bbox: object, segments: int = ELLIPSE_SEGMENTS) -> list[Point]:
    """Closed ellipse polygon inscribed in ``bbox`` (empty when degenerate)."""
    box = _bbox_of(bbox)
    if box is None:
        return []
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    rx, ry = (x1 - x0) / 2.0, (y1 - y0) / 2.0
    if rx <= 0 or ry <= 0:
        return []
    return [
        (
            cx + rx * math.cos(2.0 * math.pi * i / segments),
            cy + ry * math.sin(2.0 * math.pi * i / segments),
        )
        for i in range(segments)
    ]


def triangle_polygon(pts: object, bbox: object) -> list[Point]:
    """TRIANGLE from the first three ``pts``, else the bbox fallback triangle."""
    usable = points_of(pts)
    if len(usable) >= 3:
        return usable[:3]
    box = _bbox_of(bbox)
    if box is None:
        return []
    x0, y0, x1, y1 = box
    return [((x0 + x1) / 2.0, y0), (x1, y1), (x0, y1)]


def polyline_is_closed(
    pts: object,
    tolerance: float = CLOSE_TOLERANCE_MIN,
) -> bool:
    """``True`` when a free-hand point list ends where it started.

    The tolerance is the larger of [tolerance] and a fraction of the path
    diagonal, so both a page-sized loop and a thumbnail-sized one close on the
    same relative accuracy. A degenerate path (< 3 points) is never a region.
    """
    points = points_of(pts)
    if len(points) < 3:
        return False
    (ax, ay), (bx, by) = points[0], points[-1]
    diag = math.hypot(bx - ax, by - ay)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    span = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
    limit = max(float(tolerance), span * CLOSE_TOLERANCE_RATIO)
    return diag <= limit


def polygon_points(points: list[Point]) -> list[float]:
    """Flat ``[x0, y0, x1, y1, ...]`` for callers that build vertex lists."""
    flat: list[float] = []
    for x, y in points:
        flat.extend((x, y))
    return flat


def signed_area(points: list[Point]) -> float:
    """Shoelace area; positive when the winding is counter-clockwise."""
    if len(points) < 3:
        return 0.0
    total = 0.0
    for i, (x0, y0) in enumerate(points):
        x1, y1 = points[(i + 1) % len(points)]
        total += x0 * y1 - x1 * y0
    return total / 2.0


def point_in_polygon(point: Point, points: list[Point]) -> bool:
    """Even-odd ray cast — also correct for the concave paths a pen produces."""
    if len(points) < 3:
        return False
    x, y = float(point[0]), float(point[1])
    inside = False
    j = len(points) - 1
    for i, (xi, yi) in enumerate(points):
        xj, yj = points[j]
        if (yi > y) != (yj > y):
            denom = yj - yi
            if denom != 0.0:
                x_cross = xi + (y - yi) * (xj - xi) / denom
                if x < x_cross:
                    inside = not inside
        j = i
    return inside


def _cross(o: Point, a: Point, b: Point) -> float:
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])


def _is_ear(points: list[Point], i: int, prev_i: int, next_i: int) -> bool:
    a, b, c = points[prev_i], points[i], points[next_i]
    if _cross(a, b, c) <= 0.0:
        return False  # reflex (or collinear) vertex — not an ear
    for j, p in enumerate(points):
        if j in (prev_i, i, next_i):
            continue
        if _point_in_triangle(p, a, b, c):
            return False
    return True


def _point_in_triangle(p: Point, a: Point, b: Point, c: Point) -> bool:
    d1 = _cross(a, b, p)
    d2 = _cross(b, c, p)
    d3 = _cross(c, a, p)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def triangulate(points: list[Point]) -> list[float]:
    """Ear-clipping triangulation → flat ``[x, y, x, y, x, y, ...]`` triples.

    Ear clipping (rather than a fan) is required because a pen-drawn loop is
    routinely concave — a fan across a concave polygon paints outside the
    outline, which is exactly the artefact the fill tool must not produce.

    Degenerate input (< 3 points) and self-intersections that defeat the ear
    search fall back to a triangle fan so the caller always gets *something*
    rather than a silent hole in the canvas.
    """
    pts = list(points)
    if len(pts) < 3:
        return []
    if signed_area(pts) < 0:
        pts.reverse()  # ear clipping below assumes counter-clockwise winding
    remaining = list(range(len(pts)))
    out: list[float] = []
    guard = len(pts) * len(pts) + 8
    while len(remaining) > 3 and guard > 0:
        guard -= 1
        ear_found = False
        for pos in range(len(remaining)):
            i = remaining[pos]
            prev_i = remaining[pos - 1]
            next_i = remaining[(pos + 1) % len(remaining)]
            if not _is_ear(pts, i, prev_i, next_i):
                continue
            for index in (prev_i, i, next_i):
                out.extend(pts[index])
            remaining.pop(pos)
            ear_found = True
            break
        if not ear_found:
            break  # self-intersecting path — fall through to the fan
    if len(remaining) >= 3:
        for index in remaining:
            out.extend(pts[index])
    # A partial ear walk still leaves a valid band; a fan of the remainder
    # closes whatever is left over.
    return out


def outline_segments(points: list[Point]) -> list[tuple[float, float, float, float]]:
    """Closed-loop ``(ax, ay, bx, by)`` segments, last point back to first."""
    if len(points) < 2:
        return []
    segments = [
        (points[i][0], points[i][1], points[i + 1][0], points[i + 1][1])
        for i in range(len(points) - 1)
    ]
    segments.append(
        (points[-1][0], points[-1][1], points[0][0], points[0][1])
    )
    return segments


def polyline_segments(points: list[Point]) -> list[tuple[float, float, float, float]]:
    """Open ``(ax, ay, bx, by)`` segments through ``points``."""
    return [
        (points[i][0], points[i][1], points[i + 1][0], points[i + 1][1])
        for i in range(len(points) - 1)
    ]


# ---------------------------------------------------------------------------
# Tables (round-9 issue 06)
# ---------------------------------------------------------------------------

#: Guard rails for a hostile / corrupt ``graph_config`` on a TABLE node.
MIN_TABLE_ROWS = 1
MAX_TABLE_ROWS = 200
MIN_TABLE_COLS = 1
MAX_TABLE_COLS = 40


@dataclass
class TableGeometry:
    """Grid description of a TABLE node, in world units."""

    #: Outer rect ``(x0, y0, x1, y1)``; empty when the node is degenerate.
    box: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    rows: int = 3
    cols: int = 3
    header_row: bool = True
    header_col: bool = False
    #: Every grid segment, borders included.
    lines: list[tuple[float, float, float, float]] = field(default_factory=list)
    #: Filled header bands as ``(x0, y0, x1, y1)`` rects.
    header_rects: list[tuple[float, float, float, float]] = field(
        default_factory=list
    )
    #: Row boundaries (``rows + 1`` values, top → bottom).
    row_edges: list[float] = field(default_factory=list)
    #: Column boundaries (``cols + 1`` values, left → right).
    col_edges: list[float] = field(default_factory=list)

    @property
    def is_valid(self) -> bool:
        return self.rows >= 1 and self.cols >= 1 and bool(self.lines)


def _int_in(value: object, fallback: int, low: int, high: int) -> int:
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return fallback
    return max(low, min(high, parsed))


def table_geometry(bbox: object, config: object) -> TableGeometry:
    """Grid for a TABLE node.

    ``graph_config`` keys (Doc 03, round-9 extension): ``rows`` / ``cols`` are
    the TOTAL cell counts on each axis (header band included), ``header_row`` /
    ``header_col`` mark the first band of that axis. Clamped so a corrupt
    document can never emit a million gridlines.
    """
    cfg = config if isinstance(config, dict) else {}
    rows = _int_in(cfg.get("rows"), 3, MIN_TABLE_ROWS, MAX_TABLE_ROWS)
    cols = _int_in(cfg.get("cols"), 3, MIN_TABLE_COLS, MAX_TABLE_COLS)
    header_row = bool(cfg.get("header_row", True))
    header_col = bool(cfg.get("header_col", False))
    header_row = header_row and rows >= 2
    header_col = header_col and cols >= 2
    geo = TableGeometry(
        rows=rows,
        cols=cols,
        header_row=header_row,
        header_col=header_col,
    )
    box = _bbox_of(bbox)
    if box is None:
        return geo
    x0, y0, x1, y1 = box
    if x1 - x0 <= 0 or y1 - y0 <= 0:
        return geo
    geo.box = box
    geo.row_edges = [y0 + (y1 - y0) * i / rows for i in range(rows + 1)]
    geo.col_edges = [x0 + (x1 - x0) * i / cols for i in range(cols + 1)]
    for y in geo.row_edges:
        geo.lines.append((x0, y, x1, y))
    for x in geo.col_edges:
        geo.lines.append((x, y0, x, y1))
    if header_row:
        geo.header_rects.append((x0, geo.row_edges[0], x1, geo.row_edges[1]))
    if header_col:
        # The corner cell is already covered by the header row; only add the
        # column band below it so the two bands never double-paint.
        top = geo.row_edges[1] if header_row else geo.row_edges[0]
        geo.header_rects.append((geo.col_edges[0], top, geo.col_edges[1], y1))
    return geo


def rect_to_triangles(rect: tuple[float, float, float, float]) -> list[float]:
    """Two triangles covering ``(x0, y0, x1, y1)``."""
    x0, y0, x1, y1 = rect
    return [x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1]
