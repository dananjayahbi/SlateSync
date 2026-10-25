"""Round 11 — mirror fidelity for free-hand fills, exports and table edits.

Four defects from round 11 that share one theme: the tablet and the PC
disagreed about what a node *means*.

* **issue 04** — a fill applied to a free-hand pen loop showed on the tablet
  but not on the PC mirror. The mirror draws ``STROKE`` ink through the ink
  tessellator, which knows nothing about ``style.fill``, and
  ``PrimitiveRenderer`` only ever received ``SHAPE`` / ``LINE`` nodes.
  ``pc_agent/viewport/stroke_fill.py`` is the PC twin of
  ``region_fill.dart``'s closure test, and every renderer now paints the
  interior under the ink.
* **issue 05** — an A4 canvas exported as a square because the raster exporter
  rounded BOTH axes up to the next 2048 multiple. Bounded output is now the
  exact ``world * dpi / 300`` size (covered in
  ``test_export_extent_matrix.py``); here we pin the round-trip through the
  real exporter at every supported DPI.
* **issue 03** — removing a table row/column must not lose the cells that
  remain, so the geometry has to shrink by exactly one cell.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest

from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.viewport import stroke_fill
from pc_agent.viewport.vector_geometry import table_geometry

#: A hand-drawn circle as the pen actually reports it: ends ~7 world units
#: apart after a 520-unit sweep, so it is "closed" by ink width alone.
_NEARLY_CLOSED: list[list[float]] = [
    [300.0, 300.0],
    [380.0, 296.0],
    [452.0, 330.0],
    [495.0, 392.0],
    [497.0, 460.0],
    [460.0, 512.0],
    [398.0, 540.0],
    [336.0, 528.0],
    [304.0, 498.0],
    [305.0, 306.0],
]

#: Drawn past the start — the natural "loop a circle" gesture. The ends are far
#: apart but the tail crosses the head, so the crossing seals the region.
_OVERSHOOT: list[list[float]] = [
    [300.0, 400.0],
    [420.0, 400.0],
    [450.0, 460.0],
    [380.0, 500.0],
    [310.0, 470.0],
    [320.0, 380.0],
    [350.0, 340.0],
]

#: An open arc: no crossing, ends far apart — encloses nothing.
_OPEN_ARC: list[list[float]] = [
    [200.0, 200.0],
    [260.0, 180.0],
    [320.0, 200.0],
    [350.0, 260.0],
    [340.0, 330.0],
]


def _node(
    pts: list[list[float]],
    *,
    kind: str = "STROKE",
    fill: str | None = None,
    stroke_width: float = 6.0,
) -> CanvasNode:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return CanvasNode(
        node_id=f"n-{uuid4().hex[:8]}",
        kind=kind,
        layer=0,
        bbox=(min(xs), min(ys), max(xs), max(ys)),
        style=NodeStyle(
            color="#1E1E1E",
            stroke_width=stroke_width,
            opacity=1.0,
            blend_mode="SRC_OVER",
            fill=fill,
        ),
        geometry=NodeGeometry(
            pts=pts, shape_type=None, graph_config=None, asset_ref=None
        ),
    )


# ---------------------------------------------------------------------------
# Issue 04 — closure rule (the PC twin of `polylineCloses`)
# ---------------------------------------------------------------------------
def test_ends_meeting_within_ink_width_is_closed() -> None:
    assert stroke_fill.polyline_closes([tuple(p) for p in _NEARLY_CLOSED], 6.0)


def test_overshooting_loop_is_closed_by_its_own_crossing() -> None:
    points = [tuple(p) for p in _OVERSHOOT]
    gap = (
        (points[-1][0] - points[0][0]) ** 2
        + (points[-1][1] - points[0][1]) ** 2
    ) ** 0.5
    assert gap > stroke_fill.closure_limit(points, 6.0)
    assert stroke_fill.polyline_self_intersects(points)
    assert stroke_fill.polyline_closes(points, 6.0)


def test_open_arc_is_never_a_region() -> None:
    assert not stroke_fill.polyline_closes([tuple(p) for p in _OPEN_ARC], 6.0)
    assert stroke_fill.stroke_fill_polygon(_OPEN_ARC, 6.0) is None


def test_degenerate_polylines_are_never_regions() -> None:
    assert not stroke_fill.polyline_closes([], 6.0)
    assert not stroke_fill.polyline_closes([(0.0, 0.0)], 6.0)
    assert not stroke_fill.polyline_closes([(0.0, 0.0), (1.0, 1.0)], 6.0)


def test_closure_limit_grows_with_the_stroke_width() -> None:
    points = [(0.0, 0.0), (100.0, 0.0), (100.0, 100.0), (20.0, 0.0)]
    assert stroke_fill.closure_limit(points, 2.0) < stroke_fill.closure_limit(
        points, 40.0
    )


def test_polygon_of_node_reads_geometry_and_style() -> None:
    filled = _node(_NEARLY_CLOSED, fill="#22AA55")
    assert stroke_fill.stroke_fill_polygon_of(filled) is not None
    assert stroke_fill.stroke_fill_polygon_of(_node(_OPEN_ARC)) is None


# ---------------------------------------------------------------------------
# Issue 04 — the viewport only gets nodes it can actually fill
# ---------------------------------------------------------------------------
def test_renderer_emits_fill_for_a_closed_filled_stroke() -> None:
    """The fill must reach the TRIANGLES batch (the ink mesh cannot carry it)."""
    pytest.importorskip("moderngl")
    from pc_agent.viewport import primitive_renderer as renderer

    node = _node(_NEARLY_CLOSED, fill="#22AA55")
    interior = renderer._stroke_fill_interior(node)
    assert interior is not None
    assert interior[:3] != (0.0, 0.0, 0.0)

    fills: list[float] = []
    lines: list[float] = []
    renderer.PrimitiveRenderer._tessellate_shape(None, node, fills, lines, 1.0)
    assert fills, "a filled closed stroke must produce fill triangles"
    assert not lines, "the ink is drawn by the stroke meshes, not the shape batch"


def test_renderer_skips_an_unfilled_stroke() -> None:
    from pc_agent.viewport import primitive_renderer as renderer

    fills: list[float] = []
    lines: list[float] = []
    renderer.PrimitiveRenderer._tessellate_shape(
        None, _node(_NEARLY_CLOSED), fills, lines, 1.0
    )
    assert fills == []


def test_renderer_skips_a_filled_open_stroke() -> None:
    from pc_agent.viewport import primitive_renderer as renderer

    fills: list[float] = []
    lines: list[float] = []
    renderer.PrimitiveRenderer._tessellate_shape(
        None, _node(_OPEN_ARC, fill="#22AA55"), fills, lines, 1.0
    )
    assert fills == []


def test_shape_nodes_are_untouched_by_the_stroke_fill_path() -> None:
    from pc_agent.viewport import primitive_renderer as renderer

    square = [[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0]]
    node = _node(square, kind="SHAPE", fill="#22AA55")
    node.geometry.shape_type = "RECT"
    assert renderer._stroke_fill_interior(node) is None


# ---------------------------------------------------------------------------
# Issue 04 — the cairo exporters (PNG/JPG, PDF, thumbnail) paint it too
# ---------------------------------------------------------------------------
def test_cairo_exporters_paint_the_closed_stroke_interior(tmp_path: Path) -> None:
    cairo = pytest.importorskip("cairo")
    from pc_agent.export.cairo_shapes import apply_stroke_fill

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    ctx = cairo.Context(surface)
    assert apply_stroke_fill(ctx, _node(_NEARLY_CLOSED, fill="#22AA55")) is True
    assert apply_stroke_fill(ctx, _node(_OPEN_ARC, fill="#22AA55")) is False
    assert apply_stroke_fill(ctx, _node(_NEARLY_CLOSED)) is False


# ---------------------------------------------------------------------------
# Issue 05 — the delivered raster keeps the canvas aspect ratio
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("dpi", [300, 600, 1200])
def test_a4_raster_export_keeps_the_page_ratio(dpi: int, tmp_path: Path) -> None:
    pytest.importorskip("numpy")
    pytest.importorskip("PIL")
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.export.tiled_raster_exporter import TiledRasterExporter

    doc = CanvasDocument(
        canvas_id=f"a4-{dpi}-{uuid4().hex[:6]}",
        title="a4",
        created_at=1,
        updated_at=1,
        artboard=Artboard(preset="A4", width=2480.0, height=3508.0,
                          is_infinite=False),
        content_bounds={"min_x": 0.0, "min_y": 0.0, "max_x": 2480.0,
                        "max_y": 3508.0},
        elements=[_node(_NEARLY_CLOSED, fill="#22AA55")],
    )
    config = AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )
    out = tmp_path / "exports" / f"a4_{dpi}.png"
    TiledRasterExporter(config).export(doc, dpi, out)

    head = out.read_bytes()[:24]
    width = int.from_bytes(head[16:20], "big")
    height = int.from_bytes(head[20:24], "big")
    assert (width, height) == (2_480 * dpi // 300, 3_508 * dpi // 300)
    assert width != height
    assert width / height == pytest.approx(2480 / 3508, rel=5e-4)


# ---------------------------------------------------------------------------
# Issue 03 — removing a row/column keeps the remaining cells drawn-sized
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(("rows", "cols"), [(4, 3), (3, 4), (7, 2)])
def test_table_shrinks_by_exactly_one_cell(rows: int, cols: int) -> None:
    box = (100.0, 100.0, 700.0, 500.0)
    config: dict[str, Any] = {
        "rows": rows,
        "cols": cols,
        "header_row": True,
        "header_col": False,
    }
    before = table_geometry(box, config)
    cell_w = (box[2] - box[0]) / cols
    cell_h = (box[3] - box[1]) / rows

    # A removed row/column shortens the box by one cell so survivors keep size.
    shrunk_box = (box[0], box[1], box[2], box[3] - cell_h)
    after_row = table_geometry(
        shrunk_box, {**config, "rows": rows - 1}
    )
    assert len(after_row.row_edges) == rows  # (rows - 1) + 1
    assert after_row.row_edges[1] - after_row.row_edges[0] == pytest.approx(cell_h)
    assert after_row.col_edges == before.col_edges

    shrunk_w = (box[0], box[1], box[2] - cell_w, box[3])
    after_col = table_geometry(shrunk_w, {**config, "cols": cols - 1})
    assert len(after_col.col_edges) == cols
    assert after_col.col_edges[1] - after_col.col_edges[0] == pytest.approx(cell_w)
    assert after_col.row_edges == before.row_edges
