"""Round-6 hotfix r6-pc-line-gl — committed kind ``LINE`` nodes in the PC GL mirror.

Mobile commits the line tool as ``{kind: 'LINE', shape_type: null,
pts: [[sx, sy], [ex, ey]}`` under ``ELEMENT_COMMIT/ADD_SHAPE`` (mobile
``canvas_shape_conventions.dart``; frozen convention: LINE is a straight
segment ``pts[0] → pts[-1]`` on every renderer — normative PC exporters in
``pc_agent/export/tiled_raster_exporter.py`` draw exactly that).

The GL viewport previously had NO LINE branch in the committed-node path:
``GLCanvasHost._commit_node`` fed LINE pts through the Doc 21 Bézier-chain
normaliser (wrong: multi-anchor pts with ``n ≥ 4, (n−1) % 3 == 0`` are
misread as cubic chains; other multi-anchor pts became a Catmull-Rom spline
through the intermediate anchors instead of the normative straight segment)
and ``PrimitiveRenderer._tessellate_shape`` silently dropped kind LINE in
the Doc 08 shape phase. This module locks the fix in:

* offscreen (real host pipeline) render of one LINE node → ink along the
  analytic first→last segment at every sample (±3 px) and zero ink far off
  it (containment);
* a multi-anchor LINE renders on the STRAIGHT first→last segment, with the
  off-segment kink anchor region clean;
* branch selection: ``_commit_node`` passes exactly ``[start, end]`` to
  ``build_stroke`` (never densified chain samples), even for a 4-point pts
  layout that the chain detector would claim; ``_tessellate_shape`` returns
  before any shape-ring/circle fill for kind LINE (a SHAPE twin with the
  same geometry DOES fill — the control that proves the guard is selected).

Rig helpers are reused from ``test_mirror_render_fixtures`` (offscreen
GLCanvasHost → ``_render`` → FBO readback) and ``test_gl_canvas_host``
(windowless host for the spy-based commit tests).
"""

from __future__ import annotations

import numpy as np

from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.tests.test_gl_canvas_host import _make_host as _make_spy_host
from pc_agent.tests.test_mirror_render_fixtures import (
    _a4_doc,
    _ink,
    _make_host,
    _read_scene_top,
    _render_full,
    _shutdown,
    requires_gl,
)
from pc_agent.viewport.primitive_renderer import (
    PrimitiveRenderer,
    world_to_screen,
)

# --- rig constants ---------------------------------------------------------
#: Fixture viewport (same as mirror fixtures B/C/D — 1600x900 offscreen FBO).
VP = (1600, 900)
#: Camera putting the whole (200,300)→(900,1500) segment comfortably on-screen.
CAMERA = (0.5, 550.0, 900.0)
#: Committed LINE under test: world segment + style (dark, width 6).
LINE_START = (200.0, 300.0)
LINE_END = (900.0, 1500.0)
LINE_WIDTH = 6.0
LINE_COLOR = "#1E1E1E"
#: Analytic-segment sampling: on-screen points checked for ink.
SAMPLE_COUNT = 9
#: Per-sample ink hit window (px) — the task's ±3 px tolerance.
HIT_RADIUS_PX = 3
#: Ink near the segment: half stroke width in screen px + the 3 px tolerance.
MAX_OFF_SEGMENT_PX = 0.5 * LINE_WIDTH * CAMERA[0] + HIT_RADIUS_PX


def _line_node(
    node_id: str,
    pts: list[tuple[float, float]],
    *,
    width: float = LINE_WIDTH,
    color: str = LINE_COLOR,
    shape_type: str | None = None,
    kind: str = "LINE",
) -> CanvasNode:
    """Mobile-convention node: kind LINE, ``shape_type`` null, raw anchor pts.

    Doc 03 bbox rule (min/max over pts) — the same shape ``_build_node``
    constructs from an ``ADD_SHAPE`` payload on the wire.
    """
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return CanvasNode(
        node_id=node_id,
        kind=kind,
        layer=0,
        bbox=(min(xs), min(ys), max(xs), max(ys)),
        style=NodeStyle(color=color, stroke_width=width, opacity=1.0),
        geometry=NodeGeometry(
            pts=[[float(x), float(y)] for x, y in pts], shape_type=shape_type
        ),
    )


