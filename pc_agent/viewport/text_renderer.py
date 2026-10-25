"""Round-12 issue 05 — TEXT shape layout and rasterisation.

A text box is stored as a ``SHAPE`` node with ``shape_type: "TEXT"`` and its
content in ``graph_config`` (``text``, ``font_size``, ``align``), because
``NodeStyle`` is frozen and ``geometry.pts`` is numeric-only — the same "config
object on a shape" route ``TABLE`` already takes.

The three places that paint text disagree about how to get pixels:

* the GL viewport needs a **texture** (its shader batches triangles, and the
  glyph atlas only carries ``0123456789-+.``),
* the cairo exporters need **glyph calls** in the output surface,
* the thumbnail wants the same geometry at a smaller width.

They must nevertheless agree about *where every line sits*, otherwise the
mirror and the export drift the moment a text box wraps. So the wrapping and
line placement live here as pure functions, and only the final "put these
glyphs at these points" step is per-renderer.

Wrapping is deliberately a plain greedy word wrap rather than anything
typographically clever: the tablet has to reproduce it with a ``TextPainter``
measurer (``mobile_app/lib/canvas_engine/text_box_model.dart``) and two
independent implementations only stay identical while the rule is trivial.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field

import cairo
import numpy as np
from PIL import Image

#: Font size used when ``graph_config`` carries none (Doc 24 default).
DEFAULT_FONT_SIZE = 24.0
#: Guard rails, mirrored in Dart. A 1 pt box is unreadable and a 10 000 pt box
#: overflows every surface, so both ends are clamped rather than trusted.
MIN_FONT_SIZE = 6.0
MAX_FONT_SIZE = 400.0
#: Line box height as a multiple of the font size. 1.25 is tight enough to look
#: like a text box and loose enough that descenders never touch the next line.
LINE_HEIGHT_FACTOR = 1.25
#: Inset of the text from its own bbox, in world units.
TEXT_PADDING = 4.0
#: ``graph_config.align`` values, in the order the UI cycles them.
ALIGNMENTS = ("left", "center", "right")
DEFAULT_ALIGN = "left"
#: Same toy font stack the graph labels use, so a page never mixes faces.
TEXT_FONT_FACE = ("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
#: Pixel density of the GL text texture, per world unit. Text is a raster in
#: the viewport (see the module docstring), so this trades sharpness for VRAM.
RASTER_SCALE = 3.0
#: Hard cap on a single text texture edge; a giant text box at high zoom must
#: degrade to a coarser raster instead of asking the driver for 30 000 px.
MAX_RASTER_PX = 2048

#: ``measure(text, font_size) -> width`` — supplied by the caller because only
#: the caller owns a cairo context (or a Flutter ``TextPainter``).
Measurer = Callable[[str, float], float]


# ---------------------------------------------------------------------------
# graph_config
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TextConfig:
    """The ``graph_config`` payload of a TEXT node, already sanitised."""

    text: str = ""
    font_size: float = DEFAULT_FONT_SIZE
    align: str = DEFAULT_ALIGN

    @property
    def is_empty(self) -> bool:
        return not self.text.strip()


def clamp_font_size(value: object) -> float:
    """``graph_config.font_size`` → a usable size.

    Non-finite and non-numeric input is rejected explicitly: ``float("nan")``
    would otherwise reach cairo as a font size and raise from a paint callback,
    which is indistinguishable from a crash in the render thread.
    """
    try:
        size = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_FONT_SIZE
    if not math.isfinite(size):
        return DEFAULT_FONT_SIZE
    return max(MIN_FONT_SIZE, min(MAX_FONT_SIZE, size))


def normalise_align(value: object) -> str:
    """Unknown / missing alignment falls back to ``left``, never raises."""
    if not isinstance(value, str):
        return DEFAULT_ALIGN
    token = value.strip().lower()
    return token if token in ALIGNMENTS else DEFAULT_ALIGN


def sanitise_text(value: object) -> str:
    """``graph_config.text`` → the string to draw (``""`` for anything else)."""
    if not isinstance(value, str):
        return ""
    # Normalise newlines once, here: the wrapper and the Dart twin both split
    # on "\n" only, so a stray "\r\n" must not produce two line breaks.
    return value.replace("\r\n", "\n").replace("\r", "\n")


#: Alias kept for the Dart twin's spelling (`normaliseText`), so a reader
#: diffing the two files finds the same name on both sides.
normalise_text = sanitise_text


def text_config(graph_config: object) -> TextConfig:
    """Reads a TEXT node's ``graph_config``, tolerating a corrupt map.

    A :class:`TextConfig` passes through unchanged, so callers that already
    sanitised the config (the viewport caches one per node) do not have to keep
    the raw map around just to re-parse it.
    """
    if isinstance(graph_config, TextConfig):
        return graph_config
    config = graph_config if isinstance(graph_config, dict) else {}
    return TextConfig(
        text=sanitise_text(config.get("text")),
        font_size=clamp_font_size(config.get("font_size", DEFAULT_FONT_SIZE)),
        align=normalise_align(config.get("align", DEFAULT_ALIGN)),
    )


def is_text_shape(shape_type: object) -> bool:
    """``True`` for ``shape_type: "TEXT"`` (tolerates ``None``/garbage)."""
    return str(shape_type or "") == "TEXT"


# ---------------------------------------------------------------------------
# Wrapping (pure — the Dart model reproduces this rule exactly)
# ---------------------------------------------------------------------------


def _split_long_word(word: str, max_width: float, font_size: float, measure: Measurer) -> list[str]:
    """Hard-splits a word that cannot fit on a line of its own.

    At least one character per chunk, otherwise a single glyph wider than the
    box would loop forever looking for a prefix that fits.
    """
    chunks: list[str] = []
    current = ""
    for char in word:
        candidate = current + char
        if current and measure(candidate, font_size) > max_width:
            chunks.append(current)
            current = char
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


def wrap_lines(
    text: str,
    max_width: float,
    measure: Measurer,
    font_size: float = DEFAULT_FONT_SIZE,
    max_lines: int | None = None,
) -> list[str]:
    """Greedy word wrap of ``text`` into lines no wider than ``max_width``.

    Explicit ``\\n`` always breaks a line and empty lines are preserved, because
    a user pressing Enter twice expects a blank line — not a collapsed one.
    Runs of spaces collapse to one (the wrap is word based), which is the only
    simplification that keeps this function identical to its Dart twin.

    An unusable ``max_width`` (zero, negative, non-finite) means "cannot
    measure", so the paragraphs come back unbroken rather than being chopped
    into one character per line.
    """
    usable = sanitise_text(text)
    if not usable.strip():
        # A whitespace-only box paints no ink, and the glyph passes would
        # otherwise lay down a blank line and report "drew something".
        return []
    paragraphs = usable.split("\n")
    try:
        width = float(max_width)
    except (TypeError, ValueError):
        width = 0.0
    if not math.isfinite(width) or width <= 0.0:
        return paragraphs[:max_lines] if max_lines is not None else paragraphs
    size = clamp_font_size(font_size)
    lines: list[str] = []
    for paragraph in paragraphs:
        if measure(paragraph, size) <= width:
            lines.append(paragraph)
            continue
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        line = ""
        for word in words:
            candidate = f"{line} {word}" if line else word
            if measure(candidate, size) <= width:
                line = candidate
                continue
            if line:
                lines.append(line)
                line = ""
            if measure(word, size) <= width:
                line = word
                continue
            chunks = _split_long_word(word, width, size, measure)
            lines.extend(chunks[:-1])
            line = chunks[-1] if chunks else ""
        lines.append(line)
    return lines[:max_lines] if max_lines is not None else lines


# ---------------------------------------------------------------------------
# Layout (pure)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class TextLayout:
    """Where each line of a text box goes, in world units."""

    lines: tuple[str, ...] = ()
    font_size: float = DEFAULT_FONT_SIZE
    line_height: float = DEFAULT_FONT_SIZE * LINE_HEIGHT_FACTOR
    align: str = DEFAULT_ALIGN
    #: Width of each line, index-aligned with :attr:`lines`.
    widths: tuple[float, ...] = field(default=())

    @property
    def is_empty(self) -> bool:
        return not any(line.strip() for line in self.lines)


def line_origin_x(
    left: float,
    right: float,
    line_width: float,
    align: str,
    padding: float = TEXT_PADDING,
) -> float:
    """Left edge of one line inside a box, honouring ``align``.

    ``padding`` is clamped to the box half-width so a text box narrower than
    twice the inset still centres on the box instead of inverting its edges.
    """
    pad = max(0.0, min(float(padding), max(0.0, (right - left) / 2.0)))
    if align == "center":
        return (left + right) / 2.0 - line_width / 2.0
    if align == "right":
        return right - pad - line_width
    return left + pad


def layout_text(
    config: TextConfig,
    box: tuple[float, float, float, float],
    measure: Measurer,
    *,
    padding: float = TEXT_PADDING,
    max_lines: int | None = None,
) -> TextLayout:
    """Wraps and measures one TEXT node inside ``box`` (``x0, y0, x1, y1``)."""
    x0, y0, x1, y1 = box
    left, right = min(x0, x1), max(x0, x1)
    inset = max(0.0, min(float(padding), (right - left) / 2.0))
    lines = tuple(
        wrap_lines(
            config.text,
            right - left - 2.0 * inset,
            measure,
            config.font_size,
            max_lines=max_lines,
        )
    )
    widths = tuple(max(0.0, measure(line, config.font_size)) for line in lines)
    return TextLayout(
        lines=lines,
        font_size=config.font_size,
        line_height=config.font_size * LINE_HEIGHT_FACTOR,
        align=config.align,
        widths=widths,
    )


def line_origins(
    layout: TextLayout,
    box: tuple[float, float, float, float],
    *,
    padding: float = TEXT_PADDING,
) -> list[tuple[float, float]]:
    """Top-left world point of every line, top-aligned inside the box."""
    x0, y0, x1, y1 = box
    left, right = min(x0, x1), max(x0, x1)
    top = min(y0, y1)
    inset = max(0.0, min(float(padding), max(0.0, (right - left) / 2.0)))
    return [
        (
            line_origin_x(left, right, width, layout.align, padding),
            top + inset + index * layout.line_height,
        )
        for index, width in enumerate(layout.widths)
    ]


# ---------------------------------------------------------------------------
# cairo glyph pass (exports + the GL texture bake)
# ---------------------------------------------------------------------------


def _select_font(ctx: cairo.Context, size: float) -> None:
    slant, weight = TEXT_FONT_FACE[1], TEXT_FONT_FACE[2]
    ctx.select_font_face(str(TEXT_FONT_FACE[0]), slant, weight)
    ctx.set_font_size(max(1e-3, float(size)))


def cairo_measurer(ctx: cairo.Context, size: float) -> Measurer:
    """A :data:`Measurer` backed by the current cairo toy font.

    ``x_advance`` rather than ``width``: the advance is what the next glyph
    starts after, so a wrapping decision based on it matches where the line
    actually ends — ``width`` excludes the trailing bearing and over-fills.
    """
    _select_font(ctx, size)

    def measure(text: str, font_size: float) -> float:
        if not text:
            return 0.0
        _select_font(ctx, font_size)
        return float(ctx.text_extents(text).x_advance)

    return measure


def parse_hex_rgb(colour: object) -> tuple[float, float, float]:
    """``#RGB`` / ``#RRGGBB`` → three 0..1 floats; anything else is black."""
    text = str(colour or "").strip().lstrip("#")
    if len(text) == 3:
        text = "".join(char * 2 for char in text)
    if len(text) != 6:
        return (0.0, 0.0, 0.0)
    try:
        return (
            int(text[0:2], 16) / 255.0,
            int(text[2:4], 16) / 255.0,
            int(text[4:6], 16) / 255.0,
        )
    except ValueError:
        return (0.0, 0.0, 0.0)


