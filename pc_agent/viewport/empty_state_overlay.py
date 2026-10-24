"""Empty-workspace hint for the PC viewport (round 7, issue 02).

A freshly launched PC agent has no document, no device and no artboard. The
GL surface already clears to :data:`~pc_agent.viewport.gl_canvas_host
.EMPTY_STATE_BG` instead of white, but a plain grey rectangle still does not
tell the user *why* nothing is there.

``EmptyStateOverlay`` owns the small centred Tk label that explains it ("No
canvas open — pair a device…"). It is a sibling of the GL label inside the
viewport frame, stays hidden as soon as a document is loaded, and is
deliberately dependency-free so the host can build it without touching GL.
"""

from __future__ import annotations

import logging
import tkinter as tk

logger = logging.getLogger(__name__)

_BG = "#3A3D42"
_FG = "#C7CBD1"
_FONT = ("Segoe UI", 12)


class EmptyStateOverlay:
    """Centred hint label shown while the viewport has no document."""

    def __init__(self, parent: tk.Misc, text: str, bg: str = _BG) -> None:
        self._label = tk.Label(
            parent,
            text=text,
            bg=bg,
            fg=_FG,
            font=_FONT,
            justify="center",
            bd=0,
            wraplength=420,
        )
        self._visible = False
        self.show()

    @property
    def widget(self) -> tk.Label:
        return self._label

    @property
    def visible(self) -> bool:
        return self._visible

    def show(self) -> None:
        """Place the hint centred over the viewport (idempotent)."""
        if self._visible:
            return
        try:
            self._label.place(relx=0.5, rely=0.5, anchor="center")
        except tk.TclError:  # widget destroyed mid-teardown
            logger.debug("empty-state placement failed", exc_info=True)
            return
        self._visible = True
        try:
            self._label.lift()
        except tk.TclError:
            pass

    def hide(self) -> None:
        """Remove the hint once real content exists (idempotent)."""
        if not self._visible:
            return
        try:
            self._label.place_forget()
        except tk.TclError:
            logger.debug("empty-state hide failed", exc_info=True)
        self._visible = False

    def set_visible(self, visible: bool) -> None:
        self.show() if visible else self.hide()

    def destroy(self) -> None:
        try:
            self._label.destroy()
        except tk.TclError:  # already gone
            pass
        self._visible = False
