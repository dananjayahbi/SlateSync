"""Round-12 issue 05 — polygon and text box rendering on the PC side.

Two new tools reached the mirror and neither can be verified by eyeballing a
screenshot:

* **polygon** — a ``SHAPE`` with ``shape_type: "PATH"`` and its vertices in
  ``geometry.pts``. The renderer already had a PATH branch (round 9), so what
  matters here is that a *regular polygon* fills and strokes like one, that the
  fill honours ``style.fill`` / ``stroke_width == 0`` exactly as the other
  shapes do, and that a degenerate vertex list paints nothing.
* **text box** — a ``SHAPE`` with ``shape_type: "TEXT"`` and its content in
  ``graph_config``. Layout (wrapping, alignment, font-size clamping) is pure
  and is asserted directly; rasterisation is asserted through actual ink
  coverage on a cairo surface, because "returns True" would still pass with an
  empty raster.

The layout tests double as the parity check for
``mobile_app/lib/canvas_engine/text_box_model.dart``: both sides must agree on
where a line breaks, or the mirror and the tablet show different text.
"""

from __future__ import annotations

import math
from pathlib import Path

import cairo
import pytest

from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.export.tiled_raster_exporter import _draw_shape as _export_draw_shape
from pc_agent.viewport.primitive_renderer import PrimitiveRenderer
from pc_agent.viewport.text_renderer import (
    ALIGNMENTS,
    DEFAULT_ALIGN,
    DEFAULT_FONT_SIZE,
    LINE_HEIGHT_FACTOR,
    MAX_FONT_SIZE,
    MIN_FONT_SIZE,
    TEXT_PADDING,
    TextConfig,
    TextLayout,
    cairo_measurer,
    clamp_font_size,
    draw_text_box,
    is_text_shape,
    layout_text,
    line_origin_x,
    line_origins,
    normalise_align,
    normalise_box,
    normalise_text,
    parse_hex_rgb,
    rasterise_text,
    sanitise_text,
    text_config,
    wrap_lines,
)

# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


