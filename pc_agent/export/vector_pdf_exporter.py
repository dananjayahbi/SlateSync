"""Vector PDF exporter (Doc 14) — pycairo-only; reportlab is declared in
``pc_agent/requirements.txt`` (Doc 04) but deliberately unused here.

Generates resolution-independent vector PDFs of bounded or INFINITE canvases
via pycairo ``PDFSurface`` so viewers can zoom to 6400% with razor-sharp
curves and text labels (E2E gate, template §3).

Page policy: bounded ⇒ one page = the artboard in points (world × 72/300);
INFINITE ⇒ single page = ``content_bounds`` padded 48 world units per side ×
72/300, degenerate ⇒ ``ValueError("empty canvas")``; any page dimension beyond
``PAGE_PT_LIMIT`` (14400 pt) falls back to multi-page tiling.

Stroke ``geometry.pts`` layouts (cross-doc contract, Doc 21): Bézier chains
``[P0, c1, c2, P1, c3, c4, P2, …]`` render as exact cubic segments; anything
else is converted from anchors with the local Catmull-Rom→cubic helper
(intentional duplicate of Doc 07 math).
"""

from __future__ import annotations

import math
from pathlib import Path
from time import monotonic
from typing import Callable
from uuid import uuid4

import cairo

from pc_agent.core.config_manager import AppConfig
from pc_agent.engine.document_store import Artboard, CanvasDocument, artboard_is_infinite
from pc_agent.engine.scene_graph import CanvasNode
from pc_agent.export.cairo_shapes import apply_fill, apply_stroke_fill, trace_shape
from pc_agent.viewport.text_renderer import draw_text_box, is_text_shape

#: Points = world_units × 72/300 (template §3).
UNIT_TO_PT: float = 72 / 300
#: PDF maximum page dimension in points; larger extents tile (Doc 14 §4).
PAGE_PT_LIMIT: int = 14400
#: INFINITE pages pad ``content_bounds`` by this many world units per side.
_EXTENT_PAD: float = 48.0
#: progress(fraction) is throttled to ≤10 Hz; final 1.0 is always flushed.
_PROGRESS_INTERVAL_S: float = 0.1
#: Background pattern pitch in world units (local duplication of Doc 08 math).
_GRID_SPACING: float = 32.0
_GRID_LINE_W: float = 1.0
_GRID_RGB: tuple[float, float, float] = (0.78, 0.78, 0.80)
_DOT_RGB: tuple[float, float, float] = (0.62, 0.62, 0.66)
_DOT_RADIUS: float = 1.5
#: Graph label font size in world units (= 5.76 pt after 72/300 scaling).
_LABEL_FONT: float = 24.0


def _part_path(out_path: Path) -> Path:
    """``.part`` temp sibling of ``out_path`` (inside ``config.export_dir``)."""
    return out_path.parent / f".{out_path.stem}.{uuid4().hex}.part"


