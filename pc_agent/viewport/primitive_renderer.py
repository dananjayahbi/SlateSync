"""Doc 08 — PrimitiveRenderer: backgrounds, page chrome, graphs, shapes, images.

Frozen interface (template §4 / Doc 08 §4):

* ``PrimitiveRenderer(ctx, registry)``
* ``render(nodes, camera, artboard, content_bounds)`` — frozen render order
  ``background → (shadow + boundary) → images → shapes → graphs``.
* ``set_assets_root(root)`` — injected ``DocumentStore.assets_dir`` path (Doc 10).

Renders everything except strokes (those are Doc 07). Frustum culling is a plain
AABB test against the template §3 world rect — no engine import at runtime
(only TYPE_CHECKING contract models from Docs 09/10, never engine internals).
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Iterable, Sequence

import moderngl
import numpy as np
from PIL import Image, ImageDraw, ImageFont

if TYPE_CHECKING:  # Doc 09/10/06 contract types only — never imported at runtime
    from pc_agent.engine.document_store import Artboard
    from pc_agent.engine.scene_graph import CanvasNode
    from pc_agent.viewport.gl_canvas_host import ProgramRegistry  # Doc 06

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Frozen constants (template §3 / Doc 08 §4)
# ---------------------------------------------------------------------------

ZOOM_MIN = 0.05
ZOOM_MAX = 20.0
RULED_SPACING = 32.0            # RULED: line every 32 world units
GRID_SPACING = 24.0             # DOT_GRID / ISO_GRID lattice spacing
DOT_RADIUS = 0.45 * GRID_SPACING  # ≈ 10.8 world units
ISO_SQRT3 = math.sqrt(3.0)      # tan(60°) — line families at ±60°
ISO_PERIOD = 2.0 * GRID_SPACING  # projection period ⇒ 24 u perpendicular spacing

GLYPH_CHARS = "0123456789-+."
GLYPH_CELL_W, GLYPH_CELL_H = 16, 32
GLYPH_COLS, GLYPH_ROWS = 8, 2
GLYPH_SHEET_SIZE = (GLYPH_COLS * GLYPH_CELL_W, GLYPH_ROWS * GLYPH_CELL_H)  # 128 × 64

CIRCLE_SEGMENTS = 64
SHADOW_OFFSET_FRACTION = 0.02   # shadow offset ≈ 0.02·min(w, h)
SHADOW_FEATHER_FACTOR = 3.0     # feather width ≈ 3× offset
ARROW_HEAD_FRACTION = 0.25      # head length = 0.25·shaft length
ARROW_HEAD_HALF_WIDTH = 3.0     # head half-width = 3× style.stroke_width
TICK_FRACTION = 0.35            # tick length = 0.35·grid_step
LABEL_HEIGHT_FRACTION = 0.30    # glyph label height = 0.3·grid_step (world units)
MAX_GRAPH_TICKS = 4096          # degenerate-config guard for huge ranges

_PATTERN_IDS = {"BLANK": 0, "RULED": 1, "DOT_GRID": 2, "ISO_GRID": 3}
_PAGE_BORDER_COLOR = (0.62, 0.63, 0.66, 1.0)
_SHADOW_COLOR = (0.0, 0.0, 0.0, 0.35)
_GL_SCISSOR_TEST = 0x0C11       # GL_SCISSOR_TEST — enable_direct takes raw enums
_SRC_OVER = (moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA)
_MULTIPLY = (moderngl.DST_COLOR, moderngl.ZERO)  # template §3 MULTIPLY blend


# ---------------------------------------------------------------------------
# Camera / culling math (Doc 08 §4 — pure, unit-tested headless)
# ---------------------------------------------------------------------------


def clamp_zoom(scale: float) -> float:
    """Clamp a camera scale to the template §3 zoom range 0.05…20.0."""
    try:
        value = float(scale)
    except (TypeError, ValueError):
        return ZOOM_MIN
    if not math.isfinite(value):
        return ZOOM_MIN
    return max(ZOOM_MIN, min(ZOOM_MAX, value))


def visible_world_rect(
    camera: tuple[float, float, float], viewport_wh: tuple[float, float]
) -> tuple[float, float, float, float]:
    """World rect visible at the viewport corners: half = viewport / (2·scale)."""
    scale, tx, ty = camera
    scale = clamp_zoom(scale)
    half_x = float(viewport_wh[0]) / (2.0 * scale)
    half_y = float(viewport_wh[1]) / (2.0 * scale)
    return (tx - half_x, ty - half_y, tx + half_x, ty + half_y)


def is_visible(
    node_bbox: Sequence[float], world_rect: tuple[float, float, float, float]
) -> bool:
    """AABB intersection — inclusive edges, so touching counts as visible."""
    try:
        x0, y0, x1, y1 = node_bbox
        rx0, ry0, rx1, ry1 = world_rect
    except (TypeError, ValueError):
        return False
    bx0, bx1 = (x0, x1) if x0 <= x1 else (x1, x0)
    by0, by1 = (y0, y1) if y0 <= y1 else (y1, y0)
    return bx0 <= rx1 and bx1 >= rx0 and by0 <= ry1 and by1 >= ry0


def world_to_screen(
    world: tuple[float, float],
    camera: tuple[float, float, float],
    viewport_wh: tuple[float, float],
) -> tuple[float, float]:
    """Template §3: ``screen = (world − camera_center) * scale + viewport/2``."""
    scale, tx, ty = camera
    return (
        (float(world[0]) - tx) * scale + float(viewport_wh[0]) * 0.5,
        (float(world[1]) - ty) * scale + float(viewport_wh[1]) * 0.5,
    )


# ---------------------------------------------------------------------------
# Pattern coordinate math (mirrors grid.frag — Doc 08 §6 pattern tests)
# ---------------------------------------------------------------------------


def _smoothstep(edge0: float, edge1: float, value: float) -> float:
    """GLSL-compatible smoothstep (degenerate edges collapse to a step)."""
    if edge1 <= edge0:
        return 0.0 if value < edge0 else 1.0
    t = (value - edge0) / (edge1 - edge0)
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def ruled_line_distance(world_y: float) -> float:
    """Distance to the nearest RULED line (world_y ≡ 0 mod 32)."""
    y = float(world_y)
    return abs(y - RULED_SPACING * math.floor(y / RULED_SPACING + 0.5))


def ruled_intensity(world_y: float, line_half: float = 0.5, aa: float = 0.25) -> float:
    """0…1 RULED ink coverage (1 ⇒ line fires at this y)."""
    return 1.0 - _smoothstep(line_half - aa, line_half + aa, ruled_line_distance(world_y))


def dot_offset(world_x: float, world_y: float) -> tuple[float, float]:
    """Signed offset to the nearest DOT_GRID lattice point (24i, 24j)."""
    dx = float(world_x) - GRID_SPACING * math.floor(float(world_x) / GRID_SPACING + 0.5)
    dy = float(world_y) - GRID_SPACING * math.floor(float(world_y) / GRID_SPACING + 0.5)
    return (dx, dy)


def dot_distance(world_x: float, world_y: float) -> float:
    """Euclidean distance from (x, y) to the nearest (24i, 24j) lattice point."""
    dx, dy = dot_offset(world_x, world_y)
    return math.hypot(dx, dy)


def dot_intensity(world_x: float, world_y: float, aa: float = 0.25) -> float:
    """0…1 DOT_GRID ink coverage — 1 at lattice points, 0.5 at distance == DOT_RADIUS."""
    distance = dot_distance(world_x, world_y)
    return 1.0 - _smoothstep(DOT_RADIUS - aa, DOT_RADIUS + aa, distance)


def iso_family_distance(projection: float) -> float:
    """Signed perpendicular distance of a ±60° projection to the nearest family line."""
    wrapped = (float(projection) + GRID_SPACING) % ISO_PERIOD - GRID_SPACING
    return wrapped * 0.5


def iso_line_distance(world_x: float, world_y: float) -> float:
    """Distance to the nearest ISO_GRID line (either ±60° family, 24 u spacing)."""
    x, y = float(world_x), float(world_y)
    d1 = abs(iso_family_distance(ISO_SQRT3 * x - y))
    d2 = abs(iso_family_distance(ISO_SQRT3 * x + y))
    return d1 if d1 < d2 else d2


# ---------------------------------------------------------------------------
# Colour / asset helpers
# ---------------------------------------------------------------------------


def parse_color(color: str, opacity: float = 1.0) -> tuple[float, float, float, float]:
    """``#RGB``/``#RRGGBB`` → RGBA floats; unparsable input falls back to black."""
    text = str(color).strip().lstrip("#")
    if len(text) == 3:
        text = "".join(ch * 2 for ch in text)
    if len(text) != 6:
        return (0.0, 0.0, 0.0, _clamp01(opacity))
    try:
        r = int(text[0:2], 16) / 255.0
        g = int(text[2:4], 16) / 255.0
        b = int(text[4:6], 16) / 255.0
    except ValueError:
        return (0.0, 0.0, 0.0, _clamp01(opacity))
    return (r, g, b, _clamp01(opacity))


