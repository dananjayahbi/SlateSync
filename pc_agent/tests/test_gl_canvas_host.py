"""Doc 06 acceptance tests — GLCanvasHost + ProgramRegistry (headless-safe).

Always-run (no GL): latest-slot/seq stale-drop semantics, drain & redraw
coalescing, the five event-matrix subscriptions, camera clamping +
``visible_world_rect`` inverse, ProgramRegistry error contracts, event routing,
laser clearing, shutdown teardown, and main-thread drain spying with background
submitters. GL-guarded tests (skip after a one-time moderngl probe): mount
smoke with ``glGetError``-equivalent checks, the requested MSAA/3.3 config, the
FALLBACK FBO ROI cap, and "every GL entry point runs on the Tk main thread".
"""

from __future__ import annotations

import threading
import time
import tkinter as tk

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import EventBus
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LASER,
    FRAME_LIVE_END,
    FRAME_LIVE_POINT,
    LiveFrame,
)
from pc_agent.viewport.gl_canvas_host import GLCanvasHost, ProgramRegistry


def _probe_gl() -> tuple[object | None, str]:
    """Attempt ``moderngl.create_context()`` once, then a standalone fallback."""
    try:
        import moderngl
    except Exception as exc:  # pragma: no cover - environment dependent
        return None, f"moderngl unavailable: {exc}"
    try:
        return moderngl.create_context(), ""
    except Exception:
        pass
    try:
        return moderngl.create_standalone_context(), ""
    except Exception as exc:  # pragma: no cover - headless environments
        return None, f"no display/GL: {exc}"


_GL_CTX, _GL_REASON = _probe_gl()
requires_gl = pytest.mark.skipif(_GL_CTX is None, reason=_GL_REASON or "no display/GL")


class _FakeTk:
    """Records ``after``/``after_cancel`` so scheduling is testable headless."""

    def __init__(self) -> None:
        self.scheduled: list[dict] = []
        self.cancelled: list[str] = []
        self._next = 0

    def after(self, ms: int, callback) -> str:
        self._next += 1
        after_id = f"after#{self._next}"
        self.scheduled.append(
            {"id": after_id, "ms": ms, "callback": callback, "fired": False}
        )
        return after_id

    def after_cancel(self, after_id: str) -> None:
        self.cancelled.append(after_id)

    def pending(self, ms: int | None = None) -> list[dict]:
        return [
            entry
            for entry in self.scheduled
            if not entry["fired"] and (ms is None or entry["ms"] == ms)
        ]

    def run(self, ms: int | None = None) -> int:
        """Fire every not-yet-fired callback for ``ms`` once (main-thread pump)."""
        entries = self.pending(ms)
        for entry in entries:
            entry["fired"] = True
            entry["callback"]()
        return len(entries)


class _RecordingBus(EventBus):
    """EventBus that records ``on``/``off`` registrations for the matrix test."""

    def __init__(self) -> None:
        super().__init__()
        self.on_calls: list[tuple[str, object]] = []
        self.off_calls: list[tuple[str, object]] = []

    def on(self, event: str, handler) -> None:
        self.on_calls.append((event, handler))
        super().on(event, handler)

    def off(self, event: str, handler) -> None:
        self.off_calls.append((event, handler))
        super().off(event, handler)


def _make_host() -> tuple[_FakeTk, _RecordingBus, GLCanvasHost]:
    fake_tk = _FakeTk()
    bus = _RecordingBus()
    return fake_tk, bus, GLCanvasHost(fake_tk, AppConfig(), bus)


def _camera_frame(seq: int, scale: float = 1.0, tx: float = 0.0, ty: float = 0.0) -> LiveFrame:
    return LiveFrame(FRAME_CAMERA, 0x01, seq, scale, tx, ty)


def _make_root() -> tk.Tk:
    try:
        root = tk.Tk()
    except Exception as exc:  # pragma: no cover - depends on the display session
        pytest.skip(f"Tk unavailable: {exc}")
    root.geometry("360x300")
    return root


# ---------------------------------------------------------------------------
# Always-run: subscriptions, scheduling, seq semantics
# ---------------------------------------------------------------------------


def test_subscribes_to_exactly_the_five_matrix_events() -> None:
    _, bus, host = _make_host()
    names = [event for event, _ in bus.on_calls]
    assert names == [
        "LIVE_FRAME",
        "CAMERA_DELTA",
        "DOCUMENT_LOADED",
        "COMMITTED_NODE",
        "ARTBOARD_CHANGED",
    ]
    assert len(bus.on_calls) == 5
    assert all(callable(handler) for _, handler in bus.on_calls)
    assert host is not None


