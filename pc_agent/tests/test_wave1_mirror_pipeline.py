"""Wave 1 mirror pipeline — ``docs/micro/11_pc_websocket_stream_server.md`` §6.

The one test that may construct BOTH Doc 12 and Doc 11: pairing mints the
token, the server enforces it, and a Doc-25-style tablet client pushes a
16-byte LIVE_POINT, a CAMERA frame and a JSON envelope through the wire while
bus spies (plus a Doc-06-style latest-slot subscriber) observe the emitted
events. Hermetic: patched ``Zeroconf``, ephemeral loopback port, tmp appdata.
"""

from __future__ import annotations

import asyncio
import json
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest
import websockets
from websockets.exceptions import ConnectionClosed

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CAMERA_DELTA,
    CONNECTION_STATE,
    LIVE_FRAME,
    PAIRING_INFO,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LIVE_POINT,
    TOOL_PEN,
    LiveFrame,
    pack_live_frame,
)
from pc_agent.network.discovery_pairing import DiscoveryPairing
from pc_agent.network.ws_stream_server import WsStreamServer

_WAIT_S = 5.0
_RECORDED_EVENTS = (
    PAIRING_INFO,
    CONNECTION_STATE,
    LIVE_FRAME,
    CAMERA_DELTA,
    RPC_MESSAGE,
)


def _wait_until(predicate: Callable[[], bool], timeout: float = _WAIT_S) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class EventRecorder:
    """Thread-safe spy over the shared bus (server emits on its own thread)."""

    def __init__(self, bus: EventBus) -> None:
        self._lock = threading.Lock()
        self._events: list[tuple[str, dict[str, Any]]] = []
        for name in _RECORDED_EVENTS:
            bus.on(name, self._make_recorder(name))

    def _make_recorder(self, name: str) -> Callable[..., None]:
        def record(**payload: Any) -> None:
            with self._lock:
                self._events.append((name, payload))

        return record

    def of(self, name: str) -> list[dict[str, Any]]:
        with self._lock:
            return [payload for event, payload in self._events if event == name]

    def ordered(self) -> list[tuple[str, dict[str, Any]]]:
        with self._lock:
            return list(self._events)

    def wait_for(self, name: str, count: int = 1, timeout: float = _WAIT_S) -> bool:
        return _wait_until(lambda: len(self.of(name)) >= count, timeout)


@pytest.fixture()
def pipeline(tmp_path: Path) -> Any:
    with patch("pc_agent.network.discovery_pairing.Zeroconf"):
        config = AppConfig(ws_port=0, appdata_dir=tmp_path / "SlateSync")
        bus = EventBus()
        spy = EventRecorder(bus)
        pairing = DiscoveryPairing(bus, config)
        pairing.start()  # mints token, registers mDNS, writes QR, emits PAIRING_INFO
        server = WsStreamServer(bus, config, lambda: pairing.session_token, host="127.0.0.1")
        server.start()
        try:
            yield bus, server, pairing, spy, config
        finally:
            server.stop()  # frees the bound port
            pairing.stop()


def test_mirror_pipeline_frames_and_envelopes_to_bus(pipeline: Any) -> None:
    bus, server, pairing, spy, config = pipeline

    # Doc-06-style latest-slot subscribers; no latency gate here (Doc 28 owns it).
    slots: dict[str, Any] = {"live": None, "camera": None}
    bus.on(LIVE_FRAME, lambda **payload: slots.__setitem__("live", payload["frame"]))
    bus.on(CAMERA_DELTA, lambda **payload: slots.__setitem__("camera", payload["frame"]))

    live = LiveFrame(FRAME_LIVE_POINT, TOOL_PEN, 1, 0.25, 0.75, 3.5)  # float32-exact fields
    camera = LiveFrame(FRAME_CAMERA, TOOL_PEN, 2, 1.5, 10.0, -20.0)
    envelope = {
        "id": "3f6a0000-0000-4000-8000-000000000002",
        "type": "CANVAS_LIFECYCLE",
        "action": "OPEN_CANVAS",
        "canvas_id": "canvas-1",
        "payload": {"preset": "A4", "title": "Notes"},
    }

    async def scenario() -> None:
        base_url = f"ws://127.0.0.1:{server.port}/ws"
        # Cross-doc token gate: anything != DiscoveryPairing.session_token -> 4001.
        with pytest.raises(ConnectionClosed) as rejected:
            async with websockets.connect(f"{base_url}?token=not-the-token") as wrong:
                await asyncio.wait_for(wrong.recv(), _WAIT_S)
        assert rejected.value.rcvd is not None
        assert rejected.value.rcvd.code == 4001

        async with websockets.connect(f"{base_url}?token={pairing.session_token}") as ws:
            await ws.send(pack_live_frame(live))
            await ws.send(pack_live_frame(camera))
            await ws.send(json.dumps(envelope))

    asyncio.run(scenario())

    # PAIRING_INFO carries the token the server enforced and a real QR file.
    assert spy.wait_for(PAIRING_INFO)
    pairing_info = spy.of(PAIRING_INFO)
    assert len(pairing_info) == 1
    assert pairing_info[0]["token"] == pairing.session_token
    assert pairing_info[0]["port"] == config.ws_port == 0  # replaced config stays honest
    qr_path = Path(pairing_info[0]["qr_png_path"])
    assert qr_path.is_file() and qr_path.read_bytes()[:4] == b"\x89PNG"

    # Dual-path dispatch: binary frames routed by type, envelope forwarded whole.
    assert spy.wait_for(LIVE_FRAME)
    assert spy.wait_for(CAMERA_DELTA)
    assert spy.wait_for(RPC_MESSAGE)
    assert spy.wait_for(CONNECTION_STATE, count=2)
    time.sleep(0.1)  # settle before exactness assertions

    assert [event["frame"] for event in spy.of(LIVE_FRAME)] == [live]
    assert [event["frame"] for event in spy.of(CAMERA_DELTA)] == [camera]
    assert slots["live"] == live and slots["camera"] == camera
    assert spy.of(RPC_MESSAGE) == [{"msg": envelope}]

    binary = [
        payload
        for name, payload in spy.ordered()
        if name in (LIVE_FRAME, CAMERA_DELTA)
    ]
    assert [payload["frame"].seq for payload in binary] == [1, 2]  # order by seq

    states = [payload for name, payload in spy.ordered() if name == CONNECTION_STATE]
    assert [state["connected"] for state in states] == [True, False]
    assert states[0]["peer"] is not None and states[0]["peer"].startswith("127.0.0.1:")
    assert states[1]["peer"] is None
