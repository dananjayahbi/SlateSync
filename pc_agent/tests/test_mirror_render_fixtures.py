"""Issue 05 (round 5) — offscreen mirror-rendering fixtures A/B/C/D + camera sanity.

No window is needed: a standalone GL 3.3 context drives the REAL ``GLCanvasHost``
pipeline headless (``set_document`` → ``_sync_pending`` → ``_render`` → offscreen
FBO readback), so these tests exercise exactly the code the mirror presents.

Fixture A (band hunt): A4 doc, strokes ONLY inside the page — columns well
    outside the page must be pixel-uniform; parametrised over render phases
    (background / background+shadow / full) so a RED result names the phase.
Fixture B (tangle hunt): strokes far OUTSIDE the page (negative and >1024
    world coords, Doc 21 Bézier chains) — ink appears ONLY inside each node's
    expected screen bbox (±2 px), zero ink anywhere else.
Fixture C: same doc as B — analytic chain geometry (Doc 03 bbox + §3 transform)
    defines the tight expected positions; ink must sit there (±2 px).
Fixture D: an in-page handwriting chain must render CONTINUOUS coverage along
    the path samples (no dashes, full-width committed strokes).
Camera sanity: page-boundary pixels land where the §3 transform predicts.
"""

from __future__ import annotations

import gc
import math

import numpy as np
import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import EventBus
from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.viewport.gl_canvas_host import GLCanvasHost, _parse_color
from pc_agent.viewport.primitive_renderer import (
    clamp_zoom,
    visible_world_rect,
    world_to_screen,
)


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

# --- document / camera constants (Doc 03 world units, §3 transform) --------
A4_W, A4_H = 2480.0, 3508.0
#: shadow quad reach beyond the page edge = offset + feather = 0.02·min · (1 + 3).
SHADOW_REACH_WORLD = 4.0 * 0.02 * A4_W  # 198.4 world units
INK_MAX = 60  # channel ceiling for stroke ink (#000000); chrome stays ≥ 130

#: Fixture A rig: page centred with wide L/R margins for uniformity columns.
VP_A = (800, 600)
SCALE_A, CAM_TX, CAM_TY = 0.16, 1240.0, 1754.0  # page centre
#: Fixtures B/C/D rig: bigger viewport, coarser zoom, 300 px side margins.
VP_B = (1600, 900)
SCALE_B = 0.4


class _FakeTk:
    """Records ``after``/``after_cancel``; callbacks are never fired headless."""

    def __init__(self) -> None:
        self._next = 0

    def after(self, ms: int, callback) -> str:
        self._next += 1
        return f"after#{self._next}"

    def after_cancel(self, after_id: str) -> None:
        return None


# ---------------------------------------------------------------------------
# Offscreen harness — the real host pipeline without a window
# ---------------------------------------------------------------------------


def _make_host(viewport: tuple[int, int]) -> GLCanvasHost:
    """Attach a fresh GLCanvasHost to the probe context, FBO targets and all."""
    assert _GL_CTX is not None
    host = GLCanvasHost(_FakeTk(), AppConfig(), EventBus())
    host._ctx = _GL_CTX
    host._init_gl_surface()
    host._vp_w, host._vp_h = viewport
    host._mode = "fallback"
    host._init_fallback_targets()
    host._mounted = True
    assert _GL_CTX.error == "GL_NO_ERROR"
    return host


def _render_full(host: GLCanvasHost) -> None:
    """Production frame: GLCanvasHost._render (sync + all phases + strokes)."""
    host._render()


def _render_phases(
    host: GLCanvasHost, *, background: bool, shadow: bool, strokes: bool
) -> None:
    """Mirror of ``GLCanvasHost._render`` with per-phase switches (Fixture A bisect)."""
    import moderngl

    assert host._ctx is not None and host._fbo is not None
    width, height = host._vp_w, host._vp_h
    host._fbo.use()
    host._sync_pending()
    host._ctx.viewport = (0, 0, width, height)
    host._ctx.enable(moderngl.BLEND)
    clear = _parse_color(host._background_color(), 1.0)
    host._ctx.clear(clear[0], clear[1], clear[2], 1.0)
    prim = host._primitive
    if prim is not None and host._doc is not None and host._artboard is not None:
        cam = (
            clamp_zoom(host._camera[0]),
            float(host._camera[1]),
            float(host._camera[2]),
        )
        world_rect = visible_world_rect(cam, (width, height))
        if background:
            prim._draw_background(host._artboard, cam, width, height)
        if prim.scissor_enabled:  # production disables before phase 2
            host._ctx.disable_direct(0x0C11)  # GL_SCISSOR_TEST
        if shadow:
            prim._draw_shadow_boundary(host._artboard, cam, width, height, world_rect)
        prim._restore_state()
    if strokes:
        for mesh, color, blend in list(host._committed.values()):
            host._draw_mesh(mesh, color, blend)


def _read_scene_top(host: GLCanvasHost) -> np.ndarray:
    """Scene FBO as ``(H, W, 3)`` uint8, row 0 = visual top (screen coords)."""
    fbo = host._fbo
    assert fbo is not None
    width, height = fbo.size
    data = fbo.read(components=3, alignment=1)
    return np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3)[::-1].copy()


def _flip_present(host: GLCanvasHost) -> np.ndarray:
    """Run the blit pipeline's GPU present-flip; returns top-first pixels."""
    import moderngl

    assert host._ctx is not None
    assert host._flip_fbo is not None and host._flip_vao is not None
    host._flip_fbo.use()
    host._fbo_texture.use(0)
    host._ctx.disable(moderngl.BLEND)
    host._flip_vao.render(moderngl.TRIANGLES, vertices=3)
    width, height = host._flip_fbo.size
    data = host._flip_fbo.read(components=3, alignment=1)
    return np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3).copy()


def _shutdown(host: GLCanvasHost) -> None:
    try:
        host.shutdown()
    except Exception:  # pragma: no cover - defensive cleanup
        pass
    gc.collect()


# ---------------------------------------------------------------------------
# Doc builders — Doc 21 chain layout, Doc 03 bbox rule
# ---------------------------------------------------------------------------


def _to_chain(anchors: list[tuple[float, float]]) -> list[list[float]]:
    """Doc 21 §4 Catmull-Rom (τ = 0.5) → cubic chain ``[P0, c1, c2, P1, …]``."""
    if len(anchors) < 2:
        return [[float(x), float(y)] for x, y in anchors]
    out: list[list[float]] = [[float(anchors[0][0]), float(anchors[0][1])]]
    count = len(anchors)
    for i in range(count - 1):
        p1, p2 = anchors[i], anchors[i + 1]
        p0 = anchors[i - 1] if i > 0 else p1
        p3 = anchors[i + 2] if i + 2 < count else p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6.0, p1[1] + (p2[1] - p0[1]) / 6.0)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6.0, p2[1] - (p3[1] - p1[1]) / 6.0)
        out.extend(([c1[0], c1[1]], [c2[0], c2[1]], [float(p2[0]), float(p2[1])]))
    return out


def _squiggle(
    x0: float, x1: float, y0: float, amp: float, segments: int, phase: float = 0.0
) -> list[tuple[float, float]]:
    """Sparse handwriting-like anchors spanning ``x0…x1`` around ``y0``."""
    pts: list[tuple[float, float]] = []
    for i in range(segments + 1):
        t = i / segments
        x = x0 + (x1 - x0) * t
        y = y0 + amp * math.sin(phase + t * math.pi * 2.6) + amp * 0.35 * math.sin(
            phase * 1.7 + t * math.pi * 7.0
        )
        pts.append((x, y))
    return pts


def _stroke_node(
    node_id: str,
    anchors: list[tuple[float, float]],
    *,
    width: float = 25.0,
    kind: str = "STROKE",
) -> CanvasNode:
    """Committed stroke node with Doc 21 chain ``pts`` + Doc 03 bbox (min/max pts)."""
    chain = _to_chain(anchors)
    xs = [p[0] for p in chain]
    ys = [p[1] for p in chain]
    return CanvasNode(
        node_id=node_id,
        kind=kind,
        layer=0,
        bbox=(min(xs), min(ys), max(xs), max(ys)),
        style=NodeStyle(color="#000000", stroke_width=width, opacity=1.0),
        geometry=NodeGeometry(pts=chain),
    )