def _node(
    shape_type: str | None,
    *,
    pts: list[list[float]] | None = None,
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 200.0, 100.0),
    fill: str | None = None,
    stroke_width: float = 2.5,
    graph_config: dict | None = None,
    kind: str = "SHAPE",
    color: str = "#1E1E1E",
) -> CanvasNode:
    return CanvasNode(
        node_id="n1",
        kind=kind,
        layer=0,
        bbox=bbox,
        style=NodeStyle(
            color=color,
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
    """``(fills, lines)`` primitive vertex streams for one node."""
    renderer = PrimitiveRenderer.__new__(PrimitiveRenderer)  # no GL needed
    fills: list[float] = []
    lines: list[float] = []
    renderer._tessellate_shape(node, fills, lines, 1.0)
    return fills, lines


def _colours(stream: list[float], stride: int = 7) -> set[tuple[float, ...]]:
    return {
        tuple(round(v, 4) for v in stream[i + 3 : i + 7])
        for i in range(0, len(stream) - stride + 1, stride)
    }


def _stub_measure(text: str, font_size: float) -> float:
    """0.6 em per character — the same deterministic rule the Dart test uses."""
    return len(text) * font_size * 0.6


def _ink_rows(surface: cairo.ImageSurface) -> list[int]:
    """Rows that carry any ink, so a "drew nothing" bug cannot pass silently."""
    stride = surface.get_stride()
    data = bytes(surface.get_data())
    width = surface.get_width()
    rows: list[int] = []
    for y in range(surface.get_height()):
        row = data[y * stride : y * stride + width * 4]
        if any(row[index] > 0 for index in range(3, len(row), 4)):
            rows.append(y)
    return rows


def _ink_columns(surface: cairo.ImageSurface, row: int) -> list[int]:
    stride = surface.get_stride()
    data = bytes(surface.get_data())
    line = data[row * stride : (row + 1) * stride]
    return [x for x in range(surface.get_width()) if line[x * 4 + 3] > 0]


# ---------------------------------------------------------------------------
# Regular polygon vertices (mirror of polygon_geometry.dart)
# ---------------------------------------------------------------------------


def _regular_polygon(
    cx: float, cy: float, rx: float, ry: float, sides: int
) -> list[list[float]]:
    """What the tablet commits: top vertex first, inscribed in the drag box."""
    start = -math.pi / 2
    return [
        [
            cx + rx * math.cos(start + 2 * math.pi * i / sides),
            cy + ry * math.sin(start + 2 * math.pi * i / sides),
        ]
        for i in range(sides)
    ]


@pytest.mark.parametrize("sides", [3, 4, 5, 6, 8, 12])
def test_a_regular_polygon_fills_and_strokes(sides: int) -> None:
    pts = _regular_polygon(100.0, 50.0, 100.0, 50.0, sides)
    fills, lines = _tessellate(_node("PATH", pts=pts, fill="#00C000"))
    assert fills, f"a {sides}-gon must emit interior triangles"
    assert lines, f"a {sides}-gon must emit its outline"
    assert any(c[1] > 0.7 and c[0] < 0.1 for c in _colours(fills))


def test_a_polygon_without_a_fill_keeps_only_its_outline() -> None:
    pts = _regular_polygon(100.0, 50.0, 100.0, 50.0, 6)
    fills, lines = _tessellate(_node("PATH", pts=pts))
    assert fills == []
    assert lines


def test_a_polygon_honours_the_legacy_stroke_width_zero_fill() -> None:
    pts = _regular_polygon(100.0, 50.0, 100.0, 50.0, 5)
    fills, _ = _tessellate(_node("PATH", pts=pts, stroke_width=0.0))
    assert fills


def test_polygon_interior_and_outline_colours_stay_distinct() -> None:
    pts = _regular_polygon(100.0, 50.0, 100.0, 50.0, 6)
    fills, lines = _tessellate(_node("PATH", pts=pts, fill="#FF0000"))
    assert _colours(fills) != _colours(lines)


def test_a_degenerate_polygon_has_no_visible_interior() -> None:
    """Three identical vertices: whatever is emitted must cover zero area.

    The renderer does not special-case a zero-area ring (the tablet refuses to
    commit one via ``polygonIsUsable``), so this pins the weaker but honest
    property: no ink can land outside nothing.
    """
    point = [10.0, 10.0]
    fills, _ = _tessellate(_node("PATH", pts=[point, point, point], fill="#FF0000"))
    for index in range(0, len(fills), 7 * 3):
        xs = {fills[index], fills[index + 7], fills[index + 14]}
        assert len(xs) == 1, "a collapsed polygon cannot paint an area"


def test_a_two_point_path_degrades_to_a_segment() -> None:
    _, lines = _tessellate(_node("PATH", pts=[[0.0, 0.0], [100.0, 100.0]]))
    assert lines, "a 2-point PATH must render as the segment it is, not vanish"


def test_polygon_vertices_outside_the_bbox_still_fill() -> None:
    """A rotated/oversized ring must not be clipped by the node bbox."""
    pts = _regular_polygon(100.0, 50.0, 300.0, 300.0, 6)
    fills, _ = _tessellate(
        _node("PATH", pts=pts, bbox=(0.0, 0.0, 200.0, 100.0), fill="#0000FF")
    )
    assert fills


def test_a_polygon_is_not_treated_as_its_bounding_rectangle() -> None:
    """A triangle only has to fill half its box — a rect fill would use 4 corners."""
    triangle = _regular_polygon(50.0, 50.0, 50.0, 50.0, 3)
    fills, _ = _tessellate(_node("PATH", pts=triangle, fill="#00FF00"))
    # 3 vertices per triangle ⇒ 9 floats per triangle, 3 floats per vertex.
    assert len(fills) // 7 == 3, "a triangle must tessellate to exactly one triangle"


# ---------------------------------------------------------------------------
# graph_config sanitisation
# ---------------------------------------------------------------------------


def test_defaults_apply_to_an_empty_config() -> None:
    config = text_config(None)
    assert config.text == ""
    assert config.font_size == DEFAULT_FONT_SIZE
    assert config.align == DEFAULT_ALIGN


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (0, MIN_FONT_SIZE),
        (-40, MIN_FONT_SIZE),
        ("3", MIN_FONT_SIZE),
        (12, 12.0),
        (24.5, 24.5),
        ("31.25", 31.25),
        (10_000, MAX_FONT_SIZE),
        (None, DEFAULT_FONT_SIZE),
        ("huge", DEFAULT_FONT_SIZE),
        (float("nan"), DEFAULT_FONT_SIZE),
        (float("inf"), DEFAULT_FONT_SIZE),
        (float("-inf"), DEFAULT_FONT_SIZE),
        ([24], DEFAULT_FONT_SIZE),
    ],
)
def test_font_size_is_clamped_and_non_finite_rejected(raw: object, expected: float) -> None:
    assert clamp_font_size(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("left", "left"),
        ("Center", "center"),
        ("  RIGHT  ", "right"),
        ("justify", DEFAULT_ALIGN),
        (None, DEFAULT_ALIGN),
        (3, DEFAULT_ALIGN),
    ],
)
def test_alignment_is_normalised(raw: object, expected: str) -> None:
    assert normalise_align(raw) == expected