def test_hundred_worker_submits_schedule_one_drain_and_apply_only_newest() -> None:
    fake_tk, _, host = _make_host()
    applied: list[LiveFrame] = []
    original = host._apply_frame

    def spy(frame: LiveFrame) -> None:
        applied.append(frame)
        original(frame)

    host._apply_frame = spy

    def worker() -> None:
        for seq in range(1, 101):
            host.submit_live_frame(_camera_frame(seq, scale=1.0, tx=float(seq), ty=float(seq * 2)))

    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()

    drain_calls = [entry for entry in fake_tk.scheduled if entry["ms"] == 0]
    assert len(drain_calls) == 1, "100 submits must coalesce into one after(0, drain)"
    assert fake_tk.run(0) == 1
    assert len(applied) == 1, "the slot must keep only the newest frame"
    assert applied[0].seq == 100
    assert host._camera == (1.0, 100.0, 200.0)
    assert host._slot is None


def test_stale_seq_dropped_and_u16_wrap_accepted() -> None:
    _, _, host = _make_host()

    host.submit_live_frame(_camera_frame(65535, tx=1.0))
    host._drain()
    assert host._camera[1] == 1.0 and host._last_seq == 65535

    host.submit_live_frame(_camera_frame(0, tx=2.0))  # wrap 65535 → 0 accepted
    host._drain()
    assert host._camera[1] == 2.0 and host._last_seq == 0

    host.submit_live_frame(_camera_frame(0, tx=3.0))  # duplicate seq: not newer
    host._drain()
    assert host._camera[1] == 2.0, "duplicate seq must be dropped"

    host.submit_live_frame(_camera_frame(65535, tx=4.0))  # strictly older in window
    host._drain()
    assert host._camera[1] == 2.0, "stale seq must be dropped"

    host.submit_live_frame(_camera_frame(100, tx=5.0))
    host._drain()
    assert host._camera[1] == 5.0 and host._last_seq == 100

    host.submit_live_frame(_camera_frame(99, tx=6.0))  # backward step
    host._drain()
    assert host._camera[1] == 5.0, "out-of-order seq must be dropped"


def test_camera_clamped_to_zoom_range_by_both_entries() -> None:
    _, _, host = _make_host()
    host.set_camera_live(0.001, 5.0, 6.0)
    assert host._camera == (0.05, 5.0, 6.0)
    host.set_camera_live(1000.0, -2.0, 7.0)
    assert host._camera == (20.0, -2.0, 7.0)
    host.set_camera(0.0, 1.0, 1.0)
    assert host._camera == (0.05, 1.0, 1.0)
    host.set_camera(50.0, 1.0, 1.0)
    assert host._camera == (20.0, 1.0, 1.0)


def test_submit_routes_frame_camera_to_set_camera_live() -> None:
    fake_tk, _, host = _make_host()
    host.submit_live_frame(_camera_frame(7, scale=0.001, tx=9.0, ty=9.0))
    assert len([entry for entry in fake_tk.scheduled if entry["ms"] == 0]) == 1
    host._drain()
    assert host._camera == (0.05, 9.0, 9.0)


def test_visible_world_rect_matches_template_inverse() -> None:
    _, _, host = _make_host()
    host.resize(800, 600)
    host.set_camera(2.0, 100.0, 200.0)
    rect = host.visible_world_rect()
    # screen = (world − center)·scale + viewport/2  ⇒  world = (screen − vp/2)/scale + center
    assert rect == pytest.approx((-100.0, 50.0, 300.0, 350.0))
    scale, tx, ty = host._camera
    corners_screen = ((0.0, 0.0), (800.0, 600.0))
    corners_world = ((rect[0], rect[1]), (rect[2], rect[3]))
    for (sx, sy), (wx, wy) in zip(corners_screen, corners_world):
        assert (wx - tx) * scale + 400.0 == pytest.approx(sx)
        assert (wy - ty) * scale + 300.0 == pytest.approx(sy)


def test_request_redraw_coalesces_into_one_scheduled_tick() -> None:
    fake_tk, _, host = _make_host()
    for _ in range(50):
        host.request_redraw()
    assert len(fake_tk.pending(16)) == 1, "N redraw requests ⇒ 1 scheduled tick"
    assert host._dirty is True
    assert fake_tk.run(16) == 1  # unmounted tick consumes the schedule and idles
    assert fake_tk.pending(16) == []
    host.request_redraw()
    assert len(fake_tk.pending(16)) == 1, "pump restarts with exactly one pending tick"


