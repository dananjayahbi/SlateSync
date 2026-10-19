"""Doc 16 acceptance tests — StudioWindow on a withdrawn ``CTk`` root.

Smoke-constructs the shell around a duck-typed GL host, asserts the event
matrix (seven frozen subscriptions + round-4 ``CANVAS_LIST_UPDATED``), drives
the Start button into the injected
``export_submit`` envelope, flips the badge/zoom/preset HUD, exercises the
export-bar rules (PDF → no DPI, progress, finished → Open-in-Explorer), and
verifies bus handlers marshal worker-thread emits through ``root.after(0)``
onto the Tk thread.
"""

from __future__ import annotations

import os
import threading
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import customtkinter as ctk
import pytest
from PIL import Image

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    DOCUMENT_LOADED,
    EXPORT_FINISHED,
    EXPORT_PROGRESS,
    EXPORT_STARTED,
    PAIRING_INFO,
    EventBus,
)
from pc_agent.gui.studio_window import StudioWindow

_MATRIX_EVENTS = [
    CONNECTION_STATE,
    DOCUMENT_LOADED,
    ARTBOARD_CHANGED,
    EXPORT_STARTED,
    EXPORT_PROGRESS,
    EXPORT_FINISHED,
    PAIRING_INFO,
    CANVAS_LIST_UPDATED,
]

_GREEN, _GREY, _RED = "#2ECC71", "#9E9E9E", "#E74C3C"
_QR_FILE = Path(__file__).resolve().parent / "_qr_pairing_test.png"


class _RecordingBus(EventBus):
    """EventBus recording every ``on`` registration (matrix assertion)."""

    def __init__(self) -> None:
        super().__init__()
        self.on_calls: list[tuple[str, Callable[..., None]]] = []

    def on(self, event: str, handler: Callable[..., None]) -> None:
        self.on_calls.append((event, handler))
        super().on(event, handler)


class _FakeGLHost:
    """Duck-typed Doc 06 GLCanvasHost (doc §6 test 1: stub)."""

    def __init__(self) -> None:
        self.mounted: list[Any] = []

    def mount(self, parent_widget: Any) -> None:
        self.mounted.append(parent_widget)


class _SubmitSpy:
    """Injected ``export_submit`` capturing envelopes; returns a job id."""

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def __call__(self, job: dict) -> str:
        self.calls.append(job)
        return "job-1"


def _make_root() -> ctk.CTk:
    # Transient display contention (parallel test processes sharing the
    # interactive session) can fail a root creation once — retry before skip.
    last_error: Exception | None = None
    for _ in range(3):
        try:
            root = ctk.CTk()
            break
        except Exception as exc:  # pragma: no cover - depends on the display session
            last_error = exc
            time.sleep(0.2)
    else:  # pragma: no cover - depends on the display session
        pytest.skip(f"Tk unavailable: {last_error}")
    root.withdraw()
    root.geometry("720x480")
    return root


@contextmanager
def _studio() -> Iterator[tuple[Any, StudioWindow, _RecordingBus, _FakeGLHost, _SubmitSpy]]:
    root = _make_root()
    bus = _RecordingBus()
    gl_host = _FakeGLHost()
    submit = _SubmitSpy()
    win = StudioWindow(AppConfig(), bus, gl_host, submit)
    win.build(root)
    try:
        yield root, win, bus, gl_host, submit
    finally:
        try:
            root.destroy()
        except Exception:
            pass


def _pump_until(root: Any, condition: Callable[[], bool], timeout: float = 5.0) -> bool:
    """Drive the Tk event loop until ``condition`` holds (after(0) delivery)."""
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
# 1. Smoke construct
# ---------------------------------------------------------------------------


def test_smoke_construct_withdrawn_yields_all_components() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        assert str(root.state()) == "withdrawn"
        # HUD
        assert win._badge is not None
        assert str(win._badge.cget("text")) == "WAITING"
        assert _colour(win._badge.cget("fg_color")) == _GREY
        assert str(win._zoom_label.cget("text")) == "100%"
        assert str(win._preset_label.cget("text")) == "A4"
        assert win._qr_btn is not None
        # Center — real GL host replaced by the doc's duck-typed stub
        assert gl_host.mounted and gl_host.mounted[0] is win._viewport
        # Export bar
        assert list(win._format_combo.cget("values")) == ["PNG", "JPG", "PDF"]
        assert list(win._dpi_combo.cget("values")) == ["300", "600", "1200"]
        assert list(win._target_combo.cget("values")) == ["PC", "Tablet", "Both"]
        assert str(win._start_btn.cget("state")) == "disabled"
        assert str(win._open_btn.cget("state")) == "disabled"
        assert str(win._dpi_combo.cget("state")) == "normal"
        assert win._progress is not None
        # Menu
        assert str(root.cget("menu")) != ""
        assert win._menubar is not None


