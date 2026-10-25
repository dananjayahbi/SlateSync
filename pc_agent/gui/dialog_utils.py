"""Round-12 issue 10 — every PC popup must open ABOVE the studio window.

Report: "in the PC agent, when we open its popups, it initially displays them
behind the main window."

Cause: a `CTkToplevel` created with only a parent path does not tell the window
manager it belongs to that parent. Tk has no `parent=` ownership for toplevels;
ownership is expressed by ``transient()``, and stacking is only guaranteed once
the dialog is also raised and given focus. Several dialogs here were created
bare (only the QR dialog was ever lifted, and nothing called ``transient`` or
``grab_set``).

Rather than fix each call site and hope the next popup remembers, every dialog
goes through :func:`present_dialog` / :func:`prepare_dialog`. The module is
Tk-only and imports customtkinter lazily so it stays importable headless.
"""

from __future__ import annotations

import logging
import tkinter as tk
from typing import Any

logger = logging.getLogger(__name__)

#: Delay before the raise runs. Windows sometimes ignores a `lift()` issued
#: before the window is mapped, so the raise is repeated on the next idle turn.
_RAISE_DELAY_MS = 10


def _owner(window: Any) -> Any:
    """The main window that should own ``window``."""
    try:
        return window.winfo_toplevel().master or window.winfo_toplevel()
    except Exception:  # pragma: no cover - defensive
        return None


def prepare_dialog(dialog: Any, parent: Any, *, modal: bool = True) -> None:
    """Make ``dialog`` a proper child of ``parent`` and raise it.

    * ``transient`` ties it to the parent so the WM keeps it on top and
      minimises it with the app;
    * ``grab_set`` makes it modal (the user must answer it);
    * ``lift`` + ``focus_force`` put it in front immediately.

    Safe to call on an already-mapped dialog (it is then just a re-raise).
    """
    try:
        dialog.transient(parent)
    except Exception:  # pragma: no cover - defensive
        logger.debug("transient() failed", exc_info=True)
    if modal:
        try:
            dialog.grab_set()
        except Exception:  # pragma: no cover - defensive
            logger.debug("grab_set() failed", exc_info=True)
    raise_dialog(dialog)


def raise_dialog(dialog: Any, *, delay_ms: int = _RAISE_DELAY_MS) -> None:
    """Bring an existing dialog to the front (now, and once more after mapping)."""
    def _raise() -> None:
        try:
            dialog.lift()
            dialog.focus_force()
        except Exception:  # pragma: no cover - defensive
            logger.debug("raise failed", exc_info=True)

    _raise()
    try:
        dialog.after(delay_ms, _raise)
    except Exception:  # pragma: no cover - defensive
        pass


def present_dialog(
    dialog: Any,
    parent: Any,
    *,
    modal: bool = True,
    center: bool = True,
) -> None:
    """Full presentation: own it, optionally centre it, raise it."""
    if center:
        center_on_parent(dialog, parent)
    prepare_dialog(dialog, parent, modal=modal)


def center_on_parent(dialog: Any, parent: Any) -> None:
    """Place ``dialog`` over the middle of ``parent`` (best effort)."""
    try:
        dialog.update_idletasks()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        dw, dh = dialog.winfo_reqwidth(), dialog.winfo_reqheight()
        if pw <= 1 or ph <= 1 or dw <= 1 or dh <= 1:
            return  # not laid out yet; the geometry manager wins
        x = px + max(0, (pw - dw) // 2)
        y = py + max(0, (ph - dh) // 3)
        dialog.geometry(f"+{x}+{y}")
    except Exception:  # pragma: no cover - defensive
        logger.debug("centre failed", exc_info=True)


def release_dialog(dialog: Any) -> None:
    """Drop the modal grab before destroying a dialog (Tk leaves it dangling)."""
    try:
        dialog.grab_release()
    except Exception:  # pragma: no cover - defensive
        pass


def make_toplevel(parent: Any, title: str) -> Any:
    """Create a customtkinter toplevel already owned by ``parent``.

    Every popup should be created through this so ownership cannot be forgotten.
    """
    import customtkinter as ctk

    dialog = ctk.CTkToplevel(parent)
    dialog.title(title)
    dialog.withdraw()  # avoid the "flash at 0,0 then jump" on Windows
    return dialog


def show_toplevel(dialog: Any, parent: Any, *, modal: bool = True) -> None:
    """Map a dialog created by :func:`make_toplevel`."""
    try:
        dialog.deiconify()
    except Exception:  # pragma: no cover - defensive
        pass
    prepare_dialog(dialog, parent, modal=modal)


def messagebox_parent(parent: Any) -> dict[str, Any]:
    """Keyword args binding a ``tkinter.messagebox`` call to ``parent``.

    ``messagebox.showinfo`` without ``parent`` attaches to the default root,
    which is how those boxes ended up behind the studio window.
    """
    return {"parent": parent} if parent is not None else {}


def is_toplevel(widget: Any) -> bool:
    try:
        return isinstance(widget, (tk.Toplevel,)) or widget.winfo_class() == "Toplevel"
    except Exception:  # pragma: no cover - defensive
        return False