def _clamp01(value: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 1.0
    return max(0.0, min(1.0, number))


def resolve_asset_path(assets_root: Path | None, asset_ref: str) -> Path:
    """``asset_ref`` (e.g. ``assets/img_9921.png``) → ``assets_root / Path(ref).name``."""
    name = Path(str(asset_ref)).name
    if assets_root is None:
        return Path(name)
    return Path(assets_root) / name


def placeholder_image() -> Image.Image:
    """1×1 magenta RGBA stand-in for missing/unreadable image assets (Doc 08 §4(5))."""
    return Image.new("RGBA", (1, 1), (255, 0, 255, 255))


# ---------------------------------------------------------------------------
# Glyph atlas (PIL-baked once — Doc 08 §4)
# ---------------------------------------------------------------------------


def _load_glyph_font() -> ImageFont.ImageFont:
    """``segoeui.ttf`` (Windows builtin) → ``arial.ttf`` → DejaVu → PIL default."""
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, 24)
        except OSError:
            continue
    try:  # pragma: no cover - Pillow always ships a default bitmap font
        return ImageFont.load_default()
    except Exception:  # pragma: no cover - defensive
        return ImageFont.load_default()


def make_glyph_sheet(font: ImageFont.ImageFont | None = None) -> Image.Image:
    """Bake ``0123456789-+.`` into the frozen 128×64 sheet (8×2 cells of 16×32)."""
    if font is None:
        font = _load_glyph_font()
    sheet = Image.new("RGBA", GLYPH_SHEET_SIZE, (255, 255, 255, 0))
    draw = ImageDraw.Draw(sheet)
    for index, char in enumerate(GLYPH_CHARS):
        col, row = index % GLYPH_COLS, index // GLYPH_COLS
        left, top, right, bottom = draw.textbbox((0, 0), char, font=font)
        width, height = right - left, bottom - top
        x = col * GLYPH_CELL_W + (GLYPH_CELL_W - width) / 2 - left
        y = row * GLYPH_CELL_H + (GLYPH_CELL_H - height) / 2 - top
        draw.text((x, y), char, font=font, fill=(255, 255, 255, 255))
    return sheet


