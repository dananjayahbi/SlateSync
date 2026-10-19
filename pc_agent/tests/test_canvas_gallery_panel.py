"""Issue 03-PC acceptance tests — docked left canvas gallery strip.

Builds a real ``StudioWindow`` around a duck-typed GL host, feeds the frozen
``CANVAS_LIST_UPDATED`` payload (``{canvases, devices}`` — Doc 02 §9) through
the recording bus, and asserts:

* rows render from a bus emit (``title · preset · updated`` + source tag),
* a row click forwards the canvas id to the injected ``open_request``,
* the strip is hidden while unpaired or empty (Issue 02 spirit),
* the currently-open canvas row is highlighted (DOCUMENT_LOADED state),
* worker-thread emits marshal through ``after(0)`` onto the Tk thread.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any

import customtkinter as ctk
import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    DOCUMENT_LOADED,
    EventBus,
)
from pc_agent.gui.canvas_gallery_panel import (
    _ROW_BG,
    _ROW_BG_CURRENT,
    CanvasGalleryPanel,
    format_updated,
    row_label,
)
from pc_agent.gui.studio_window import StudioWindow

_NOW = int(time.time())
_ROWS = [
    {
        "id": "c-1",
        "title": "Control Systems 04",
        "preset": "A4",
        "background": "RULED",
        "updated_at": _NOW - 120,  # recent → relative stamp
        "source": "hub",
    },
    {
        "id": "c-2",
        "title": "Scribbles",
        "preset": "INFINITE",
        "background": "DOT_GRID",
        "updated_at": 1760760000,  # old → absolute stamp
    },
]


class _RecordingBus(EventBus):
    """EventBus recording every ``on`` registration (matrix assertion)."""

    def __init__(self) -> None:
        super().__init__()
        self.on_calls: list[tuple[str, Callable[..., None]]] = []

    def on(self, event: str, handler: Callable[..., None]) -> None:
        self.on_calls.append((event, handler))
        super().on(event, handler)


class _FakeGLHost:
    def __init__(self) -> None:
        self.mounted: list[Any] = []

    def mount(self, parent_widget: Any) -> None:
        self.mounted.append(parent_widget)


class _SubmitSpy:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, job: dict) -> str:
        self.calls.append(job)
        return "job-1"


def _make_root() -> ctk.CTk:
    last_error: Exception | None = None
    for _ in range(3):
        try:
            root = ctk.CTk()
            break
        except Exception as exc:  # pragma: no cover - display contention
            last_error = exc
            time.sleep(0.2)
    else:  # pragma: no cover - depends on the display session
        pytest.skip(f"Tk unavailable: {last_error}")
    root.withdraw()
    root.geometry("1280x800")
    return root


@contextmanager
def _studio(
    open_request: Callable[[str], None] | None = None,
) -> Iterator[tuple[Any, StudioWindow, _RecordingBus]]:
    root = _make_root()
    bus = _RecordingBus()
    win = StudioWindow(
        AppConfig(), bus, _FakeGLHost(), _SubmitSpy(), open_request=open_request
    )
    win.build(root)
    try:
        yield root, win, bus
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
        time.sleep(0.01)
    return condition()


def _flush(root: Any, rounds: int = 5) -> None:
    for _ in range(rounds):
        root.update()
        time.sleep(0.02)


def _colour(value: Any) -> str:
    return value[0] if isinstance(value, (tuple, list)) else str(value)


def _doc(canvas_id: str = "cv-42", preset: str = "A4") -> dict:
    return {"canvas_id": canvas_id, "title": "T", "artboard": {"preset": preset}}


# ---------------------------------------------------------------------------
# 1. Pure helpers
# ---------------------------------------------------------------------------


def test_format_updated_buckets_relative_and_absolute_stamps() -> None:
    now = 1_800_000_000.0
    assert format_updated(now - 10, now) == "just now"
    assert format_updated(now - 5 * 60, now) == "5m ago"
    assert format_updated(now - 3 * 3600, now) == "3h ago"
    assert format_updated(now - 2 * 86400, now) == "2d ago"
    old = now - 40 * 86400
    assert format_updated(old, now) == time.strftime("%Y-%m-%d %H:%M", time.localtime(old))
    assert format_updated("nonsense", now) == "?"
    assert format_updated(None, now) == "?"


def test_row_label_composes_title_preset_and_stamp() -> None:
    now = int(time.time())
    row = {"title": "Notes", "preset": "A5", "updated_at": now - 120}
    assert row_label(row) == "Notes · A5 · 2m ago"
    assert row_label({"title": None, "preset": None, "updated_at": None}) == (
        "Untitled · ? · ?"
    )


# ---------------------------------------------------------------------------
# 2. Rendering rows from a bus emit
# ---------------------------------------------------------------------------


def test_gallery_renders_rows_from_bus_emit() -> None:
    with _studio() as (root, win, bus):
        gallery = win._gallery
        assert isinstance(gallery, CanvasGalleryPanel)
        # Unpaired + empty at build → hidden entirely.
        assert not gallery.visible
        assert gallery.frame.winfo_manager() == ""

        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(gallery.row_ids) == 2)
        assert gallery.visible
        assert gallery.frame.winfo_manager() == "grid"
        assert gallery.row_ids == ["c-1", "c-2"]

        first = gallery.row_for("c-1")
        assert first is not None
        label = str(first.cget("text"))
        assert label.startswith("Control Systems 04 · A4 · ")
        assert "m ago" in label  # recent → relative stamp
        # Small source tag beside the row (present only when source is set).
        tags = [
            child
            for child in first.master.winfo_children()
            if child is not first
        ]
        assert len(tags) == 1 and str(tags[0].cget("text")) == "hub"

        second = gallery.row_for("c-2")
        assert second is not None
        assert str(second.cget("text")).startswith("Scribbles · INFINITE · ")
        assert not [
            child for child in second.master.winfo_children() if child is not second
        ]


def test_gallery_layout_mounts_left_of_the_viewport() -> None:
    with _studio() as (root, win, bus):
        # Viewport keeps center row/col weights so it still fills the window.
        assert win._viewport.grid_info()["column"] == 1
        assert root.grid_columnconfigure(1)["weight"] == 1
        assert root.grid_rowconfigure(1)["weight"] == 1
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: win._gallery.visible)
        assert win._gallery.frame.grid_info()["column"] == 0
        assert win._gallery.frame.grid_info()["row"] == 1


# ---------------------------------------------------------------------------
# 3. Row activation → open_request (Doc 02 §8.3 flow 3)
# ---------------------------------------------------------------------------


def test_row_click_calls_open_request_with_id() -> None:
    requested: list[str] = []
    with _studio(open_request=requested.append) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 2)

        win._gallery.row_for("c-2").invoke()
        assert requested == ["c-2"]

        # Double-click (two releases within the dedupe window) → one request.
        win._gallery.row_for("c-1").invoke()
        win._gallery.row_for("c-1").invoke()
        assert requested == ["c-2", "c-1"]


def test_source_tag_click_also_requests_open() -> None:
    requested: list[str] = []
    with _studio(open_request=requested.append) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 2)
        root.deiconify()  # pointer bindings need a viewable window
        _flush(root)
        first = win._gallery.row_for("c-1")
        tag = next(c for c in first.master.winfo_children() if c is not first)
        # CTkLabel.bind() registers on the inner label/canvas — real clicks
        # land there, so synthesize the event on the same target.
        tag._label.event_generate("<Button-1>", x=1, y=1)
        _flush(root)
        assert requested == ["c-1"]


def test_open_request_unbound_logs_warning_not_crash(
    caplog: pytest.LogCaptureFixture,
) -> None:
    root = _make_root()
    try:
        panel = CanvasGalleryPanel(root, open_request=None)
        with caplog.at_level("WARNING"):
            panel.activate("c-x")
        assert any("open_request" in r.getMessage() for r in caplog.records)
    finally:
        try:
            root.destroy()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# 4. Hidden while unpaired or empty (Issue 02 spirit)
# ---------------------------------------------------------------------------


def test_gallery_hidden_when_no_devices_or_empty_list() -> None:
    with _studio() as (root, win, bus):
        gallery = win._gallery
        # Devices but no canvases → still hidden.
        bus.emit(CANVAS_LIST_UPDATED, canvases=[], devices=1)
        assert _pump_until(root, lambda: win._devices == 1)
        _flush(root)
        assert not gallery.visible
        assert gallery.frame.winfo_manager() == ""

        # Canvases but no devices (unpaired) → hidden.
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=0)
        assert _pump_until(root, lambda: len(win._canvases) == 2)
        _flush(root)
        assert not gallery.visible
        assert gallery.frame.winfo_manager() == ""

        # Paired + rows → shown.
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: gallery.visible)
        assert gallery.frame.winfo_manager() == "grid"

        # The CONNECTION_STATE connected path counts as paired too.
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=0)
        assert _pump_until(root, lambda: win._devices == 0)
        _flush(root)
        assert not gallery.visible
        bus.emit(CONNECTION_STATE, connected=True, peer=None)
        assert _pump_until(root, lambda: gallery.visible)


# ---------------------------------------------------------------------------
# 5. Highlight tracks the currently-open canvas
# ---------------------------------------------------------------------------


def test_highlight_follows_document_loaded_and_artboard_state() -> None:
    with _studio() as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 2)
        gallery = win._gallery
        # Nothing open yet → both rows neutral.
        assert _colour(gallery.row_for("c-1").cget("fg_color")) == _ROW_BG

        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-2"))
        assert _pump_until(
            root,
            lambda: _colour(gallery.row_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(gallery.row_for("c-1").cget("fg_color")) == _ROW_BG

        # Switch canvases → highlight follows.
        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-1"))
        assert _pump_until(
            root,
            lambda: _colour(gallery.row_for("c-1").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(gallery.row_for("c-2").cget("fg_color")) == _ROW_BG

        # Artboard changes keep the same highlight (state re-asserted).
        bus.emit(ARTBOARD_CHANGED, artboard={"preset": "LETTER"}, content_bounds={})
        assert _pump_until(
            root,
            lambda: str(win._preset_label.cget("text")) == "LETTER",
        )
        assert _colour(gallery.row_for("c-1").cget("fg_color")) == _ROW_BG_CURRENT


def test_set_rows_re_applies_highlight_for_current_canvas() -> None:
    with _studio() as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 2)
        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-2"))
        assert _pump_until(
            root,
            lambda: _colour(win._gallery.row_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        # A refreshed list rebuilds the rows → highlight must survive.
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(
            root,
            lambda: _colour(win._gallery.row_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(win._gallery.row_for("c-1").cget("fg_color")) == _ROW_BG


# ---------------------------------------------------------------------------
# 6. Worker-thread marshalling (§5.8 — no widget write off the Tk thread)
# ---------------------------------------------------------------------------


def test_worker_thread_emit_marshals_onto_tk_thread() -> None:
    with _studio() as (root, win, bus):
        scheduled: list[tuple[int, Callable[..., None]]] = []
        original_after = root.after

        def spy_after(ms: int, func: Callable[..., None] | None = None, *args):
            scheduled.append((ms, func))
            return original_after(ms, func, *args)

        root.after = spy_after  # type: ignore[method-assign]
        gallery = win._gallery
        main_ident = threading.get_ident()

        def worker() -> None:
            assert threading.get_ident() != main_ident
            bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join(timeout=2)
        assert not thread.is_alive(), "the handler must not block on Tk"

        # Nothing was pumped: no widget write may have happened off-thread.
        assert gallery.row_ids == []
        assert not gallery.visible
        assert not any(
            func == win._apply_canvas_list for _, func in scheduled
        ), "the worker thread must not call root.after itself"

        # Eventual consistency once the Tk thread pumps.
        assert _pump_until(root, lambda: len(gallery.row_ids) == 2)
        assert gallery.visible
        assert any(
            ms == 0 and func == win._apply_canvas_list for ms, func in scheduled
        ), "the handler must marshal via after(0, _apply_canvas_list, …)"


# ---------------------------------------------------------------------------
# 7. Collapse toggle
# ---------------------------------------------------------------------------


def test_collapse_toggle_hides_and_restores_row_list() -> None:
    with _studio() as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 2)
        gallery = win._gallery
        assert not gallery.collapsed

        gallery.toggle_collapse()
        assert gallery.collapsed
        # CTkScrollableFrame delegates pack/pack_forget to its parent frame.
        assert gallery._list._parent_frame.winfo_manager() == ""  # list away
        assert str(gallery._toggle_btn.cget("text")) == "+"

        gallery.toggle_collapse()
        assert not gallery.collapsed
        assert gallery._list._parent_frame.winfo_manager() == "pack"
        assert str(gallery._toggle_btn.cget("text")) == "–"


# ---------------------------------------------------------------------------
# 8. Rows without ids are skipped (defensive against bad hub payloads)
# ---------------------------------------------------------------------------


def test_rows_without_id_are_skipped(caplog: pytest.LogCaptureFixture) -> None:
    with _studio() as (root, win, bus):
        rows = [{"title": "orphan", "preset": "A4"}, _ROWS[0]]
        with caplog.at_level("DEBUG"):
            bus.emit(CANVAS_LIST_UPDATED, canvases=rows, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.row_ids) == 1)
        assert win._gallery.row_ids == ["c-1"]