def _a4_doc(elements: list[CanvasNode]) -> CanvasDocument:
    bounds = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
    if elements:
        bounds = {
            "min_x": min(e.bbox[0] for e in elements),
            "min_y": min(e.bbox[1] for e in elements),
            "max_x": max(e.bbox[2] for e in elements),
            "max_y": max(e.bbox[3] for e in elements),
        }
    return CanvasDocument(
        canvas_id="mirror-fixtures",
        title="Issue 05 round 5",
        created_at=0,
        updated_at=0,
        artboard=Artboard(
            preset="A4",
            width=A4_W,
            height=A4_H,
            is_infinite=False,
            background_style="RULED",
            background_color="#FFFFFF",
        ),
        content_bounds=bounds,
        elements=elements,
    )


def _in_page_strokes() -> list[CanvasNode]:
    """Fixture A content: chains WELL inside the A4 page."""
    return [
        _stroke_node(
            "in-1", _squiggle(600.0, 1900.0, 900.0, 160.0, 8), width=30.0
        ),
        _stroke_node(
            "in-2", _squiggle(500.0, 1800.0, 1900.0, 200.0, 9, phase=1.3), width=30.0
        ),
        _stroke_node(
            "in-3", _squiggle(700.0, 2000.0, 2800.0, 140.0, 7, phase=2.4), width=30.0
        ),
    ]


def _outside_strokes() -> list[CanvasNode]:
    """Fixture B/C content: leftover chains OUTSIDE the page (neg & >1024 world).

    Sparse anchors (heavily decimated old content) — the layout where
    chain-vs-anchor confusion historically wandered the most.
    """
    return [
        # visible, left of the page (negative world x)
        _stroke_node("out-left", _squiggle(-600.0, -250.0, 1200.0, 220.0, 4)),
        # visible, right of the page (> 1024 world x)
        _stroke_node("out-right", _squiggle(2700.0, 3150.0, 1400.0, 260.0, 4, phase=0.7)),
        # fully off-screen, far negative
        _stroke_node("far-neg", _squiggle(-4000.0, -3500.0, 1200.0, 200.0, 3, phase=2.0)),
        # fully off-screen, far positive (> 1024)
        _stroke_node("far-pos", _squiggle(5000.0, 5500.0, 1400.0, 200.0, 3, phase=1.1)),
        # fully off-screen, negative corner (negative x AND y)
        _stroke_node("neg-corner", _squiggle(-500.0, -200.0, -300.0, -100.0, 3, phase=0.4)),
    ]


# ---------------------------------------------------------------------------
# Geometry helpers (Doc 03 bbox, §3 transform, Doc 21 chain evaluation)
# ---------------------------------------------------------------------------


def _chain_samples(chain: list[list[float]], step_world: float = 2.0) -> np.ndarray:
    """Dense samples of the exact cubic chain (ground truth path)."""
    from pc_agent.viewport.stroke_tessellator import sample_segment

    out = [tuple(chain[0])]
    i = 1
    while i + 2 < len(chain):
        c0 = out[-1]
        c1 = tuple(chain[i])
        c2 = tuple(chain[i + 1])
        c3 = tuple(chain[i + 2])
        out.extend(sample_segment(c0, c1, c2, c3, step_px=step_world, scale=1.0)[1:])
        i += 3
    if i < len(chain):  # trailing point (frozen Doc 21 n ≡ 2 layout)
        out.append(tuple(chain[i]))
    return np.asarray(out, dtype=float)


def _screen_box(
    world_box: tuple[float, float, float, float],
    camera: tuple[float, float, float],
    viewport: tuple[int, int],
    pad_px: float,
) -> tuple[int, int, int, int]:
    """World bbox → inclusive screen pixel box, padded by ``pad_px``."""
    x0, y0 = world_to_screen((world_box[0], world_box[1]), camera, viewport)
    x1, y1 = world_to_screen((world_box[2], world_box[3]), camera, viewport)
    return (
        int(math.floor(min(x0, x1) - pad_px)),
        int(math.floor(min(y0, y1) - pad_px)),
        int(math.ceil(max(x0, x1) + pad_px)),
        int(math.ceil(max(y0, y1) + pad_px)),
    )


def _clip_box(
    box: tuple[int, int, int, int], width: int, height: int
) -> tuple[int, int, int, int] | None:
    x0, y0, x1, y1 = box
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(width, x1), min(height, y1)
    if x1 <= x0 or y1 <= y0:
        return None
    return (x0, y0, x1, y1)


def _ink(img: np.ndarray) -> np.ndarray:
    return np.max(img, axis=2) < INK_MAX


