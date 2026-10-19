"""Issue 07-PC acceptance tests — thumbnail card gallery strip.

Builds a real ``StudioWindow`` around a duck-typed GL host, feeds the frozen
``CANVAS_LIST_UPDATED`` payload (``{canvases, devices}`` — Doc 02 §9) through
the recording bus, and asserts:

* rows render as a 2-column **card grid** (rounded thumb box + overlaid
  preset badge chip + title + updated-below + source tag — Doc 02 §10.6,
  badge = UI overlay, never baked into the image),
* a card click forwards the canvas id to the injected ``open_request``
  (double activation deduped),
* the strip is hidden while unpaired or empty (Issue 02 spirit),
* the currently-open canvas card is highlighted (DOCUMENT_LOADED state),
* worker-thread emits marshal through ``after(0)`` onto the Tk thread,
* the §10.6 pipeline: injectable fake ``thumbnail_fn``, placeholder → image
  swap marshalled from the 2-worker pool, missing/stale regeneration,
  ``updated_at`` cache invalidation, LRU cap, and the lazy-import default
  renderer degrading to the gray placeholder when its module is absent.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import sys
import tempfile
import threading
import time
import zipfile
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
    EventBus,
)
from pc_agent.gui.canvas_gallery_panel import (
    _LRU_CAP,
    _ROW_BG,
    _ROW_BG_CURRENT,
    _THUMB_BG,
    CanvasGalleryPanel,
    badge_bg,
    badge_text,
    default_thumbnail_fn,
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

# Noop default: studio-driven tests never render or touch disk; only the
# pipeline tests opt into a fake renderer + their own tmp thumbs dir.
_DEFAULT_THUMBS = Path(tempfile.gettempdir()) / f"slatesync-gallery-{os.getpid()}"


def _noop_thumbnail(row: dict, out_path: Path, size: int) -> None:
    """Default fake renderer: no PNG, no disk — the placeholder stays."""
    return None


class _ThumbSpy:
    """Fake ``thumbnail_fn``: solid-colour 192² PNG + call log (+ sha)."""

    def __init__(self, color: tuple[int, int, int] = (200, 40, 40)) -> None:
        self.color = color
        self.calls: list[tuple[str, int, Path, int]] = []
        self.shas: dict[str, str] = {}
        self._lock = threading.Lock()

    def __call__(self, row: dict, out_path: Path, size: int) -> Path:
        try:
            updated = int(row.get("updated_at"))
        except (TypeError, ValueError):
            updated = -1
        with self._lock:
            self.calls.append((str(row.get("id")), updated, Path(out_path), size))
        out = Path(out_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (size, size), self.color).save(out, "PNG")
        self.shas[str(row.get("id"))] = hashlib.sha256(out.read_bytes()).hexdigest()
        return out


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
    thumbnail_fn: Callable[..., Any] | None = _noop_thumbnail,
    thumbs_dir: Path | None = None,
) -> Iterator[tuple[Any, StudioWindow, _RecordingBus]]:
    """Real StudioWindow; gallery renders default to the noop fake.

    ``thumbnail_fn=None`` deliberately selects the panel's lazy-import
    default renderer path (tests that exercise it monkeypatch the import).
    """
    root = _make_root()
    bus = _RecordingBus()
    win = StudioWindow(
        AppConfig(),
        bus,
        _FakeGLHost(),
        _SubmitSpy(),
        open_request=open_request,
        thumbnail_fn=thumbnail_fn,
        thumbs_dir=thumbs_dir if thumbs_dir is not None else _DEFAULT_THUMBS,
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


def _state(win: Any, canvas_id: str) -> dict:
    state = win._gallery.card_state(canvas_id)
    assert state is not None, f"missing gallery card for {canvas_id}"
    return state


def _image_pixel(state: dict, xy: tuple[int, int] = (40, 40)) -> tuple[int, ...]:
    assert state["image"] is not None, "no thumbnail image on the card"
    return state["image"]._dark_image.getpixel(xy)


def _close(pixel: tuple, color: tuple[int, int, int], tol: int = 4) -> bool:
    return all(abs(int(ch) - want) <= tol for ch, want in zip(pixel, color))


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


def test_badge_text_and_colour_per_preset() -> None:
    assert badge_text("A5") == "A5"
    assert badge_text("a4") == "A4"
    assert badge_text("Letter") == "LETTER"
    assert badge_text("INFINITE") == "INFINITE"
    assert badge_text(None) == "?"
    assert badge_text("") == "?"
    # Known presets get distinct chip colours; unknown ones stay neutral.
    colours = {badge_bg(p) for p in ("A5", "A4", "LETTER", "INFINITE")}
    assert len(colours) == 4
    assert badge_bg("mystery") == badge_bg("?") == badge_bg(None)


# ---------------------------------------------------------------------------
# 2. Rendering thumbnail cards from a bus emit
# ---------------------------------------------------------------------------


def test_gallery_renders_cards_from_bus_emit() -> None:
    with _studio() as (root, win, bus):
        gallery = win._gallery
        assert isinstance(gallery, CanvasGalleryPanel)
        # Unpaired + empty at build → hidden entirely.
        assert not gallery.visible
        assert gallery.frame.winfo_manager() == ""

        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(gallery.card_ids) == 2)
        assert gallery.visible
        assert gallery.frame.winfo_manager() == "grid"
        assert gallery.card_ids == ["c-1", "c-2"]
        assert gallery.row_ids == gallery.card_ids  # issue-03 back-compat alias

        # Two cards side by side in the scrollable 2-column grid.
        assert isinstance(gallery._list, ctk.CTkScrollableFrame)
        first, second = gallery.card_for("c-1"), gallery.card_for("c-2")
        assert first is not None and second is not None
        assert first.grid_info()["row"] == second.grid_info()["row"] == 0
        assert (first.grid_info()["column"], second.grid_info()["column"]) == (0, 1)

        # Card contents: title, updated-below, source tag, preset badge.
        state1 = _state(win, "c-1")
        assert str(state1["title"].cget("text")) == "Control Systems 04"
        assert "m ago" in str(state1["updated"].cget("text"))  # relative stamp
        assert state1["source"] is not None
        assert str(state1["source"].cget("text")) == "hub"
        assert str(state1["badge"].cget("text")) == "A4"
        state2 = _state(win, "c-2")
        assert str(state2["title"].cget("text")) == "Scribbles"
        assert state2["source"] is None
        assert str(state2["badge"].cget("text")) == "INFINITE"

        # Noop renderer → neutral gray placeholder box, no image yet.
        assert _colour(state1["thumb_box"].cget("fg_color")) == _THUMB_BG
        assert state1["image"] is None
        assert state1["image_label"].cget("image") is None


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


def test_cards_for_every_preset_show_matching_badge(tmp_path: Path) -> None:
    rows = [
        {"id": "p-a5", "title": "A5", "preset": "A5", "updated_at": _NOW - 60},
        {"id": "p-a4", "title": "A4", "preset": "A4", "updated_at": _NOW - 60},
        {"id": "p-lt", "title": "LT", "preset": "LETTER", "updated_at": _NOW - 60},
        {"id": "p-inf", "title": "Inf", "preset": "INFINITE", "updated_at": _NOW - 60},
    ]
    with _studio(thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=rows, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 4)
        ids = ("p-a5", "p-a4", "p-lt", "p-inf")
        badges = {cid: str(_state(win, cid)["badge"].cget("text")) for cid in ids}
        assert badges == {
            "p-a5": "A5",
            "p-a4": "A4",
            "p-lt": "LETTER",
            "p-inf": "INFINITE",
        }
        chips = {_colour(_state(win, cid)["badge"].cget("fg_color")) for cid in ids}
        assert len(chips) == 4


# ---------------------------------------------------------------------------
# 3. Card activation → open_request (Doc 02 §8.3 flow 3)
# ---------------------------------------------------------------------------


def test_card_click_calls_open_request_with_id() -> None:
    requested: list[str] = []
    with _studio(open_request=requested.append) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
        root.deiconify()  # pointer bindings need a viewable window
        _flush(root)

        # Real click on the card's thumbnail area.  CTkLabel.bind registers
        # on the inner tk.Label too — synthesize the event there (this is
        # where real pointer hits land).
        _state(win, "c-2")["image_label"]._label.event_generate("<Button-1>", x=5, y=5)
        _flush(root)
        assert requested == ["c-2"]

        # Double click (two releases within the dedupe window) → one request.
        label1 = _state(win, "c-1")["image_label"]._label
        for _ in range(2):
            label1.event_generate("<Button-1>", x=5, y=5)
        _flush(root)
        assert requested == ["c-2", "c-1"]


def test_activate_dedupes_double_click() -> None:
    requested: list[str] = []
    with _studio(open_request=requested.append) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
        gallery = win._gallery
        gallery.activate("c-1")
        gallery.activate("c-1")  # second release of the same double-click
        gallery.activate("c-2")  # different id → always allowed
        assert requested == ["c-1", "c-2"]


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
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
        gallery = win._gallery
        # Nothing open yet → both cards neutral.
        assert _colour(gallery.card_for("c-1").cget("fg_color")) == _ROW_BG

        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-2"))
        assert _pump_until(
            root,
            lambda: _colour(gallery.card_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(gallery.card_for("c-1").cget("fg_color")) == _ROW_BG

        # Switch canvases → highlight follows.
        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-1"))
        assert _pump_until(
            root,
            lambda: _colour(gallery.card_for("c-1").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(gallery.card_for("c-2").cget("fg_color")) == _ROW_BG

        # Artboard changes keep the same highlight (state re-asserted).
        bus.emit(ARTBOARD_CHANGED, artboard={"preset": "LETTER"}, content_bounds={})
        assert _pump_until(
            root,
            lambda: str(win._preset_label.cget("text")) == "LETTER",
        )
        assert _colour(gallery.card_for("c-1").cget("fg_color")) == _ROW_BG_CURRENT


def test_set_rows_re_applies_highlight_for_current_canvas() -> None:
    with _studio() as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
        bus.emit(DOCUMENT_LOADED, doc=_doc(canvas_id="c-2"))
        assert _pump_until(
            root,
            lambda: _colour(win._gallery.card_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        # A refreshed list rebuilds the cards → highlight must survive.
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(
            root,
            lambda: _colour(win._gallery.card_for("c-2").cget("fg_color"))
            == _ROW_BG_CURRENT,
        )
        assert _colour(win._gallery.card_for("c-1").cget("fg_color")) == _ROW_BG


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
        assert gallery.card_ids == []
        assert not gallery.visible
        assert not any(
            func == win._apply_canvas_list for _, func in scheduled
        ), "the worker thread must not call root.after itself"

        # Eventual consistency once the Tk thread pumps.
        assert _pump_until(root, lambda: len(gallery.card_ids) == 2)
        assert gallery.visible
        assert any(
            ms == 0 and func == win._apply_canvas_list for ms, func in scheduled
        ), "the handler must marshal via after(0, _apply_canvas_list, …)"


# ---------------------------------------------------------------------------
# 7. Collapse toggle
# ---------------------------------------------------------------------------


def test_collapse_toggle_hides_and_restores_card_list() -> None:
    with _studio() as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
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
# 8. Cards without ids are skipped (defensive against bad hub payloads)
# ---------------------------------------------------------------------------


def test_cards_without_id_are_skipped(caplog: pytest.LogCaptureFixture) -> None:
    with _studio() as (root, win, bus):
        rows = [{"title": "orphan", "preset": "A4"}, _ROWS[0]]
        with caplog.at_level("DEBUG"):
            bus.emit(CANVAS_LIST_UPDATED, canvases=rows, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 1)
        assert win._gallery.card_ids == ["c-1"]


# ---------------------------------------------------------------------------
# 9. Doc 02 §10.6 thumbnail pipeline (fake renderer, tmp thumbs dir)
# ---------------------------------------------------------------------------


def test_missing_thumb_renders_and_swaps_placeholder_for_image(
    tmp_path: Path,
) -> None:
    spy = _ThumbSpy(color=(220, 30, 90))
    with _studio(thumbnail_fn=spy, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)

        # Placeholder → image swap once the pool completion is marshalled
        # back (the exact pre-swap state is asserted in the gated test below).
        assert _pump_until(
            root,
            lambda: _state(win, "c-1")["image"] is not None
            and _state(win, "c-2")["image"] is not None,
        )
        assert _close(_image_pixel(_state(win, "c-1")), (220, 30, 90))

        # Exactly one render per missing thumb, at the §10.6 contract size.
        assert len(spy.calls) == 2
        by_id = {cid: (updated, path, size) for cid, updated, path, size in spy.calls}
        assert sorted(by_id) == ["c-1", "c-2"]
        updated, path, size = by_id["c-1"]
        assert updated == _ROWS[0]["updated_at"]
        assert path == tmp_path / "c-1.png"
        assert size == 192
        assert path.exists()


def test_fresh_thumb_loads_from_disk_without_rerender(tmp_path: Path) -> None:
    fresh = tmp_path / "c-1.png"
    Image.new("RGB", (192, 192), (10, 90, 200)).save(fresh, "PNG")
    os.utime(fresh, (_NOW - 30, _NOW - 30))  # newer than updated_at → fresh
    spy = _ThumbSpy()
    with _studio(thumbnail_fn=spy, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: _state(win, "c-1")["image"] is not None)
        assert _close(_image_pixel(_state(win, "c-1")), (10, 90, 200))
        # c-1 never went to the pool; only the missing c-2 did.
        rendered = {cid for cid, *_ in spy.calls}
        assert "c-1" not in rendered and rendered <= {"c-2"}


def test_stale_thumb_regenerates(tmp_path: Path) -> None:
    stale = tmp_path / "c-1.png"
    Image.new("RGB", (192, 192), (10, 90, 200)).save(stale, "PNG")
    old = _ROWS[0]["updated_at"] - 3600  # older than the row → stale
    os.utime(stale, (old, old))
    spy = _ThumbSpy(color=(240, 160, 20))
    with _studio(thumbnail_fn=spy, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: _state(win, "c-1")["image"] is not None)
        # Regenerated: the swap now shows the fresh render's colour.
        assert _close(_image_pixel(_state(win, "c-1")), (240, 160, 20))
        assert [cid for cid, *_ in spy.calls].count("c-1") == 1
        # The rewritten file is fresh again → no render loop on the next list.
        assert stale.stat().st_mtime + 1 >= _ROWS[0]["updated_at"]


def test_updated_at_change_invalidates_cache_and_rerenders(tmp_path: Path) -> None:
    spy = _ThumbSpy(color=(60, 60, 240))
    with _studio(thumbnail_fn=spy, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=[dict(_ROWS[0])], devices=1)
        assert _pump_until(root, lambda: _state(win, "c-1")["image"] is not None)
        gallery = win._gallery
        image_v1 = _state(win, "c-1")["image"]
        assert ("c-1", _ROWS[0]["updated_at"]) in gallery._image_cache

        bumped = dict(_ROWS[0], updated_at=_ROWS[0]["updated_at"] + 600)
        spy.color = (250, 220, 40)
        bus.emit(CANVAS_LIST_UPDATED, canvases=[bumped], devices=1)
        assert _pump_until(root, lambda: len(gallery.card_ids) == 1)
        # The old key is pruned synchronously with the rebuild…
        assert ("c-1", _ROWS[0]["updated_at"]) not in gallery._image_cache
        # …and the bumped row re-renders (the old mtime is stale now).
        assert _pump_until(
            root,
            lambda: _state(win, "c-1")["image"] is not None
            and _state(win, "c-1")["image"] is not image_v1,
        )
        assert _close(_image_pixel(_state(win, "c-1")), (250, 220, 40))
        assert ("c-1", bumped["updated_at"]) in gallery._image_cache
        assert len(spy.calls) == 2


def test_badge_chip_overlaid_on_thumbnail_not_baked(tmp_path: Path) -> None:
    spy = _ThumbSpy(color=(30, 120, 60))
    with _studio(thumbnail_fn=spy, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=[dict(_ROWS[0])], devices=1)
        assert _pump_until(root, lambda: _state(win, "c-1")["image"] is not None)
        state = _state(win, "c-1")

        # The badge is a separate chip widget gridded OVER the image box…
        assert state["badge"].winfo_manager() == "grid"
        assert state["badge"].master is state["thumb_box"]
        assert state["image_label"].master is state["thumb_box"]
        assert str(state["badge"].cget("text")) == "A4"

        # …and the displayed PNG is byte-identical to what the renderer
        # wrote: §10.6 badges are UI overlays, never baked into the image.
        png = tmp_path / "c-1.png"
        assert hashlib.sha256(png.read_bytes()).hexdigest() == spy.shas["c-1"]
        # Even under the chip's position the image is still solid colour.
        assert _close(_image_pixel(state, (6, 6)), (30, 120, 60))
        assert _close(_image_pixel(state, (40, 40)), (30, 120, 60))


def test_render_failure_keeps_placeholder(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    def boom(row: dict, out_path: Path, size: int) -> None:
        raise RuntimeError("renderer exploded")

    with _studio(thumbnail_fn=boom, thumbs_dir=tmp_path) as (root, win, bus):
        with caplog.at_level(logging.WARNING, logger="pc_agent.gui.canvas_gallery_panel"):
            bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
            assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
            assert _pump_until(root, lambda: not win._gallery._pending)
        assert any("crashed" in r.getMessage() for r in caplog.records)
        state = _state(win, "c-1")
        assert state["image"] is None
        assert _colour(state["thumb_box"].cget("fg_color")) == _THUMB_BG
        assert not (tmp_path / "c-1.png").exists()


def test_default_thumbnail_fn_keeps_placeholder_without_renderer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Force the lazy import to fail no matter whether a sibling landed the
    # renderer module (None in sys.modules → ImportError on import).
    monkeypatch.setitem(sys.modules, "pc_agent.export.thumbnail_renderer", None)
    out = tmp_path / "nested" / "c-9.png"
    assert default_thumbnail_fn(_ROWS[0], out, 192) is None
    assert not out.exists()
    assert not out.parent.exists()  # the import fails before any mkdir


def test_default_thumbnail_fn_prefers_archive_document(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    tr_mod = pytest.importorskip("pc_agent.export.thumbnail_renderer")
    captured: dict[str, Any] = {}

    def fake_render(doc: Any, out_path: Path, size: int = 192) -> Path:
        captured["doc"] = doc
        Path(out_path).write_bytes(b"png-bytes")
        return Path(out_path)

    monkeypatch.setattr(tr_mod, "render_thumbnail", fake_render)

    # §9.3 hub archive: a ZIP holding the full Doc 03 document.json.
    canvases = tmp_path / "canvases"
    canvases.mkdir()
    body = {
        "canvas_id": "c-7",
        "title": "Archived",
        "created_at": 1_760_000_000,
        "updated_at": _NOW - 60,
        "artboard": {
            "preset": "A4",
            "width": 595.0,
            "height": 842.0,
            "background": "RULED",
            "is_infinite": False,
        },
        "content_bounds": {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        "elements": [],
    }
    with zipfile.ZipFile(canvases / "c-7.slatesync", "w") as archive:
        archive.writestr("document.json", json.dumps(body))
    row = {"id": "c-7", "title": "Row title", "preset": "A4", "updated_at": _NOW - 60}

    out = tmp_path / "thumbs" / "c-7.png"
    assert default_thumbnail_fn(row, out, 192, canvases_dir=canvases) == out
    assert out.exists()
    # The ARCHIVED full document wins over the row-derived fallback — the
    # renderer (Doc 02 §10.6) needs created_at/elements a row cannot carry.
    assert captured["doc"]["title"] == "Archived"
    assert captured["doc"]["created_at"] == 1_760_000_000
    assert captured["doc"]["artboard"]["preset"] == "A4"

    # Without an archive the row-derived document is passed instead.
    captured.clear()
    out2 = tmp_path / "thumbs" / "c-8.png"
    fallback_row = {"id": "c-8", "preset": "INFINITE", "updated_at": 1}
    assert default_thumbnail_fn(fallback_row, out2, 192, canvases_dir=canvases) == out2
    assert out2.exists()
    assert captured["doc"]["canvas_id"] == "c-8"
    assert captured["doc"]["artboard"]["is_infinite"] is True
    assert captured["doc"]["elements"] == []


def test_panel_without_renderer_keeps_placeholder_end_to_end(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """thumbnail_fn=None → lazy default path degrades to the gray box."""
    monkeypatch.setitem(sys.modules, "pc_agent.export.thumbnail_renderer", None)
    with _studio(thumbnail_fn=None, thumbs_dir=tmp_path) as (root, win, bus):
        bus.emit(CANVAS_LIST_UPDATED, canvases=_ROWS, devices=1)
        assert _pump_until(root, lambda: len(win._gallery.card_ids) == 2)
        assert _pump_until(root, lambda: not win._gallery._pending)
        state = _state(win, "c-1")
        assert state["image"] is None
        assert _colour(state["thumb_box"].cget("fg_color")) == _THUMB_BG
        assert str(state["badge"].cget("text")) == "A4"  # badge survives
        assert not (tmp_path / "c-1.png").exists()


def test_image_cache_is_lru_capped() -> None:
    root = _make_root()
    try:
        panel = CanvasGalleryPanel(root)
        for i in range(_LRU_CAP + 6):
            panel._remember_image((f"c-{i}", 1), object())  # type: ignore[arg-type]
        assert len(panel._image_cache) == _LRU_CAP
        assert ("c-0", 1) not in panel._image_cache  # oldest evicted
        assert (f"c-{_LRU_CAP + 5}", 1) in panel._image_cache  # newest kept
    finally:
        try:
            root.destroy()
        except Exception:
            pass


def test_thumbnail_completion_marshals_via_after0(tmp_path: Path) -> None:
    started = threading.Event()
    release = threading.Event()
    done = threading.Event()

    def slow_thumb(row: dict, out_path: Path, size: int) -> Path:
        out = Path(out_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (size, size), (120, 30, 160)).save(out, "PNG")
        started.set()
        release.wait(timeout=5)
        done.set()
        return out

    with _studio(thumbnail_fn=slow_thumb, thumbs_dir=tmp_path) as (root, win, bus):
        gallery = win._gallery
        scheduled: list[tuple[int, Callable[..., None]]] = []
        original_after = gallery.frame.after

        def spy_after(ms: int, func: Callable[..., None] | None = None, *args):
            scheduled.append((ms, func))
            return original_after(ms, func, *args)

        gallery.frame.after = spy_after  # type: ignore[method-assign]

        bus.emit(CANVAS_LIST_UPDATED, canvases=[dict(_ROWS[0])], devices=1)
        assert _pump_until(root, lambda: len(gallery.card_ids) == 1)
        assert _state(win, "c-1")["image"] is None  # placeholder while rendering

        # The worker finishes while nothing is pumped → still no widget write.
        assert started.wait(timeout=5), "fake renderer never ran"
        release.set()
        assert done.wait(timeout=5), "fake renderer never finished"
        assert _state(win, "c-1")["image"] is None
        assert not any(
            getattr(func, "__name__", "") == "_on_render_done"
            for _, func in scheduled
        ), "the render pool must not marshal (or mutate) on its own thread"

        # Pumping delivers the completion through after(0) on the Tk thread.
        assert _pump_until(root, lambda: _state(win, "c-1")["image"] is not None)
        assert _close(_image_pixel(_state(win, "c-1")), (120, 30, 160))
        assert any(
            ms == 0 and getattr(func, "__name__", "") == "_on_render_done"
            for ms, func in scheduled
        ), "completion must be re-posted via after(0, _on_render_done, …)"
