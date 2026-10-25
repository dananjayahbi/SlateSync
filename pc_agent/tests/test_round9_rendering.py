"""Round-9 fill / PATH / TABLE rendering on the PC side.

Three features reached the mirror in round 9 and each has a failure mode that
only a rendering assertion catches:

* **fill (issue 04)** — a paint-bucket interior must paint in the fill colour
  while the OUTLINE keeps ``style.color``. Before this the PC only filled when
  ``stroke_width == 0``, so a filled shape with a visible outline mirrored as an
  empty outline.
* **PATH (issue 05)** — a rotated shape arrives as a closed polygon; it must
  fill and stroke as a polygon, not fall through to the bbox rectangle.
* **TABLE (issue 06)** — grid segments plus filled header bands from
  ``graph_config``.

The tests drive ``PrimitiveRenderer._tessellate_shape`` directly (it is pure
maths: no GL context needed) and the cairo helpers for the exporters.
"""

from __future__ import annotations

import cairo
import pytest

from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.viewport.primitive_renderer import PrimitiveRenderer
from pc_agent.viewport.shape_fill import shape_is_filled


def _node(
    shape_type: str | None,
    *,
    pts: list[list[float]] | None = None,
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 100.0, 100.0),
    fill: str | None = None,
    stroke_width: float = 2.5,
    graph_config: dict | None = None,
    kind: str = "SHAPE",
) -> CanvasNode:
    return CanvasNode(
        node_id="n1",
        kind=kind,
        layer=0,
        bbox=bbox,
        style=NodeStyle(
            color="#1E1E1E",
            stroke_width=stroke_width,
            opacity=1.0,
            blend_mode="SRC_OVER",
            fill=fill,
        ),
        geometry=NodeGeometry(
            pts=pts or [],
            shape_type=shape_type,
            graph_config=graph_config,
            asset_ref=None,
        ),
    )


def _tessellate(node: CanvasNode) -> tuple[list[float], list[float]]:
    """``(fills, lines)`` vertex streams for one node."""
    renderer = PrimitiveRenderer.__new__(PrimitiveRenderer)  # no GL needed
    fills: list[float] = []
    lines: list[float] = []
    renderer._tessellate_shape(node, fills, lines, 1.0)
    return fills, lines


def _colours(stream: list[float], stride: int = 7) -> set[tuple[float, ...]]:
    """RGBA tuples present in a primitive vertex stream."""
    return {
        tuple(round(v, 4) for v in stream[i + 3 : i + 7])
        for i in range(0, len(stream) - stride + 1, stride)
    }


# ---------------------------------------------------------------------------
# fill (issue 04)
# ---------------------------------------------------------------------------


def test_an_unfilled_shape_emits_no_interior_triangles() -> None:
    fills, lines = _tessellate(_node("RECT"))
    assert fills == []
    assert lines


def test_fill_paints_the_interior_and_keeps_the_outline_colour() -> None:
    fills, lines = _tessellate(_node("RECT", fill="#FF0000"))
    assert fills, "a filled RECT must emit interior triangles"
    outline = _colours(lines)
    interior = _colours(fills)
    # #1E1E1E outline vs #FF0000 interior — the two must not be conflated.
    assert interior != outline
    assert any(c[0] > 0.9 and c[1] < 0.1 for c in interior)
    assert any(c[0] < 0.2 for c in outline)


def test_stroke_width_zero_still_means_solid_in_colour() -> None:
    """The legacy spelling must survive round 9 (no fill field set)."""
    assert shape_is_filled(0.0)
    fills, _ = _tessellate(_node("RECT", stroke_width=0.0))
    assert fills


def test_a_malformed_fill_colour_is_ignored() -> None:
    fills, _ = _tessellate(_node("RECT", fill="#ZZZZZZ"))
    assert fills == []


def test_an_arrow_never_fills_its_interior() -> None:
    """ARROW is stroked on both sides — a filled wedge would be a new bug."""
    fills, lines = _tessellate(
        _node("ARROW", pts=[[0.0, 0.0], [100.0, 100.0]], fill="#FF0000")
    )
    assert fills == []
    assert lines


# ---------------------------------------------------------------------------
# PATH (issue 05)
# ---------------------------------------------------------------------------


