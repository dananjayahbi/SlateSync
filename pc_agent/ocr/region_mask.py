"""Round-12 issue 09 — free-drawn OCR selection → raster mask.

A rectangle is not the shape the user draws. The tablet sends a free-hand
polygon, and only the ink *inside* that outline may be recognised, so the mask
is what turns "scan this blob of the page" into a cropped, punched-out raster.

Two details matter and are cheap to get wrong:

* The outline is **grown by a stroke radius** before masking. A user circling a
  word draws *around* it, and the ink frequently touches the drawn line; a
  zero-width test would clip the first and last glyph.
* The mask is applied by pasting onto **white**, not by making pixels
  transparent. PP-OCR's recogniser was trained on white paper; transparent
  pixels would arrive as black and destroy contrast.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence

#: How far the user's outline is expanded before masking, in world/px units.
#: One glyph stroke width is a good proxy for "circled loosely".
DEFAULT_GROW = 6.0

#: A polygon needs at least three distinct points to enclose anything.
MIN_POLYGON_POINTS = 3

Point = tuple[float, float]


def _as_points(points: Iterable[Sequence[float]] | None) -> list[Point]:
    """Coerce loose wire data into a clean point list, dropping junk."""
    if not points:
        return []
    cleaned: list[Point] = []
    for item in points:
        try:
            x = float(item[0])
            y = float(item[1])
        except (TypeError, ValueError, IndexError):
            continue
        if math.isfinite(x) and math.isfinite(y):
            cleaned.append((x, y))
    return cleaned


def polygon_bounds(
    points: Iterable[Sequence[float]] | None,
) -> tuple[float, float, float, float] | None:
    """Axis-aligned bounds of [points], or `None` when there is no area."""
    pts = _as_points(points)
    if len(pts) < MIN_POLYGON_POINTS:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    box = (min(xs), min(ys), max(xs), max(ys))
    if box[2] - box[0] < 1.0 or box[3] - box[1] < 1.0:
        return None
    return box


def is_usable_polygon(points: Iterable[Sequence[float]] | None) -> bool:
    """True when [points] could enclose something (not a dot or a line)."""
    return polygon_bounds(points) is not None


@dataclass(frozen=True)
class RegionCrop:
    """A raster crop plus where it came from, in source-image pixels."""

    image: object  # PIL.Image.Image
    #: Offset of the crop's top-left within the source image, in pixels.
    offset: tuple[float, float]
    #: Bounds of the selection in source pixels — `(x0, y0, x1, y1)`.
    bounds: tuple[float, float, float, float]


def crop_to_polygon(
    source: object,
    points: Iterable[Sequence[float]] | None,
    *,
    scale: float = 1.0,
    grow: float = DEFAULT_GROW,
) -> RegionCrop | None:
    """Crop [source] to the polygon's bounds and blank everything outside it.

    [points] are in world/source coordinates; [scale] converts them to the
    raster's pixel space (the caller rasterises at some export DPI). Returns
    `None` when the polygon cannot enclose anything, so callers can report a
    real "nothing selected" error instead of scanning the whole page.
    """
    from PIL import Image, ImageDraw

    pts = _as_points(points)
    bounds = polygon_bounds(pts)
    if bounds is None:
        return None

    scale = float(scale) if math.isfinite(float(scale)) and scale > 0 else 1.0
    grow_px = max(0.0, float(grow) * scale)

    if not isinstance(source, Image.Image):
        source = Image.fromarray(source)

    # Pad by the grow radius so the expanded outline is not clipped.
    x0 = max(0.0, bounds[0] * scale - grow_px)
    y0 = max(0.0, bounds[1] * scale - grow_px)
    x1 = min(float(source.width), bounds[2] * scale + grow_px)
    y1 = min(float(source.height), bounds[3] * scale + grow_px)
    if x1 - x0 < 1.0 or y1 - y0 < 1.0:
        return None

    left, top = int(math.floor(x0)), int(math.floor(y0))
    right, bottom = int(math.ceil(x1)), int(math.ceil(y1))
    right = min(right, source.width)
    bottom = min(bottom, source.height)
    if right - left < 1 or bottom - top < 1:
        return None

    crop = source.crop((left, top, right, bottom)).convert("RGB")

    # Outline shifted into crop space, grown by the stroke radius.
    local = [(p[0] * scale - left, p[1] * scale - top) for p in pts]
    mask = Image.new("L", crop.size, 0)
    drawer = ImageDraw.Draw(mask)
    drawer.polygon(local, fill=255, outline=255)
    if grow_px >= 1.0:
        # `ImageDraw.line` with a width approximates dilation cheaply and is
        # all that is needed to keep ink touching the outline.
        closed = local + [local[0]]
        drawer.line(closed, fill=255, width=int(round(grow_px * 2)))

    white = Image.new("RGB", crop.size, (255, 255, 255))
    # White background, not transparency: the recogniser expects paper.
    masked = Image.composite(crop, white, mask)

    return RegionCrop(
        image=masked,
        offset=(float(left), float(top)),
        bounds=(float(left), float(top), float(right), float(bottom)),
    )
