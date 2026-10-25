"""Tiled high-resolution raster exporter (Doc 13).

Renders bounded or INFINITE canvases to PNG/JPG at 300 / 600 / 1200 DPI as a
row-major grid of ``2048x2048`` px pycairo strips written straight into a
disk-backed ``np.memmap`` RGBA buffer, then encodes exactly once with PIL.

RAM gate (Doc 13 §5 step 8): the resident set is ≈ one 2048x2048 ARGB32
surface + the memmap's OS page cache + the PIL row encoder; a full-canvas
RGBA Python copy is never materialised.  A JPG canvas whose longest side
exceeds 65535 px must use PNG (this module) or the vector PDF exporter
(Doc 14).

Stroke ``geometry.pts`` layouts (cross-doc contract, Doc 21): Bézier chains
``[P0, c1, c2, P1, c3, c4, P2, …]`` render as exact cubic segments; anything
else is treated as a plain anchor polyline and sampled with the local
Catmull-Rom sampler (intentional duplicate of Doc 07 spline math — avoids GL
dependencies).
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Callable
from uuid import uuid4

import cairo
import numpy as np
from PIL import Image

from pc_agent.core.config_manager import AppConfig
from pc_agent.engine.document_store import Artboard, CanvasDocument, artboard_is_infinite
from pc_agent.engine.scene_graph import CanvasNode
from pc_agent.export.cairo_shapes import apply_fill, apply_stroke_fill, trace_shape

#: Export strip size in px (template §3 "Export strips").
STRIP_PX: int = 2048
#: Allowed raster DPI choices (template §3; PDF is vector).
SUPPORTED_DPIS: frozenset[int] = frozenset({300, 600, 1200})
#: JPEG cannot store a dimension beyond this; advise PNG / Doc 14 instead.
JPG_MAX_PX: int = 65535
#: INFINITE canvases are padded by this many world units per side (Doc 13 §4).
_EXTENT_PAD: float = 64.0
#: Background pattern pitch in world units (local duplication of Doc 08 math).
_GRID_SPACING: float = 32.0
_GRID_LINE_W: float = 1.0
_GRID_RGB: tuple[float, float, float] = (0.78, 0.78, 0.80)
_DOT_RGB: tuple[float, float, float] = (0.62, 0.62, 0.66)
_DOT_RADIUS: float = 1.5
#: Graph label font size in world units (~7 pt at 300 DPI).
_LABEL_FONT: float = 24.0
#: Catmull-Rom tension τ = 0.5 → control offset τ/3 = 1/6 (Doc 07 §4).
_CATMULL_K: float = 1.0 / 6.0


def _part_path(out_path: Path) -> Path:
    """``.part`` temp sibling of ``out_path`` (inside ``config.export_dir``)."""
    return out_path.parent / f".{out_path.stem}.{uuid4().hex}.part"


def resolve_extent(doc: CanvasDocument) -> tuple[float, float, float, float]:
    """Frozen extent policy (Doc 13 §4).

    Bounded ⇒ ``(0, 0, w, h)``; INFINITE ⇒ ``content_bounds`` padded 64 world
    units per side; empty / degenerate ⇒ ``ValueError("empty canvas")``.

    §10.4 (issue 06): boundedness comes from the preset table
    (:func:`artboard_is_infinite`) — an extent resolving to content size for a
    bounded preset is a bug, whatever the ``is_infinite`` flag says.
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


def extent_to_px(extent: tuple[float, float, float, float], dpi: int) -> tuple[int, int]:
    """EXACT output pixel size: ``ceil(world * dpi / 300)``.

    Round-11 issue 05 — this used to round BOTH axes up to the next 2048
    multiple, so an A4 canvas (2480×3508 world units) exported as 4096×4096:
    the aspect ratio was destroyed and every A4 PNG came out square. The 2048
    strip grid is a renderer detail, not a property of the delivered file; the
    memmap is allocated at exactly this size and edge strips are clipped.
    """
    if dpi not in SUPPORTED_DPIS:
        raise ValueError(f"unsupported dpi {dpi!r}; expected one of {sorted(SUPPORTED_DPIS)}")
    min_x, min_y, max_x, max_y = extent
    px_w = max(1, math.ceil((max_x - min_x) * dpi / 300.0))
    px_h = max(1, math.ceil((max_y - min_y) * dpi / 300.0))
    return px_w, px_h