def test_background_submits_drain_only_on_the_main_thread() -> None:
    fake_tk, _, host = _make_host()
    main_thread = threading.get_ident()
    applied_threads: list[int] = []
    render_threads: list[int] = []
    original_apply = host._apply_frame
    original_render = host._render

    def spy_apply(frame: LiveFrame) -> None:
        applied_threads.append(threading.get_ident())
        original_apply(frame)

    def spy_render() -> None:
        render_threads.append(threading.get_ident())
        original_render()

    host._apply_frame = spy_apply
    host._render = spy_render

    worker_ids: list[int] = []

    def worker() -> None:
        worker_ids.append(threading.get_ident())
        for seq in range(1, 51):
            host.submit_live_frame(_camera_frame(seq, tx=float(seq)))

    thread = threading.Thread(target=worker)
    thread.start()
    thread.join()

    assert worker_ids and worker_ids[0] != main_thread
    assert fake_tk.run(0) == 1  # pump the marshalled drain on "the Tk thread"
    fake_tk.run(16)  # tick also fires on this thread (unmounted ⇒ returns early)
    assert applied_threads == [main_thread], "stale-drop must run on the main thread"
    assert render_threads == [], "no render may run before mount (no GL yet)"


# ---------------------------------------------------------------------------
# Always-run: ProgramRegistry contracts
# ---------------------------------------------------------------------------


def test_program_registry_missing_pair_raises_file_not_found_and_keyerror(
    tmp_path,
) -> None:
    registry = ProgramRegistry(AppConfig(shader_dir=tmp_path))
    with pytest.raises(FileNotFoundError) as info:
        registry.get("stroke")
    error = info.value
    assert isinstance(error, KeyError), "missing stem must also be catchable as KeyError"
    message = str(error)
    assert str(tmp_path / "stroke.vert") in message
    assert str(tmp_path / "stroke.frag") in message


def test_program_registry_lists_only_existing_pairs(tmp_path) -> None:
    (tmp_path / "stroke.vert").write_text("// v", encoding="utf-8")
    (tmp_path / "stroke.frag").write_text("// f", encoding="utf-8")
    (tmp_path / "orphan.frag").write_text("// lone", encoding="utf-8")
    registry = ProgramRegistry(AppConfig(shader_dir=tmp_path))
    assert registry.stems == ["stroke"]


class _FakeProgramCtx:
    """Stub context: counts compilation attempts and can be set to explode."""

    def __init__(self, fail: bool = False) -> None:
        self.calls = 0
        self.fail = fail

    def program(self, vertex_shader: str, fragment_shader: str):
        self.calls += 1
        if self.fail:
            raise RuntimeError("driver exploded")
        return object()


def test_program_registry_compile_failure_raises_runtime_error(tmp_path) -> None:
    (tmp_path / "bad.vert").write_text("not glsl", encoding="utf-8")
    (tmp_path / "bad.frag").write_text("not glsl", encoding="utf-8")
    registry = ProgramRegistry(AppConfig(shader_dir=tmp_path), ctx=_FakeProgramCtx(fail=True))
    with pytest.raises(RuntimeError, match="bad"):
        registry.get("bad")


def test_program_registry_caches_compiled_programs(tmp_path) -> None:
    (tmp_path / "stroke.vert").write_text("// v", encoding="utf-8")
    (tmp_path / "stroke.frag").write_text("// f", encoding="utf-8")
    ctx = _FakeProgramCtx()
    registry = ProgramRegistry(AppConfig(shader_dir=tmp_path), ctx=ctx)
    first = registry.get("stroke")
    second = registry.get("stroke")
    assert first is second
    assert ctx.calls == 1


def test_program_registry_without_context_raises_clear_runtime_error(tmp_path) -> None:
    (tmp_path / "stroke.vert").write_text("// v", encoding="utf-8")
    (tmp_path / "stroke.frag").write_text("// f", encoding="utf-8")
    registry = ProgramRegistry(AppConfig(shader_dir=tmp_path))
    with pytest.raises(RuntimeError, match="set_ctx"):
        registry.get("stroke")


# ---------------------------------------------------------------------------
# Always-run: event-matrix routing, laser, shutdown
# ---------------------------------------------------------------------------