def _segment_screen_frame() -> tuple[np.ndarray, np.ndarray]:
    """Analytic segment as screen-space ``(start, end)`` float arrays."""
    start = np.asarray(world_to_screen(LINE_START, CAMERA, VP), dtype=float)
    end = np.asarray(world_to_screen(LINE_END, CAMERA, VP), dtype=float)
    return start, end


def _segment_points_screen(count: int = SAMPLE_COUNT) -> list[tuple[float, float]]:
    """``count`` evenly spaced analytic points of the segment in screen px."""
    start, end = _segment_screen_frame()
    ts = np.linspace(0.0, 1.0, count)
    return [tuple(start + t * (end - start)) for t in ts]


def _ink_hit(ink: np.ndarray, x: float, y: float, radius: int = HIT_RADIUS_PX) -> bool:
    """Is there ink inside the ±``radius`` window around a screen pixel?"""
    xi, yi = int(round(x)), int(round(y))
    if not (0 <= xi < VP[0] and 0 <= yi < VP[1]):
        return False
    window = ink[max(0, yi - radius) : yi + radius + 1, max(0, xi - radius) : xi + radius + 1]
    return bool(window.any())


def _max_off_segment_px(ink: np.ndarray) -> float:
    """Largest perpendicular (clamped-to-segment) distance of any ink pixel."""
    ys, xs = np.nonzero(ink)
    assert len(xs) > 0, "no ink at all — nothing to bound"
    start, end = _segment_screen_frame()
    points = np.stack([xs.astype(float), ys.astype(float)], axis=1)
    seg = end - start
    t = np.clip(((points - start) @ seg) / float(seg @ seg), 0.0, 1.0)
    nearest = start + t[:, None] * seg
    return float(np.linalg.norm(points - nearest, axis=1).max())


# ---------------------------------------------------------------------------
# Offscreen render — ink ON the analytic segment, nowhere else
# ---------------------------------------------------------------------------


@requires_gl
def test_line_node_renders_ink_on_analytic_segment_with_containment() -> None:
    """One committed LINE: every analytic sample has ink (±3 px), all ink hugs
    the segment — the live mirror draws the frozen first→last convention."""
    host = _make_host(VP)
    try:
        host.set_document(
            _a4_doc(
                [_line_node("line-1", [LINE_START, LINE_END])]
            )
        )
        host.set_camera(*CAMERA)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        img = _read_scene_top(host)
        ink = _ink(img)

        samples = _segment_points_screen()
        misses = [
            (round(x, 1), round(y, 1))
            for x, y in samples
            if not _ink_hit(ink, x, y)
        ]
        assert len(samples) >= 5
        assert not misses, (
            f"no ink within ±{HIT_RADIUS_PX}px at {len(misses)}/{len(samples)} "
            f"analytic segment samples: {misses} (LINE not drawn / drawn elsewhere)"
        )

        max_off = _max_off_segment_px(ink)
        assert max_off <= MAX_OFF_SEGMENT_PX, (
            f"ink {max_off:.2f}px off the analytic segment (budget "
            f"{MAX_OFF_SEGMENT_PX:.2f}px) — stray geometry, not a straight stroke"
        )
    finally:
        _shutdown(host)


@requires_gl
def test_multianchor_line_is_straight_first_to_last_not_anchor_spline() -> None:
    """Multi-anchor LINE renders on the STRAIGHT first→last normative segment:
    samples hit, and the region around an off-segment kink anchor stays clean."""
    kink = (1400.0, 400.0)  # far off the (200,300)→(900,1500) straight line
    host = _make_host(VP)
    try:
        host.set_document(_a4_doc([_line_node("line-3", [LINE_START, kink, LINE_END])]))
        host.set_camera(*CAMERA)
        _render_full(host)
        assert host._ctx.error == "GL_NO_ERROR"
        ink = _ink(_read_scene_top(host))

        misses = [
            (round(x, 1), round(y, 1))
            for x, y in _segment_points_screen()
            if not _ink_hit(ink, x, y)
        ]
        assert not misses, (
            f"straight-segment samples missing ink: {misses} — a spline through "
            "the kink anchor replaced the normative first→last segment"
        )

        # Kink anchor region: ~490 px off the analytic segment — must stay clear.
        kx, ky = world_to_screen(kink, CAMERA, VP)
        kink_window = ink[
            max(0, int(ky) - 10) : int(ky) + 11, max(0, int(kx) - 10) : int(kx) + 11
        ]
        assert not kink_window.any(), (
            "ink found at the off-segment kink anchor — LINE is being splined "
            "through intermediate anchors instead of drawn first→last"
        )

        max_off = _max_off_segment_px(ink)
        assert max_off <= MAX_OFF_SEGMENT_PX, (
            f"ink {max_off:.2f}px off the analytic segment (budget "
            f"{MAX_OFF_SEGMENT_PX:.2f}px)"
        )
    finally:
        _shutdown(host)


