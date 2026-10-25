"""Tests for the tiled high-res raster exporter (Doc 13 §6).

Covers the frozen extent policy, the px = world × dpi / 300 dimension formula
at 300/600/1200 DPI, PNG/JPG magic bytes, strip progress + the disk-backed
``np.memmap`` RAM gate, both stroke ``pts`` layouts (exact cubic chain and
Catmull-Rom anchors), multiply highlighter blending, background patterns and
``.part`` cleanup on success and failure.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

import pc_agent.export.tiled_raster_exporter as tiled
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
#: Plain anchor polylines (n = 3 and n = 6 ⇒ Catmull-Rom sampler path).
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


def _bbox(pts: list[list[float]]) -> tuple[float, float, float, float]:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


def _node(
    kind: str = "STROKE",
    pts: list[list[float]] | None = None,
    bbox: tuple[float, float, float, float] | None = None,
    color: str = "#E03030",
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
def exporter(tmp_path: Path) -> tiled.TiledRasterExporter:
    return tiled.TiledRasterExporter(_config(tmp_path))


def _exports(tmp_path: Path, name: str) -> Path:
    return tmp_path / "exports" / name


def _ink_count(path: Path) -> int:
    """Non-white pixels in the exported image (background is white)."""
    arr = np.asarray(Image.open(path).convert("RGB"))
    return int((arr.sum(axis=2) < 720).sum())


class _RecCtx:
    """Records the only three path ops ``_trace_path`` may issue."""

    def __init__(self) -> None:
        self.ops: list[tuple] = []

    def move_to(self, x: float, y: float) -> None:
        self.ops.append(("move", x, y))

    def line_to(self, x: float, y: float) -> None:
        self.ops.append(("line", x, y))

    def curve_to(self, x1: float, y1: float, x2: float, y2: float, x3: float, y3: float) -> None:
        self.ops.append(("curve", (x1, y1), (x2, y2), (x3, y3)))


@pytest.mark.parametrize(
    "dpi,expected", [(300, (1748, 2480)), (600, (3496, 4960)), (1200, (6992, 9920))]
)
def test_dim_formula_a5(dpi: int, expected: tuple[int, int]) -> None:
    # Round-11 issue 05: the DELIVERED image is exactly ceil(world * dpi / 300).
    pre_w = math.ceil(1748 * dpi / 300)
    pre_h = math.ceil(2480 * dpi / 300)
    assert abs(pre_w - expected[0]) <= 1
    assert abs(pre_h - expected[1]) <= 1
    assert tiled.extent_to_px((0.0, 0.0, 1748.0, 2480.0), dpi) == (pre_w, pre_h)


def test_bounded_extent() -> None:
    doc = _doc(width=1748.0, height=2480.0, preset="A5")
    assert tiled.resolve_extent(doc) == (0.0, 0.0, 1748.0, 2480.0)


def test_infinite_extent_padded_64() -> None:
    bounds = {"min_x": 100.0, "min_y": 100.0, "max_x": 200.0, "max_y": 200.0}
    doc = _doc(infinite=True, bounds=bounds)
    assert tiled.resolve_extent(doc) == pytest.approx((36.0, 36.0, 264.0, 264.0))


@pytest.mark.parametrize(
    "doc",
    [
        _doc(infinite=True, bounds=dict(_ZERO_BOUNDS)),
        _doc(infinite=True, bounds={"min_x": 0.0, "min_y": 0.0, "max_x": 10.0, "max_y": 0.0}),
        _doc(infinite=True, bounds={}),
        _doc(width=None, height=100.0),
        _doc(width=0.0, height=100.0),
    ],
)
def test_empty_canvas_raises(doc: CanvasDocument) -> None:
    with pytest.raises(ValueError, match="empty canvas"):
        tiled.resolve_extent(doc)


def test_unsupported_dpi_raises(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="unsupported dpi"):
        exporter.export(_doc(), 72, _exports(tmp_path, "bad.png"))


def test_png_magic(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "tiny.png")
    values: list[float] = []
    result = exporter.export(_doc(elements=[_node(pts=_CHAIN7)]), 300, out, values.append)
    assert result == out
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    with Image.open(out) as img:
        assert img.size == (200, 150)  # round-11 issue 05: EXACT extent, no strip padding
    assert values == [1.0]  # single strip ⇒ progress = strips/total = 1.0
    assert list(out.parent.glob("*.part")) == []


def test_jpg_magic(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    out = _exports(tmp_path, "tiny.jpg")
    exporter.export(_doc(elements=[_node(pts=_ANCHORS3)]), 300, out)
    assert out.read_bytes()[:3] == b"\xff\xd8\xff"
    assert list(out.parent.glob("*.part")) == []


def test_jpg_dimension_cap(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    doc = _doc(width=70000.0, height=100.0)
    with pytest.raises(ValueError, match="65535"):
        exporter.export(doc, 300, _exports(tmp_path, "huge.jpg"))
    # The advisory points at the PNG / vector PDF alternatives (Doc 13 §5.3).
    with pytest.raises(ValueError, match="PNG"):
        exporter.export(doc, 300, _exports(tmp_path, "huge.jpg"))


def test_progress_monotonic_and_memmap_ram_gate(
    exporter: tiled.TiledRasterExporter, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    real_memmap = np.memmap
    calls: list[tuple] = []

    def spy(*args, **kwargs):  # noqa: ANN002, ANN003
        calls.append((args, kwargs))
        return real_memmap(*args, **kwargs)

    monkeypatch.setattr(np, "memmap", spy)

    # 2100×100 world @300 DPI ⇒ 2100×100 px ⇒ two row-major strips of 2048.
    wide = _doc(width=2100.0, height=100.0, elements=[_node(pts=[[100.0, 20.0], [2000.0, 80.0]])])
    values: list[float] = []
    out = _exports(tmp_path, "wide.png")
    exporter.export(wide, 300, out, values.append)

    # RAM gate: one disk-backed memmap of the full canvas — never a RAM copy.
    assert len(calls) == 1
    args, kwargs = calls[0]
    assert str(args[0]).endswith(".part")
    assert kwargs["mode"] == "w+"
    # Round-11 issue 05: allocated at the EXACT delivered size, not 2048-padded.
    assert kwargs["shape"] == (100, 2100, 4)

    # progress = strips_done / strips_total, monotonic, ending at 1.0.
    assert values == [0.5, 1.0]
    with Image.open(out) as img:
        assert img.size == (2100, 100)
    assert list(out.parent.glob("*.part")) == []


def test_cubic_chain_path_renders() -> None:
    ctx = _RecCtx()
    assert tiled._trace_path(ctx, _CHAIN7) is True
    curves = [op for op in ctx.ops if op[0] == "curve"]
    assert ctx.ops[0] == ("move", _CHAIN7[0][0], _CHAIN7[0][1])
    assert len(curves) == 2
    assert curves[0] == ("curve", tuple(_CHAIN7[1]), tuple(_CHAIN7[2]), tuple(_CHAIN7[3]))
    assert curves[1] == ("curve", tuple(_CHAIN7[4]), tuple(_CHAIN7[5]), tuple(_CHAIN7[6]))

    # Single-segment chain (n = 4).
    ctx4 = _RecCtx()
    four = _CHAIN7[:4]
    assert tiled._trace_path(ctx4, four) is True
    assert [op for op in ctx4.ops if op[0] == "curve"] == [
        ("curve", tuple(four[1]), tuple(four[2]), tuple(four[3]))
    ]

    # Contract-literal (n − 2) % 3 == 0 chain (n = 8): two cubics + trailing line.
    ctx8 = _RecCtx()
    eight = _CHAIN7 + [[200.0, 60.0]]
    assert tiled._trace_path(ctx8, eight) is True
    assert len([op for op in ctx8.ops if op[0] == "curve"]) == 2
    assert ctx8.ops[-1] == ("line", 200.0, 60.0)


def test_anchor_fallback_renders() -> None:
    for pts in (_ANCHORS3, _ANCHORS6):
        ctx = _RecCtx()
        assert tiled._trace_path(ctx, pts) is True
        assert not any(op[0] == "curve" for op in ctx.ops)
        assert ctx.ops[0] == ("move", pts[0][0], pts[0][1])
        # steps=8 samples per segment ⇒ 1 moveTo + 8 × (n − 1) lineTo.
        assert len(ctx.ops) == 1 + 8 * (len(pts) - 1)
        sampled = tiled._catmull_rom_sample(pts)
        assert sampled[0] == (pts[0][0], pts[0][1])
        assert sampled[-1] == pytest.approx((pts[-1][0], pts[-1][1]))
        for ax, ay in pts:
            assert any(abs(sx - ax) < 1e-9 and abs(sy - ay) < 1e-9 for sx, sy in sampled)


def test_is_cubic_chain_layout() -> None:
    assert tiled._is_cubic_chain(_CHAIN7)  # n = 7 = 3k − 2 (Doc 21 layout)
    assert tiled._is_cubic_chain(_CHAIN7[:4])  # n = 4
    assert tiled._is_cubic_chain(_CHAIN7 + [[0.0, 0.0]])  # n = 8, (n − 2) % 3 == 0
    assert not tiled._is_cubic_chain(_ANCHORS3)  # n = 3 anchors
    assert not tiled._is_cubic_chain(_ANCHORS6)  # n = 6 anchors
    assert not tiled._is_cubic_chain([[0.0, 0.0], [1.0, 1.0]])  # n = 2 anchors


@pytest.mark.parametrize("pts", [_CHAIN7, _ANCHORS3], ids=["chain", "anchors"])
def test_stroke_renders_pixels(
    exporter: tiled.TiledRasterExporter, tmp_path: Path, pts: list[list[float]]
) -> None:
    out = _exports(tmp_path, f"stroke-{len(pts)}.png")
    exporter.export(_doc(elements=[_node(pts=pts)]), 300, out)
    assert _ink_count(out) > 0


def test_part_removed_on_progress_failure(
    exporter: tiled.TiledRasterExporter, tmp_path: Path
) -> None:
    out = _exports(tmp_path, "boom.png")

    def boom(_fraction: float) -> None:
        raise RuntimeError("cancelled")

    with pytest.raises(RuntimeError, match="cancelled"):
        exporter.export(_doc(elements=[_node()]), 300, out, boom)
    assert not out.exists()
    assert list(out.parent.glob("*.part")) == []


def test_background_patterns(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    blank = _exports(tmp_path, "blank.png")
    ruled = _exports(tmp_path, "ruled.png")
    exporter.export(_doc(), 300, blank)
    exporter.export(_doc(background_style="RULED"), 300, ruled)
    assert _ink_count(blank) == 0
    assert _ink_count(ruled) > 0  # grid lines drawn on the white page
    assert blank.read_bytes() != ruled.read_bytes()


def test_highlight_multiply_blend(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    line = [[30.0, 75.0], [170.0, 75.0]]
    highlight_out = _exports(tmp_path, "hl.png")
    stroke_out = _exports(tmp_path, "stroke-src.png")
    exporter.export(
        _doc(
            background_color="#808080",
            elements=[_node(kind="HIGHLIGHT", pts=line, color="#FF0000", stroke_width=8.0)],
        ),
        300,
        highlight_out,
    )
    exporter.export(
        _doc(
            background_color="#808080",
            elements=[_node(kind="STROKE", pts=line, color="#FF0000", stroke_width=8.0)],
        ),
        300,
        stroke_out,
    )
    # HIGHLIGHT ⇒ CAIRO_OPERATOR_MULTIPLY: red × mid-gray ≈ 128.
    assert int(np.asarray(Image.open(highlight_out).convert("RGB"))[75, 100, 0]) < 160
    # SRC_OVER control: red over mid-gray ≈ 255.
    assert int(np.asarray(Image.open(stroke_out).convert("RGB"))[75, 100, 0]) > 200


def test_missing_asset_skipped(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
    node = _node(kind="IMAGE", pts=[], bbox=(10.0, 10.0, 50.0, 50.0), asset_ref="assets/gone.png")
    out = _exports(tmp_path, "no-asset.png")
    exporter.export(_doc(elements=[node]), 300, out)  # must not raise
    assert out.exists()


def test_shape_graph_image_smoke(exporter: tiled.TiledRasterExporter, tmp_path: Path) -> None:
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
    ]
    out = _exports(tmp_path, "kinds.png")
    exporter.export(_doc(elements=elements), 300, out)
    assert out.exists()
    assert _ink_count(out) > 0