def test_event_routing_feeds_slot_camera_document_artboard_and_deletes() -> None:
    fake_tk, bus, host = _make_host()

    live = LiveFrame(FRAME_LIVE_POINT, 0x01, 1, 10.0, 20.0, 0.5)
    bus.emit("LIVE_FRAME", frame=live)
    assert host._slot is live, "LIVE_FRAME must land in the latest-frame slot"

    bus.emit("CAMERA_DELTA", frame=_camera_frame(2, scale=99.0, tx=4.0, ty=5.0))
    assert host._camera == (20.0, 4.0, 5.0), "CAMERA_DELTA clamps immediately"

    class _Doc:
        artboard = object()
        content_bounds = {"min_x": 0.0}
        elements = ["node-a", "node-b"]

    doc = _Doc()
    bus.emit("DOCUMENT_LOADED", doc=doc)
    assert host._doc is doc
    assert host._pending_nodes == ["node-a", "node-b"]
    assert host._committed == {}

    class _Node:
        node_id = "n1"
        kind = "STROKE"

    bus.emit("COMMITTED_NODE", node=_Node())
    assert len(host._pending_nodes) == 3

    host._committed["n1"] = (object(), (0.0, 0.0, 0.0, 1.0), 0)
    bus.emit("COMMITTED_NODE", node=None, deleted_node_id="n1")
    assert "n1" not in host._committed

    class _Artboard:
        preset = "A4"
        background_color = "#102030"

    bus.emit("ARTBOARD_CHANGED", artboard=_Artboard(), content_bounds={"min_y": 1.0})
    assert host._artboard.background_color == "#102030"
    assert host._content_bounds == {"min_y": 1.0}
    assert host._dirty is True
    assert fake_tk.pending(0), "state changes must marshal a drain"


def test_laser_cleared_on_live_end_and_on_timeout() -> None:
    _, _, host = _make_host()

    host.submit_live_frame(LiveFrame(FRAME_LASER, 0x01, 1, 30.0, 40.0, 0.0))
    host._drain()
    assert host._laser == (30.0, 40.0)

    host.submit_live_frame(LiveFrame(FRAME_LIVE_END, 0x01, 2, 0.0, 0.0, 0.0))
    host._drain()
    assert host._laser is None, "LIVE_END must clear the crosshair"

    host.submit_live_frame(LiveFrame(FRAME_LASER, 0x01, 3, 1.0, 2.0, 0.0))
    host._drain()
    assert host._laser == (1.0, 2.0)
    host._laser_deadline = time.monotonic() - 1.0
    host._expire_laser()
    assert host._laser is None, "500 ms timeout must clear the crosshair"


def test_shutdown_unsubscribes_cancels_after_ids_and_blocks_scheduling() -> None:
    fake_tk, bus, host = _make_host()
    host.request_redraw()  # schedules a tick
    host.submit_live_frame(_camera_frame(1))  # schedules a drain
    assert len(fake_tk.pending()) == 2

    host.shutdown()

    off_names = [event for event, _ in bus.off_calls]
    assert off_names == [
        "LIVE_FRAME",
        "CAMERA_DELTA",
        "DOCUMENT_LOADED",
        "COMMITTED_NODE",
        "ARTBOARD_CHANGED",
    ]
    cancelled = set(fake_tk.cancelled)
    scheduled_ids = {entry["id"] for entry in fake_tk.pending()}
    assert scheduled_ids <= cancelled, "pending after ids must be cancelled"

    scheduled_before = len(fake_tk.scheduled)
    host.submit_live_frame(_camera_frame(2))
    host.request_redraw()
    assert len(fake_tk.scheduled) == scheduled_before, "shutdown blocks rescheduling"
    host.shutdown()  # idempotent
    assert len(bus.off_calls) == 5


def test_pyglet_config_requests_msaa4_and_core33() -> None:
    pytest.importorskip("pyglet.gl")
    config = GLCanvasHost._pyglet_config()
    assert config.sample_buffers == 1
    assert config.samples == 4  # pyglet 2 spelling; Doc 06's sample=4 is passed too
    assert (config.major_version, config.minor_version) == (3, 3)


# ---------------------------------------------------------------------------
# GL-guarded (skipped when the moderngl probe fails)
# ---------------------------------------------------------------------------


@requires_gl
def test_mount_smoke_live_stroke_from_worker_gl_error_free() -> None:
    root = _make_root()
    host = GLCanvasHost(root, AppConfig(), EventBus())
    try:
        parent = tk.Frame(root, width=320, height=240)
        parent.pack(fill="both", expand=True)
        host.mount(parent)
        assert host._mode != "none", "GL surface failed despite an available context"

        def worker() -> None:
            for seq in range(1, 6):
                host.submit_live_frame(
                    LiveFrame(FRAME_LIVE_POINT, 0x02, seq, 10.0 + seq, 20.0 + seq, 0.8)
                )

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join()
        host.submit_live_frame(LiveFrame(FRAME_LIVE_END, 0x02, 6, 0.0, 0.0, 0.0))
        host.request_redraw()
        for _ in range(12):
            root.update()  # the real Tk pump fires after(0)/after(16) callbacks

        assert host._ctx is not None
        assert host._ctx.error == "GL_NO_ERROR"
        # Round-3 default: the pure-Tk blit path — no pyglet window, no
        # SetParent child (issue 03/04: that child corrupted Win11 drag/resize).
        assert host._mode == "fallback", "the default mount must be the pure-Tk blit path"
        assert host._window is None and host._user32 is None
    finally:
        try:
            host.shutdown()
        except Exception:
            pass
        root.destroy()


