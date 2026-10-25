"""PC thumbnail renderer (Doc 02 §10.6) — gallery mini-renders.

Frozen contract: ``render_thumbnail(doc, out_path, size=192) -> Path`` renders
a PNG no larger than 192² px (typical render ≪ 200 ms), creating parent
directories on demand.  The look mirrors the pre-seeded mobile renderer: a
neutral backdrop, a white paper rect + light border for bounded artboards, and
elements drawn through small local helpers that mirror the normative §10.3
conventions (``viewport/primitive_renderer.py`` + ``export/tiled_raster_
exporter.py``):

* Bézier chains are traced as EXACT cubics when ``n >= 4 and (n-1) % 3 == 0``
  (Doc 21 layout ``[P0, c1, c2, P1, …]``); anything else is a plain anchor
  polyline — chains are never re-fitted as anchors.
* Strokes/HIGHLIGHTS honour colour/opacity/blend (multiply), with the line
  width floored at ``max(1 px, stroke_width * scale)``.
* Shapes (RECT/CIRCLE/TRIANGLE/ARROW) and graphs (CARTESIAN_2D/NUMBER_LINE)
  follow the exporter's geometry; graph labels are omitted (thumbnails may
  approximate — §10.3).  Images resolve through the Doc 10 assets layout and
  degrade to a neutral placeholder when missing/undecodable.

The view rect is the artboard for bounded presets (§10.4 preset table wins —
a stale ``is_infinite`` flag never drops a bounded page onto content bounds)
and ``content_bounds`` (empty ⇒ §10.5 fallback) for INFINITE.  Preset badges
are UI overlays and are never baked into the image (§10.6).  Missing or
malformed elements are skipped — only I/O errors propagate.
"""

from __future__ import annotations

import logging
import math
import os
from pathlib import Path

import cairo

from pc_agent.engine.document_store import (
    CanvasDocument,
    DocumentStore,
    artboard_is_infinite,
)
from pc_agent.engine.scene_graph import CanvasNode
from pc_agent.export.cairo_shapes import apply_fill, apply_stroke_fill, trace_shape

logger = logging.getLogger("slatesync.thumbnail")

#: §10.6 frozen default AND maximum thumbnail edge (px).
MAX_SIZE: int = 192
#: Letterbox inset mirroring the mobile renderer's ``(size - 8)`` fit.
_MARGIN_PX: float = 8.0
#: Neutral backdrop (mobile parity: 0xFFECEEF2).
_BG_RGB: tuple[float, float, float] = (0xEC / 255.0, 0xEE / 255.0, 0xF2 / 255.0)
#: Paper border (mobile parity: 0xFFC9CFDA).
_BORDER_RGB: tuple[float, float, float] = (0xC9 / 255.0, 0xCF / 255.0, 0xDA / 255.0)
#: Missing/undecodable image placeholder (mobile parity: 0xFFB9C2CF).
_PLACEHOLDER_RGB: tuple[float, float, float] = (0xB9 / 255.0, 0xC2 / 255.0, 0xCF / 255.0)
#: Light grid strokes for graph backgrounds (local Doc 08 math).
_GRID_RGB: tuple[float, float, float] = (0.78, 0.78, 0.80)
#: §10.5 view fallback when neither artboard nor content bounds are usable.
_FALLBACK_VIEW: tuple[float, float, float, float] = (-500.0, -500.0, 500.0, 500.0)
#: Graph line-count guard (mirrors the viewport's MAX_GRAPH_TICKS spirit).
_MAX_GRAPH_LINES = 4096


