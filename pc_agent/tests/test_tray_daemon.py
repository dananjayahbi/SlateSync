"""Tests for the pystray background tray daemon (Doc 17 §6).

No display or pystray loop is required except the final guarded smoke test —
the icon is faked everywhere else.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

import pytest

import pc_agent.gui.tray_daemon as tray_module
from pc_agent.core.events import LIVE_FRAME, EventBus
from pc_agent.gui.tray_daemon import TrayDaemon


class _FakeIcon:
    """Stand-in for ``pystray.Icon``: blocking loop gated by an event (§6.3)."""

    def __init__(self) -> None:
        self._gate = threading.Event()
        self.run_calls = 0
        self.stop_calls = 0
        self.notify_calls: list[tuple[str, str | None]] = []

    def run(self) -> None:
        self.run_calls += 1
        self._gate.wait(3.0)

    def stop(self) -> None:
        self.stop_calls += 1
        self._gate.set()

    def notify(self, message: str, title: str | None = None) -> None:
        self.notify_calls.append((message, title))


class _RecordingBus(EventBus):
    """EventBus spy recording ``on`` / ``off`` registrations (§6.5)."""

    def __init__(self) -> None:
        super().__init__()
        self.on_calls: list[tuple[str, object]] = []
        self.off_calls: list[tuple[str, object]] = []

    def on(self, event: str, handler: object) -> None:
        self.on_calls.append((event, handler))
        super().on(event, handler)  # type: ignore[arg-type]

    def off(self, event: str, handler: object) -> None:
        self.off_calls.append((event, handler))
        super().off(event, handler)  # type: ignore[arg-type]


def _start_fake(d: TrayDaemon, fake: _FakeIcon) -> threading.Thread:
    """Inject the fake icon and start, waiting until its loop is entered."""
    d._icon = fake
    d.start()
    thread = d._thread
    assert thread is not None
    deadline = time.monotonic() + 1.0
    while fake.run_calls == 0 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert fake.run_calls == 1
    return thread


def test_construction_without_loop() -> None:
    shown: list[int] = []
    quit_: list[int] = []
    d = TrayDaemon(lambda: shown.append(1), lambda: quit_.append(1))
    assert d._running is False
    assert d._thread is None
    assert d._icon is None
    assert shown == [] and quit_ == []


def test_throttle_hundred_rapid_emits_fire_once_then_at_1s_spacing() -> None:
    fires: list[float] = []
    now = [500.0]
    d = TrayDaemon(lambda: fires.append(now[0]), lambda: None)
    d._clock = lambda: now[0]
    bus = EventBus()
    d.bind_bus(bus)

    for _ in range(100):  # 100 rapid LIVE_FRAME emits at one timestamp
        bus.emit(LIVE_FRAME, frame=None)
    assert fires == [500.0]

    now[0] = 500.999  # still below the 1.0 s window
    bus.emit(LIVE_FRAME, frame=None)
    assert fires == [500.0]

    now[0] = 501.0  # spacing exactly 1.0 s → allowed
    bus.emit(LIVE_FRAME, frame=None)
    assert fires == [500.0, 501.0]

    for _ in range(100):  # rapid stream at the new timestamp → no extra fire
        bus.emit(LIVE_FRAME, frame=None)
    assert fires == [500.0, 501.0]

    now[0] = 502.0
    d._on_live_frame(None)  # positional call path as well
    assert fires == [500.0, 501.0, 502.0]
    assert all(b - a >= 1.0 for a, b in zip(fires, fires[1:]))


def test_bind_bus_registers_exactly_one_live_frame_handler() -> None:
    shown: list[int] = []
    d = TrayDaemon(lambda: shown.append(1), lambda: None)
    bus = _RecordingBus()
    d.bind_bus(bus)
    assert len(bus.on_calls) == 1
    event, handler = bus.on_calls[0]
    assert event == LIVE_FRAME
    assert handler == d._on_live_frame
    assert d._thread is None  # binding never starts the loop
    bus.emit(LIVE_FRAME, frame=None)
    assert shown == [1]  # registration actually delivers


def test_start_stop_idempotent_with_faked_icon() -> None:
    d = TrayDaemon(lambda: None, lambda: None)
    fake = _FakeIcon()
    first = _start_fake(d, fake)
    assert first.name == "SlateSyncTray"
    assert first.daemon is True

    d.start()  # second start no-ops while running
    assert d._thread is first
    assert sum(1 for t in threading.enumerate() if t.name == "SlateSyncTray") == 1

    t0 = time.perf_counter()
    d.stop()
    elapsed = time.perf_counter() - t0
    assert elapsed <= 2.0  # join budget
    assert d._running is False
    assert not first.is_alive()
    assert fake.stop_calls == 1

    d.stop()  # idempotent: early-return without touching the icon again
    assert fake.stop_calls == 1


def test_stop_without_start_is_noop() -> None:
    d = TrayDaemon(lambda: None, lambda: None)
    d.stop()  # never started → no-op, no hang, no Tk
    assert d._running is False
    assert d._icon is None


def test_stop_never_joins_the_caller_thread() -> None:
    d = TrayDaemon(lambda: None, lambda: None)
    fake = _FakeIcon()
    d._icon = fake
    d._running = True
    d._thread = threading.current_thread()  # pathological: caller is the loop
    d.stop()  # must skip the self-join instead of raising/hanging
    assert d._running is False
    assert fake.stop_calls == 1


def test_quit_menu_callback_invokes_on_quit_once_and_menu_contract() -> None:
    quit_: list[int] = []
    shown: list[int] = []
    d = TrayDaemon(lambda: shown.append(1), lambda: quit_.append(1))
    d._handle_quit(None)  # pystray passes the icon as first arg — wrapper ignores it
    assert quit_ == [1]

    menu = d._build_menu()
    items = list(menu)
    assert [item.text for item in items] == ["Show Studio", "Quit"]
    assert items[0].default is True
    assert items[1].default is False
    d._handle_show(None)
    assert shown == [1]


def test_build_image_covers_shell_sizes() -> None:
    asset = TrayDaemon(lambda: None, lambda: None)._build_image()
    assert asset.size16.size == (16, 16)
    assert asset.size32.size == (32, 32)
    assert asset.size48.size == (48, 48)
    assert asset.size48.mode == "RGBA"


def test_notify_guarded_and_routed() -> None:
    d = TrayDaemon(lambda: None, lambda: None)
    d.notify("Title", "Body")  # before start → guarded no-op, icon never created
    assert d._icon is None

    fake = _FakeIcon()
    _start_fake(d, fake)
    d.notify("Title", "Body")
    assert fake.notify_calls == [("Body", "Title")]  # pystray: notify(message, title)

    d.stop()
    d.notify("Title 2", "Body 2")  # after stop → guarded no-op
    assert fake.notify_calls == [("Body", "Title")]


def test_module_never_imports_tk() -> None:
    src = Path(tray_module.__file__).read_text(encoding="utf-8")
    assert "tkinter" not in src
    assert "customtkinter" not in src


def _pystray_smoke_once() -> str:
    """One start/notify/stop cycle → 'pass' | 'slow:<s>' | 'skip:<reason>'."""
    d = TrayDaemon(lambda: None, lambda: None)
    try:
        d.start()
    except Exception as exc:  # backend init failure is the only skip reason
        return f"skip:pystray backend unavailable in this session: {exc!r}"
    thread = d._thread
    assert thread is not None
    time.sleep(0.5)  # let the icon backend create its window / shell icon
    if not thread.is_alive():
        try:
            d.stop()
        except Exception:
            d._running = False
        return "skip:pystray could not initialise a backend in this session"
    d.notify("SlateSync", "tray smoke")
    assert thread.is_alive()
    t0 = time.perf_counter()
    d.stop()
    elapsed = time.perf_counter() - t0
    assert d._running is False
    assert not thread.is_alive()
    return "pass" if elapsed <= 2.0 else f"slow:{elapsed:.1f}"


def test_real_pystray_start_stop_smoke() -> None:
    """≤3 s smoke around a real pystray loop; skips only if no backend inits.

    Load-transient retry: shared-machine CPU contention can stall pystray's
    pump thread past the 2 s stop budget (pystray itself only warns after 5 s).
    The ≤2 s contract is retried on a fresh daemon — never relaxed.
    """
    slowest = 0.0
    for _attempt in range(3):
        outcome = _pystray_smoke_once()
        if outcome.startswith("skip:"):
            pytest.skip(outcome[len("skip:"):])
        if outcome == "pass":
            return
        slowest = max(slowest, float(outcome[len("slow:"):]))
    pytest.fail(
        f"pystray stop never met the 2 s budget across 3 attempts (slowest {slowest:.1f} s)"
    )
