"""Round 4/5 (Doc 02 §8/§9) — CanvasSyncManager PC-side flows.

Covers: CONNECTION_STATE(connected) → hub CANVAS_LIST broadcast +
CANVAS_LIST_REQUEST push, CANVAS_LIST → merge + ``CANVAS_LIST_UPDATED`` bus
event with the frozen ``{canvases, devices}`` payload, OPEN_CANVAS canvas
dialect → ``store.open_payload`` (path dialect ignored per §8.2),
``request_open`` → CANVAS_OPEN_REQUEST envelope, the ``canvases`` property,
and shutdown symmetry. Round-5 hub flows (merge/LWW, pull/put, index
persistence, New-flow) live in ``test_canvas_sync_hub.py``.
"""

from __future__ import annotations

import logging
import uuid
from pathlib import Path

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.core.protocol import RPC_ACTIONS
from pc_agent.network.canvas_sync import CanvasSyncManager

_ROWS = [
    {"id": "c-1", "title": "Control Systems 04", "preset": "A4",
     "background": "RULED", "updated_at": 1760763600},
    {"id": "c-2", "title": "Scribbles", "preset": "INFINITE",
     "background": "DOT_GRID", "updated_at": 1760760000},
]


class _PushSpy:
    def __init__(self) -> None:
        self.messages: list[dict] = []

    def __call__(self, msg: dict) -> None:
        self.messages.append(msg)


class _PushBomb:
    """push that always raises — the bus chain must survive it."""

    def __call__(self, msg: dict) -> None:
        raise RuntimeError("push exploded")


class _StoreSpy:
    def __init__(self) -> None:
        self.opened: list[dict] = []

    def open_payload(self, data: dict) -> dict:
        self.opened.append(data)
        return data


class _StoreBomb:
    def open_payload(self, data: dict) -> dict:
        raise ValueError("bad document")


def _envelope(envelope_type: str, action: str, payload: dict) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": envelope_type,
        "action": action,
        "canvas_id": "cv-1",
        "payload": payload,
        "timestamp": 1760760000,
    }


def _manager(
    tmp_path: Path, push=None, store=None
) -> tuple[EventBus, CanvasSyncManager, _PushSpy, _StoreSpy]:
    bus = EventBus()
    push_spy = push if push is not None else _PushSpy()
    store_spy = store if store is not None else _StoreSpy()
    # tmp appdata: the hub device id is persisted under <appdata>/device_id.
    config = AppConfig(appdata_dir=tmp_path / "appdata")
    manager = CanvasSyncManager(
        bus, config, push_spy, store_spy, pull_interval_s=0.0  # synchronous drain
    )
    return bus, manager, push_spy, store_spy


def _assert_shell(msg: dict, action: str) -> None:
    assert set(msg) == {"id", "type", "action", "canvas_id", "payload", "timestamp"}
    assert msg["type"] == "CANVAS_LIFECYCLE"
    assert msg["action"] == action
    assert action in RPC_ACTIONS
    assert msg["canvas_id"] == ""
    assert isinstance(msg["payload"], dict)
    assert isinstance(msg["timestamp"], int)


def test_connected_pushes_canvas_list_request_and_disconnect_does_not(
    tmp_path: Path,
) -> None:
    _bus, manager, push, _store = _manager(tmp_path)
    manager._on_connection_state(connected=False, peer=None)
    assert push.messages == []

    manager._on_connection_state(connected=True, peer="10.0.0.5:40000")
    # §9.2: hub list on each new connection, then §8.3 flow 2 requests the
    # device's own list.
    assert [m["action"] for m in push.messages] == ["CANVAS_LIST", "CANVAS_LIST_REQUEST"]
    hub_list = push.messages[0]
    _assert_shell(hub_list, "CANVAS_LIST")
    assert hub_list["payload"]["origin"] == "hub"
    assert hub_list["payload"]["canvases"] == []
    assert isinstance(hub_list["payload"]["device_id"], str)
    _assert_shell(push.messages[1], "CANVAS_LIST_REQUEST")
    assert push.messages[1]["payload"] == {}

    manager._on_connection_state(connected=False, peer=None)  # no new pushes
    assert [m["action"] for m in push.messages] == ["CANVAS_LIST", "CANVAS_LIST_REQUEST"]


