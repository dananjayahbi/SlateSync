"""Tests for the vector PDF exporter (Doc 14 §6).

Covers ``%PDF`` magic, A4/infinite page-point policies, the empty-canvas
error, non-trivial content, the 14400 pt tiling fallback (unit + end-to-end),
both stroke ``pts`` layouts (exact cubic chain vs. Catmull-Rom→cubic
fallback), CAIRO_OPERATOR_MULTIPLY highlighter emission and the ≤10 Hz
throttled progress contract with ``.part`` cleanup on failure.
"""

from __future__ import annotations

import re
import zlib
from pathlib import Path

import pytest
from PIL import Image

import pc_agent.export.vector_pdf_exporter as pdf
from pc_agent.core.config_manager import AppConfig
from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle

#: Doc 21 Bézier chain: n = 7 = 3k − 2 (k = 3 anchors) ⇒ exact cubic path.
_CHAIN7 = [
    [10.0, 40.0],
    [40.0, 80.0],
    [70.0, 80.0],
    [100.0, 40.0],
    [130.0, 90.0],
    [160.0, 90.0],
    [190.0, 40.0],
]
#: Plain anchor polylines (n = 3 and n = 6 ⇒ Catmull-Rom→cubic fallback).
_ANCHORS3 = [[10.0, 40.0], [100.0, 120.0], [190.0, 40.0]]
_ANCHORS6 = [
    [10.0, 30.0],
    [40.0, 70.0],
    [80.0, 110.0],
    [130.0, 110.0],
    [170.0, 70.0],
    [195.0, 30.0],
]

_ZERO_BOUNDS = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
_MEDIABOX_RE = rb"/MediaBox\s*\[\s*[-\d.]+\s+[-\d.]+\s+([-\d.]+)\s+([-\d.]+)\s*\]"


def _bbox(pts: list[list[float]]) -> tuple[float, float, float, float]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def _node(
    kind: str = "STROKE",
    pts: list[list[float]] | None = None,
    bbox: tuple[float, float, float, float] | None = None,
    color: str = "#1E1E1E",
    stroke_width: float = 6.0,
    opacity: float = 1.0,
    blend_mode: str = "SRC_OVER",
    layer: int = 0,
    shape_type: str | None = None,
    graph_config: dict | None = None,
    asset_ref: str | None = None,
) -> CanvasNode:
    pts = _CHAIN7 if pts is None else pts
    if bbox is None:
        bbox = _bbox(pts) if pts else (0.0, 0.0, 0.0, 0.0)
    return CanvasNode(
        node_id=f"node-{kind}-{len(pts)}-{layer}",
        kind=kind,
        layer=layer,
        bbox=bbox,
        style=NodeStyle(
            color=color, stroke_width=stroke_width, opacity=opacity, blend_mode=blend_mode
        ),
        geometry=NodeGeometry(
            pts=pts, shape_type=shape_type, graph_config=graph_config, asset_ref=asset_ref
        ),
    )


def _doc(
    width: float | None = 200.0,
    height: float | None = 150.0,
    infinite: bool = False,
    bounds: dict[str, float] | None = None,
    elements: list[CanvasNode] | None = None,
    background_style: str = "BLANK",
    background_color: str = "#FFFFFF",
    preset: str = "A5",
) -> CanvasDocument:
    return CanvasDocument(
        canvas_id="cv-test",
        title="fixture",
        created_at=0,
        updated_at=0,
        artboard=Artboard(
            preset="INFINITE" if infinite else preset,
            width=width,
            height=height,
            is_infinite=infinite,
            background_style=background_style,
            background_color=background_color,
        ),
        content_bounds=dict(_ZERO_BOUNDS) if bounds is None else bounds,
        elements=list(elements or []),
    )


def _config(tmp_path: Path) -> AppConfig:
    return AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )


@pytest.fixture
def exporter(tmp_path: Path) -> pdf.VectorPdfExporter:
    return pdf.VectorPdfExporter(_config(tmp_path))


def _exports(tmp_path: Path, name: str) -> Path:
    return tmp_path / "exports" / name


def _pdf_page_sizes(path: Path) -> list[tuple[float, float]]:
    """All page MediaBox sizes (pt) — cairo stores pages in ObjStm streams."""
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


class _RecCtx:
    """Records the path ops ``_trace_path`` may issue."""

    def __init__(self) -> None:
        self.ops: list[tuple] = []

    def move_to(self, x: float, y: float) -> None:
        self.ops.append(("move", x, y))

    def line_to(self, x: float, y: float) -> None:
        self.ops.append(("line", x, y))

    def curve_to(self, x1: float, y1: float, x2: float, y2: float, x3: float, y3: float) -> None:
        self.ops.append(("curve", (x1, y1), (x2, y2), (x3, y3)))


