"""Dark-mode CustomTkinter desktop shell of the PC agent (Doc 16 §4 freeze).

Layout: TOP HUD (connection badge / zoom / artboard preset / QR button),
LEFT gallery strip (Issue 07-PC thumbnail cards, docked col 0, hidden until
paired),
CENTER OpenGL viewport via Doc 06 ``GLCanvasHost.mount``, BOTTOM export bar
(format/DPI/target combos, Start, progress, Open-in-Explorer) plus the
File/View/Help menu. Export execution reaches Doc 15 **only** through the
injected ``export_submit`` callable — this module never imports the exporter.

``EventBus.emit`` runs synchronously on the caller's (WS/worker) thread, so
every bus handler is a single forward through ``self.after(0, …)`` and every
widget mutation runs on the Tk thread (see ``after`` for the off-thread
marshalling detail).
"""

from __future__ import annotations

import logging
import os
import sys
import threading
import time
import tkinter as tk
import uuid
from collections import deque
from pathlib import Path
from tkinter import filedialog, messagebox
from typing import TYPE_CHECKING, Callable

import customtkinter as ctk
from PIL import Image

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    DEVICES_UPDATED,
    DOCUMENT_LOADED,
    EXPORT_FINISHED,
    EXPORT_PROGRESS,
    EXPORT_STARTED,
    MIRROR_CHANGED,
    PAIRING_INFO,
    EventBus,
)
from pc_agent.gui import dialog_utils, pairing_status
from pc_agent.gui.canvas_gallery_panel import CanvasGalleryPanel
from pc_agent.gui.ocr_jobs_panel import OcrJobsPanel
from pc_agent.gui.settings_panel import SettingsPanel

if TYPE_CHECKING:  # Doc 06 GLCanvasHost — consumed, never redefined
    from pc_agent.viewport.gl_canvas_host import GLCanvasHost

logger = logging.getLogger(__name__)

# Badge states (Doc 16 §4): CONNECTED green | WAITING grey | ERROR red
_CONNECTED_BG = "#2ECC71"
_WAITING_BG = "#9E9E9E"
_ERROR_BG = "#E74C3C"

_ZOOM_MIN, _ZOOM_MAX = 0.05, 20.0  # template §3 zoom range
_POLL_MS = 10  # Tk-thread poller cadence for off-thread after() requests
_DRAG_CLEAR_MS = 300  # Issue 04: silence window this long after the last move

# Issue 04 round 3 (window layout): Tk's default toplevel is ~200×200 and the
# HUD + export bar eat ~100 px, so the mirror opened as a "thin row" — and the
# legacy SetParent child window (see Doc 06 header) broke native resize, so the
# user could never fix it. build() applies this default geometry + minsize
# (wiring point chosen here, in StudioWindow.build, so run_full and the tests
# share the same guarantee); size-only geometry preserves a caller-set +x+y.
_DEFAULT_GEOMETRY = "1280x800"
_DEFAULT_MINSIZE = (800, 560)

_ASSET_NAMES = ("slatesync.ico", "slatesync_64.png")  # Issue 06 branding


def _branding_asset(name: str) -> Path | None:
    """Resolve ``pc_agent/assets/<name>`` for source and frozen (onedir) runs.

    Source: repo-relative next to this package. Frozen (PyInstaller): datas are
    collected under ``pc_agent/assets`` inside ``_internal/`` (next to the
    exe) or inside ``sys._MEIPASS`` (onefile / `_internal` prefix), so both
    layouts are probed in order. ``None`` when the asset is absent — callers
    fall back instead of raising.
    """
    if getattr(sys, "frozen", False):  # pragma: no cover - exercised in bundles
        exe_dir = Path(sys.executable).resolve().parent
        candidates = [
            Path(getattr(sys, "_MEIPASS", exe_dir)) / "pc_agent" / "assets" / name,
            exe_dir / "_internal" / "pc_agent" / "assets" / name,
            exe_dir / "pc_agent" / "assets" / name,
        ]
    else:
        candidates = [Path(__file__).resolve().parent.parent / "assets" / name]
    for candidate in candidates:
        try:
            if candidate.is_file():
                return candidate
        except OSError:  # pragma: no cover - unreadable mount
            continue
    return None


def _move_loop_active() -> bool:
    """Issue 04: ``True`` while Win32's modal move/size loop runs on this thread.

    The 10 ms poller, the GL pump and queued ``show`` callbacks all execute
    *inside* the native drag (Tk enables ``Tcl_SetServiceMode(TCL_SERVICE_ALL)``
    on ``WM_ENTERSIZEMOVE``), so ``deiconify``+``lift`` (a ``SetWindowPos``)
    landing mid-loop cancels the move and Windows rolls the window back to its
    original position. ``GetGUIThreadInfo`` exposes the loop directly via
    ``hwndMoveSize`` — including the press-and-hold phase before any
    ``<Configure>`` position change fires.
    """
    try:
        import ctypes
        from ctypes import wintypes as _wt

        class _GTI(ctypes.Structure):
            _fields_ = [
                ("cbSize", ctypes.c_uint),
                ("flags", ctypes.c_uint),
                ("hwndActive", _wt.HWND),
                ("hwndFocus", _wt.HWND),
                ("hwndCapture", _wt.HWND),
                ("hwndMenuOwner", _wt.HWND),
                ("hwndMoveSize", _wt.HWND),
                ("hwndCaret", _wt.HWND),
                ("rcCaret", _wt.RECT),
            ]

        g = _GTI()
        g.cbSize = ctypes.sizeof(_GTI)
        tid = ctypes.windll.kernel32.GetCurrentThreadId()
        if not ctypes.windll.user32.GetGUIThreadInfo(tid, ctypes.byref(g)):
            return False
        return bool(g.hwndMoveSize)
    except Exception:  # pragma: no cover - non-Windows / ctypes failure
        return False


