"""Issue 02 (round 6) — live PC mirror pan must present NO stale-frame trails.

Reproduces the PC-only drag-trail defect in the REAL live render loop (the
round-5 offscreen fixtures rendered static frames, so they missed it): a
mounted ``GLCanvasHost`` on the DEFAULT pure-Tk blit path — real Tk ``after``
pump, real GL 3.3 context — loads an A4 doc with an ON-page stroke, an
OFF-page stroke (outside the artboard scissor box) and the page drop shadow,
then pans the camera ``+40`` world units per step, presenting the buffer each
step.

Defect mechanics (root cause, issue 02 round 6): moderngl's
``Framebuffer.use()`` re-ENABLES ``GL_SCISSOR_TEST`` with the box stored by
the previous frame's ``PrimitiveRenderer`` phase-1 scissor, so ``glClear``
only wiped the *previous* artboard rect. Everything drawn OUTSIDE that rect
(off-page strokes, the page shadow ring) was blended over its own previous
frame every step: strokes left ghosts at old positions and the feathered
shadow accumulated into dark "smeared bands".

Regression invariants per pan step (presented buffer, top-first rows):

1. No stale ink: every stroke-ink pixel of the previous frame must be
   background now (each stroke moves ``40·scale`` px > its ``20·scale`` px
   width per step, so clean frames never overlap);
2. All ink must sit inside the two expected stroke screen bboxes (§3
   transform) — accumulated shadow bands or any other stale darkening fail
   this.
"""

from __future__ import annotations

import tkinter as tk

import numpy as np

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import DOCUMENT_LOADED, EventBus
from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.tests.test_gl_canvas_host import (
    _make_root,
    _pump_until_clean,
    requires_gl,
)
from pc_agent.viewport.gl_canvas_host import GLCanvasHost
from pc_agent.viewport.primitive_renderer import world_to_screen

#: stroke ink ceiling (#000000); chrome stays far above (pattern 140,
#: boundary ≥120, feathered shadow ≥150 — test_gl_canvas_host helpers).
INK_MAX = 60
PAN_WORLD = 40.0  # world units panned per step (issue 02 repro)
STEPS = 6

#: stroke geometry: vertical lines, ``20`` world wide ⇒ ``20·scale`` px on
#: screen while the camera moves ``40·scale`` px per step ⇒ clean frames are
#: always disjoint by exactly one stroke width.
_ON_PAGE = (1240.0, 1600.0, 1240.0, 1900.0)   # inside the A4 page
_OFF_PAGE = (3200.0, 1600.0, 3200.0, 1900.0)  # right of world x=2480 ⇒ off-page
_STROKE_WIDTH_WORLD = 20.0


def _pan_doc() -> CanvasDocument:
    def stroke(node_id: str, x0: float, y0: float, x1: float, y1: float) -> CanvasNode:
        return CanvasNode(
            node_id=node_id,
            kind="STROKE",
            geometry=NodeGeometry(pts=[[x0, y0], [x1, y1]]),
            style=NodeStyle(stroke_width=_STROKE_WIDTH_WORLD, color="#000000", opacity=1.0),
            layer=1,
        )

    return CanvasDocument(
        canvas_id="pan-trail",
        title="Pan trail repro",
        created_at=0,
        updated_at=0,
        artboard=Artboard(
            preset="A4",
            width=2480.0,
            height=3508.0,
            is_infinite=False,
            background_style="RULED",
            background_color="#FFFFFF",
        ),
        content_bounds={"min_x": 0.0, "min_y": 0.0, "max_x": 2480.0, "max_y": 3508.0},
        elements=[
            stroke("on-page", *_ON_PAGE),
            stroke("off-page", *_OFF_PAGE),
        ],
    )


def _capture_presented(host: GLCanvasHost) -> np.ndarray:
    """The blit pipeline's PRESENTED RGBA buffer (top-first rows)."""
    height, width = host._vp_h, host._vp_w
    data = bytes(host._blit_buf)
    assert len(data) == height * width * 4, "presented buffer must match the viewport"
    return np.frombuffer(data, dtype=np.uint8).reshape(height, width, 4)


def _ink(presented: np.ndarray) -> np.ndarray:
    """Stroke-ink mask: dark pixels (chrome/background never reach ≤60)."""
    return presented[..., :3].max(axis=2) <= INK_MAX