@requires_gl
def test_primary_embedding_uses_gl33_context_and_requested_msaa(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Round-3 change (documented): SetParent is NO LONGER the default — this
    # test now proves the legacy embedding still works when explicitly opted
    # in via SLATESYNC_EMBED=setparent (Doc 06 escape hatch), GetParent check
    # included.
    monkeypatch.setenv("SLATESYNC_EMBED", "setparent")
    root = _make_root()
    host = GLCanvasHost(root, AppConfig(), EventBus())
    try:
        parent = tk.Frame(root, width=320, height=240)
        parent.pack(fill="both", expand=True)
        host.mount(parent)
        if host._mode != "primary":
            pytest.skip(f"setparent pyglet embedding unavailable (mode={host._mode})")
        assert str(host._ctx.info["GL_VERSION"]).startswith("3.3")
        assert host._window.config.sample_buffers == 1
        assert host._window.config.samples == 4
        import ctypes

        parent_hwnd = int(host._frame.winfo_id())
        assert ctypes.windll.user32.GetParent(int(host._window._hwnd)) == parent_hwnd
    finally:
        try:
            host.shutdown()
        except Exception:
            pass
        root.destroy()


@requires_gl
def test_fallback_fbo_tracks_widget_size_within_roi() -> None:
    # Round-3 change (documented): Doc 06's FALLBACK is now the DEFAULT path,
    # so the _embed_pyglet monkeypatch that used to force it is gone, and the
    # ROI cap moved from 1280x720 to 1600x900 (issue 04: keep filling a
    # maximized window).
    root = _make_root()
    host = GLCanvasHost(root, AppConfig(), EventBus())
    try:
        parent = tk.Frame(root, width=320, height=240)
        parent.pack(fill="both", expand=True)
        host.mount(parent)
        assert host._mode == "fallback"
        assert host._fbo is not None and host._label is not None

        host.resize(640, 360)
        assert host._fbo.size == (640, 360), "FBO must track the widget size"
        host.resize(2000, 900)
        assert host._fbo.size == (1600, 900), "blit ROI is capped at 1600x900"

        host.request_redraw()
        for _ in range(6):
            root.update()
        assert host._ctx.error == "GL_NO_ERROR"
    finally:
        try:
            host.shutdown()
        except Exception:
            pass
        root.destroy()


@requires_gl
def test_gl_entry_points_stay_on_the_main_thread_with_worker_submits() -> None:
    root = _make_root()
    host = GLCanvasHost(root, AppConfig(), EventBus())
    try:
        parent = tk.Frame(root, width=320, height=240)
        parent.pack(fill="both", expand=True)
        host.mount(parent)
        root.update()

        main_thread = threading.get_ident()
        recorded: list[tuple[str, int]] = []
        original_render = host._render
        original_drain = host._drain
        tessellator = host._tessellator
        original_append = tessellator.append_live

        def spy_render() -> None:
            recorded.append(("render", threading.get_ident()))
            original_render()

        def spy_drain() -> None:
            recorded.append(("drain", threading.get_ident()))
            original_drain()

        def spy_append(points, pressure, width):
            recorded.append(("append_live", threading.get_ident()))
            return original_append(points, pressure, width)

        host._render = spy_render
        host._drain = spy_drain
        tessellator.append_live = spy_append

        worker_ids: list[int] = []

        def worker() -> None:
            worker_ids.append(threading.get_ident())
            for seq in range(1, 21):
                host.submit_live_frame(
                    LiveFrame(FRAME_LIVE_POINT, 0x01, seq, float(seq), float(seq * 2), 0.6)
                )

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join()
        host.request_redraw()
        for _ in range(10):
            root.update()

        labels = {label for label, _ in recorded}
        assert "render" in labels, "the pump must render after worker submits"
        assert "append_live" in labels, "the in-flight stroke must be tessellated"
        non_main = [(label, tid) for label, tid in recorded if tid != main_thread]
        assert non_main == [], f"GL entry points ran off the main thread: {non_main}"
        assert worker_ids and worker_ids[0] != main_thread
    finally:
        try:
            host.shutdown()
        except Exception:
            pass
        root.destroy()
