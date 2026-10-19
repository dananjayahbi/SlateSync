"""Doc 02 §10.5 — PC view-fit-on-open wiring in ``main.py``.

``attach_view_fit`` is the frozen contract handler: on ``DOCUMENT_LOADED`` it
calls ``gl_host.fit_viewport()`` FIRST, then refreshes the HUD via
``window.update_hud(scale=gl_host.camera_scale, preset=...)`` — both names are
§10.5 API freezes (the GL host implementation lands with the viewport agent).
``run_full`` mocks nothing here: the handler is exercised against fakes that
record call order and arguments.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from pc_agent.core.events import DOCUMENT_LOADED, EventBus
from pc_agent.main import attach_view_fit

_SOURCE = Path(__file__).resolve().parents[1] / "main.py"


class _FakeGlHost:
    """Frozen surface used by §10.5: ``fit_viewport()`` + ``camera_scale``."""

    def __init__(self, log: list) -> None:
        self._log = log
        self.camera_scale = 2.5

    def fit_viewport(self) -> None:
        self._log.append(("fit",))


class _FakeWindow:
    """Frozen ``update_hud(scale=..., preset=...)`` call recorder."""

    def __init__(self, log: list) -> None:
        self._log = log

    def update_hud(self, scale: float, preset: str) -> None:
        self._log.append(("hud", scale, preset))


def _doc(preset: str = "A4") -> SimpleNamespace:
    return SimpleNamespace(artboard=SimpleNamespace(preset=preset))


def _wired(current_doc: dict | None = None):
    log: list = []
    bus = EventBus()
    attach_view_fit(bus, _FakeGlHost(log), _FakeWindow(log), current_doc or {"doc": None})
    return log, bus


def test_document_loaded_fits_viewport_then_updates_hud_in_order() -> None:
    log, bus = _wired()
    bus.emit(DOCUMENT_LOADED, doc=_doc("A5"))
    assert log == [("fit",), ("hud", 2.5, "A5")]  # fit FIRST, then HUD refresh


def test_hud_preset_falls_back_to_current_document_without_doc_payload() -> None:
    log, bus = _wired({"doc": _doc("INFINITE")})
    bus.emit(DOCUMENT_LOADED)  # event without a doc kwarg → run_full's slot
    assert log == [("fit",), ("hud", 2.5, "INFINITE")]


def test_hud_preset_is_empty_when_no_document_anywhere() -> None:
    log, bus = _wired({"doc": None})
    bus.emit(DOCUMENT_LOADED, doc=None)
    assert log == [("fit",), ("hud", 2.5, "")]


def test_repeated_loads_refit_and_refresh_every_time() -> None:
    log, bus = _wired()
    for preset in ("A5", "LETTER"):
        bus.emit(DOCUMENT_LOADED, doc=_doc(preset))
    assert log == [("fit",), ("hud", 2.5, "A5"), ("fit",), ("hud", 2.5, "LETTER")]


def test_run_full_registers_the_view_fit_handler() -> None:
    """Wiring proof: run_full attaches the §10.5 handler after the GUI exists."""
    source = _SOURCE.read_text(encoding="utf-8")
    assert "attach_view_fit(bus, gl_host, window, current_doc)" in source