def _stroke_bbox(
    stroke: tuple[float, float, float, float],
    camera: tuple[float, float, float],
    vp: tuple[int, int],
    margin_px: float = 4.0,
) -> tuple[int, int, int, int]:
    """Expected screen bbox (x0, y0, x1, y1 — y down) via the §3 transform."""
    x0, y0, x1, y1 = stroke
    half = _STROKE_WIDTH_WORLD / 2.0 + 2.0 / max(camera[0], 1e-9)
    corners = [
        world_to_screen((sx, sy), camera, vp)
        for sx in (x0 - half, x1 + half)
        for sy in (y0 - half, y1 + half)
    ]
    xs = [c[0] for c in corners]
    ys = [c[1] for c in corners]
    return (
        int(np.floor(min(xs) - margin_px)),
        int(np.floor(min(ys) - margin_px)),
        int(np.ceil(max(xs) + margin_px)),
        int(np.ceil(max(ys) + margin_px)),
    )


@requires_gl
def test_live_pan_presents_no_stale_frame_trails() -> None:
    """Issue 02: panning the live mirror must not smear previous frames."""
    root = _make_root()
    root.geometry("640x560")
    bus = EventBus()
    host = GLCanvasHost(root, AppConfig(), bus)
    try:
        parent = tk.Frame(root, width=600, height=500)
        parent.pack(fill="both", expand=True)
        host.mount(parent)
        _pump_until_clean(root, host)
        assert host._mode == "fallback", "the trail defect lives on the blit path"

        bus.emit(DOCUMENT_LOADED, doc=_pan_doc())
        host.fit_viewport()  # §10.5 fit — interior artboard scissor box (open state)
        _pump_until_clean(root, host)
        assert host._ctx.error == "GL_NO_ERROR"

        base = host._camera  # (scale, tx, ty) — fit result; panning keeps scale
        frames: list[np.ndarray] = [_capture_presented(host)]
        cameras: list[tuple[float, float, float]] = [base]
        for step in range(1, STEPS + 1):
            scale, tx, ty = base
            host.set_camera(scale, tx + PAN_WORLD * step, ty)
            host.request_redraw()
            _pump_until_clean(root, host)
            assert host._ctx.error == "GL_NO_ERROR", f"GL error after pan step {step}"
            frames.append(_capture_presented(host))
            cameras.append(host._camera)

        vp = (host._vp_w, host._vp_h)
        scale = base[0]
        # Sanity: per-step screen shift must exceed the stroke width, otherwise
        # "no overlap" would be impossible even for a clean renderer.
        assert PAN_WORLD * scale > _STROKE_WIDTH_WORLD * scale + 1.0

        for step in range(1, len(frames)):
            prev_ink = _ink(frames[step - 1])
            cur_ink = _ink(frames[step])
            stale = prev_ink & cur_ink
            assert not stale.any(), (
                f"step {step}: {int(stale.sum())} stale ink px at previous "
                f"stroke positions (trail) — presented buffer smeared"
            )

            # All ink must sit inside the two expected stroke screen bboxes.
            allowed = np.zeros(cur_ink.shape, dtype=bool)
            camera = cameras[step]
            for stroke in (_ON_PAGE, _OFF_PAGE):
                x0, y0, x1, y1 = _stroke_bbox(stroke, camera, vp)
                x0, y0 = max(0, x0), max(0, y0)
                x1, y1 = min(vp[0], x1), min(vp[1], y1)
                allowed[y0:y1, x0:x1] = True
            ys, xs = np.nonzero(cur_ink)
            assert len(ys) > 0, f"step {step}: strokes vanished (render broken)"
            outside = ~allowed[ys, xs]
            assert not outside.any(), (
                f"step {step}: {int(outside.sum())} ink px outside the expected "
                f"stroke bboxes (stale shadow band / ghost)"
            )

        # Task contract: pixels at PREVIOUS page/stroke positions are uniform
        # background — checked against the FIRST frame's ink as well.
        first_ink = _ink(frames[0])
        final_ink = _ink(frames[-1])
        assert not (first_ink & final_ink).any(), (
            "first-frame stroke positions must be background after the full pan"
        )
    finally:
        try:
            host.shutdown()
        except Exception:
            pass
        root.destroy()
        import gc

        gc.collect()


def test_fit_and_camera_scale_surface_exists_headless() -> None:
    """Frozen §10.5 surface on the host — importable + callable without GL."""
    from pc_agent.tests.test_gl_canvas_host import _make_host

    _, _, host = _make_host()
    assert isinstance(host.camera_scale, float), "camera_scale must be a float property"
    assert callable(host.fit_viewport), "fit_viewport must be a frozen callable"
    host.fit_viewport()  # no document ⇒ fallback rect fit, never raises
    assert 0.05 <= host.camera_scale <= 20.0
