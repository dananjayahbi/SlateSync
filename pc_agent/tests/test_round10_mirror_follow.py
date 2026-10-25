"""Round 10 — the PC mirror follows the device that owns it.

Issue 02 report: a RULED canvas opened on the tablet, then the *same* device
switched to a BLANK canvas. The mobile viewport changed but the PC mirror kept
the ruled paper — and kept mirroring the old canvas id.

Root cause: ``_on_open_canvas`` returns early (persist-only) whenever a mirror
is already selected. That early return exists so a *second* device cannot steal
the mirror (round-7 issue 07), but it also froze the *owning* device's switches.

These tests pin the three rules that must hold together:

* the owning device switching canvases MOVES the mirror (issue 02);
* a different device still cannot steal it (round-7 issue 07);
* an explicit Settings choice stays pinned until it is cleared.
"""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CONNECTION_STATE,
    MIRROR_CHANGED,
    RPC_MESSAGE,
    RPC_ORIGIN,
    EventBus,
)
from pc_agent.engine.document_store import DocumentStore
from pc_agent.engine.scene_graph import SceneGraph
from pc_agent.network.canvas_sync import CanvasSyncManager


class _Push:
    def __init__(self) -> None:
        self.envelopes: list[dict] = []

    def __call__(self, envelope: dict) -> None:
        self.envelopes.append(envelope)


class _Recorder:
    def __init__(self, bus: EventBus) -> None:
        self.mirror: list[dict] = []
        self.artboard: list[dict] = []
        bus.on(MIRROR_CHANGED, lambda **kw: self.mirror.append(kw))
        bus.on(ARTBOARD_CHANGED, lambda **kw: self.artboard.append(kw))


@pytest.fixture()
def hub(tmp_path: Path) -> Any:
    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path, export_dir=tmp_path / "exports")
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    sync = CanvasSyncManager(bus, config, _Push(), store, index=None, pull_interval_s=0.0)
    rec = _Recorder(bus)
    try:
        yield bus, sync, store, rec
    finally:
        sync.shutdown()


def _canvas(canvas_id: str, style: str, updated_at: int = 1760760000) -> dict:
    return {
        "canvas_id": canvas_id,
        "title": canvas_id,
        "created_at": 1760760000,
        "updated_at": updated_at,
        "artboard": {
            "preset": "A4",
            "width": 2480.0,
            "height": 3508.0,
            "is_infinite": False,
            "background_style": style,
            "background_color": "#FFFFFF",
            "background_spacing": 32.0,
        },
        "content_bounds": {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        "elements": [],
    }


def _open(canvas: dict, device_id: str = "dev-1") -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": "CANVAS_LIFECYCLE",
        "action": "OPEN_CANVAS",
        "canvas_id": canvas["canvas_id"],
        "payload": {
            "canvas": canvas,
            "device_id": device_id,
            "device_name": device_id,
        },
        "timestamp": 1760760000,
    }


def _open_from(bus: EventBus, canvas: dict, connection_id: str, device_id: str = "dev-1") -> None:
    """Deliver an OPEN_CANVAS the way the WS server does: MESSAGE then ORIGIN."""
    bus.emit(RPC_MESSAGE, msg=_open(canvas, device_id))
    bus.emit(RPC_ORIGIN, msg=_open(canvas, device_id), connection_id=connection_id)


def test_owning_device_switch_moves_the_mirror_and_the_artboard(hub: Any) -> None:
    """Issue 02 — the reported defect, end to end."""
    bus, sync, store, rec = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="10.0.0.5:1111", connection_id="c1")

    _open_from(bus, _canvas("cv-ruled", "RULED"), "c1")
    assert sync.mirrored_canvas_id == "cv-ruled"
    assert store._current.artboard.background_style == "RULED"

    _open_from(bus, _canvas("cv-blank", "BLANK"), "c1")
    assert sync.mirrored_canvas_id == "cv-blank", "the mirror must follow its device"
    assert store._current.canvas_id == "cv-blank"
    assert store._current.artboard.background_style == "BLANK", (
        "the PC mirror must repaint with the newly opened canvas's background"
    )
    assert rec.mirror[-1]["canvas_id"] == "cv-blank"


def test_a_second_device_cannot_steal_the_mirror(hub: Any) -> None:
    """Round-7 issue 07 must survive: only the owning device moves the mirror."""
    bus, sync, store, _rec = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    bus.emit(CONNECTION_STATE, connected=True, peer="b:2", connection_id="c2")

    _open_from(bus, _canvas("cv-1", "RULED"), "c1")
    _open_from(bus, _canvas("cv-2", "BLANK"), "c2", device_id="dev-2")

    assert sync.mirrored_canvas_id == "cv-1"
    assert store._current.canvas_id == "cv-1", (
        "a foreign open is persisted, never loaded into the PC viewport"
    )
    rows = {row["connection_id"]: row for row in sync.device_rows()}
    assert rows["c1"]["open_canvas_id"] == "cv-1"
    assert rows["c2"]["open_canvas_id"] == "cv-2"
    assert rows["c1"]["mirrored"] is True and rows["c2"]["mirrored"] is False


def test_settings_choice_pins_the_mirror(hub: Any) -> None:
    """An explicit Settings switch must not be undone by the owning device."""
    bus, sync, store, _rec = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    bus.emit(CONNECTION_STATE, connected=True, peer="b:2", connection_id="c2")

    _open_from(bus, _canvas("cv-1", "RULED"), "c1")
    _open_from(bus, _canvas("cv-2", "BLANK"), "c2", device_id="dev-2")
    assert sync.select_mirror("cv-2", "cv-2") is True
    assert sync.mirrored_canvas_id == "cv-2"

    # Device 1 switches again — the operator's pinned choice wins.
    _open_from(bus, _canvas("cv-3", "SQUARE_GRID"), "c1")
    assert sync.mirrored_canvas_id == "cv-2", "a pinned Settings choice is never stolen"
    assert store._current.canvas_id != "cv-3", "the pinned viewport is not repainted"


def test_reconnected_device_keeps_its_claim(hub: Any) -> None:
    """A reconnect gets a new connection id; the tablet identity carries over."""
    bus, sync, store, _rec = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    _open_from(bus, _canvas("cv-1", "RULED"), "c1", device_id="dev-1")

    # Same tablet, new transport connection, identity announced by the payload.
    sync.roster.detach("c1")
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c9")
    _open_from(bus, _canvas("cv-2", "BLANK"), "c9", device_id="dev-1")

    assert sync.mirrored_canvas_id == "cv-2"
    assert store._current.artboard.background_style == "BLANK"
