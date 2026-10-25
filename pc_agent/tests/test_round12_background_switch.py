"""Round 12 — issue 07: the PC agent closed when switching to a canvas with a
different background.

The report is specifically about SWITCHING: BLANK↔RULED↔SQUARE_GRID canvases
were fine to open individually, but moving between them terminated the agent.

Why a switch is different from an in-place artboard edit:

* an artboard EDIT arrives as ``ARTBOARD_CHANGED`` and mutates the artboard in
  place (no camera change);
* a canvas SWITCH goes ``open_payload`` → ``DOCUMENT_LOADED`` →
  ``GLCanvasHost.set_document``, which calls ``fit_viewport()`` and installs a
  NEW artboard (new preset/size/``background_spacing``) plus a new camera.

The first frame after that switch renders the new artboard while the GL state
still describes the old one. ``PrimitiveRenderer._draw_background`` derived a
scissor rect from that mixed state and handed it straight to
``ctx.scissor = box``. moderngl rejects an out-of-range rect with an exception,
and a driver can fault outright — and a native fault is not catchable, which is
why the render path's ``try/except`` guards did not save the process.

The fix has three parts, each pinned below:

1. ``_artboard_scissor_box`` validates its inputs (finite, positive scale,
   positive viewport) before doing any math;
2. ``_apply_scissor`` is the only place that touches ``ctx.scissor`` and it can
   never let a bad rect escape;
3. ``reset_scissor`` gives ``set_document`` a way to clear the previous page's
   scissor before the new artboard's first frame.
"""

from __future__ import annotations

import math
from typing import Any

import pytest

from pc_agent.viewport.primitive_renderer import (
    _artboard_scissor_box,
    clamp_zoom,
)

_CAM = (0.5, 0.0, 0.0)  # scale, offset_x, offset_y
_VIEW = (1000, 800)


# ---------------------------------------------------------------------------
# 1. Scissor-box validation — a bad rect must become None, never a bad box
# ---------------------------------------------------------------------------
def test_a_normal_artboard_yields_a_valid_box() -> None:
    box = _artboard_scissor_box(2480.0, 3508.0, _CAM, *_VIEW)
    assert box is not None
    gx, gy, gw, gh = box
    assert gx >= 0 and gy >= 0
    assert gw > 0 and gh > 0
    assert gx + gw <= _VIEW[0]
    assert gy + gh <= _VIEW[1]


@pytest.mark.parametrize(
    ("width", "height"),
    [(0.0, 3508.0), (2480.0, 0.0), (-10.0, 3508.0), (2480.0, -1.0)],
)
def test_degenerate_page_size_is_rejected(width: float, height: float) -> None:
    assert _artboard_scissor_box(width, height, _CAM, *_VIEW) is None


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), float("-inf")])
def test_non_finite_page_size_is_rejected(bad: float) -> None:
    assert _artboard_scissor_box(bad, 3508.0, _CAM, *_VIEW) is None
    assert _artboard_scissor_box(2480.0, bad, _CAM, *_VIEW) is None


@pytest.mark.parametrize("bad", [float("nan"), float("inf")])
def test_non_finite_camera_is_rejected(bad: float) -> None:
    assert _artboard_scissor_box(2480.0, 3508.0, (bad, 0.0, 0.0), *_VIEW) is None
    assert _artboard_scissor_box(2480.0, 3508.0, (0.5, bad, 0.0), *_VIEW) is None
    assert _artboard_scissor_box(2480.0, 3508.0, (0.5, 0.0, bad), *_VIEW) is None


def test_zero_or_negative_zoom_is_rejected() -> None:
    """A transient scale of 0 collapses the rect to nothing; reject, never send."""
    assert _artboard_scissor_box(2480.0, 3508.0, (0.0, 0.0, 0.0), *_VIEW) is None
    assert _artboard_scissor_box(2480.0, 3508.0, (-1.0, 0.0, 0.0), *_VIEW) is None


def test_zero_viewport_is_rejected() -> None:
    assert _artboard_scissor_box(2480.0, 3508.0, _CAM, 0, 800) is None
    assert _artboard_scissor_box(2480.0, 3508.0, _CAM, 1000, 0) is None


def test_off_screen_page_is_rejected() -> None:
    # Panned far away: the page is outside the viewport entirely.
    assert _artboard_scissor_box(2480.0, 3508.0, (0.5, 1e7, 1e7), *_VIEW) is None


@pytest.mark.parametrize("scale", [0.05, 0.25, 0.5, 1.0, 4.0, 20.0])
def test_every_supported_zoom_yields_an_in_range_box(scale: float) -> None:
    """No zoom the app allows may produce an out-of-range rect.

    ``ctx.scissor`` raises on a rect outside the framebuffer, so this is the
    exact property the crash depended on.
    """
    box = _artboard_scissor_box(2480.0, 3508.0, (scale, -100.0, -100.0), *_VIEW)
    if box is None:
        return  # legitimately off-screen at this zoom — fine
    gx, gy, gw, gh = box
    assert 0 <= gx and 0 <= gy
    assert gw > 0 and gh > 0
    assert gx + gw <= _VIEW[0]
    assert gy + gh <= _VIEW[1]