# ---------------------------------------------------------------------------
# 2. Bus subscriptions
# ---------------------------------------------------------------------------


def test_subscribes_exactly_the_event_matrix() -> None:
    bus = _RecordingBus()
    StudioWindow(AppConfig(), bus, _FakeGLHost(), _SubmitSpy())
    assert [event for event, _ in bus.on_calls] == _MATRIX_EVENTS


# ---------------------------------------------------------------------------
# 3. Start button → export envelope
# ---------------------------------------------------------------------------


def test_start_button_invokes_export_submit_with_frozen_envelope() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        bus.emit(DOCUMENT_LOADED, doc=_doc())
        assert _pump_until(root, lambda: str(win._start_btn.cget("state")) == "normal")
        assert win._canvas_id == "cv-42"
        assert str(win._zoom_label.cget("text")) == "100%"
        assert str(win._preset_label.cget("text")) == "A4"

        win._target_combo.set("Both")
        win._start_btn.invoke()

        assert len(submit.calls) == 1
        env = submit.calls[0]
        assert set(env) == {"id", "type", "action", "canvas_id", "payload", "timestamp"}
        assert env["type"] == "EXPORT_JOB"
        assert env["action"] == "START_EXPORT"
        assert env["canvas_id"] == "cv-42"
        assert set(env["payload"]) == {"format", "dpi", "target"}
        assert env["payload"]["format"] == "PNG"
        assert env["payload"]["dpi"] == 300
        assert env["payload"]["target"] == "BOTH"
        assert isinstance(env["id"], str) and env["id"]
        assert isinstance(env["timestamp"], int)
        assert win._job_id == "job-1"
        assert str(win._start_btn.cget("state")) == "disabled"
        assert win._progress.get() == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# 4. Badge flips
# ---------------------------------------------------------------------------


def test_set_connection_state_flips_badge_text_and_colour() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        win.set_connection_state(True, None)
        assert str(win._badge.cget("text")) == "CONNECTED"
        assert _colour(win._badge.cget("fg_color")) == _GREEN

        win.set_connection_state(False, None)
        assert str(win._badge.cget("text")) == "WAITING"
        assert _colour(win._badge.cget("fg_color")) == _GREY

        win.set_connection_state(False, "192.168.1.9")
        assert str(win._badge.cget("text")) == "ERROR"
        assert _colour(win._badge.cget("fg_color")) == _RED


# ---------------------------------------------------------------------------
# 5. HUD updates
# ---------------------------------------------------------------------------


def test_update_hud_clamps_zoom_and_sets_preset() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        win.update_hud(1.5, "A4")
        assert str(win._zoom_label.cget("text")) == "150%"
        assert str(win._preset_label.cget("text")) == "A4"
        assert win._last_scale == pytest.approx(1.5)

        win.update_hud(0.01, "INFINITE")  # clamped to 0.05×
        assert str(win._zoom_label.cget("text")) == "5%"

        win.update_hud(50.0, "LETTER")  # clamped to 20.0×
        assert str(win._zoom_label.cget("text")) == "2000%"
        assert str(win._preset_label.cget("text")) == "LETTER"
        assert win._last_scale == pytest.approx(20.0)


def test_bus_events_drive_the_hud_on_the_tk_thread() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        bus.emit(CONNECTION_STATE, connected=True, peer=None)
        assert _pump_until(
            root, lambda: str(win._badge.cget("text")) == "CONNECTED"
        )
        bus.emit(ARTBOARD_CHANGED, artboard={"preset": "LETTER"}, content_bounds={})
        assert _pump_until(
            root, lambda: str(win._preset_label.cget("text")) == "LETTER"
        )
        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="cv-9", preset="A5"))
        assert _pump_until(
            root, lambda: str(win._preset_label.cget("text")) == "A5"
        )
        assert win._canvas_id == "cv-9"


# ---------------------------------------------------------------------------
# 6. Export bar rules
# ---------------------------------------------------------------------------


def test_pdf_disables_dpi_combo_and_sends_null_dpi() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        win._format_combo.set("PDF")
        win._on_format_change("PDF")
        assert str(win._dpi_combo.cget("state")) == "disabled"

        bus.emit(DOCUMENT_LOADED, doc=_doc())
        assert _pump_until(root, lambda: str(win._start_btn.cget("state")) == "normal")
        win._start_btn.invoke()
        assert submit.calls[-1]["payload"] == {"format": "PDF", "dpi": None, "target": "PC"}

        win._format_combo.set("PNG")
        win._on_format_change("PNG")
        assert str(win._dpi_combo.cget("state")) == "normal"
        assert list(win._dpi_combo.cget("values")) == ["300", "600", "1200"]


