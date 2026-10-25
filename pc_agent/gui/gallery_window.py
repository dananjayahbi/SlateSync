"""Round-13 — the PC image library window (Doc 02 §13.1, plan §03).

Why a separate window instead of a panel inside the studio: the brief asks for a
library that is usable **independently** of a canvas. A user pastes a screenshot,
copies it into a ticket, and never opens a document — forcing the studio window
open first would make the library feel like a canvas feature. So this is a plain
``CTkToplevel``:

* **never modal** — no ``grab_set()`` anywhere. A grab would freeze the agent
  while the library is open, which is the opposite of "independent".
* **closing it must not exit the app.** ``WM_DELETE_WINDOW`` destroys only this
  window; the root keeps its own handler (``main.py`` teardown). Getting this
  wrong ends the whole agent when the user dismisses the library.
* ``transient()`` is still applied so the window minimises with the app, but it is
  deliberately NOT forced on top: the user may want it behind the studio.

The two interaction details that decide whether the window is actually useful:

* **paste** (``Ctrl+V``) decodes a ``CF_DIB`` from the clipboard via
  :mod:`pc_agent.gallery.clipboard_image` — a PNG-only clipboard helper would
  produce entries nothing can paste.
* **drag-and-drop** needs ``tkinterdnd2``, which is not installed by default and
  is NOT added to ``requirements.txt``. Its absence degrades to paste plus the
  "Add from file…" button; it never breaks the window.
"""

from __future__ import annotations

import logging
import os
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable

import customtkinter as ctk
from PIL import Image

from pc_agent.core.events import EventBus
from pc_agent.gallery.clipboard_image import (
    ClipboardError,
    copy_image_to_clipboard,
    image_from_clipboard,
)
from pc_agent.gallery.events import GALLERY_CHANGED
from pc_agent.gallery.gallery_index import SOURCE_DROP, SOURCE_PASTE
from pc_agent.gallery.library_store import LibraryStore
from pc_agent.gui import dialog_utils

logger = logging.getLogger("slatesync.gallery.window")

try:  # optional: drag-and-drop needs a Tcl extension package
    from tkinterdnd2 import DND_FILES, TkinterDnD  # type: ignore[import-not-found]

    HAS_DND = True
except Exception:  # pragma: no cover - the normal case on a stock install
    DND_FILES = None
    TkinterDnD = None  # type: ignore[assignment]
    HAS_DND = False

_THUMB_PX = 148  # card thumbnail box
_CARD_PX = 196  # card footprint, so the grid maths is predictable
_GRID_PAD = 12
_POLL_MS = 10
_LRU_CAP = 128
_IMAGE_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff"}
)

_CARD_BG = "#2B2B2B"
_CARD_BG_HOVER = "#343434"
_THUMB_BG = "#3C3C3C"
_META_TEXT = "#9A9A9A"


def is_image_path(path: str | os.PathLike[str]) -> bool:
    """Cheap extension check for drop payloads (content is validated later)."""
    return Path(str(path)).suffix.lower() in _IMAGE_SUFFIXES


def parse_drop_paths(payload: str) -> list[str]:
    """Split a Tk drop payload into paths.

    Tk hands over a Tcl list, and a path containing spaces arrives wrapped in
    braces — ``{C:\\My Images\\shot 1.png}`` — so a plain ``split()`` would mangle
    exactly the files a user is most likely to drop.
    """
    text = str(payload or "").strip()
    if not text:
        return []
    paths: list[str] = []
    buffer: list[str] = []
    braced = False
    for char in text:
        if char == "{" and not braced:
            braced = True
            continue
        if char == "}" and braced:
            braced = False
            continue
        if char == " " and not braced:
            if buffer:
                paths.append("".join(buffer))
                buffer = []
            continue
        buffer.append(char)
    if buffer:
        paths.append("".join(buffer))
    return [path for path in paths if path]


