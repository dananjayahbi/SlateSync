"""PC Settings dialog — connected devices, mirrored canvas, export folder.

Round 7 (issues 03/04/05/07). The PC agent is the orchestrator, so it needs a
place to *see* and *steer* the session:

* **Connected devices** — one row per tablet (name, peer, the canvas it has
  open, and a radio button selecting which canvas the PC mirrors).
* **Export folder** — pick any directory (defaults to the OS Downloads folder)
  and persist it through ``ConfigManager.set_export_dir``; the next export job
  writes there without a restart.
* **Pairing** — "Reset pairing" rotates the static QR token.

The dialog owns only widgets + callbacks; state and persistence stay in
``DeviceRoster`` / ``ConfigManager`` so it is trivially testable with fakes.
"""

from __future__ import annotations

import logging
import os
import tkinter as tk
from collections.abc import Callable
from pathlib import Path
from tkinter import filedialog

import customtkinter as ctk

logger = logging.getLogger(__name__)

_FALLBACK = "—"


class SettingsPanel:
    """Toplevel settings dialog (devices, mirror choice, export folder)."""

    def __init__(
        self,
        root: tk.Misc,
        *,
        set_export_dir: Callable[[Path], object] | None = None,
        select_mirror: Callable[[str | None], object] | None = None,
        rotate_pairing: Callable[[], object] | None = None,
        export_dir: Path | None = None,
        on_close: Callable[[], None] | None = None,
    ) -> None:
        self._root = root
        self._set_export_dir = set_export_dir
        self._select_mirror = select_mirror
        self._rotate_pairing = rotate_pairing
        self._on_close = on_close
        self._export_dir = Path(export_dir) if export_dir else None

        self._dialog = ctk.CTkToplevel(root)
        self._dialog.title("SlateSync Settings")
        self._dialog.geometry("560x520")
        self._dialog.minsize(480, 420)
        self._dialog.protocol("WM_DELETE_WINDOW", self.close)

        self._devices_frame: ctk.CTkFrame | None = None
        self._empty_label: ctk.CTkLabel | None = None
        self._selected_canvas: str | None = None
        self._export_label: ctk.CTkLabel | None = None
        self._device_rows: list[dict] = []

        self._build()

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------
    def _build(self) -> None:
        dialog = self._dialog
        body = ctk.CTkFrame(dialog)
        body.pack(fill="both", expand=True, padx=12, pady=12)

        ctk.CTkLabel(
            body, text="Connected devices", anchor="w",
            font=ctk.CTkFont(size=14, weight="bold"),
        ).pack(fill="x", pady=(0, 6))
        self._devices_frame = ctk.CTkFrame(body)
        self._devices_frame.pack(fill="x", pady=(0, 4))
        self._empty_label = ctk.CTkLabel(
            body,
            text="No devices connected yet - scan the pairing QR with a tablet.",
            anchor="w",
        )
        self._empty_label.pack(fill="x", pady=(0, 10))

        ctk.CTkLabel(
            body, text="Export folder", anchor="w",
            font=ctk.CTkFont(size=14, weight="bold"),
        ).pack(fill="x", pady=(6, 6))
        row = ctk.CTkFrame(body)
        row.pack(fill="x", pady=(0, 10))
        self._export_label = ctk.CTkLabel(
            row, text=str(self._export_dir or _FALLBACK), anchor="w"
        )
        self._export_label.pack(side="left", fill="x", expand=True, padx=(0, 8))
        self._browse_btn = ctk.CTkButton(
            row, text="Change…", width=100, command=self.choose_export_dir
        )
        self._browse_btn.pack(side="right")

        footer = ctk.CTkFrame(body)
        footer.pack(fill="x", pady=(6, 0))
        self._reset_btn = ctk.CTkButton(
            footer,
            text="Reset pairing",
            width=130,
            fg_color="#B03A2E",
            hover_color="#922B21",
            command=self.reset_pairing,
        )
        self._reset_btn.pack(side="left")
        ctk.CTkButton(footer, text="Close", width=90, command=self.close).pack(
            side="right"
        )

        self.refresh_devices([])

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    @property
    def window(self) -> ctk.CTkToplevel:
        return self._dialog

    @property
    def device_rows(self) -> list[dict]:
        return list(self._device_rows)

    @property
    def mirrored_selection(self) -> str | None:
        return self._selected_canvas

    def exists(self) -> bool:
        try:
            return bool(self._dialog.winfo_exists())
        except tk.TclError:
            return False

    def refresh_devices(
        self, rows: list[dict], mirrored_canvas_id: str | None = None
    ) -> None:
        """Rebuild the device list from ``DEVICES_UPDATED`` rows."""
        frame = self._devices_frame
        if frame is None:
            return
        self._device_rows = [dict(row) for row in rows or []]
        for child in frame.winfo_children():
            child.destroy()
        if mirrored_canvas_id is None:
            for row in self._device_rows:
                if row.get("mirrored") and row.get("open_canvas_id"):
                    mirrored_canvas_id = str(row["open_canvas_id"])
                    break
        self._selected_canvas = str(mirrored_canvas_id) if mirrored_canvas_id else None

        if self._empty_label is not None:
            if self._device_rows:
                self._empty_label.pack_forget()
            else:
                self._empty_label.pack(fill="x", pady=(0, 10))

        for index, row in enumerate(self._device_rows):
            self._build_device_row(frame, index, row)

    def _build_device_row(self, parent: tk.Misc, index: int, row: dict) -> None:
        line = ctk.CTkFrame(parent)
        line.pack(fill="x", pady=2)
        canvas_id = row.get("open_canvas_id")
        value = str(canvas_id) if canvas_id else ""
        selected = bool(value) and value == self._selected_canvas
        mirror_btn = ctk.CTkButton(
            line,
            text="Mirroring" if selected else "Mirror",
            width=90,
            state="normal" if value else "disabled",
            fg_color="#2E7D32" if selected else None,
            command=lambda target=value: self.select_mirror(target),
        )
        mirror_btn.pack(side="left", padx=(4, 6))
        label = ctk.CTkLabel(
            line,
            text=self._row_text(row),
            anchor="w",
            justify="left",
        )
        label.pack(side="left", fill="x", expand=True, padx=4)

    @staticmethod
    def _row_text(row: dict) -> str:
        name = row.get("name") or row.get("device_id") or row.get("peer") or _FALLBACK
        peer = row.get("peer") or _FALLBACK
        title = row.get("open_canvas_title") or row.get("open_canvas_id")
        canvas = f"- {title}" if title else "- no canvas open"
        return f"{name}  ({peer})\n   {canvas}"

    def select_mirror(self, canvas_id: str | None) -> None:
        """Choose the mirrored canvas for the PC (round 7, issue 07)."""
        target = str(canvas_id) if canvas_id else None
        self._selected_canvas = target
        if self._select_mirror is not None:
            try:
                self._select_mirror(target)
            except Exception:
                logger.exception("mirror selection failed for %r", target)
        self.refresh_devices(self._device_rows, target)

    # ------------------------------------------------------------------
    # Export folder
    # ------------------------------------------------------------------
    def choose_export_dir(self) -> Path | None:
        """Ask for a folder and persist it as the export destination."""
        initial = str(self._export_dir) if self._export_dir else ""
        if not initial or not Path(initial).is_dir():
            initial = str(Path.home() / "Downloads")
        try:
            chosen = filedialog.askdirectory(
                parent=self._dialog, title="Choose export folder", initialdir=initial
            )
        except tk.TclError:
            logger.debug("folder picker unavailable", exc_info=True)
            return None
        if not chosen:
            return None
        return self.set_export_dir(Path(chosen))

    def set_export_dir(self, path: Path) -> Path:
        """Persist + display a new export folder (also used by tests)."""
        target = Path(path).expanduser()
        if self._set_export_dir is not None:
            try:
                self._set_export_dir(target)
            except Exception:
                logger.exception("persisting the export folder failed: %s", target)
        self._export_dir = target
        if self._export_label is not None:
            self._export_label.configure(text=str(target))
        return target

    # ------------------------------------------------------------------
    # Pairing
    # ------------------------------------------------------------------
    def reset_pairing(self) -> None:
        """Rotate the static pairing token (previously paired devices fail)."""
        if self._rotate_pairing is None:
            return
        try:
            self._rotate_pairing()
        except Exception:
            logger.exception("pairing reset failed")

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def close(self) -> None:
        try:
            self._dialog.destroy()
        except tk.TclError:  # already gone
            pass
        if self._on_close is not None:
            self._on_close()

    @staticmethod
    def default_export_dir() -> Path:
        """Downloads folder — the documented default destination."""
        return Path(os.path.expanduser("~")) / "Downloads"