def test_connection_state_via_bus_reaches_the_manager(tmp_path: Path) -> None:
    bus, _manager_obj, push, _store = _manager(tmp_path)
    bus.emit(CONNECTION_STATE, connected=True, peer=None)
    assert [m["action"] for m in push.messages] == ["CANVAS_LIST", "CANVAS_LIST_REQUEST"]


def test_canvas_list_caches_rows_and_emits_canvas_list_updated(tmp_path: Path) -> None:
    bus, manager, _push, _store = _manager(tmp_path)
    seen: list[dict] = []
    bus.on(CANVAS_LIST_UPDATED, lambda **payload: seen.append(payload))

    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": _ROWS}),
    )
    assert manager.canvases == _ROWS
    assert len(seen) == 1
    # Round-5 frozen payload: {canvases, devices} (core/events.py).
    assert seen[0]["canvases"] == _ROWS
    assert seen[0]["devices"] == 0
    # The event carries a copy — later cache swaps don't mutate delivered rows.
    seen[0]["canvases"].append({"id": "ghost"})
    assert len(manager.canvases) == 2


def test_canvas_list_may_be_empty_and_still_emits(tmp_path: Path) -> None:
    bus, manager, _push, _store = _manager(tmp_path)
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {}))
    assert manager.canvases == []

    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": []}))
    assert manager.canvases == []


def test_open_canvas_canvas_dialect_routes_to_store_open_payload(tmp_path: Path) -> None:
    bus, _manager_obj, _push, store = _manager(tmp_path)
    body = {"canvas_id": "c-1", "title": "T", "elements": []}
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": body}),
    )
    assert store.opened == [body]


def test_open_canvas_path_dialect_is_ignored_per_8_2(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    bus, _manager_obj, _push, store = _manager(tmp_path)
    with caplog.at_level(logging.DEBUG):
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS",
                          {"path": "C:/local/file.slatesync"}),
        )
        # Non-dict canvas value: logged as an error, never routed to the store.
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": "nope"}),
        )
    assert store.opened == []
    assert any("canvas dialect" in r.getMessage() for r in caplog.records)


def test_foreign_types_and_actions_never_touch_the_store(tmp_path: Path) -> None:
    bus, _manager_obj, _push, store = _manager(tmp_path)
    bus.emit(RPC_MESSAGE, msg=_envelope("ELEMENT_COMMIT", "OPEN_CANVAS", {"canvas": {}}))
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "ADD_STROKE", {"canvas": {}}))
    bus.emit(RPC_MESSAGE, msg={"not": "an envelope"})
    assert store.opened == []


def test_request_open_pushes_canvas_open_request_shell(tmp_path: Path) -> None:
    _bus, manager, push, _store = _manager(tmp_path)
    manager.request_open("c-1")
    assert len(push.messages) == 1
    _assert_shell(push.messages[0], "CANVAS_OPEN_REQUEST")
    assert push.messages[0]["payload"] == {"canvas_id": "c-1"}


def test_push_and_store_failures_are_logged_never_raised(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    bus, _manager_obj, _push_bomb, _store = _manager(tmp_path, push=_PushBomb())
    with caplog.at_level(logging.ERROR):
        bus.emit(CONNECTION_STATE, connected=True, peer=None)  # raised → swallowed
    assert any("CANVAS_LIST_REQUEST push failed" in r.getMessage()
               for r in caplog.records)

    caplog.clear()
    bus2, _m2, _p2, _s2 = _manager(tmp_path, store=_StoreBomb())
    with caplog.at_level(logging.ERROR):
        bus2.emit(
            RPC_MESSAGE,
            msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": {"x": 1}}),
        )  # store raised → swallowed; the chain continues after it
    assert any("OPEN_CANVAS (canvas dialect) failed" in r.getMessage()
               for r in caplog.records)


def test_shutdown_unsubscribes_symmetrically(tmp_path: Path) -> None:
    bus, manager, push, _store = _manager(tmp_path)
    manager.shutdown()
    manager.shutdown()  # idempotent
    bus.emit(CONNECTION_STATE, connected=True, peer=None)
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": _ROWS}),
    )
    assert push.messages == []
    assert manager.canvases == []
