"""Generate pc_agent/assets/slatesync.ico — SlateSync PC branding (Issue 05).

Design (matches the mobile mark):
  * rounded-square tile, vertical gradient #121212 -> #1E1E1E
  * bold accent #4F8EF7 tapered "stylus nib" stroke sweeping
    bottom-left -> top-right (pressure-thick, sharp at the tip)
  * stroke-only final mark: the optional subtle white "S" (``render(with_s)``
    keeps the experiment) previews muddy under the sweep at 256 px and
    contributes nothing at 16 px, so the shipping ICO omits it

The ICO embeds PNG-compressed entries for 16/32/48/64/256 px (hand-built
container: Pillow's ICO writer emits BMP entries, so the directory is
assembled here and every payload is encoded as PNG).

Usage:
    python pc_agent/assets/gen_branding.py            # write slatesync.ico
    python pc_agent/assets/gen_branding.py --preview  # + _preview_*.png
"""

from __future__ import annotations

import argparse
import io
import math
import os
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZES = (16, 32, 48, 64, 256)
ACCENT = (79, 142, 247, 255)  # #4F8EF7
GRAD_TOP = (0x12, 0x12, 0x12)
GRAD_BOTTOM = (0x1E, 0x1E, 0x1E)
_SUPERSAMPLE = 4  # draw at 4x, downscale -> clean AA at every size
OUT_NAME = "slatesync.ico"


def _font(px: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """Segoe UI Bold (Windows), then Arial Bold, then PIL's bitmap default."""
    windir = os.environ.get("WINDIR", r"C:\Windows")
    for name in ("segoeuib.ttf", "arialbd.ttf"):
        path = os.path.join(windir, "Fonts", name)
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, px)
            except OSError:  # pragma: no cover - corrupt font file
                continue
    return ImageFont.load_default()


def _gradient_tile(n: int) -> Image.Image:
    """n x n RGBA rounded tile with the vertical #121212 -> #1E1E1E gradient."""
    grad = Image.new("RGB", (1, n))
    px = grad.load()
    for y in range(n):
        t = y / max(n - 1, 1)
        px[0, y] = tuple(
            round(a + (b - a) * t) for a, b in zip(GRAD_TOP, GRAD_BOTTOM)
        )
    tile = grad.resize((n, n), Image.Resampling.BILINEAR).convert("RGBA")
    mask = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, n - 1, n - 1), radius=round(n * 0.22), fill=255)
    tile.putalpha(mask)
    return tile


def _stroke_points(p0: tuple[float, float], p1: tuple[float, float],
                   bend: float, width: float, steps: int) -> list[tuple[float, float]]:
    """Closed polygon of a tapered quadratic stroke from p0 (thick) to p1 (tip).

    Width profile peaks early (pressure at the nib) and tapers to a sharp
    point at p1, giving the stylus-sweep silhouette.
    """
    cx = (p0[0] + p1[0]) / 2 - (p1[1] - p0[1]) * bend
    cy = (p0[1] + p1[1]) / 2 + (p1[0] - p0[0]) * bend

    def pt(t: float) -> tuple[float, float]:
        u = 1 - t
        return (u * u * p0[0] + 2 * u * t * cx + t * t * p1[0],
                u * u * p0[1] + 2 * u * t * cy + t * t * p1[1])

    def wid(t: float) -> float:
        # peak near t=0.3, sharp taper into the tip; thin start = nib edge
        return width * (t**0.4) * ((1.0 - t) ** 0.85) / 0.385

    centers = [pt(i / steps) for i in range(steps + 1)]
    left: list[tuple[float, float]] = []
    right: list[tuple[float, float]] = []
    for i, (x, y) in enumerate(centers):
        t = i / steps
        if i == 0:
            dx, dy = centers[1][0] - x, centers[1][1] - y
        elif i == steps:
            dx, dy = x - centers[-2][0], y - centers[-2][1]
        else:
            dx, dy = (centers[i + 1][0] - centers[i - 1][0],
                      centers[i + 1][1] - centers[i - 1][1])
        length = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / length, dx / length
        half = wid(t) / 2
        left.append((x + nx * half, y + ny * half))
        right.append((x - nx * half, y - ny * half))
    tip = centers[-1]  # close on the sharp tip
    return left + [tip] + list(reversed(right))


def render(size: int, with_s: bool = True) -> Image.Image:
    """Render the branded tile at ``size`` px (RGBA)."""
    s = size * _SUPERSAMPLE
    img = _gradient_tile(s)
    draw = ImageDraw.Draw(img)

    if with_s and size >= 32:  # the S only reads at >=32 px
        font = _font(round(s * 0.62))
        text = "S"
        box = draw.textbbox((0, 0), text, font=font)
        tw, th = box[2] - box[0], box[3] - box[1]
        draw.text(((s - tw) / 2 - box[0], (s - th) / 2 - box[1] - s * 0.01),
                  text, font=font, fill=(255, 255, 255, 70))  # subtle

    # stylus stroke: bottom-left -> top-right, slightly bowed
    margin = s * 0.16
    poly = _stroke_points(
        (margin, s - margin), (s - margin, margin),
        bend=0.10, width=s * 0.15, steps=64,
    )
    draw.polygon(poly, fill=ACCENT)

    return img.resize((size, size), Image.Resampling.LANCZOS)


def write_ico(path: Path, sizes: tuple[int, ...] = SIZES, with_s: bool = True) -> None:
    """Assemble a multi-size ICO whose entries are PNG-compressed."""
    payloads: list[bytes] = []
    for n in sizes:
        buf = io.BytesIO()
        render(n, with_s=with_s).save(buf, format="PNG")
        payloads.append(buf.getvalue())

    header = struct.pack("<HHH", 0, 1, len(sizes))  # reserved, type=icon, count
    offset = 6 + 16 * len(sizes)
    directory = b""
    for n, data in zip(sizes, payloads):
        dim = 0 if n >= 256 else n  # 0 encodes 256 in the classic directory
        directory += struct.pack(
            "<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + directory + b"".join(payloads))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true",
                        help="also write _preview_{16,32,256}*.png for review")
    args = parser.parse_args()

    out = Path(__file__).resolve().parent / OUT_NAME
    # Final mark: stroke-only — the white "S" previews muddy under the sweep
    # at 256 px and contributes nothing at 16 px (size gate skips it there).
    write_ico(out, with_s=False)
    print(f"wrote {out} ({out.stat().st_size} bytes, sizes={SIZES}, PNG entries)")

    if args.preview:
        for n in (16, 32, 256):
            for with_s, tag in ((False, ""), (True, "_s")):
                p = out.parent / f"_preview_{n}{tag}.png"
                render(n, with_s=with_s).save(p)
                print(f"preview {p.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