def render_thumbnail(doc, out_path: Path, size: int = 192) -> Path:
    """§10.6 frozen signature — render ``doc`` to a ≤192² PNG at ``out_path``.

    ``doc`` is a :class:`CanvasDocument` (or a Doc 03 wire dict, which is
    parsed first).  Parent directories are created; the path is returned.
    """
    document = _as_document(doc)
    out_path = Path(out_path)
    size = max(1, min(int(size), MAX_SIZE))
    out_path.parent.mkdir(parents=True, exist_ok=True)

    view = _thumb_view(document)
    scale, dx, dy = _fit(view, size)
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    ctx = cairo.Context(surface)

    ctx.set_source_rgb(*_BG_RGB)
    ctx.paint()

    ctx.save()
    ctx.translate(dx, dy)
    ctx.scale(scale, scale)
    ctx.translate(-view[0], -view[1])
    _draw_paper(ctx, document.artboard, view, scale)
    assets_root = _assets_root(document.canvas_id)
    for node in sorted(document.elements, key=lambda n: n.layer):
        try:
            _draw_node(ctx, node, assets_root, scale)
        except Exception:  # noqa: BLE001 — one bad element must not kill the gallery
            logger.debug("thumbnail skipped node %r", getattr(node, "node_id", "?"),
                         exc_info=True)
    ctx.restore()

    surface.write_to_png(str(out_path))
    return out_path


# ---------------------------------------------------------------------------
# Document / view helpers
# ---------------------------------------------------------------------------
def _as_document(doc: object) -> CanvasDocument:
    """Accept a :class:`CanvasDocument` or a Doc 03 dict (wire payloads).

    Best-effort rows (the gallery's no-archive fallback carries only
    ``canvas_id/title/artboard{preset,is_infinite}/elements``) are widened into
    a full document so the thumbnail still renders instead of degrading to the
    caller's placeholder box.
    """
    if isinstance(doc, CanvasDocument):
        return doc
    if isinstance(doc, dict):
        try:
            return DocumentStore.parse_document(doc)
        except (ValueError, TypeError, KeyError):
            return _best_effort_document(doc)
    raise TypeError(f"render_thumbnail() needs a CanvasDocument, got {type(doc).__name__}")


def _best_effort_document(data: dict) -> CanvasDocument:
    """Doc 03 body assembled from a partial dict, then parsed normally.

    Missing timestamps/elements default; the artboard keeps whatever preset
    metadata exists (``_artboard_from_json`` backfills known presets — §10.4),
    so an ``A4`` row still renders its paper rect.
    """
    artboard = dict(data.get("artboard") or {})
    if "preset" not in artboard:
        artboard["preset"] = str(data.get("preset") or "INFINITE")
    artboard.setdefault("is_infinite", str(artboard["preset"]).upper() == "INFINITE")
    bounds = data.get("content_bounds")
    if not isinstance(bounds, dict):
        bounds = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
    body = {
        "canvas_id": str(data.get("canvas_id") or data.get("id") or ""),
        "title": str(data.get("title") or ""),
        "created_at": int(data.get("created_at") or 0),
        "updated_at": int(data.get("updated_at") or 0),
        "artboard": artboard,
        "content_bounds": bounds,
        "elements": list(data.get("elements") or []),
    }
    return DocumentStore.parse_document(body)


def _thumb_view(doc: CanvasDocument) -> tuple[float, float, float, float]:
    """World rect the thumbnail fits: bounded ⇒ artboard; else content/fallback.

    §10.4: bounded presets use the exact artboard rect whenever its dims are
    usable — the ``is_infinite`` flag never redirects a bounded page.
    """
    artboard = doc.artboard
    if not artboard_is_infinite(artboard):
        w = float(artboard.width) if artboard.width is not None else 0.0
        h = float(artboard.height) if artboard.height is not None else 0.0
        if math.isfinite(w) and math.isfinite(h) and w > 0.0 and h > 0.0:
            return (0.0, 0.0, w, h)
    bounds = doc.content_bounds or {}
    try:
        min_x = float(bounds["min_x"])
        min_y = float(bounds["min_y"])
        max_x = float(bounds["max_x"])
        max_y = float(bounds["max_y"])
    except (KeyError, TypeError, ValueError):
        return _FALLBACK_VIEW
    corners = (min_x, min_y, max_x, max_y)
    if all(math.isfinite(v) for v in corners) and max_x > min_x and max_y > min_y:
        return (min_x, min_y, max_x, max_y)
    return _FALLBACK_VIEW