def normalise_box(box: object) -> tuple[float, float, float, float] | None:
    """Any 4-number bbox → ``(x0, y0, x1, y1)`` with ordered corners.

    ``None`` for malformed or non-finite input: a NaN edge would otherwise
    propagate into every glyph position and silently paint nothing.
    """
    if not isinstance(box, (list, tuple)) or len(box) < 4:
        return None
    try:
        x0, y0, x1, y1 = (float(value) for value in box[:4])
    except (TypeError, ValueError):
        return None
    if not all(math.isfinite(value) for value in (x0, y0, x1, y1)):
        return None
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def draw_text_box(
    ctx: cairo.Context,
    graph_config: object,
    box: tuple[float, float, float, float],
    colour: object = "#1E1E1E",
    opacity: float = 1.0,
    *,
    padding: float = TEXT_PADDING,
) -> bool:
    """Draws a TEXT node's glyphs into ``ctx``; ``True`` when ink was laid.

    The caller has already painted the box fill and outline — this pass only
    places the text, clipped to the box, so a long line cannot bleed over a
    neighbouring shape in an export.
    """
    config = text_config(graph_config)
    if config.is_empty:
        return False
    x0, y0, x1, y1 = box
    if x1 - x0 <= 0.0 or y1 - y0 <= 0.0:
        return False
    measure = cairo_measurer(ctx, config.font_size)
    layout = layout_text(config, box, measure, padding=padding)
    if layout.is_empty:
        return False
    red, green, blue = parse_hex_rgb(colour)
    # ``font_extents()[0]`` is the ascent: cairo's ``move_to`` sets the BASELINE,
    # while the layout works in top-left line boxes.
    _select_font(ctx, config.font_size)
    ascent = float(ctx.font_extents()[0])
    ctx.save()
    try:
        ctx.rectangle(x0, y0, x1 - x0, y1 - y0)
        ctx.clip()
        ctx.set_source_rgba(red, green, blue, max(0.0, min(1.0, float(opacity))))
        for line, (line_x, line_top) in zip(
            layout.lines, line_origins(layout, box, padding=padding)
        ):
            if not line:
                continue
            ctx.move_to(line_x, line_top + ascent)
            ctx.show_text(line)
    finally:
        ctx.restore()
    return True


