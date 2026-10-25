"""Embedded OpenGL viewport host + generic shader registry — Doc 06 (Wave 1.B).

DEFAULT (issue 03/04 round 3): a PURE-Tk blit viewport — standalone ``moderngl``
context + RGBA FBO rendered offscreen, blitted on every 16 ms tick into a Tk
``Label`` via ``ImageTk.PhotoImage`` (raw RGB ``Image.frombytes``, no PNG
encode). The Tk toplevel then contains ZERO foreign child windows, so native
drag / resize / maximize / minsize work unconditionally on Win11 —
``user32.SetParent`` is NEVER called on this path (windows reparented with
``SetParent`` lose the parent's move/size semantics: microsoft-ui-xaml#8707 /
#8779; a maximize is a state command, so it kept working while drag snapped
back and borders could not resize). Doc 06 documents this as its FALLBACK
escape hatch — this round promotes it to the default; docs are not edited.

OPT-IN EXPERIMENTAL (default OFF): ``SLATESYNC_EMBED=setparent`` restores the
legacy Doc 06 PRIMARY embedding — hidden pyglet window (GL 3.3 core, MSAA 4×)
reparented into the Tk frame via ctypes ``user32.SetParent`` + ``WS_CHILD``
styles. Known to corrupt Win11 drag/resize (the original issue 03/04
symptoms); kept only as an escape hatch, guarded in both ``mount`` and
``_embed_pyglet``.

Threading (template §4): the WS thread may only call ``submit_live_frame`` /
``request_redraw`` — lock-free latest-frame slot + ``after(0, …)`` marshal, seq
stale-drop inside ``_drain``, every GL call on the Tk main thread, and a
coalescing ``after(16, …)`` pump (never ``pyglet.app.run()``).
"""

from __future__ import annotations

import ctypes
import logging
import os
import threading
import time
import tkinter as tk
from collections import deque
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Mapping

import moderngl
from PIL import Image, ImageTk

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    ASSET_UPLOADED,
    CAMERA_DELTA,
    CANVAS_CLEARED,
    COMMITTED_NODE,
    DOCUMENT_LOADED,
    LIVE_FRAME,
    EventBus,
)
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LASER,
    FRAME_LIVE_END,
    FRAME_LIVE_POINT,
    TOOL_HIGHLIGHTER,
    LiveFrame,
    is_newer_seq,
)
from pc_agent.viewport.empty_state_overlay import EmptyStateOverlay
from pc_agent.viewport.mirror_scene import MirrorArtboard, MirrorScene
from pc_agent.viewport.stroke_tessellator import (
    CAP_VERTS,
    DEFAULT_STROKE_WIDTH,
    StrokeTessellator,
    TessellatedMesh,
    flatten_stroke_path,
)

if TYPE_CHECKING:
    import pyglet

    from pc_agent.engine.document_store import CanvasDocument

logger = logging.getLogger(__name__)

# --- template §3 constants -------------------------------------------------
ZOOM_MIN, ZOOM_MAX = 0.05, 20.0  # live camera clamp (§3 zoom range)

# --- Doc 02 §10.5 view-fit-on-open (issue 03 round 6 — frozen additive) ----
FIT_PADDING = 48.0  # world units per side (⇒ +96 total per axis, Doc 20 §4)
#: empty/degenerate content fallback target rect as (x, y, w, h)
#: — spans (-500,-500)..(500,500), center (0,0); mirrors the mobile
#: ``Rect.fromLTWH(-500, -500, 1000, 1000)`` thumbnail/fit fallback.
FIT_FALLBACK_RECT = (-500.0, -500.0, 1000.0, 1000.0)

# GL_SCISSOR_TEST raw enum — moderngl exposes no SCISSOR capability constant,
# so enable_direct/disable_direct take the raw enum (as in primitive_renderer).
_GL_SCISSOR_TEST = 0x0C11

# --- Round 7 issue 02: "no canvas yet" surface -------------------------------
#: Workspace colour shown when NOTHING is open. The viewport used to clear to
#: pure white with no document loaded, which read as a blank sheet the user
#: could not tell apart from a real (empty) artboard. A neutral slate makes
#: the disconnected/empty state obviously "no canvas"; the real artboard
#: background takes over the moment a document loads.
EMPTY_STATE_BG = "#3A3D42"
#: Centred hint drawn over the empty workspace (Tk text, not GL).
EMPTY_STATE_HINT = "No canvas open — pair a device or press Ctrl+N"

# --- Doc 06 §4/§5 tuning ---------------------------------------------------
TICK_MS = 16  # Tk after(16) pump — never pyglet.app.run()
LASER_TIMEOUT_S = 0.5  # LASER 0x04 crosshair cleared on LIVE_END or timeout
LASER_ARM_PX = 12.0  # crosshair arm length in screen pixels
LASER_THICK_PX = 2.0  # crosshair arm thickness in screen pixels
LASER_COLOR = (1.0, 0.1, 0.1, 1.0)
FALLBACK_MAX_W, FALLBACK_MAX_H = 1600, 900  # blit FBO ROI cap — Doc 06's FALLBACK
# ROI, promoted to the DEFAULT pure-Tk path and raised from 1280×720 so the
# mirror keeps filling a maximized window (issue 04 round 3).
DEFAULT_COLOR = "#1E1E1E"  # NodeStyle.stroke default (template §4)
DEFAULT_MOUNT_W, DEFAULT_MOUNT_H = 640, 480  # size used before <Configure> realizes
_COMMIT_BUDGET = 64  # committed meshes tessellated per render (rest via redraw)
#: Round-9 issue 09 — LIVE_POINT frames are stroke SAMPLES, not state: the
#: latest-slot rule that is correct for CAMERA/LASER silently discarded every
#: point but the last one whenever two frames arrived between pumps, so the
#: mirror only got a dot until the pen lifted (when ADD_STROKE delivered the
#: finished stroke). Points are queued instead, with a cap so a stalled main
#: thread cannot grow the queue without bound.
LIVE_POINT_QUEUE_CAP = 4096

# Embedding strategy (issue 03/04 round 3): DEFAULT "blit" = pure-Tk offscreen
# FBO → ImageTk blit (no foreign child windows); "setparent" = the legacy Doc 06
# pyglet/SetParent reparent, opt-in ONLY via SLATESYNC_EMBED=setparent (default
# off — it breaks native window drag/resize on Win11, microsoft-ui-xaml#8707).
EMBED_ENV_VAR = "SLATESYNC_EMBED"
EMBED_BLIT = "blit"
EMBED_SETPARENT = "setparent"


def resolve_embed_strategy(env: Mapping[str, str] | None = None) -> str:
    """``SLATESYNC_EMBED`` → strategy name; default ``"blit"`` (pure-Tk path).

    Only the exact value ``setparent`` (case-insensitive) enables the legacy
    reparent embedding; unknown values are ignored with a warning.
    """
    source = os.environ if env is None else env
    raw = str(source.get(EMBED_ENV_VAR, "")).strip().lower()
    if raw == EMBED_SETPARENT:
        return EMBED_SETPARENT
    if raw and raw != EMBED_BLIT:
        logger.warning(
            "ignoring unknown %s=%r — using the pure-Tk blit viewport", EMBED_ENV_VAR, raw
        )
    return EMBED_BLIT

# Kinds whose geometry Doc 06 tessellates; SHAPE/GRAPH_AXES/IMAGE belong to Doc 08.
_STROKE_KINDS = frozenset({"STROKE", "HIGHLIGHT", "LINE"})

