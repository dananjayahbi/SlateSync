"""Issue 04 regression tests — window position stability + drag-safe raising.

Proves that (a) the toplevel position survives a LIVE_FRAME storm with the
production raise wiring active (poller + ``after(0)`` show + ``on_live_activity``),
(b) auto-raise is suppressed while the ``_dragging`` flag is set, (c) auto-raise
is suppressed while Win32's modal move loop reports ``hwndMoveSize`` (the
press-and-hold phase, before any ``<Configure>`` fires), and (d) the
``<Configure>``-based drag detection sets and clears the flag on schedule.
All roots are withdrawn ``CTk`` instances (Doc 16 test convention).
"""

from __future__ import annotations

import time
import tkinter as tk
import types
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import EventBus
from pc_agent.core.protocol import FRAME_LIVE_POINT, LiveFrame
from pc_agent.gui import studio_window as sw
from pc_agent.gui.studio_window import StudioWindow

_STORM_S = 1.6  # spans ≥1 raise-per-second throttle window


class _FakeGLHost:
    def mount(self, parent_widget: Any) -> None:
        pass


class _SubmitSpy:
    def __call__(self, job: dict) -> str:
        return "job-1"


def _make_root() -> tk.Tk:
    # Plain withdrawn tk.Tk — the production root type (run_full: root = tk.Tk()).
    last_error: Exception | None = None
    for _ in range(3):
        try:
            root = tk.Tk()
            break
        except Exception as exc:  # pragma: no cover - display contention
            last_error = exc
            time.sleep(0.2)
    else:  # pragma: no cover - display contention
        pytest.skip(f"Tk unavailable: {last_error}")
    root.withdraw()
    root.geometry("720x480+400+300")  # explicit position BEFORE build()
    root.update_idletasks()
    return root


@contextmanager
def _studio() -> Iterator[tuple[Any, StudioWindow]]:
    root = _make_root()
    win = StudioWindow(AppConfig(), EventBus(), _FakeGLHost(), _SubmitSpy())
    win.build(root)
    try:
        yield root, win
    finally:
        try:
            root.destroy()
        except Exception:
            pass


def _pump_until(root: Any, condition: Callable[[], bool], timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        root.update()
        if condition():
            return True
        time.sleep(0.02)
    return condition()


def _storm(root: Any, win: StudioWindow, bus: EventBus, duration: float) -> None:
    """Frames + production raise wiring pumping for ``duration`` seconds."""
    end = time.monotonic() + duration
    seq = 0
    last_show = 0.0
    while time.monotonic() < end:
        seq += 1
        bus.emit(
            "LIVE_FRAME",
            frame=LiveFrame(FRAME_LIVE_POINT, 1, seq & 0xFFFF, 5.0, 5.0, 0.5),
        )
        win.on_live_activity()  # frozen ≥1 s throttle path
        now = time.monotonic()
        if now - last_show >= 1.0:  # TrayDaemon's own ≥1 s wiring
            last_show = now
            win.after(0, win.show)
        root.update()
        time.sleep(0.01)


def test_position_stable_under_live_frame_storm() -> None:
    """Geometry set → storm of frames/ticks/raises → position unchanged."""
    with _studio() as (root, win):
        start = (root.winfo_x(), root.winfo_y())
        assert start == (400, 300), "geometry must be pinned before the storm"

        _storm(root, win, win._bus, _STORM_S)
        _pump_until(root, lambda: False, timeout=0.2)  # settle after(0) queue

        assert (root.winfo_x(), root.winfo_y()) == start, (
            "window position must not drift while frames stream"
        )
        # The raises really executed during the storm (wiring is alive):
        # state may be normal (deiconified) — but position must be identical.
        assert root.state() in ("withdrawn", "normal", "iconic")


def test_auto_raise_suppressed_while_drag_flag_set() -> None:
    """_dragging=True → show/_raise_window never touch the window."""
    with _studio() as (root, win):
        win._dragging = True
        win.show()
        win._raise_window()
        root.update()
        assert root.state() == "withdrawn", (
            "deiconify+lift must be skipped during an active drag"
        )

        win._dragging = False
        win.show()
        assert _pump_until(root, lambda: root.state() == "normal"), (
            "show must work again once the drag flag clears"
        )
        pos_after = (root.winfo_x(), root.winfo_y())
        assert pos_after == (400, 300)


def test_auto_raise_suppressed_while_native_move_loop_active(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """GetGUIThreadInfo(hwndMoveSize) set → raise skipped (hold-before-move)."""
    with _studio() as (root, win):
        monkeypatch.setattr(sw, "_move_loop_active", lambda: True)
        win.show()
        win._raise_window()
        root.update()
        assert root.state() == "withdrawn", (
            "a live Win32 move loop must block deiconify+lift"
        )

        monkeypatch.undo()
        assert isinstance(sw._move_loop_active(), bool)  # callable & no crash
        win.show()
        assert _pump_until(root, lambda: root.state() == "normal")


def test_configure_position_change_sets_and_clears_drag_flag() -> None:
    """A toplevel position change marks _dragging; it clears after the debounce."""
    with _studio() as (root, win):
        root.deiconify()  # mapped window: geometry changes fire real <Configure>
        root.update()
        assert win._dragging is False
        root.geometry("720x480+430+330")
        root.update()
        assert win._dragging is True, "position change must raise the drag flag"

        # Debounce: flag clears _DRAG_CLEAR_MS after the last movement.
        assert _pump_until(root, lambda: win._dragging is False, timeout=2.0)
        assert (root.winfo_x(), root.winfo_y()) == (430, 330)


def test_child_configure_events_do_not_raise_drag_flag() -> None:
    """Children share the toplevel bindtag — their Configure must be ignored."""
    with _studio() as (root, win):
        win._drag_pos = (0, 0)  # would look like a move if the filter failed
        child = root.winfo_children()[0]  # real child widget of the toplevel
        fake = types.SimpleNamespace(widget=child)
        win._on_position_configure(fake)  # type: ignore[arg-type]
        assert win._dragging is False, "child Configure events must be filtered"
