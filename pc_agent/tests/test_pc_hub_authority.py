"""Round 7 — PC hub authority, device roster and mirror switching.

Binds the new behaviour to ``docs/micro/02_vector_stream_protocol_spec.md``
§8/§9/§10 semantics:

* issue 03 — the PC applies a device mutation first, then relays;
* issue 07 — only the FIRST opened canvas is mirrored, Settings can switch it,
  and mutations from a non-mirrored canvas never leak to the other devices.
"""

from __future__ import annotations

import uuid
from pathlib import Path
from typing import Any

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CONNECTION_STATE,
    DEVICES_UPDATED,
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

    def __call__(self, msg: dict) -> None:
        self.envelopes.append(msg)

    def actions(self, action: str) -> list[dict]:
        return [env for env in self.envelopes if env.get("action") == action]


class _Recorder:
    def __init__(self, bus: EventBus) -> None:
        self.devices: list[dict] = []
        self.mirror: list[dict] = []
        bus.on(DEVICES_UPDATED, lambda **kw: self.devices.append(kw))
        bus.on(MIRROR_CHANGED, lambda **kw: self.mirror.append(kw))


@pytest.fixture()
def hub(tmp_path: Path) -> Any:
    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path, export_dir=tmp_path / "exports")
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    push = _Push()
    sync = CanvasSyncManager(bus, config, push, store, index=None, pull_interval_s=0.0)
    rec = _Recorder(bus)
    try:
        yield bus, sync, push, rec, store
    finally:
        sync.shutdown()


def _envelope(envelope_type: str, action: str, payload: dict, canvas_id="cv-1") -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": envelope_type,
        "action": action,
        "canvas_id": canvas_id,
        "payload": payload,
        "timestamp": 1760760000,
    }


def _canvas(canvas_id: str = "cv-1", title: str = "Alpha", preset: str = "A4") -> dict:
    return {
        "canvas_id": canvas_id,
        "title": title,
        "created_at": 1760760000,
        "updated_at": 1760760000,
        "artboard": {
            "preset": preset,
            "width": 2480.0 if preset == "A4" else None,
            "height": 3508.0 if preset == "A4" else None,
            "is_infinite": preset == "INFINITE",
            "background_style": "BLANK",
            "background_color": "#FFFFFF",
        },
        "content_bounds": {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
        "elements": [],
    }


# ---------------------------------------------------------------------------
# Device roster wiring
# ---------------------------------------------------------------------------


def test_connection_state_populates_the_roster(hub: Any) -> None:
    bus, sync, _push, rec, _store = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="10.0.0.5:1111", connection_id="c1")
    assert sync.roster.count == 1
    assert rec.devices, "DEVICES_UPDATED must be emitted on connect"
    assert rec.devices[-1]["count"] == 1
    assert rec.devices[-1]["devices"][0]["peer"] == "10.0.0.5:1111"

    bus.emit(CONNECTION_STATE, connected=False, peer=None, connection_id="c1")
    assert sync.roster.count == 0
    assert rec.devices[-1]["count"] == 0


def test_connection_state_without_id_still_counts(hub: Any) -> None:
    """Legacy emits (no connection_id) must not crash the roster."""
    bus, sync, _push, rec, _store = hub
    bus.emit(CONNECTION_STATE, connected=True, peer=None)
    assert sync.devices == 1
    assert rec.devices[-1]["count"] == 1  # synthetic session keeps Settings honest
    bus.emit(CONNECTION_STATE, connected=False, peer=None)
    assert sync.devices == 0
    assert rec.devices[-1]["count"] == 0


def test_rpc_origin_binds_device_identity(hub: Any) -> None:
    bus, sync, _push, rec, _store = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    bus.emit(
        RPC_ORIGIN,
        msg=_envelope(
            "CANVAS_LIFECYCLE",
            "CANVAS_LIST",
            {"device_id": "dev-1", "device_name": "Pixel", "canvases": []},
        ),
        connection_id="c1",
    )
    row = sync.device_rows()[0]
    assert row["device_id"] == "dev-1"
    assert row["name"] == "Pixel"
    assert rec.devices[-1]["devices"][0]["name"] == "Pixel"