# Win32 styles for the SetParent reparent (Doc 06 §4).
_GWL_STYLE = -16
_WS_CHILD = 0x40000000
_WS_CLIPSIBLINGS = 0x04000000
_WS_CLIPCHILDREN = 0x02000000
_WS_POPUP = 0x80000000
_WS_CAPTION = 0x00C00000
_WS_THICKFRAME = 0x00040000
_WS_MINIMIZEBOX = 0x00020000
_WS_MAXIMIZEBOX = 0x00010000
_WS_SYSMENU = 0x00080000
_WS_MINIMIZE = 0x20000000
_WS_MAXIMIZE = 0x01000000
_DECORATIONS = (
    _WS_POPUP | _WS_CAPTION | _WS_THICKFRAME | _WS_MINIMIZEBOX | _WS_MAXIMIZEBOX
    | _WS_SYSMENU | _WS_MINIMIZE | _WS_MAXIMIZE
)

_SRC_OVER_BLEND = (moderngl.SRC_ALPHA, moderngl.ONE_MINUS_SRC_ALPHA)  # u_blendMode 0
_MULTIPLY_BLEND = (moderngl.DST_COLOR, moderngl.ZERO)  # u_blendMode 1 (§3)

# Deliberate GL-context keep-alive (issue 03/04 round 3). moderngl does not
# re-MakeCurrent per call, and releasing the thread-CURRENT context leaves the
# thread with NO current GL context: every later context in the process then
# fails ("cannot create program/buffer") and pyglet's WGL extension query
# fails ("wglChoosePixelFormatARB is not exported"). The baseline masked this
# by accident — its pyglet windows left a context current after close; the
# pure-Tk default creates no pyglet windows, so shutdown keeps its context
# alive and current on purpose (all GL *objects* are released above; only the
# empty context shell survives, until process exit).
_GL_KEEPALIVE: list[moderngl.Context] = []

# One-triangle present flip (issue 04 round 3): samples the scene FBO with an
# inverted V so readback rows arrive top-first — keeps the PIL/Tk row order
# exact without a per-frame CPU transpose. Written inline (not a shader-dir
# stem) because it is a GL plumbing detail of Doc 06's blit path only.
_FLIP_VERT = """#version 330 core
in vec2 in_pos;
out vec2 v_uv;
void main() {
    v_uv = vec2(in_pos.x * 0.5 + 0.5, 0.5 - in_pos.y * 0.5);
    gl_Position = vec4(in_pos, 0.0, 1.0);
}
"""
_FLIP_FRAG = """#version 330 core
uniform sampler2D u_tex;
in vec2 v_uv;
out vec4 fragColor;
void main() {
    fragColor = texture(u_tex, v_uv);
}
"""


class MissingShaderPairError(FileNotFoundError, KeyError):
    """Stem lookup failed because ``<stem>.vert`` or ``<stem>.frag`` is absent.

    Subclasses :class:`FileNotFoundError` (Doc 06 §4 — the message names both
    paths) and :class:`KeyError` so ``except KeyError`` handlers around
    ``ProgramRegistry.get`` also catch a missing stem.
    """


def _parse_color(color: str, opacity: float = 1.0) -> tuple[float, float, float, float]:
    """``#RGB``/``#RRGGBB`` → RGBA floats; unparsable input falls back to black."""
    text = str(color).strip().lstrip("#")
    if len(text) == 3:
        text = "".join(ch * 2 for ch in text)
    if len(text) != 6:
        return (0.0, 0.0, 0.0, _clamp01(opacity))
    try:
        r = int(text[0:2], 16) / 255.0
        g = int(text[2:4], 16) / 255.0
        b = int(text[4:6], 16) / 255.0
    except ValueError:
        return (0.0, 0.0, 0.0, _clamp01(opacity))
    return (r, g, b, _clamp01(opacity))