def _outside_columns(
    camera: tuple[float, float, float], viewport: tuple[int, int]
) -> tuple[range, range]:
    """Columns strictly beyond the page edge plus the shadow reach."""
    reach = SHADOW_REACH_WORLD * camera[0] + 8.0
    left_edge = world_to_screen((0.0, 0.0), camera, viewport)[0]
    right_edge = world_to_screen((A4_W, 0.0), camera, viewport)[0]
    return (
        range(4, max(5, int(left_edge - reach))),
        range(min(viewport[0] - 4, int(right_edge + reach) + 1), viewport[0] - 3),
    )


def _column_report(img: np.ndarray, cols: range) -> dict[str, float]:
    region = img[:, list(cols), :].astype(np.int32)
    luminance = region.mean(axis=2)  # (rows, cols)
    per_column_range = luminance.max(axis=0) - luminance.min(axis=0)
    means = luminance.mean(axis=0)
    return {
        "range": float(per_column_range.max()),
        "spread": float(means.max() - means.min()),
        "mean": float(means.mean()),
    }


def _ascii_map(img: np.ndarray, cols: int = 100, rows: int = 32) -> str:
    """Coarse luminance map for console diagnosis (``pytest -s``)."""
    height, width = img.shape[:2]
    chars = " .:-=+*#%@"
    lines = []
    for r in range(rows):
        y0, y1 = r * height // rows, max(r * height // rows + 1, (r + 1) * height // rows)
        line = []
        for c in range(cols):
            x0, x1 = c * width // cols, max(c * width // cols + 1, (c + 1) * width // cols)
            value = float(img[y0:y1, x0:x1].mean())
            line.append(chars[min(len(chars) - 1, int(value / 256.0 * len(chars)))])
        lines.append("".join(line))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Fixture A — band hunt (+ phase bisect, blit-flip stride)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("phase", ["background", "background+shadow", "full"])
@requires_gl
def test_fixture_a_outside_page_columns_stay_uniform(phase: str) -> None:
    """In-page strokes only: columns outside the page must be renderer-clean.

    Any non-uniformity outside the page is renderer garbage, never content —
    the failing ``phase`` names the responsible render phase.
    """
    host = _make_host(VP_A)
    try:
        camera = (SCALE_A, CAM_TX, CAM_TY)
        host.set_document(_a4_doc(_in_page_strokes()))
        host.set_camera(*camera)
        if phase == "full":
            _render_full(host)
        else:
            _render_phases(
                host,
                background=True,
                shadow=(phase == "background+shadow"),
                strokes=False,
            )
        assert host._ctx.error == "GL_NO_ERROR"
        img = _read_scene_top(host)
        print(f"\n--- Fixture A [{phase}] ---\n{_ascii_map(img)}")
        left_cols, right_cols = _outside_columns(camera, VP_A)
        assert len(left_cols) > 40 and len(right_cols) > 40, "fixture rig lost its margins"
        for name, cols in (("left", left_cols), ("right", right_cols)):
            report = _column_report(img, cols)
            assert report["range"] <= 2.0, (
                f"[{phase}] {name} columns vary within a column by "
                f"{report['range']:.1f} (vertical banding/streaks)"
            )
            assert report["spread"] <= 2.0, (
                f"[{phase}] {name} column means spread {report['spread']:.1f} "
                f"(band-to-band brightness streaks)"
            )
            assert report["mean"] >= 250.0, (
                f"[{phase}] {name} region mean {report['mean']:.1f} — darkened "
                "outside-page background"
            )
        # The legit shadow feather ring (inside the reach) must be a SMOOTH
        # vertical band: constant down every column across the page's rows.
        reach_px = SHADOW_REACH_WORLD * SCALE_A
        page_top = world_to_screen((0.0, 0.0), camera, VP_A)[1]
        page_bottom = world_to_screen((0.0, A4_H), camera, VP_A)[1]
        rows = slice(int(page_top + reach_px + 10), int(page_bottom - reach_px - 10))
        left_edge = world_to_screen((0.0, 0.0), camera, VP_A)[0]
        right_edge = world_to_screen((A4_W, 0.0), camera, VP_A)[0]
        for name, centre in (("left", left_edge - reach_px * 0.5),
                             ("right", right_edge + reach_px * 0.5)):
            cols = range(int(centre) - 3, int(centre) + 4)
            band = img[rows, list(cols), :].astype(np.int32).mean(axis=2)
            col_range = (
                float((band.max(axis=0) - band.min(axis=0)).max()) if len(cols) else 9e9
            )
            assert col_range <= 2.0, (
                f"[{phase}] {name} shadow-ring column streaked by {col_range:.1f}"
            )
    finally:
        _shutdown(host)