def _fit(
    view: tuple[float, float, float, float], size: int
) -> tuple[float, float, float]:
    """``(scale, dx, dy)``: fit ``view`` into ``size``² with the §10.6 margin."""
    x0, y0, x1, y1 = view
    span = max(x1 - x0, y1 - y0)
    if not math.isfinite(span) or span <= 0.0:
        span = 1.0
    scale = (size - _MARGIN_PX) / span
    if not math.isfinite(scale) or scale <= 0.0:
        scale = size / span
    dx = (size - (x1 - x0) * scale) / 2.0
    dy = (size - (y1 - y0) * scale) / 2.0
    return scale, dx, dy


def _map_point(
    view: tuple[float, float, float, float], size: int, x: float, y: float
) -> tuple[float, float]:
    """World → thumbnail px (test/containment helper mirroring ``_fit``)."""
    scale, dx, dy = _fit(view, size)
    return (dx + (x - view[0]) * scale, dy + (y - view[1]) * scale)


def _assets_root(canvas_id: str) -> Path:
    """Doc 10 default assets layout (``%APPDATA%/SlateSync/assets/<id>``)."""
    root = Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "assets"
    return root / str(canvas_id)


# ---------------------------------------------------------------------------
# Path / paint helpers (§10.3 conventions, thumbnail variants)
# ---------------------------------------------------------------------------
def _is_chain(pts: list) -> bool:
    """Doc 21 chain layout: ``n >= 4`` and ``(n - 1) % 3 == 0`` (§10.6/§10.3)."""
    n = len(pts)
    return n >= 4 and (n - 1) % 3 == 0


def _finite_pts(pts: list) -> list[tuple[float, float]] | None:
    """Valid world anchors, or None when nothing drawable survives."""
    out: list[tuple[float, float]] = []
    for p in pts or []:
        try:
            x, y = float(p[0]), float(p[1])
        except (TypeError, ValueError, IndexError, KeyError):
            return None
        if not (math.isfinite(x) and math.isfinite(y)):
            return None
        out.append((x, y))
    return out or None


def _trace_path(ctx: cairo.Context, pts: list) -> bool:
    """Build the stroke path: exact cubics for chains, anchor polyline otherwise.

    Chains are NEVER re-fitted as anchors — each triple becomes one exact
    ``curve_to`` (trailing point, if any, a straight ``line_to``).
    """
    coords = _finite_pts(pts)
    if coords is None or len(coords) < 2:
        return False
    ctx.new_path()
    if _is_chain(coords):
        ctx.move_to(*coords[0])
        i = 1
        while i + 2 < len(coords):
            ctx.curve_to(*coords[i], *coords[i + 1], *coords[i + 2])
            i += 3
        if i < len(coords):
            ctx.line_to(*coords[i])
    else:
        ctx.move_to(*coords[0])
        for pt in coords[1:]:
            ctx.line_to(*pt)
    return True


def _set_color(ctx: cairo.Context, color: str, alpha: float = 1.0) -> None:
    """``#RRGGBB``/``#RGB`` hex → (possibly alpha) cairo source; garbage → black."""
    raw = str(color or "#000000").lstrip("#")
    if len(raw) == 3:
        raw = "".join(ch * 2 for ch in raw)
    try:
        r = int(raw[0:2], 16) / 255.0
        g = int(raw[2:4], 16) / 255.0
        b = int(raw[4:6], 16) / 255.0
    except (ValueError, IndexError):
        r = g = b = 0.0
    ctx.set_source_rgba(r, g, b, max(0.0, min(1.0, float(alpha))))


def _line_w(scale: float, world_w: float) -> float:
    """World line width yielding ``max(1 px, stroke_width * scale)`` on screen."""
    return max(1.0 / scale, float(world_w))