def test_text_config_reads_every_field() -> None:
    config = text_config({"text": "Hi", "font_size": 30, "align": "center"})
    assert config == TextConfig(text="Hi", font_size=30.0, align="center")


def test_a_corrupt_graph_config_degrades_field_by_field() -> None:
    config = text_config({"text": 42, "font_size": "abc", "align": "justify"})
    assert config.text == ""
    assert config.font_size == DEFAULT_FONT_SIZE
    assert config.align == DEFAULT_ALIGN


def test_a_table_config_is_an_empty_text_box() -> None:
    config = text_config({"rows": 3, "cols": 4})
    assert config.is_empty
    assert config.align == DEFAULT_ALIGN


def test_text_config_passes_an_already_sanitised_config_through() -> None:
    original = TextConfig(text="kept", font_size=18.0, align="right")
    assert text_config(original) is original


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("a\r\nb\rc", "a\nb\nc"),
        (None, ""),
        (12, ""),
        ("plain", "plain"),
    ],
)
def test_newlines_are_normalised_once(raw: object, expected: str) -> None:
    assert sanitise_text(raw) == expected
    assert normalise_text(raw) == expected


def test_is_text_shape_is_tolerant() -> None:
    assert is_text_shape("TEXT") is True
    assert is_text_shape("PATH") is False
    assert is_text_shape(None) is False
    assert is_text_shape("") is False


# ---------------------------------------------------------------------------
# Wrapping
# ---------------------------------------------------------------------------


def test_empty_text_wraps_to_nothing() -> None:
    assert wrap_lines("", 100.0, _stub_measure) == []
    assert wrap_lines("   ", 100.0, _stub_measure) == []


def test_a_short_line_is_returned_unchanged() -> None:
    assert wrap_lines("Hello", 200.0, _stub_measure, 10.0) == ["Hello"]


def test_a_paragraph_breaks_on_word_boundaries() -> None:
    # 0.6 em/char at 10 pt = 6 units per character ⇒ 60 units fits 10 chars.
    assert wrap_lines("aaa bbb ccc ddd", 60.0, _stub_measure, 10.0) == [
        "aaa bbb",
        "ccc ddd",
    ]


def test_every_paragraph_is_wrapped() -> None:
    assert wrap_lines("aaa bbb ccc\nddd eee fff", 60.0, _stub_measure, 10.0) == [
        "aaa bbb",
        "ccc",
        "ddd eee",
        "fff",
    ]


def test_a_blank_line_is_preserved() -> None:
    assert wrap_lines("one\n\ntwo", 200.0, _stub_measure) == ["one", "", "two"]


def test_a_long_word_is_hard_split() -> None:
    lines = wrap_lines("abcdefghij", 30.0, _stub_measure, 10.0)
    assert lines == ["abcde", "fghij"]
    assert all(_stub_measure(line, 10.0) <= 30.0 for line in lines)


def test_a_narrow_width_still_yields_one_character_per_chunk() -> None:
    assert wrap_lines("abcd", 1.0, _stub_measure, 10.0) == ["a", "b", "c", "d"]


@pytest.mark.parametrize("width", [0.0, -5.0, float("nan"), float("inf")])
def test_an_unusable_width_leaves_paragraphs_unbroken(width: float) -> None:
    assert wrap_lines("aaa bbb\nccc", width, _stub_measure) == ["aaa bbb", "ccc"]


def test_max_lines_truncates_without_wrapping_further() -> None:
    lines = wrap_lines("aaa bbb ccc ddd eee", 60.0, _stub_measure, 10.0, max_lines=1)
    assert lines == ["aaa bbb"]


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------


def _layout(text: str, box=(0.0, 0.0, 200.0, 200.0), **kwargs) -> TextLayout:
    config = text_config({"text": text, **kwargs})
    return layout_text(config, box, _stub_measure)


def test_layout_wraps_and_measures_every_line() -> None:
    layout = _layout("aaa bbb ccc", box=(0.0, 0.0, 60.0, 200.0), font_size=10)
    assert layout.lines == ("aaa bbb", "ccc")
    assert layout.widths == tuple(_stub_measure(line, 10.0) for line in layout.lines)
    assert layout.line_height == pytest.approx(10.0 * LINE_HEIGHT_FACTOR)


def test_layout_insets_the_box_before_wrapping() -> None:
    # 200 wide minus 2×4 padding = 192 available; 32 chars at 6 units = 192 fits.
    assert _layout("a" * 32, font_size=10).lines == ("a" * 32,)
    # One more character no longer fits inside the inset box.
    assert len(_layout("a" * 33, font_size=10).lines) > 1


def test_a_degenerate_box_leaves_paragraphs_unbroken() -> None:
    """Zero inner width means "cannot measure", so nothing is chopped.

    The box is empty anyway (a degenerate node paints no ink), and splitting it
    into single characters would be busywork the user never sees.
    """
    layout = _layout("abc", box=(10.0, 10.0, 10.0, 10.0), font_size=10)
    assert layout.lines == ("abc",)


def test_a_narrow_box_still_wraps_to_one_character_chunks() -> None:
    layout = _layout("abcd", box=(0.0, 0.0, 10.0, 200.0), font_size=10)
    assert layout.lines == ("a", "b", "c", "d")


def test_empty_text_produces_an_empty_layout() -> None:
    layout = _layout("")
    assert layout.lines == ()
    assert layout.is_empty


@pytest.mark.parametrize(
    ("align", "expected_offset"),
    [
        ("left", TEXT_PADDING),
        ("center", 100.0 - 20.0),
        ("right", 200.0 - TEXT_PADDING - 40.0),
    ],
)
def test_line_origin_x_honours_alignment(align: str, expected_offset: float) -> None:
    assert line_origin_x(0.0, 200.0, 40.0, align) == pytest.approx(expected_offset)


def test_an_unknown_alignment_behaves_as_left() -> None:
    assert line_origin_x(0.0, 200.0, 40.0, "justify") == pytest.approx(TEXT_PADDING)


def test_a_box_narrower_than_the_padding_does_not_invert() -> None:
    # Half-width of 2 clamps the inset to 2, so centring stays inside the box.
    assert line_origin_x(10.0, 14.0, 40.0, "center") == pytest.approx(12.0 - 20.0)


def test_line_origins_stack_from_the_padded_top() -> None:
    layout = _layout("a\nb\nc", box=(0.0, 100.0, 200.0, 400.0), font_size=20)
    origins = line_origins(layout, (0.0, 100.0, 200.0, 400.0))
    assert len(origins) == 3
    assert origins[0][1] == pytest.approx(100.0 + TEXT_PADDING)
    assert origins[1][1] == pytest.approx(
        100.0 + TEXT_PADDING + 20.0 * LINE_HEIGHT_FACTOR
    )
    for origin in origins:
        assert origin[0] == pytest.approx(TEXT_PADDING)


def test_centre_alignment_recentres_each_line() -> None:
    layout = _layout("aa\nbbbb", font_size=10, align="center")
    origins = line_origins(layout, (0.0, 0.0, 200.0, 200.0))
    assert origins[0][0] == pytest.approx(100.0 - _stub_measure("aa", 10.0) / 2.0)
    assert origins[1][0] == pytest.approx(100.0 - _stub_measure("bbbb", 10.0) / 2.0)