def test_pdf_magic(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "tiny.pdf")
    values: list[float] = []
    result = exporter.export(_doc(elements=[_node()]), out, values.append)
    assert result == out
    assert out.read_bytes()[:4] == b"%PDF"
    assert values[-1] == 1.0  # final 1.0 always flushed
    assert all(0.0 <= v <= 1.0 for v in values)
    assert list(out.parent.glob("*.part")) == []


def test_a4_page_points(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    doc = _doc(width=2480.0, height=3508.0, preset="A4", elements=[_node()])
    w_pt, h_pt = pdf.page_size_pt(doc)
    # 2480 × 3508 world × 72/300 ⇒ 595.2 × 841.92 pt.
    assert w_pt == pytest.approx(595.2, abs=0.5)
    assert h_pt == pytest.approx(841.9, abs=0.5)
    out = _exports(tmp_path, "a4.pdf")
    exporter.export(doc, out)
    page_w, page_h = _pdf_page_sizes(out)[0]
    assert page_w == pytest.approx(595.2, abs=0.5)
    assert page_h == pytest.approx(841.9, abs=0.5)


def test_infinite_page_points(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    bounds = {"min_x": 100.0, "min_y": 100.0, "max_x": 200.0, "max_y": 200.0}
    doc = _doc(infinite=True, bounds=bounds, elements=[_node(pts=[[110.0, 110.0], [190.0, 190.0]])])
    w_pt, h_pt = pdf.page_size_pt(doc)
    # content_bounds padded ±48 units ⇒ 196 × 196 world × 72/300 = 47.04 pt.
    assert w_pt == pytest.approx(47.04, abs=0.5)
    assert h_pt == pytest.approx(47.04, abs=0.5)
    out = _exports(tmp_path, "infinite.pdf")
    exporter.export(doc, out)
    page_w, page_h = _pdf_page_sizes(out)[0]
    assert page_w == pytest.approx(w_pt, abs=0.5)
    assert page_h == pytest.approx(h_pt, abs=0.5)


def test_empty_canvas_raises() -> None:
    with pytest.raises(ValueError, match="empty canvas"):
        pdf.page_size_pt(_doc(infinite=True, bounds=dict(_ZERO_BOUNDS)))
    with pytest.raises(ValueError, match="empty canvas"):
        pdf.page_size_pt(_doc(infinite=True, bounds={}))
    with pytest.raises(ValueError, match="empty canvas"):
        pdf.page_size_pt(_doc(width=None, height=100.0))


def test_empty_canvas_export_raises(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "empty.pdf")
    with pytest.raises(ValueError, match="empty canvas"):
        exporter.export(_doc(infinite=True, bounds=dict(_ZERO_BOUNDS)), out)
    assert not out.exists()
    assert list(out.parent.glob("*.part")) == []


def test_nontrivial_size(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "stroke.pdf")
    exporter.export(_doc(elements=[_node(pts=_CHAIN7)]), out)
    assert out.stat().st_size > 1024  # real content, not an empty header


def test_tiling_fallback() -> None:
    single = pdf._tile_pages(600.0, 800.0)
    assert single == [(0, 1, 0.0, 0.0)]
    assert pdf._tile_pages(14400.0, 14400.0) == [(0, 1, 0.0, 0.0)]

    # 15000 pt > 14400 along the long axis (x) ⇒ split into row-major tiles.
    tiles = pdf._tile_pages(15000.0, 600.0)
    assert len(tiles) > 1
    assert tiles[0][1] == len(tiles)
    xs = {t[2] for t in tiles}
    ys = {t[3] for t in tiles}
    assert len(xs) == len(tiles)  # offsets vary along the long axis only
    assert len(ys) == 1
    assert tiles[0][2] == 0.0
    assert tiles[1][2] == pytest.approx(7500.0 / pdf.UNIT_TO_PT)

    # Tall extent splits along y instead.
    tall = pdf._tile_pages(600.0, 30000.0)
    assert len(tall) > 1
    assert len({t[3] for t in tall}) == len(tall)
    assert len({t[2] for t in tall}) == 1
    assert len(pdf._tile_pages(14400.5, 10.0)) == 2


def test_multipage_export(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    bounds = {"min_x": 0.0, "min_y": 0.0, "max_x": 100000.0, "max_y": 400.0}
    doc = _doc(
        infinite=True,
        bounds=bounds,
        elements=[_node(pts=[[0.0, 100.0], [100000.0, 300.0]], bbox=(0.0, 0.0, 100000.0, 400.0))],
    )
    out = _exports(tmp_path, "wide.pdf")
    exporter.export(doc, out)
    sizes = _pdf_page_sizes(out)
    # padded 100096 world ⇒ 24023 pt > 14400 ⇒ two pages along x.
    assert len(sizes) == 2
    expected_tile_pt = (100000.0 + 96.0) * pdf.UNIT_TO_PT / 2
    for page_w, page_h in sizes:
        assert page_w == pytest.approx(expected_tile_pt, abs=0.5)
        assert page_w <= pdf.PAGE_PT_LIMIT
    assert list(out.parent.glob("*.part")) == []


def test_cubic_chain_path_renders() -> None:
    ctx = _RecCtx()
    assert pdf._trace_path(ctx, _CHAIN7) is True
    curves = [op for op in ctx.ops if op[0] == "curve"]
    assert ctx.ops[0] == ("move", _CHAIN7[0][0], _CHAIN7[0][1])
    assert len(curves) == 2
    assert curves[0] == ("curve", tuple(_CHAIN7[1]), tuple(_CHAIN7[2]), tuple(_CHAIN7[3]))
    assert curves[1] == ("curve", tuple(_CHAIN7[4]), tuple(_CHAIN7[5]), tuple(_CHAIN7[6]))

    # Contract-literal (n − 2) % 3 == 0 chain (n = 8): two cubics + trailing line.
    ctx8 = _RecCtx()
    eight = _CHAIN7 + [[200.0, 60.0]]
    assert pdf._trace_path(ctx8, eight) is True
    assert len([op for op in ctx8.ops if op[0] == "curve"]) == 2
    assert ctx8.ops[-1] == ("line", 200.0, 60.0)


def test_anchor_catmull_fallback_renders() -> None:
    for pts in (_ANCHORS3, _ANCHORS6):
        ctx = _RecCtx()
        assert pdf._trace_path(ctx, pts) is True
        curves = [op for op in ctx.ops if op[0] == "curve"]
        assert ctx.ops[0] == ("move", pts[0][0], pts[0][1])
        assert len(curves) == len(pts) - 1
        # Controls come from the Catmull-Rom→cubic conversion, not raw chain data.
        expected = pdf._catmull_to_cubic(pts)
        assert len(expected) == len(pts) - 1
        for op, seg in zip(curves, expected):
            assert op == ("curve", (seg[0], seg[1]), (seg[2], seg[3]), (seg[4], seg[5]))

    # First segment of the 3-anchor fallback follows c1 = P0 + (P1 − P0)/6,
    # c2 = P1 − (P2 − P0)/6 with clamped start anchor (P_{-1} = P0).
    a0, a1, a2 = _ANCHORS3
    c1 = (a0[0] + (a1[0] - a0[0]) / 6.0, a0[1] + (a1[1] - a0[1]) / 6.0)
    c2 = (a1[0] - (a2[0] - a0[0]) / 6.0, a1[1] - (a2[1] - a0[1]) / 6.0)
    ctx = _RecCtx()
    assert pdf._trace_path(ctx, _ANCHORS3) is True
    curve0 = [op for op in ctx.ops if op[0] == "curve"][0]
    assert curve0[1] == pytest.approx(c1)
    assert curve0[2] == pytest.approx(c2)
    assert curve0[3] == (a1[0], a1[1])  # first segment ends at anchor 1


def test_is_cubic_chain_layout() -> None:
    assert pdf._is_cubic_chain(_CHAIN7)  # n = 7 = 3k − 2 (Doc 21 layout)
    assert pdf._is_cubic_chain(_CHAIN7[:4])  # n = 4
    assert pdf._is_cubic_chain(_CHAIN7 + [[0.0, 0.0]])  # n = 8, (n − 2) % 3 == 0
    assert not pdf._is_cubic_chain(_ANCHORS3)  # n = 3 anchors
    assert not pdf._is_cubic_chain(_ANCHORS6)  # n = 6 anchors
    assert not pdf._is_cubic_chain([[0.0, 0.0], [1.0, 1.0]])  # n = 2 anchors


@pytest.mark.parametrize("pts", [_CHAIN7, _ANCHORS3], ids=["chain", "anchors"])
def test_stroke_renders_pdf(
    exporter: pdf.VectorPdfExporter, tmp_path: Path, pts: list[list[float]]
) -> None:
    out = _exports(tmp_path, f"stroke-{len(pts)}.pdf")
    exporter.export(_doc(elements=[_node(pts=pts)]), out)
    assert out.read_bytes()[:4] == b"%PDF"
    assert out.stat().st_size > 1024


def test_highlight_multiply_pdf(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    highlight_out = _exports(tmp_path, "hl.pdf")
    exporter.export(_doc(elements=[_node(kind="HIGHLIGHT", pts=_CHAIN7)]), highlight_out)
    assert b"/Multiply" in highlight_out.read_bytes()

    plain_out = _exports(tmp_path, "plain.pdf")
    exporter.export(_doc(elements=[_node(kind="STROKE", pts=_CHAIN7)]), plain_out)
    assert b"/Multiply" not in plain_out.read_bytes()


def test_progress_throttled_and_monotonic(
    exporter: pdf.VectorPdfExporter, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = {"t": 0.0}

    def fake_monotonic() -> float:
        clock["t"] += 0.001
        return clock["t"]

    monkeypatch.setattr(pdf, "monotonic", fake_monotonic)
    elements = [
        _node(pts=[[10.0, 10.0 + (i % 60)], [190.0, 80.0 + (i % 60)]]) for i in range(300)
    ]
    calls: list[tuple[float, float]] = []

    def progress(fraction: float) -> None:
        calls.append((clock["t"], fraction))

    out = _exports(tmp_path, "progress.pdf")
    exporter.export(_doc(elements=elements), out, progress)

    assert calls, "progress must be called"
    fractions = [f for _, f in calls]
    assert all(a <= b for a, b in zip(fractions, fractions[1:]))  # monotonic
    assert calls[-1][1] == 1.0  # final 1.0 always flushed
    # Every non-final tick is ≥0.1 s apart on the injected clock (≤10 Hz).
    times = [t for t, _ in calls][:-1]
    for earlier, later in zip(times, times[1:]):
        assert later - earlier >= 0.1 - 1e-9
    assert len(calls) <= 6  # 300 fast nodes ⇒ a handful of throttled ticks


def test_progress_exception_cleanup(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "boom.pdf")

    def boom(_fraction: float) -> None:
        raise RuntimeError("cancel-signal")

    with pytest.raises(RuntimeError, match="cancel-signal"):
        exporter.export(_doc(elements=[_node()]), out, boom)
    assert not out.exists()
    assert list(out.parent.glob("*.part")) == []


def test_missing_asset_skipped(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    node = _node(kind="IMAGE", pts=[], bbox=(10.0, 10.0, 50.0, 50.0), asset_ref="assets/gone.png")
    out = _exports(tmp_path, "no-asset.pdf")
    exporter.export(_doc(elements=[node]), out)  # must not raise
    assert out.exists()


def test_shape_graph_image_smoke(exporter: pdf.VectorPdfExporter, tmp_path: Path) -> None:
    asset_dir = tmp_path / "assets" / "cv-test"
    asset_dir.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", (16, 16), (30, 90, 200, 255)).save(asset_dir / "img.png")
    elements = [
        _node(kind="SHAPE", pts=[], bbox=(10.0, 10.0, 60.0, 50.0), shape_type="RECT"),
        _node(kind="SHAPE", pts=[], bbox=(70.0, 10.0, 120.0, 60.0), shape_type="CIRCLE"),
        _node(kind="SHAPE", pts=[], bbox=(10.0, 60.0, 50.0, 100.0), shape_type="TRIANGLE"),
        _node(
            kind="SHAPE",
            pts=[[60.0, 100.0], [95.0, 130.0]],
            bbox=(60.0, 100.0, 95.0, 130.0),
            shape_type="ARROW",
        ),
        _node(kind="LINE", pts=[[5.0, 140.0], [60.0, 105.0]], bbox=(5.0, 105.0, 60.0, 140.0)),
        _node(
            kind="GRAPH_AXES",
            pts=[],
            bbox=(100.0, 60.0, 195.0, 145.0),
            shape_type="CARTESIAN_2D",
            graph_config={
                "origin": [150.0, 120.0],
                "x_range": [-2, 2],
                "y_range": [-2, 2],
                "grid_step": 20.0,
                "show_labels": True,
            },
        ),
        _node(kind="IMAGE", pts=[], bbox=(130.0, 10.0, 170.0, 50.0), asset_ref="assets/img.png"),
        _node(kind="HIGHLIGHT", pts=_CHAIN7, color="#FFFF00", opacity=0.5),
    ]
    out = _exports(tmp_path, "kinds.pdf")
    exporter.export(_doc(elements=elements), out)
    assert out.exists()
    assert out.stat().st_size > 1024
