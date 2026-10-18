"""pystray system-tray background daemon for the PC agent (Doc 17, §4 freeze).

Runs the tray icon loop in a daemon thread with a runtime-generated PIL icon
(rounded square + stylus glyph), a Show Studio / Quit menu, balloon
notifications, and a throttled ``LIVE_FRAME`` auto-foreground trigger.

This module performs zero Tk calls: ``on_show`` / ``on_quit`` are injected by
``main.py`` (wired to Doc 16 ``StudioWindow.show`` and graceful teardown);
every Tk write is marshalled behind those callables.
"""

from __future__ import annotations

import threading
import time
from typing import Callable, NamedTuple

import pystray
from PIL import Image, ImageDraw

from pc_agent.core.events import LIVE_FRAME, EventBus

_BASE_PX = 48  # rounded-square canvas; 16/32 downsampled for Windows shell sizes
_THROTTLE_S = 1.0  # on_show fires at most once per 1.0 s (60 Hz stream ⇒ ≤1 raise/s)
_JOIN_TIMEOUT_S = 2.0  # stop() join budget (template §4 / Wave 2.A contract)


class ImageAsset(NamedTuple):
    """Stylus-glyph tray icon at the Windows shell sizes 16/32/48 (Doc 17 §4)."""

    size16: Image.Image
    size32: Image.Image
    size48: Image.Image


class TrayDaemon:
    """System-tray presence: pystray loop in a daemon thread (Doc 17 §4).

    Lifecycle: *created* (no thread, no pystray icon) → *bound* (``bind_bus``)
    → *running* (``start``) → *stopped* (``stop``; ``start`` may run again).
    ``start()`` and ``stop()`` are idempotent; ``stop()`` never joins the
    caller's thread and always respects the 2 s budget.
    """

    def __init__(self, on_show: Callable[[], None], on_quit: Callable[[], None]) -> None:
        self._on_show = on_show
        self._on_quit = on_quit
        self._running = False
        self._icon: pystray.Icon | None = None
        self._thread: threading.Thread | None = None
        self._bus: EventBus | None = None
        self._subscribed = False
        self._asset: ImageAsset | None = None
        self._last_fire = float("-inf")
        self._clock: Callable[[], float] = time.monotonic  # test-patchable

    # ------------------------------------------------------------------ icon
    def _build_image(self) -> ImageAsset:
        """48×48 RGBA rounded square + stylus glyph; 16/32 nearest-neighbour copies."""
        base = Image.new("RGBA", (_BASE_PX, _BASE_PX), (0, 0, 0, 0))
        draw = ImageDraw.Draw(base)
        draw.rounded_rectangle((0, 0, 47, 47), radius=10, fill=(28, 31, 38, 255))
        # stylus: light diagonal body (upper-right) + nib triangle (lower-left)
        draw.line((33, 13, 16, 30), fill=(236, 240, 246, 255), width=5)
        draw.polygon([(11, 37), (17, 37), (14, 31)], fill=(236, 240, 246, 255))
        return ImageAsset(
            size16=base.resize((16, 16), Image.Resampling.NEAREST),
            size32=base.resize((32, 32), Image.Resampling.NEAREST),
            size48=base,
        )

    def _build_menu(self) -> pystray.Menu:
        """Exactly two items — Show Studio (default double-click) / Quit (§1)."""
        return pystray.Menu(
            pystray.MenuItem("Show Studio", self._handle_show, default=True),
            pystray.MenuItem("Quit", self._handle_quit),
        )

    def _ensure_icon(self) -> pystray.Icon:
        """Lazily compose the pystray icon (called from ``start()`` only)."""
        if self._icon is None:
            if self._asset is None:
                self._asset = self._build_image()
            self._icon = pystray.Icon(
                "SlateSync",
                icon=self._asset.size48,
                title="SlateSync",
                menu=self._build_menu(),
            )
        return self._icon

    # -------------------------------------------------------------- lifecycle
    def start(self) -> None:
        """Run the pystray loop on daemon thread ``SlateSyncTray`` (§5.5)."""
        if self._running:
            return
        icon = self._ensure_icon()
        if self._bus is not None and not self._subscribed:
            self._bus.on(LIVE_FRAME, self._on_live_frame)  # re-arm after stop() unbound it
            self._subscribed = True
        self._thread = threading.Thread(target=icon.run, name="SlateSyncTray", daemon=True)
        self._thread.start()
        self._running = True

    def stop(self) -> None:
        """Stop the loop and join within ≤2 s; idempotent (§5.6)."""
        if not self._running:
            return
        if self._icon is not None:
            self._icon.stop()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=_JOIN_TIMEOUT_S)
        self._running = False
        if self._bus is not None and self._subscribed:
            self._bus.off(LIVE_FRAME, self._on_live_frame)
            self._subscribed = False

    def notify(self, title: str, message: str) -> None:
        """Raise a native Windows balloon; guarded no-op when not running (§5.7)."""
        if not self._running or self._icon is None:
            return
        self._icon.notify(message, title)

    # ------------------------------------------------------------------- bus
    def bind_bus(self, bus: EventBus) -> None:
        """Register the single ``LIVE_FRAME`` auto-foreground handler (§5.8)."""
        self._bus = bus
        bus.on(LIVE_FRAME, self._on_live_frame)  # handler fires on the WS thread (Doc 11)
        self._subscribed = True

    def _on_live_frame(self, frame: object | None = None) -> None:
        """Throttled raise: ``on_show`` at most once per 1.0 s (§5.9)."""
        now = self._clock()
        if now - self._last_fire >= _THROTTLE_S:
            self._last_fire = now
            self._on_show()  # → StudioWindow.show: deiconify + lift (Doc 16)

    # -------------------------------------------------------- menu callbacks
    def _handle_show(self, *_args: object) -> None:
        self._on_show()

    def _handle_quit(self, *_args: object) -> None:
        self._on_quit()  # teardown order stays in main.py (§5.10)