@requires_gl
def test_fixture_a_leftover_outside_strokes_confined_to_their_geometry() -> None:
    """The band theory in one test: leftover out-of-page strokes (Doc 21 chains)
    must render ONLY where their geometry says — ink escapes ⇒ mangling, and
    every margin column not intersecting a node box stays uniform (no bands).
    """
    host = _make_host(VP_A)
    try:
        camera = (SCALE_A, CAM_TX, CAM_TY)
        host.set_document(_a4_doc(_outside_strokes()))
        host.set_camera(*camera)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        img = _read_scene_top(host)
        print(f"\n--- Fixture A[leftover] ---\n{_ascii_map(img)}")
        width, height = img.shape[1], img.shape[0]
        ink = _ink(img)
        union = np.zeros_like(ink)
        box_ranges: list[tuple[int, int]] = []
        for node in host._doc.elements:
            samples = _chain_samples(node.geometry.pts, step_world=2.0)
            world_box = (
                float(samples[:, 0].min()),
                float(samples[:, 1].min()),
                float(samples[:, 0].max()),
                float(samples[:, 1].max()),
            )
            half_px = 0.5 * node.style.stroke_width * camera[0]
            clipped = _clip_box(
                _screen_box(world_box, camera, VP_A, pad_px=half_px + 2.0),
                width,
                height,
            )
            if clipped is None:
                continue
            x0, y0, x1, y1 = clipped
            union[y0:y1, x0:x1] = True
            box_ranges.append((x0, x1))
        escape = int((ink & ~union).sum())
        assert escape == 0, (
            f"{escape} ink px outside every leftover stroke's analytic box — "
            "smeared band garbage outside the geometry"
        )
        left_cols, right_cols = _outside_columns(camera, VP_A)
        for name, cols in (("left", left_cols), ("right", right_cols)):
            for col in cols:
                if any(x0 - 1 <= col <= x1 for x0, x1 in box_ranges):
                    continue  # column legitimately crossed by a leftover stroke
                column = img[:, col, :].astype(np.int32).mean(axis=1)
                column_range = float(column.max() - column.min())
                assert column_range <= 2.0, (
                    f"[leftover] {name} margin column {col} varies by "
                    f"{column_range:.1f} (vertical band outside any stroke box)"
                )
    finally:
        _shutdown(host)


@requires_gl
def test_fixture_a_present_flip_keeps_outside_uniform_and_aligned() -> None:
    """Blit-pipeline GPU flip: same uniformity + exact scene correspondence."""
    host = _make_host(VP_A)
    try:
        camera = (SCALE_A, CAM_TX, CAM_TY)
        host.set_document(_a4_doc(_in_page_strokes()))
        host.set_camera(*camera)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        scene = _read_scene_top(host)
        flipped = _flip_present(host)
        assert host._ctx.error == "GL_NO_ERROR"
        left_cols, right_cols = _outside_columns(camera, VP_A)
        for name, cols in (("left", left_cols), ("right", right_cols)):
            report = _column_report(flipped, cols)
            assert report["range"] <= 2.0, f"flip {name}: row range {report['range']:.1f}"
            assert report["spread"] <= 2.0, f"flip {name}: band spread {report['spread']:.1f}"
        # exact top-first correspondence (NEAREST, no scaling)
        assert np.array_equal(flipped, scene), "present flip must not shift/duplicate rows"
    finally:
        _shutdown(host)


# ---------------------------------------------------------------------------
# Fixture B — tangle hunt (ink containment per node, zero ink elsewhere)
# ---------------------------------------------------------------------------


def _run_outside_doc() -> tuple[GLCanvasHost, np.ndarray, tuple[float, float, float]]:
    host = _make_host(VP_B)
    camera = (SCALE_B, CAM_TX, CAM_TY)
    host.set_document(_a4_doc(_outside_strokes()))
    host.set_camera(*camera)
    _render_full(host)
    assert host._ctx.error == "GL_NO_ERROR"
    img = _read_scene_top(host)
    return host, img, camera