def format_graph_value(value: float) -> str:
    """Tick label restricted to the atlas charset ``0123456789-+.``."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return ""
    if not math.isfinite(number):
        return ""
    if abs(number - round(number)) < 1e-9:
        text = str(int(round(number)))
    else:
        text = f"{number:.2f}".rstrip("0").rstrip(".")
    if not text or any(ch not in GLYPH_CHARS for ch in text):  # pragma: no cover - guard
        text = str(int(round(number)))
    return text


# ---------------------------------------------------------------------------
# Graph tessellation (pure — Doc 08 §4(3))
# ---------------------------------------------------------------------------


@dataclass
class GraphGeometry:
    """Axis/grid line segments, filled triangles (arrowheads), and glyph placements."""

    lines: list[tuple[float, float, float, float]] = field(default_factory=list)
    tris: list[tuple[float, float, float, float, float, float]] = field(default_factory=list)
    glyphs: list[tuple[str, float, float, float]] = field(default_factory=list)
    # glyphs: (char, center_x, top_y, height) — world units, y-down top-left origin


def _range_pair(values: object, default: tuple[float, float]) -> tuple[float, float]:
    try:
        lo, hi = float(values[0]), float(values[1])  # type: ignore[index]
    except (TypeError, ValueError, IndexError):
        return default
    if not (math.isfinite(lo) and math.isfinite(hi)):
        return default
    return (lo, hi) if lo <= hi else (hi, lo)


def _tick_values(lo: float, hi: float, step: float) -> list[float]:
    """Graph-space tick values ``k·step`` covering ``[lo, hi]`` (inclusive edges)."""
    if not (step > 0.0) or not (math.isfinite(lo) and math.isfinite(hi)) or hi < lo:
        return []
    k0 = math.ceil(lo / step - 1e-9)
    k1 = math.floor(hi / step + 1e-9)
    if k1 - k0 + 1 > MAX_GRAPH_TICKS:
        logger.warning("graph tick count exceeds %d — skipping gridlines", MAX_GRAPH_TICKS)
        return []
    return [k * step for k in range(int(k0), int(k1) + 1)]


def _graph_params(
    cfg: dict,
) -> tuple[tuple[float, float], tuple[float, float], tuple[float, float], float, bool]:
    origin = cfg.get("origin") or (0.0, 0.0)
    try:
        ox, oy = float(origin[0]), float(origin[1])
    except (TypeError, ValueError, IndexError):
        ox, oy = 0.0, 0.0
    x_lo, x_hi = _range_pair(cfg.get("x_range"), (-100.0, 100.0))
    y_lo, y_hi = _range_pair(cfg.get("y_range"), (-100.0, 100.0))
    try:
        step = float(cfg.get("grid_step", 0.0) or 0.0)
    except (TypeError, ValueError):
        step = 0.0
    show_labels = bool(cfg.get("show_labels", True))
    return (ox, oy), (x_lo, x_hi), (y_lo, y_hi), step, show_labels


def build_cartesian_graph(cfg: dict) -> GraphGeometry:
    """``CARTESIAN_2D`` — axes through origin, gridlines/ticks every grid_step.

    ``x_range``/``y_range`` are graph-space extents relative to ``origin``
    (axis lines therefore always pass through the origin; gridlines are clipped
    to the ranges as Doc 08 §4(3) requires).
    """
    geo = GraphGeometry()
    (ox, oy), (x_lo, x_hi), (y_lo, y_hi), step, show_labels = _graph_params(cfg)
    # Axis lines through the origin, clipped to the configured ranges.
    geo.lines.append((ox + x_lo, oy, ox + x_hi, oy))
    geo.lines.append((ox, oy + y_lo, ox, oy + y_hi))
    if step <= 0.0:
        return geo
    tick = TICK_FRACTION * step
    half = tick * 0.5
    pad = 0.06 * step
    label_h = LABEL_HEIGHT_FRACTION * step
    x_ticks = _tick_values(x_lo, x_hi, step)
    y_ticks = _tick_values(y_lo, y_hi, step)
    # Major gridlines clipped to x_range / y_range.
    for value in x_ticks:
        geo.lines.append((ox + value, oy + y_lo, ox + value, oy + y_hi))
    for value in y_ticks:
        geo.lines.append((ox + x_lo, oy + value, ox + x_hi, oy + value))
    # Ticks: x-axis vertical, y-axis horizontal, length 0.35·grid_step.
    for value in x_ticks:
        geo.lines.append((ox + value, oy - half, ox + value, oy + half))
    for value in y_ticks:
        geo.lines.append((ox - half, oy + value, ox + half, oy + value))
    if show_labels:
        label_w = label_h * GLYPH_CELL_W / GLYPH_CELL_H
        for value in x_ticks:
            geo.glyphs.append(
                (format_graph_value(value), ox + value, oy + half + pad, label_h)
            )
        for value in y_ticks:
            geo.glyphs.append(
                (
                    format_graph_value(value),
                    ox - half - pad - label_w * 0.5,
                    oy + value - label_h * 0.5,
                    label_h,
                )
            )
    return geo


def build_number_line_graph(cfg: dict) -> GraphGeometry:
    """``NUMBER_LINE`` — horizontal axis, ticks + labels below, arrowheads both ends."""
    geo = GraphGeometry()
    (ox, oy), (x_lo, x_hi), _, step, show_labels = _graph_params(cfg)
    geo.lines.append((ox + x_lo, oy, ox + x_hi, oy))
    if step <= 0.0:
        return geo
    tick = TICK_FRACTION * step
    half = tick * 0.5
    pad = 0.06 * step
    label_h = LABEL_HEIGHT_FRACTION * step
    for value in _tick_values(x_lo, x_hi, step):
        tx = ox + value
        geo.lines.append((tx, oy - half, tx, oy + half))
        if show_labels:
            geo.glyphs.append(
                (format_graph_value(value), tx, oy + half + pad, label_h)
            )
    # Arrowheads at both ends (two triangles each, mirroring the ARROW shape).
    head_len = tick
    head_hw = tick * 0.4
    right = ox + x_hi
    left = ox + x_lo
    geo.tris.append((right, oy - head_hw, right, oy, right + head_len, oy))
    geo.tris.append((right, oy + head_hw, right, oy, right + head_len, oy))
    geo.tris.append((left, oy - head_hw, left, oy, left - head_len, oy))
    geo.tris.append((left, oy + head_hw, left, oy, left - head_len, oy))
    return geo


def graph_geometry(shape_type: str | None, graph_config: dict | None) -> GraphGeometry | None:
    """Dispatch Doc 08 §4(3); any other ``shape_type`` is skipped (returns None)."""
    cfg = graph_config if isinstance(graph_config, dict) else {}
    if shape_type == "CARTESIAN_2D":
        return build_cartesian_graph(cfg)
    if shape_type == "NUMBER_LINE":
        return build_number_line_graph(cfg)
    return None


# ---------------------------------------------------------------------------
# Shape tessellation (pure — Doc 08 §4(4))
# ---------------------------------------------------------------------------


def rect_corners(
    pts: Sequence[Sequence[float]] | None, bbox: Sequence[float]
) -> tuple[float, float, float, float] | None:
    """RECT corners from ``pts[0]/pts[1]`` when present, else the node bbox."""
    if pts and len(pts) >= 2:
        try:
            ax, ay = float(pts[0][0]), float(pts[0][1])
            bx, by = float(pts[1][0]), float(pts[1][1])
        except (TypeError, ValueError, IndexError):
            pass
        else:
            return (min(ax, bx), min(ay, by), max(ax, bx), max(ay, by))
    try:
        x0, y0, x1, y1 = (float(v) for v in bbox)
    except (TypeError, ValueError):
        return None
    if x0 == x1 or y0 == y1:
        return None
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def rect_triangles(
    corners: tuple[float, float, float, float]
) -> list[float]:
    """Two triangles covering the corner quad (flat x, y triples)."""
    x0, y0, x1, y1 = corners
    return [x0, y0, x1, y0, x1, y1, x0, y0, x1, y1, x0, y1]


def circle_triangles(
    cx: float, cy: float, rx: float, ry: float, segments: int = CIRCLE_SEGMENTS
) -> list[float]:
    """CIRCLE as a 64-segment fan expanded to a TRIANGLES batch."""
    verts: list[float] = []
    for index in range(segments):
        a0 = 2.0 * math.pi * index / segments
        a1 = 2.0 * math.pi * (index + 1) / segments
        verts.extend(
            (
                cx,
                cy,
                cx + rx * math.cos(a0),
                cy + ry * math.sin(a0),
                cx + rx * math.cos(a1),
                cy + ry * math.sin(a1),
            )
        )
    return verts


def circle_rim_points(
    cx: float, cy: float, rx: float, ry: float, segments: int = CIRCLE_SEGMENTS
) -> list[tuple[float, float]]:
    """Rim sample points (closed) used for the optional CIRCLE outline."""
    return [
        (
            cx + rx * math.cos(2.0 * math.pi * index / segments),
            cy + ry * math.sin(2.0 * math.pi * index / segments),
        )
        for index in range(segments)
    ]


def triangle_points(pts: Sequence[Sequence[float]]) -> list[float] | None:
    """TRIANGLE from the first three ``pts`` (flat x, y triples) or None."""
    if not pts or len(pts) < 3:
        return None
    try:
        return [
            float(pts[0][0]), float(pts[0][1]),
            float(pts[1][0]), float(pts[1][1]),
            float(pts[2][0]), float(pts[2][1]),
        ]
    except (TypeError, ValueError, IndexError):
        return None


def arrow_geometry(
    start: tuple[float, float],
    end: tuple[float, float],
    stroke_width: float,
) -> tuple[list[float], list[float], float] | None:
    """ARROW = shaft quad + 2 head triangles.

    Head length ``0.25·shaft_length``, head half-width ``3× stroke_width``,
    shaft half-width ``stroke_width``. Returns ``(shaft_tris, head_tris, head_len)``.
    """
    dx = float(end[0]) - float(start[0])
    dy = float(end[1]) - float(start[1])
    length = math.hypot(dx, dy)
    if length <= 1e-9 or not math.isfinite(length):
        return None
    ux, uy = dx / length, dy / length
    px, py = -uy, ux
    shaft_hw = max(float(stroke_width), 1e-6)
    head_len = ARROW_HEAD_FRACTION * length
    head_hw = ARROW_HEAD_HALF_WIDTH * float(stroke_width)
    ex, ey = float(end[0]), float(end[1])
    sx, sy = float(start[0]), float(start[1])
    shaft = [
        sx + px * shaft_hw, sy + py * shaft_hw,
        sx - px * shaft_hw, sy - py * shaft_hw,
        ex - px * shaft_hw, ey - py * shaft_hw,
        sx + px * shaft_hw, sy + py * shaft_hw,
        ex - px * shaft_hw, ey - py * shaft_hw,
        ex + px * shaft_hw, ey + py * shaft_hw,
    ]
    apex = (ex + ux * head_len, ey + uy * head_len)
    head = [
        ex + px * head_hw, ey + py * head_hw, ex, ey, apex[0], apex[1],
        ex - px * head_hw, ey - py * head_hw, ex, ey, apex[0], apex[1],
    ]
    return shaft, head, head_len


def line_quad(
    x0: float, y0: float, x1: float, y1: float, half_width: float
) -> list[float]:
    """Four vertices (x, y, signed ±half-width) forming an AA line quad.

    Returns a flat list of 12 floats (4 × xyz); empty for degenerate segments.
    """
    dx, dy = float(x1) - float(x0), float(y1) - float(y0)
    length = math.hypot(dx, dy)
    if length <= 1e-9 or not math.isfinite(length):
        return []
    hw = max(float(half_width), 1e-9)
    nx, ny = -dy / length * hw, dx / length * hw
    return [
        x0 + nx, y0 + ny, hw,
        x0 - nx, y0 - ny, -hw,
        x1 - nx, y1 - ny, -hw,
        x1 + nx, y1 + ny, hw,
    ]


def quad_triangles(verts4: Sequence[float]) -> list[float]:
    """Two triangles (6 × xyz) from a 4-vertex line quad."""
    if len(verts4) != 12:
        return []
    a, b, c, d = verts4[0:3], verts4[3:6], verts4[6:9], verts4[9:12]
    return [*a, *b, *c, *a, *c, *d]


def outline_quads(
    x0: float, y0: float, x1: float, y1: float, half_width: float
) -> list[float]:
    """Four edge line-quads of a rectangle → flat triangle vertex list."""
    corners = [
        (x0, y0, x1, y0),
        (x1, y0, x1, y1),
        (x1, y1, x0, y1),
        (x0, y1, x0, y0),
    ]
    verts: list[float] = []
    for ax, ay, bx, by in corners:
        verts.extend(quad_triangles(line_quad(ax, ay, bx, by, half_width)))
    return verts


def polyline_quads(
    points: Sequence[tuple[float, float]], half_width: float
) -> list[float]:
    """Consecutive-segment line quads through ``points`` (closed loop)."""
    verts: list[float] = []
    count = len(points)
    if count < 2:
        return verts
    for index in range(count):
        ax, ay = points[index]
        bx, by = points[(index + 1) % count]
        verts.extend(quad_triangles(line_quad(ax, ay, bx, by, half_width)))
    return verts


# ---------------------------------------------------------------------------
# Vertex stream (CPU list → growable GL buffer + VAO)
# ---------------------------------------------------------------------------


class _Stream:
    """Growable CPU float list uploaded to one (program, layout) GL buffer/VAO."""

    def __init__(
        self,
        ctx: moderngl.Context,
        program: moderngl.Program,
        fmt: str,
        stride: int,
        attributes: tuple[str, ...],
    ) -> None:
        self._ctx = ctx
        self._program = program
        self._fmt = fmt
        self._stride = stride
        self._attributes = attributes
        self._buffer: moderngl.Buffer | None = None
        self._vao: moderngl.VertexArray | None = None
        self.data: list[float] = []

    def clear(self) -> None:
        self.data.clear()

    def extend(self, values: Iterable[float]) -> None:
        self.data.extend(values)

    def upload(self) -> moderngl.VertexArray | None:
        """Upload pending floats; returns the VAO (None when empty)."""
        if not self.data:
            return None
        raw = np.asarray(self.data, dtype=np.float32).tobytes()
        if self._buffer is None:
            self._buffer = self._ctx.buffer(raw, dynamic=True)
            self._vao = self._ctx.vertex_array(
                self._program, [(self._buffer, self._fmt, *self._attributes)]
            )
        elif self._buffer.size < len(raw):
            self._buffer.orphan(len(raw))
            self._buffer.write(raw)
        else:
            self._buffer.write(raw)
        return self._vao

    @property
    def vertex_count(self) -> int:
        return len(self.data) // self._stride

    def release(self) -> None:
        for target in (self._vao, self._buffer):
            if target is not None:
                try:
                    target.release()
                except Exception:  # pragma: no cover - defensive
                    logger.debug("stream release failed", exc_info=True)
        self._vao = None
        self._buffer = None
        self.data.clear()


# ---------------------------------------------------------------------------
# PrimitiveRenderer (frozen interface — template §4)
# ---------------------------------------------------------------------------


class PrimitiveRenderer:
    """Doc 08 renderer — backgrounds, page chrome, graphs, shapes, image quads."""

    # Pure math from Doc 08 §4 exposed as statics so both import paths work.
    visible_world_rect = staticmethod(visible_world_rect)
    is_visible = staticmethod(is_visible)

    def __init__(self, ctx: moderngl.Context, registry: "ProgramRegistry") -> None:
        self._ctx = ctx
        self._registry = registry
        if getattr(registry, "ctx", None) is None and hasattr(registry, "set_ctx"):
            registry.set_ctx(ctx)  # tolerate construction before Doc 06 attaches
        self._assets_root: Path | None = None
        self._content_bounds: dict[str, float] = {}
        self._image_cache: dict[str, moderngl.Texture] = {}
        self._glyph_tex: moderngl.Texture | None = None
        self._placeholder_tex: moderngl.Texture | None = None
        self.applied_scissor: tuple[int, int, int, int] | None = None
        self.scissor_enabled: bool = False
        # Doc 06 stems — ProgramRegistry pairs <stem>.vert + <stem>.frag itself.
        self._grid_prog = registry.get("grid")
        self._prim_prog = registry.get("primitive")
        self._tex_prog = registry.get("texture")
        self._grid_stream = _Stream(ctx, self._grid_prog, "2f", 2, ("in_pos",))
        self._prim_stream = _Stream(ctx, self._prim_prog, "3f 4f", 7, ("in_vec3", "in_rgba"))
        self._tex_stream = _Stream(ctx, self._tex_prog, "4f", 4, ("in_pos_uv",))

    # ------------------------------------------------------------------
    # Public API (frozen — Doc 08 §4)
    # ------------------------------------------------------------------

    def set_assets_root(self, root: Path) -> None:
        """Injected ``DocumentStore.assets_dir`` (Doc 10); swapping releases textures."""
        new_root = Path(root) if root is not None else None
        if new_root != self._assets_root:
            self._release_textures()
            self._assets_root = new_root

    def glyph_atlas(self) -> "moderngl.Texture":
        """PIL-baked once: chars ``0123456789-+.`` → 128×64 LINEAR RGBA sheet."""
        if self._glyph_tex is None:
            sheet = make_glyph_sheet()
            texture = self._ctx.texture(sheet.size, 4, sheet.tobytes())
            texture.filter = (moderngl.LINEAR, moderngl.LINEAR)
            self._glyph_tex = texture
        return self._glyph_tex

    def render(
        self,
        nodes: list["CanvasNode"],
        camera: tuple[float, float, float],
        artboard: "Artboard",
        content_bounds: dict[str, float],
    ) -> None:
        """Draw one frame in the frozen Doc 08 order (state restored on exit)."""
        self._content_bounds = dict(content_bounds or {})
        viewport = self._ctx.viewport
        view_w, view_h = int(viewport[2]), int(viewport[3])
        if view_w <= 0 or view_h <= 0:
            return
        cam = (clamp_zoom(camera[0]), float(camera[1]), float(camera[2]))
        world_rect = visible_world_rect(cam, (view_w, view_h))
        ordered = sorted(
            (node for node in (nodes or [])
             if is_visible(getattr(node, "bbox", (0, 0, 0, 0)), world_rect)),
            key=lambda node: (getattr(node, "layer", 0), str(getattr(node, "node_id", ""))),
        )
        images = [node for node in ordered if getattr(node, "kind", "") == "IMAGE"]
        shapes = [node for node in ordered if getattr(node, "kind", "") in ("SHAPE", "LINE")]
        graphs = [node for node in ordered if getattr(node, "kind", "") == "GRAPH_AXES"]
        # Frozen phase order (Doc 08 §4): background → shadow → images → shapes → graphs.
        self._draw_background(artboard, cam, view_w, view_h)
        self._draw_shadow_boundary(artboard, cam, view_w, view_h, world_rect)
        self._draw_images(images, cam, view_w, view_h)
        self._draw_shapes(shapes, cam, view_w, view_h)
        self._draw_graphs(graphs, cam, view_w, view_h)
        self._restore_state()

    def release(self) -> None:
        """Release GL objects owned by this renderer (programs belong to Doc 06)."""
        self._release_textures()
        if self._glyph_tex is not None:
            try:
                self._glyph_tex.release()
            except Exception:  # pragma: no cover - defensive
                logger.debug("glyph atlas release failed", exc_info=True)
            self._glyph_tex = None
        for stream in (self._grid_stream, self._prim_stream, self._tex_stream):
            stream.release()

    # ------------------------------------------------------------------
    # Phase 1 — background (fullscreen grid program)
    # ------------------------------------------------------------------

    def _draw_background(
        self, artboard: "Artboard", camera: tuple[float, float, float], view_w: int, view_h: int
    ) -> None:
        pattern = _PATTERN_IDS.get(str(getattr(artboard, "background_style", "BLANK")), 0)
        bg = parse_color(getattr(artboard, "background_color", "#FFFFFF"), 1.0)
        line_color = (bg[0] * 0.55, bg[1] * 0.55, bg[2] * 0.55)
        bounded = (
            not bool(getattr(artboard, "is_infinite", False))
            and (getattr(artboard, "width", None) or 0) > 0
            and (getattr(artboard, "height", None) or 0) > 0
        )
        program = self._grid_prog
        self._set(program, "u_camera", camera)
        self._set(program, "u_viewport", (float(view_w), float(view_h)))
        self._set(program, "u_pattern", int(pattern))
        self._set(program, "u_bgColor", bg[:3])
        self._set(program, "u_lineColor", line_color)
        if bounded:
            width = float(artboard.width)
            height = float(artboard.height)
            self._set(program, "u_scissor", (0.0, 0.0, width, height))
            self._set(program, "u_scissorEnabled", 1)
            box = _artboard_scissor_box(width, height, camera, view_w, view_h)
            if box is not None:
                self._ctx.scissor = box
                self._ctx.enable_direct(_GL_SCISSOR_TEST)
            self.applied_scissor = box
            self.scissor_enabled = True
        else:
            self._set(program, "u_scissorEnabled", 0)
            self.applied_scissor = None
            self.scissor_enabled = False
        if not self._grid_stream.data:
            self._grid_stream.extend(
                (-1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, 1.0)
            )
        vao = self._grid_stream.upload()
        if vao is not None:
            vao.render(moderngl.TRIANGLE_STRIP, vertices=4)
            self._grid_stream.clear()

    # ------------------------------------------------------------------
    # Phase 2 — drop shadow + 1 px page boundary (bounded presets only)
    # ------------------------------------------------------------------

    def _draw_shadow_boundary(
        self,
        artboard: "Artboard",
        camera: tuple[float, float, float],
        view_w: int,
        view_h: int,
        world_rect: tuple[float, float, float, float],
    ) -> None:
        if bool(getattr(artboard, "is_infinite", False)):
            return  # INFINITE renders neither shadow nor boundary
        width = float(getattr(artboard, "width", 0) or 0)
        height = float(getattr(artboard, "height", 0) or 0)
        if width <= 0 or height <= 0:
            return
        if not is_visible((0.0, 0.0, width, height), world_rect):
            return  # whole page off-screen
        scale = camera[0]
        # Feathered drop-shadow quad (kind 2 — fragment does the smoothstep math).
        offset = SHADOW_OFFSET_FRACTION * min(width, height)
        feather = SHADOW_FEATHER_FACTOR * offset
        x0, y0 = offset - feather, offset - feather
        x1, y1 = width + offset + feather, height + offset + feather
        stream = self._prim_stream
        stream.extend(_flat_quad(x0, y0, x1, y1))
        shadow_uniforms = {
            "u_kind": 2,
            "u_pageSize": (width, height),
            "u_shadowOf": (offset, feather),
            "u_shadowColor": _SHADOW_COLOR,
        }
        self._emit_primitive(
            stream, blend=0, uniforms=shadow_uniforms, camera=camera,
            viewport=(view_w, view_h),
        )
        # 1 px screen-scaled page outline (kind 1).
        half = 0.5 / max(scale, 1e-9)
        stream.extend(outline_quads(0.0, 0.0, width, height, half))
        self._emit_primitive(
            stream, blend=0, uniforms={"u_kind": 1}, camera=camera,
            viewport=(view_w, view_h),
        )

    # ------------------------------------------------------------------
    # Phase 3 — image quads
    # ------------------------------------------------------------------

    def _draw_images(
        self,
        images: list["CanvasNode"],
        camera: tuple[float, float, float],
        view_w: int,
        view_h: int,
    ) -> None:
        if not images:
            return
        stream = self._tex_stream
        for node in images:
            try:
                corners = rect_corners(None, node.bbox)
            except Exception:
                logger.debug("image bbox rejected", exc_info=True)
                continue
            if corners is None:
                continue
            x0, y0, x1, y1 = corners
            texture = self._image_texture(getattr(node.geometry, "asset_ref", None))
            # Images keep their source colours; style opacity scales coverage.
            opacity = float(getattr(node.style, "opacity", 1.0) or 1.0)
            tint = (1.0, 1.0, 1.0, opacity)
            stream.extend(
                [
                    x0, y0, 0.0, 0.0,
                    x1, y0, 1.0, 0.0,
                    x1, y1, 1.0, 1.0,
                    x0, y0, 0.0, 0.0,
                    x1, y1, 1.0, 1.0,
                    x0, y1, 0.0, 1.0,
                ]
            )
            blend = _blend_of(node)
            vao = stream.upload()
            if vao is None:
                continue
            self._set(self._tex_prog, "u_camera", camera)
            self._set(self._tex_prog, "u_viewport", (float(view_w), float(view_h)))
            self._set(self._tex_prog, "u_tint", tint)
            self._set(self._tex_prog, "u_blendMode", blend)
            self._set(self._tex_prog, "u_tex", 0)
            self._apply_blend(blend)
            texture.use(location=0)
            vao.render(moderngl.TRIANGLES, vertices=stream.vertex_count)
            stream.clear()

    # ------------------------------------------------------------------
    # Phase 4 — geometric shapes
    # ------------------------------------------------------------------

    def _draw_shapes(
        self,
        shapes: list["CanvasNode"],
        camera: tuple[float, float, float],
        view_w: int,
        view_h: int,
    ) -> None:
        if not shapes:
            return
        scale = camera[0]
        fills: list[float] = []
        lines: list[float] = []
        run_blend: int | None = None
        for node in shapes:
            blend = _blend_of(node)
            if run_blend is not None and blend != run_blend:
                self._flush_shape_run(fills, lines, run_blend, camera, view_w, view_h)
                fills, lines = [], []
            run_blend = blend
            self._tessellate_shape(node, fills, lines, scale)
        if run_blend is not None:
            self._flush_shape_run(fills, lines, run_blend, camera, view_w, view_h)

    def _flush_shape_run(
        self,
        fills: list[float],
        lines: list[float],
        blend: int,
        camera: tuple[float, float, float],
        view_w: int,
        view_h: int,
    ) -> None:
        stream = self._prim_stream
        if fills:
            stream.extend(fills)
            self._emit_primitive(
                stream, blend=blend, uniforms={"u_kind": 0}, camera=camera,
                viewport=(view_w, view_h),
            )
        if lines:
            stream.extend(lines)
            self._emit_primitive(
                stream, blend=blend, uniforms={"u_kind": 1}, camera=camera,
                viewport=(view_w, view_h),
            )

    def _tessellate_shape(
        self, node: "CanvasNode", fills: list[float], lines: list[float], scale: float
    ) -> None:
        geometry = getattr(node, "geometry", None)
        style = getattr(node, "style", None)
        shape_type = str(getattr(geometry, "shape_type", "") or "")
        stroke_width = float(getattr(style, "stroke_width", 0.0) or 0.0)
        rgba = parse_color(getattr(style, "color", "#1E1E1E"), getattr(style, "opacity", 1.0))
        bbox = getattr(node, "bbox", (0.0, 0.0, 0.0, 0.0))
        pts = list(getattr(geometry, "pts", None) or [])
        outline_hw = max(stroke_width * 0.5, 0.5 / max(scale, 1e-9))
        if shape_type == "RECT":
            corners = rect_corners(pts, bbox)
            if corners is None:
                return
            _push_tri(fills, rect_triangles(corners), rgba)
            if stroke_width > 0:
                _push_line_tris(lines, outline_quads(*corners, outline_hw), rgba)
        elif shape_type == "CIRCLE":
            cx, cy, rx, ry = _circle_frame(pts, bbox)
            if rx <= 0 or ry <= 0:
                return
            _push_tri(fills, circle_triangles(cx, cy, rx, ry), rgba)
            if stroke_width > 0:
                _push_line_tris(
                    lines,
                    polyline_quads(circle_rim_points(cx, cy, rx, ry), outline_hw),
                    rgba,
                )
        elif shape_type == "TRIANGLE":
            triangle = triangle_points(pts)
            if triangle is None:
                return
            _push_tri(fills, triangle, rgba)
            if stroke_width > 0:
                outline = polyline_quads(
                    [(triangle[0], triangle[1]), (triangle[2], triangle[3]),
                     (triangle[4], triangle[5])],
                    outline_hw,
                )
                _push_line_tris(lines, outline, rgba)
        elif shape_type == "ARROW":
            start, end = _arrow_frame(pts, bbox)
            built = arrow_geometry(start, end, stroke_width)
            if built is None:
                return
            shaft, head, _ = built
            _push_tri(fills, shaft, rgba)
            _push_tri(fills, head, rgba)
        # Unknown shape_type (incl. graph types on SHAPE nodes) — skipped per Doc 08 §4.

    # ------------------------------------------------------------------
    # Phase 5 — graph axes
    # ------------------------------------------------------------------

    def _draw_graphs(
        self,
        graphs: list["CanvasNode"],
        camera: tuple[float, float, float],
        view_w: int,
        view_h: int,
    ) -> None:
        if not graphs:
            return
        scale = camera[0]
        prim = self._prim_stream
        tex = self._tex_stream
        atlas = None
        for node in graphs:
            geometry = getattr(node, "geometry", None)
            geo = graph_geometry(
                getattr(geometry, "shape_type", None),
                getattr(geometry, "graph_config", None),
            )
            if geo is None:
                continue  # other shape_type values on GRAPH_AXES are skipped
            style = getattr(node, "style", None)
            stroke_width = float(getattr(style, "stroke_width", 0.0) or 0.0)
            rgba = parse_color(getattr(style, "color", "#1E1E1E"), getattr(style, "opacity", 1.0))
            blend = _blend_of(node)
            line_hw = max(stroke_width * 0.5, 0.5 / max(scale, 1e-9))
            for x0, y0, x1, y1 in geo.lines:
                _push_line_tris(
                    prim.data, quad_triangles(line_quad(x0, y0, x1, y1, line_hw)), rgba
                )
            if prim.data:
                self._emit_primitive(
                    prim, blend=blend, uniforms={"u_kind": 1},
                    camera=camera, viewport=(view_w, view_h),
                )
            if geo.tris:
                _push_tri_data(prim.data, geo.tris, rgba)
                self._emit_primitive(
                    prim, blend=blend, uniforms={"u_kind": 0},
                    camera=camera, viewport=(view_w, view_h),
                )
            if geo.glyphs:
                if atlas is None:
                    atlas = self.glyph_atlas()
                _push_glyph_quads(tex.data, geo.glyphs)
                vao = tex.upload()
                if vao is not None:
                    self._set(self._tex_prog, "u_camera", camera)
                    self._set(self._tex_prog, "u_viewport", (float(view_w), float(view_h)))
                    self._set(self._tex_prog, "u_tint", rgba)
                    self._set(self._tex_prog, "u_blendMode", blend)
                    self._set(self._tex_prog, "u_tex", 0)
                    self._apply_blend(blend)
                    atlas.use(location=0)
                    vao.render(moderngl.TRIANGLES, vertices=tex.vertex_count)
                    tex.clear()

    # ------------------------------------------------------------------
    # Emission helpers
    # ------------------------------------------------------------------

    def _emit_primitive(
        self,
        stream: _Stream,
        blend: int,
        uniforms: dict[str, object],
        camera: tuple[float, float, float] | None = None,
        viewport: tuple[int, int] | None = None,
    ) -> None:
        """Draw accumulated primitive verts and reset the stream."""
        try:
            vao = stream.upload()
            if vao is None:
                return
            if camera is not None:
                self._set(self._prim_prog, "u_camera", camera)
                self._set(self._prim_prog, "u_viewport", (float(viewport[0]), float(viewport[1])))
            self._set(self._prim_prog, "u_blendMode", int(blend))
            for name, value in uniforms.items():
                self._set(self._prim_prog, name, value)
            self._apply_blend(blend)
            vao.render(moderngl.TRIANGLES, vertices=stream.vertex_count)
        finally:
            stream.clear()

    @staticmethod
    def _set(program: moderngl.Program, name: str, value: object) -> None:
        """Set a uniform, tolerating driver-side elimination of unused ones."""
        try:
            program[name].value = value  # type: ignore[index]
        except KeyError:
            logger.debug("uniform %s absent from program", name)

    def _apply_blend(self, blend: int) -> None:
        self._ctx.blend_func = _MULTIPLY if blend == 1 else _SRC_OVER  # template §3

    def _restore_state(self) -> None:
        """Blend/scissor state restored after every render (Doc 08 §4)."""
        self._ctx.disable_direct(_GL_SCISSOR_TEST)
        self._ctx.blend_func = _SRC_OVER

    # ------------------------------------------------------------------
    # Image textures (assets_root contract — Doc 10)
    # ------------------------------------------------------------------

    def _image_texture(self, asset_ref: object) -> moderngl.Texture:
        if not asset_ref:
            return self._placeholder()
        path = resolve_asset_path(self._assets_root, str(asset_ref))
        key = str(path)
        cached = self._image_cache.get(key)
        if cached is not None:
            return cached
        image: Image.Image | None = None
        try:
            if self._assets_root is not None and path.is_file():
                with Image.open(path) as opened:
                    image = opened.convert("RGBA")
            else:
                logger.warning(
                    "missing image asset %r (resolved %s) — using 1×1 magenta placeholder",
                    asset_ref,
                    path,
                )
        except Exception:
            logger.warning(
                "failed to decode image asset %s — using placeholder", path, exc_info=True
            )
        if image is None:
            image = placeholder_image()
        texture = self._ctx.texture(image.size, 4, image.tobytes())
        texture.filter = (moderngl.LINEAR, moderngl.LINEAR)
        self._image_cache[key] = texture
        return texture

    def _placeholder(self) -> moderngl.Texture:
        if self._placeholder_tex is None:
            image = placeholder_image()
            self._placeholder_tex = self._ctx.texture(image.size, 4, image.tobytes())
            self._placeholder_tex.filter = (moderngl.NEAREST, moderngl.NEAREST)
        return self._placeholder_tex

    def _release_textures(self) -> None:
        for texture in self._image_cache.values():
            try:
                texture.release()
            except Exception:  # pragma: no cover - defensive
                logger.debug("image texture release failed", exc_info=True)
        self._image_cache.clear()
        if self._placeholder_tex is not None:
            try:
                self._placeholder_tex.release()
            except Exception:  # pragma: no cover - defensive
                logger.debug("placeholder release failed", exc_info=True)
            self._placeholder_tex = None


# ---------------------------------------------------------------------------
# Module helpers (pure)
# ---------------------------------------------------------------------------


def _blend_of(node: object) -> int:
    style = getattr(node, "style", None)
    mode = str(getattr(style, "blend_mode", "SRC_OVER") or "SRC_OVER")
    return 1 if mode == "MULTIPLY" else 0


def _flat_quad(x0: float, y0: float, x1: float, y1: float) -> list[float]:
    """Two triangles (flat x, y; aux 0; rgba white) spanning the corners."""
    return [
        x0, y0, 0.0, 1.0, 1.0, 1.0, 1.0,
        x1, y0, 0.0, 1.0, 1.0, 1.0, 1.0,
        x1, y1, 0.0, 1.0, 1.0, 1.0, 1.0,
        x0, y0, 0.0, 1.0, 1.0, 1.0, 1.0,
        x1, y1, 0.0, 1.0, 1.0, 1.0, 1.0,
        x0, y1, 0.0, 1.0, 1.0, 1.0, 1.0,
    ]


def _push_tri(dest: list[float], flat_points: Sequence[float], rgba: tuple[float, ...]) -> None:
    """Append flat x,y point pairs to a primitive stream as (x, y, aux=0, rgba) verts."""
    for index in range(0, len(flat_points), 2):
        dest.extend((flat_points[index], flat_points[index + 1], 0.0, *rgba))


def _push_line_tris(dest: list[float], flat_xyz: Sequence[float], rgba: tuple[float, ...]) -> None:
    """Append flat (x, y, signed aux) vertex triples as full primitive verts."""
    for index in range(0, len(flat_xyz), 3):
        dest.extend(
            (flat_xyz[index], flat_xyz[index + 1], flat_xyz[index + 2], *rgba)
        )


def _push_tri_data(
    dest: list[float],
    tris: Iterable[Sequence[float]],
    rgba: tuple[float, ...],
) -> None:
    for tri in tris:
        _push_tri(dest, tri, rgba)


def _circle_frame(
    pts: Sequence[Sequence[float]], bbox: Sequence[float]
) -> tuple[float, float, float, float]:
    try:
        if pts and len(pts) >= 2:
            cx, cy = float(pts[0][0]), float(pts[0][1])
            radius = math.hypot(float(pts[1][0]) - cx, float(pts[1][1]) - cy)
            if radius > 0:
                return (cx, cy, radius, radius)
        x0, y0, x1, y1 = (float(v) for v in bbox)
    except (TypeError, ValueError, IndexError):
        return (0.0, 0.0, 0.0, 0.0)
    return ((x0 + x1) * 0.5, (y0 + y1) * 0.5, abs(x1 - x0) * 0.5, abs(y1 - y0) * 0.5)


def _arrow_frame(
    pts: Sequence[Sequence[float]], bbox: Sequence[float]
) -> tuple[tuple[float, float], tuple[float, float]]:
    try:
        if pts and len(pts) >= 2:
            return (
                (float(pts[0][0]), float(pts[0][1])),
                (float(pts[-1][0]), float(pts[-1][1])),
            )
        x0, y0, x1, y1 = (float(v) for v in bbox)
    except (TypeError, ValueError, IndexError):
        return ((0.0, 0.0), (0.0, 0.0))
    return ((x0, y0), (x1, y1))


def _glyph_cell_uv(index: int) -> tuple[float, float, float, float]:
    """Atlas cell (u0, v0, u1, v1) — sheet row 0 sits at v 0 (no upload flip)."""
    col, row = index % GLYPH_COLS, index // GLYPH_COLS
    u0 = col * GLYPH_CELL_W / GLYPH_SHEET_SIZE[0]
    v0 = row * GLYPH_CELL_H / GLYPH_SHEET_SIZE[1]
    u1 = u0 + GLYPH_CELL_W / GLYPH_SHEET_SIZE[0]
    v1 = v0 + GLYPH_CELL_H / GLYPH_SHEET_SIZE[1]
    return (u0, v0, u1, v1)


def _push_glyph_quads(
    dest: list[float], glyphs: Iterable[tuple[str, float, float, float]]
) -> None:
    """Append (char, center_x, top_y, height) labels as textured quad verts."""
    for char, center_x, top_y, height in glyphs:
        index = GLYPH_CHARS.find(char)
        if index < 0 or height <= 0:
            continue
        u0, v0, u1, v1 = _glyph_cell_uv(index)
        half_w = height * GLYPH_CELL_W / GLYPH_CELL_H * 0.5
        left, right = center_x - half_w, center_x + half_w
        bottom = top_y + height
        dest.extend(
            (
                left, top_y, u0, v0,
                right, top_y, u1, v0,
                right, bottom, u1, v1,
                left, top_y, u0, v0,
                right, bottom, u1, v1,
                left, bottom, u0, v1,
            )
        )


def _artboard_scissor_box(
    width: float,
    height: float,
    camera: tuple[float, float, float],
    view_w: int,
    view_h: int,
) -> tuple[int, int, int, int] | None:
    """GL scissor (bottom-left origin) for the artboard's screen rect, or None off-screen."""
    x0, y0 = world_to_screen((0.0, 0.0), camera, (view_w, view_h))
    x1, y1 = world_to_screen((width, height), camera, (view_w, view_h))
    left, right = min(x0, x1), max(x0, x1)
    top, bottom = min(y0, y1), max(y0, y1)
    left, right = max(0.0, left), min(float(view_w), right)
    top, bottom = max(0.0, top), min(float(view_h), bottom)
    if right - left < 1.0 or bottom - top < 1.0:
        return None
    gx = int(math.floor(left))
    gy = int(math.floor(view_h - bottom))
    gw = int(math.ceil(right)) - gx
    gh = int(math.ceil(view_h - top)) - gy
    gx, gy = max(0, gx), max(0, gy)
    gw = min(gw, view_w - gx)
    gh = min(gh, view_h - gy)
    if gw <= 0 or gh <= 0:
        return None
    return (gx, gy, gw, gh)
