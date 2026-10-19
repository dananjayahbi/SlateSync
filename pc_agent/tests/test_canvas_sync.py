"""Round 4 (Doc 02 §8) — CanvasSyncManager PC-side flows.

Covers: CONNECTION_STATE(connected) → CANVAS_LIST_REQUEST push, CANVAS_LIST →
cache + CANVAS_LIST_UPDATED bus event, OPEN_CANVAS canvas dialect →
``store.open_payload`` (path dialect ignored per §8.2), ``request_open`` →
CANVAS_OPEN_REQUEST envelope, the ``canvases`` property, and shutdown symmetry.
"""

from __future__ import annotations

import logging
import uuid

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


def _manager(push=None, store=None) -> tuple[EventBus, CanvasSyncManager, _PushSpy, _StoreSpy]:
    bus = EventBus()
    push_spy = push if push is not None else _PushSpy()
    store_spy = store if store is not None else _StoreSpy()
    manager = CanvasSyncManager(bus, AppConfig(), push_spy, store_spy)
    return bus, manager, push_spy, store_spy


def _assert_shell(msg: dict, action: str) -> None:
    assert set(msg) == {"id", "type", "action", "canvas_id", "payload", "timestamp"}
    assert msg["type"] == "CANVAS_LIFECYCLE"
    assert msg["action"] == action
    assert action in RPC_ACTIONS
    assert msg["canvas_id"] == ""
    assert isinstance(msg["payload"], dict)
    assert isinstance(msg["timestamp"], int)


def test_connected_pushes_canvas_list_request_and_disconnect_does_not() -> None:
    _bus, manager, push, _store = _manager()
    manager._on_connection_state(connected=False, peer=None)
    assert push.messages == []

    manager._on_connection_state(connected=True, peer="10.0.0.5:40000")
    assert len(push.messages) == 1
    _assert_shell(push.messages[0], "CANVAS_LIST_REQUEST")
    assert push.messages[0]["payload"] == {}


def test_connection_state_via_bus_reaches_the_manager() -> None:
    bus, _manager_obj, push, _store = _manager()
    bus.emit(CONNECTION_STATE, connected=True, peer=None)
    assert [m["action"] for m in push.messages] == ["CANVAS_LIST_REQUEST"]


def test_canvas_list_caches_rows_and_emits_canvas_list_updated() -> None:
    bus, manager, _push, _store = _manager()
    seen: list[list[dict]] = []
    bus.on(CANVAS_LIST_UPDATED, lambda canvases: seen.append(canvases))

    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": _ROWS}),
    )
    assert manager.canvases == _ROWS
    assert len(seen) == 1
    assert seen[0] == _ROWS
    # The event carries a copy — later cache swaps don't mutate delivered rows.
    seen[0].append({"id": "ghost"})
    assert len(manager.canvases) == 2


def test_canvas_list_may_be_empty_and_still_emits() -> None:
    bus, manager, _push, _store = _manager()
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {}))
    assert manager.canvases == []

    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": []}))
    assert manager.canvases == []


def test_open_canvas_canvas_dialect_routes_to_store_open_payload() -> None:
    bus, _manager_obj, _push, store = _manager()
    body = {"canvas_id": "c-1", "title": "T", "elements": []}
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": body}),
    )
    assert store.opened == [body]


def test_open_canvas_path_dialect_is_ignored_per_8_2(
    caplog: pytest.LogCaptureFixture,
) -> None:
    bus, _manager_obj, _push, store = _manager()
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


def test_foreign_types_and_actions_never_touch_the_store() -> None:
    bus, _manager_obj, _push, store = _manager()
    bus.emit(RPC_MESSAGE, msg=_envelope("ELEMENT_COMMIT", "OPEN_CANVAS", {"canvas": {}}))
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "ADD_STROKE", {"canvas": {}}))
    bus.emit(RPC_MESSAGE, msg={"not": "an envelope"})
    assert store.opened == []


def test_request_open_pushes_canvas_open_request_shell() -> None:
    _bus, manager, push, _store = _manager()
    manager.request_open("c-1")
    assert len(push.messages) == 1
    _assert_shell(push.messages[0], "CANVAS_OPEN_REQUEST")
    assert push.messages[0]["payload"] == {"canvas_id": "c-1"}


def test_push_and_store_failures_are_logged_never_raised(
    caplog: pytest.LogCaptureFixture,
) -> None:
    bus, _manager_obj, _push_bomb, _store = _manager(push=_PushBomb())
    with caplog.at_level(logging.ERROR):
        bus.emit(CONNECTION_STATE, connected=True, peer=None)  # raised → swallowed
    assert any("CANVAS_LIST_REQUEST push failed" in r.getMessage()
               for r in caplog.records)

    caplog.clear()
    bus2, _m2, _p2, _s2 = _manager(store=_StoreBomb())
    with caplog.at_level(logging.ERROR):
        bus2.emit(
            RPC_MESSAGE,
            msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas": {"x": 1}}),
        )  # store raised → swallowed; the chain continues after it
    assert any("OPEN_CANVAS (canvas dialect) failed" in r.getMessage()
               for r in caplog.records)


def test_shutdown_unsubscribes_symmetrically() -> None:
    bus, manager, push, _store = _manager()
    manager.shutdown()
    manager.shutdown()  # idempotent
    bus.emit(CONNECTION_STATE, connected=True, peer=None)
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "CANVAS_LIST", {"canvases": _ROWS}),
    )
    assert push.messages == []
    assert manager.canvases == []