def grid_columns(width_px: int, card_px: int = _CARD_PX) -> int:
    """Cards per row for a given width; always at least one.

    Computed rather than fixed so the window stays a *grid* at any size — a
    hardcoded column count leaves a narrow window with cards clipped off its edge.
    """
    usable = max(int(width_px) - 2 * _GRID_PAD, card_px)
    return max(1, usable // card_px)


def format_dimensions(width: object, height: object) -> str:
    """``1920 × 1080`` for the card caption; tolerant of bad values."""
    try:
        w = int(width)  # type: ignore[arg-type]
        h = int(height)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return "—"
    return f"{w} × {h}" if w > 0 and h > 0 else "—"


def suggested_save_name(row: dict) -> str:
    """Filename proposed by "Download": the stored name, safely re-derived."""
    raw = str(row.get("filename") or "").replace("\\", "/").rsplit("/", 1)[-1]
    name = raw.replace("..", "").strip(" .")
    return name or f"{row.get('image_id', 'image')}.png"


class GalleryWindow:
    """Non-modal thumbnail grid over :class:`LibraryStore`."""

    def __init__(
        self,
        root: object,
        bus: EventBus,
        store: LibraryStore,
        *,
        on_close: Callable[[], None] | None = None,
        auto_show: bool = False,
        thumbnail_loader: Callable[[Path, int], Image.Image] | None = None,
    ) -> None:
        self._bus = bus
        self._store = store
        self._on_close = on_close
        self._root = root
        self._closed = False
        self._rows: dict[str, dict] = {}
        self._order: list[str] = []
        self._images: "OrderedDict[str, Any]" = OrderedDict()
        self._cards: dict[str, ctk.CTkFrame] = {}
        self._thumb_future_images: dict[str, Image.Image] = {}
        self._columns = 0
        self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="gallery-thumb")
        self._load_thumbnail = thumbnail_loader or _pil_thumbnail

        self._window = dialog_utils.make_toplevel(root, "SlateSync Image Library")
        self._window.geometry("880x640")
        self._window.minsize(420, 360)
        self._window.protocol("WM_DELETE_WINDOW", self.close)
        # `make_toplevel` creates the window withdrawn and `show_toplevel` maps
        # it through `prepare_dialog`, which applies `transient()` for us. The
        # gallery is created on demand, so it must not appear until `show()` —
        # opening the window is the caller's decision, not a constructor
        # side-effect.

        self._build()
        bus.on(GALLERY_CHANGED, self._on_changed)
        self.reload()
        if auto_show:
            self.show()

    # ------------------------------------------------------------------ window

    @property
    def window(self) -> Any:
        return self._window

    def exists(self) -> bool:
        return not self._closed

    def show(self) -> None:
        if self._closed:
            return
        try:
            # modal=False is the whole point: the library must stay usable
            # beside the studio window, so it never takes a grab. Ownership
            # (transient) still comes from dialog_utils, which is what keeps it
            # from opening BEHIND the studio on Windows.
            dialog_utils.show_toplevel(self._window, self._root, modal=False)
        except Exception:  # pragma: no cover - window may already be gone
            logger.debug("gallery: show failed", exc_info=True)

    def close(self) -> None:
        """Close ONLY this window. The app keeps running (see module docstring)."""
        if self._closed:
            return
        self._closed = True
        try:
            self._bus.off(GALLERY_CHANGED, self._on_changed)
        except Exception:  # pragma: no cover - defensive
            logger.debug("gallery: unsubscribe failed", exc_info=True)
        self._pool.shutdown(wait=False, cancel_futures=True)
        try:
            self._window.destroy()
        except Exception:  # pragma: no cover - already destroyed
            pass
        self._images.clear()
        if self._on_close is not None:
            self._on_close()

    # -------------------------------------------------------------------- view

    def _build(self) -> None:
        self._bar = ctk.CTkFrame(self._window, fg_color="transparent")
        self._bar.pack(fill="x", padx=_GRID_PAD, pady=(_GRID_PAD, 6))
        self._count_label = ctk.CTkLabel(self._bar, text="No images yet", anchor="w")
        self._count_label.pack(side="left")
        self._add_button = ctk.CTkButton(
            self._bar, text="Add from file…", width=130, command=self.add_from_file
        )
        self._add_button.pack(side="right", padx=(6, 0))
        self._paste_button = ctk.CTkButton(
            self._bar, text="Paste", width=80, command=self.paste_from_clipboard
        )
        self._paste_button.pack(side="right")

        self._status = ctk.CTkLabel(
            self._window, text=self._status_text(), anchor="w", text_color=_META_TEXT
        )
        self._status.pack(fill="x", padx=_GRID_PAD, pady=(0, 6))

        self._grid = ctk.CTkScrollableFrame(self._window, label_text="Images")
        self._grid.pack(fill="both", expand=True, padx=_GRID_PAD, pady=(0, _GRID_PAD))
        self._empty = ctk.CTkLabel(
            self._grid,
            text="Paste (Ctrl+V) or drop an image here to start the library.",
            anchor="w",
        )

        # Ctrl+V on the window (not just a button): the shortcut is what people
        # actually press after a screenshot, and it works while the grid has
        # focus because the binding sits on the toplevel.
        for sequence in ("<Control-v>", "<Control-V>"):
            try:
                self._window.bind(sequence, lambda _event: self.paste_from_clipboard())
            except Exception:  # pragma: no cover - defensive
                logger.debug("gallery: Ctrl+V bind failed", exc_info=True)
        self._grid.bind("<Configure>", self._on_grid_configure, add="+")

        self._dnd_ok = self._enable_drop()

    def _status_text(self) -> str:
        if HAS_DND:
            return "Paste, drop files, or use Add from file…"
        return "Paste (Ctrl+V) or Add from file… — drag-and-drop needs tkinterdnd2"

    def _enable_drop(self) -> bool:
        """Register this window as a file drop target; ``False`` when unavailable.

        ``tkinterdnd2`` adds Tcl commands to the interpreter it created itself, so
        a plain ``CTk`` root cannot host them. The registration therefore fails
        gracefully and the button/paste paths — which need no extra package —
        remain the supported route.
        """
        if not HAS_DND:
            return False
        try:
            widget = self._grid  # type: ignore[attr-defined]
            widget.drop_target_register(DND_FILES)  # type: ignore[attr-defined]
            widget.dnd_bind("<<Drop>>", self._on_drop)  # type: ignore[attr-defined]
            return True
        except Exception:
            logger.info("gallery: drag-and-drop unavailable on this root", exc_info=True)
            return False

    # ---------------------------------------------------------------- behaviour

    def reload(self) -> None:
        """Re-read the library and redraw; the single refresh entry point."""
        if self._closed:
            return
        try:
            rows = self._store.list()
        except Exception:  # pragma: no cover - a broken disk must not kill the window
            logger.exception("gallery: listing the library failed")
            rows = []
        self._rows = {str(row["image_id"]): row for row in rows}
        self._order = [str(row["image_id"]) for row in rows]
        self._render()

    def _on_changed(self, **_payload: object) -> None:
        """``GALLERY_CHANGED`` handler: bus events may arrive off the Tk thread."""
        self._marshal(self.reload)

    def _marshal(self, action: Callable[[], None]) -> None:
        try:
            self._window.after(0, action)
        except Exception:  # pragma: no cover - window already destroyed
            logger.debug("gallery: marshal failed", exc_info=True)

    def paste_from_clipboard(self) -> dict | None:
        """``Ctrl+V``: store the clipboard image; failures become a status line.

        Never raises — a clipboard read can fail because another process holds it,
        and a traceback on a keystroke would look like a crash.
        """
        image = image_from_clipboard()
        if image is None:
            self._set_message("The clipboard does not contain an image")
            return None
        return self._store_pil(image, source=SOURCE_PASTE, title="Pasted image")

    def add_from_file(self) -> dict | None:
        """File picker fallback for when drag-and-drop is unavailable."""
        try:
            from tkinter import filedialog

            chosen = filedialog.askopenfilename(
                parent=self._window,
                title="Add image to library",
                filetypes=[
                    ("Images", "*.png *.jpg *.jpeg *.gif *.bmp *.webp *.tif *.tiff"),
                    ("All files", "*.*"),
                ],
            )
        except Exception:  # pragma: no cover - dialog unavailable
            logger.exception("gallery: file dialog failed")
            return None
        if not chosen:
            return None
        return self.add_path(chosen)

    def add_path(self, path: str | os.PathLike[str]) -> dict | None:
        try:
            row = self._store.import_file(path, source=SOURCE_DROP)
        except Exception as exc:
            self._set_message(f"Could not add {Path(str(path)).name}: {exc}")
            return None
        self._after_change(row)
        return row

    def _on_drop(self, event: Any) -> None:
        payload = getattr(event, "data", "")
        for path in parse_drop_paths(payload):
            if is_image_path(path):
                self.add_path(path)
        self.reload()

    def _store_pil(self, image: Image.Image, *, source: str, title: str) -> dict | None:
        """Encode a PIL image to PNG bytes and store it."""
        import io

        buffer = io.BytesIO()
        try:
            image.convert("RGBA").save(buffer, format="PNG")
        except Exception as exc:  # pragma: no cover - exotic modes
            self._set_message(f"Could not encode the image: {exc}")
            return None
        try:
            row = self._store.add(
                buffer.getvalue(), title=title, filename=f"{title}.png", source=source
            )
        except (ValueError, OSError) as exc:
            self._set_message(f"Could not store the image: {exc}")
            return None
        self._after_change(row)
        return row

    def _after_change(self, row: dict) -> None:
        """Announce a local change so the tablet is told as well."""
        self._set_message(f"Added “{row.get('title', 'image')}”")
        # The sync layer listens for this and pushes GALLERY_LIST; emitting it
        # here (rather than pushing directly) keeps one notification path.
        self._bus.emit(GALLERY_CHANGED, reason="added", image_id=row.get("image_id"))
        self.reload()

    def download(self, image_id: str) -> Path | None:
        """Save-as for one card; a cancelled dialog is not an error."""
        row = self._rows.get(image_id)
        if row is None:
            self._set_message("That image is no longer in the library")
            return None
        try:
            from tkinter import filedialog

            destination = filedialog.asksaveasfilename(
                parent=self._window,
                title="Save image",
                initialfile=suggested_save_name(row),
                defaultextension=Path(suggested_save_name(row)).suffix or ".png",
            )
        except Exception:  # pragma: no cover - dialog unavailable
            logger.exception("gallery: save dialog failed")
            return None
        if not destination:
            return None
        try:
            saved = self._store.save_as(image_id, destination)
        except Exception as exc:
            self._set_message(f"Could not save the image: {exc}")
            return None
        self._set_message(f"Saved to {saved}")
        return saved

    def copy_to_clipboard(self, image_id: str) -> bool:
        """``CF_DIB`` copy; a failure is reported, never raised."""
        data = self._store.read_bytes(image_id)
        if data is None:
            self._set_message("That image's file is missing")
            return False
        try:
            import io

            with Image.open(io.BytesIO(data)) as image:
                copy_image_to_clipboard(image)
        except ClipboardError as exc:
            self._set_message(str(exc))
            return False
        except Exception as exc:  # pragma: no cover - decode failures
            logger.exception("gallery: copy failed")
            self._set_message(f"Could not copy the image: {exc}")
            return False
        self._set_message("Copied to the clipboard — paste it into any app")
        return True

    def delete(self, image_id: str) -> bool:
        row = self._rows.get(image_id)
        if row is None:
            return False
        removed = self._store.remove(image_id)
        if removed:
            self._bus.emit(GALLERY_CHANGED, reason="removed", image_id=image_id)
            self.reload()
        return removed

    # ------------------------------------------------------------------ render

    def _on_grid_configure(self, event: Any) -> None:
        columns = grid_columns(getattr(event, "width", 0) or 0)
        if columns == self._columns:
            return
        self._columns = columns
        self._render()

    def _render(self) -> None:
        if self._closed:
            return
        try:
            self._count_label.configure(
                text=(
                    f"{len(self._order)} image{'s' if len(self._order) != 1 else ''}"
                    if self._order
                    else "No images yet"
                )
            )
            if self._order:
                self._empty.pack_forget()
            else:
                self._empty.pack(fill="x", pady=8)
            for stale in list(self._cards):
                if stale not in self._rows:
                    self._cards.pop(stale).destroy()
            for index, image_id in enumerate(self._order):
                card = self._cards.get(image_id)
                if card is None:
                    card = self._build_card(self._rows[image_id])
                    self._cards[image_id] = card
                card.grid(
                    row=index // max(self._columns, 1),
                    column=index % max(self._columns, 1),
                    padx=6,
                    pady=6,
                )
                self._ensure_thumbnail(image_id)
        except Exception:  # pragma: no cover - a UI error must not kill the app
            logger.debug("gallery: render failed", exc_info=True)

    def _build_card(self, row: dict) -> ctk.CTkFrame:
        image_id = str(row["image_id"])
        card = ctk.CTkFrame(self._grid, width=_CARD_PX, fg_color=_CARD_BG)
        holder = ctk.CTkLabel(
            card, text="", width=_THUMB_PX, height=_THUMB_PX, fg_color=_THUMB_BG
        )
        holder.pack(padx=8, pady=(8, 4))
        title = ctk.CTkLabel(
            card,
            text=_elide(str(row.get("title") or image_id), 22),
            anchor="w",
            justify="left",
            wraplength=_CARD_PX - 20,
        )
        title.pack(fill="x", padx=8)
        meta = ctk.CTkLabel(
            card,
            text=format_dimensions(row.get("width"), row.get("height")),
            anchor="w",
            text_color=_META_TEXT,
        )
        meta.pack(fill="x", padx=8, pady=(0, 4))
        buttons = ctk.CTkFrame(card, fg_color="transparent")
        buttons.pack(fill="x", padx=8, pady=(0, 8))
        ctk.CTkButton(
            buttons, text="Download", width=84, command=lambda: self.download(image_id)
        ).pack(side="left")
        ctk.CTkButton(
            buttons,
            text="Copy",
            width=60,
            command=lambda: self.copy_to_clipboard(image_id),
        ).pack(side="right")
        return card

    def _ensure_thumbnail(self, image_id: str) -> None:
        """Decode a thumbnail off the Tk thread, then swap it in on ``after(0)``.

        Decoding on the Tk thread would stall the window for every large
        screenshot in the grid, which reads as a freeze on open.
        """
        if image_id in self._images or image_id in self._thumb_future_images:
            return
        row = self._rows.get(image_id)
        if row is None:
            return
        path = self._store.path_for(row)
        self._thumb_future_images[image_id] = None  # placeholder marker

        def work() -> None:
            try:
                image = self._load_thumbnail(path, _THUMB_PX)
            except Exception:  # pragma: no cover - unreadable file
                logger.debug("gallery: thumbnail failed for %s", path, exc_info=True)
                image = None
            self._marshal(lambda: self._apply_thumbnail(image_id, image))

        try:
            self._pool.submit(work)
        except RuntimeError:  # pragma: no cover - pool already shut down
            self._thumb_future_images.pop(image_id, None)

    def _apply_thumbnail(self, image_id: str, image: Any) -> None:
        self._thumb_future_images.pop(image_id, None)
        if self._closed or image is None:
            return
        card = self._cards.get(image_id)
        if card is None:
            return
        try:
            holder = card.winfo_children()[0]
            photo = ctk.CTkImage(
                light_image=image, dark_image=image, size=(_THUMB_PX, _THUMB_PX)
            )
            # Keep the CTkImage alive: Tk drops a PhotoImage that Python
            # garbage-collects and the card would go blank on the next redraw.
            self._images[image_id] = photo
            while len(self._images) > _LRU_CAP:
                self._images.popitem(last=False)
            holder.configure(image=photo, text="")
        except Exception:  # pragma: no cover - widget destroyed mid-flight
            logger.debug("gallery: applying a thumbnail failed", exc_info=True)

    def _set_message(self, text: str) -> None:
        try:
            self._status.configure(text=text)
        except Exception:  # pragma: no cover - window already destroyed
            logger.debug("gallery: status update failed", exc_info=True)

    # ---------------------------------------------------------- test-only view

    @property
    def order(self) -> list[str]:
        """Image ids in display order (newest first)."""
        return list(self._order)

    @property
    def card_count(self) -> int:
        return len(self._cards)


def _pil_thumbnail(path: Path, size: int) -> Image.Image | None:
    """Decode ``path`` into a square-ish RGB thumbnail of at most ``size`` px."""
    with Image.open(path) as image:
        image.load()
        thumb = image.convert("RGBA")
        thumb.thumbnail((size, size))
        canvas = Image.new("RGB", (size, size), (60, 60, 60))
        canvas.paste(
            thumb,
            ((size - thumb.width) // 2, (size - thumb.height) // 2),
            thumb,
        )
        return canvas


def _elide(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: max(limit - 1, 0)] + "…"


__all__ = [
    "GalleryWindow",
    "HAS_DND",
    "format_dimensions",
    "grid_columns",
    "is_image_path",
    "parse_drop_paths",
    "suggested_save_name",
]