def _page_extent(doc: CanvasDocument) -> tuple[float, float, float, float]:
    """World extent of the PDF page(s): bounded ⇒ ``(0, 0, w, h)``; INFINITE ⇒
    ``content_bounds`` padded 48 units/side; degenerate ⇒ ``ValueError``.

    §10.4 (issue 06): boundedness comes from the preset table
    (:func:`artboard_is_infinite`) — the page of a bounded preset is always its
    artboard in points, whatever the ``is_infinite`` flag says.
    """
    artboard = doc.artboard
    infinite = artboard_is_infinite(artboard)
    if not infinite:
        w, h = artboard.width, artboard.height
        if w is None or h is None or w <= 0 or h <= 0:
            raise ValueError("empty canvas")
        if not (math.isfinite(w) and math.isfinite(h)):
            raise ValueError("empty canvas")
        return (0.0, 0.0, float(w), float(h))
    bounds = doc.content_bounds or {}
    try:
        min_x = float(bounds["min_x"])
        min_y = float(bounds["min_y"])
        max_x = float(bounds["max_x"])
        max_y = float(bounds["max_y"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError("empty canvas") from exc
    corners = (min_x, min_y, max_x, max_y)
    if not all(math.isfinite(v) for v in corners) or max_x <= min_x or max_y <= min_y:
        raise ValueError("empty canvas")
    return (min_x - _EXTENT_PAD, min_y - _EXTENT_PAD, max_x + _EXTENT_PAD, max_y + _EXTENT_PAD)


def page_size_pt(doc: CanvasDocument) -> tuple[float, float]:
    """Frozen page policy (Doc 14 §4): page size in PDF points."""
    extent = _page_extent(doc)
    w_pt = (extent[2] - extent[0]) * UNIT_TO_PT
    h_pt = (extent[3] - extent[1]) * UNIT_TO_PT
    return (w_pt, h_pt)


def _tile_pages(w_pt: float, h_pt: float) -> list[tuple[int, int, float, float]]:
    """Tiles for a ``w_pt × h_pt`` extent: single page iff both dims ≤ 14400 pt.

    Larger extents split along the long axis into a row-major tile grid.
    Returns ``(page_index, page_count, offset_world_x, offset_world_y)`` with
    offsets measured in world units from the extent origin.
    """
    nx = max(1, math.ceil(w_pt / PAGE_PT_LIMIT))
    ny = max(1, math.ceil(h_pt / PAGE_PT_LIMIT))
    count = nx * ny
    tile_w_pt = w_pt / nx
    tile_h_pt = h_pt / ny
    tiles: list[tuple[int, int, float, float]] = []
    for j in range(ny):
        for i in range(nx):
            off_x = i * tile_w_pt / UNIT_TO_PT
            off_y = j * tile_h_pt / UNIT_TO_PT
            tiles.append((j * nx + i, count, off_x, off_y))
    return tiles


def _is_cubic_chain(pts: list[list[float]]) -> bool:
    """True for Doc 21 Bézier chains ``[P0, c1, c2, P1, c3, c4, P2, …]``.

    Doc 21 emits ``n = 3k − 2`` points for ``k`` anchors, i.e. ``n ≡ 1 (mod 3)``
    ⇒ ``(n − 1) % 3 == 0``; the frozen cross-doc contract additionally accepts
    ``(n − 2) % 3 == 0``.  Anything else (``n ≤ 3`` or ``n ≡ 0 (mod 3)``) is a
    plain anchor polyline for the Catmull-Rom→cubic fallback.
    """
    n = len(pts)
    return n >= 4 and ((n - 1) % 3 == 0 or (n - 2) % 3 == 0)


def _catmull_to_cubic(
    pts: list[list[float]],
) -> list[tuple[float, float, float, float, float, float]]:
    """Local Catmull-Rom (τ = 0.5) → cubic Bézier helper (Doc 07 math).

    Each sextuple ``(c1x, c1y, c2x, c2y, ex, ey)`` feeds one ``curve_to`` for
    the segment ending at ``(ex, ey)``; terminal points are clamped by
    duplicating the endpoint anchors.
    """
    anchors = [(float(p[0]), float(p[1])) for p in pts]
    n = len(anchors)
    segs: list[tuple[float, float, float, float, float, float]] = []
    for i in range(n - 1):
        p1 = anchors[i]
        p2 = anchors[i + 1]
        p0 = anchors[i - 1] if i > 0 else p1
        p3 = anchors[i + 2] if i + 2 < n else p2
        c1x = p1[0] + (p2[0] - p0[0]) / 6.0
        c1y = p1[1] + (p2[1] - p0[1]) / 6.0
        c2x = p2[0] - (p3[0] - p1[0]) / 6.0
        c2y = p2[1] - (p3[1] - p1[1]) / 6.0
        segs.append((c1x, c1y, c2x, c2y, p2[0], p2[1]))
    return segs


def _trace_path(ctx: cairo.Context, pts: list[list[float]]) -> bool:
    """Build the stroke path on ``ctx`` for either ``pts`` layout.

    Exact cubic chain when :func:`_is_cubic_chain` holds (``move_to P0`` then
    ``curve_to (c1, c2, P1)`` per triple); otherwise anchors are converted via
    :func:`_catmull_to_cubic`.  Returns ``False`` when there is nothing to draw.
    """
    n = len(pts)
    if n < 2:
        return False
    if _is_cubic_chain(pts):
        ctx.move_to(float(pts[0][0]), float(pts[0][1]))
        i = 1
        while i + 2 < n:
            ctx.curve_to(
                float(pts[i][0]),
                float(pts[i][1]),
                float(pts[i + 1][0]),
                float(pts[i + 1][1]),
                float(pts[i + 2][0]),
                float(pts[i + 2][1]),
            )
            i += 3
        if i < n:
            ctx.line_to(float(pts[i][0]), float(pts[i][1]))
        return True
    segs = _catmull_to_cubic(pts)
    if not segs:
        return False
    ctx.move_to(float(pts[0][0]), float(pts[0][1]))
    for seg in segs:
        ctx.curve_to(*seg)
    return True


def _set_color(ctx: cairo.Context, color: str, alpha: float = 1.0) -> None:
    """Set a (possibly alpha) source from a ``#RRGGBB`` / ``#RGB`` hex string."""
    raw = (color or "#000000").lstrip("#")
    if len(raw) == 3:
        raw = "".join(ch * 2 for ch in raw)
    try:
        r = int(raw[0:2], 16) / 255.0
        g = int(raw[2:4], 16) / 255.0
        b = int(raw[4:6], 16) / 255.0
    except (ValueError, IndexError):
        r = g = b = 0.0
    ctx.set_source_rgba(r, g, b, max(0.0, min(1.0, float(alpha))))


def _paint_pattern(
    ctx: cairo.Context,
    style: str,
    rect: tuple[float, float, float, float],
    spacing: float = 32.0,
) -> None:
    """RULED / SQUARE_GRID helper, spacing-aware (round-9).

    ``DOT_GRID`` / ``ISO_GRID`` were removed from the Doc 03 enum; documents
    that still carry them are normalised to ``BLANK`` by ``DocumentStore`` on
    load, so they never reach this function.
    """
    step = max(float(spacing), 1.0)
    if style not in ("RULED", "SQUARE_GRID"):
        return
    x0, y0, x1, y1 = rect
    ctx.set_line_width(_GRID_LINE_W)
    ctx.set_source_rgb(*_GRID_RGB)
    ctx.new_path()
    if style == "RULED":
        y = math.floor(y0 / step) * step
        while y <= y1:
            ctx.move_to(x0, y)
            ctx.line_to(x1, y)
            y += step
    else:  # SQUARE_GRID — both families ⇒ closed cells.
        y = math.floor(y0 / step) * step
        while y <= y1:
            ctx.move_to(x0, y)
            ctx.line_to(x1, y)
            y += step
        x = math.floor(x0 / step) * step
        while x <= x1:
            ctx.move_to(x, y0)
            ctx.line_to(x, y1)
            x += step
    ctx.stroke()


def _draw_background(ctx: cairo.Context, artboard: Artboard, w: float, h: float) -> None:
    """Fill ``background_color`` + grid pattern over the local page rect."""
    _set_color(ctx, artboard.background_color, 1.0)
    ctx.rectangle(0.0, 0.0, float(w), float(h))
    ctx.fill()
    _paint_pattern(
        ctx,
        artboard.background_style,
        (0.0, 0.0, float(w), float(h)),
        getattr(artboard, "background_spacing", _GRID_SPACING),
    )


def _intersects(
    bbox: tuple[float, float, float, float], rect: tuple[float, float, float, float]
) -> bool:
    """Bbox ∩ rect pre-filter; degenerate bboxes are conservatively included."""
    rx0, ry0, rx1, ry1 = rect
    bx0, by0, bx1, by1 = (float(v) for v in bbox)
    if bx1 <= bx0 or by1 <= by0:
        return True
    return bx0 < rx1 and bx1 > rx0 and by0 < ry1 and by1 > ry0


def _draw_stroke(ctx: cairo.Context, node: CanvasNode, kind: str) -> None:
    style = node.style
    pts = node.geometry.pts
    multiply = kind == "HIGHLIGHT" or style.blend_mode == "MULTIPLY"
    if multiply:
        ctx.set_operator(cairo.OPERATOR_MULTIPLY)
    try:
        # Round-11 issue 04 — the interior of a closed pen loop goes UNDER the
        # ink, exactly as `paintNodeFill` paints it before the outline.
        apply_stroke_fill(ctx, node)
        _set_color(ctx, style.color, style.opacity)
        ctx.set_line_width(max(1e-3, float(style.stroke_width)))
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        if len(pts) == 1:
            x, y = float(pts[0][0]), float(pts[0][1])
            ctx.arc(x, y, max(0.5, float(style.stroke_width) / 2.0), 0.0, math.tau)
            ctx.fill()
        elif kind == "LINE" and len(pts) >= 2:
            # LINE is always a straight segment: first anchor → last anchor.
            ctx.move_to(float(pts[0][0]), float(pts[0][1]))
            ctx.line_to(float(pts[-1][0]), float(pts[-1][1]))
            ctx.stroke()
        elif _trace_path(ctx, pts):
            ctx.stroke()
    finally:
        if multiply:
            ctx.set_operator(cairo.OPERATOR_OVER)


def _draw_shape(ctx: cairo.Context, node: CanvasNode) -> None:
    shape = node.geometry.shape_type
    if shape in ("CARTESIAN_2D", "NUMBER_LINE"):
        _draw_graph(ctx, node)
        return
    style = node.style
    bx0, by0, bx1, by1 = (float(v) for v in node.bbox)
    if bx1 < bx0:
        bx0, bx1 = bx1, bx0
    if by1 < by0:
        by0, by1 = by1, by0
    box = (bx0, by0, bx1, by1)
    # Round-9 issues 04/05/06 — shared with the raster/thumbnail exporters so
    # the vector output cannot drift (fill, rotated PATH, TABLE grid).
    apply_fill(ctx, style, shape, box, node.geometry.pts, node.geometry.graph_config)
    if is_text_shape(shape):
        # Round-12 issue 05 — glyphs instead of a bbox outline (see trace_shape).
        draw_text_box(
            ctx,
            node.geometry.graph_config,
            box,
            getattr(style, "color", "#1E1E1E"),
            float(getattr(style, "opacity", 1.0) or 1.0),
        )
        return
    _set_color(ctx, style.color, style.opacity)
    ctx.set_line_width(max(0.5, float(style.stroke_width)))
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.new_path()
    trace_shape(ctx, node, box, shape)
    ctx.stroke()


def _draw_graph(ctx: cairo.Context, node: CanvasNode) -> None:
    """CARTESIAN_2D / NUMBER_LINE axes from ``graph_config`` (overview §4.3)."""
    cfg = node.geometry.graph_config or {}
    style = node.style
    try:
        origin = cfg.get("origin") or [0.0, 0.0]
        ox, oy = float(origin[0]), float(origin[1])
    except (TypeError, ValueError, IndexError):
        ox, oy = 0.0, 0.0
    x_range = cfg.get("x_range") or [-10.0, 10.0]
    y_range = cfg.get("y_range") or [-10.0, 10.0]
    try:
        xr0, xr1 = float(x_range[0]), float(x_range[1])
        yr0, yr1 = float(y_range[0]), float(y_range[1])
    except (TypeError, ValueError, IndexError):
        xr0, xr1, yr0, yr1 = -10.0, 10.0, -10.0, 10.0
    if xr1 < xr0:
        xr0, xr1 = xr1, xr0
    if yr1 < yr0:
        yr0, yr1 = yr1, yr0
    gs = float(cfg.get("grid_step") or 25.0)
    if gs <= 0:
        gs = 25.0
    show_labels = bool(cfg.get("show_labels", True))
    number_line = node.geometry.shape_type == "NUMBER_LINE"
    wx0, wx1 = ox + xr0 * gs, ox + xr1 * gs
    wy0, wy1 = oy - yr1 * gs, oy - yr0 * gs  # data y is up; world y is down.
    # Light grid at integer data units.
    ctx.set_source_rgb(*_GRID_RGB)
    ctx.set_line_width(1.0)
    ctx.new_path()
    i = math.ceil(xr0)
    while i <= xr1:
        x = ox + i * gs
        ctx.move_to(x, wy0)
        ctx.line_to(x, wy1)
        i += 1
    if not number_line:
        j = math.ceil(yr0)
        while j <= yr1:
            y = oy - j * gs
            ctx.move_to(wx0, y)
            ctx.line_to(wx1, y)
            j += 1
    ctx.stroke()
    # Axes.
    _set_color(ctx, style.color, style.opacity)
    ctx.set_line_width(max(1.0, float(style.stroke_width)))
    ctx.new_path()
    ctx.move_to(wx0, oy)
    ctx.line_to(wx1, oy)
    if not number_line:
        ctx.move_to(ox, wy0)
        ctx.line_to(ox, wy1)
    ctx.stroke()
    # Ticks.
    tick = 8.0
    ctx.set_line_width(1.2)
    ctx.new_path()
    i = math.ceil(xr0)
    while i <= xr1:
        x = ox + i * gs
        ctx.move_to(x, oy)
        ctx.line_to(x, oy + tick)
        i += 1
    if not number_line:
        j = math.ceil(yr0)
        while j <= yr1:
            y = oy - j * gs
            ctx.move_to(ox, y)
            ctx.line_to(ox - tick, y)
            j += 1
    ctx.stroke()
    # Toy-API text labels.
    if show_labels:
        ctx.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        ctx.set_font_size(_LABEL_FONT)
        i = math.ceil(xr0)
        while i <= xr1:
            label = f"{float(i):g}"
            ext = ctx.text_extents(label)
            x = ox + i * gs
            ctx.move_to(x - ext.width / 2.0, oy + tick + ext.height + 4.0)
            ctx.show_text(label)
            i += 1
        if not number_line:
            j = math.ceil(yr0)
            while j <= yr1:
                label = f"{float(j):g}"
                ext = ctx.text_extents(label)
                y = oy - j * gs
                ctx.move_to(ox - tick - 6.0 - ext.width, y + ext.height / 3.0)
                ctx.show_text(label)
                j += 1


def _draw_image(ctx: cairo.Context, node: CanvasNode, assets_root: Path) -> None:
    ref = node.geometry.asset_ref
    if not ref:
        return
    candidates = (assets_root / ref, assets_root / Path(ref).name, assets_root.parent / ref)
    path = next((c for c in candidates if c.is_file()), None)
    if path is None:
        return  # missing asset ⇒ skip node (Doc 14 §5 step 7)
    try:
        surface = cairo.ImageSurface.create_from_png(str(path))
    except cairo.Error:
        return
    bx0, by0, bx1, by1 = (float(v) for v in node.bbox)
    w, h = bx1 - bx0, by1 - by0
    if w <= 0 or h <= 0:
        ctx.set_source_surface(surface, bx0, by0)
        ctx.paint()
        return
    ctx.save()
    ctx.translate(bx0, by0)
    ctx.scale(w / surface.get_width(), h / surface.get_height())
    ctx.set_source_surface(surface, 0.0, 0.0)
    ctx.paint()
    ctx.restore()


def _draw_node(ctx: cairo.Context, node: CanvasNode, assets_root: Path) -> None:
    kind = node.kind
    if kind in ("STROKE", "HIGHLIGHT", "LINE"):
        _draw_stroke(ctx, node, kind)
    elif kind == "SHAPE":
        _draw_shape(ctx, node)
    elif kind == "GRAPH_AXES":
        _draw_graph(ctx, node)
    elif kind == "IMAGE":
        _draw_image(ctx, node, assets_root)


class _Throttle:
    """Gate ``progress(fraction)`` to ≤10 Hz; ``finish`` always sends 1.0."""

    def __init__(self, callback: Callable[[float], None] | None) -> None:
        self._callback = callback
        self._last = -math.inf

    def maybe(self, fraction: float) -> None:
        if self._callback is None:
            return
        now = monotonic()
        if now - self._last >= _PROGRESS_INTERVAL_S:
            self._last = now
            self._callback(min(1.0, max(0.0, fraction)))

    def finish(self) -> None:
        if self._callback is not None:
            self._callback(1.0)


class VectorPdfExporter:
    """Doc 14 frozen interface: pycairo PDFSurface vector exporter."""

    def __init__(self, config: AppConfig) -> None:
        self._config = config

    def export(
        self,
        doc: CanvasDocument,
        out_path: Path,
        progress: Callable[[float], None] | None = None,
    ) -> Path:
        out_path = Path(out_path)
        extent = _page_extent(doc)  # raises ValueError("empty canvas")
        w_u = extent[2] - extent[0]
        h_u = extent[3] - extent[1]
        w_pt, h_pt = page_size_pt(doc)
        tiles = _tile_pages(w_pt, h_pt)
        nx = max(1, math.ceil(w_pt / PAGE_PT_LIMIT))
        ny = max(1, math.ceil(h_pt / PAGE_PT_LIMIT))
        tile_w_u = w_u / nx
        tile_h_u = h_u / ny
        out_path.parent.mkdir(parents=True, exist_ok=True)
        part = _part_path(out_path)
        artboard = doc.artboard
        bounded = not artboard_is_infinite(artboard)
        board_w = float(artboard.width or 0.0)
        board_h = float(artboard.height or 0.0)
        elements = sorted(doc.elements, key=lambda n: n.layer)
        assets_root = self._config.assets_dir / doc.canvas_id
        throttle = _Throttle(progress)
        surface = cairo.PDFSurface(str(part), tile_w_u * UNIT_TO_PT, tile_h_u * UNIT_TO_PT)
        ctx = cairo.Context(surface)
        try:
            n_tiles = len(tiles)
            for tile_index, (_idx, _count, off_x, off_y) in enumerate(tiles):
                ox = extent[0] + off_x
                oy = extent[1] + off_y
                tile_rect = (ox, oy, ox + tile_w_u, oy + tile_h_u)
                ctx.save()
                ctx.identity_matrix()
                ctx.scale(UNIT_TO_PT, UNIT_TO_PT)
                _draw_background(ctx, artboard, tile_w_u, tile_h_u)
                # User space = absolute world: page shows [origin, origin+tile].
                ctx.translate(-ox, -oy)
                page_nodes = [n for n in elements if _intersects(n.bbox, tile_rect)]
                n_nodes = len(page_nodes)
                for i, node in enumerate(page_nodes):
                    _draw_node(ctx, node, assets_root)
                    throttle.maybe((tile_index + (i + 1) / max(1, n_nodes)) / n_tiles)
                if bounded:
                    # Artboard boundary line, on top of the content (Doc 14 §6).
                    ctx.set_source_rgba(0.25, 0.25, 0.3, 1.0)
                    ctx.set_line_width(1.5)
                    ctx.rectangle(0.0, 0.0, board_w, board_h)
                    ctx.stroke()
                ctx.restore()
                ctx.show_page()
            throttle.finish()
            surface.finish()
            part.replace(out_path)
            return out_path
        finally:
            surface.finish()
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass
