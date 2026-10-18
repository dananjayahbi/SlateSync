"""Doc 07 acceptance tests — StrokeTessellator & stroke shaders (headless-safe).

Pure-math tests always run: golden Catmull-Rom → Bézier conversions (τ = 0.5),
adaptive sampling counts, the ``2·S + 20`` vertex formula, bbox exactness,
width-profile lerp/clamp endpoints, degenerate inputs, and the source-level
shader contract. VAO upload/draw tests are GL-guarded (skipif after a one-time
moderngl context probe).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.viewport.gl_canvas_host import ProgramRegistry
from pc_agent.viewport.stroke_tessellator import (
    CAP_VERTS,
    StrokeTessellator,
    TessellatedMesh,
    build_strip,
    catmull_rom_to_bezier,
    compute_half_widths,
    sample_path,
    sample_segment,
    spline_control_points,
    tessellate_stroke,
)

SHADER_DIR = Path(__file__).resolve().parents[1] / "viewport" / "shaders"


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
# Always-run: Catmull-Rom → cubic Bézier (golden values, Doc 07 §6)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("points", "expected"),
    [
        (((0.0, 0.0), (3.0, 0.0), (6.0, 0.0), (9.0, 0.0)), ((4.0, 0.0), (5.0, 0.0))),
        (((0.0, 0.0), (0.0, 3.0), (0.0, 6.0), (0.0, 9.0)), ((0.0, 4.0), (0.0, 5.0))),
        (
            ((0.0, 0.0), (1.0, 0.0), (2.0, 1.0), (3.0, 1.0)),
            ((4.0 / 3.0, 1.0 / 6.0), (5.0 / 3.0, 5.0 / 6.0)),
        ),
    ],
)
def test_catmull_rom_golden_control_points(
    points: tuple, expected: tuple[float, float]
) -> None:
    c1, c2 = catmull_rom_to_bezier(*points)
    assert c1 == pytest.approx(expected[0], abs=1e-6)
    assert c2 == pytest.approx(expected[1], abs=1e-6)


def test_spline_clamps_open_polyline_endpoints() -> None:
    pts = [(0.0, 0.0), (3.0, 0.0), (6.0, 0.0), (9.0, 0.0)]
    segments = spline_control_points(pts)
    assert len(segments) == 3
    # p_{-1} = p_0 for the first segment, p_n = p_{n-1} for the last.
    first = segments[0]
    assert first == (
        pts[0],
        *catmull_rom_to_bezier(pts[0], pts[0], pts[1], pts[2]),
        pts[1],
    )
    last = segments[-1]
    assert last == (
        pts[2],
        *catmull_rom_to_bezier(pts[1], pts[2], pts[3], pts[3]),
        pts[3],
    )
    assert spline_control_points([(1.0, 2.0)]) == []


# ---------------------------------------------------------------------------
# Always-run: adaptive sampling (Doc 07 §4: n = max(2, ceil(L·scale/8)))
# ---------------------------------------------------------------------------


def test_sample_segment_count_from_chord_length() -> None:
    # L = 10 + 15 + 15 = 40 px ⇒ n = ceil(40/8) = 5 ⇒ 6 samples (both endpoints)
    long_seg = ((0.0, 0.0), (10.0, 0.0), (25.0, 0.0), (40.0, 0.0))
    samples = sample_segment(*long_seg)
    assert len(samples) == 6
    assert samples[0] == pytest.approx((0.0, 0.0))
    assert samples[-1] == pytest.approx((40.0, 0.0))

    # L = 1 + 1 + 2 = 4 px ⇒ n = max(2, ceil(0.5)) = 2 ⇒ 3 samples (floor)
    short_seg = ((0.0, 0.0), (1.0, 0.0), (2.0, 0.0), (4.0, 0.0))
    assert len(sample_segment(*short_seg)) == 3

    # scale multiplies the on-screen control-polygon length: 40·2/8 = 10 ⇒ 11
    assert len(sample_segment(*long_seg, scale=2.0)) == 11


def test_sample_segment_uniform_spacing_on_a_straight_cubic() -> None:
    # With evenly spaced control points the cubic reduces to B(t) = 40t, so
    # uniform-in-t sampling yields exactly uniform spacing (40/5 per step).
    seg = ((0.0, 0.0), (40.0 / 3.0, 0.0), (80.0 / 3.0, 0.0), (40.0, 0.0))
    samples = sample_segment(*seg)
    steps = [samples[i + 1][0] - samples[i][0] for i in range(len(samples) - 1)]
    assert steps == pytest.approx([steps[0]] * len(steps))


def test_sample_path_dedups_shared_segment_joints() -> None:
    pts = [(0.0, 0.0), (40.0, 0.0), (80.0, 0.0)]
    segments = spline_control_points(pts)
    raw_counts = [len(sample_segment(*seg)) for seg in segments]
    path = sample_path(pts)
    assert len(path) == sum(raw_counts) - (len(segments) - 1)
    assert path[0] == pytest.approx((0.0, 0.0))
    assert path[-1] == pytest.approx((80.0, 0.0))


# ---------------------------------------------------------------------------
# Always-run: vertex-count formula, bboxes, width profile (Doc 07 §6)
# ---------------------------------------------------------------------------


def test_vertex_count_formula_two_s_plus_twenty() -> None:
    # S = 1 ⇒ 22 verts; S = 50 ⇒ 120 verts (2·S strip + 20 cap verts)
    one_sample, _ = build_strip([(0.0, 0.0)], [1.0])
    assert len(one_sample) == 22
    fifty = [(float(i), 0.0) for i in range(50)]
    fifty_mesh, _ = build_strip(fifty, [1.0] * 50)
    assert len(fifty_mesh) == 120

    # End to end: single point degenerates to S = 1.
    single, _ = tessellate_stroke([(0.0, 0.0)], [1.0], 4.0)
    assert len(single) == 22

    # Two-point stroke: S equals the deduplicated sample path length.
    pts = [(0.0, 0.0), (40.0, 0.0)]
    expected_s = len(sample_path(pts))
    verts, _ = tessellate_stroke(pts, [1.0, 1.0], 4.0)
    assert len(verts) == 2 * expected_s + 20


def test_bbox_straight_stroke_is_exact() -> None:
    verts, bbox = build_strip([(0.0, 0.0), (50.0, 0.0), (100.0, 0.0)], [5.0, 5.0, 5.0])
    assert bbox == (-5.0, -5.0, 105.0, 5.0)
    assert len(verts) == 2 * 3 + CAP_VERTS

    # End to end: width 10 ⇒ hw 5 with constant pressure (wpf = 0).
    _, tess_bbox = tessellate_stroke([(0.0, 0.0), (100.0, 0.0)], [1.0, 1.0], 10.0, wpf=0.0)
    assert tess_bbox == (-5.0, -5.0, 105.0, 5.0)


def test_curved_bbox_contains_every_offset_vertex_and_pads_by_max_hw() -> None:
    pts = [(0.0, 0.0), (50.0, 40.0), (120.0, 10.0), (180.0, 60.0)]
    width = 8.0

    # Constant hw: bbox must equal the sample extent padded by exactly 0.5·width.
    samples = sample_path(pts)
    verts, bbox = tessellate_stroke(pts, [1.0] * len(pts), width, wpf=0.0)
    xs = [p[0] for p in samples]
    ys = [p[1] for p in samples]
    half = 0.5 * width
    assert bbox == pytest.approx((min(xs) - half, min(ys) - half, max(xs) + half, max(ys) + half))

    # Variable hw (wpf = 1): every strip/cap vertex must sit inside the bbox.
    verts_var, bbox_var = tessellate_stroke(pts, [1.0, 0.4, 0.7, 1.0], width, wpf=1.0)
    assert float(verts[:, 0].min()) >= bbox[0] - 1e-5
    assert float(verts[:, 1].min()) >= bbox[1] - 1e-5
    assert float(verts[:, 0].max()) <= bbox[2] + 1e-5
    assert float(verts[:, 1].max()) <= bbox[3] + 1e-5
    assert float(verts_var[:, 0].min()) >= bbox_var[0] - 1e-5
    assert float(verts_var[:, 1].max()) <= bbox_var[3] + 1e-5


def test_width_profile_endpoints_follow_lerp_rule() -> None:
    # hw = 0.5·width·lerp(1, p, wpf), clamped to ≥ 1e-4 (Doc 07 §4/§6)
    assert compute_half_widths([0.0, 1.0], 10.0, 0.0) == pytest.approx([5.0, 5.0])
    assert compute_half_widths([0.0, 1.0], 10.0, 1.0) == pytest.approx([1e-4, 5.0])
    assert compute_half_widths([1.0], 10.0, 1.0) == pytest.approx([5.0])

    pressure = [0.3, 0.9, 0.6]
    widths = compute_half_widths(pressure, 8.0, 0.5)
    assert widths[0] == pytest.approx(0.5 * 8.0 * (1.0 + (0.3 - 1.0) * 0.5))
    assert widths[-1] == pytest.approx(0.5 * 8.0 * (1.0 + (0.6 - 1.0) * 0.5))


def test_tessellate_rejects_empty_and_pads_short_pressure() -> None:
    with pytest.raises(ValueError):
        tessellate_stroke([], [], 2.0)

    verts, bbox = tessellate_stroke([(0.0, 0.0)], [], 4.0)
    assert len(verts) == 22
    assert bbox == (-2.0, -2.0, 2.0, 2.0)

    # A short pressure list pads with 1.0 ⇒ the far endpoint keeps the full hw.
    pts = [(0.0, 0.0), (100.0, 0.0)]
    verts_padded, _ = tessellate_stroke(pts, [1.0], 10.0, wpf=1.0)
    samples = len(sample_path(pts))
    end_rim_z = float(verts_padded[2 * samples + CAP_VERTS - 1, 2])
    assert end_rim_z == pytest.approx(5.0), "padding must give the last point full pressure"


# ---------------------------------------------------------------------------
# Always-run: shader source contracts (Doc 07 §6)
# ---------------------------------------------------------------------------


def test_shader_source_contract() -> None:
    vert = (SHADER_DIR / "stroke.vert").read_text(encoding="utf-8")
    frag = (SHADER_DIR / "stroke.frag").read_text(encoding="utf-8")
    geom = (SHADER_DIR / "stroke.geom").read_text(encoding="utf-8")

    # Fragment: fwidth AA, blend-mode branch, and the §3 multiply reference.
    assert "fwidth" in frag
    assert "smoothstep" in frag
    assert "u_blendMode" in frag
    assert "GL_DST_COLOR, GL_ZERO" in frag

    # Geometry: minimal pass-through, no emission API (Doc 07 §4 decision).
    assert "EmitVertex" not in geom
    assert "EndPrimitive" not in geom

    # Vertex: template §3 camera transform and viewport uniforms.
    assert "u_camera" in vert
    assert "u_viewport" in vert
    assert "(world - u_camera.yz) * u_camera.x + u_viewport * 0.5" in vert
    assert "screen / u_viewport * 2.0 - 1.0" in vert

    # Varyings pair up between stages; every stage targets GL 3.3 core.
    assert "out float v_dist" in vert and "in float v_dist" in frag
    assert "out float v_half" in vert and "in float v_half" in frag
    for name in ("stroke.vert", "stroke.geom", "stroke.frag"):
        source = (SHADER_DIR / name).read_text(encoding="utf-8")
        assert "#version 330 core" in source


# ---------------------------------------------------------------------------
# GL-guarded: VAO upload / dynamic rewrite (Doc 07 §6)
# ---------------------------------------------------------------------------


def _registry() -> ProgramRegistry:
    registry = ProgramRegistry(AppConfig(shader_dir=SHADER_DIR))
    registry.set_ctx(_GL_CTX)
    return registry


@requires_gl
def test_build_stroke_uploads_static_vao_and_draws_clean() -> None:
    import moderngl

    registry = _registry()
    program = registry.get("stroke")
    tessellator = StrokeTessellator(_GL_CTX)
    tessellator.program = program

    points = [(0.0, 0.0), (100.0, 0.0)]
    mesh = tessellator.build_stroke(points, [1.0, 1.0], 10.0)
    assert isinstance(mesh, TessellatedMesh)
    expected_s = len(sample_path(points))
    assert mesh.vertex_count == 2 * expected_s + 20
    assert mesh.bbox == pytest.approx((-5.0, -5.0, 105.0, 5.0))

    # Draw strip + both cap fans exactly like Doc 06's renderer does.
    _GL_CTX.viewport = (0, 0, 64, 64)
    _GL_CTX.enable(moderngl.BLEND)
    _GL_CTX.blend_func = moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA
    program["u_camera"].value = (1.0, 50.0, 0.0)
    program["u_viewport"].value = (64.0, 64.0)
    program["u_color"].value = (0.0, 0.0, 0.0)
    program["u_opacity"].value = 1.0
    program["u_blendMode"].value = 0
    strip = mesh.vertex_count - CAP_VERTS
    mesh.vao.render(moderngl.TRIANGLE_STRIP, vertices=strip, first=0)
    mesh.vao.render(moderngl.TRIANGLE_FAN, vertices=CAP_VERTS // 2, first=strip)
    mesh.vao.render(
        moderngl.TRIANGLE_FAN, vertices=CAP_VERTS // 2, first=strip + CAP_VERTS // 2
    )
    assert _GL_CTX.error == "GL_NO_ERROR"
    assert registry.get("stroke") is program  # cache hit


@requires_gl
def test_live_append_rewrites_dynamic_vao_and_hides_after_end() -> None:
    registry = _registry()
    tessellator = StrokeTessellator(_GL_CTX)
    tessellator.program = registry.get("stroke")

    assert tessellator.live_mesh is None
    tessellator.begin_live()
    first = tessellator.append_live([(0.0, 0.0), (40.0, 0.0)], [1.0, 1.0], 4.0)
    assert first is not None and tessellator.live_mesh is first
    assert first.vertex_count == 2 * len(sample_path([(0.0, 0.0), (40.0, 0.0)])) + 20

    # Growth rewrites the dynamic buffer (orphan / rebuild) without GL errors.
    longer = [(float(i) * 10.0, 0.0) for i in range(9)]
    second = tessellator.append_live(longer, [1.0] * len(longer), 4.0)
    assert second.vertex_count > first.vertex_count
    assert _GL_CTX.error == "GL_NO_ERROR"

    tessellator.end_live()
    assert tessellator.live_mesh is None, "finished strokes must stop rendering"


@requires_gl
def test_build_without_program_raises_clear_runtime_error() -> None:
    bare = StrokeTessellator(_GL_CTX)
    with pytest.raises(RuntimeError, match="ProgramRegistry"):
        bare.build_stroke([(0.0, 0.0), (1.0, 0.0)], [1.0, 1.0], 1.0)


def test_numpy_import_is_usable_headless() -> None:
    # Guardrail for the CPU pipeline: pure-math tests must not require GL.
    values = np.asarray([1.0, 2.0], dtype=np.float64)
    assert float(values.sum()) == pytest.approx(3.0)