# ---------------------------------------------------------------------------
# Element drawing
# ---------------------------------------------------------------------------
def _draw_paper(ctx: cairo.Context, artboard, view: tuple[float, float, float, float],
                scale: float) -> None:
    """White paper + 1 px light border for bounded presets (§10.6)."""
    if artboard_is_infinite(artboard):
        return
    w = float(artboard.width) if artboard.width is not None else 0.0
    h = float(artboard.height) if artboard.height is not None else 0.0
    if not (math.isfinite(w) and math.isfinite(h)) or w <= 0.0 or h <= 0.0:
        return
    if (view[0], view[1], view[2], view[3]) != (0.0, 0.0, w, h):
        return  # view fell back to content: nothing to frame
    ctx.set_source_rgb(1.0, 1.0, 1.0)
    ctx.rectangle(0.0, 0.0, w, h)
    ctx.fill()
    ctx.set_source_rgb(*_BORDER_RGB)
    ctx.set_line_width(1.0 / scale)
    ctx.rectangle(0.0, 0.0, w, h)
    ctx.stroke()


def _draw_stroke(ctx: cairo.Context, node: CanvasNode, kind: str, scale: float) -> None:
    pts = node.geometry.pts or []
    if not pts:
        return
    style = node.style
    lw = _line_w(scale, style.stroke_width)
    multiply = kind == "HIGHLIGHT" or style.blend_mode == "MULTIPLY"
    if multiply:
        ctx.set_operator(cairo.OPERATOR_MULTIPLY)
    try:
        # Round-11 issue 04 — interior of a closed pen loop, under the ink.
        apply_stroke_fill(ctx, node)
        _set_color(ctx, style.color, style.opacity)
        ctx.set_line_width(lw)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        coords = _finite_pts(pts)
        if coords is None:
            return
        if len(coords) == 1:
            x, y = coords[0]
            ctx.arc(x, y, lw / 2.0, 0.0, math.tau)
            ctx.fill()
        elif kind == "LINE" and len(coords) >= 2:
            ctx.move_to(*coords[0])
            ctx.line_to(*coords[-1])
            ctx.stroke()
        elif _trace_path(ctx, coords):
            ctx.stroke()
    finally:
        if multiply:
            ctx.set_operator(cairo.OPERATOR_OVER)


def _draw_shape(ctx: cairo.Context, node: CanvasNode, scale: float) -> None:
    shape = node.geometry.shape_type
    if shape in ("CARTESIAN_2D", "NUMBER_LINE"):
        _draw_graph(ctx, node, scale)
        return
    style = node.style
    bx0, by0, bx1, by1 = (float(v) for v in node.bbox)
    if bx1 < bx0:
        bx0, bx1 = bx1, bx0
    if by1 < by0:
        by0, by1 = by1, by0
    box = (bx0, by0, bx1, by1)
    # Round-9 issues 04/05/06 — shared with the raster/PDF exporters so the
    # thumbnail cannot drift (fill, rotated PATH, TABLE grid).
    apply_fill(ctx, style, shape, box, node.geometry.pts, node.geometry.graph_config)
    _set_color(ctx, style.color, style.opacity)
    ctx.set_line_width(_line_w(scale, style.stroke_width))
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    ctx.new_path()
    trace_shape(ctx, node, box, shape)
    ctx.stroke()


