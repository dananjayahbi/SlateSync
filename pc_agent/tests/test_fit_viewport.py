"""Issue 03 round 6 (Doc 02 §10.5, NORMATIVE) — ``GLCanvasHost.fit_viewport``.

Covers the frozen surface (``fit_viewport() -> None`` + ``camera_scale ->
float``), the fit math table (bounded / infinite / empty-fallback / clamps),
fit-on-``set_document`` (headless, real event bus), idempotency, the
pre-realization default-size fit, and the documented CAMERA_DELTA-override
rule (the PC mirrors the tablet camera, so a later CAMERA_DELTA replaces the
fitted camera — by design).

Formula (Doc 02 §10.5 + Doc 20 §4 mobile mirror, which this implementation
matches exactly):

* target rect: bounded ⇒ ``(0, 0, w, h)``; infinite ⇒ ``content_bounds``
  (empty/degenerate ⇒ ``(-500, -500, 1000, 1000)`` as ``x, y, w, h``);
* ``scale = clamp(min(viewport_w / (w + 96), viewport_h / (h + 96)),
  0.05, 20.0)`` — 48 world units of padding per side;
* ``tx, ty`` = rect center (§3 transform: world coord at viewport center).
"""

from __future__ import annotations

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import CAMERA_DELTA, DOCUMENT_LOADED, EventBus
from pc_agent.core.protocol import FRAME_CAMERA, LiveFrame
from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.viewport.gl_canvas_host import (
    DEFAULT_MOUNT_H,
    DEFAULT_MOUNT_W,
    FIT_FALLBACK_RECT,
    FIT_PADDING,
    ZOOM_MAX,
    ZOOM_MIN,
    GLCanvasHost,
)
from pc_agent.viewport.primitive_renderer import visible_world_rect


class _FakeTk:
    """Records ``after``/``after_cancel``; callbacks never fire headless."""

    def __init__(self) -> None:
        self._next = 0

    def after(self, ms: int, callback) -> str:
        self._next += 1
        return f"after#{self._next}"

    def after_cancel(self, after_id: str) -> None:
        return None


def _host(vp: tuple[int, int] | None = None) -> tuple[EventBus, GLCanvasHost]:
    bus = EventBus()
    host = GLCanvasHost(_FakeTk(), AppConfig(), bus)
    if vp is not None:
        host._vp_w, host._vp_h = vp
    return bus, host