def _is_cubic_chain(pts: list[list[float]]) -> bool:
    """True for Doc 21 Bézier chains ``[P0, c1, c2, P1, c3, c4, P2, …]``.

    Doc 21 emits ``n = 3k − 2`` points for ``k`` anchors, i.e. ``n ≡ 1 (mod 3)``
    ⇒ ``(n − 1) % 3 == 0``; the frozen cross-doc contract additionally accepts
    ``(n − 2) % 3 == 0``.  Anything else (``n ≤ 3`` or ``n ≡ 0 (mod 3)``) is a
    plain anchor polyline for the local Catmull-Rom sampler.
    """
    n = len(pts)
    return n >= 4 and ((n - 1) % 3 == 0 or (n - 2) % 3 == 0)


def _cubic_point(
    p0: tuple[float, float],
    c1: tuple[float, float],
    c2: tuple[float, float],
    p1: tuple[float, float],
    t: float,
) -> tuple[float, float]:
    mt = 1.0 - t
    a = mt * mt * mt
    b = 3.0 * mt * mt * t
    c = 3.0 * mt * t * t
    d = t * t * t
    x = a * p0[0] + b * c1[0] + c * c2[0] + d * p1[0]
    y = a * p0[1] + b * c1[1] + c * c2[1] + d * p1[1]
    return (x, y)


def _catmull_rom_sample(pts: list[list[float]], steps: int = 8) -> list[tuple[float, float]]:
    """Local Catmull-Rom (τ = 0.5) sampler — duplicate of Doc 07 spline math.

    Endpoints are clamped by duplicating the terminal anchors.  Returns the
    sampled polyline including the original anchors (n ≥ 2), the single anchor
    or an empty list for degenerate inputs.
    """
    anchors = [(float(p[0]), float(p[1])) for p in pts]
    n = len(anchors)
    if n == 0:
        return []
    if n == 1:
        return [anchors[0]]
    out: list[tuple[float, float]] = [anchors[0]]
    for i in range(n - 1):
        p1 = anchors[i]
        p2 = anchors[i + 1]
        p0 = anchors[i - 1] if i > 0 else p1
        p3 = anchors[i + 2] if i + 2 < n else p2
        c1 = (p1[0] + (p2[0] - p0[0]) * _CATMULL_K, p1[1] + (p2[1] - p0[1]) * _CATMULL_K)
        c2 = (p2[0] - (p3[0] - p1[0]) * _CATMULL_K, p2[1] - (p3[1] - p1[1]) * _CATMULL_K)
        for s in range(1, steps + 1):
            out.append(_cubic_point(p1, c1, c2, p2, s / steps))
    return out