@requires_gl
def test_fixture_b_ink_only_inside_each_node_bbox() -> None:
    """Cross-stroke bridges / misplacement / wild overshoot ⇒ ink escapes bboxes."""
    host, img, camera = _run_outside_doc()
    try:
        print(f"\n--- Fixture B ---\n{_ascii_map(img)}")
        width, height = img.shape[1], img.shape[0]
        ink = _ink(img)
        allowed = np.zeros_like(ink)
        per_node: dict[str, tuple[tuple[int, int, int, int], int]] = {}
        for node in host._doc.elements:
            pts = node.geometry.pts
            world_box = (
                min(p[0] for p in pts),
                min(p[1] for p in pts),
                max(p[0] for p in pts),
                max(p[1] for p in pts),
            )
            half_px = 0.5 * node.style.stroke_width * camera[0]
            box = _screen_box(world_box, camera, VP_B, pad_px=half_px + 2.0)
            clipped = _clip_box(box, width, height)
            count = 0
            if clipped is not None:
                x0, y0, x1, y1 = clipped
                allowed[y0:y1, x0:x1] = True
                count = int(ink[y0:y1, x0:x1].sum())
            per_node[node.node_id] = (box, count)
        escape = ink & ~allowed
        escape_count = int(escape.sum())
        if escape_count:
            ys, xs = np.nonzero(escape)
            samples = [(int(xs[i]), int(ys[i])) for i in range(0, len(xs), max(1, len(xs) // 5))]
            raise AssertionError(
                f"{escape_count} ink px outside every node bbox (cross-stroke "
                f"bridges / misfit / misplacement) at (x, y): {samples}"
            )
        for node_id, (box, count) in per_node.items():
            if _clip_box(box, width, height) is None:
                assert count == 0, f"{node_id} off-screen yet produced {count} ink px"
            else:
                assert count >= 30, (
                    f"{node_id} expected inside screen box {box} but only {count} "
                    "ink px rendered (missing or misplaced stroke)"
                )
    finally:
        _shutdown(host)


# ---------------------------------------------------------------------------
# Fixture C — analytic chain geometry defines the expected screen positions
# ---------------------------------------------------------------------------


@requires_gl
def test_fixture_c_positions_match_analytic_chain_geometry() -> None:
    """Same doc as B: ink must sit where Doc 03 bbox + §3 transform predict.

    The analytic path bbox (exact cubics, not the control-point hull) is the
    tight ground truth — re-fitting chains as Catmull-Rom anchors pushes ink
    outside it.
    """
    host, img, camera = _run_outside_doc()
    try:
        width, height = img.shape[1], img.shape[0]
        ink = _ink(img)
        boxes: dict[str, tuple[tuple[int, int, int, int] | None, int]] = {}
        union = np.zeros_like(ink)
        for node in host._doc.elements:
            samples = _chain_samples(node.geometry.pts, step_world=2.0)
            world_box = (
                float(samples[:, 0].min()),
                float(samples[:, 1].min()),
                float(samples[:, 0].max()),
                float(samples[:, 1].max()),
            )
            half_px = 0.5 * node.style.stroke_width * camera[0]
            box = _screen_box(world_box, camera, VP_B, pad_px=half_px + 2.0)
            clipped = _clip_box(box, width, height)
            if clipped is not None:
                x0, y0, x1, y1 = clipped
                union[y0:y1, x0:x1] = True
            boxes[node.node_id] = (clipped, 0)
        escape = int((ink & ~union).sum())
        assert escape == 0, (
            f"{escape} ink px outside every analytic path box "
            "(chain re-fit / overshoot / misplacement)"
        )
        for node in host._doc.elements:
            clipped, _ = boxes[node.node_id]
            if clipped is None:
                continue  # off-screen node: no ink required (covered by B)
            x0, y0, x1, y1 = clipped
            count = int(ink[y0:y1, x0:x1].sum())
            boxes[node.node_id] = (clipped, count)
            assert count >= 30, (
                f"{node.node_id}: analytic screen box {(x0, y0, x1, y1)} holds only "
                f"{count} ink px — stroke not where the geometry math says it must be"
            )
    finally:
        _shutdown(host)


# ---------------------------------------------------------------------------
# Fixture D — in-page handwriting chain renders continuous (no dashes)
# ---------------------------------------------------------------------------


@requires_gl
def test_fixture_d_in_page_chain_renders_continuous_coverage() -> None:
    """Every sample of an in-page chain must hit ink — no dashes, full width."""
    host = _make_host(VP_B)
    try:
        camera = (SCALE_B, CAM_TX, CAM_TY)
        node = _stroke_node(
            "handwriting", _squiggle(400.0, 2100.0, 1400.0, 420.0, 12), width=25.0
        )
        host.set_document(_a4_doc([node]))
        host.set_camera(*camera)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        img = _read_scene_top(host)
        ink = _ink(img)
        samples = _chain_samples(node.geometry.pts, step_world=4.0)
        misses: list[tuple[int, int]] = []
        for wx, wy in samples:
            sx, sy = world_to_screen((float(wx), float(wy)), camera, VP_B)
            xi, yi = int(round(sx)), int(round(sy))
            window = ink[max(0, yi - 1) : yi + 2, max(0, xi - 1) : xi + 2]
            if not window.any():
                misses.append((xi, yi))
        coverage = 1.0 - len(misses) / max(1, len(samples))
        assert coverage >= 0.995, (
            f"chain coverage {coverage:.3%} — {len(misses)}/{len(samples)} path "
            f"samples have no ink (dashes / zero width / broken strip); first "
            f"misses: {misses[:8]}"
        )
        # committed strokes must render at the full style.stroke_width: the ink
        # area can't fall far below path_length × width (catches stale/zero
        # width_pressure_factor feeding near-zero strip half-widths).
        screen = np.array(
            [world_to_screen((float(wx), float(wy)), camera, VP_B) for wx, wy in samples]
        )
        path_px = float(
            np.hypot(np.diff(screen[:, 0]), np.diff(screen[:, 1])).sum()
        )
        width_px = node.style.stroke_width * camera[0]
        total_ink = int(ink.sum())
        assert total_ink >= 0.5 * path_px * width_px, (
            f"stroke ink {total_ink} px below 50% of the theoretical "
            f"{0.5 * path_px * width_px:.0f} px (path {path_px:.0f} px × width "
            f"{width_px:.1f} px) — committed width collapsed"
        )
    finally:
        _shutdown(host)


# ---------------------------------------------------------------------------
# Camera sanity — page boundary pixels where §3 says they are
# ---------------------------------------------------------------------------


def _is_borderish(rgb: np.ndarray) -> bool:
    r, g, b = (int(v) for v in rgb)
    return 120 <= r <= 235 and abs(r - g) <= 8 and 4 <= (b - r) <= 30


@requires_gl
def test_camera_page_boundary_pixels_land_where_transform_predicts() -> None:
    host = _make_host(VP_A)
    try:
        camera = (SCALE_A, CAM_TX, CAM_TY)
        host.set_document(_a4_doc([]))
        host.set_camera(*camera)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        img = _read_scene_top(host)
        left = world_to_screen((0.0, 0.0), camera, VP_A)[0]
        right = world_to_screen((A4_W, 0.0), camera, VP_A)[0]
        top = world_to_screen((0.0, 0.0), camera, VP_A)[1]
        bottom = world_to_screen((0.0, A4_H), camera, VP_A)[1]
        for row in (150, 300, 450):
            for edge, name in ((left, "left"), (right, "right")):
                window = img[row, int(edge) - 3 : int(edge) + 4]
                assert any(_is_borderish(px) for px in window), (
                    f"{name} page border not within ±3 px of x={edge:.1f} at row {row}"
                )
        for col in (350, 450):
            for edge, name in ((top, "top"), (bottom, "bottom")):
                window = img[int(edge) - 3 : int(edge) + 4, col]
                assert any(_is_borderish(px) for px in window), (
                    f"{name} page border not within ±3 px of y={edge:.1f} at col {col}"
                )
        # interior is paper or RULED pattern ink (neutral), never border blue
        mid = VP_A[1] // 2
        interior = img[mid, int(left) + 12].astype(int)
        assert interior.min() >= 130, f"page interior must be paper/pattern, got {interior}"
        assert int(interior[2] - interior[0]) <= 3, (
            f"page interior must be neutral (paper/pattern), not border blue: {interior}"
        )
        exterior = img[mid, int(left) - int(SHADOW_REACH_WORLD * SCALE_A) - 20].astype(int)
        assert exterior.min() >= 250, f"outside-page scaffold must be clear colour, got {exterior}"
    finally:
        _shutdown(host)