def _doc(
    *,
    preset: str = "A4",
    width: float | None = 2480.0,
    height: float | None = 3508.0,
    is_infinite: bool = False,
    content_bounds: dict[str, float] | None = None,
) -> CanvasDocument:
    return CanvasDocument(
        canvas_id=f"fit-{preset.lower()}",
        title="Fit",
        created_at=0,
        updated_at=0,
        artboard=Artboard(
            preset=preset,
            width=width,
            height=height,
            is_infinite=is_infinite,
            background_style="BLANK",
            background_color="#FFFFFF",
        ),
        content_bounds=content_bounds
        if content_bounds is not None
        else {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        elements=[],
    )


_VP = (1264, 660)  # task's fit table viewport


def _expected(vw: int, vh: int, w: float, h: float) -> tuple[float, float, float]:
    """§10.5 + Doc 20 §4: clamp(min(vw/(w+96), vh/(h+96))) + center."""
    zx = vw / (w + 96.0)
    zy = vh / (h + 96.0)
    scale = max(ZOOM_MIN, min(ZOOM_MAX, zx if zx < zy else zy))
    return (scale, w / 2.0, h / 2.0)


FIT_TABLE = [
    # (name, doc, viewport, (w, h) target rect, expected (center_x, center_y))
    (
        "A4 bounded → artboard rect",
        _doc(),
        _VP,
        (2480.0, 3508.0),
        (1240.0, 1754.0),
    ),
    (
        "A5 bounded → artboard rect",
        _doc(preset="A5", width=1748.0, height=2480.0),
        _VP,
        (1748.0, 2480.0),
        (874.0, 1240.0),
    ),
    (
        "INFINITE with content → content_bounds",
        _doc(
            preset="INFINITE",
            width=None,
            height=None,
            is_infinite=True,
            content_bounds={
                "min_x": 0.0, "min_y": 0.0, "max_x": 1000.0, "max_y": 800.0
            },
        ),
        _VP,
        (1000.0, 800.0),
        (500.0, 400.0),
    ),
    (
        "INFINITE empty content → (-500,-500,1000,1000) fallback",
        _doc(
            preset="INFINITE",
            width=None,
            height=None,
            is_infinite=True,
            content_bounds={"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        ),
        _VP,
        (1000.0, 1000.0),
        (0.0, 0.0),
    ),
    (
        "bounded but degenerate size → content_bounds",
        _doc(
            preset="A4",
            width=None,
            height=None,
            content_bounds={
                "min_x": 0.0, "min_y": 0.0, "max_x": 600.0, "max_y": 400.0
            },
        ),
        _VP,
        (600.0, 400.0),
        (300.0, 200.0),
    ),
    (
        "clamp 0.05 — viewport smaller than padding+1",
        _doc(),
        (96, 96),
        (2480.0, 3508.0),
        (1240.0, 1754.0),
    ),
    (
        "clamp 20.0 — huge viewport over fallback rect",
        _doc(
            preset="INFINITE",
            width=None,
            height=None,
            is_infinite=True,
            content_bounds={"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        ),
        (40000, 40000),
        (1000.0, 1000.0),
        (0.0, 0.0),
    ),
]


@pytest.mark.parametrize(
    ("name", "doc", "viewport", "rect", "center"),
    FIT_TABLE,
    ids=[row[0] for row in FIT_TABLE],
)
def test_fit_math_table(
    name: str,
    doc: CanvasDocument,
    viewport: tuple[int, int],
    rect: tuple[float, float],
    center: tuple[float, float],
) -> None:
    _, host = _host(viewport)
    host.set_document(doc)
    rect_w, rect_h = rect
    scale = _expected(viewport[0], viewport[1], rect_w, rect_h)[0]
    assert host.camera_scale == pytest.approx(scale, abs=1e-9), name
    assert host._camera[1] == pytest.approx(center[0], abs=1e-6), name
    assert host._camera[2] == pytest.approx(center[1], abs=1e-6), name
    assert ZOOM_MIN <= host.camera_scale <= ZOOM_MAX, name


def test_fit_padding_is_48_world_units_per_side() -> None:
    """§10.5: the fitted axis leaves exactly FIT_PADDING margin per side."""
    assert FIT_PADDING == 48.0
    _, host = _host(_VP)
    host.set_document(_doc())  # A4 → height-bound at 1264×660
    scale = host.camera_scale
    # visible_world_rect is symmetric about (tx, ty): half-height = vh/(2s).
    left, top, right, bottom = visible_world_rect(host._camera, _VP)
    # On the fitted (height) axis the content + 48u padding fills the view
    # exactly; the other axis only over-fills.
    assert top <= 0.0 - 48.0 + 1e-6  # 48u clear above y=0 …
    assert bottom >= 3508.0 + 48.0 - 1e-6  # … and below the page bottom
    assert (right - left) * scale >= _VP[0] - 1e-6
    assert scale == pytest.approx(_VP[1] / (3508.0 + 96.0), rel=1e-12)


def test_fit_applied_by_set_document_and_document_loaded() -> None:
    """set_document applies the fit; DOCUMENT_LOADED routes through it."""
    bus, host = _host(_VP)
    host.set_document(_doc())
    expected = _expected(_VP[0], _VP[1], 2480.0, 3508.0)
    assert host.camera_scale == pytest.approx(expected[0], abs=1e-9)
    assert host._camera[1:] == pytest.approx(expected[1:], abs=1e-6)

    # Fresh host through the real event bus.
    bus2, host2 = _host(_VP)
    bus2.emit(DOCUMENT_LOADED, doc=_doc())
    assert host2.camera_scale == pytest.approx(expected[0], abs=1e-9)
    assert host2._camera[1:] == pytest.approx(expected[1:], abs=1e-6)


def test_fit_is_idempotent() -> None:
    _, host = _host(_VP)
    host.set_document(_doc())
    first = host._camera
    host.fit_viewport()
    assert host._camera == first, "repeat fit must recompute the same camera"
    host.fit_viewport()
    assert host._camera == first


def test_fit_before_realized_viewport_uses_default_mount_size() -> None:
    _, host = _host()  # vp 0×0 — set_document can precede <Configure>
    host.set_document(_doc())
    expected = _expected(DEFAULT_MOUNT_W, DEFAULT_MOUNT_H, 2480.0, 3508.0)
    assert host.camera_scale == pytest.approx(expected[0], abs=1e-9)
    assert host._camera[1:] == pytest.approx(expected[1:], abs=1e-6)


def test_fit_without_document_uses_fallback_rect() -> None:
    _, host = _host(_VP)
    x, y, w, h = FIT_FALLBACK_RECT
    host.fit_viewport()
    expected = _expected(_VP[0], _VP[1], w, h)
    assert host.camera_scale == pytest.approx(expected[0], abs=1e-9)
    assert host._camera[1:] == pytest.approx(
        (x + w / 2.0, y + h / 2.0), abs=1e-6
    )


def test_camera_delta_overrides_fitted_camera() -> None:
    """Documented §10.5 rule: later CAMERA_DELTA (tablet mirror) wins."""
    bus, host = _host(_VP)
    bus.emit(DOCUMENT_LOADED, doc=_doc())
    fitted = host.camera_scale
    assert fitted == pytest.approx(_expected(_VP[0], _VP[1], 2480.0, 3508.0)[0])

    frame = LiveFrame(FRAME_CAMERA, 0x01, 7, 3.25, -12.0, 44.0)
    bus.emit(CAMERA_DELTA, frame=frame)
    assert host.camera_scale == pytest.approx(3.25, abs=1e-9)
    assert host._camera[1:] == pytest.approx((-12.0, 44.0), abs=1e-9)


def test_camera_scale_is_a_float_property() -> None:
    _, host = _host(_VP)
    assert isinstance(host.camera_scale, float)
    assert host.camera_scale == 1.0  # constructor default (§3)