# ---------------------------------------------------------------------------
# Issue 07 — mirror selection
# ---------------------------------------------------------------------------


def test_first_open_becomes_the_mirror(hub: Any) -> None:
    bus, sync, _push, rec, _store = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    bus.emit(
        RPC_ORIGIN,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": _canvas()}),
        connection_id="c1",
    )
    bus.emit(
        RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": _canvas()})
    )
    assert sync.mirrored_canvas_id == "cv-1"
    assert rec.mirror and rec.mirror[-1]["canvas_id"] == "cv-1"
    assert rec.mirror[-1]["connection_id"] == "c1"


def test_second_device_opening_another_canvas_does_not_steal_the_mirror(
    hub: Any,
) -> None:
    bus, sync, _push, rec, _store = hub
    bus.emit(CONNECTION_STATE, connected=True, peer="a:1", connection_id="c1")
    bus.emit(CONNECTION_STATE, connected=True, peer="b:2", connection_id="c2")

    first = _canvas("cv-1", "Alpha")
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": first}))
    bus.emit(
        RPC_ORIGIN,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": first}),
        connection_id="c1",
    )
    assert sync.mirrored_canvas_id == "cv-1"

    second = _canvas("cv-2", "Beta")
    bus.emit(
        RPC_ORIGIN,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": second}),
        connection_id="c2",
    )
    bus.emit(
        RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": second})
    )
    assert sync.mirrored_canvas_id == "cv-1", "issue 07: first opened wins"
    rows = {row["connection_id"]: row for row in sync.device_rows()}
    assert rows["c1"]["open_canvas_id"] == "cv-1"
    assert rows["c2"]["open_canvas_id"] == "cv-2"
    assert rows["c1"]["mirrored"] is True and rows["c2"]["mirrored"] is False


def test_select_mirror_switches_and_announces(hub: Any) -> None:
    bus, sync, _push, rec, store = hub
    sync.roster.attach("c1", "a:1")
    sync.roster.attach("c2", "b:2")
    sync.roster.note_open("c1", "cv-1", "Alpha")
    sync.roster.note_open("c2", "cv-2", "Beta")

    assert sync.select_mirror("cv-2", "Beta") is True
    assert sync.mirrored_canvas_id == "cv-2"
    assert rec.mirror[-1]["canvas_id"] == "cv-2"
    assert sync.select_mirror("cv-2", "Beta") is False  # unchanged → no churn


def test_relay_gate_only_lets_the_mirrored_canvas_through(hub: Any) -> None:
    """Issue 03/07: the PC orchestrates; unmirrored canvases never fan out."""
    _bus, sync, _push, _rec, _store = hub
    assert sync.allows_relay({"canvas_id": "cv-1"}) is True  # no mirror yet

    sync.roster.attach("c1")
    sync.roster.note_open("c1", "cv-1", "Alpha")
    assert sync.allows_relay({"canvas_id": "cv-1"}) is True
    assert sync.allows_relay({"canvas_id": "cv-2"}) is False
    assert sync.allows_relay({}) is True  # no canvas_id → not gated
    assert sync.allows_relay({"canvas_id": ""}) is True


def test_shutdown_unsubscribes_the_origin_handler() -> None:
    bus = EventBus()
    config = AppConfig()
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    sync = CanvasSyncManager(bus, config, lambda msg: None, store, index=None)
    sync.shutdown()
    # Handlers are gone: a further RPC_ORIGIN must not touch the roster.
    bus.emit(RPC_ORIGIN, msg={"type": "CANVAS_LIFECYCLE"}, connection_id="c1")
    assert sync.roster.count == 0
