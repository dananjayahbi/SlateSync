"""Docked left canvas-gallery strip for the PC Studio (Issue 07-PC, round 6).

Renders the hub's merged canvas rows delivered by the frozen
``CANVAS_LIST_UPDATED`` payload (``{canvases, devices}`` — Doc 02 §9) as a
two-column grid of **thumbnail cards** instead of text rows: a rounded
thumbnail box (192² source per Doc 02 §10.6) with the preset badge chip
(``A5``/``A4``/``LETTER``/``INFINITE``) overlaid on top, the title below and
the updated stamp (relative for recent changes, absolute otherwise) under it
plus a small ``source`` tag when the row carries one.  Per §10.6 the badge
is a **UI overlay** — a widget, never baked into the image.  The current
open canvas card is highlighted with the brand accent.

Thumbnail pipeline (Doc 02 §10.6): on every list update, cards whose
``<thumbs_dir>/<id>.png`` (default ``%APPDATA%/SlateSync/thumbs/``) is
missing — or stale, i.e. its mtime predates the row's ``updated_at`` — are
queued on a shared ``ThreadPoolExecutor(max_workers=2)`` whose worker calls
``render_thumbnail`` through a **lazy import inside the function** (a plain
``ImportError`` leaves the neutral gray placeholder box in place, so the
panel is fully usable before ``pc_agent.export.thumbnail_renderer`` lands).
Completions marshal onto the Tk thread with ``after(0)`` via this panel's
own queue + poller (the StudioWindow §5.8 pattern — calling Tk off-thread
raises ``RuntimeError`` in CPython) and swap the placeholder for the decoded
``CTkImage``.  Decoded images live in an in-memory LRU capped at 64 entries
keyed by ``(canvas_id, updated_at)``, so a bumped ``updated_at`` drops its
own image; card + cache both keep the ``CTkImage`` (→ PhotoImage) reference
so Tk never garbage-collects a displayed thumbnail.

The panel is purely presentational: the owning ``StudioWindow`` decides
visibility (paired **and** non-empty) and feeds rows/highlight state; card
activation forwards to the injected ``open_request`` callback (Doc 02 §8.3
flow 3 — both sides open).  This module never imports the bus or network
code, and never mutates widgets before it is mounted.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import tkinter as tk
import zipfile
from collections import OrderedDict, deque
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path
from typing import Callable

import customtkinter as ctk
from PIL import Image

logger = logging.getLogger(__name__)

_PANEL_WIDTH = 240
_CARD_COLUMNS = 2  # thumbnail cards per grid row in the 240 px strip
_THUMB_SOURCE = 192  # Doc 02 §10.6 render size (square source image)
_THUMB_DISPLAY = 80  # on-card thumbnail display box (px)
_ACTIVATE_DEDUPE_S = 0.4  # a double-click is two releases → one open_request
_RECENT_S = 7 * 24 * 3600  # newer than 7 days → relative stamp
_LRU_CAP = 64  # decoded CTkImage cache entries
_POLL_MS = 10  # Tk-thread drain cadence (matches StudioWindow)
_STALE_SLACK_S = 1.0  # mtime within 1 s of updated_at counts as fresh

# Card backgrounds: neutral rows, brand accent (#4F8EF7) for the open canvas.
_ROW_BG = "#2B2B2B"
_ROW_BG_CURRENT = "#4F8EF7"
_THUMB_BG = "#3C3C3C"  # neutral gray placeholder box behind the badge
_UPDATED_TEXT = "#9A9A9A"
_TAG_TEXT = "#B0B0B0"

# Badge chip colours (Doc 02 §10.6: UI overlay only — never baked into the
# rendered thumbnail).
_PRESET_BADGE_BG = {
    "A5": "#4F8EF7",
    "A4": "#7B5BF2",
    "LETTER": "#E67E22",
    "INFINITE": "#16A085",
    "?": "#6B6B6B",
}
_BADGE_FG = "#FFFFFF"

_EXECUTOR: ThreadPoolExecutor | None = None  # shared §10.6 render pool
_EXECUTOR_LOCK = threading.Lock()


def format_updated(timestamp, now: float | None = None) -> str:
    """Relative stamp for recent changes, absolute otherwise.

    ``just now`` / ``5m ago`` / ``3h ago`` / ``2d ago`` when ``0 <= age <
    _RECENT_S``; ``%Y-%m-%d %H:%M`` for older, future or unparsable values
    (``?`` only when the value is not an integer at all).
    """
    try:
        stamp = int(timestamp)
    except (TypeError, ValueError):
        return "?"
    now = time.time() if now is None else now
    delta = now - stamp
    if 0 <= delta < 60:
        return "just now"
    if 0 <= delta < 3600:
        return f"{int(delta // 60)}m ago"
    if 0 <= delta < 24 * 3600:
        return f"{int(delta // 3600)}h ago"
    if 0 <= delta < _RECENT_S:
        return f"{int(delta // 86400)}d ago"
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(stamp))
    except (OSError, OverflowError, ValueError):  # pragma: no cover - absurd stamps
        return "?"


def row_label(row: dict) -> str:
    """``title · preset · updated`` display string for one CANVAS_LIST row."""
    title = str(row.get("title") or "Untitled")
    preset = str(row.get("preset") or "?")
    return f"{title} · {preset} · {format_updated(row.get('updated_at'))}"


def badge_text(preset) -> str:
    """Overlay chip text (``A5`` / ``A4`` / ``LETTER`` / ``INFINITE``)."""
    text = str(preset or "?").strip().upper()
    return text or "?"


def badge_bg(preset) -> str:
    """Chip colour per preset (unknown presets fall back to neutral gray)."""
    return _PRESET_BADGE_BG.get(badge_text(preset), _PRESET_BADGE_BG["?"])


def _appdata_root() -> Path:
    """``%APPDATA%/SlateSync`` — mirrors ``AppConfig.appdata_dir`` (Doc 04)."""
    return Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync"


def _row_updated(row: dict) -> int:
    """Row ``updated_at`` as an int (0 when missing/unparsable)."""
    try:
        return int(row.get("updated_at"))
    except (TypeError, ValueError):
        return 0


def _load_archive_doc(canvas_id: str, canvases_dir: str | Path | None) -> dict | None:
    """Full Doc 03 body from ``<canvases_dir>/<id>.slatesync`` (read-only).

    The Doc 02 §9.3 hub archive is a ZIP holding ``document.json``; loading it
    here (stdlib only — no engine imports from the GUI) gives the renderer the
    complete document a CANVAS_LIST row cannot carry.  Returns ``None`` when
    the archive is missing or unreadable (the row-derived fallback applies).
    """
    if not canvas_id:
        return None
    root = Path(canvases_dir) if canvases_dir is not None else _appdata_root() / "canvases"
    path = root / f"{canvas_id}.slatesync"
    try:
        with zipfile.ZipFile(path, "r") as archive:
            return json.loads(archive.read("document.json").decode("utf-8"))
    except FileNotFoundError:
        return None
    except Exception:  # corrupt zip / bad json → placeholder path handles it
        logger.debug("archive read failed for %s", canvas_id, exc_info=True)
        return None


def _thumb_executor() -> ThreadPoolExecutor:
    """Shared ``ThreadPoolExecutor(max_workers=2)`` for §10.6 renders."""
    global _EXECUTOR
    with _EXECUTOR_LOCK:
        if _EXECUTOR is None:
            _EXECUTOR = ThreadPoolExecutor(
                max_workers=2, thread_name_prefix="slatesync-thumb"
            )
    return _EXECUTOR


def default_thumbnail_fn(
    row: dict,
    out_path: Path,
    size: int = _THUMB_SOURCE,
    *,
    canvases_dir: str | Path | None = None,
):
    """Doc 02 §10.6 wrapper: lazy renderer import, placeholder on failure.

    ``pc_agent.export.thumbnail_renderer`` is imported **inside** this
    function (a sibling agent owns that module); ``ImportError`` — or any
    render failure — returns ``None`` so the caller keeps the gray
    placeholder box.  The renderer needs a full Doc 03 document, so the
    archived ``document.json`` (``<canvases_dir>/<id>.slatesync``, §9.3) is
    loaded read-only first; without an archive the CANVAS_LIST ``row`` is
    widened into a best-effort document dict (``canvas_id``, ``artboard``
    with ``is_infinite``, ``elements``).  Returns the written ``Path`` on
    success, ``None`` otherwise.
    """
    try:
        from pc_agent.export.thumbnail_renderer import render_thumbnail
    except ImportError:
        logger.debug("thumbnail renderer not importable yet", exc_info=True)
        return None
    canvas_id = str(row.get("canvas_id") or row.get("id") or "")
    doc = _load_archive_doc(canvas_id, canvases_dir)
    if doc is None:
        preset = badge_text(row.get("preset"))
        doc = dict(row)
        doc.update(
            canvas_id=canvas_id,
            elements=row.get("elements") or [],
            artboard={
                "preset": preset,
                "background": row.get("background"),
                "is_infinite": preset == "INFINITE",
            },
        )
    out_path = Path(out_path)
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        written = render_thumbnail(doc, out_path=out_path, size=size)
    except Exception:
        logger.warning("thumbnail render failed for %s", canvas_id, exc_info=True)
        return None
    if written:
        return Path(written)
    return out_path if out_path.exists() else None


class CanvasGalleryPanel:
    """Collapsible left strip of thumbnail cards (Issue 07-PC).

    The frame is *mounted* (grid options stored) but not managed until the
    owner calls ``set_visible(True)``; hiding uses ``grid_remove`` so the
    stored options come back verbatim on the next show.
    """

    def __init__(
        self,
        master: tk.Misc,
        open_request: Callable[[str], None] | None = None,
        *,
        thumbnail_fn: Callable[[dict, Path, int], object] | None = None,
        thumbs_dir: str | Path | None = None,
        canvases_dir: str | Path | None = None,
    ) -> None:
        """Build the strip's widgets on ``master`` (ungridded until mounted).

        ``thumbnail_fn(row, out_path, size)`` overrides the default lazy
        :func:`default_thumbnail_fn` (tests inject a fake; ``None`` keeps the
        Doc 02 §10.6 renderer path).  ``thumbs_dir`` defaults to
        ``%APPDATA%/SlateSync/thumbs`` and ``canvases_dir`` (the §9.3 archive
        root the default renderer reads full documents from) to
        ``%APPDATA%/SlateSync/canvases``.
        """
        self._open_request = open_request
        self._thumbnail_fn = thumbnail_fn
        self._thumbs_dir = (
            Path(thumbs_dir) if thumbs_dir is not None else _appdata_root() / "thumbs"
        )
        self._canvases_dir = (
            Path(canvases_dir)
            if canvases_dir is not None
            else _appdata_root() / "canvases"
        )
        self._current_id: str | None = None
        self._visible = False
        self._collapsed = False
        self._grid_kwargs: dict = {}
        self._last_activation: tuple[str, float] = ("", float("-inf"))
        self._cards: dict[str, dict] = {}  # canvas_id → card widget bundle
        self._card_frames: list[ctk.CTkFrame] = []  # ours only (never internals)
        self._image_cache: OrderedDict[tuple[str, int], ctk.CTkImage] = OrderedDict()
        self._pending: dict[str, int] = {}  # canvas_id → updated_at rendering
        self._pending_calls: deque[tuple[int, Callable[..., None], tuple]] = deque()
        self._tk_ident = threading.get_ident()  # built on the Tk thread
        self._polling = False

        self.frame = ctk.CTkFrame(master, width=_PANEL_WIDTH, corner_radius=8)
        self._header = self._build_header()
        self._list = self._build_list()

    # ------------------------------------------------------------------
    # Component builders (§5.2 style — small, one concern each)
    # ------------------------------------------------------------------
    def _build_header(self) -> ctk.CTkFrame:
        """Title label + collapse toggle pinned at the strip's top."""
        header = ctk.CTkFrame(self.frame, fg_color="transparent")
        header.pack(fill="x", padx=6, pady=(6, 2))
        ctk.CTkLabel(
            header,
            text="Canvases",
            font=ctk.CTkFont(size=13, weight="bold"),
        ).pack(side="left", padx=(2, 0))
        self._toggle_btn = ctk.CTkButton(
            header, text="–", width=26, height=24, command=self.toggle_collapse
        )
        self._toggle_btn.pack(side="right")
        return header

    def _build_list(self) -> ctk.CTkScrollableFrame:
        """Scrollable 2-column card grid filling the strip below the header."""
        listing = ctk.CTkScrollableFrame(self.frame, width=_PANEL_WIDTH - 16)
        listing.pack(fill="both", expand=True, padx=2, pady=(0, 6))
        for column in range(_CARD_COLUMNS):
            listing.grid_columnconfigure(column, weight=1, uniform="cards")
        return listing

    def _build_card(self, row: dict, slot: int) -> dict | None:
        """One thumbnail card bundle; ``None`` without an id.

        Layout: rounded gray thumb box (the §10.6 placeholder / image area)
        with the preset badge chip overlaid top-left, title below, updated
        stamp (+ optional source tag) at the bottom.  ``slot`` places the
        card in the 2-column grid (left to right, then down).
        """
        canvas_id = str(row.get("id") or row.get("canvas_id") or "")
        if not canvas_id:
            logger.debug("gallery card without id skipped: %r", row)
            return None
        card = ctk.CTkFrame(
            self._list,
            corner_radius=10,
            fg_color=(
                _ROW_BG_CURRENT if canvas_id == self._current_id else _ROW_BG
            ),
        )
        grid_row, grid_col = divmod(slot, _CARD_COLUMNS)
        card.grid(row=grid_row, column=grid_col, sticky="nsew", padx=3, pady=4)
        card.grid_columnconfigure(0, weight=1)

        thumb_box = ctk.CTkFrame(card, corner_radius=10, fg_color=_THUMB_BG)
        thumb_box.grid(row=0, column=0, pady=(6, 3))
        image_label = ctk.CTkLabel(
            thumb_box,
            text="",
            width=_THUMB_DISPLAY,
            height=_THUMB_DISPLAY,
            fg_color="transparent",
            corner_radius=6,
        )
        image_label.grid(row=0, column=0, padx=4, pady=4)
        # UI overlay (§10.6) — a chip widget, never baked into the PNG.
        badge = ctk.CTkLabel(
            thumb_box,
            text=badge_text(row.get("preset")),
            fg_color=badge_bg(row.get("preset")),
            text_color=_BADGE_FG,
            corner_radius=6,
            height=16,
            font=ctk.CTkFont(size=9, weight="bold"),
        )
        badge.grid(row=0, column=0, sticky="nw", padx=5, pady=5)
        title = ctk.CTkLabel(
            card,
            text=str(row.get("title") or "Untitled"),
            anchor="w",
            justify="left",
            wraplength=80,
            font=ctk.CTkFont(size=11, weight="bold"),
        )
        title.grid(row=1, column=0, sticky="ew", padx=6, pady=(3, 0))
        footer = ctk.CTkFrame(card, fg_color="transparent")
        footer.grid(row=2, column=0, sticky="ew", padx=6, pady=(0, 6))
        updated = ctk.CTkLabel(
            footer,
            text=format_updated(row.get("updated_at")),
            anchor="w",
            font=ctk.CTkFont(size=10),
            text_color=_UPDATED_TEXT,
        )
        updated.pack(side="left")
        source = None
        if row.get("source"):
            source = ctk.CTkLabel(
                footer,
                text=str(row.get("source")),
                font=ctk.CTkFont(size=9),
                text_color=_TAG_TEXT,
            )
            source.pack(side="right", padx=(4, 0))
        for widget in (card, thumb_box, image_label, badge, title, footer, updated, source):
            if widget is not None:
                self._bind_activate(widget, canvas_id)
        return {
            "frame": card,
            "thumb_box": thumb_box,
            "image_label": image_label,
            "badge": badge,
            "title": title,
            "footer": footer,
            "updated": updated,
            "source": source,
            "canvas_id": canvas_id,
            "updated_at": _row_updated(row),
            "row": dict(row),
            "image": None,
        }

    def _bind_activate(self, widget: tk.Misc, canvas_id: str) -> None:
        """Route a click anywhere on the card to :meth:`activate`."""
        try:
            widget.bind(
                "<Button-1>",
                lambda _event, cid=canvas_id: self.activate(cid),
            )
        except (tk.TclError, TypeError):  # pragma: no cover - widget gone
            logger.debug("gallery card bind skipped", exc_info=True)

    # ------------------------------------------------------------------
    # Thumbnail pipeline (Doc 02 §10.6 — render, marshal, cache)
    # ------------------------------------------------------------------
    def _thumb_path(self, canvas_id: str) -> Path:
        """``<thumbs_dir>/<canvas_id>.png`` (default ``%APPDATA%/…/thumbs``)."""
        return self._thumbs_dir / f"{canvas_id}.png"

    def _ensure_thumbnail(self, canvas_id: str, row: dict) -> None:
        """Show a fresh cached/disk image, else queue a background render."""
        updated_at = _row_updated(row)
        if self._pending.get(canvas_id) == updated_at:
            return  # this generation is already rendering
        if self._thumb_fresh(canvas_id, updated_at):
            card = self._cards.get(canvas_id)
            if card is not None and self._show_thumbnail(card, canvas_id, updated_at):
                return
        self._submit_render(canvas_id, row, updated_at)

    def _thumb_fresh(self, canvas_id: str, updated_at: int) -> bool:
        """True when the PNG exists and is not older than ``updated_at``."""
        try:
            mtime = self._thumb_path(canvas_id).stat().st_mtime
        except OSError:
            return False  # missing
        return mtime + _STALE_SLACK_S >= float(updated_at)

    def _submit_render(self, canvas_id: str, row: dict, updated_at: int) -> None:
        """Queue the render on the shared 2-worker pool (Tk thread only)."""
        self._start_poller()
        self._pending[canvas_id] = updated_at
        try:
            _thumb_executor().submit(self._render_job, canvas_id, dict(row), updated_at)
        except RuntimeError:  # interpreter shutdown — placeholder stays
            logger.debug("thumbnail submit skipped (pool closed)", exc_info=True)
            self._pending.pop(canvas_id, None)

    def _render_job(self, canvas_id: str, row: dict, updated_at: int) -> None:
        """Worker thread: run the (lazily imported) renderer, then marshal."""
        fn = self._thumbnail_fn or partial(
            default_thumbnail_fn, canvases_dir=self._canvases_dir
        )
        try:
            fn(row, self._thumb_path(canvas_id), _THUMB_SOURCE)
        except Exception:
            logger.warning("thumbnail job crashed for %s", canvas_id, exc_info=True)
        self._post(0, self._on_render_done, canvas_id, updated_at)

    def _on_render_done(self, canvas_id: str, updated_at: int) -> None:
        """Tk thread: release the pending slot and swap in the new image."""
        if self._pending.get(canvas_id) == updated_at:
            self._pending.pop(canvas_id, None)
        card = self._cards.get(canvas_id)
        if card is not None and card["updated_at"] == updated_at:
            self._show_thumbnail(card, canvas_id, updated_at)

    def _show_thumbnail(self, card: dict, canvas_id: str, updated_at: int) -> bool:
        """Decode → LRU cache → set the card image (True when it displays)."""
        image = self._cached_image(canvas_id, updated_at)
        if image is None:
            return False
        card["image"] = image  # keep the PhotoImage alive (Tk GC rule)
        card["image_label"].configure(image=image, text="")
        return True

    def _cached_image(self, canvas_id: str, updated_at: int) -> ctk.CTkImage | None:
        """LRU-cached PIL→CTkImage decode of the PNG (None when unreadable)."""
        key = (canvas_id, updated_at)
        image = self._image_cache.get(key)
        if image is not None:
            self._image_cache.move_to_end(key)
            return image
        try:
            with Image.open(self._thumb_path(canvas_id)) as source:
                source.load()
                scaled = source.convert("RGBA").resize(
                    (_THUMB_DISPLAY, _THUMB_DISPLAY), Image.Resampling.LANCZOS
                )
        except (OSError, ValueError):
            return None
        image = ctk.CTkImage(
            light_image=scaled,
            dark_image=scaled,
            size=(_THUMB_DISPLAY, _THUMB_DISPLAY),
        )
        self._remember_image(key, image)
        return image

    def _remember_image(self, key: tuple[str, int], image: ctk.CTkImage) -> None:
        """Insert into the LRU, evicting oldest entries beyond ``_LRU_CAP``."""
        self._image_cache.pop(key, None)
        self._image_cache[key] = image
        while len(self._image_cache) > _LRU_CAP:
            self._image_cache.popitem(last=False)

    def _prune_images(self, current: dict[str, int]) -> None:
        """Drop cache entries whose canvas vanished or ``updated_at`` moved."""
        for key in list(self._image_cache):
            if key[0] not in current or current[key[0]] != key[1]:
                self._image_cache.pop(key, None)

    def _post(self, ms: int, func: Callable[..., None], *args) -> None:
        """Schedule ``func`` on the Tk thread via the queue + poller.

        On the Tk thread this is a plain ``frame.after(ms, …)``.  Off it a
        direct Tk call is unreliable in CPython (``RuntimeError: main thread
        is not in main loop``), so worker completions are queued and the
        Tk-thread poller re-posts them with ``after(0, …)`` — the same §5.8
        pattern as ``StudioWindow.after``.
        """
        if threading.get_ident() == self._tk_ident:
            try:
                self.frame.after(ms, func, *args)
            except tk.TclError:  # pragma: no cover - frame gone mid-teardown
                logger.debug("gallery after(%d) dropped", ms, exc_info=True)
            return
        self._pending_calls.append((ms, func, args))

    def _start_poller(self) -> None:
        """Arm the recurring Tk-thread drain (idempotent)."""
        if self._polling:
            return
        self._polling = True
        try:
            self.frame.after(_POLL_MS, self._poll_pending)
        except tk.TclError:  # pragma: no cover - frame gone
            self._polling = False

    def _poll_pending(self) -> None:
        """Drain queued worker completions onto the Tk thread via ``after``."""
        while True:
            try:
                ms, func, args = self._pending_calls.popleft()
            except IndexError:
                break
            try:
                self.frame.after(ms, func, *args)
            except Exception:  # destroyed frame mid-drain — keep it benign
                logger.debug("re-post of after(%d) failed", ms, exc_info=True)
                break
        try:
            self.frame.after(_POLL_MS, self._poll_pending)
        except Exception:
            self._polling = False  # frame gone

    # ------------------------------------------------------------------
    # Public API (driven by StudioWindow on the Tk thread)
    # ------------------------------------------------------------------
    def mount(self, **grid_kwargs) -> None:
        """Store grid options for later shows; grid now only if visible."""
        self._grid_kwargs = grid_kwargs
        if self._visible:
            self.frame.grid(**grid_kwargs)

    def set_visible(self, visible: bool) -> None:
        """Show (grid with the mounted options) or ``grid_remove`` the strip."""
        visible = bool(visible)
        if visible == self._visible:
            return
        self._visible = visible
        if visible:
            if self._grid_kwargs:  # mounted → grid now; mount() finishes the job
                self.frame.grid(**self._grid_kwargs)
        else:
            try:
                if self.frame.winfo_manager() == "grid":
                    self.frame.grid_remove()
            except tk.TclError:  # frame gone mid-teardown
                logger.debug("gallery hide skipped", exc_info=True)

    def set_rows(self, canvases: list[dict]) -> None:
        """Rebuild the card grid from CANVAS_LIST rows (Tk thread only).

        Only frames this panel created are destroyed — CTkScrollableFrame
        internals stay untouched even if they surface in ``winfo_children``.
        Afterwards each card's thumbnail is refreshed per Doc 02 §10.6
        (fresh → shown from cache/disk, missing/stale → rendered in the
        background pool).
        """
        for frame in self._card_frames:
            try:
                frame.destroy()
            except tk.TclError:  # pragma: no cover - already gone
                pass
        self._card_frames.clear()
        self._cards.clear()
        current: dict[str, int] = {}
        slot = 0
        for row in canvases:
            if not isinstance(row, dict):
                continue
            state = self._build_card(row, slot)
            if state is None:
                continue
            slot += 1
            self._cards[state["canvas_id"]] = state
            self._card_frames.append(state["frame"])
            current[state["canvas_id"]] = state["updated_at"]
        self._prune_images(current)
        for canvas_id, state in self._cards.items():
            self._ensure_thumbnail(canvas_id, state["row"])

    def set_current(self, canvas_id) -> None:
        """Highlight the card of the currently-open canvas (``None`` clears)."""
        self._current_id = str(canvas_id) if canvas_id else None
        for cid, state in self._cards.items():
            state["frame"].configure(
                fg_color=(
                    _ROW_BG_CURRENT if cid == self._current_id else _ROW_BG
                )
            )

    def toggle_collapse(self) -> None:
        """Collapse to just the header, or expand the row list again."""
        self._collapsed = not self._collapsed
        if self._collapsed:
            self._list.pack_forget()
            self._toggle_btn.configure(text="+")
        else:
            self._list.pack(fill="both", expand=True, padx=2, pady=(0, 6))
            self._toggle_btn.configure(text="–")

    def activate(self, canvas_id: str) -> None:
        """Select-and-open ``canvas_id`` via the injected callback.

        Deduplicated over ``_ACTIVATE_DEDUPE_S`` so a double-click (two
        button releases) issues exactly one ``open_request``.
        """
        now = time.monotonic()
        last_id, last_at = self._last_activation
        if canvas_id == last_id and now - last_at < _ACTIVATE_DEDUPE_S:
            return
        self._last_activation = (canvas_id, now)
        callback = self._open_request
        if callback is None:
            logger.warning("gallery open: no open_request callback wired")
            return
        callback(canvas_id)

    # ------------------------------------------------------------------
    # Read accessors (tests + owner diagnostics)
    # ------------------------------------------------------------------
    @property
    def visible(self) -> bool:
        return self._visible

    @property
    def collapsed(self) -> bool:
        return self._collapsed

    @property
    def card_ids(self) -> list[str]:
        return list(self._cards)

    @property
    def row_ids(self) -> list[str]:
        """Back-compat alias of :attr:`card_ids` (issue 03 name)."""
        return self.card_ids

    def card_for(self, canvas_id: str) -> ctk.CTkFrame | None:
        state = self._cards.get(str(canvas_id))
        return state["frame"] if state else None

    def row_for(self, canvas_id: str) -> ctk.CTkFrame | None:
        """Back-compat alias of :meth:`card_for` (issue 03 name)."""
        return self.card_for(canvas_id)

    def card_state(self, canvas_id: str) -> dict | None:
        """Widget/data bundle for one card (tests + owner diagnostics)."""
        return self._cards.get(str(canvas_id))