def test_a_path_fills_and_strokes_as_a_polygon() -> None:
    diamond = [[50.0, 0.0], [100.0, 50.0], [50.0, 100.0], [0.0, 50.0]]
    fills, lines = _tessellate(
        _node("PATH", pts=diamond, fill="#00FF00"),
    )
    assert fills
    assert lines
    assert any(c[1] > 0.9 and c[0] < 0.1 for c in _colours(fills))


def test_a_two_point_path_renders_as_a_segment_not_a_rect() -> None:
    _, lines = _tessellate(_node("PATH", pts=[[0.0, 0.0], [100.0, 100.0]]))
    assert lines


def test_an_unfilled_path_keeps_its_outline_only() -> None:
    diamond = [[50.0, 0.0], [100.0, 50.0], [50.0, 100.0], [0.0, 50.0]]
    fills, lines = _tessellate(_node("PATH", pts=diamond))
    assert fills == []
    assert lines


# ---------------------------------------------------------------------------
# TABLE (issue 06)
# ---------------------------------------------------------------------------


def test_a_table_emits_grid_lines_and_filled_header_bands() -> None:
    fills, lines = _tessellate(
        _node(
            "TABLE",
            graph_config={
                "rows": 4,
                "cols": 3,
                "header_row": True,
                "header_col": True,
            },
            fill="#EEEEEE",
        )
    )
    assert fills, "header bands must be filled"
    assert lines, "the grid must be stroked"


def test_a_table_without_a_fill_paints_no_bands() -> None:
    fills, _ = _tessellate(
        _node("TABLE", graph_config={"rows": 3, "cols": 3, "header_row": False})
    )
    assert fills == []


def test_a_degenerate_table_bbox_emits_nothing() -> None:
    fills, lines = _tessellate(
        _node(
            "TABLE",
            bbox=(10.0, 10.0, 10.0, 10.0),
            graph_config={"rows": 3, "cols": 3},
            fill="#EEEEEE",
        )
    )
    assert fills == []
    assert lines == []


# ---------------------------------------------------------------------------
# cairo exporters
# ---------------------------------------------------------------------------


def test_apply_fill_paints_a_path_and_reports_true() -> None:
    from pc_agent.export.cairo_shapes import apply_fill

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    ctx = cairo.Context(surface)
    style = NodeStyle(color="#000000", fill="#FF0000")
    painted = apply_fill(
        ctx,
        style,
        "PATH",
        (0.0, 0.0, 64.0, 64.0),
        [[0.0, 0.0], [64.0, 0.0], [64.0, 64.0], [0.0, 64.0]],
    )
    assert painted is True


def test_apply_fill_is_a_no_op_without_a_fill() -> None:
    from pc_agent.export.cairo_shapes import apply_fill

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 16, 16)
    ctx = cairo.Context(surface)
    style = NodeStyle(color="#000000", stroke_width=2.5)
    assert apply_fill(ctx, style, "RECT", (0.0, 0.0, 16.0, 16.0), []) is False


def test_trace_shape_builds_table_grid_segments() -> None:
    from pc_agent.export.cairo_shapes import trace_shape

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    ctx = cairo.Context(surface)
    node = _node("TABLE", graph_config={"rows": 2, "cols": 2})
    trace_shape(ctx, node, (0.0, 0.0, 64.0, 64.0), "TABLE")
    # A 2x2 grid has 3 horizontal + 3 vertical lines; cairo exposes the path
    # extent, so just prove something was built rather than nothing.
    assert ctx.copy_path_flat()


def test_fill_colour_rejects_malformed_values() -> None:
    from pc_agent.export.cairo_shapes import fill_colour

    assert fill_colour(NodeStyle(fill="#00FF00")) == "#00FF00"
    assert fill_colour(NodeStyle(fill="00FF00")) is None
    assert fill_colour(NodeStyle(fill="#ZZZZZZ")) is None
    assert fill_colour(NodeStyle()) is None


@pytest.mark.parametrize("shape", ["RECT", "CIRCLE", "TRIANGLE", "PATH", "TABLE", "TEXT"])
def test_apply_fill_covers_every_fillable_shape(shape: str) -> None:
    from pc_agent.export.cairo_shapes import apply_fill

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 32, 32)
    ctx = cairo.Context(surface)
    style = NodeStyle(color="#000000", fill="#0000FF")
    pts = [[0.0, 0.0], [32.0, 0.0], [32.0, 32.0]]
    assert apply_fill(
        ctx, style, shape, (0.0, 0.0, 32.0, 32.0), pts, {"rows": 2, "cols": 2}
    )
