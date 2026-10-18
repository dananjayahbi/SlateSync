#!/usr/bin/env python3
"""Doc 28 §4 — export_verify: 600 DPI infinite lossless + PDF vector QA.

Builds two in-memory fixtures (Docs 09/10): an A5-bounded document (strokes +
GRAPH_AXES inside 1748×2480) and an INFINITE document with
``content_bounds (−2000,−1500)–(8000,6000)`` (HIGHLIGHT multiply + IMAGE),
then runs the read-only exporters (Doc 13 TiledRasterExporter, Doc 14
VectorPdfExporter) at 300/600/1200 DPI for PNG/JPG plus a vector PDF.

Assertions (Doc 28 §4): raster W×H == round(world_extent * dpi / 300) ± 1 px
evaluated at the artifact canvas level with the template §3 strip constant
(2048×2048) applied — files are strip-padded by Doc 13 ``extent_to_px``;
pre-strip unit-math precision is enforced by Doc 13 ``test_dim_formula_a5``
in the pytest gate. PDF: ``%PDF`` magic, first-page extent == page world ×
72/300 pt (Doc 14 page policy: bounded ⇒ artboard; INFINITE ⇒ content_bounds
± 48/side, Doc 14 §4). Every real artifact must be larger than the same
export of an empty fixture (non-trivial guard, no hardcoded byte floor).

Exit 0 iff zero failed rows / 1 otherwise (Doc 28 §4).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import zlib
from pathlib import Path
from uuid import uuid4

from PIL import Image

_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from pc_agent.core.config_manager import AppConfig  # noqa: E402
from pc_agent.engine.document_store import Artboard, CanvasDocument  # noqa: E402
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle  # noqa: E402
from pc_agent.export.tiled_raster_exporter import STRIP_PX, TiledRasterExporter  # noqa: E402
from pc_agent.export.vector_pdf_exporter import UNIT_TO_PT, VectorPdfExporter  # noqa: E402

#: Template §3 DPI set (raster); PDF is vector but exercised once per fixture.
DPIS: tuple[int, ...] = (300, 600, 1200)
#: Fixture world extents (Doc 28 §4 parentheticals).
A5_WORLD = (1748.0, 2480.0)
INFINITE_WORLD = (10000.0, 7500.0)
#: Doc 14 §4 page pad for INFINITE canvases (world units per side).
_PDF_EXTENT_PAD = 48.0
#: Doc 14 test tolerance for MediaBox sizes in points.
_PT_TOLERANCE = 0.5
_PNG_MAGIC = b"\x89PNG"
_JPG_MAGIC = b"\xff\xd8\xff"
_PDF_MAGIC = b"%PDF"
_MEDIABOX_RE = rb"/MediaBox\s*\[\s*[-\d.]+\s+[-\d.]+\s+([-\d.]+)\s+([-\d.]+)\s*\]"

_A5_CHAIN = [
    [150.0, 300.0],
    [350.0, 500.0],
    [600.0, 420.0],
    [850.0, 650.0],
    [1100.0, 560.0],
    [1350.0, 780.0],
    [1550.0, 700.0],
]
_A5_ANCHORS = [[200.0, 1800.0], [500.0, 2050.0], [900.0, 1900.0]]
_INF_CHAIN = [
    [-2000.0, -1500.0],
    [-500.0, -400.0],
    [1000.0, 700.0],
    [2500.0, 1800.0],
    [4000.0, 2900.0],
    [5500.0, 4000.0],
    [7000.0, 5100.0],
]
_INF_HIGHLIGHT = [
    [-1500.0, -800.0],
    [0.0, -200.0],
    [1500.0, 300.0],
    [3000.0, 800.0],
    [4500.0, 1300.0],
    [6000.0, 1800.0],
    [7500.0, 2300.0],
]
_ZERO_BOUNDS = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
_INFINITE_BOUNDS = {"min_x": -2000.0, "min_y": -1500.0, "max_x": 8000.0, "max_y": 6000.0}


def _bbox(pts: list[list[float]]) -> tuple[float, float, float, float]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def _node(
    kind: str,
    pts: list[list[float]],
    *,
    bbox: tuple[float, float, float, float] | None = None,
    color: str = "#1E1E1E",
    stroke_width: float = 6.0,
    opacity: float = 1.0,
    blend_mode: str = "SRC_OVER",
    shape_type: str | None = None,
    graph_config: dict | None = None,
    asset_ref: str | None = None,
) -> CanvasNode:
    if bbox is None:
        bbox = _bbox(pts) if pts else (0.0, 0.0, 0.0, 0.0)
    return CanvasNode(
        node_id=f"qa-{kind.lower()}-{uuid4().hex[:8]}",
        kind=kind,
        layer=0,
        bbox=bbox,
        style=NodeStyle(
            color=color, stroke_width=stroke_width, opacity=opacity, blend_mode=blend_mode
        ),
        geometry=NodeGeometry(
            pts=pts, shape_type=shape_type, graph_config=graph_config, asset_ref=asset_ref
        ),
    )


def build_a5_fixture(elements: list[CanvasNode] | None = None) -> CanvasDocument:
    """A5-bounded Doc 28 §4 fixture: strokes + GRAPH_AXES inside 1748×2480."""
    if elements is None:
        graph_bbox = (274.0, 640.0, 1474.0, 1840.0)
        elements = [
            _node("STROKE", _A5_CHAIN, color="#E03030"),
            _node("STROKE", _A5_ANCHORS, color="#1E1E1E", stroke_width=4.0),
            _node(
                "GRAPH_AXES",
                [],
                bbox=graph_bbox,
                color="#2050C0",
                stroke_width=2.0,
                shape_type="CARTESIAN_2D",
                graph_config={
                    "origin": [874.0, 1240.0],
                    "x_range": [-6.0, 6.0],
                    "y_range": [-6.0, 6.0],
                    "grid_step": 100.0,
                    "show_labels": True,
                },
            ),
        ]
    return CanvasDocument(
        canvas_id=f"qa-a5-{uuid4().hex[:8]}",
        title="qa A5 fixture",
        created_at=0,
        updated_at=0,
        artboard=Artboard(preset="A5", width=1748.0, height=2480.0, is_infinite=False),
        content_bounds=dict(_ZERO_BOUNDS),
        elements=list(elements),
    )


def build_infinite_fixture(
    elements: list[CanvasNode] | None = None, *, assets_dir: Path | None = None
) -> CanvasDocument:
    """INFINITE Doc 28 §4 fixture: content_bounds ±10000×7500 world span,
    HIGHLIGHT (multiply) + IMAGE node (+ strokes)."""
    if elements is None:
        elements = [
            _node("STROKE", _INF_CHAIN, color="#1060C0", stroke_width=8.0),
            _node(
                "HIGHLIGHT",
                _INF_HIGHLIGHT,
                color="#FFFF00",
                opacity=0.5,
                stroke_width=40.0,
            ),
            _node(
                "IMAGE",
                [],
                bbox=(5500.0, 3500.0, 6700.0, 4700.0),
                asset_ref="photo.png",
            ),
        ]
    canvas_id = f"qa-inf-{uuid4().hex[:8]}"
    if assets_dir is not None:
        asset_path = assets_dir / canvas_id / "photo.png"
        asset_path.parent.mkdir(parents=True, exist_ok=True)
        if not asset_path.exists():
            _write_placeholder_image(asset_path)
    return CanvasDocument(
        canvas_id=canvas_id,
        title="qa INFINITE fixture",
        created_at=0,
        updated_at=0,
        artboard=Artboard(preset="INFINITE", width=None, height=None, is_infinite=True),
        content_bounds=dict(_INFINITE_BOUNDS),
        elements=list(elements),
    )


def _write_placeholder_image(path: Path) -> None:
    """Small deterministic PNG asset so the IMAGE node actually renders."""
    img = Image.new("RGB", (128, 128))
    px = img.load()
    for y in range(128):
        for x in range(128):
            px[x, y] = ((x * 2) % 256, (y * 2) % 256, ((x + y) % 128) + 64)
    img.save(path, format="PNG")


def expected_px(extent: float, dpi: int) -> int:
    """Doc 28 §5: ``round(extent * dpi / 300)`` (content px, pre-strip)."""
    return round(extent * dpi / 300)


def expected_canvas_px(world: tuple[float, float], dpi: int) -> tuple[int, int]:
    """Content px padded up to strip multiples of 2048 (template §3)."""
    w = expected_px(world[0], dpi)
    h = expected_px(world[1], dpi)
    return (math.ceil(w / STRIP_PX) * STRIP_PX, math.ceil(h / STRIP_PX) * STRIP_PX)


def expected_pt(extent: float) -> float:
    """Doc 28 §5: ``extent * 72 / 300`` (world extent → PDF points)."""
    return extent * UNIT_TO_PT


def expected_page_pt(world: tuple[float, float], infinite: bool) -> tuple[float, float]:
    """Page size per Doc 14 §4 policy: bounded ⇒ artboard; INFINITE ⇒
    content_bounds padded ±48/side."""
    w, h = world
    if infinite:
        w += 2 * _PDF_EXTENT_PAD
        h += 2 * _PDF_EXTENT_PAD
    return (expected_pt(w), expected_pt(h))


def pdf_page_sizes(path: Path) -> list[tuple[float, float]]:
    """First/all MediaBox page sizes (pt) — cairo stores pages in ObjStm
    streams (technique mirrored from Doc 14's acceptance suite, no pypdf)."""
    data = path.read_bytes()
    sizes: list[tuple[float, float]] = []
    for match in re.finditer(rb"stream\r?\n", data):
        start = match.end()
        end = data.find(b"endstream", start)
        if end < 0:
            continue
        try:
            inflated = zlib.decompress(data[start:end])
        except zlib.error:
            continue
        for mb in re.finditer(_MEDIABOX_RE, inflated):
            sizes.append((float(mb.group(1)), float(mb.group(2))))
    if not sizes:
        for mb in re.finditer(_MEDIABOX_RE, data):
            sizes.append((float(mb.group(1)), float(mb.group(2))))
    return sizes


def _magic_ok(head: bytes, kind: str) -> bool:
    if kind == "PNG":
        return head.startswith(_PNG_MAGIC)
    if kind == "JPG":
        return head.startswith(_JPG_MAGIC)
    return head.startswith(_PDF_MAGIC)


def _head(path: Path, n: int = 8) -> bytes:
    with path.open("rb") as fh:
        return fh.read(n)


def _raster_size(path: Path) -> tuple[int, int]:
    """Canvas W×H read straight from the artifact header.

    Not ``PIL.Image.open``: its decompression-bomb guard (default cap
    ~179 MP) rejects the INFINITE 600/1200 DPI canvases (335 MP / 1.26 GP)
    during a header-only read, which is exactly the ladder Doc 28 §4 demands.
    """
    with path.open("rb") as fh:
        head = fh.read(24)
    if head.startswith(_PNG_MAGIC) and head[12:16] == b"IHDR":
        return (int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big"))
    with path.open("rb") as fh:
        data = fh.read()
    if not data.startswith(_JPG_MAGIC):
        raise ValueError(f"unrecognized raster header in {path}")
    pos = 2  # after SOI
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            pos += 1
            continue
        marker = data[pos + 1]
        if marker == 0xFF:  # fill byte
            pos += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            pos += 2
            continue
        if marker == 0xD9 or marker == 0xDA:  # EOI/SOS before SOF
            break
        seg_len = int.from_bytes(data[pos + 2 : pos + 4], "big")
        is_sof = 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC)
        if is_sof:
            height = int.from_bytes(data[pos + 5 : pos + 7], "big")
            width = int.from_bytes(data[pos + 7 : pos + 9], "big")
            return (width, height)
        pos += 2 + seg_len
    raise ValueError(f"no SOF marker in {path}")


def _row(
    fixture: str,
    kind: str,
    dpi: str,
    got: str,
    expected: str,
    size_bytes: int,
    magic: str,
    passed: bool,
    detail: str = "",
) -> dict:
    return {
        "fixture": fixture,
        "kind": kind,
        "dpi": dpi,
        "got": got,
        "expected": expected,
        "bytes": size_bytes,
        "magic": magic,
        "result": "PASS" if passed else "FAIL",
        "detail": detail,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="export_verify.py",
        description="Doc 28 §4 export verification (raster DPI ladder + vector PDF).",
    )
    parser.add_argument(
        "--out-dir",
        default=str(Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "exports"),
        help="export root (default %%APPDATA%%/SlateSync/exports)",
    )
    parser.add_argument("--json", dest="json_out", default=None, metavar="OUT",
                        help="write results JSON to OUT")
    args = parser.parse_args(argv)

    out_dir = Path(args.out_dir) / "qa"
    out_dir.mkdir(parents=True, exist_ok=True)
    config = AppConfig(
        shader_dir=out_dir / "shaders",
        assets_dir=out_dir / "assets",
        export_dir=out_dir,
        appdata_dir=out_dir / "appdata",
    )

    fixtures = [
        ("A5", build_a5_fixture(), build_a5_fixture(elements=[]), A5_WORLD, False),
        (
            "INFINITE",
            build_infinite_fixture(assets_dir=config.assets_dir),
            build_infinite_fixture(elements=[], assets_dir=config.assets_dir),
            INFINITE_WORLD,
            True,
        ),
    ]

    raster = TiledRasterExporter(config)
    vector = VectorPdfExporter(config)
    rows: list[dict] = []
    # 2 fixtures × (3 DPI × 2 raster kinds × real+empty + PDF real+empty) = 28
    total_steps = len(fixtures) * (len(DPIS) * 2 * 2 + 2)
    counter = {"n": 0}

    def log(msg: str, t0: float) -> None:
        print(f"[{counter['n']}/{total_steps}] {msg} ({time.monotonic() - t0:.1f}s)",
              flush=True)

    for name, doc, empty_doc, world, infinite in fixtures:
        slug = name.lower()
        for ext, kind_name in (("png", "PNG"), ("jpg", "JPG")):
            for dpi in DPIS:
                real_path = out_dir / f"{slug}_{dpi}.{ext}"
                base_path = out_dir / f"{slug}_{dpi}_empty.{ext}"
                # baseline first so the real row's >empty guard is non-vacuous
                t0 = time.monotonic()
                counter["n"] += 1
                raster.export(empty_doc, dpi, base_path)
                log(f"{name}-empty {kind_name} {dpi} DPI export", t0)
                t0 = time.monotonic()
                counter["n"] += 1
                raster.export(doc, dpi, real_path)
                log(f"{name} {kind_name} {dpi} DPI export", t0)

                exp = expected_canvas_px(world, dpi)
                content_w = expected_px(world[0], dpi)
                content_h = expected_px(world[1], dpi)
                base_size = base_path.stat().st_size
                for label, path, is_real in (
                    (f"{name}-empty", base_path, False),
                    (name, real_path, True),
                ):
                    got = _raster_size(path)
                    dims_ok = abs(got[0] - exp[0]) <= 1 and abs(got[1] - exp[1]) <= 1
                    covers = got[0] >= content_w - 1 and got[1] >= content_h - 1
                    head = _head(path, 4)
                    magic_ok = _magic_ok(head, kind_name)
                    size = path.stat().st_size
                    bigger = (size > base_size) if is_real else True
                    passed = dims_ok and covers and magic_ok and bigger
                    rows.append(
                        _row(
                            label,
                            kind_name,
                            str(dpi),
                            f"{got[0]}x{got[1]}",
                            f"{exp[0]}x{exp[1]}",
                            size,
                            f"{kind_name} {'ok' if magic_ok else 'BAD ' + head.hex()}",
                            passed,
                            detail=(
                                f"content px {content_w}x{content_h}; "
                                f"empty {base_size} B; covers={covers}; "
                                f">empty={bigger}"
                            ),
                        )
                    )
        # vector PDF per fixture — empty baseline exported before the real row
        base_pdf = out_dir / f"{slug}_vector_empty.pdf"
        real_pdf = out_dir / f"{slug}_vector.pdf"
        t0 = time.monotonic()
        counter["n"] += 1
        vector.export(empty_doc, base_pdf)
        log(f"{name}-empty PDF export", t0)
        t0 = time.monotonic()
        counter["n"] += 1
        vector.export(doc, real_pdf)
        log(f"{name} PDF export", t0)

        exp_w, exp_h = expected_page_pt(world, infinite)
        exp_str = f"{exp_w:.2f}x{exp_h:.2f}pt"
        base_size = base_pdf.stat().st_size
        for label, path, is_real in (
            (f"{name}-empty", base_pdf, False),
            (name, real_pdf, True),
        ):
            head = _head(path, 4)
            magic_ok = _magic_ok(head, "PDF")
            size = path.stat().st_size
            pages = pdf_page_sizes(path)
            if pages:
                got_w, got_h = pages[0]
                dims_ok = (
                    abs(got_w - exp_w) <= _PT_TOLERANCE
                    and abs(got_h - exp_h) <= _PT_TOLERANCE
                )
                got_str = f"{got_w:.2f}x{got_h:.2f}pt"
            else:
                dims_ok = False
                got_str = "no MediaBox"
            bigger = (size > base_size) if is_real else True
            passed = magic_ok and dims_ok and bigger
            rows.append(
                _row(
                    label,
                    "PDF",
                    "-",
                    got_str,
                    exp_str,
                    size,
                    f"%PDF {'ok' if magic_ok else 'BAD ' + head.hex()}",
                    passed,
                    detail=f"pages={len(pages)}; empty {base_size} B; >empty={bigger}",
                )
            )

    failed = [r for r in rows if r["result"] == "FAIL"]
    print()
    header = (
        f"{'FIXTURE':<12} | {'KIND':<4} | {'DPI':>4} | {'W×H got/expected':<30} | "
        f"{'BYTES':>10} | {'MAGIC':<16} | PASS/FAIL"
    )
    print(header)
    print("-" * len(header))
    for r in rows:
        dims = f"{r['got']} / {r['expected']}"
        print(
            f"{r['fixture']:<12} | {r['kind']:<4} | {r['dpi']:>4} | {dims:<30} | "
            f"{r['bytes']:>10} | {r['magic']:<16} | {r['result']}"
        )
        if r["detail"] and r["result"] == "FAIL":
            print(f"{'':<12} | detail: {r['detail']}")
    print(
        f"RESULT: {'PASS' if not failed else 'FAIL'} "
        f"({len(rows) - len(failed)}/{len(rows)} rows; {len(failed)} failed)"
    )

    if args.json_out:
        out = Path(args.json_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            json.dumps(
                {
                    "rows": rows,
                    "failed": len(failed),
                    "result": "PASS" if not failed else "FAIL",
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