def _raster_density(width: float, height: float, scale: float, max_px: int) -> float:
    """World → pixel factor for a text raster, reduced until BOTH edges fit.

    A per-axis factor would let the quad stretch the glyphs, so the smaller of
    the two ceilings wins: an unusually tall text box then renders at a lower
    density rather than a horizontally squashed one.
    """
    density = float(scale) if math.isfinite(float(scale)) and scale > 0 else RASTER_SCALE
    limit = float(max(1, int(max_px)))
    return max(1e-6, min(density, limit / max(width, 1e-6), limit / max(height, 1e-6)))


def rasterise_text(
    graph_config: object,
    box: Sequence[float],
    *,
    scale: float = RASTER_SCALE,
    padding: float = TEXT_PADDING,
    max_px: int = MAX_RASTER_PX,
) -> Image.Image | None:
    """Bakes a TEXT node into a WHITE RGBA mask for the GL texture pass.

    White with an alpha ramp (not the node colour) so the viewport can tint it
    through the existing ``u_tint`` uniform — that is what lets one cached
    texture serve the same text at any colour and both blend modes.

    The layout is computed in PIXEL space (box and padding scaled by the same
    density) so a line break lands where the exported glyphs actually end.
    """
    normalised = normalise_box(box)
    if normalised is None:
        return None
    config = text_config(graph_config)
    if config.is_empty:
        return None
    width = normalised[2] - normalised[0]
    height = normalised[3] - normalised[1]
    if width <= 0.0 or height <= 0.0:
        return None
    density = _raster_density(width, height, scale, max_px)
    px_w = max(1, int(math.ceil(width * density)))
    px_h = max(1, int(math.ceil(height * density)))
    surface = cairo.ImageSurface(cairo.FORMAT_A8, px_w, px_h)
    ctx = cairo.Context(surface)
    px_config = TextConfig(
        text=config.text,
        font_size=config.font_size * density,
        align=config.align,
    )
    measure = cairo_measurer(ctx, px_config.font_size)
    layout = layout_text(
        px_config, (0.0, 0.0, float(px_w), float(px_h)), measure, padding=padding * density
    )
    if layout.is_empty:
        return None
    _select_font(ctx, px_config.font_size)
    ascent = float(ctx.font_extents()[0])
    ctx.set_source_rgba(1.0, 1.0, 1.0, 1.0)
    for line, (line_x, line_top) in zip(
        layout.lines,
        line_origins(
            layout, (0.0, 0.0, float(px_w), float(px_h)), padding=padding * density
        ),
    ):
        if not line:
            continue
        ctx.move_to(line_x, line_top + ascent)
        ctx.show_text(line)
    surface.flush()
    stride = surface.get_stride()
    alpha = np.frombuffer(bytes(surface.get_data()), dtype=np.uint8)
    alpha = alpha.reshape(px_h, stride)[:, :px_w]
    if not alpha.any():
        return None
    rgb = np.full((px_h, px_w, 3), 255, dtype=np.uint8)
    return Image.fromarray(np.dstack([rgb, alpha]), mode="RGBA")


__all__ = [
    "ALIGNMENTS",
    "DEFAULT_ALIGN",
    "DEFAULT_FONT_SIZE",
    "LINE_HEIGHT_FACTOR",
    "MAX_FONT_SIZE",
    "MAX_RASTER_PX",
    "MIN_FONT_SIZE",
    "RASTER_SCALE",
    "TEXT_FONT_FACE",
    "TEXT_PADDING",
    "Measurer",
    "TextConfig",
    "TextLayout",
    "cairo_measurer",
    "clamp_font_size",
    "draw_text_box",
    "is_text_shape",
    "layout_text",
    "line_origin_x",
    "line_origins",
    "normalise_align",
    "normalise_box",
    "normalise_text",
    "parse_hex_rgb",
    "rasterise_text",
    "sanitise_text",
    "text_config",
    "wrap_lines",
]
