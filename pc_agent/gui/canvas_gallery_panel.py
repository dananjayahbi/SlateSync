"""Docked left canvas-gallery strip for the PC Studio (Issue 03-PC, round 5).

Lists the hub's merged canvas rows delivered by the frozen
``CANVAS_LIST_UPDATED`` payload (``{canvases, devices}`` — Doc 02 §9 /
``pc_agent/core/events.py``): each row is ``title · preset · updated``
(relative for recent changes, absolute otherwise) plus a small ``source``
tag when the row carries one.  The current open canvas row is highlighted.

The panel is purely presentational: the owning ``StudioWindow`` decides
visibility (paired **and** non-empty) and feeds rows/highlight state; row
activation forwards to the injected ``open_request`` callback (Doc 02 §8.3
flow 3 — both sides open).  This module never imports the bus or network
code, and never mutates widgets before it is mounted.
"""

from __future__ import annotations

import logging
import time
import tkinter as tk
from typing import Callable

import customtkinter as ctk

logger = logging.getLogger(__name__)

_PANEL_WIDTH = 240
_TAG_WIDTH = 56
_ACTIVATE_DEDUPE_S = 0.4  # a double-click is two releases → one open_request
_RECENT_S = 7 * 24 * 3600  # newer than 7 days → relative stamp

# Row backgrounds: neutral rows, brand accent (#4F8EF7) for the open canvas.
_ROW_BG = "#2B2B2B"
_ROW_BG_HOVER = "#3A3A3A"
_ROW_BG_CURRENT = "#4F8EF7"


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


class CanvasGalleryPanel:
    """Collapsible left strip listing the hub canvases (Issue 03-PC).

    The frame is *mounted* (grid options stored) but not managed until the
    owner calls ``set_visible(True)``; hiding uses ``grid_remove`` so the
    stored options come back verbatim on the next show.
    """

    def __init__(
        self,
        master: tk.Misc,
        open_request: Callable[[str], None] | None = None,
    ) -> None:
        """Build the strip's widgets on ``master`` (ungridded until mounted)."""
        self._open_request = open_request
        self._current_id: str | None = None
        self._visible = False
        self._collapsed = False
        self._grid_kwargs: dict = {}
        self._last_activation: tuple[str, float] = ("", float("-inf"))
        self._row_buttons: dict[str, ctk.CTkButton] = {}
        self._row_holders: list[ctk.CTkFrame] = []  # our rows only (never internals)

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
        """Scrollable row container filling the strip below the header."""
        listing = ctk.CTkScrollableFrame(self.frame, width=_PANEL_WIDTH - 16)
        listing.pack(fill="both", expand=True, padx=2, pady=(0, 6))
        return listing

    def _build_row(self, row: dict) -> ctk.CTkFrame | None:
        """One ``button (+ optional source tag)`` row; ``None`` without an id."""
        canvas_id = str(row.get("id") or row.get("canvas_id") or "")
        if not canvas_id:
            logger.debug("gallery row without id skipped: %r", row)
            return None
        holder = ctk.CTkFrame(self._list, fg_color="transparent")
        holder.pack(fill="x", padx=4, pady=2)
        self._row_holders.append(holder)
        button = ctk.CTkButton(
            holder,
            text=row_label(row),
            anchor="w",
            height=28,
            corner_radius=6,
            fg_color=(
                _ROW_BG_CURRENT if canvas_id == self._current_id else _ROW_BG
            ),
            hover_color=_ROW_BG_HOVER,
            command=lambda cid=canvas_id: self.activate(cid),
        )
        button.pack(side="left", fill="x", expand=True)
        source = row.get("source")
        if source:
            tag = ctk.CTkLabel(
                holder,
                text=str(source),
                width=_TAG_WIDTH,
                height=18,
                font=ctk.CTkFont(size=10),
                text_color="#B0B0B0",
            )
            tag.pack(side="right", padx=(4, 4))
            tag.bind(
                "<Button-1>", lambda _event, cid=canvas_id: self.activate(cid)
            )
        self._row_buttons[canvas_id] = button
        return holder

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
        """Rebuild the row buttons from CANVAS_LIST rows (Tk thread only).

        Only frames this panel created are destroyed — CTkScrollableFrame
        internals stay untouched even if they surface in ``winfo_children``.
        """
        for holder in self._row_holders:
            try:
                holder.destroy()
            except tk.TclError:  # pragma: no cover - already gone
                pass
        self._row_holders.clear()
        self._row_buttons.clear()
        for row in canvases:
            if isinstance(row, dict):
                self._build_row(row)

    def set_current(self, canvas_id) -> None:
        """Highlight the row of the currently-open canvas (``None`` clears)."""
        self._current_id = str(canvas_id) if canvas_id else None
        for cid, button in self._row_buttons.items():
            button.configure(
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
    def row_ids(self) -> list[str]:
        return list(self._row_buttons)

    def row_for(self, canvas_id: str) -> ctk.CTkButton | None:
        return self._row_buttons.get(str(canvas_id))