def _draw_graph(ctx: cairo.Context, node: CanvasNode, scale: float) -> None:
    """CARTESIAN_2D / NUMBER_LINE grid + axes from ``graph_config`` (§10.3).

    Label text is omitted — thumbnails may approximate (§10.3/§10.6).
    """
    cfg = node.geometry.graph_config or {}
    style = node.style
    try:
        origin = cfg.get("origin") or [0.0, 0.0]
        ox, oy = float(origin[0]), float(origin[1])
    except (TypeError, ValueError, IndexError):
        ox, oy = 0.0, 0.0
    try:
        xr0, xr1 = (float(v) for v in (cfg.get("x_range") or [-10.0, 10.0]))
        yr0, yr1 = (float(v) for v in (cfg.get("y_range") or [-10.0, 10.0]))
    except (TypeError, ValueError, IndexError):
        xr0, xr1, yr0, yr1 = -10.0, 10.0, -10.0, 10.0
    if xr1 < xr0:
        xr0, xr1 = xr1, xr0
    if yr1 < yr0:
        yr0, yr1 = yr1, yr0
    gs = float(cfg.get("grid_step") or 25.0)
    if not math.isfinite(gs) or gs <= 0.0:
        gs = 25.0
    number_line = node.geometry.shape_type == "NUMBER_LINE"
    wx0, wx1 = ox + xr0 * gs, ox + xr1 * gs
    wy0, wy1 = oy - yr1 * gs, oy - yr0 * gs  # data y is up; world y is down.

    ctx.set_source_rgb(*_GRID_RGB)
    ctx.set_line_width(_line_w(scale, 1.0))
    ctx.new_path()
    i = math.ceil(xr0)
    steps = 0
    while i <= xr1 and steps < _MAX_GRAPH_LINES:
        x = ox + i * gs
        ctx.move_to(x, wy0)
        ctx.line_to(x, wy1)
        i += 1
        steps += 1
    if not number_line:
        j = math.ceil(yr0)
        steps = 0
        while j <= yr1 and steps < _MAX_GRAPH_LINES:
            y = oy - j * gs
            ctx.move_to(wx0, y)
            ctx.line_to(wx1, y)
            j += 1
            steps += 1
    ctx.stroke()

    _set_color(ctx, style.color, style.opacity)
    ctx.set_line_width(_line_w(scale, style.stroke_width))
    ctx.new_path()
    ctx.move_to(wx0, oy)
    ctx.line_to(wx1, oy)
    if not number_line:
        ctx.move_to(ox, wy0)
        ctx.line_to(ox, wy1)
    ctx.stroke()

    tick = 8.0
    ctx.set_line_width(_line_w(scale, 1.2))
    ctx.new_path()
    i = math.ceil(xr0)
    steps = 0
    while i <= xr1 and steps < _MAX_GRAPH_LINES:
        x = ox + i * gs
        ctx.move_to(x, oy)
        ctx.line_to(x, oy + tick)
        i += 1
        steps += 1
    if not number_line:
        j = math.ceil(yr0)
        steps = 0
        while j <= yr1 and steps < _MAX_GRAPH_LINES:
            y = oy - j * gs
            ctx.move_to(ox, y)
            ctx.line_to(ox - tick, y)
            j += 1
            steps += 1
    ctx.stroke()


def _draw_image(ctx: cairo.Context, node: CanvasNode, assets_root: Path) -> None:
    """PNG asset scaled into the node bbox; missing/undecodable ⇒ placeholder."""
    bx0, by0, bx1, by1 = (float(v) for v in node.bbox)
    w, h = bx1 - bx0, by1 - by0
    ref = node.geometry.asset_ref
    surface = None
    if ref:
        candidates = (assets_root / str(ref), assets_root / Path(str(ref)).name,
                      assets_root.parent / str(ref))
        path = next((c for c in candidates if c.is_file()), None)
        if path is not None:
            try:
                surface = cairo.ImageSurface.create_from_png(str(path))
            except cairo.Error:
                surface = None
    if surface is None:
        if w <= 0.0 or h <= 0.0:
            return
        ctx.set_source_rgb(*_PLACEHOLDER_RGB)
        ctx.rectangle(bx0, by0, w, h)
        ctx.fill()
        return
    if w <= 0.0 or h <= 0.0:
        ctx.set_source_surface(surface, bx0, by0)
        ctx.paint()
        return
    ctx.save()
    ctx.translate(bx0, by0)
    ctx.scale(w / surface.get_width(), h / surface.get_height())
    ctx.set_source_surface(surface, 0.0, 0.0)
    ctx.paint()
    ctx.restore()


def _draw_node(ctx: cairo.Context, node: CanvasNode, assets_root: Path,
               scale: float) -> None:
    kind = node.kind
    if kind in ("STROKE", "HIGHLIGHT", "LINE"):
        _draw_stroke(ctx, node, kind, scale)
    elif kind == "SHAPE":
        _draw_shape(ctx, node, scale)
    elif kind == "GRAPH_AXES":
        _draw_graph(ctx, node, scale)
    elif kind == "IMAGE":
        _draw_image(ctx, node, assets_root)