def _trace_path(ctx: cairo.Context, pts: list[list[float]]) -> bool:
    """Build the stroke path on ``ctx`` for either ``pts`` layout.

    Exact cubic chain when :func:`_is_cubic_chain` holds (``moveTo P0`` then
    ``curveTo (c1, c2, P1)`` per triple, trailing point connected by a line);
    otherwise the local Catmull-Rom sampler polyline.  Returns ``False`` when
    there is nothing to draw.
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
    poly = _catmull_rom_sample(pts)
    ctx.move_to(poly[0][0], poly[0][1])
    for x, y in poly[1:]:
        ctx.line_to(x, y)
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
    that still carry them are normalised to ``BLANK`` by
    ``DocumentStore`` on load, so they never reach this function.
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


def _draw_background(ctx: cairo.Context, artboard: Artboard, strip_world: tuple) -> None:
    """Fill ``background_color`` + grid pattern over the strip world rect."""
    x0, y0, x1, y1 = (float(v) for v in strip_world)
    _set_color(ctx, artboard.background_color, 1.0)
    ctx.rectangle(x0, y0, x1 - x0, y1 - y0)
    ctx.fill()
    _paint_pattern(
        ctx,
        artboard.background_style,
        (x0, y0, x1, y1),
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
    # Round-9 issues 04/05/06 — interior fill (paint bucket), rotated PATHs and
    # TABLE grids all come from the shared cairo helper so this exporter cannot
    # drift from the viewport or the other two exporters.
    apply_fill(ctx, style, shape, box, node.geometry.pts, node.geometry.graph_config)
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
        return  # missing asset ⇒ skip node (Doc 13 §4)
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


def _blit_strip(buf: np.memmap, surface: cairo.ImageSurface, sx: int, sy: int) -> None:
    """Copy one rendered strip into the disk-backed RGBA canvas (O(strip)).

    Round-11 issue 05 — the buffer is the EXACT canvas size, so the final row
    and column strips are clipped to whatever remains instead of the image
    being padded up to a 2048 multiple on both axes.
    """
    stride = surface.get_stride()
    data = np.frombuffer(surface.get_data(), np.uint8)
    if stride == STRIP_PX * 4:
        view = data.reshape(STRIP_PX, STRIP_PX, 4)
    else:
        view = data.reshape(STRIP_PX, stride)[:, : STRIP_PX * 4].reshape(STRIP_PX, STRIP_PX, 4)
    buf_h, buf_w = buf.shape[0], buf.shape[1]
    y0, x0 = sy * STRIP_PX, sx * STRIP_PX
    h, w = min(STRIP_PX, buf_h - y0), min(STRIP_PX, buf_w - x0)
    if h > 0 and w > 0:
        buf[y0 : y0 + h, x0 : x0 + w] = view[:h, :w]


class TiledRasterExporter:
    """Doc 13 frozen interface: tiled strip renderer → memmap → PIL encode."""

    def __init__(self, config: AppConfig) -> None:
        self._config = config

    def export(
        self,
        doc: CanvasDocument,
        dpi: int,
        out_path: Path,
        progress: Callable[[float], None] | None = None,
    ) -> Path:
        out_path = Path(out_path)
        if dpi not in SUPPORTED_DPIS:
            raise ValueError(f"unsupported dpi {dpi!r}; expected one of {sorted(SUPPORTED_DPIS)}")
        extent = resolve_extent(doc)  # raises ValueError("empty canvas")
        canvas_w, canvas_h = extent_to_px(extent, dpi)
        is_jpg = out_path.suffix.lower() in (".jpg", ".jpeg")
        if is_jpg and max(canvas_w, canvas_h) > JPG_MAX_PX:
            raise ValueError(
                f"JPG canvas dimension {max(canvas_w, canvas_h)} px exceeds the "
                f"{JPG_MAX_PX} px JPEG limit; use PNG or the vector PDF exporter (Doc 14)"
            )
        out_path.parent.mkdir(parents=True, exist_ok=True)
        part = _part_path(out_path)
        min_x, min_y, _, _ = extent
        world_per_strip = STRIP_PX * 300.0 / dpi
        strips_x = math.ceil(canvas_w / STRIP_PX)
        strips_y = math.ceil(canvas_h / STRIP_PX)
        total_strips = strips_x * strips_y
        assets_root = self._config.assets_dir / doc.canvas_id
        elements = sorted(doc.elements, key=lambda n: n.layer)
        buf: np.memmap | None = None
        try:
            buf = np.memmap(part, dtype=np.uint8, mode="w+", shape=(canvas_h, canvas_w, 4))
            done = 0
            for sy in range(strips_y):
                wy0 = min_y + sy * world_per_strip
                for sx in range(strips_x):
                    wx0 = min_x + sx * world_per_strip
                    strip_rect = (wx0, wy0, wx0 + world_per_strip, wy0 + world_per_strip)
                    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, STRIP_PX, STRIP_PX)
                    ctx = cairo.Context(surface)
                    # User space = absolute world: px = (world − origin) * dpi/300.
                    ctx.scale(dpi / 300.0, dpi / 300.0)
                    ctx.translate(-wx0, -wy0)
                    _draw_background(ctx, doc.artboard, strip_rect)
                    for node in elements:
                        if _intersects(node.bbox, strip_rect):
                            _draw_node(ctx, node, assets_root)
                    surface.flush()
                    _blit_strip(buf, surface, sx, sy)
                    done += 1
                    if progress is not None:
                        progress(done / total_strips)
                    del ctx, surface
            buf.flush()
            img = Image.frombuffer("RGBA", (canvas_w, canvas_h), buf, "raw", "BGRA", 0, 1)
            try:
                if is_jpg:
                    img.convert("RGB").save(out_path, "JPEG")
                else:
                    img.save(out_path, "PNG")
            finally:
                del img
            return out_path
        finally:
            if buf is not None:
                buf.flush()
                del buf
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass
