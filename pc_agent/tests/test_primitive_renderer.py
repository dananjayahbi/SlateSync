"""Doc 08 acceptance tests — PrimitiveRenderer, graph/shape math & shader contracts.

Pure-math tests always run: frustum-culling/zoom math, pattern coordinate math
(32 u ruled / 24 u dot / 24 u 60° iso), glyph-atlas sheet dimensions, shape and
graph tessellation, shader-source contracts, and source-level render-order /
import-purity checks. GL-context tests are guarded by a one-time
``moderngl.create_context()`` probe (Doc 06/07 pattern).
"""

from __future__ import annotations

import ast
import inspect
import re
from pathlib import Path

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.viewport.gl_canvas_host import ProgramRegistry
from pc_agent.viewport.primitive_renderer import (
    CIRCLE_SEGMENTS,
    GLYPH_CELL_H,
    GLYPH_CELL_W,
    GLYPH_CHARS,
    GLYPH_COLS,
    GLYPH_ROWS,
    GLYPH_SHEET_SIZE,
    MAX_GRAPH_TICKS,
    RULED_SPACING,
    ZOOM_MAX,
    ZOOM_MIN,
    PrimitiveRenderer,
    arrow_geometry,
    build_cartesian_graph,
    build_number_line_graph,
    circle_triangles,
    format_graph_value,
    graph_geometry,
    is_visible,
    line_quad,
    make_glyph_sheet,
    parse_color,
    placeholder_image,
    rect_corners,
    resolve_asset_path,
    ruled_intensity,
    ruled_line_distance,
    square_intensity,
    square_line_distance,
    triangle_points,
    visible_world_rect,
    world_to_screen,
)

SHADER_DIR = Path(__file__).resolve().parents[1] / "viewport" / "shaders"
RENDERER_PATH = Path(__file__).resolve().parents[1] / "viewport" / "primitive_renderer.py"
SHADER_STEMS = ("primitive", "grid", "texture")


def _probe_gl() -> tuple[object | None, str]:
    """Attempt ``moderngl.create_context()`` once, then a standalone fallback."""
    try:
        import moderngl
    except Exception as exc:  # pragma: no cover - environment dependent
        return None, f"moderngl unavailable: {exc}"
    try:
        return moderngl.create_context(), ""
    except Exception:
        pass
    try:
        return moderngl.create_standalone_context(), ""
    except Exception as exc:  # pragma: no cover - headless environments
        return None, f"no display/GL: {exc}"


_GL_CTX, _GL_REASON = _probe_gl()
requires_gl = pytest.mark.skipif(_GL_CTX is None, reason=_GL_REASON or "no display/GL")


# ---------------------------------------------------------------------------
# Always-run: frustum culling math (Doc 08 §6)
# ---------------------------------------------------------------------------


def test_visible_world_rect_doc_example_exact() -> None:
    # camera (scale=2, tx=100, ty=50) at 800×600 ⇒ exactly (-100, -100, 300, 200)
    assert visible_world_rect((2.0, 100.0, 50.0), (800, 600)) == (-100.0, -100.0, 300.0, 200.0)


def test_visible_world_rect_scale_clamp_follows_zoom_range() -> None:
    assert ZOOM_MIN == 0.05 and ZOOM_MAX == 20.0
    # scale 0 → clamped to 0.05 ⇒ half-extent 100 / (2·0.05) = 1000
    assert visible_world_rect((0.0, 0.0, 0.0), (100, 100)) == (-1000.0, -1000.0, 1000.0, 1000.0)
    # scale 100 → clamped to 20 ⇒ half-extent 100 / 40 = 2.5
    assert visible_world_rect((100.0, 0.0, 0.0), (100, 100)) == (-2.5, -2.5, 2.5, 2.5)


def test_is_visible_overlap_and_inclusive_edges() -> None:
    assert is_visible((0.0, 0.0, 10.0, 10.0), (5.0, 5.0, 15.0, 15.0)) is True
    # touching an edge counts as visible (inclusive)
    assert is_visible((-1.0, -1.0, 0.0, 0.0), (0.0, 0.0, 5.0, 5.0)) is True
    # disjoint → culled
    assert is_visible((0.0, 0.0, 1.0, 1.0), (2.0, 2.0, 3.0, 3.0)) is False
    # bbox corners may arrive in any order; degenerate points still intersect
    assert is_visible((15.0, 15.0, 5.0, 5.0), (0.0, 0.0, 10.0, 10.0)) is True
    assert is_visible((0.0, 0.0, 0.0, 0.0), (0.0, 0.0, 1.0, 1.0)) is True
    assert is_visible((0.0, 0.0, 0.0, 0.0), (1.0, 1.0, 2.0, 2.0)) is False
    assert is_visible("garbage", (0.0, 0.0, 1.0, 1.0)) is False


def test_world_to_screen_matches_template_transform() -> None:
    # camera centre lands on the viewport centre (template §3)
    assert world_to_screen((10.0, 20.0), (2.0, 10.0, 20.0), (800, 600)) == (400.0, 300.0)
    # +16 world units at scale 2 → +32 px
    assert world_to_screen((26.0, 20.0), (2.0, 10.0, 20.0), (800, 600)) == (432.0, 300.0)


def test_class_exposes_pure_math_as_staticmethods() -> None:
    assert PrimitiveRenderer.visible_world_rect((1.0, 0.0, 0.0), (100, 100)) == (
        -50.0,
        -50.0,
        50.0,
        50.0,
    )
    assert PrimitiveRenderer.is_visible((0.0, 0.0, 1.0, 1.0), (0.0, 0.0, 2.0, 2.0)) is True


# ---------------------------------------------------------------------------
# Always-run: pattern coordinate math (Doc 08 §6)
# ---------------------------------------------------------------------------


def test_rule_pattern_fires_on_multiples_of_the_configured_spacing() -> None:
    assert RULED_SPACING == 32.0
    for y in (-64.0, 0.0, 32.0, 64.0):
        assert ruled_line_distance(y) == pytest.approx(0.0, abs=1e-9)
        assert ruled_intensity(y) == pytest.approx(1.0, abs=1e-6)
    # 16 is half-way between lines → no fire
    assert ruled_line_distance(16.0) == pytest.approx(16.0)
    assert ruled_intensity(16.0) == pytest.approx(0.0)
    # half intensity exactly at the line half-width edge
    assert ruled_intensity(0.5, line_half=0.5, aa=0.25) == pytest.approx(0.5)


def test_rule_spacing_is_configurable() -> None:
    """Round-9: the user picks the gap between rules."""
    for gap in (8.0, 16.0, 24.0, 48.0, 100.0):
        for multiple in (0.0, 1.0, 3.0, -2.0):
            y = gap * multiple
            assert ruled_line_distance(y, gap) == pytest.approx(0.0, abs=1e-9)
            assert ruled_intensity(y, spacing=gap) == pytest.approx(1.0, abs=1e-6)
        # half-way between two rules is ink-free
        assert ruled_intensity(gap * 0.5, spacing=gap) == pytest.approx(0.0)


def test_square_grid_fires_on_both_rule_families() -> None:
    """SQUARE_GRID replaced DOT_GRID/ISO_GRID in round 9."""
    for gap in (16.0, 32.0):
        # a horizontal rule
        assert square_line_distance(0.0, gap, gap) == pytest.approx(0.0, abs=1e-9)
        # a vertical rule
        assert square_line_distance(gap, 0.0, gap) == pytest.approx(0.0, abs=1e-9)
        assert square_intensity(gap * 2, gap * 3, spacing=gap) == pytest.approx(
            1.0, abs=1e-6
        )
        # cell centre is equidistant from both families → no ink
        assert square_intensity(gap * 0.5, gap * 0.5, spacing=gap) == pytest.approx(
            0.0
        )
    # A larger cell means fewer rules: a point that IS on the 16 u lattice is
    # no longer on the 32 u one.
    assert square_intensity(16.0, 8.0, spacing=16.0) == pytest.approx(1.0, abs=1e-6)
    assert square_intensity(16.0, 8.0, spacing=32.0) == pytest.approx(0.0)


def test_retired_patterns_are_gone() -> None:
    """DOT_GRID / ISO_GRID were removed; importing them must fail now."""
    import pc_agent.viewport.primitive_renderer as renderer

    for retired in ("DOT_RADIUS", "ISO_SQRT3", "ISO_PERIOD", "dot_intensity"):
        assert not hasattr(renderer, retired), retired
    assert renderer._PATTERN_IDS == {"BLANK": 0, "RULED": 1, "SQUARE_GRID": 2}


# ---------------------------------------------------------------------------
# Always-run: glyph atlas dimensions (Doc 08 §4/§6)
# ---------------------------------------------------------------------------


def test_glyph_sheet_frozen_dimensions() -> None:
    assert GLYPH_SHEET_SIZE == (128, 64)
    assert (GLYPH_CELL_W, GLYPH_CELL_H) == (16, 32)
    assert GLYPH_COLS * GLYPH_ROWS == 16  # 8 cols × 2 rows = 16 frozen cells
    assert GLYPH_CHARS == "0123456789-+."  # 13 chars occupy the first 13 cells
    sheet = make_glyph_sheet()
    assert sheet.size == (128, 64)
    assert sheet.mode == "RGBA"


def test_every_digit_has_ink_inside_its_cell() -> None:
    sheet = make_glyph_sheet()
    for index, char in enumerate("0123456789"):
        col, row = index % 8, index // 8
        cell = sheet.crop((col * 16, row * 32, (col + 1) * 16, (row + 1) * 32))
        channel = cell.getchannel("A")
        assert channel.getbbox() is not None, f"digit {char!r} cell is empty"
        assert channel.getextrema()[1] > 0, f"digit {char!r} has zero alpha"


def test_glyph_charset_matches_atlas_and_labels_format() -> None:
    assert set(GLYPH_CHARS) == set("0123456789-+.")
    assert format_graph_value(25.0) == "25"
    assert format_graph_value(-12.5) == "-12.5"
    assert format_graph_value(-0.0) == "0"
    assert format_graph_value(float("nan")) == ""
    for value in (1e6, -3.14, 0.0, 9999999.0, 0.125):
        text = format_graph_value(value)
        assert text and all(ch in GLYPH_CHARS for ch in text)


# ---------------------------------------------------------------------------
# Always-run: shader source contracts (Doc 08 §6, stems per Doc 06 registry)
# ---------------------------------------------------------------------------


def test_shader_stems_present_and_registry_lists_them() -> None:
    for stem in SHADER_STEMS:
        assert (SHADER_DIR / f"{stem}.vert").is_file()
        assert (SHADER_DIR / f"{stem}.frag").is_file()
    registry = ProgramRegistry(AppConfig(shader_dir=SHADER_DIR))
    assert {"stroke", *SHADER_STEMS} <= set(registry.stems)


def test_every_shader_stage_targets_gl33_core() -> None:
    names = [f"{stem}{ext}" for stem in SHADER_STEMS for ext in (".vert", ".frag")]
    for name in names:
        source = (SHADER_DIR / name).read_text(encoding="utf-8")
        assert "#version 330 core" in source, name


def test_camera_transform_is_shared_across_vertex_stages() -> None:
    transform = "(world - u_camera.yz) * u_camera.x + u_viewport * 0.5"
    for name in ("stroke.vert", "primitive.vert", "texture.vert"):
        source = (SHADER_DIR / name).read_text(encoding="utf-8")
        assert transform in source, name
        assert "screen / u_viewport * 2.0 - 1.0" in source, name


def test_grid_shader_uniform_contract() -> None:
    frag = (SHADER_DIR / "grid.frag").read_text(encoding="utf-8")
    vert = (SHADER_DIR / "grid.vert").read_text(encoding="utf-8")
    assert "in vec2 in_pos" in vert
    for uniform in (
        "u_camera",
        "u_viewport",
        "u_pattern",
        "u_spacing",
        "u_bgColor",
        "u_lineColor",
        "u_scissor",
        "u_scissorEnabled",
    ):
        assert uniform in frag, uniform
    assert "fwidth" in frag and "smoothstep" in frag
    # Round-9: only BLANK / RULED / SQUARE_GRID remain, and both patterned
    # branches are parameterised by u_spacing (user-chosen gap / cell side).
    assert "u_spacing" in frag
    assert "spacing * floor" in frag
    # both axes are sampled for SQUARE_GRID (a real lattice, not dots)
    assert "world.x - spacing * floor" in frag
    assert "world.y - spacing * floor" in frag
    assert "min(dx, dy)" in frag
    # the retired ISO_GRID math must be gone
    assert "sqrt(3.0)" not in frag
    assert "0.45 * 24.0" not in frag


def test_primitive_shader_uniform_contract() -> None:
    vert = (SHADER_DIR / "primitive.vert").read_text(encoding="utf-8")
    frag = (SHADER_DIR / "primitive.frag").read_text(encoding="utf-8")
    for uniform in ("u_camera", "u_viewport"):
        assert uniform in vert, uniform
    for uniform in ("u_kind", "u_pageSize", "u_shadowOf", "u_shadowColor", "u_blendMode"):
        assert uniform in frag, uniform
    assert "fwidth" in frag and "smoothstep" in frag
    assert "GL_DST_COLOR, GL_ZERO" in frag  # template §3 MULTIPLY pairing
    # varyings pair between stages
    for varying in ("v_rgba", "v_aux", "v_hw", "v_world"):
        assert re.search(rf"\bout\s+\w+\s+{varying}\b", vert), varying
        assert re.search(rf"\bin\s+\w+\s+{varying}\b", frag), varying


def test_texture_shader_uniform_contract() -> None:
    vert = (SHADER_DIR / "texture.vert").read_text(encoding="utf-8")
    frag = (SHADER_DIR / "texture.frag").read_text(encoding="utf-8")
    assert "in vec4 in_pos_uv" in vert
    for uniform in ("u_camera", "u_viewport"):
        assert uniform in vert, uniform
    for uniform in ("u_tex", "u_tint", "u_blendMode"):
        assert uniform in frag, uniform
    assert "texture(" in frag
    assert "out vec2 v_uv" in vert and "in vec2 v_uv" in frag
    assert "GL_DST_COLOR, GL_ZERO" in frag


# ---------------------------------------------------------------------------
# Always-run: render order & import purity (Doc 08 §6)
# ---------------------------------------------------------------------------


def test_render_phases_execute_in_frozen_order() -> None:
    source = inspect.getsource(PrimitiveRenderer.render)
    order = [
        "self._draw_background(",
        "self._draw_shadow_boundary(",
        "self._draw_images(",
        "self._draw_shapes(",
        "self._draw_graphs(",
    ]
    positions = [source.index(token) for token in order]
    assert positions == sorted(positions), "frozen phase order violated"
    assert source.index("self._restore_state()") > positions[-1]


def test_render_restores_state_source_level() -> None:
    source = inspect.getsource(PrimitiveRenderer._restore_state)
    assert "blend_func" in source
    assert "disable_direct" in source  # GL_SCISSOR_TEST switched back off


def test_module_imports_only_contract_models() -> None:
    tree = ast.parse(RENDERER_PATH.read_text(encoding="utf-8"))
    imported: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            imported.setdefault(node.module, set()).update(alias.name for alias in node.names)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                imported.setdefault(alias.name, set())
    allowed = {
        "pc_agent.engine.scene_graph": {"CanvasNode"},
        "pc_agent.engine.document_store": {"Artboard"},
        "pc_agent.viewport.gl_canvas_host": {"ProgramRegistry"},
        # Round-8 issue 02: pure leaf helper (no GL, no engine deps) for the
        # fill-vs-outline decision the Doc 08 §5(7) contract always required.
        "pc_agent.viewport.shape_fill": {"shape_is_filled"},
        # Round-9 issues 04/05/06: pure geometry (polygon fill, PATH, TABLE)
        # shared by the viewport and all three exporters — leaf module, no GL
        # and no engine imports, exactly like shape_fill.
        "pc_agent.viewport.vector_geometry": {
            "outline_segments",
            "points_of",
            "polyline_segments",
            "rect_to_triangles",
            "table_geometry",
            "triangulate",
        },
    }
    pc_modules = {module for module in imported if module.startswith("pc_agent")}
    assert pc_modules <= set(allowed), f"unexpected pc_agent imports: {pc_modules}"
    for module in pc_modules:
        assert imported[module] <= allowed[module], module
    # engine contract types stay TYPE_CHECKING-only: no runtime engine import
    import pc_agent.viewport.primitive_renderer as renderer_module

    assert not hasattr(renderer_module, "CanvasNode")
    assert not hasattr(renderer_module, "Artboard")
    assert not hasattr(renderer_module, "ProgramRegistry")
    source = RENDERER_PATH.read_text(encoding="utf-8")
    for forbidden in ("SceneGraph", "query_bbox", "apply_rpc", "DocumentStore(", "WsStream"):
        assert forbidden not in source, forbidden


# ---------------------------------------------------------------------------
# Always-run: shape tessellation (Doc 08 §4(4))
# ---------------------------------------------------------------------------


def test_rect_corners_prefer_pts_then_bbox() -> None:
    assert rect_corners([[10.0, 20.0], [40.0, 60.0]], (0.0, 0.0, 1.0, 1.0)) == (
        10.0,
        20.0,
        40.0,
        60.0,
    )
    # corners normalise regardless of order
    assert rect_corners([[40.0, 60.0], [10.0, 20.0]], (0.0, 0, 1, 1)) == (10.0, 20.0, 40.0, 60.0)
    assert rect_corners([], (0.0, 0.0, 50.0, 40.0)) == (0.0, 0.0, 50.0, 40.0)
    assert rect_corners(None, (5.0, 5.0, 5.0, 9.0)) is None  # degenerate edge


def test_circle_fan_has_64_segments_covering_the_bbox() -> None:
    verts = circle_triangles(100.0, 100.0, 50.0, 50.0)
    assert len(verts) == CIRCLE_SEGMENTS * 6  # 64 segments × 3 verts × (x, y)
    xs, ys = verts[0::2], verts[1::2]
    assert max(xs) == pytest.approx(150.0)
    assert min(xs) == pytest.approx(50.0)
    assert max(ys) == pytest.approx(150.0)
    assert min(ys) == pytest.approx(50.0)


def test_triangle_requires_three_points() -> None:
    assert triangle_points([[0.0, 0.0], [10.0, 0.0], [0.0, 10.0]]) == [
        0.0, 0.0, 10.0, 0.0, 0.0, 10.0,
    ]
    assert triangle_points([[0.0, 0.0], [1.0, 1.0]]) is None


def test_arrow_geometry_head_length_and_half_width() -> None:
    built = arrow_geometry((0.0, 0.0), (100.0, 0.0), 4.0)
    assert built is not None
    shaft, head, head_len = built
    assert head_len == pytest.approx(0.25 * 100.0)  # 0.25·shaft_length
    assert len(shaft) == 12  # shaft quad = 6 verts × (x, y)
    assert len(head) == 12  # 2 head triangles
    # base corners sit at the shaft end with half-width 3× stroke_width = 12
    base_ys = sorted({round(head[1], 6), round(head[7], 6)})
    assert base_ys == [pytest.approx(-12.0), pytest.approx(12.0)]
    # apex extends 0.25·L beyond the end
    assert head[4] == pytest.approx(125.0)
    assert head[5] == pytest.approx(0.0)
    assert arrow_geometry((5.0, 5.0), (5.0, 5.0), 2.0) is None  # degenerate


def test_line_quad_carries_signed_half_width() -> None:
    quad = line_quad(0.0, 0.0, 10.0, 0.0, 2.0)  # horizontal ⇒ normal (0, ±2)
    assert len(quad) == 12
    assert quad[0:3] == [0.0, 2.0, 2.0]
    assert quad[3:6] == [0.0, -2.0, -2.0]
    assert quad[6:9] == [10.0, -2.0, -2.0]
    assert quad[9:12] == [10.0, 2.0, 2.0]
    assert line_quad(5.0, 5.0, 5.0, 5.0, 1.0) == []  # degenerate segment


# ---------------------------------------------------------------------------
# Always-run: graph tessellation (Doc 08 §4(3))
# ---------------------------------------------------------------------------


def test_cartesian_axes_gridlines_ticks_and_labels() -> None:
    cfg = {
        "origin": [100.0, 100.0],
        "x_range": [-100.0, 300.0],
        "y_range": [-100.0, 200.0],
        "grid_step": 100.0,
        "show_labels": True,
    }
    geo = build_cartesian_graph(cfg)
    # axis lines pass through the origin, clipped to the ranges
    assert (0.0, 100.0, 400.0, 100.0) in geo.lines
    assert (100.0, 0.0, 100.0, 300.0) in geo.lines
    # major gridlines every grid_step clipped to both ranges
    assert (200.0, 0.0, 200.0, 300.0) in geo.lines  # vertical at origin.x + 100
    assert (0.0, 300.0, 400.0, 300.0) in geo.lines  # horizontal at origin.y + 200
    # tick length 0.35·grid_step centred on the axes
    assert (0.0, 100.0 - 17.5, 0.0, 100.0 + 17.5) in geo.lines
    # labels exist, use only atlas characters, and "200" appears on both axes
    assert geo.glyphs
    assert all(glyph[0] and all(ch in GLYPH_CHARS for ch in glyph[0]) for glyph in geo.glyphs)
    labels_200 = [glyph for glyph in geo.glyphs if glyph[0] == "200"]
    assert len(labels_200) == 2
    x_label = max(labels_200, key=lambda glyph: glyph[1])
    y_label = min(labels_200, key=lambda glyph: glyph[1])
    assert x_label[1] == pytest.approx(300.0)  # origin.x + 200
    assert y_label[1] < 100.0  # left of the y-axis
    assert x_label[2] > 100.0  # below the x-axis


def test_cartesian_show_labels_and_zero_step_degrade_gracefully() -> None:
    quiet = build_cartesian_graph(
        {"origin": [0, 0], "x_range": [-50, 50], "y_range": [-50, 50],
         "grid_step": 25.0, "show_labels": False}
    )
    assert quiet.glyphs == []
    assert len(quiet.lines) > 2  # gridlines + ticks still drawn
    no_step = build_cartesian_graph(
        {"origin": [0, 0], "x_range": [-50, 50], "y_range": [-50, 50], "grid_step": 0}
    )
    assert len(no_step.lines) == 2  # axes only


def test_number_line_axis_ticks_labels_and_arrowheads() -> None:
    cfg = {
        "origin": [0.0, 50.0],
        "x_range": [0.0, 300.0],
        "grid_step": 100.0,
        "show_labels": True,
    }
    geo = build_number_line_graph(cfg)
    assert (0.0, 50.0, 300.0, 50.0) in geo.lines
    ticks = [seg for seg in geo.lines if seg[0] == seg[2]]
    assert len(ticks) == 4  # values 0, 100, 200, 300
    assert len(geo.tris) == 4  # 2 arrowhead triangles per end
    head_len = 0.35 * 100.0
    assert max(tri[4] for tri in geo.tris) == pytest.approx(300.0 + head_len)
    assert min(tri[4] for tri in geo.tris) == pytest.approx(-head_len)
    assert [glyph[0] for glyph in geo.glyphs] == ["0", "100", "200", "300"]
    assert all(glyph[2] > 50.0 for glyph in geo.glyphs)  # labels below the axis


def test_graph_geometry_skips_other_shape_types() -> None:
    assert graph_geometry("RECT", {}) is None
    assert graph_geometry(None, None) is None
    assert graph_geometry("CARTESIAN_2D", {}) is not None
    assert graph_geometry("NUMBER_LINE", {}) is not None


def test_graph_tick_guard_caps_degenerate_configs() -> None:
    geo = build_cartesian_graph(
        {"origin": [0, 0], "x_range": [0.0, 1e9], "y_range": [-5.0, 5.0],
         "grid_step": 0.001}  # 10^12 x-ticks and 10^4 y-ticks → both skipped
    )
    assert len(geo.lines) == 2  # axis lines only
    assert geo.glyphs == []
    assert MAX_GRAPH_TICKS == 4096


# ---------------------------------------------------------------------------
# Always-run: colour / asset helpers
# ---------------------------------------------------------------------------


def test_parse_color_and_placeholder_helpers() -> None:
    assert parse_color("#F00") == (1.0, 0.0, 0.0, 1.0)
    assert parse_color("#1E1E1E", 0.5)[3] == pytest.approx(0.5)
    assert parse_color("nonsense") == (0.0, 0.0, 0.0, 1.0)
    image = placeholder_image()
    assert image.size == (1, 1)
    assert image.getpixel((0, 0)) == (255, 0, 255, 255)