def test_right_alignment_keeps_the_inset_on_the_right() -> None:
    layout = _layout("aa", font_size=10, align="right")
    origins = line_origins(layout, (0.0, 0.0, 200.0, 200.0))
    assert origins[0][0] == pytest.approx(200.0 - TEXT_PADDING - _stub_measure("aa", 10.0))


def test_the_alignment_vocabulary_is_closed() -> None:
    assert ALIGNMENTS == ("left", "center", "right")
    assert DEFAULT_ALIGN in ALIGNMENTS


# ---------------------------------------------------------------------------
# Bounds / colour helpers
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ([0, 0, 10, 10], (0.0, 0.0, 10.0, 10.0)),
        ([10, 10, 0, 0], (0.0, 0.0, 10.0, 10.0)),
        ([0, 0], None),
        ("garbage", None),
        ([0, 0, float("nan"), 10], None),
        ([0, 0, float("inf"), 10], None),
    ],
)
def test_normalise_box_rejects_unusable_rects(raw: object, expected: object) -> None:
    assert normalise_box(raw) == expected


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("#FF0000", (1.0, 0.0, 0.0)),
        ("#f00", (1.0, 0.0, 0.0)),
        ("00FF00", (0.0, 1.0, 0.0)),
        ("#ZZZZZZ", (0.0, 0.0, 0.0)),
        (None, (0.0, 0.0, 0.0)),
        (12, (0.0, 0.0, 0.0)),
    ],
)
def test_parse_hex_rgb(raw: object, expected: tuple[float, float, float]) -> None:
    assert parse_hex_rgb(raw) == expected


# ---------------------------------------------------------------------------
# GL texture raster
# ---------------------------------------------------------------------------


def test_rasterise_produces_an_alpha_mask_sized_to_the_box() -> None:
    image = rasterise_text({"text": "Hi", "font_size": 24}, [0.0, 0.0, 200.0, 100.0])
    assert image is not None
    assert image.mode == "RGBA"
    # RASTER_SCALE (3×) worth of pixels, not the world size.
    assert image.size == (600, 300)


def test_rasterise_returns_none_when_there_is_nothing_to_draw() -> None:
    assert rasterise_text({"text": ""}, [0.0, 0.0, 200.0, 100.0]) is None
    assert rasterise_text({"text": "   "}, [0.0, 0.0, 200.0, 100.0]) is None
    assert rasterise_text({"text": "Hi"}, [0.0, 0.0, 0.0, 100.0]) is None
    assert rasterise_text({"text": "Hi"}, [0.0, 0.0, 200.0, float("nan")]) is None


def test_rasterise_actually_contains_ink() -> None:
    image = rasterise_text({"text": "Hello", "font_size": 24}, [0.0, 0.0, 200.0, 100.0])
    assert image is not None
    alphas = image.getchannel("A").tobytes()
    assert any(value > 0 for value in alphas), "the text mask must contain glyphs"


def test_rasterise_clamps_a_huge_box_to_the_pixel_ceiling() -> None:
    image = rasterise_text({"text": "Hi"}, [0.0, 0.0, 5000.0, 5000.0], max_px=256)
    assert image is not None
    assert max(image.size) <= 256


# ---------------------------------------------------------------------------
# cairo glyph pass
# ---------------------------------------------------------------------------


def _surface(width: int = 400, height: int = 200) -> cairo.ImageSurface:
    return cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)


def test_draw_text_box_lays_down_ink() -> None:
    surface = _surface()
    ctx = cairo.Context(surface)
    painted = draw_text_box(ctx, {"text": "Hello", "font_size": 24}, (0.0, 0.0, 300.0, 80.0))
    surface.flush()
    assert painted is True
    assert _ink_rows(surface), "the glyph pass must actually paint something"


def test_draw_text_box_is_a_no_op_without_text() -> None:
    surface = _surface()
    ctx = cairo.Context(surface)
    assert draw_text_box(ctx, {"text": ""}, (0.0, 0.0, 300.0, 80.0)) is False
    surface.flush()
    assert _ink_rows(surface) == []