def test_export_progress_started_and_finished_drive_bar_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        bus.emit(DOCUMENT_LOADED, doc=_doc())
        assert _pump_until(root, lambda: str(win._start_btn.cget("state")) == "normal")

        bus.emit(EXPORT_STARTED, job_id="job-1")
        assert _pump_until(root, lambda: str(win._start_btn.cget("state")) == "disabled")
        assert win._progress.get() == pytest.approx(0.0)

        bus.emit(EXPORT_PROGRESS, job_id="job-1", percent=42)
        assert _pump_until(root, lambda: win._progress.get() == pytest.approx(0.42, abs=1e-6))

        out_path = str(Path(__file__).resolve().parent / "exports" / "job1.png")
        bus.emit(EXPORT_FINISHED, job_id="job-1", percent=100.0, path=out_path, ok=True)
        assert _pump_until(root, lambda: str(win._open_btn.cget("state")) == "normal")
        assert str(win._start_btn.cget("state")) == "normal"
        assert win._last_path == out_path

        opened: list[str] = []
        monkeypatch.setattr(os, "startfile", opened.append, raising=False)
        win._open_btn.invoke()
        assert opened == [out_path]

        # ok=False leaves Open disabled even with a path present
        win._open_btn.configure(state="disabled")
        bus.emit(EXPORT_FINISHED, job_id="job-2", percent=100.0, path=out_path, ok=False)
        assert _pump_until(root, lambda: str(win._open_btn.cget("state")) == "disabled")


# ---------------------------------------------------------------------------
# 7. after(0) marshalling from a worker thread
# ---------------------------------------------------------------------------


def test_worker_thread_emit_marshals_through_after_zero() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        scheduled: list[tuple[int, Callable[..., None]]] = []
        original_after = root.after

        def spy_after(ms: int, func: Callable[..., None] | None = None, *args):
            scheduled.append((ms, func))
            return original_after(ms, func, *args)

        root.after = spy_after  # type: ignore[method-assign]

        main_ident = threading.get_ident()
        worker_id: list[int] = []

        def worker() -> None:
            worker_id.append(threading.get_ident())
            bus.emit(CONNECTION_STATE, connected=True, peer=None)

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join(timeout=2)
        assert not thread.is_alive(), "the handler must not block on Tk"
        assert worker_id and worker_id[0] != main_ident

        # Nothing was pumped yet — no widget write may have happened off-thread,
        # and the worker never touched Tk directly: the request is queued for
        # the Tk-thread poller, which re-posts it through root.after(0, …).
        assert str(win._badge.cget("text")) == "WAITING"
        assert not any(
            func == win.set_connection_state for _, func in scheduled
        ), "the worker thread must not call root.after itself"

        # Eventual consistency once the Tk thread pumps
        assert _pump_until(root, lambda: str(win._badge.cget("text")) == "CONNECTED")
        assert any(
            ms == 0 and func == win.set_connection_state for ms, func in scheduled
        ), "the handler must marshal via after(0, set_connection_state, …)"


def test_on_live_activity_throttles_to_one_raise_per_second() -> None:
    with _studio() as (root, win, bus, gl_host, submit):
        scheduled: list[tuple[int, Callable[..., None]]] = []
        original_after = win.after

        def spy_after(ms: int, func: Callable[..., None] | None = None, *args):
            scheduled.append((ms, func))
            return original_after(ms, func, *args)

        win.after = spy_after  # type: ignore[method-assign]

        win.on_live_activity()
        win.on_live_activity()  # within 1 s → suppressed
        raises = [1 for _, func in scheduled if func == win._raise_window]
        assert len(raises) == 1, "two rapid calls must schedule exactly one raise"

        _flush(root)  # let the scheduled raise run on the Tk thread


# ---------------------------------------------------------------------------
# 8. QR dialog
# ---------------------------------------------------------------------------


def test_qr_dialog_renders_pairing_info_and_refreshes_while_open() -> None:
    _QR_FILE.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (120, 120), "white").save(_QR_FILE)
    try:
        with _studio() as (root, win, bus, gl_host, submit):
            win.open_qr_dialog()  # before PAIRING_INFO arrives
            assert win._qr_dialog is not None and win._qr_dialog.winfo_exists()
            assert "Waiting for pairing info" in str(win._qr_image_label.cget("text"))

            bus.emit(
                PAIRING_INFO,
                ipv4="192.168.1.50",
                port=50606,
                token="tok-1",
                qr_png_path=str(_QR_FILE),
            )
            assert _pump_until(
                root,
                lambda: str(win._qr_ip_label.cget("text")) == "192.168.1.50:50606",
            )
            assert str(win._qr_token_label.cget("text")) == "tok-1"
            assert win._qr_image_label.cget("image") is not None
            assert win._qr_image is not None

            # Re-render while the dialog is open (§5.7)
            bus.emit(
                PAIRING_INFO,
                ipv4="192.168.1.50",
                port=50606,
                token="tok-2",
                qr_png_path=str(_QR_FILE),
            )
            assert _pump_until(
                root, lambda: str(win._qr_token_label.cget("text")) == "tok-2"
            )

            win._close_qr_dialog()
            assert win._qr_dialog is None
    finally:
        try:
            _QR_FILE.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# 9. File → Open synced canvas… (Doc 02 §8.3 flow 3)
