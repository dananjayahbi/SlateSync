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
    flatten_stroke_path,
    is_cubic_chain,
    sample_cubic_chain,
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
# Always-run: Doc 21 chain layout detection + exact-chain flattening
# (issue 05 round 5 — committed nodes must never re-fit chains as anchors)
# ---------------------------------------------------------------------------


def _chain_of(anchors: list[tuple[float, float]]) -> list[list[float]]:
    """Doc 21 §4 chain from anchors: ``[P0, c1, c2, P1, …]`` (τ = 0.5)."""
    out = [[float(anchors[0][0]), float(anchors[0][1])]]
    n = len(anchors)
    for i in range(n - 1):
        p1, p2 = anchors[i], anchors[i + 1]
        p0 = anchors[i - 1] if i > 0 else p1
        p3 = anchors[i + 2] if i + 2 < n else p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6.0, p1[1] + (p2[1] - p0[1]) / 6.0)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6.0, p2[1] - (p3[1] - p1[1]) / 6.0)
        out.extend(([c1[0], c1[1]], [c2[0], c2[1]], [float(p2[0]), float(p2[1])]))
    return out


@pytest.mark.parametrize(
    ("point_count", "expect_chain"),
    [(2, False), (3, False), (4, True), (5, True), (6, False),
     (7, True), (8, True), (9, False), (10, True)],
)
def test_is_cubic_chain_matches_frozen_doc21_contract(
    point_count: int, expect_chain: bool
) -> None:
    pts = [(float(i), 0.0) for i in range(point_count)]
    assert is_cubic_chain(pts) is expect_chain


def test_sample_cubic_chain_walks_exact_cubics_and_dedups_joints() -> None:
    # Straight chain: control points sit ON the chord ⇒ every sample collinear.
    chain = _chain_of([(0.0, 0.0), (90.0, 0.0), (180.0, 0.0)])
    assert is_cubic_chain(chain) and len(chain) == 7  # 3k − 2
    samples = sample_cubic_chain(chain, step_px=4.0, scale=1.0)
    assert samples[0] == pytest.approx((0.0, 0.0))
    assert samples[-1] == pytest.approx((180.0, 0.0))
    for x, y in samples:
        assert y == pytest.approx(0.0, abs=1e-6)
        assert -1e-6 <= x <= 180.0 + 1e-6
    # joint-dedup: strictly increasing x on the straight line (no repeats)
    xs = [p[0] for p in samples]
    assert all(b > a for a, b in zip(xs, xs[1:]))
    # the anchor vertices themselves must be interpolated exactly
    for anchor in ((0.0, 0.0), (90.0, 0.0), (180.0, 0.0)):
        assert any(
            p[0] == pytest.approx(anchor[0]) and p[1] == pytest.approx(anchor[1])
            for p in samples
        ), f"anchor {anchor} missing from chain samples"


def test_flatten_stroke_path_identity_for_non_chain_layouts() -> None:
    # n ≤ 3 and n ≡ 0 (mod 3) polylines are anchors — returned unchanged.
    for pts in ([(0.0, 0.0), (40.0, 0.0)],
                [(0.0, 0.0), (40.0, 0.0), (80.0, 0.0)],
                [(0.0, 0.0), (10.0, 0.0), (20.0, 0.0), (30.0, 0.0),
                 (40.0, 0.0), (50.0, 0.0)]):
        flat = flatten_stroke_path(pts, step_px=4.0, scale=1.0)
        assert flat == [(float(x), float(y)) for x, y in pts]


def test_flatten_stroke_path_chain_stays_inside_control_hull() -> None:
    anchors = [(0.0, 0.0), (160.0, 60.0), (320.0, -40.0), (480.0, 80.0)]
    chain = _chain_of(anchors)
    flat = flatten_stroke_path(chain, step_px=4.0, scale=1.0)
    # densified, endpoints preserved, anchors interpolated
    assert len(flat) > len(chain)
    assert flat[0] == pytest.approx(anchors[0])
    assert flat[-1] == pytest.approx(anchors[-1])
    for ax, ay in anchors:
        assert any(
            abs(x - ax) < 1e-6 and abs(y - ay) < 1e-6 for x, y in flat
        ), f"anchor {(ax, ay)} not interpolated"
    # exact cubic sampling NEVER leaves the control hull (the whole point —
    # re-fitting controls as Catmull-Rom anchors overshoots by tens of units)
    xs = [p[0] for p in chain]
    ys = [p[1] for p in chain]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    for x, y in flat:
        assert x0 - 1e-6 <= x <= x1 + 1e-6
        assert y0 - 1e-6 <= y <= y1 + 1e-6
    # control-hull bbox is strictly larger than the anchor bbox here ⇒ the
    # chain-vs-anchor ambiguity is real, and sampling stays on the true path
    ax0 = min(a[0] for a in anchors)
    assert x0 <= ax0


def test_flatten_stroke_path_appends_trailing_point_layout() -> None:
    # Frozen n ≡ 2 (mod 3) contract: chain + one trailing anchor point.
    chain = _chain_of([(0.0, 0.0), (90.0, 0.0)]) + [[200.0, 5.0]]
    assert len(chain) == 5 and is_cubic_chain(chain)
    flat = flatten_stroke_path(chain, step_px=4.0, scale=1.0)
    assert flat[0] == pytest.approx((0.0, 0.0))
    assert flat[-1] == pytest.approx((200.0, 5.0))


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