def test_resolve_asset_path_follows_assets_dir_contract() -> None:
    root = Path("C:/slatesync/assets")
    assert resolve_asset_path(root, "assets/img_9921.png") == root / "img_9921.png"
    assert resolve_asset_path(root, "img_9921.png") == root / "img_9921.png"
    assert resolve_asset_path(None, "assets/img_9921.png") == Path("img_9921.png")


# ---------------------------------------------------------------------------
# GL-guarded: atlas texture + single-frame render smoke (Doc 08 §6)
# ---------------------------------------------------------------------------


def _registry() -> ProgramRegistry:
    registry = ProgramRegistry(AppConfig(shader_dir=SHADER_DIR))
    registry.set_ctx(_GL_CTX)
    return registry


@requires_gl
def test_glyph_atlas_uploads_cached_linear_texture() -> None:
    import moderngl

    renderer = PrimitiveRenderer(_GL_CTX, _registry())
    try:
        atlas = renderer.glyph_atlas()
        assert atlas.size == (128, 64)
        assert atlas.filter == (moderngl.LINEAR, moderngl.LINEAR)
        assert renderer.glyph_atlas() is atlas  # second call returns the cached object
        assert _GL_CTX.error == "GL_NO_ERROR"
    finally:
        renderer.release()


@requires_gl
def test_render_smoke_a4_ruled_number_line_image_single_frame() -> None:
    from pc_agent.engine.document_store import Artboard
    from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle

    registry = _registry()
    renderer = PrimitiveRenderer(_GL_CTX, registry)
    fbo = _GL_CTX.simple_framebuffer((400, 300))
    try:
        fbo.use()
        _GL_CTX.viewport = (0, 0, 400, 300)
        _GL_CTX.clear(1.0, 1.0, 1.0, 1.0)
        artboard = Artboard(
            preset="A4",
            width=2480.0,
            height=3508.0,
            is_infinite=False,
            background_style="RULED",
            background_color="#FFFFFF",
        )
        rect = CanvasNode(
            node_id="rect-1",
            kind="SHAPE",
            layer=1,
            bbox=(1220.0, 1734.0, 1260.0, 1774.0),
            # Round-8 issue 02: stroke_width == 0 is the schema's only way to
            # request a solid shape (see pc_agent/viewport/shape_fill.py), so
            # this node exercises the fill branch; positive widths are outlines.
            style=NodeStyle(color="#FF0000", stroke_width=0.0),
            geometry=NodeGeometry(shape_type="RECT"),
        )
        multiplied = CanvasNode(
            node_id="mul-1",
            kind="SHAPE",
            layer=0,
            bbox=(1100.0, 1700.0, 1140.0, 1740.0),
            style=NodeStyle(color="#808080", blend_mode="MULTIPLY"),
            geometry=NodeGeometry(shape_type="RECT"),
        )
        graph = CanvasNode(
            node_id="graph-1",
            kind="GRAPH_AXES",
            layer=2,
            bbox=(1090.0, 1600.0, 1390.0, 1710.0),
            style=NodeStyle(color="#1E1E1E", stroke_width=2.5),
            geometry=NodeGeometry(
                shape_type="NUMBER_LINE",
                graph_config={
                    "origin": [1240.0, 1654.0],
                    "x_range": [-150.0, 150.0],
                    "grid_step": 50.0,
                    "show_labels": True,
                },
            ),
        )
        image = CanvasNode(
            node_id="img-1",
            kind="IMAGE",
            layer=3,
            bbox=(1300.0, 1754.0, 1340.0, 1794.0),
            geometry=NodeGeometry(asset_ref="assets/definitely_missing.png"),
        )
        culled = CanvasNode(
            node_id="far-away",
            kind="SHAPE",
            layer=9,
            bbox=(100000.0, 100000.0, 100100.0, 100100.0),
            geometry=NodeGeometry(shape_type="RECT"),
        )
        renderer.set_assets_root(Path(__file__).parent)  # asset absent → placeholder
        renderer.render(
            [rect, multiplied, graph, image, culled],
            (1.0, 1240.0, 1754.0),
            artboard,
            {"min_x": 0.0, "min_y": 0.0, "max_x": 2480.0, "max_y": 3508.0},
        )
        assert _GL_CTX.error == "GL_NO_ERROR"
        # bounded preset ⇒ scissor applied and recorded
        assert renderer.scissor_enabled is True
        assert renderer.applied_scissor is not None

        data = fbo.read(components=3, alignment=1)

        def pixel(x: int, y_bottom_up: int) -> tuple[int, int, int]:
            start = (y_bottom_up * 400 + x) * 3
            return tuple(data[start : start + 3])

        # centre pixel: the red RECT covering the camera centre
        centre = pixel(200, 150)
        assert centre[0] > 200 and centre[1] < 80 and centre[2] < 80
        # image phase: 1×1 magenta placeholder stretched over the image bbox
        placeholder = pixel(280, 130)
        assert placeholder[0] > 200 and placeholder[1] < 60 and placeholder[2] > 200
        # background: RULED grey line ink (r == g == b, between white and dark)
        has_pattern = any(
            value[0] == value[1] == value[2] and 90 < value[0] < 235
            for value in (tuple(data[i : i + 3]) for i in range(0, len(data), 3))
        )
        assert has_pattern, "RULED background must paint line ink"
        # graph phase: dark axis/glyph pixels (#1E1E1E)
        has_graph = any(
            value[0] < 100 and value[1] < 100 and value[2] < 100
            for value in (tuple(data[i : i + 3]) for i in range(0, len(data), 3))
        )
        assert has_graph, "NUMBER_LINE axes/labels must be drawn"

        # INFINITE canvas: no shadow/boundary and no scissor applied
        infinite = Artboard(
            preset="INFINITE",
            width=None,
            height=None,
            is_infinite=True,
            background_style="SQUARE_GRID",
            background_color="#FFFFFF",
        )
        renderer.render([], (0.5, 0.0, 0.0), infinite, {})
        assert renderer.applied_scissor is None
        assert renderer.scissor_enabled is False
        assert _GL_CTX.error == "GL_NO_ERROR"
    finally:
        renderer.release()
        fbo.release()