# ---------------------------------------------------------------------------


def _file_menu(win: StudioWindow, root: Any) -> Any:
    menubar = win._menubar
    for index in range(menubar.index("end") + 1):
        if (
            menubar.type(index) == "cascade"
            and str(menubar.entrycget(index, "label")) == "File"
        ):
            return root.nametowidget(menubar.entrycget(index, "menu"))
    raise AssertionError("File cascade not found in the menu bar")


def _menu_labels(menu: Any) -> list[str]:
    labels = []
    for index in range(menu.index("end") + 1):
        if menu.type(index) == "command":
            labels.append(str(menu.entrycget(index, "label")))
    return labels


def test_menu_splits_synced_canvas_from_local_file() -> None:
    with _studio() as (root, win, _bus, _gl, _submit):
        labels = _menu_labels(_file_menu(win, root))
        assert "Open synced canvas…" in labels
        assert "Open local file…" in labels
        assert "Open…" not in labels
        assert "New…" in labels and "Save" in labels


def test_open_synced_canvas_dialog_lists_rows_and_requests_selection() -> None:
    rows = [
        {"id": "c-1", "title": "Control Systems 04", "preset": "A4",
         "background": "RULED", "updated_at": 1760763600},
        {"id": "c-2", "title": "Scribbles", "preset": "INFINITE",
         "background": "DOT_GRID", "updated_at": 1760760000},
    ]
    requested: list[str] = []
    root = _make_root()
    bus = _RecordingBus()
    win = StudioWindow(
        AppConfig(), bus, _FakeGLHost(), _SubmitSpy(), open_request=requested.append
    )
    win.build(root)
    try:
        # The cache is fed through the event-matrix subscription + after(0).
        bus.emit(CANVAS_LIST_UPDATED, canvases=rows)
        assert _pump_until(root, lambda: len(win._canvases) == 2)
        assert win._canvases[0]["id"] == "c-1"

        win._menu_open_synced()
        assert win._sync_dialog is not None and win._sync_dialog.winfo_exists()
        assert win._sync_listbox is not None
        expected = [
            time.strftime("%Y-%m-%d %H:%M", time.localtime(row["updated_at"]))
            for row in rows
        ]
        labels = list(win._sync_listbox.get(0, "end"))
        assert labels == [
            f"Control Systems 04 · A4 · {expected[0]}",
            f"Scribbles · INFINITE · {expected[1]}",
        ]

        # No selection → no request; then select row 2 → request carries its id.
        win._confirm_sync_open()
        assert requested == []
        win._sync_listbox.selection_set(1)
        win._confirm_sync_open()
        assert requested == ["c-2"]
        assert win._sync_dialog is None

        # The dialog destroy path (Cancel) is symmetric.
        win._menu_open_synced()
        assert win._sync_dialog is not None
        win._close_sync_dialog()
        assert win._sync_dialog is None and win._sync_listbox is None
    finally:
        try:
            root.destroy()
        except Exception:
            pass


def test_open_synced_canvas_empty_list_shows_connect_hint(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with _studio() as (root, win, bus, _gl, _submit):
        shown: list[tuple[str, str]] = []

        def fake_showinfo(title: str, message: str, **_kwargs: Any) -> None:
            shown.append((title, message))

        monkeypatch.setattr(
            "pc_agent.gui.studio_window.messagebox.showinfo", fake_showinfo
        )
        win._menu_open_synced()
        assert shown == [
            ("Open synced canvas", "Connect a tablet to browse its canvases")
        ]
        assert win._sync_dialog is None
        assert bus.on_calls  # sanity: the recording bus is wired


def test_open_request_unbound_is_logged_not_crashing(
    caplog: pytest.LogCaptureFixture,
) -> None:
    with _studio() as (root, win, _bus, _gl, _submit):
        win._canvases = [{"id": "c-9", "title": "T", "preset": "A5", "updated_at": 1}]
        with caplog.at_level("WARNING", logger="pc_agent.gui.studio_window"):
            win._menu_open_synced()  # no open_request wired → warn, no dialog
        assert win._sync_dialog is None
        assert any("open_request" in r.getMessage() for r in caplog.records)
