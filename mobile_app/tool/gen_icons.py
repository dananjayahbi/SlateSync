"""Generate the SlateSync launcher/app icons from one shared design.

Design (must match the PC executable icon):
  * Full-bleed canvas with a vertical gradient #121212 -> #1E1E1E.
  * A bold, tapered diagonal stylus stroke in accent #4F8EF7 sweeping
    from bottom-left to top-right, ending in a sharp nib-like tip.
  * No text (unreadable at launcher sizes); the stroke stays inside the
    legacy circular safe zone (max radial extent <= 0.45 of the canvas).

Outputs:
  * Android legacy mipmaps (opaque full-bleed squares):
      android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png
  * iOS AppIcon.appiconset entries (opaque, per existing Contents.json).
  * Source master: assets/branding/icon_1024.png (rounded-square RGBA).

Usage:
  python tool/gen_icons.py                 # generate everything
  python tool/gen_icons.py --target android
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# ---------------------------------------------------------------- design tokens

GRADIENT_TOP = (0x12, 0x12, 0x12)     # #121212
GRADIENT_BOTTOM = (0x1E, 0x1E, 0x1E)  # #1E1E1E
ACCENT = (0x4F, 0x8E, 0xF7)           # #4F8EF7

# Stroke path (normalized quadratic bezier): bottom-left -> top-right sweep.
_P0 = (0.24, 0.76)
_P1 = (0.42, 0.42)
_P2 = (0.76, 0.24)
_MAX_HALF_WIDTH = 0.055   # bold head width, fraction of canvas
_TIP_FLOOR = 0.03         # keeps the nib from vanishing after downsampling
_STROKE_SAMPLES = 200
_CORNER_RADIUS = 0.22     # rounded-square radius for the source master only
_SAFE_ZONE_MAX = 0.45     # radial extent budget (legacy circle mask awareness)

# Android densities (legacy icons: opaque, full-bleed squares).
ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

MOBILE_APP_DIR = Path(__file__).resolve().parents[1]


# --------------------------------------------------------------------- geometry

def _bezier(t: float) -> tuple[float, float]:
    """Quadratic bezier point at parameter t (normalized coordinates)."""
    u = 1.0 - t
    return (
        u * u * _P0[0] + 2 * u * t * _P1[0] + t * t * _P2[0],
        u * u * _P0[1] + 2 * u * t * _P1[1] + t * t * _P2[1],
    )


def _half_width(t: float) -> float:
    """Taper profile: full width at the tail, nib point at the tip."""
    return _MAX_HALF_WIDTH * max((1.0 - t) ** 0.8, _TIP_FLOOR)


def _stroke_outline() -> list[tuple[float, float]]:
    """Closed tapered-stroke polygon in normalized (0..1) coordinates."""
    n = _STROKE_SAMPLES
    ts = [i / n for i in range(n + 1)]
    pts = [_bezier(t) for t in ts]

    left: list[tuple[float, float]] = []
    right: list[tuple[float, float]] = []
    for i, t in enumerate(ts):
        # Finite-difference tangent.
        x, y = pts[i]
        x0, y0 = pts[max(i - 1, 0)]
        x1, y1 = pts[min(i + 1, n)]
        tx, ty = x1 - x0, y1 - y0
        mag = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / mag, tx / mag  # normal
        h = _half_width(t)
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))

    # Rounded tail cap, traced from the right flank back to the left flank
    # (phi 180 deg ~ right[0], phi 90 deg ~ behind the tail, 0 deg ~ left[0]).
    x, y = pts[0]
    tx, ty = pts[1][0] - x, pts[1][1] - y
    mag = math.hypot(tx, ty) or 1.0
    tx, ty = tx / mag, ty / mag
    nx, ny = -ty, tx
    cap: list[tuple[float, float]] = []
    for k in range(1, 180):  # 1..179 deg; ends land just inside left/right[0]
        phi = math.radians(k)
        cap.append((
            x + (nx * math.cos(phi) - tx * math.sin(phi)) * _MAX_HALF_WIDTH,
            y + (ny * math.cos(phi) - ty * math.sin(phi)) * _MAX_HALF_WIDTH,
        ))

    # left(tail->tip) -> right(tip->tail) -> cap(right->left) closes the shape.
    outline = left + list(reversed(right)) + list(reversed(cap))

    # Guard: legacy launchers mask to a circle; keep everything aware of it.
    extent = max(math.hypot(px - 0.5, py - 0.5) for px, py in outline)
    if extent > _SAFE_ZONE_MAX:
        raise ValueError(f"stroke exceeds safe zone: {extent:.3f} > {_SAFE_ZONE_MAX}")
    return outline


def _supersample(size: int) -> int:
    """Sample factor so small icons still get smooth, crisp edges."""
    return max(4, min(16, math.ceil(768 / size)))


# --------------------------------------------------------------------- rendering

def _vertical_gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (1, size))
    rows = [
        tuple(round(a + (b - a) * (y / max(size - 1, 1)))
              for a, b in zip(GRADIENT_TOP, GRADIENT_BOTTOM))
        for y in range(size)
    ]
    img.putdata(rows)
    return img.resize((size, size), Image.NEAREST)


def _stroke_mask(size: int) -> Image.Image:
    ss = _supersample(size)
    edge = size * ss
    mask = Image.new("L", (edge, edge), 0)
    draw = ImageDraw.Draw(mask)
    polygon = [(px * edge, py * edge) for px, py in _stroke_outline()]
    draw.polygon(polygon, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def _rounded_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    r = round(_CORNER_RADIUS * size)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=r, fill=255
    )
    return mask


def render_icon(size: int, *, rounded: bool = False) -> Image.Image:
    """Render the shared design at `size` px.

    rounded=False -> opaque full-bleed square (Android legacy / iOS; the
    platform applies its own mask). rounded=True -> RGBA rounded-square
    master for reuse outside the launchers.
    """
    base = _vertical_gradient(size)
    icon = Image.composite(Image.new("RGB", (size, size), ACCENT), base, _stroke_mask(size))
    if rounded:
        icon = icon.convert("RGBA")
        icon.putalpha(_rounded_mask(size))
    return icon


# ------------------------------------------------------------------------ writers

def _save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")
    print(f"  wrote {path.relative_to(MOBILE_APP_DIR)} ({img.size[0]}x{img.size[1]})")


def write_android() -> list[Path]:
    res = MOBILE_APP_DIR / "android" / "app" / "src" / "main" / "res"
    outputs = []
    for density, size in ANDROID_DENSITIES.items():
        path = res / f"mipmap-{density}" / "ic_launcher.png"
        _save(render_icon(size).convert("RGB"), path)
        outputs.append(path)
    return outputs


def write_source() -> list[Path]:
    path = MOBILE_APP_DIR / "assets" / "branding" / "icon_1024.png"
    _save(render_icon(1024, rounded=True), path)
    return [path]


def write_ios() -> list[Path]:
    iconset = (MOBILE_APP_DIR / "ios" / "Runner" / "Assets.xcassets"
               / "AppIcon.appiconset")
    contents_path = iconset / "Contents.json"
    if not contents_path.is_file():
        print("  iOS Contents.json missing; skipping iOS icons")
        return []
    entries = json.loads(contents_path.read_text(encoding="utf-8"))["images"]
    outputs = []
    for entry in entries:
        if "filename" not in entry:
            continue
        base = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = round(base * scale)
        path = iconset / entry["filename"]
        _save(render_icon(px).convert("RGB"), path)
        outputs.append(path)
    return outputs


# -------------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate SlateSync app icons")
    parser.add_argument(
        "--target",
        choices=("all", "android", "ios", "source"),
        default="all",
        help="which icon set to generate (default: all)",
    )
    args = parser.parse_args(argv)

    print("SlateSync icon generator")
    if args.target in ("all", "android"):
        print("Android mipmaps:")
        write_android()
    if args.target in ("all", "ios"):
        print("iOS AppIcon set:")
        write_ios()
    if args.target in ("all", "source"):
        print("Source master:")
        write_source()
    return 0


if __name__ == "__main__":
    sys.exit(main())