class StudioWindow:
    """Doc 16 frozen shell: ``build/show/hide/set_connection_state/open_qr_dialog/
    update_hud/on_live_activity`` + ``bind_actions`` (§4)."""

    def __init__(
        self,
        config: AppConfig,
        bus: EventBus,
        gl_host: "GLCanvasHost",
        export_submit: Callable[[dict], str],
        open_request: Callable[[str], None] | None = None,
        *,
        thumbnail_fn: Callable[[dict, Path, int], object] | None = None,
        thumbs_dir: str | Path | None = None,
        canvases_dir: str | Path | None = None,
        select_mirror: Callable[[str | None], object] | None = None,
        rotate_pairing: Callable[[], object] | None = None,
        set_export_dir: Callable[[Path], object] | None = None,
        ocr_cancel: Callable[[str], object] | None = None,
    ) -> None:
        """``open_request`` (round 4, optional): injected File → "Open synced
        canvas…" callback wired by main.py to
        ``CanvasSyncManager.request_open(canvas_id)`` — the window only ever
        passes the picked id; the manager owns the wire envelope.

        ``thumbnail_fn`` / ``thumbs_dir`` / ``canvases_dir`` (Issue 07-PC,
        optional) forward to the gallery's §10.6 render pipeline — tests
        inject a fake renderer and isolated directories; main.py leaves all
        three ``None`` (lazy renderer import, ``%APPDATA%/SlateSync/thumbs``
        output, ``%APPDATA%/SlateSync/canvases`` archives).
        """
        self._config = config
        self._bus = bus
        self._gl_host = gl_host
        self._export_submit = export_submit
        self._ocr_cancel_hook = ocr_cancel
        self._open_request = open_request
        self._thumbnail_fn = thumbnail_fn
        self._thumbs_dir = thumbs_dir
        self._canvases_dir = canvases_dir
        #: Round 7 — Settings panel wiring (devices, mirror switch, export dir,
        #: pairing reset). All injected; the window never touches the hub.
        self._select_mirror = select_mirror
        self._rotate_pairing = rotate_pairing
        self._set_export_dir = set_export_dir
        self._settings: SettingsPanel | None = None
        self._ocr_jobs: OcrJobsPanel | None = None
        # Injected by main.py so this window never imports the OCR package
        # (keeps the GUI free of the model/runtime dependency).
        self._ocr_cancel_hook: Callable[[str], object] | None = None
        self._device_rows: list[dict] = []
        self._mirrored_canvas_id: str | None = None

        # Tk scaffolding — set by build(); None until then.
        self._root: tk.Misc | None = None
        self._parent: tk.Misc | None = None
        self._tk_ident: int | None = None
        # Off-thread after() requests, drained by the Tk-thread poller.
        self._pending: deque[tuple[int, Callable[..., None], tuple]] = deque()
        self._polling = False

        # Widget refs (Doc 16 §5.1)
        self._badge: ctk.CTkLabel | None = None
        self._zoom_label: ctk.CTkLabel | None = None
        self._preset_label: ctk.CTkLabel | None = None
        self._qr_btn: ctk.CTkButton | None = None
        self._settings_btn: ctk.CTkButton | None = None
        self._viewport: ctk.CTkFrame | None = None
        self._format_combo: ctk.CTkComboBox | None = None
        self._dpi_combo: ctk.CTkComboBox | None = None
        self._target_combo: ctk.CTkComboBox | None = None
        self._start_btn: ctk.CTkButton | None = None
        self._open_btn: ctk.CTkButton | None = None
        self._progress: ctk.CTkProgressBar | None = None
        self._menubar: tk.Menu | None = None

        # Issue 03-PC: left gallery strip (None until build(); hidden until
        # a device pairs AND the hub list is non-empty — Issue 02/03 spirit).
        self._gallery: CanvasGalleryPanel | None = None

        # Issue 02: pairing state driving the Pair / QR button visibility
        # (devices comes from CANVAS_LIST_UPDATED, connected from the badge
        # path — either signal alone hides the button).
        self._devices = 0
        self._connected = False

        # Issue 06: applied branding icon (for tests/diagnostics).
        self._icon_applied: str | None = None
        self._icon_photos: list[tk.PhotoImage] = []  # keep refs (Tk GC rule)

        # QR dialog state
        self._qr_dialog: ctk.CTkToplevel | None = None
        self._qr_image_label: ctk.CTkLabel | None = None
        self._qr_ip_label: ctk.CTkLabel | None = None
        self._qr_token_label: ctk.CTkLabel | None = None
        self._qr_hint_label: ctk.CTkLabel | None = None
        self._qr_status_label: ctk.CTkLabel | None = None
        self._qr_image: ctk.CTkImage | None = None

        # Round 4 (Doc 02 §8): cached tablet canvas list + picker dialog state.
        self._canvases: list[dict] = []
        self._sync_dialog: ctk.CTkToplevel | None = None
        self._sync_listbox: tk.Listbox | None = None

        # Data (Doc 16 §5.1)
        self._pairing: dict | None = None
        self._canvas_id: str | None = None
        #: Round 7: canvas title, used to name the exported file.
        self._canvas_title: str | None = None
        self._last_scale = 1.0
        self._last_raise = 0.0
        self._job_id: str | None = None
        self._last_path: str | None = None

        # Issue 04 drag guard: while the user is moving the window, the tray/
        # stylus auto-raise (deiconify+lift) must not fire — a SetWindowPos
        # mid-WM_ENTERSIZEMOVE aborts the native move loop and the window
        # snaps back to its original position.
        self._dragging = False
        self._drag_pos: tuple[int, int] | None = None
        self._drag_clear_id: str | None = None

        # Injected menu actions — unbound no-ops until main.py wires them.
        self._rpc: Callable[[dict], None] | None = None
        self._save: Callable[[], None] | None = None
        self._zoom_to_fit: Callable[[], None] | None = None

        # Template §4 event matrix (seven) + round-4 CANVAS_LIST_UPDATED (§8).
        self._subscriptions: list[tuple[str, Callable[..., None]]] = [
            (CONNECTION_STATE, self._on_connection_state),
            (DOCUMENT_LOADED, self._on_document_loaded),
            (ARTBOARD_CHANGED, self._on_artboard_changed),
            (EXPORT_STARTED, self._on_export_started),
            (EXPORT_PROGRESS, self._on_export_progress),
            (EXPORT_FINISHED, self._on_export_finished),
            (PAIRING_INFO, self._on_pairing_info),
            (CANVAS_LIST_UPDATED, self._on_canvas_list_updated),
            (DEVICES_UPDATED, self._on_devices_updated),
            (MIRROR_CHANGED, self._on_mirror_changed),
        ]
        for event, handler in self._subscriptions:
            bus.on(event, handler)

    # ------------------------------------------------------------------
    # Threading marshalling (§5.8: no widget mutation off the Tk thread)
    # ------------------------------------------------------------------
    def after(self, ms: int, func: Callable[..., None] | None = None, *args):
        """Schedule ``func(*args)`` on the Tk thread — the §5.8 forward.

        On the Tk thread this is a plain ``root.after(ms, …)``. Off it, a
        direct Tk call is unreliable in CPython (it raises ``RuntimeError:
        main thread is not in main loop`` — or blocks — unless the main
        thread happens to sit inside the Tcl event loop), so the request is
        queued and the Tk-thread poller re-posts it via ``root.after(0, …)``.
        Either way widget mutations never run on the WS/worker thread.
        """
        root = self._root
        if root is None or func is None:
            return None
        if self._tk_ident is not None and threading.get_ident() == self._tk_ident:
            return root.after(ms, func, *args)
        self._pending.append((ms, func, args))
        return None

    def _start_poller(self) -> None:
        """Arm the recurring Tk-thread drain of off-thread ``after`` requests."""
        root = self._root
        if root is None or self._polling:
            return
        self._polling = True
        root.after(_POLL_MS, self._poll_pending)

    def _poll_pending(self) -> None:
        root = self._root
        if root is None:
            self._polling = False
            return
        while True:
            try:
                ms, func, args = self._pending.popleft()
            except IndexError:
                break
            try:
                root.after(ms, func, *args)
            except Exception:  # destroyed root mid-drain — keep the poller benign
                logger.debug("re-post of after(%d) failed", ms, exc_info=True)
                break
        try:
            root.after(_POLL_MS, self._poll_pending)
        except Exception:
            self._polling = False  # root gone

    # ------------------------------------------------------------------
    # Frozen public API (template §4)
    # ------------------------------------------------------------------
    def build(self, parent: tk.Misc) -> None:
        """Grid the HUD / gallery / viewport / export bar + menu on ``parent``.

        Issue 03-PC: the gallery strip takes grid col 0 (fixed width, hidden
        until paired) and the Doc 06 viewport moves to col 1 — the center row
        keeps ``weight=1`` so the viewport still fills the window; HUD and
        export bar span both columns. Default geometry is unchanged.
        """
        if self._root is not None:
            return
        self._parent = parent
        self._root = parent.winfo_toplevel()
        self._tk_ident = threading.get_ident()
        self._root.title("SlateSync Studio")

        # Issue 04 round 3: usable default size + hard floor (see module
        # constants). Size-only geometry leaves any caller-set position intact.
        self._root.geometry(_DEFAULT_GEOMETRY)
        self._root.minsize(*_DEFAULT_MINSIZE)

        # Issue 04: track toplevel position changes → drag flag (child
        # <Configure> events share the toplevel's bindtag — filter them out).
        self._root.bind("<Configure>", self._on_position_configure, add="+")
        try:
            self._drag_pos = (self._root.winfo_x(), self._root.winfo_y())
        except Exception:  # pragma: no cover - root gone mid-build
            self._drag_pos = None

        # Issue 06: brand the window before it maps (see helper).
        self._apply_window_icon(self._root)

        parent.grid_columnconfigure(0, weight=0)  # gallery strip (fixed)
        parent.grid_columnconfigure(1, weight=1)  # viewport fills
        parent.grid_rowconfigure(1, weight=1)  # center row keeps the weight
        self._build_hud().grid(
            row=0, column=0, columnspan=2, sticky="ew", padx=8, pady=(8, 4)
        )
        self._gallery = CanvasGalleryPanel(
            parent,
            open_request=self._open_request,
            thumbnail_fn=self._thumbnail_fn,
            thumbs_dir=(
                self._thumbs_dir
                if self._thumbs_dir is not None
                else self._config.appdata_dir / "thumbs"
            ),
            canvases_dir=(
                self._canvases_dir
                if self._canvases_dir is not None
                else self._config.appdata_dir / "canvases"
            ),
        )
        self._gallery.mount(row=1, column=0, sticky="nsw", padx=(8, 0), pady=4)
        self._build_center().grid(
            row=1, column=1, sticky="nsew", padx=8, pady=4
        )
        self._build_export_bar().grid(
            row=2, column=0, columnspan=2, sticky="ew", padx=8, pady=(4, 8)
        )
        self._build_menu()
        self._refresh_pairing_affordance()
        self._start_poller()

    def show(self) -> None:
        """Deiconify + lift; self-marshalled when called from the tray thread."""
        self._marshal(self._show_impl)

    def hide(self) -> None:
        """Withdraw; self-marshalled when called from the tray thread."""
        self._marshal(self._hide_impl)

    # ------------------------------------------------------------------
    # Issue 06: real window logo (root + QR dialog)
    # ------------------------------------------------------------------
    def _apply_window_icon(self, window: tk.Misc) -> str | None:
        """Brand ``window`` with the SlateSync icon; returns "ico"/"png"/None.

        ``slatesync.ico`` is resolved repo-relative from source and from the
        PyInstaller bundle (``sys._MEIPASS`` / ``_internal/``) when frozen —
        see ``_branding_asset``. Falls back to ``wm iconphoto`` from the
        ``slatesync_64.png`` kept alongside the .ico when iconbitmap fails
        (e.g. non-Windows or a missing .ico). Any Tk error is swallowed: a
        missing brand asset must never break window construction.
        """
        # Hold the PhotoImage alive for the window's lifetime (Tk GC rule).
        def _photo(path: Path) -> tk.PhotoImage | None:
            try:
                image = tk.PhotoImage(file=str(path))
            except tk.TclError:
                logger.debug("iconphoto load failed for %s", path)
                return None
            self._icon_photos.append(image)
            return image

        ico = _branding_asset(_ASSET_NAMES[0])
        if ico is not None:
            try:
                window.iconbitmap(str(ico))  # CTk override sets its own flag too
                self._icon_applied = "ico"
                return "ico"
            except tk.TclError:
                logger.debug("iconbitmap failed for %s", ico)
        png = _branding_asset(_ASSET_NAMES[1])
        if png is not None:
            image = _photo(png)
            if image is not None:
                try:
                    window.tk.call("wm", "iconphoto", window, "-default", image)
                    self._icon_applied = "png"
                    return "png"
                except tk.TclError:
                    logger.debug("iconphoto failed for %s", png)
        self._icon_applied = None
        return None

    def set_connection_state(self, connected: bool, peer: str | None) -> None:
        """Badge flip: CONNECTED / WAITING / ERROR (colours per §4).

        Issue 02: also re-evaluates Pair / QR button visibility — the button is
        hidden while a connection is up (or the hub reports ``devices >= 1``)
        and shown again once nothing is paired.
        """
        if connected:
            text, colour = "CONNECTED", _CONNECTED_BG
        elif peer:
            text, colour = "ERROR", _ERROR_BG
        else:
            text, colour = "WAITING", _WAITING_BG
        self._connected = bool(connected)
        if self._badge is not None:
            self._badge.configure(text=text, fg_color=colour)
        self._refresh_pairing_affordance()

    def open_qr_dialog(self) -> None:
        """Raise the pairing dialog rendering PAIRING_INFO (§5.7)."""
        root = self._root
        if root is None:
            return
        dialog = self._qr_dialog
        if dialog is None or not dialog.winfo_exists():
            dialog = ctk.CTkToplevel(root)
            dialog.title("Pair with tablet")
            dialog.geometry("260x340")
            dialog.resizable(False, False)
            dialog.protocol("WM_DELETE_WINDOW", self._close_qr_dialog)
            # Issue 06: brand the Toplevel (Tk usually inherits the owner's
            # icon, but apply explicitly so it is verifiable either way).
            self._apply_window_icon(dialog)
            self._qr_dialog = dialog
            self._qr_image_label = ctk.CTkLabel(dialog, text="")
            self._qr_image_label.pack(padx=20, pady=(20, 8))
            self._qr_ip_label = ctk.CTkLabel(dialog, text="")
            self._qr_ip_label.pack(pady=2)
            # Doc 12 extension: the address the QR advertises, then live
            # pairing progress — scanning used to give no feedback at all.
            self._qr_hint_label = ctk.CTkLabel(
                dialog, text=pairing_status.HINT_TEXT, wraplength=220, text_color="#8A8F98"
            )
            self._qr_hint_label.pack(pady=(0, 4))
            self._qr_status_label = ctk.CTkLabel(
                dialog, text=pairing_status.WAITING_TEXT, wraplength=220
            )
            self._qr_status_label.pack(pady=(0, 4))
            self._qr_token_label = ctk.CTkLabel(dialog, text="", wraplength=220)
            self._qr_token_label.pack(pady=(2, 12))
        self._render_qr()
        # Round-12 issue 10: own the dialog and raise it, or the WM may stack it
        # behind the studio window (the reported "popups open behind" defect).
        dialog_utils.present_dialog(dialog, root, modal=False)

    def update_hud(self, scale: float, preset: str) -> None:
        """Zoom ``%`` (clamped 0.05–20.0) + artboard preset labels (§5.13)."""
        try:
            value = float(scale)
        except (TypeError, ValueError):
            value = self._last_scale
        value = max(_ZOOM_MIN, min(_ZOOM_MAX, value))
        self._last_scale = value
        if self._zoom_label is not None:
            self._zoom_label.configure(text=f"{value * 100:.0f}%")
        if self._preset_label is not None and preset:
            self._preset_label.configure(text=str(preset))

    def on_live_activity(self) -> None:
        """Tray auto-foreground target: at most one raise per ≥1 s (§5.13)."""
        now = time.monotonic()
        if now - self._last_raise < 1.0:
            return
        self._last_raise = now
        self.after(0, self._raise_window)

    def bind_actions(
        self,
        *,
        rpc: Callable[[dict], None],
        save: Callable[[], None],
        zoom_to_fit: Callable[[], None],
    ) -> None:
        """Wire the menu callbacks (§4 doc-specific API; main.py, Wave 3.A)."""
        self._rpc = rpc
        self._save = save
        self._zoom_to_fit = zoom_to_fit

    # ------------------------------------------------------------------
    # Component builders (§5.2)
    # ------------------------------------------------------------------
    def _build_hud(self) -> ctk.CTkFrame:
        hud = ctk.CTkFrame(self._parent)
        self._badge = ctk.CTkLabel(
            hud, text="WAITING", fg_color=_WAITING_BG, text_color="#FFFFFF",
            width=110, height=24, corner_radius=8,
        )
        self._badge.pack(side="left", padx=(8, 12), pady=6)
        self._zoom_label = ctk.CTkLabel(hud, text="100%")
        self._zoom_label.pack(side="left", padx=6, pady=6)
        self._preset_label = ctk.CTkLabel(hud, text="A4")
        self._preset_label.pack(side="left", padx=6, pady=6)
        self._qr_btn = ctk.CTkButton(
            hud, text="Pair / QR", width=110, command=self.open_qr_dialog
        )
        self._qr_btn.pack(side="right", padx=8, pady=6)
        self._settings_btn = ctk.CTkButton(
            hud, text="Settings", width=90, command=self.open_settings
        )
        self._settings_btn.pack(side="right", padx=(0, 4), pady=6)
        return hud

    def _build_center(self) -> ctk.CTkFrame:
        """Empty frame handed to Doc 06 (owns the 16 ms pump)."""
        frame = ctk.CTkFrame(self._parent)
        self._viewport = frame
        self._gl_host.mount(frame)
        return frame

    def _build_export_bar(self) -> ctk.CTkFrame:
        bar = ctk.CTkFrame(self._parent)
        self._format_combo = ctk.CTkComboBox(
            bar, values=["PNG", "JPG", "PDF"], width=90,
            command=self._on_format_change,
        )
        self._format_combo.pack(side="left", padx=(8, 6), pady=6)
        self._dpi_combo = ctk.CTkComboBox(bar, values=["300", "600", "1200"], width=80)
        self._dpi_combo.pack(side="left", padx=6, pady=6)
        self._target_combo = ctk.CTkComboBox(
            bar, values=["PC", "Tablet", "Both"], width=90
        )
        self._target_combo.pack(side="left", padx=6, pady=6)
        self._start_btn = ctk.CTkButton(
            bar, text="Start", width=90, state="disabled", command=self._on_start
        )
        self._start_btn.pack(side="left", padx=6, pady=6)
        self._progress = ctk.CTkProgressBar(bar, width=180)
        self._progress.set(0.0)
        self._progress.pack(side="left", padx=10, pady=6)
        self._open_btn = ctk.CTkButton(
            bar, text="Open in Explorer", width=130, state="disabled",
            command=self._on_open_explorer,
        )
        self._open_btn.pack(side="left", padx=(6, 8), pady=6)
        return bar

    def _build_menu(self) -> None:
        """File / View / Help menus on the CTk root (§5.12)."""
        menubar = tk.Menu(self._root)
        file_menu = tk.Menu(menubar, tearoff=0)
        file_menu.add_command(label="New…", command=self._menu_new)
        file_menu.add_command(label="Open synced canvas…", command=self._menu_open_synced)
        file_menu.add_command(label="Open local file…", command=self._menu_open)
        file_menu.add_separator()
        file_menu.add_command(label="Save", command=self._menu_save)
        menubar.add_cascade(label="File", menu=file_menu)
        view_menu = tk.Menu(menubar, tearoff=0)
        view_menu.add_command(label="Zoom to Fit", command=self._menu_zoom_to_fit)
        menubar.add_cascade(label="View", menu=view_menu)
        help_menu = tk.Menu(menubar, tearoff=0)
        help_menu.add_command(label="About", command=self._menu_about)
        menubar.add_cascade(label="Help", menu=help_menu)
        edit_menu = tk.Menu(menubar, tearoff=0)
        # Round 7: Settings lives on the menu bar so the device roster and the
        # export folder are always reachable (issue 03/04/05/07).
        edit_menu.add_command(label="Settings…", command=self._menu_settings)
        # Round-13 issue 02 — make the OCR queue observable from the PC itself.
        edit_menu.add_command(label="OCR Jobs…", command=self.open_ocr_jobs)
        menubar.insert_cascade(1, label="Tools", menu=edit_menu)
        self._root.configure(menu=menubar)
        self._menubar = menubar

    # ------------------------------------------------------------------
    # Bus handlers — single forwards; widget writes happen in _apply_* (§5.8)
    # ------------------------------------------------------------------
    def _on_connection_state(self, connected=None, peer=None, **_extra) -> None:
        self.after(0, self.set_connection_state, bool(connected), peer)

    def _on_document_loaded(self, doc=None, **_extra) -> None:
        self.after(0, self._apply_document_loaded, doc)

    def _on_artboard_changed(self, artboard=None, content_bounds=None, **_extra) -> None:
        self.after(0, self._apply_artboard_changed, artboard)

    def _on_export_started(self, **_extra) -> None:
        self.after(0, self._apply_export_started)

    def _on_export_progress(self, percent=0.0, **_extra) -> None:
        self.after(0, self._apply_export_progress, percent)

    def _on_export_finished(self, job_id=None, percent=0.0, path=None, ok=False, **_extra) -> None:
        self.after(0, self._apply_export_finished, path, bool(ok))

    def _on_pairing_info(
        self, ipv4=None, port=None, token=None, qr_png_path=None, **_extra
    ) -> None:
        self.after(0, self._apply_pairing_info, ipv4, port, token, qr_png_path)

    def _on_canvas_list_updated(self, canvases=None, devices=None, **_extra) -> None:
        # Frozen v2 payload (Doc 02 §9): {canvases, devices}. ``devices`` is
        # optional so older/no-device emits still land (Issue 02 default: none).
        self.after(0, self._apply_canvas_list, canvases, devices)

    def _on_devices_updated(
        self, devices=None, mirrored_canvas_id=None, count=None, **_extra
    ) -> None:
        """Round 7: live device roster from the hub (Settings panel)."""
        self.after(0, self._apply_devices_updated, devices, mirrored_canvas_id, count)

    def _on_mirror_changed(self, canvas_id=None, title=None, **_extra) -> None:
        """Round 7: the mirrored canvas changed (auto on first open, or Settings)."""
        self.after(0, self._apply_mirror_changed, canvas_id)

    # ------------------------------------------------------------------
    # Tk-thread appliers
    # ------------------------------------------------------------------
    def _apply_document_loaded(self, doc) -> None:
        canvas_id, preset = self._doc_view(doc)
        if canvas_id is not None:
            self._canvas_id = str(canvas_id)
        self._canvas_title = (
            str(doc.get("title")) if isinstance(doc, dict) and doc.get("title") else None
        )
        self.update_hud(1.0, preset)
        if self._start_btn is not None:
            self._start_btn.configure(state="normal")
        # Issue 03-PC: highlight the row for the canvas now open in the viewport.
        if self._gallery is not None:
            self._gallery.set_current(self._canvas_id)

    def _apply_artboard_changed(self, artboard) -> None:
        preset = self._preset_of(artboard)
        if preset:
            self.update_hud(self._last_scale, preset)
        # Artboard switches may follow a canvas swap — re-assert the highlight.
        if self._gallery is not None:
            self._gallery.set_current(self._canvas_id)

    def _apply_export_started(self) -> None:
        if self._progress is not None:
            self._progress.set(0.0)
        if self._start_btn is not None:
            self._start_btn.configure(state="disabled")

    def _apply_export_progress(self, percent) -> None:
        if self._progress is None:
            return
        try:
            fraction = float(percent) / 100.0
        except (TypeError, ValueError):
            return
        self._progress.set(max(0.0, min(1.0, fraction)))

    def _apply_export_finished(self, path, ok: bool) -> None:
        if path:
            self._last_path = path  # kept even when !ok; Open stays disabled (§5.10)
        if self._start_btn is not None and self._canvas_id:
            self._start_btn.configure(state="normal")
        if self._open_btn is not None:
            self._open_btn.configure(state="normal" if (ok and path) else "disabled")

    def _apply_pairing_info(self, ipv4, port, token, qr_png_path) -> None:
        self._pairing = {
            "ipv4": ipv4,
            "port": port,
            "token": token,
            "qr_png_path": qr_png_path,
        }
        dialog = self._qr_dialog
        if dialog is not None and dialog.winfo_exists():
            self._render_qr()  # re-render while open (§5.7)

    def _apply_canvas_list(self, canvases, devices=None) -> None:
        """Tk-thread cache of the hub's CANVAS_LIST rows (Doc 02 §8.1/§9).

        Issue 02/03-PC: store the frozen ``devices`` count (kept when absent)
        and refresh the Pair / QR visibility + gallery strip.
        """
        self._canvases = [dict(row) for row in canvases] if isinstance(canvases, list) else []
        if devices is not None:
            try:
                self._devices = int(devices)
            except (TypeError, ValueError):
                logger.warning("bad CANVAS_LIST_UPDATED devices=%r", devices)
        if self._gallery is not None:
            self._gallery.set_rows(self._canvases)
            self._gallery.set_current(self._canvas_id)
        self._refresh_pairing_affordance()

    def _apply_devices_updated(self, devices, mirrored_canvas_id, count=None) -> None:
        """Round 7: cache the roster and push it into the open Settings panel."""
        self._device_rows = (
            [dict(row) for row in devices] if isinstance(devices, list) else []
        )
        if isinstance(mirrored_canvas_id, str) and mirrored_canvas_id:
            self._mirrored_canvas_id = mirrored_canvas_id
        elif mirrored_canvas_id is None and not self._device_rows:
            self._mirrored_canvas_id = None
        if count is not None:
            try:
                self._devices = int(count)  # roster is authoritative for "paired"
            except (TypeError, ValueError):
                logger.warning("bad DEVICES_UPDATED count=%r", count)
        elif self._device_rows:
            self._devices = len(self._device_rows)
        panel = self._settings
        if panel is not None and panel.exists():
            panel.refresh_devices(self._device_rows, self._mirrored_canvas_id)
        self._refresh_pairing_affordance()
        self._refresh_pairing_status()  # QR dialog: "1 tablet connected."

    def _apply_mirror_changed(self, canvas_id) -> None:
        """Round 7: follow the hub's mirror choice (issue 07)."""
        self._mirrored_canvas_id = str(canvas_id) if canvas_id else None
        panel = self._settings
        if panel is not None and panel.exists():
            panel.refresh_devices(self._device_rows, self._mirrored_canvas_id)

    def open_settings(self) -> None:
        """Open (or raise) the PC Settings panel — devices/mirror/export folder."""
        root = self._root
        if root is None:
            return
        panel = self._settings
        if panel is not None and panel.exists():
            panel.window.lift()
            panel.refresh_devices(self._device_rows, self._mirrored_canvas_id)
            return
        self._settings = SettingsPanel(
            root,
            set_export_dir=self._set_export_dir,
            select_mirror=self._select_mirror,
            rotate_pairing=self._rotate_pairing,
            export_dir=self._config.export_dir,
            on_close=self._on_settings_closed,
        )
        self._settings.refresh_devices(self._device_rows, self._mirrored_canvas_id)

    def _on_settings_closed(self) -> None:
        self._settings = None

    def _menu_settings(self) -> None:
        self.open_settings()

    # ------------------------------------------------------------------
    # Round-13 issue 02 — OCR jobs window
    # ------------------------------------------------------------------
    def open_ocr_jobs(self) -> None:
        """Open (or raise) the OCR jobs window.

        Non-modal by design: an operator must be able to watch the agent while a
        scan runs, and a stuck job has to be cancellable from the machine that is
        actually doing the work.
        """
        panel = self._ocr_jobs
        if panel is not None and panel.exists():
            panel.show()
            return
        root = self._root
        if root is None:
            return
        self._ocr_jobs = OcrJobsPanel(
            root,
            self._bus,
            cancel=self._ocr_cancel,
            on_close=self._on_ocr_jobs_closed,
        )

    def _on_ocr_jobs_closed(self) -> None:
        self._ocr_jobs = None

    def _ocr_cancel(self, job_id: str) -> None:
        """Cancel an OCR job from the PC side.

        Emits the same bus message the tablet's CANCEL_OCR produces, so there is
        exactly one cancellation path to reason about.
        """
        cancel = self._ocr_cancel_hook
        if cancel is not None:
            cancel(job_id)

    # ------------------------------------------------------------------
    # Issue 02/03-PC pairing affordances
    # ------------------------------------------------------------------
    def _refresh_pairing_affordance(self) -> None:
        """Hide Pair / QR while paired; show/hide the gallery strip.

        Paired = ``devices >= 1`` (frozen CANVAS_LIST_UPDATED count) OR the
        connection badge says CONNECTED. The gallery needs paired AND a
        non-empty canvas list (unpaired/empty → hidden entirely).
        """
        paired = self._devices >= 1 or self._connected
        btn = self._qr_btn
        if btn is not None:
            try:
                managed = bool(btn.winfo_manager())
                if paired and managed:
                    btn.pack_forget()  # hidden while a device is paired
                elif not paired and not managed:
                    btn.pack(side="right", padx=8, pady=6)
            except tk.TclError:  # widget gone mid-teardown
                logger.debug("QR affordance refresh skipped", exc_info=True)
        if self._gallery is not None:
            self._gallery.set_visible(bool(paired and self._canvases))

    # ------------------------------------------------------------------
    # Export bar actions (§5.5–5.6, §5.11)
    # ------------------------------------------------------------------
    def _on_format_change(self, choice: str) -> None:
        if self._dpi_combo is None:
            return
        if choice == "PDF":
            self._dpi_combo.configure(state="disabled")  # vector → DPI n/a
        else:
            self._dpi_combo.configure(values=["300", "600", "1200"], state="normal")

    def _on_start(self) -> None:
        """Build the §4 EXPORT_JOB/START_EXPORT envelope → injected submit."""
        if not self._canvas_id or self._format_combo is None:
            return
        fmt = str(self._format_combo.get()).upper()
        dpi: int | None
        if fmt == "PDF":
            dpi = None  # vector
        else:
            try:
                dpi = int(str(self._dpi_combo.get()))
            except (TypeError, ValueError, AttributeError):
                dpi = 300
        target = {"PC": "PC", "Tablet": "TABLET", "Both": "BOTH"}.get(
            str(self._target_combo.get()) if self._target_combo else "PC", "PC"
        )
        env = self._rpc_envelope(
            "EXPORT_JOB", "START_EXPORT", self._canvas_id,
            {
                "format": fmt,
                "dpi": dpi,
                "target": target,
                # Round 7: name the file after the canvas so the user can find
                # it in the (Settings-selectable) export folder.
                "title": self._canvas_title or self._canvas_id,
            },
        )
        self._job_id = self._export_submit(env)
        if self._start_btn is not None:
            self._start_btn.configure(state="disabled")
        if self._progress is not None:
            self._progress.set(0.0)

    def _on_open_explorer(self) -> None:
        """Reveal EXPORT_FINISHED path in Windows Explorer (§5.11)."""
        path = self._last_path
        if not path or not hasattr(os, "startfile"):
            return
        try:
            os.startfile(path)  # opens Windows Explorer (frozen §5.11 behaviour)
        except OSError:
            logger.warning("os.startfile(%s) failed", path, exc_info=True)

    # ------------------------------------------------------------------
    # QR dialog internals (§5.7)
    # ------------------------------------------------------------------
    def _render_qr(self) -> None:
        label = self._qr_image_label
        ip_label = self._qr_ip_label
        token_label = self._qr_token_label
        if label is None or ip_label is None or token_label is None:
            return
        pairing = self._pairing
        if not pairing:
            label.configure(image=None, text="Waiting for pairing info…")
            ip_label.configure(text="")
            token_label.configure(text="")
            self._refresh_pairing_status()
            return
        path = pairing.get("qr_png_path")
        try:
            with Image.open(path) as src:
                pil = src.convert("RGBA")
            # Doc 16 writes CTkImage(pil_image=…); CustomTkinter 6 renamed the
            # single-image parameter to light_image/dark_image (same semantics).
            self._qr_image = ctk.CTkImage(
                light_image=pil, dark_image=pil, size=(220, 220)
            )
            label.configure(image=self._qr_image, text="")
        except (OSError, ValueError, TypeError):
            logger.warning("cannot render QR image %r", path, exc_info=True)
            self._qr_image = None
            label.configure(image=None, text="QR image unavailable")
        ip_label.configure(text=f"{pairing.get('ipv4')}:{pairing.get('port')}")
        token_label.configure(text=str(pairing.get("token") or ""))
        self._refresh_pairing_status()

    def _refresh_pairing_status(self) -> None:
        """Doc 12 extension — say out loud what pairing is waiting for.

        Scanning used to give no feedback ("it says nothing"), so the dialog
        now explains the state: waiting for a scan, how many tablets paired, or
        a warning when the advertised address is unreachable from another
        device.
        """
        status = self._qr_status_label
        if status is None:
            return
        ipv4 = (self._pairing or {}).get("ipv4")
        warning = pairing_status.reachability_warning(ipv4)
        hint = self._qr_hint_label
        if hint is not None:
            hint.configure(text=warning or pairing_status.HINT_TEXT)
        status.configure(text=pairing_status.device_count_text(self._devices))

    def _close_qr_dialog(self) -> None:
        dialog = self._qr_dialog
        self._qr_dialog = None
        if dialog is not None and dialog.winfo_exists():
            dialog.destroy()

    # ------------------------------------------------------------------
    # Menu actions (§5.12) — unbound callbacks are no-ops
    # ------------------------------------------------------------------
    def _menu_new(self) -> None:
        if self._rpc is None:
            return
        self._rpc(
            self._rpc_envelope(
                "CANVAS_LIFECYCLE", "OPEN_CANVAS", None,
                {"preset": "A4", "title": "Untitled"},
            )
        )

    def _menu_open(self) -> None:
        if self._rpc is None:
            return
        path = filedialog.askopenfilename(
            parent=self._root, filetypes=[("SlateSync document", "*.slatesync")]
        )
        if not path:
            return
        self._rpc(
            self._rpc_envelope(
                "CANVAS_LIFECYCLE", "OPEN_CANVAS", None, {"path": str(path)}
            )
        )

    def _menu_open_synced(self) -> None:
        """File → "Open synced canvas…" (Doc 02 §8.3 flow 3).

        Lists the cached CANVAS_LIST rows (`title · preset · updated`); picking
        one calls the injected ``open_request(canvas_id)`` (main.py wires it to
        ``CanvasSyncManager.request_open``, which pushes CANVAS_OPEN_REQUEST).
        An empty cache gets the connect hint instead of a dialog.
        """
        if self._root is None:
            return
        rows = self._canvases
        if not rows:
            messagebox.showinfo(
                "Open synced canvas",
                "Connect a tablet to browse its canvases",
                parent=self._root,
            )
            return
        if self._open_request is None:
            logger.warning("Open synced canvas: no open_request callback wired")
            return
        dialog = ctk.CTkToplevel(self._root)
        dialog.title("Open synced canvas")
        dialog.geometry("440x300")
        dialog.transient(self._root)
        dialog.protocol("WM_DELETE_WINDOW", self._close_sync_dialog)
        self._sync_dialog = dialog
        listbox = tk.Listbox(dialog, exportselection=False)
        for row in rows:
            listbox.insert(tk.END, self._canvas_row_label(row))
        listbox.pack(fill="both", expand=True, padx=12, pady=(12, 6))
        listbox.bind("<Double-Button-1>", lambda _event: self._confirm_sync_open())
        self._sync_listbox = listbox
        buttons = tk.Frame(dialog)
        buttons.pack(fill="x", padx=12, pady=(0, 12))
        tk.Button(buttons, text="Cancel", command=self._close_sync_dialog).pack(
            side="right", padx=(6, 0)
        )
        tk.Button(buttons, text="Open", command=self._confirm_sync_open).pack(
            side="right"
        )
        # Round-12 issue 10: present it above the studio window (modality is
        # taken while it is open, so the user answers it before continuing).
        dialog_utils.present_dialog(dialog, self._root)

    def _confirm_sync_open(self) -> None:
        """Dialog Open/double-click: hand the selected row's id to the manager."""
        dialog, listbox = self._sync_dialog, self._sync_listbox
        rows = self._canvases
        if dialog is None or not dialog.winfo_exists() or listbox is None:
            return
        selection = listbox.curselection()
        if not selection:
            return
        index = int(selection[0])
        if not 0 <= index < len(rows):
            return
        row = rows[index]
        canvas_id = row.get("id") or row.get("canvas_id")
        self._close_sync_dialog()
        if canvas_id and self._open_request is not None:
            self._open_request(str(canvas_id))

    def _close_sync_dialog(self) -> None:
        dialog = self._sync_dialog
        self._sync_dialog = None
        self._sync_listbox = None
        if dialog is not None and dialog.winfo_exists():
            dialog.destroy()

    @staticmethod
    def _canvas_row_label(row: dict) -> str:
        """``title · preset · updated`` display string for one CANVAS_LIST row."""
        title = str(row.get("title") or "Untitled")
        preset = str(row.get("preset") or "?")
        try:
            stamp = time.strftime(
                "%Y-%m-%d %H:%M", time.localtime(int(row.get("updated_at")))
            )
        except (TypeError, ValueError, OSError, OverflowError):
            stamp = "?"
        return f"{title} · {preset} · {stamp}"

    def _menu_save(self) -> None:
        if self._save is not None:
            self._save()

    def _menu_zoom_to_fit(self) -> None:
        if self._zoom_to_fit is not None:
            self._zoom_to_fit()

    def _menu_about(self) -> None:
        messagebox.showinfo(
            "SlateSync", f"PC Studio · WS port {self._config.ws_port}", parent=self._root
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def _marshal(self, func: Callable[[], None]) -> None:
        """Run ``func`` on the Tk thread now (if on it) or via ``after(0)``."""
        if self._root is None:
            return
        if self._tk_ident is not None and threading.get_ident() == self._tk_ident:
            func()
        else:
            self.after(0, func)

    def _show_impl(self) -> None:
        if self._root is not None and not (self._dragging or _move_loop_active()):
            self._root.deiconify()
            self._root.lift()

    def _hide_impl(self) -> None:
        self._dragging = False  # hidden window cannot be mid-drag (stale flag)
        if self._root is not None:
            self._root.withdraw()

    def _raise_window(self) -> None:
        if self._dragging or _move_loop_active():
            return  # Issue 04: never SetWindowPos during an active native move
        if self._root is not None:
            self._root.deiconify()
            self._root.lift()

    # ------------------------------------------------------------------
    # Issue 04: native-drag detection (position-change Configure tracking)
    # ------------------------------------------------------------------
    def _on_position_configure(self, event: tk.Event) -> None:
        """Mark an active drag when the toplevel's position changes."""
        root = self._root
        if root is None or event.widget is not root:
            return  # child <Configure>s share the toplevel's bindtag
        try:
            pos = (root.winfo_x(), root.winfo_y())
        except Exception:  # pragma: no cover - root destroyed mid-event
            return
        if self._drag_pos is not None and pos != self._drag_pos:
            self._dragging = True
            self._arm_drag_clear()
        self._drag_pos = pos

    def _arm_drag_clear(self) -> None:
        """(Re)arm the timer that clears the drag flag after motion stops."""
        root = self._root
        if root is None:
            return
        if self._drag_clear_id is not None:
            try:
                root.after_cancel(self._drag_clear_id)
            except Exception:  # pragma: no cover - root gone
                pass
        try:
            self._drag_clear_id = root.after(_DRAG_CLEAR_MS, self._end_drag)
        except Exception:  # pragma: no cover - root gone
            self._drag_clear_id = None

    def _end_drag(self) -> None:
        self._dragging = False
        self._drag_clear_id = None

    @staticmethod
    def _rpc_envelope(
        msg_type: str, action: str, canvas_id: str | None, payload: dict
    ) -> dict:
        """overview §4.2 RPC envelope."""
        return {
            "id": str(uuid.uuid4()),
            "type": msg_type,
            "action": action,
            "canvas_id": canvas_id,
            "payload": payload,
            "timestamp": int(time.time()),
        }

    @staticmethod
    def _doc_view(doc) -> tuple[str | None, str | None]:
        """``(canvas_id, preset)`` from a Doc 10 dict or CanvasDocument."""
        if doc is None:
            return None, None
        if isinstance(doc, dict):
            canvas_id = doc.get("canvas_id")
            artboard = doc.get("artboard")
        else:
            canvas_id = getattr(doc, "canvas_id", None)
            artboard = getattr(doc, "artboard", None)
        if isinstance(artboard, dict):
            preset = artboard.get("preset")
        else:
            preset = getattr(artboard, "preset", None)
        return canvas_id, preset

    @staticmethod
    def _preset_of(artboard) -> str | None:
        if artboard is None:
            return None
        if isinstance(artboard, dict):
            return artboard.get("preset")
        return getattr(artboard, "preset", None)