# ---------------------------------------------------------------------------
# Branch selection — unit level (no GL required)
# ---------------------------------------------------------------------------


def test_commit_node_line_branch_feeds_exactly_start_end_to_build_stroke() -> None:
    """``_commit_node`` takes the LINE branch: ``build_stroke`` receives exactly
    ``[pts[0], pts[last]]`` — never chain densification (a 4-point layout the
    Doc 21 detector claims: ``(4 − 1) % 3 == 0``) and never the anchor list."""
    from pc_agent.viewport.stroke_tessellator import is_cubic_chain

    _, _, host = _make_spy_host()

    class _RecordingTess:
        width_pressure_factor = -1.0  # sentinel: _commit_node must zero it
        scale = 1.0

        def __init__(self) -> None:
            self.calls: list[tuple[list, list, float]] = []

        def build_stroke(self, points, pressure, width):
            self.calls.append((list(points), list(pressure), float(width)))
            return ("mesh", len(points))

    tess = _RecordingTess()
    host._tessellator = tess
    host._stroke_program = object()  # non-None gate only — no GL on this path

    # 4 layout points ⇒ is_cubic_chain True — the pre-fix chain misread.
    pts = [(10.0, 20.0), (110.0, 5.0), (260.0, 400.0), (500.0, 700.0)]
    assert is_cubic_chain(pts), "fixture must exercise the chain-claiming layout"
    host._commit_node(_line_node("line-u1", pts, width=6.0))
    assert len(tess.calls) == 1, "kind LINE must reach the stroke mesh path"
    points, pressure, width = tess.calls[-1]
    assert points == [pts[0], pts[-1]], (
        f"LINE must tessellate as exactly [start, end], got {points}"
    )
    assert width == 6.0, "LINE must use style.stroke_width"
    assert pressure == [1.0] * len(points)

    # 2-point convention (the mobile wire layout) keeps working unchanged.
    host._commit_node(_line_node("line-u2", [(0.0, 0.0), (60.0, 80.0)]))
    points, _, _ = tess.calls[-1]
    assert points == [(0.0, 0.0), (60.0, 80.0)]


def test_tessellate_shape_line_branch_returns_before_shape_ring_or_circle() -> None:
    """``_tessellate_shape`` selects the kind-LINE guard: even a LINE carrying a
    misleading ``shape_type='CIRCLE'`` produces NO fills/lines, while a SHAPE
    twin with identical geometry does produce circle fill (control)."""
    pts = [(100.0, 100.0), (340.0, 260.0)]  # center→rim: a circle if drawn
    line = _line_node("line-ring", pts, shape_type="CIRCLE")

    fills: list[float] = []
    lines: list[float] = []
    PrimitiveRenderer._tessellate_shape(None, line, fills, lines, 1.0)
    assert fills == [] and lines == [], (
        "kind LINE fell into shape-ring/circle tessellation instead of the "
        "stroke-mesh branch"
    )

    # Control: the same geometry as a SHAPE only fills when its style asks for
    # a fill — round-8 issue 02 made stroke_width == 0 the sole fill trigger
    # (positive widths are outlines, which is what the tablet draws).
    shape = _line_node(
        "shape-ring", pts, shape_type="CIRCLE", kind="SHAPE", width=0.0
    )
    ctrl_fills: list[float] = []
    ctrl_lines: list[float] = []
    PrimitiveRenderer._tessellate_shape(None, shape, ctrl_fills, ctrl_lines, 1.0)
    assert ctrl_fills, "control SHAPE/CIRCLE (stroke_width 0) must fill"

    # And the default stroked width really is outline-only.
    stroked = _line_node("shape-ring-2", pts, shape_type="CIRCLE", kind="SHAPE")
    out_fills: list[float] = []
    out_lines: list[float] = []
    PrimitiveRenderer._tessellate_shape(None, stroked, out_fills, out_lines, 1.0)
    assert out_fills == [], "a stroked CIRCLE must not fill its interior"
    assert out_lines, "a stroked CIRCLE must still draw its rim"
