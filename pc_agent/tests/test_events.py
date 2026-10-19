"""Tests for EventBus + the 12 event-name constants (Doc 04 §6)."""

import logging
import threading

from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CAMERA_DELTA,
    CANVAS_LIST_UPDATED,
    COMMITTED_NODE,
    CONNECTION_STATE,
    DOCUMENT_LOADED,
    EXPORT_FINISHED,
    EXPORT_PROGRESS,
    EXPORT_STARTED,
    LIVE_FRAME,
    PAIRING_INFO,
    RPC_MESSAGE,
    EventBus,
)


def test_emit_delivers_payload_kwargs_to_all_handlers_in_registration_order() -> None:
    bus = EventBus()
    seen: list[tuple[str, dict]] = []
    bus.on("E", lambda **payload: seen.append(("first", payload)))
    bus.on("E", lambda **payload: seen.append(("second", payload)))
    bus.emit("E", x=1, y=2)
    assert seen == [("first", {"x": 1, "y": 2}), ("second", {"x": 1, "y": 2})]


def test_emit_runs_synchronously_on_caller_thread() -> None:
    bus = EventBus()
    observed: list[threading.Thread] = []
    bus.on("E", lambda **_: observed.append(threading.current_thread()))
    bus.emit("E")
    assert observed == [threading.current_thread()]


def test_off_stops_delivery_and_missing_off_is_noop() -> None:
    bus = EventBus()
    calls: list[int] = []

    def handler(**_: object) -> None:
        calls.append(1)

    bus.on("E", handler)
    bus.emit("E")
    bus.off("E", handler)
    bus.emit("E")  # no delivery after off
    bus.off("E", handler)  # second off is a no-op
    bus.off("UNKNOWN_EVENT", handler)  # unknown event is a no-op
    assert calls == [1]


def test_duplicate_on_invokes_handler_once() -> None:
    bus = EventBus()
    calls: list[int] = []

    def handler(**_: object) -> None:
        calls.append(1)

    bus.on("E", handler)
    bus.on("E", handler)  # duplicate registration is dropped
    bus.emit("E")
    assert calls == [1]


def test_handler_exception_logged_and_later_handlers_still_run(caplog) -> None:
    bus = EventBus()
    order: list[str] = []

    def exploding(**_: object) -> None:
        order.append("boom")
        raise RuntimeError("boom")

    def survivor(**_: object) -> None:
        order.append("survivor")

    bus.on("E", exploding)
    bus.on("E", survivor)
    with caplog.at_level(logging.ERROR):
        bus.emit("E", v=1)  # must not raise
    assert order == ["boom", "survivor"]
    assert any(record.exc_info for record in caplog.records)
    assert "boom" in caplog.text


def test_event_name_constants_unique_and_match_template() -> None:
    names = [
        LIVE_FRAME,
        CAMERA_DELTA,
        RPC_MESSAGE,
        CONNECTION_STATE,
        DOCUMENT_LOADED,
        COMMITTED_NODE,
        ARTBOARD_CHANGED,
        EXPORT_STARTED,
        EXPORT_PROGRESS,
        EXPORT_FINISHED,
        PAIRING_INFO,
        CANVAS_LIST_UPDATED,
    ]
    assert len(names) == 12
    assert len(set(names)) == 12
    assert names == [
        "LIVE_FRAME",
        "CAMERA_DELTA",
        "RPC_MESSAGE",
        "CONNECTION_STATE",
        "DOCUMENT_LOADED",
        "COMMITTED_NODE",
        "ARTBOARD_CHANGED",
        "EXPORT_STARTED",
        "EXPORT_PROGRESS",
        "EXPORT_FINISHED",
        "PAIRING_INFO",
        "CANVAS_LIST_UPDATED",
    ]