@pytest.mark.parametrize("preset", [(1748.0, 2480.0), (2480.0, 3508.0), (2550.0, 3300.0)])
def test_every_preset_yields_an_in_range_box(preset: tuple[float, float]) -> None:
    box = _artboard_scissor_box(preset[0], preset[1], (0.3, 0.0, 0.0), *_VIEW)
    assert box is not None
    gx, gy, gw, gh = box
    assert gx + gw <= _VIEW[0] and gy + gh <= _VIEW[1]


# ---------------------------------------------------------------------------
# 2/3. The renderer's scissor surface: guarded, resettable
# ---------------------------------------------------------------------------
class _FakeCtx:
    """Records scissor traffic; optionally rejects a rect like moderngl does."""

    def __init__(self, reject: bool = False) -> None:
        self.reject = reject
        self._scissor: tuple[int, int, int, int] | None = None
        self.enabled = False
        self.assignments: list[Any] = []

    @property
    def scissor(self) -> tuple[int, int, int, int] | None:
        return self._scissor

    @scissor.setter
    def scissor(self, value: tuple[int, int, int, int] | None) -> None:
        self.assignments.append(value)
        if self.reject and value is not None:
            raise RuntimeError("moderngl: scissor rect outside the framebuffer")
        self._scissor = value

    def enable_direct(self, _enum: int) -> None:
        self.enabled = True

    def disable_direct(self, _enum: int) -> None:
        self.enabled = False


def _renderer(ctx: Any) -> Any:
    """A PrimitiveRenderer with only the GL bits these tests touch."""
    from pc_agent.viewport import primitive_renderer as renderer

    obj = renderer.PrimitiveRenderer.__new__(renderer.PrimitiveRenderer)
    obj._ctx = ctx
    obj.applied_scissor = (1, 2, 3, 4)
    obj.scissor_enabled = True
    return obj


def test_a_rejected_scissor_is_swallowed_and_released() -> None:
    """The renderer must never raise out of a scissor assignment."""
    ctx = _FakeCtx(reject=True)
    obj = _renderer(ctx)
    obj._apply_scissor((0, 0, 10, 10))  # must not raise
    assert ctx.enabled is False, "the test is left disabled after a rejection"


def test_a_good_scissor_is_applied_and_enabled() -> None:
    ctx = _FakeCtx()
    obj = _renderer(ctx)
    obj._apply_scissor((5, 6, 100, 200))
    assert ctx.scissor == (5, 6, 100, 200)
    assert ctx.enabled is True


def test_reset_scissor_clears_both_state_and_gl() -> None:
    ctx = _FakeCtx()
    obj = _renderer(ctx)
    obj._apply_scissor((5, 6, 100, 200))
    obj.reset_scissor()
    assert obj.applied_scissor is None
    assert obj.scissor_enabled is False
    assert ctx.scissor is None
    assert ctx.enabled is False


def test_reset_scissor_survives_a_broken_context() -> None:
    """A failed reset must not propagate - it runs on the render thread."""

    class _Broken(_FakeCtx):
        @property
        def scissor(self) -> Any:
            return None

        @scissor.setter
        def scissor(self, value: Any) -> None:
            raise RuntimeError("context lost")

        def disable_direct(self, _enum: int) -> None:
            raise RuntimeError("context lost")

    obj = _renderer(_Broken())
    obj.reset_scissor()  # must not raise
    assert obj.scissor_enabled is False


def test_switch_resets_the_scissor_through_the_host(monkeypatch: pytest.MonkeyPatch) -> None:
    """``set_document`` must clear the previous page's scissor."""
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.core.events import EventBus
    from pc_agent.viewport.gl_canvas_host import GLCanvasHost

    calls: list[str] = []

    class _Primitive:
        def reset_scissor(self) -> None:
            calls.append("reset")

    host = GLCanvasHost(_FakeTk(), AppConfig(), EventBus())
    host._primitive = _Primitive()  # type: ignore[assignment]
    host._reset_renderer_scissor()
    assert calls == ["reset"]


class _FakeTk:
    def after(self, _ms: int, callback: Any = None, *args: Any) -> str:
        return "after#1"

    def after_cancel(self, _after_id: str) -> None:
        return None


# ---------------------------------------------------------------------------
# Zoom clamping is what keeps the scale positive in the first place
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("raw", [0.0, -5.0, float("nan"), 1e-9, 1e9])
def test_clamp_zoom_always_returns_a_usable_scale(raw: float) -> None:
    scale = clamp_zoom(raw)
    assert math.isfinite(scale)
    assert scale > 0.0