def test_draw_text_box_skips_a_degenerate_box() -> None:
    ctx = cairo.Context(_surface())
    assert draw_text_box(ctx, {"text": "Hi"}, (10.0, 10.0, 10.0, 40.0)) is False
    assert draw_text_box(ctx, {"text": "Hi"}, (10.0, 10.0, 60.0, 10.0)) is False


def test_alignment_moves_the_ink_horizontally() -> None:
    """Left/centre/right must produce measurably different ink columns."""
    spans: dict[str, tuple[int, int]] = {}
    for align in ALIGNMENTS:
        surface = _surface(400, 100)
        ctx = cairo.Context(surface)
        draw_text_box(
            ctx,
            {"text": "Hi", "font_size": 24, "align": align},
            (0.0, 0.0, 400.0, 60.0),
        )
        surface.flush()
        rows = _ink_rows(surface)
        assert rows, align
        columns = _ink_columns(surface, rows[len(rows) // 2])
        assert columns, align
        spans[align] = (columns[0], columns[-1])
    assert spans["left"][0] < spans["center"][0] < spans["right"][0]
    assert spans["right"][1] > spans["center"][1] > spans["left"][1]


def test_lines_stack_downwards() -> None:
    surface = _surface(300, 200)
    ctx = cairo.Context(surface)
    draw_text_box(ctx, {"text": "one\ntwo", "font_size": 20}, (0.0, 0.0, 300.0, 160.0))
    surface.flush()
    rows = _ink_rows(surface)
    assert rows
    # Two visually separate bands: a gap somewhere between the first and last ink.
    gaps = [
        y
        for y in range(rows[0], rows[-1])
        if y not in set(rows)
    ]
    assert gaps, "the second line must start below the first, not overlap it"


def test_the_colour_comes_from_the_node_not_the_mask() -> None:
    surface = _surface(200, 80)
    ctx = cairo.Context(surface)
    draw_text_box(ctx, {"text": "Hi"}, (0.0, 0.0, 200.0, 60.0), colour="#FF0000")
    surface.flush()
    stride = surface.get_stride()
    data = bytes(surface.get_data())
    rows = _ink_rows(surface)
    assert rows
    # BGRA on little-endian ARGB32: check a strongly-covered pixel is red.
    row = rows[len(rows) // 2]
    line = data[row * stride : (row + 1) * stride]
    covered = [
        line[x * 4 + 2]
        for x in range(surface.get_width())
        if line[x * 4 + 3] > 200
    ]
    assert covered and max(covered) > 200


def test_cairo_measurer_matches_text_extents() -> None:
    ctx = cairo.Context(_surface())
    measure = cairo_measurer(ctx, 24.0)
    assert measure("", 24.0) == 0.0
    assert measure("Hello", 24.0) > 0.0
    # Twice the text is roughly twice the advance.
    assert measure("HelloHello", 24.0) > measure("Hello", 24.0)


# ---------------------------------------------------------------------------
# Renderer integration
# ---------------------------------------------------------------------------


def test_a_text_node_paints_no_outline_rectangle() -> None:
    """A bbox outline around body text is not what the user drew."""
    fills, lines = _tessellate(
        _node("TEXT", graph_config={"text": "Hello"}, bbox=(0.0, 0.0, 200.0, 100.0))
    )
    assert lines == []
    assert fills == []


def test_a_text_node_with_a_fill_keeps_it() -> None:
    fills, _ = _tessellate(
        _node("TEXT", graph_config={"text": "Hi"}, fill="#EEEEDD")
    )
    assert fills, "an explicit style.fill must still paint the text box background"


def test_an_unknown_shape_type_is_still_skipped() -> None:
    fills, lines = _tessellate(_node("SOMETHING_ELSE"))
    assert fills == [] and lines == []


def test_the_text_phase_runs_after_the_primitive_phases() -> None:
    """Text rides the texture stream, so it must not be overdrawn by shapes."""
    import inspect

    source = inspect.getsource(PrimitiveRenderer.render)
    assert source.index("self._draw_shapes(") < source.index("self._draw_texts(")


def test_export_draw_shape_renders_a_text_box() -> None:
    """The tiled raster exporter must mirror the viewport's text box."""
    surface = _surface(400, 200)
    ctx = cairo.Context(surface)
    node = _node(
        "TEXT",
        graph_config={"text": "Export", "font_size": 28},
        bbox=(10.0, 10.0, 380.0, 120.0),
    )
    _export_draw_shape(ctx, node)
    surface.flush()
    assert _ink_rows(surface), "the export must contain the text"


def test_export_draw_shape_omits_the_text_box_outline() -> None:
    surface = _surface(200, 120)
    ctx = cairo.Context(surface)
    node = _node("TEXT", graph_config={"text": "Hi"}, bbox=(20.0, 20.0, 180.0, 100.0))
    _export_draw_shape(ctx, node)
    surface.flush()
    columns = _ink_columns(surface, 20)
    # No glyph reaches the very left of the box, so ink there would be an outline.
    assert not columns or min(columns) > 20


def test_export_draw_shape_still_handles_a_path_polygon() -> None:
    surface = _surface(200, 200)
    ctx = cairo.Context(surface)
    pts = _regular_polygon(100.0, 100.0, 90.0, 90.0, 6)
    node = _node(
        "PATH",
        pts=pts,
        bbox=(10.0, 10.0, 190.0, 190.0),
        fill="#3366CC",
        stroke_width=3.0,
    )
    _export_draw_shape(ctx, node)
    surface.flush()
    assert _ink_rows(surface)


def test_constants_are_shared_with_the_dart_model() -> None:
    """These four numbers are duplicated in `text_box_model.dart` on purpose."""
    assert DEFAULT_FONT_SIZE == 24.0
    assert MIN_FONT_SIZE == 6.0
    assert MAX_FONT_SIZE == 400.0
    assert LINE_HEIGHT_FACTOR == 1.25


# ---------------------------------------------------------------------------
# Shared cairo helper — TEXT must not gain a bbox outline anywhere
# ---------------------------------------------------------------------------


def test_trace_shape_builds_no_path_for_a_text_box() -> None:
    """The PDF and thumbnail exporters trace through this shared helper."""
    from pc_agent.export.cairo_shapes import trace_shape

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    ctx = cairo.Context(surface)
    trace_shape(ctx, _node("TEXT", graph_config={"text": "Hi"}), (0.0, 0.0, 64.0, 64.0), "TEXT")
    assert list(ctx.copy_path_flat()) == [], "a TEXT box must trace no outline"


def test_apply_fill_still_fills_a_text_box_background() -> None:
    from pc_agent.export.cairo_shapes import apply_fill

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    ctx = cairo.Context(surface)
    assert apply_fill(
        ctx, NodeStyle(color="#000000", fill="#FFCC00"), "TEXT", (0.0, 0.0, 64.0, 64.0), []
    )
    surface.flush()
    assert _ink_rows(surface)


def test_the_pdf_exporter_renders_text_without_a_frame() -> None:
    from pc_agent.export.vector_pdf_exporter import _draw_shape as _pdf_draw_shape

    surface = _surface(300, 120)
    ctx = cairo.Context(surface)
    _pdf_draw_shape(
        ctx,
        _node("TEXT", graph_config={"text": "Vector"}, bbox=(10.0, 10.0, 290.0, 100.0)),
    )
    surface.flush()
    assert _ink_rows(surface), "the vector export must contain the text"
    # The top row of the box carries no glyphs, so ink there would be the frame.
    assert _ink_columns(surface, 10) == []


def test_the_thumbnail_renderer_renders_text_without_a_frame() -> None:
    from pc_agent.export.thumbnail_renderer import _draw_shape as _thumb_draw_shape

    surface = _surface(300, 120)
    ctx = cairo.Context(surface)
    _thumb_draw_shape(
        ctx,
        _node("TEXT", graph_config={"text": "Thumb"}, bbox=(10.0, 10.0, 290.0, 100.0)),
        0.25,
    )
    surface.flush()
    assert _ink_rows(surface), "the thumbnail must contain the text"
    assert _ink_columns(surface, 10) == []


# ---------------------------------------------------------------------------
# GL viewport (guarded — the text pass only exists as a texture on the mirror)
# ---------------------------------------------------------------------------


def _probe_gl() -> tuple[object | None, str]:
    """One-time ``moderngl`` context probe (the Doc 06/07/08 pattern)."""
    try:
        import moderngl
    except Exception as exc:  # pragma: no cover - environment dependent
        return None, f"moderngl unavailable: {exc}"
    for factory in (moderngl.create_context, moderngl.create_standalone_context):
        try:
            return factory(), ""
        except Exception:
            continue
    return None, "no display/GL"  # pragma: no cover - headless environments


_GL_CTX, _GL_REASON = _probe_gl()
requires_gl = pytest.mark.skipif(_GL_CTX is None, reason=_GL_REASON or "no display/GL")

_SHADER_DIR = Path(__file__).resolve().parents[1] / "viewport" / "shaders"


@requires_gl
def test_a_text_node_paints_ink_on_the_gl_viewport() -> None:
    """End-to-end: the mirrored text box must actually reach the framebuffer.

    Asserting "no GL error" alone would pass with an empty texture, so the
    frame is read back and the ink coverage compared against the same frame
    with the text removed.
    """
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.engine.document_store import Artboard
    from pc_agent.viewport.gl_canvas_host import ProgramRegistry

    ctx = _GL_CTX
    registry = ProgramRegistry(AppConfig(shader_dir=_SHADER_DIR))
    registry.set_ctx(ctx)
    renderer = PrimitiveRenderer(ctx, registry)
    fbo = ctx.simple_framebuffer((240, 160))
    artboard = Artboard(preset="A5", width=240.0, height=160.0, background_style="BLANK")

    def dark_pixels(node: CanvasNode) -> int:
        fbo.use()
        ctx.viewport = (0, 0, 240, 160)
        fbo.clear(1.0, 1.0, 1.0, 1.0)
        renderer.render(
            [node],
            (1.0, 120.0, 80.0),
            artboard,
            {"min_x": 0.0, "min_y": 0.0, "max_x": 240.0, "max_y": 160.0},
        )
        raw = fbo.read(components=3)
        return sum(
            1
            for index in range(0, len(raw) - 2, 3)
            if raw[index] < 200 and raw[index + 1] < 200 and raw[index + 2] < 200
        )

    try:
        with_text = dark_pixels(
            _node(
                "TEXT",
                graph_config={"text": "MIRRORED TEXT", "font_size": 40},
                bbox=(10.0, 20.0, 230.0, 80.0),
            )
        )
        without_text = dark_pixels(
            _node(
                "TEXT",
                graph_config={"text": "", "font_size": 40},
                bbox=(10.0, 20.0, 230.0, 80.0),
            )
        )
        assert with_text > without_text, "the text box must reach the framebuffer"
        assert ctx.error == "GL_NO_ERROR"
    finally:
        renderer.release()
        fbo.release()


@requires_gl
def test_the_text_texture_is_cached_between_frames() -> None:
    """The raster must not be re-baked per frame — that would run cairo in the loop."""
    import moderngl  # noqa: F401  (documents that this test needs a live context)

    from pc_agent.core.config_manager import AppConfig
    from pc_agent.viewport.gl_canvas_host import ProgramRegistry

    ctx = _GL_CTX
    registry = ProgramRegistry(AppConfig(shader_dir=_SHADER_DIR))
    registry.set_ctx(ctx)
    renderer = PrimitiveRenderer(ctx, registry)
    node = _node(
        "TEXT",
        graph_config={"text": "cached", "font_size": 20},
        bbox=(0.0, 0.0, 120.0, 40.0),
    )
    try:
        first = renderer._text_texture(node)
        second = renderer._text_texture(node)
        assert first is not None
        assert first is second
        assert len(renderer._text_cache) == 1
        # A different string is a different cache entry, not a silent reuse.
        other = _node(
            "TEXT",
            graph_config={"text": "different", "font_size": 20},
            bbox=(0.0, 0.0, 120.0, 40.0),
        )
        assert renderer._text_texture(other) is not first
        assert len(renderer._text_cache) == 2
    finally:
        renderer.release()
        assert renderer._text_cache == {}