@requires_gl
def test_missing_asset_logs_warning_once_and_caches_placeholder() -> None:
    from pc_agent.engine.document_store import Artboard
    from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry

    renderer = PrimitiveRenderer(_GL_CTX, _registry())
    fbo = _GL_CTX.simple_framebuffer((64, 64))
    try:
        fbo.use()
        _GL_CTX.viewport = (0, 0, 64, 64)
        artboard = Artboard(preset="A5", width=1748.0, height=2480.0)
        node = CanvasNode(
            node_id="img-miss",
            kind="IMAGE",
            bbox=(0.0, 0.0, 10.0, 10.0),
            geometry=NodeGeometry(asset_ref="assets/nope.png"),
        )
        renderer.set_assets_root(Path(__file__).parent)
        _assert_warning_once(renderer, node, artboard)
        assert _GL_CTX.error == "GL_NO_ERROR"
    finally:
        renderer.release()
        fbo.release()


def _assert_warning_once(renderer, node, artboard) -> None:
    """Render twice; the second render must not re-warn (round-9: the miss is
    remembered but the texture is intentionally NOT cached, so the bytes can
    land later and be picked up without a restart)."""
    import logging

    class _Capture(logging.Handler):
        def __init__(self) -> None:
            super().__init__()
            self.messages: list[str] = []

        def emit(self, record: logging.LogRecord) -> None:
            self.messages.append(record.getMessage())

    handler = _Capture()
    logger = logging.getLogger("pc_agent.viewport.primitive_renderer")
    logger.addHandler(handler)
    try:
        logger.setLevel(logging.DEBUG)
        renderer.render([node], (1.0, 5.0, 5.0), artboard, {})
        renderer.render([node], (1.0, 5.0, 5.0), artboard, {})
    finally:
        logger.removeHandler(handler)
    warnings = [m for m in handler.messages if "magenta placeholder" in m]
    assert len(warnings) == 1, f"expected exactly one placeholder warning, got {warnings}"
    # Nothing was cached under the asset key, so a later ASSET_DONE can win.
    assert not any("nope.png" in key for key in renderer._image_cache)