def _clamp01(value: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 1.0
    return max(0.0, min(1.0, number))


class ProgramRegistry:
    """Generic ``<stem>.vert`` + ``<stem>.frag`` pair loader with a program cache.

    Missing pair → :class:`MissingShaderPairError` (a ``FileNotFoundError``
    naming both paths); compile failure → ``RuntimeError`` with the driver log.
    Stems: ``stroke`` (Doc 07), ``primitive``/``grid``/``texture`` (Doc 08) —
    whichever pairs exist on disk are loadable (``stems`` lists them).
    """

    def __init__(self, config: AppConfig, ctx: moderngl.Context | None = None) -> None:
        self._shader_dir = Path(config.shader_dir)
        self._ctx = ctx
        self._programs: dict[str, moderngl.Program] = {}

    @property
    def shader_dir(self) -> Path:
        return self._shader_dir

    @property
    def ctx(self) -> moderngl.Context | None:
        return self._ctx

    def set_ctx(self, ctx: moderngl.Context | None) -> None:
        """Attach/replace the GL context used for compilation (called by Doc 06)."""
        self._ctx = ctx

    @property
    def stems(self) -> list[str]:
        """Sorted stems whose ``.vert`` and ``.frag`` files both exist."""
        if not self._shader_dir.is_dir():
            return []
        found = [
            vert.stem
            for vert in self._shader_dir.glob("*.vert")
            if vert.with_suffix(".frag").is_file()
        ]
        return sorted(found)

    def get(self, stem: str) -> moderngl.Program:
        """Compile (once) and cache the program for ``stem``."""
        cached = self._programs.get(stem)
        if cached is not None:
            return cached
        vert = self._shader_dir / f"{stem}.vert"
        frag = self._shader_dir / f"{stem}.frag"
        if not vert.is_file() or not frag.is_file():
            raise MissingShaderPairError(
                f"missing shader pair for stem {stem!r}: expected both {vert} and {frag}"
            )
        if self._ctx is None:
            raise RuntimeError(
                f"no GL context attached — call ProgramRegistry.set_ctx() before get({stem!r})"
            )
        try:
            program = self._ctx.program(
                vertex_shader=vert.read_text(encoding="utf-8"),
                fragment_shader=frag.read_text(encoding="utf-8"),
            )
        except Exception as exc:
            logger.error("shader stem %r failed to compile (%s, %s): %s", stem, vert, frag, exc)
            raise RuntimeError(
                f"failed to compile shader stem {stem!r} from {vert} and {frag}: {exc}"
            ) from exc
        self._programs[stem] = program
        return program

    def release(self) -> None:
        """Release every cached program (shutdown path, Doc 06 §5.9)."""
        for program in self._programs.values():
            program.release()
        self._programs.clear()


class GLCanvasHost:
    """Tk-hosted OpenGL viewport consuming the Doc 04/11/09/10 event matrix."""

    # ------------------------------------------------------------------
    # Construction & event wiring (Doc 06 §5.3)
    # ------------------------------------------------------------------
    def __init__(self, tk_parent: tk.Misc, config: AppConfig, bus: EventBus) -> None:
        self._tk_parent = tk_parent
        self._config = config
        self._bus = bus

        self._registry = ProgramRegistry(config)
        self._stroke_program: moderngl.Program | None = None
        self._tessellator: StrokeTessellator | None = None
        self._primitive = None  # Doc 08 PrimitiveRenderer once Wave 2.A lands
        self._ctx: moderngl.Context | None = None
        self._window = None  # pyglet window (PRIMARY)
        self._user32 = None
        self._fbo: moderngl.Framebuffer | None = None
        self._fbo_texture: moderngl.Texture | None = None
        self._label: tk.Label | None = None
        self._frame: tk.Frame | None = None
        self._empty_state: EmptyStateOverlay | None = None
        self._parent_widget: tk.Misc | None = None
        # Blit-pipeline reuse state (DEFAULT pure-Tk path, issue 04 round 3):
        # one cached read buffer, one zero-copy frombuffer view, two PhotoImage
        # slots alternated so paste runs detached and configure stays a cheap swap.
        self._blit_buf: bytearray | None = None
        self._blit_view: Image.Image | None = None
        self._blit_photo: ImageTk.PhotoImage | None = None
        # GPU present-flip: the scene renders into the FBO in GL orientation
        # (row 0 = visual bottom) but PIL/Tk want row 0 on top. A one-triangle
        # pass samples the scene FBO with inverted V into ``_flip_fbo`` so the
        # readback rows arrive top-first — no CPU transpose (~2.5 ms) per frame.
        self._flip_texture: moderngl.Texture | None = None
        self._flip_fbo: moderngl.Framebuffer | None = None
        self._flip_program: moderngl.Program | None = None
        self._flip_vao: moderngl.VertexArray | None = None

        # Lock-free latest-frame slot: GIL-atomic attribute replace (Doc 06 §4).
        self._slot: LiveFrame | None = None
        #: Round-9 issue 09 — ordered LIVE_POINT backlog (samples, never
        #: coalesced). Appended under a short lock because the WS reader thread
        #: and the Tk pump both touch it.
        self._live_queue: deque[LiveFrame] = deque()
        self._live_queue_lock = threading.Lock()
        self._drain_pending = False
        self._drain_after_id: str | None = None
        self._tick_pending = False
        self._tick_after_id: str | None = None
        self._dirty = False
        self._last_seq: int | None = None

        self._camera: tuple[float, float, float] = (1.0, 0.0, 0.0)
        self._vp_w, self._vp_h = 0, 0
        # "primary" (opt-in setparent) | "fallback" (DEFAULT pure-Tk blit) | "none"
        self._mode = "none"
        self._mounted = False
        self._shutdown = False
        # Default: pure-Tk blit — pyglet is neither probed nor imported. The
        # legacy SetParent path exists only behind SLATESYNC_EMBED=setparent.
        self._embed_strategy = resolve_embed_strategy()
        self._pyglet_available = (
            self._probe_pyglet() if self._embed_strategy == EMBED_SETPARENT else False
        )

        self._doc: CanvasDocument | None = None
        self._artboard = None
        self._content_bounds: dict[str, float] = {}
        #: Round-8 issue 05 — the open canvas's asset folder (Doc 10
        #: ``assets_dir``), forwarded to PrimitiveRenderer so mirrored IMAGE
        #: nodes resolve instead of falling back to the magenta placeholder.
        self._assets_root: object = None
        #: Round-10 issue 06 — resolver injected by ``main.py``
        #: (``canvas_id -> assets_dir``). ``DOCUMENT_LOADED`` is not the only
        #: way a canvas becomes visible (a persisted-only open, a restored
        #: mirror after a reconnect), so the render pass re-asks for the folder
        #: whenever the mirrored canvas id changes. Without this an IMAGE node
        #: arriving on a canvas whose ``DOCUMENT_LOADED`` was missed renders
        #: with ``assets_root is None`` — the pink-block report.
        self._assets_root_for: Callable[[str], object] | None = None
        self._assets_root_canvas: str | None = None
        #: Round 7 issue 06 — live element mirror. ``doc.elements`` is only the
        #: snapshot taken when the document was opened; every later
        #: COMMITTED_NODE keeps this registry current so SHAPE/GRAPH_AXES/IMAGE
        #: edits from a tablet actually paint in the PC mirror.
        self._scene = MirrorScene()
        self._committed: dict[
            str, tuple[TessellatedMesh, tuple[float, float, float, float], int]
        ] = {}
        self._pending_nodes: list[object] = []

        self._live_points: list[tuple[float, float]] = []
        self._live_pressure: list[float] = []
        self._live_width = DEFAULT_STROKE_WIDTH
        self._live_wpf = 0.0
        self._live_tool = 0
        self._live_active = False
        self._live_dirty = False

        self._laser: tuple[float, float] | None = None
        self._laser_deadline = 0.0
        self._laser_key: tuple[float, float, float] | None = None
        self._laser_meshes: list[TessellatedMesh] = []

        # Template §4 event matrix + round 7 CANVAS_CLEARED (mirror wipe).
        self._subscriptions = [
            (LIVE_FRAME, self._on_live_frame),
            (CAMERA_DELTA, self._on_camera_delta),
            (DOCUMENT_LOADED, self._on_document_loaded),
            (COMMITTED_NODE, self._on_committed_node),
            (ARTBOARD_CHANGED, self._on_artboard_changed),
            (CANVAS_CLEARED, self._on_canvas_cleared),
            (ASSET_UPLOADED, self._on_asset_uploaded),
        ]
        for event, handler in self._subscriptions:
            bus.on(event, handler)

    def _probe_pyglet(self) -> bool:
        """Constructor-side availability probe (Doc 06 §1: degrade, don't explode).

        Only consulted for the opt-in ``SLATESYNC_EMBED=setparent`` strategy —
        the default pure-Tk blit path never touches pyglet.
        """
        try:
            import pyglet

            _ = pyglet.version  # import side-effect free: no display/GL touched yet
        except Exception as exc:
            logger.warning(
                "pyglet unavailable (%s) — SLATESYNC_EMBED=setparent will degrade to "
                "the pure-Tk blit viewport",
                exc,
            )
            return False
        return True

    # ------------------------------------------------------------------
    # Frozen public API (template §4)
    # ------------------------------------------------------------------
    def mount(self, parent_widget: tk.Misc) -> None:
        """Build the Tk container, embed the GL surface, start the 16 ms pump."""
        if self._mounted or self._shutdown:
            return
        self._parent_widget = parent_widget
        self._frame = tk.Frame(parent_widget, bg=EMPTY_STATE_BG)
        self._frame.pack(fill="both", expand=True)
        self._frame.bind("<Configure>", self._on_configure)

        w = self._frame.winfo_width()
        h = self._frame.winfo_height()
        if w <= 1 or h <= 1:  # not realized yet — the first <Configure> corrects this
            w, h = DEFAULT_MOUNT_W, DEFAULT_MOUNT_H
        self._vp_w, self._vp_h = w, h

        mode = "none"
        try:
            if (
                self._embed_strategy == EMBED_SETPARENT
                and self._pyglet_available
                and self._embed_pyglet()
            ):
                mode = "primary"
            else:
                # DEFAULT (pure-Tk): standalone context + FBO blit — reached
                # without ever calling _embed_pyglet, i.e. without SetParent.
                if self._embed_strategy == EMBED_SETPARENT:
                    logger.warning(
                        "SLATESYNC_EMBED=setparent embedding failed — degrading to the "
                        "pure-Tk blit viewport (standalone moderngl FBO ≤%dx%d → ImageTk blit)",
                        FALLBACK_MAX_W,
                        FALLBACK_MAX_H,
                    )
                if self._ctx is not None:  # half-attached setparent context
                    self._ctx.release()
                    self._ctx = None
                self._ctx = moderngl.create_standalone_context()
                mode = "fallback"  # DEFAULT pure-Tk blit mode (legacy name kept)
            self._init_gl_surface()
            if mode == "fallback":
                self._init_fallback_targets()
                self._build_fallback_label()
        except Exception:
            logger.exception("GL surface initialization failed — viewport stays blank")
            self._release_gl()
            mode = "none"
        self._mode = mode

        self._mounted = True
        real_w = self._frame.winfo_width()
        real_h = self._frame.winfo_height()
        if real_w > 1 and real_h > 1:
            self.resize(real_w, real_h)
        self.request_redraw()  # initial paint + pump start
        logger.info("GLCanvasHost mounted (mode=%s, viewport=%dx%d)", mode, self._vp_w, self._vp_h)

    def submit_live_frame(self, frame: LiveFrame) -> None:
        """THREAD-SAFE: marshal one ``after(0)`` drain and hand the frame over.

        Round-9 issue 09: LIVE_POINT frames are stroke SAMPLES, so they must be
        queued in order — a latest-slot replace (correct for CAMERA/LASER, which
        carry state) threw away every point but the newest whenever two arrived
        between pumps, which is why a mirrored pen stroke only appeared as the
        tip until the pen lifted and the committed ADD_STROKE arrived.
        """
        if self._shutdown:
            return
        if frame.frame_type == FRAME_LIVE_POINT:
            with self._live_queue_lock:
                if len(self._live_queue) < LIVE_POINT_QUEUE_CAP:
                    self._live_queue.append(frame)
                else:
                    logger.warning(
                        "LIVE_POINT backlog full (%d) — dropping sample", LIVE_POINT_QUEUE_CAP
                    )
        else:
            self._slot = frame  # GIL-atomic attribute replace (lock-free)
        self._schedule_drain()

    def set_document(self, doc: CanvasDocument) -> None:
        """Swap the rendered document; strokes are re-queued for tessellation.

        Also applies the Doc 02 §10.5 view-fit (round 6, issue 03): additive
        and idempotent — ``main.py`` re-calls :meth:`fit_viewport` after
        ``DOCUMENT_LOADED`` for the HUD, and any later ``CAMERA_DELTA``
        overrides the fitted camera (the PC mirrors the tablet camera by
        design).
        """
        self._doc = doc
        self._committed.clear()
        self._pending_nodes = []
        # Round 7 issue 06: elements come from the LIVE mirror registry, not
        # from the opener's snapshot, so later commits keep painting.
        self._scene.reset(getattr(doc, "elements", None) if doc is not None else None)
        if doc is not None:
            self._artboard = getattr(doc, "artboard", self._artboard)
            bounds = getattr(doc, "content_bounds", None)
            if bounds:
                self._content_bounds = dict(bounds)
            self._pending_nodes = [
                node for node in (getattr(doc, "elements", None) or []) if node is not None
            ]
            self.fit_viewport()
        else:
            # Round 7 issue 02: closing the document must release the page so
            # the viewport falls back to the neutral empty workspace instead of
            # repainting the previous artboard's paper colour.
            self._artboard = None
            self._content_bounds = {}
        self._update_empty_state()
        self.request_redraw()

    def invalidate_images(self) -> None:
        """Round-9 issue 07b — drop cached IMAGE textures and repaint.

        ``ASSET_DONE`` writes the bytes AFTER the IMAGE node was already
        committed and drawn (placeholder), so the renderer must be told to
        forget its cache or the mirror keeps showing a filled block. Called
        from ``main.py`` on the asset-completion event.
        """
        invalidator = getattr(self._primitive, "invalidate_images", None)
        if invalidator is None:
            return
        try:
            if invalidator():
                self.request_redraw()
        except Exception:
            logger.exception("PrimitiveRenderer.invalidate_images failed (Doc 08)")

    def set_assets_root(self, root: object) -> None:
        """Round-8 issue 05 — point image assets at the open canvas's folder.

        ``PrimitiveRenderer`` resolves ``geometry.asset_ref`` against an
        injected ``assets_root`` (Doc 08 §5(8) / Doc 10 ``assets_dir``), but
        nothing ever injected one in production: every mirrored IMAGE fell
        through to the 1×1 magenta placeholder even when the bytes had
        arrived over ``ASSET_START/CHUNK/DONE``. ``main.py`` calls this with
        the store's live ``assets_dir`` whenever the open canvas changes.

        Swapping roots releases cached textures so a different canvas's
        same-named asset can never reuse a stale texture.
        """
        setter = getattr(self._primitive, "set_assets_root", None)
        if setter is None:
            # No GL surface yet (renderer is built on mount) — remember it so
            # _init_gl_surface can apply the pending root.
            self._assets_root = root
            return
        self._assets_root = root
        try:
            setter(root)
        except Exception:
            logger.exception("PrimitiveRenderer.set_assets_root failed (Doc 08)")

    def set_assets_root_resolver(self, resolver: object) -> None:
        """Round-10 issue 06 — inject ``canvas_id -> assets_dir``.

        ``DOCUMENT_LOADED`` is not the only way a canvas becomes visible, so the
        render pass re-resolves the folder whenever the mirrored canvas id
        changes (see :meth:`_sync_assets_root`). ``main.py`` passes
        ``document_store.assets_dir`` here.
        """
        self._assets_root_for = resolver if callable(resolver) else None
        self._assets_root_canvas = None

    def _sync_assets_root(self) -> None:
        """Re-point the image root when the mirrored canvas changed (main thread).

        Cheap: one string compare per frame once the id is settled, and it makes
        a missing ``DOCUMENT_LOADED`` self-healing instead of a permanent pink
        block over every IMAGE node.
        """
        resolver = self._assets_root_for
        if resolver is None:
            return
        canvas_id = self._canvas_id()
        if not canvas_id or canvas_id == self._assets_root_canvas:
            return
        try:
            root = resolver(canvas_id)
        except Exception:
            logger.exception("asset-root resolver failed for %s", canvas_id)
            return
        self._assets_root_canvas = canvas_id
        if root != self._assets_root:
            self.set_assets_root(root)

    def fit_viewport(self) -> None:
        """Doc 02 §10.5 (frozen): zoom-to-fit the open document.

        Target rect: bounded ⇒ ``(0, 0, width, height)``; infinite ⇒
        ``content_bounds`` (empty/degenerate ⇒ :data:`FIT_FALLBACK_RECT`).
        Scale = ``min(viewport_w / (w + 96), viewport_h / (h + 96))`` (48
        world units of padding per side, Doc 20 §4 mirror), clamped to the §3
        zoom range 0.05…20; camera centered on the rect via the §3 transform
        (``tx, ty`` = rect center). Uses the realized viewport (or the
        default mount size before ``<Configure>``). Idempotent — repeated
        calls recompute the same camera.
        """
        x, y, w, h = self._fit_target_rect()
        view_w = self._vp_w if self._vp_w > 0 else DEFAULT_MOUNT_W
        view_h = self._vp_h if self._vp_h > 0 else DEFAULT_MOUNT_H
        dw = w + 2.0 * FIT_PADDING
        dh = h + 2.0 * FIT_PADDING
        zx = view_w / dw if dw > 0 else ZOOM_MAX
        zy = view_h / dh if dh > 0 else ZOOM_MAX
        scale = max(ZOOM_MIN, min(ZOOM_MAX, zx if zx < zy else zy))
        self.set_camera(scale, x + w * 0.5, y + h * 0.5)

    @property
    def camera_scale(self) -> float:
        """Current camera scale — Doc 02 §10.5 frozen accessor (§3 zoom range)."""
        return float(self._camera[0])

    def _fit_target_rect(self) -> tuple[float, float, float, float]:
        """§10.5 target rect as ``(x, y, w, h)`` for :meth:`fit_viewport`.

        Mirrors the mobile ``_thumbRect``/``zoomToFit`` rules: bounded
        artboard with positive size ⇒ ``(0, 0, w, h)``; otherwise
        ``content_bounds`` when it has positive extent; otherwise the
        ``(-500, -500, 1000, 1000)`` fallback.
        """
        artboard = self._artboard
        if artboard is None and self._doc is not None:
            artboard = getattr(self._doc, "artboard", None)
        if artboard is not None and not bool(getattr(artboard, "is_infinite", False)):
            width = float(getattr(artboard, "width", 0) or 0)
            height = float(getattr(artboard, "height", 0) or 0)
            if width > 0 and height > 0:
                return (0.0, 0.0, width, height)
        bounds = self._content_bounds or dict(
            getattr(self._doc, "content_bounds", None) or {}
        )
        try:
            min_x = float(bounds.get("min_x") or 0.0)
            min_y = float(bounds.get("min_y") or 0.0)
            max_x = float(bounds.get("max_x") or 0.0)
            max_y = float(bounds.get("max_y") or 0.0)
        except (AttributeError, TypeError, ValueError):
            return FIT_FALLBACK_RECT
        if max_x > min_x and max_y > min_y:
            return (min_x, min_y, max_x - min_x, max_y - min_y)
        return FIT_FALLBACK_RECT

    def set_camera(self, scale: float, tx: float, ty: float) -> None:
        """Programmatic camera; ``scale`` clamped to the §3 zoom range 0.05…20.0."""
        clamped = max(ZOOM_MIN, min(ZOOM_MAX, float(scale)))
        self._camera = (clamped, float(tx), float(ty))
        if self._live_active:
            self._live_dirty = True  # resample the in-flight stroke at the new scale
        self.request_redraw()

    def request_redraw(self) -> None:
        """THREAD-SAFE: set the dirty flag; N calls coalesce into ≤1 scheduled tick."""
        self._dirty = True
        self._ensure_tick()

    def resize(self, w: int, h: int) -> None:
        """Update the viewport, reparented window, or DEFAULT blit FBO target."""
        width = max(int(w), 1)
        height = max(int(h), 1)
        if self._mode == "fallback":
            # Blit ROI: the camera math (u_viewport) must equal the FBO size,
            # so the logical viewport is capped together with the FBO.
            width = min(width, FALLBACK_MAX_W)
            height = min(height, FALLBACK_MAX_H)
        if (width, height) == (self._vp_w, self._vp_h):
            return
        self._vp_w, self._vp_h = width, height
        if self._mode == "primary" and self._window is not None and self._user32 is not None:
            try:  # legacy setparent path: glue the WS_CHILD surface to the Tk frame
                self._user32.MoveWindow(int(self._window._hwnd), 0, 0, width, height, True)
            except Exception:
                logger.debug("MoveWindow failed during resize", exc_info=True)
        elif self._mode == "fallback" and self._ctx is not None:
            self._recreate_fbo()
        self.request_redraw()

    def shutdown(self) -> None:
        """Cancel pending ``after`` ids, unsubscribe the bus, destroy window/GL."""
        if self._shutdown:
            return
        self._shutdown = True
        for after_id in (self._tick_after_id, self._drain_after_id):
            if after_id is not None:
                try:
                    self._tk_parent.after_cancel(after_id)
                except Exception:
                    logger.debug("after_cancel(%s) failed", after_id, exc_info=True)
        self._tick_after_id = None
        self._drain_after_id = None
        with self._live_queue_lock:
            self._live_queue.clear()
        self._slot = None
        for event, handler in self._subscriptions:
            self._bus.off(event, handler)
        if self._empty_state is not None:
            self._empty_state.destroy()
            self._empty_state = None
        self._release_gl()
        frame = self._frame
        self._frame = None
        if frame is not None:
            try:
                frame.destroy()
            except Exception:
                logger.debug("Tk frame destroy failed during shutdown", exc_info=True)
        self._mounted = False
        logger.info("GLCanvasHost shut down")

    # ------------------------------------------------------------------
    # Doc-specific frozen API (Doc 06 §4)
    # ------------------------------------------------------------------
    def _tick(self) -> None:
        """Tk ``after(16)`` pump: drain → dispatch → render → flip (reschedules first)."""
        self._tick_pending = False
        self._tick_after_id = None
        if self._shutdown or not self._mounted:
            return
        self._ensure_tick()  # reschedule BEFORE work — an exception can't stop the pump
        try:
            self._drain()
            window = self._window
            if self._mode == "primary" and window is not None:
                window.switch_to()
                window.dispatch_events()
            self._expire_laser()
            if self._dirty:
                self._dirty = False
                self._render()
                if self._mode == "primary" and window is not None:
                    window.flip()
                elif self._mode == "fallback":
                    self._blit_fallback()
        except Exception:
            logger.exception("viewport tick failed (pump continues)")

    def _drain(self) -> None:
        """Main thread: apply queued LIVE_POINT samples, then the latest slot.

        The slot keeps ``is_newer_seq`` semantics (CAMERA/LASER are state, so
        only the newest matters); the queue preserves stroke order (round-9
        issue 09) and is drained under the lock to keep the reader thread's
        appends coherent.
        """
        self._drain_pending = False
        self._drain_after_id = None
        while True:
            with self._live_queue_lock:
                batch = list(self._live_queue)
                self._live_queue.clear()
            for frame in batch:
                self._apply_frame(frame)
            frame = self._slot
            if frame is None:
                return
            self._slot = None
            self._apply_frame(frame)

    def set_camera_live(self, f1: float, f2: float, f3: float) -> None:
        """``CAMERA_DELTA``/0x03 route: clamp scale to 0.05…20.0, store, redraw."""
        self.set_camera(f1, f2, f3)

    def visible_world_rect(self) -> tuple[float, float, float, float]:
        """World-space rect currently visible: the §3 inverse at the viewport corners."""
        scale, tx, ty = self._camera
        half_w = self._vp_w / 2.0
        half_h = self._vp_h / 2.0
        return (
            (0.0 - half_w) / scale + tx,
            (0.0 - half_h) / scale + ty,
            (self._vp_w - half_w) / scale + tx,
            (self._vp_h - half_h) / scale + ty,
        )

    @staticmethod
    def _pyglet_config() -> pyglet.gl.Config:
        """GL 3.3 core + MSAA 4× pixel-format request (Doc 06 §1/§4).

        Doc 06 spells the sample count ``sample=4`` (pyglet 1.x); pyglet 2.x
        renamed the attribute ``samples`` — both kwargs are passed so the request
        survives either generation (pyglet ignores unknown kwargs).
        """
        import pyglet

        return pyglet.gl.Config(
            sample_buffers=1, sample=4, samples=4, major_version=3, minor_version=3
        )

    # ------------------------------------------------------------------
    # Event-matrix handlers (template §4)
    # ------------------------------------------------------------------
    def _on_live_frame(self, frame: LiveFrame) -> None:
        self.submit_live_frame(frame)

    def _on_camera_delta(self, frame: LiveFrame) -> None:
        self.set_camera_live(frame.f1, frame.f2, frame.f3)

    def _on_document_loaded(self, doc: CanvasDocument) -> None:
        self.set_document(doc)

    def _on_committed_node(
        self, node=None, deleted_node_id=None, **_extra
    ) -> None:
        if node is None:
            if deleted_node_id is not None:
                self._committed.pop(str(deleted_node_id), None)
                self._scene.remove(deleted_node_id)
                self.request_redraw()
            return
        # Round 7 issue 06: keep the live mirror in step with every commit and
        # re-derive the content bounds, so SHAPE/GRAPH_AXES/IMAGE nodes that
        # arrive AFTER the document was opened still paint (PrimitiveRenderer
        # needs the node list + bounds; doc.elements is a stale snapshot).
        self._scene.upsert(node)
        bounds = self._scene.bounds()
        if bounds["max_x"] > bounds["min_x"] or bounds["max_y"] > bounds["min_y"]:
            self._content_bounds = bounds
        self._pending_nodes.append(node)  # tessellated on the Tk main thread
        self.request_redraw()

    def _on_canvas_cleared(self, canvas_id=None, **_extra) -> None:
        """Round 7 issue 06: a CLEAR_CANVAS wipes the mirrored element set too."""
        self._scene.clear()
        self._committed.clear()
        self._pending_nodes = []
        self._content_bounds = {}
        self.request_redraw()

    def _on_asset_uploaded(self, canvas_id=None, filename=None, **_extra) -> None:
        """Round-9 issue 07b: an uploaded image landed — repaint with real bytes.

        The IMAGE node reaches the mirror (and is tessellated into a quad) long
        before ``ASSET_DONE`` finishes streaming the file, so the first frames
        legitimately use the placeholder. This drops the renderer's texture
        cache when the bytes finally exist.
        """
        current = self._canvas_id()
        if canvas_id and current and str(canvas_id) != str(current):
            return  # another canvas's asset; this viewport is unaffected
        invalidate = getattr(self, "invalidate_images", None)
        if callable(invalidate):
            invalidate()

    def _canvas_id(self) -> str | None:
        """Id of the canvas this viewport mirrors (``None`` before an open)."""
        doc = self._doc
        canvas_id = getattr(doc, "canvas_id", None) if doc is not None else None
        return str(canvas_id) if canvas_id else None

    def _on_artboard_changed(self, artboard=None, content_bounds=None, **_extra) -> None:
        if artboard is not None:
            self._artboard = artboard
        if content_bounds:
            self._content_bounds = dict(content_bounds)
        self.request_redraw()

    # ------------------------------------------------------------------
    # Scheduling helpers (thread-safe marshalling)
    # ------------------------------------------------------------------
    def _schedule_drain(self) -> None:
        if self._drain_pending or self._shutdown:
            return
        self._drain_pending = True
        try:
            self._drain_after_id = self._tk_parent.after(0, self._drain)
        except Exception:
            self._drain_pending = False
            logger.debug("after(0, drain) scheduling failed", exc_info=True)

    def _ensure_tick(self) -> None:
        if self._tick_pending or self._shutdown:
            return
        self._tick_pending = True
        try:
            self._tick_after_id = self._tk_parent.after(TICK_MS, self._tick)
        except Exception:
            self._tick_pending = False
            logger.debug("after(%d, tick) scheduling failed", TICK_MS, exc_info=True)

    # ------------------------------------------------------------------
    # Frame application (main thread only)
    # ------------------------------------------------------------------
    def _apply_frame(self, frame: LiveFrame) -> None:
        if not is_newer_seq(frame.seq, self._last_seq):
            return  # stale-drop: single u16 per-connection counter (template §3)
        self._last_seq = frame.seq
        if frame.frame_type == FRAME_CAMERA:
            self.set_camera_live(frame.f1, frame.f2, frame.f3)
        elif frame.frame_type == FRAME_LIVE_POINT:
            if not self._live_active:
                self._live_points.clear()
                self._live_pressure.clear()
                self._live_active = True
                if self._tessellator is not None:
                    self._tessellator.begin_live()
            self._live_points.append((float(frame.f1), float(frame.f2)))
            # f3 is the wire's width_pressure_factor (template §3 / Doc 21 §4):
            # it feeds both the per-point pressure and the lerp factor below.
            self._live_pressure.append(float(frame.f3))
            self._live_wpf = float(frame.f3)
            self._live_tool = frame.tool_id
            self._live_dirty = True
            self.request_redraw()
        elif frame.frame_type == FRAME_LIVE_END:
            self._live_active = False
            self._live_dirty = False
            self._laser = None  # LIVE_END clears the crosshair (Doc 06 §4)
            self._laser_key = None
            if self._tessellator is not None:
                self._tessellator.end_live()
            self.request_redraw()
        elif frame.frame_type == FRAME_LASER:
            self._laser = (float(frame.f1), float(frame.f2))
            self._laser_deadline = time.monotonic() + LASER_TIMEOUT_S
            self._laser_key = None  # force crosshair rebuild on next sync
            self.request_redraw()

    def _expire_laser(self) -> None:
        if self._laser is not None and time.monotonic() > self._laser_deadline:
            self._laser = None
            self._laser_key = None
            self.request_redraw()

    # ------------------------------------------------------------------
    # LEGACY setparent embedding — opt-in ONLY via SLATESYNC_EMBED=setparent
    # (issue 03/04 round 3: breaks native drag/resize on Win11; see header)
    # ------------------------------------------------------------------
    def _embed_pyglet(self) -> bool:
        """Hidden pyglet window → ``SetParent`` into the Tk frame.

        Guarded at entry: without an explicit ``SLATESYNC_EMBED=setparent``
        opt-in this returns ``False`` immediately, so ``user32.SetParent`` is
        unreachable on the default pure-Tk path (belt-and-suspenders on top
        of the strategy check in :meth:`mount`).
        """
        if self._embed_strategy != EMBED_SETPARENT:
            return False  # never reparent unless the user explicitly opted in
        import pyglet

        w, h = self._vp_w, self._vp_h
        try:
            window = pyglet.window.Window(
                visible=False, width=w, height=h, resizable=False,
                config=self._pyglet_config(),
            )
        except Exception:
            logger.exception("pyglet window creation failed")
            return False
        try:
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            hwnd = int(window._hwnd)
            tk_hwnd = int(self._frame.winfo_id())
            style = user32.GetWindowLongW(hwnd, _GWL_STYLE)
            style = (style | _WS_CHILD | _WS_CLIPSIBLINGS | _WS_CLIPCHILDREN) & ~_DECORATIONS
            user32.SetWindowLongW(hwnd, _GWL_STYLE, style)
            user32.SetParent(hwnd, tk_hwnd)
            if user32.GetParent(hwnd) != tk_hwnd:
                logger.warning(
                    "SetParent(%d, %d) failed (Win32 error %d)",
                    hwnd,
                    tk_hwnd,
                    ctypes.get_last_error(),
                )
                window.close()
                return False
            user32.MoveWindow(hwnd, 0, 0, w, h, True)
            window.set_visible(True)
            window.switch_to()
            self._ctx = moderngl.create_context()  # attach to pyglet's 3.3 core context
            self._window = window
            self._user32 = user32
            return True
        except Exception:
            logger.exception("PRIMARY SetParent embedding failed")
            try:
                window.close()
            except Exception:
                logger.debug("pyglet window cleanup after embed failure failed", exc_info=True)
            self._ctx = None
            return False

    # ------------------------------------------------------------------
    # GL surface setup / teardown
    # ------------------------------------------------------------------
    def _init_gl_surface(self) -> None:
        if self._ctx is None:
            raise RuntimeError("no GL context available for the viewport surface")
        self._registry.set_ctx(self._ctx)
        self._stroke_program = self._registry.get("stroke")  # Doc 07 stem
        self._tessellator = StrokeTessellator(self._ctx)
        self._tessellator.program = self._stroke_program  # VAOs bind this program
        self._ctx.enable(moderngl.BLEND)
        self._ctx.blend_func = _SRC_OVER_BLEND
        try:  # Doc 08 (Wave 2.A) — optional until that wave lands
            from pc_agent.viewport.primitive_renderer import PrimitiveRenderer

            self._primitive = PrimitiveRenderer(self._ctx, self._registry)
            if self._assets_root is not None:
                self._primitive.set_assets_root(self._assets_root)
        except ImportError:
            self._primitive = None

    def _init_flip_pass(self) -> None:
        """Compile the one-triangle present-flip pass (size-independent).

        The sampler unit is bound once while the flip program is current —
        setting a sampler uniform while ANOTHER program is current targets the
        wrong uniform type and raises GL_INVALID_OPERATION.
        """
        if self._ctx is None or self._flip_program is not None:
            return
        import struct

        self._flip_program = self._ctx.program(
            vertex_shader=_FLIP_VERT,
            fragment_shader=_FLIP_FRAG,
        )
        # Sampler unit bound once — moderngl uniform sets are DSA (no current-
        # program dependency), and the program object retains the value.
        self._flip_program["u_tex"].value = 0  # texture unit 0 (scene FBO texture)
        vertices = struct.pack("6f", -1.0, -1.0, 3.0, -1.0, -1.0, 3.0)
        self._flip_vao = self._ctx.vertex_array(
            self._flip_program, [(self._ctx.buffer(vertices), "2f", "in_pos")]
        )

    def _fallback_size(self) -> tuple[int, int]:
        return (
            min(max(self._vp_w, 1), FALLBACK_MAX_W),
            min(max(self._vp_h, 1), FALLBACK_MAX_H),
        )

    def _init_fallback_targets(self) -> None:
        width, height = self._fallback_size()
        self._fbo_texture = self._ctx.texture((width, height), 4)
        self._fbo_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
        self._fbo = self._ctx.framebuffer(color_attachments=[self._fbo_texture])
        # Benign driver flag: the FIRST framebuffer() after deleting targets
        # that were cross-bound (draw = flip FBO, unit 0 = scene texture, the
        # blit's steady state) reports GL_INVALID_OPERATION on this stack while
        # the created FBO is fully functional (proven by the pixel/orientation
        # and FBO-resize tests). Drain it right here so later ctx.error probes
        # stay meaningful; on stacks without the quirk this is one clean read.
        while self._ctx.error != "GL_NO_ERROR":
            pass
        self._init_flip_pass()
        self._flip_texture = self._ctx.texture((width, height), 4)
        self._flip_texture.filter = (moderngl.NEAREST, moderngl.NEAREST)
        self._flip_fbo = self._ctx.framebuffer(color_attachments=[self._flip_texture])

    def _recreate_fbo(self) -> None:
        width, height = self._fallback_size()
        if self._fbo is not None and self._fbo.size == (width, height):
            return
        for target in (self._fbo, self._fbo_texture, self._flip_fbo, self._flip_texture):
            if target is not None:
                try:
                    target.release()
                except Exception:
                    logger.debug("FBO release failed", exc_info=True)
        self._fbo = None
        self._fbo_texture = None
        self._flip_fbo = None
        self._flip_texture = None
        self._init_fallback_targets()

    def _build_fallback_label(self) -> None:
        # DEFAULT pure-Tk surface: an ordinary tk.Label — zero foreign child
        # windows, so the toplevel keeps native drag/resize/maximize (issue 03/04).
        self._label = tk.Label(self._frame, bg=EMPTY_STATE_BG, bd=0)
        self._label.pack(fill="both", expand=True)
        # Round 7 issue 02: explain the neutral workspace instead of showing an
        # apparently blank (white) canvas before anything is connected.
        try:
            self._empty_state = EmptyStateOverlay(self._frame, EMPTY_STATE_HINT)
        except tk.TclError:  # pragma: no cover - teardown race
            logger.debug("empty-state overlay unavailable", exc_info=True)
            self._empty_state = None
        self._update_empty_state()

    def _update_empty_state(self) -> None:
        """Show the workspace hint only while no document is loaded (issue 02)."""
        overlay = self._empty_state
        if overlay is None:
            return
        overlay.set_visible(self._doc is None)

    def _blit_fallback(self) -> None:
        """Present the scene FBO on the Tk label — DEFAULT pure-Tk pipeline.

        Per frame (issue 04 round 3, budget < 8 ms mean at default size):

        1. GPU present-flip: one triangle samples the scene FBO with inverted
           V into ``_flip_fbo`` (~0.03 ms — replaces a ~2.5 ms CPU transpose);
        2. ``read_into`` a cached bytearray (no per-frame allocation);
        3. ``Image.frombuffer("RGBA", …)`` — ZERO-COPY shared view of that
           buffer (RGB is *not* shareable in Pillow; RGBA is), no PNG encode;
        4. present: the photo is attached ONCE per size; steady state pastes
           into it (reconfiguring/rotating photos each frame costs 15 ms+).

        The label keeps the reference so Tk's GC cannot collect a displayed
        photo (flicker). Size changes rebuild buffer + view + photo.
        """
        if (
            self._fbo is None
            or self._label is None
            or self._flip_fbo is None
            or self._flip_texture is None
            or self._flip_program is None
            or self._flip_vao is None
            or self._ctx is None
        ):
            return
        size = self._fbo.size
        length = size[0] * size[1] * 4
        if self._blit_buf is None or len(self._blit_buf) != length:
            self._blit_buf = bytearray(length)
            self._blit_view = None
            self._blit_photo = None
        # 1) GPU flip: scene FBO (row 0 = bottom) -> flip FBO (row 0 = top).
        # Sampler MUST be the scene texture — sampling the bound draw target
        # would be a feedback loop (GL_INVALID_OPERATION). The sampler uniform
        # was bound in _init_flip_pass; vao.render() makes the program current.
        self._flip_fbo.use()
        self._fbo_texture.use(0)
        self._ctx.disable(moderngl.BLEND)
        self._flip_vao.render(moderngl.TRIANGLES, vertices=3)
        # 2) + 3) read top-first rows into the cached buffer, share them.
        self._flip_fbo.read_into(self._blit_buf, components=4, alignment=1)
        if self._blit_view is None:
            self._blit_view = Image.frombuffer("RGBA", size, self._blit_buf)
        # 4) present.
        photo = self._blit_photo
        if photo is None:
            photo = ImageTk.PhotoImage(self._blit_view)
            self._blit_photo = photo
            self._label._slatesync_photo = photo  # keep a reference (Tk does not)
            self._label.configure(image=photo)
        else:
            photo.paste(self._blit_view)

    def _release_gl(self) -> None:
        """Release GL objects, programs, context, and the pyglet window (idempotent)."""
        self._committed.clear()
        self._pending_nodes.clear()
        self._laser_meshes = []
        if self._tessellator is not None:
            self._tessellator.release()
            self._tessellator = None
        if self._primitive is not None:
            try:
                release = getattr(self._primitive, "release", None)
                if callable(release):
                    release()
            except Exception:
                logger.debug("PrimitiveRenderer release failed", exc_info=True)
            self._primitive = None
        for target in (
            self._fbo,
            self._fbo_texture,
            self._flip_fbo,
            self._flip_texture,
            self._flip_vao,
            self._flip_program,
        ):
            if target is not None:
                try:
                    target.release()
                except Exception:
                    logger.debug("GL target release failed", exc_info=True)
        self._fbo = None
        self._fbo_texture = None
        self._flip_fbo = None
        self._flip_texture = None
        self._flip_vao = None
        self._flip_program = None
        self._label = None
        self._blit_buf = None
        self._blit_view = None
        self._blit_photo = None
        self._registry.release()
        self._stroke_program = None
        if self._ctx is not None:
            try:  # release every GL object above, but keep the context itself
                _GL_KEEPALIVE.append(self._ctx)  # alive + current (see module note)
            except Exception:
                logger.debug("context keep-alive failed", exc_info=True)
            self._ctx = None
        window = self._window
        self._window = None
        if window is not None:
            try:
                window.close()
            except Exception:
                logger.debug("pyglet window close failed", exc_info=True)
        self._user32 = None

    # ------------------------------------------------------------------
    # Rendering (Tk main thread only)
    # ------------------------------------------------------------------
    def _render(self) -> None:
        if self._ctx is None or self._mode not in ("primary", "fallback"):
            return
        width, height = self._vp_w, self._vp_h
        if width <= 0 or height <= 0:
            return
        # moderngl 5.13 has no context-activation API: this process has exactly
        # one GL context (created on the Tk main thread), which stays current.
        if self._mode == "fallback" and self._fbo is not None:
            # DEFAULT pure-Tk path: draw OFFSCREEN into the blit source. Without
            # this, clear/draw hit the context's hidden default framebuffer and
            # the FBO (what the label shows) stays black — Doc 06's FALLBACK
            # path had this latent defect, surfaced by the round-3 pixel tests.
            self._fbo.use()
        self._sync_pending()
        self._ctx.viewport = (0, 0, width, height)
        # Issue 02 round 6 — full-viewport clear with the stale artboard
        # scissor box RESET first:
        #   • PrimitiveRenderer phase 1 stores its artboard box on the bound
        #     framebuffer (ctx.scissor = box is per-FBO, and moderngl's
        #     Framebuffer.use() RE-ENABLES GL_SCISSOR_TEST with that box);
        #   • moderngl's Framebuffer.clear() applies the FBO's stored box and
        #     re-enables the test ITSELF, so merely disabling the test before
        #     the clear does not help — with the stale box the clear only
        #     wiped the PREVIOUS artboard rect.
        # Everything drawn outside that rect — the page shadow ring and
        # off-page strokes — then blended over its own previous frame every
        # pan step: ghost strokes at old positions + darkening "smeared
        # bands" (the PC-only drag trail; round-5 offscreen fixtures never
        # panned between frames, so their outside-page columns stayed
        # white-on-white and looked clean). scissor = None resets the box to
        # the full framebuffer and turns the test off; disable_direct keeps
        # the invariant explicit (moderngl exposes no SCISSOR capability
        # constant, so the raw enum is used).
        self._ctx.scissor = None
        self._ctx.disable_direct(_GL_SCISSOR_TEST)
        self._ctx.enable(moderngl.BLEND)
        background = _parse_color(self._background_color(), 1.0)
        self._ctx.clear(background[0], background[1], background[2], 1.0)
        # Round-10 issue 06: mirrored IMAGE nodes need THIS canvas's asset
        # folder; re-resolve when the mirrored canvas changed so a missed
        # DOCUMENT_LOADED cannot pin the magenta placeholder forever.
        self._sync_assets_root()
        # Round 7 issue 06: mirror elements live in ``self._scene`` (refreshed
        # by COMMITTED_NODE) — falling back to ``doc.elements`` only keeps the
        # first frame of a freshly opened document identical to before. An
        # artboard-less mirror (mutations before any OPEN_CANVAS) borrows an
        # infinite board so primitive nodes are never silently skipped.
        artboard = self._artboard
        if artboard is None and self._doc is not None:
            artboard = getattr(self._doc, "artboard", None)
        if artboard is None and len(self._scene):
            artboard = MirrorArtboard()
        if self._primitive is not None and artboard is not None:
            nodes = self._scene.nodes()
            if not nodes:
                nodes = list(getattr(self._doc, "elements", None) or [])
            bounds = self._content_bounds or dict(
                getattr(self._doc, "content_bounds", None) or {}
            )
            try:
                self._primitive.render(nodes, self._camera, artboard, bounds)
            except Exception:
                logger.exception("PrimitiveRenderer.render failed (Doc 08)")
        for mesh, color, blend_mode in self._committed.values():
            self._draw_mesh(mesh, color, blend_mode)
        live = self._tessellator.live_mesh if self._tessellator is not None else None
        if live is not None:
            live_blend = 1 if self._live_tool == TOOL_HIGHLIGHTER else 0
            self._draw_mesh(live, _parse_color(DEFAULT_COLOR, 1.0), live_blend)
        for laser_mesh in self._laser_meshes:
            self._draw_mesh(laser_mesh, LASER_COLOR, 0)

    def _sync_pending(self) -> None:
        """Tessellate queued commits / live stroke / laser — GL work, main thread."""
        tess = self._tessellator
        if tess is None or self._stroke_program is None:
            return
        tess.scale = self._camera[0]
        built = 0
        while self._pending_nodes and built < _COMMIT_BUDGET:
            self._commit_node(self._pending_nodes.pop(0))
            built += 1
        if self._pending_nodes:
            self.request_redraw()  # continue next tick (bounded per-frame work)
        if self._live_active and self._live_dirty:
            tess.width_pressure_factor = self._live_wpf
            tess.append_live(self._live_points, self._live_pressure, self._live_width)
            self._live_dirty = False
        self._sync_laser()

    def _commit_node(self, node: object) -> None:
        kind = str(getattr(node, "kind", "") or "")
        if kind not in _STROKE_KINDS:
            return  # SHAPE/GRAPH_AXES/IMAGE belong to Doc 08's renderer
        geometry = getattr(node, "geometry", None)
        raw = getattr(geometry, "pts", None) or []
        points = [
            (float(p[0]), float(p[1]))
            for p in raw
            if isinstance(p, (list, tuple)) and len(p) >= 2
        ]
        if not points:
            return
        style = getattr(node, "style", None)
        width = float(getattr(style, "stroke_width", DEFAULT_STROKE_WIDTH))
        color = _parse_color(
            str(getattr(style, "color", DEFAULT_COLOR)), float(getattr(style, "opacity", 1.0))
        )
        blend_mode = (
            1
            if kind == "HIGHLIGHT" or str(getattr(style, "blend_mode", "")) == "MULTIPLY"
            else 0
        )
        tess = self._tessellator
        tess.width_pressure_factor = 0.0  # committed payloads keep style.stroke_width base
        if kind == "LINE":
            # r6-pc-line-gl: normative LINE geometry (exporters + mobile
            # canvas_shape_conventions) — ALWAYS the straight first→last
            # segment. Never spline the anchors (Catmull-Rom wanders off the
            # segment through intermediate anchors) and never let a Doc 21
            # chain-layout guess reinterpret multi-anchor pts as Béziers
            # (n ≡ 1,2 mod 3 ≥ 4 sampled as control chains). Feed the mesh
            # pipeline exactly [start, end]; a single-point LINE stays a dot.
            flat = [points[0], points[-1]] if len(points) >= 2 else points
        else:
            # Doc 21 chain layout (issue 05 round 5): committed nodes carry Bézier
            # control chains — tessellate the EXACT cubics, never re-fit controls
            # as Catmull-Rom anchors (that wanders tens of world units off-path).
            flat = flatten_stroke_path(points, scale=tess.scale)
        mesh = tess.build_stroke(flat, [1.0] * len(flat), width)
        node_id = str(getattr(node, "node_id", "") or f"__node_{id(node)}")
        self._committed[node_id] = (mesh, color, blend_mode)

    def _sync_laser(self) -> None:
        if self._laser is None:
            if self._laser_meshes:
                self._laser_meshes = []
            return
        key = (self._laser[0], self._laser[1], self._camera[0])
        if key == self._laser_key:
            return
        scale = self._camera[0]
        x, y = self._laser
        arm = LASER_ARM_PX / scale
        thickness = LASER_THICK_PX / scale
        tess = self._tessellator
        self._laser_meshes = [
            tess.build_stroke([(x - arm, y), (x + arm, y)], [1.0, 1.0], thickness),
            tess.build_stroke([(x, y - arm), (x, y + arm)], [1.0, 1.0], thickness),
        ]
        self._laser_key = key

    def _draw_mesh(
        self,
        mesh: TessellatedMesh,
        color: tuple[float, float, float, float],
        blend_mode: int,
    ) -> None:
        """Strip body + both cap fans from one VAO, with per-draw blend state."""
        if self._stroke_program is None or mesh.vertex_count <= 0:
            return
        program = self._stroke_program
        program["u_camera"].value = self._camera
        program["u_viewport"].value = (float(self._vp_w), float(self._vp_h))
        program["u_color"].value = color[:3]
        program["u_opacity"].value = color[3]
        program["u_blendMode"].value = int(blend_mode)
        self._ctx.blend_func = _MULTIPLY_BLEND if blend_mode == 1 else _SRC_OVER_BLEND
        cap = CAP_VERTS // 2  # 10 verts per 8-seg fan (center + 9 rim)
        strip = mesh.vertex_count - CAP_VERTS
        if strip > 0:
            mesh.vao.render(moderngl.TRIANGLE_STRIP, vertices=strip, first=0)
        if mesh.vertex_count >= CAP_VERTS:  # both cap fans are baked into every mesh
            mesh.vao.render(moderngl.TRIANGLE_FAN, vertices=cap, first=max(strip, 0))
            mesh.vao.render(
                moderngl.TRIANGLE_FAN, vertices=cap, first=max(strip, 0) + cap
            )

    def _background_color(self) -> str:
        """Clear colour: the artboard paper, else the neutral empty workspace.

        Round 7 issue 02: with no document/artboard the viewport must NOT look
        like a white page — it clears to :data:`EMPTY_STATE_BG` so a freshly
        launched PC agent is visibly idle instead of showing an apparently
        blank canvas before anything is connected.
        """
        artboard = self._artboard
        if artboard is None and self._doc is not None:
            artboard = getattr(self._doc, "artboard", None)
        if artboard is None:
            return EMPTY_STATE_BG
        return str(getattr(artboard, "background_color", "#FFFFFF") or "#FFFFFF")

    # ------------------------------------------------------------------
    # Tk glue
    # ------------------------------------------------------------------
    def _on_configure(self, event: tk.Event) -> None:
        self.resize(event.width, event.height)
