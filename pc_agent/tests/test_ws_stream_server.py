"""Doc 11 tests — ``docs/micro/11_pc_websocket_stream_server.md`` §6.

Hermetic by construction: loopback host, ephemeral port (``ws_port=0``),
token stub, real ``EventBus`` wired to thread-safe recorders; the fixture
teardown stops every server so no bound port or thread leaks across the suite.
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
from collections.abc import Callable
from typing import Any

import pytest
import websockets
from websockets.exceptions import ConnectionClosed

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CAMERA_DELTA,
    CONNECTION_STATE,
    LIVE_FRAME,
    RPC_MESSAGE,
    RPC_ORIGIN,
    EventBus,
)
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LIVE_POINT,
    TOOL_PEN,
    LiveFrame,
    pack_live_frame,
)
from pc_agent.network.ws_stream_server import WsStreamServer

TOKEN = "hermetic-session-token"
_WAIT_S = 5.0


def _wait_until(predicate: Callable[[], bool], timeout: float = _WAIT_S) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


async def _async_wait_until(predicate: Callable[[], bool], timeout: float = _WAIT_S) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.01)
    return predicate()


class EventRecorder:
    """Thread-safe spy: the server emits on its asyncio thread, tests read here."""

    def __init__(self, bus: EventBus, events: tuple[str, ...]) -> None:
        self._lock = threading.Lock()
        self._events: list[tuple[str, dict[str, Any]]] = []
        for name in events:
            bus.on(name, self._make_recorder(name))

    def _make_recorder(self, name: str) -> Callable[..., None]:
        def record(**payload: Any) -> None:
            with self._lock:
                self._events.append((name, payload))

        return record

    def of(self, name: str) -> list[dict[str, Any]]:
        with self._lock:
            return [payload for event, payload in self._events if event == name]

    def snapshot(self) -> list[tuple[str, dict[str, Any]]]:
        with self._lock:
            return list(self._events)

    def wait_for(self, name: str, count: int = 1, timeout: float = _WAIT_S) -> bool:
        return _wait_until(lambda: len(self.of(name)) >= count, timeout)


def _ws_url(server: WsStreamServer, token: str | None = TOKEN, path: str = "/ws") -> str:
    url = f"ws://127.0.0.1:{server.port}{path}"
    if token is not None:
        url += f"?token={token}"
    return url


async def _await_close_code(url: str) -> int | None:
    """Connect, then return the close code the server chose (None if none).

    Transient retry: under full-suite CPU contention the close handshake can be
    lost to a transport reset (returns None) — retry on a fresh connection so
    the contract (exact close code) is still asserted, never relaxed.
    """
    code: int | None = None
    for _attempt in range(3):
        code = None
        try:
            async with websockets.connect(url) as websocket:
                await asyncio.wait_for(websocket.recv(), _WAIT_S)
        except ConnectionClosed as exc:
            if exc.rcvd is not None:
                code = exc.rcvd.code
            elif exc.sent is not None:
                code = exc.sent.code
        except asyncio.TimeoutError:
            code = None
        if code is not None:
            return code
        await asyncio.sleep(0.2)
    return code


def _envelope(**overrides: Any) -> dict[str, Any]:
    msg: dict[str, Any] = {
        "id": "3f6a0000-0000-4000-8000-000000000001",
        "type": "CANVAS_LIFECYCLE",
        "action": "OPEN_CANVAS",
        "canvas_id": "canvas-1",
        "payload": {"preset": "A4"},
    }
    msg.update(overrides)
    return msg


def _frame(seq: int, frame_type: int = FRAME_LIVE_POINT) -> LiveFrame:
    # 0.25/0.75/3.5 are float32-exact, so packed/unpacked fields compare equal.
    return LiveFrame(frame_type, TOOL_PEN, seq, 0.25, 0.75, 3.5)


@pytest.fixture()
def server_env() -> Any:
    bus = EventBus()
    recorder = EventRecorder(bus, (LIVE_FRAME, CAMERA_DELTA, RPC_MESSAGE, CONNECTION_STATE))
    server = WsStreamServer(bus, AppConfig(ws_port=0), lambda: TOKEN, host="127.0.0.1")
    server.start()
    try:
        yield bus, server, recorder
    finally:
        server.stop()


# -- lifecycle ---------------------------------------------------------------


def test_start_stop_lifecycle_and_bound_port(server_env: Any) -> None:
    _, server, _ = server_env
    assert 0 < server.port < 65536
    bound_port = server.port
    thread = server._thread
    assert thread is not None and thread.is_alive()

    server.start()  # second start: logged no-op, same bound port
    assert server.port == bound_port
    assert server._thread is thread

    started = time.monotonic()
    server.stop()
    assert time.monotonic() - started < 5.0  # thread joined well within 5 s
    server.stop()  # idempotent
    assert not thread.is_alive()
    assert server.port == 0  # back to config.ws_port


def test_startup_failure_raises_and_is_stoppable() -> None:
    bus = EventBus()
    server = WsStreamServer(bus, AppConfig(ws_port=0), lambda: TOKEN, host="192.0.2.1")
    with pytest.raises(RuntimeError, match="failed to start"):
        server.start()
    server.stop()  # safe no-op after a failed start
    assert server.port == 0


# -- auth and path gates -----------------------------------------------------


def test_valid_token_connects_and_state_is_exactly_once(server_env: Any) -> None:
    _, server, rec = server_env

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)):
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 1)

    asyncio.run(scenario())
    assert rec.wait_for(CONNECTION_STATE, count=2)
    states = rec.of(CONNECTION_STATE)
    assert [state["connected"] for state in states] == [True, False]
    assert states[0]["peer"] is not None and states[0]["peer"].startswith("127.0.0.1:")
    assert states[1]["peer"] is None


@pytest.mark.parametrize("rejection", ["missing_token", "wrong_token", "wrong_path"])
def test_rejected_connection_closes_without_events(server_env: Any, rejection: str) -> None:
    _, server, rec = server_env
    if rejection == "missing_token":
        code = asyncio.run(_await_close_code(_ws_url(server, token=None)))
        assert code == 4001
    elif rejection == "wrong_token":
        code = asyncio.run(_await_close_code(_ws_url(server, token="not-the-token")))
        assert code == 4001
    else:
        code = asyncio.run(_await_close_code(_ws_url(server, path="/other")))
        assert code is not None  # closed before any event; exact code is internal
    assert rec.snapshot() == []


# -- dual-path dispatch ------------------------------------------------------


def test_binary_live_point_emits_live_frame(server_env: Any) -> None:
    _, server, rec = server_env
    frame = LiveFrame(FRAME_LIVE_POINT, TOOL_PEN, 7, 0.25, 0.75, 2.5)

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            await websocket.send(pack_live_frame(frame))

    asyncio.run(scenario())
    assert rec.wait_for(LIVE_FRAME)
    assert rec.of(LIVE_FRAME)[0]["frame"] == frame
    assert rec.of(CAMERA_DELTA) == []


def test_binary_camera_emits_camera_delta(server_env: Any) -> None:
    _, server, rec = server_env
    frame = LiveFrame(FRAME_CAMERA, TOOL_PEN, 9, 1.5, 10.0, -20.0)

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            await websocket.send(pack_live_frame(frame))

    asyncio.run(scenario())
    assert rec.wait_for(CAMERA_DELTA)
    assert rec.of(CAMERA_DELTA)[0]["frame"] == frame
    assert rec.of(LIVE_FRAME) == []


def test_wrong_length_binary_dropped_connection_survives(server_env: Any) -> None:
    _, server, rec = server_env
    good = _frame(3)

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            await websocket.send(b"\x01" * 15)
            await websocket.send(b"\x01" * 17)
            await websocket.send(pack_live_frame(good))

    asyncio.run(scenario())
    assert rec.wait_for(LIVE_FRAME)
    time.sleep(0.1)  # settle before exactness check
    assert [event["frame"] for event in rec.of(LIVE_FRAME)] == [good]


def test_invalid_json_dropped_but_connection_survives(server_env: Any) -> None:
    _, server, rec = server_env
    valid = _envelope()

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            await websocket.send("{this is not json")
            await websocket.send(json.dumps(valid))

    asyncio.run(scenario())
    assert rec.wait_for(RPC_MESSAGE)
    time.sleep(0.1)
    assert rec.of(RPC_MESSAGE) == [{"msg": valid}]


def test_envelope_shell_validation_matrix(server_env: Any) -> None:
    _, server, rec = server_env
    base = _envelope()
    bad: list[Any] = []
    for key in ("id", "type", "action", "canvas_id"):
        case = dict(base)
        del case[key]
        bad.append(case)
    bad.append(_envelope(type="NOT_A_TYPE"))
    bad.append(_envelope(action="NOT_AN_ACTION"))
    bad.append(_envelope(action=""))
    bad.append(_envelope(id=123))
    bad.append(_envelope(canvas_id=7))
    bad.append([base])  # valid JSON, not an envelope object
    good = _envelope(type="EXPORT_JOB", action="EXPORT_FINISHED", payload={"job_id": "j1"})
    # Doc 02 §8/§9: the canvas-sync actions pass the shell matrix too (19 total).
    canvas_good = [
        _envelope(type="CANVAS_LIFECYCLE", action="CANVAS_LIST_REQUEST", payload={}),
        _envelope(
            type="CANVAS_LIFECYCLE",
            action="CANVAS_LIST",
            payload={"canvases": []},
        ),
        _envelope(
            type="CANVAS_LIFECYCLE",
            action="CANVAS_OPEN_REQUEST",
            payload={"canvas_id": "c-1"},
        ),
        _envelope(
            type="CANVAS_LIFECYCLE",
            action="CANVAS_PUT",
            payload={"canvas": {}, "source": "hub"},
        ),
        _envelope(
            type="CANVAS_LIFECYCLE",
            action="CANVAS_PULL",
            payload={"canvas_id": "c-1", "have_updated_at": 0},
        ),
    ]

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            for case in bad:
                await websocket.send(json.dumps(case))
            await websocket.send(json.dumps(good))
            for case in canvas_good:
                await websocket.send(json.dumps(case))

    asyncio.run(scenario())
    assert rec.wait_for(RPC_MESSAGE, count=1 + len(canvas_good))
    time.sleep(0.1)
    assert rec.of(RPC_MESSAGE) == [{"msg": good}] + [{"msg": m} for m in canvas_good]


def test_envelope_fidelity_passthrough(server_env: Any) -> None:
    _, server, rec = server_env
    envelopes = [
        _envelope(payload={"preset": "A4", "title": "Notes"}),
        _envelope(
            type="ARTBOARD_RESIZE",
            action="UPGRADE_SIZE",
            payload={"min_x": 0.0, "min_y": 0.0, "max_x": 748.0, "max_y": 1052.0},
        ),
        _envelope(
            type="ASSET_UPLOAD",
            action="ASSET_CHUNK",
            payload={
                "transfer_id": "t1",
                "filename": "a.png",
                "total_chunks": 2,
                "size_bytes": 300000,
                "index": 0,
                "data_b64": "AAAA",
            },
        ),
    ]

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            for msg in envelopes:
                await websocket.send(json.dumps(msg))

    asyncio.run(scenario())
    assert rec.wait_for(RPC_MESSAGE, count=len(envelopes))
    time.sleep(0.1)
    assert rec.of(RPC_MESSAGE) == [{"msg": msg} for msg in envelopes]


# -- seq gate ----------------------------------------------------------------


def test_seq_accept_table(server_env: Any) -> None:
    _, server, _ = server_env
    assert server._seq_accept(None, 0)
    assert server._seq_accept(None, 65535)
    assert server._seq_accept(100, 101)
    assert not server._seq_accept(100, 100)  # duplicate
    assert not server._seq_accept(100, 99)  # reordered/stale
    assert server._seq_accept(65535, 1)  # u16 wrap
    assert server._seq_accept(100, 32767)  # just inside the half-window
    assert not server._seq_accept(100, 32868)  # half-window boundary dropped


def test_seq_gate_reorder_and_duplicate_dropped(server_env: Any) -> None:
    _, server, rec = server_env

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            for seq in (10, 10, 9, 12):
                await websocket.send(pack_live_frame(_frame(seq)))

    asyncio.run(scenario())
    assert rec.wait_for(LIVE_FRAME, count=2)
    time.sleep(0.1)
    assert [event["frame"].seq for event in rec.of(LIVE_FRAME)] == [10, 12]


def test_seq_gate_per_connection_isolation(server_env: Any) -> None:
    _, server, rec = server_env

    async def scenario() -> None:
        async with (
            websockets.connect(_ws_url(server)) as client_a,
            websockets.connect(_ws_url(server)) as client_b,
        ):
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 2)
            for seq_a, seq_b in ((10, 1), (10, 1), (12, 3)):
                await client_a.send(pack_live_frame(_frame(seq_a)))
                await client_b.send(pack_live_frame(_frame(seq_b)))

    asyncio.run(scenario())
    assert rec.wait_for(LIVE_FRAME, count=4)
    time.sleep(0.1)
    seqs = [event["frame"].seq for event in rec.of(LIVE_FRAME)]
    assert sorted(seqs) == [1, 3, 10, 12]  # each connection kept its own gate


def test_seq_gate_wrap_and_reconnect_resets_gate(server_env: Any) -> None:
    _, server, rec = server_env

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as first:
            for seq in (65535, 65534, 1):  # wrap 65535 -> 1 accepted, stale dropped
                await first.send(pack_live_frame(_frame(seq)))
        async with websockets.connect(_ws_url(server)) as second:
            await second.send(pack_live_frame(_frame(1)))  # fresh last_seq = None

    asyncio.run(scenario())
    assert rec.wait_for(LIVE_FRAME, count=3)
    time.sleep(0.1)
    seqs = [event["frame"].seq for event in rec.of(LIVE_FRAME)]
    assert seqs == [65535, 1, 1]


# -- broadcast ---------------------------------------------------------------


def test_broadcast_json_reaches_clients_from_foreign_thread(server_env: Any) -> None:
    _, server, rec = server_env
    msg = _envelope(
        type="EXPORT_JOB", action="EXPORT_PROGRESS", payload={"job_id": "j1", "percent": 40.0}
    )

    async def scenario() -> None:
        async with (
            websockets.connect(_ws_url(server)) as gui,
            websockets.connect(_ws_url(server)) as tablet,
        ):
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 2)
            task_gui = asyncio.create_task(gui.recv())
            task_tablet = asyncio.create_task(tablet.recv())
            worker = threading.Thread(target=lambda: server.broadcast_json(msg))
            worker.start()
            worker.join()
            raw_gui, raw_tablet = await asyncio.wait_for(
                asyncio.gather(task_gui, task_tablet), _WAIT_S
            )
            assert json.loads(raw_gui) == msg
            assert json.loads(raw_tablet) == msg

    asyncio.run(scenario())


def test_broadcast_json_survives_one_dead_client(server_env: Any) -> None:
    _, server, rec = server_env
    msg = _envelope(type="EXPORT_JOB", action="EXPORT_FINISHED", payload={"job_id": "j1"})

    async def scenario() -> None:
        async with (
            websockets.connect(_ws_url(server)) as vanishing,
            websockets.connect(_ws_url(server)) as survivor,
        ):
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 2)
            vanishing.transport.abort()  # vanish without a close frame
            await asyncio.wait_for(vanishing.wait_closed(), _WAIT_S)
            pending = asyncio.create_task(survivor.recv())
            worker = threading.Thread(target=lambda: server.broadcast_json(msg))
            worker.start()
            worker.join()
            raw = await asyncio.wait_for(pending, _WAIT_S)
            assert json.loads(raw) == msg

    asyncio.run(scenario())


def test_broadcast_json_before_start_drops_without_raising(caplog: Any) -> None:
    bus = EventBus()
    server = WsStreamServer(bus, AppConfig(ws_port=0), lambda: TOKEN, host="127.0.0.1")
    with caplog.at_level(logging.WARNING, logger="slatesync.ws"):
        server.broadcast_json(_envelope())  # must never raise into a GUI thread
    assert "message dropped" in caplog.text


def test_broadcast_json_after_stop_and_non_serializable(server_env: Any) -> None:
    _, server, _ = server_env
    server.broadcast_json({"bad": object()})  # TypeError swallowed + logged
    server.stop()
    server.broadcast_json(_envelope())  # stopped server: dropped, never raises


# -- connection state on abrupt drop ----------------------------------------


def test_abrupt_drop_emits_single_disconnect(server_env: Any) -> None:
    _, server, rec = server_env

    async def scenario() -> None:
        async with websockets.connect(_ws_url(server)) as websocket:
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 1)
            websocket.transport.abort()  # vanish without a close frame
            await asyncio.wait_for(websocket.wait_closed(), _WAIT_S)

    asyncio.run(scenario())
    assert rec.wait_for(CONNECTION_STATE, count=2)
    time.sleep(0.1)
    states = rec.of(CONNECTION_STATE)
    assert [state["connected"] for state in states] == [True, False]
    assert states[1]["peer"] is None


# -- token liveness ----------------------------------------------------------


def test_token_provider_read_per_connection() -> None:
    bus = EventBus()
    rec = EventRecorder(bus, (LIVE_FRAME, CONNECTION_STATE))
    state = {"token": "token-alpha"}
    server = WsStreamServer(bus, AppConfig(ws_port=0), lambda: state["token"], host="127.0.0.1")
    server.start()
    try:

        async def scenario() -> None:
            async with websockets.connect(_ws_url(server, token="token-alpha")) as first:
                assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 1)
                state["token"] = "token-beta"  # swap affects only NEW connections
                stale = await _await_close_code(_ws_url(server, token="token-alpha"))
                assert stale == 4001
                async with websockets.connect(_ws_url(server, token="token-beta")) as second:
                    await second.send(pack_live_frame(_frame(1)))
                    assert rec.wait_for(LIVE_FRAME)
                await first.send(pack_live_frame(_frame(5)))  # established stays open
                assert rec.wait_for(LIVE_FRAME, count=2)

        asyncio.run(scenario())
    finally:
        server.stop()
    assert [event["frame"].seq for event in rec.of(LIVE_FRAME)] == [1, 5]


# -- round 6 live mutation relay (Doc 02 §10.2) ------------------------------


class _FakeConn:
    """Stand-in ``ServerConnection``: records every payload pushed to it.

    ``__eq__`` deliberately reports every fake as equal to every other — the
    relay's ``exclude`` must therefore key on IDENTITY (``is``), never ``==``.
    """

    def __init__(self, name: str, *, broken: bool = False) -> None:
        self.name = name
        self.broken = broken
        self.sent: list[str] = []

    async def send(self, payload: str) -> None:
        if self.broken:
            raise RuntimeError(f"fake connection {self.name!r} is dead")
        self.sent.append(payload)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, _FakeConn)

    __hash__ = object.__hash__  # keep identity hashing for set membership


def test_relay_reaches_other_clients_but_never_the_sender(server_env: Any) -> None:
    _, server, rec = server_env
    sender, peer_a, peer_b = _FakeConn("sender"), _FakeConn("a"), _FakeConn("b")
    server._clients.update({sender, peer_a, peer_b})
    msg = _envelope(type="ELEMENT_COMMIT", action="ADD_STROKE", payload={"node_id": "n1"})

    server._dispatch_text(json.dumps(msg), sender=sender)

    assert rec.wait_for(RPC_MESSAGE)  # local dispatch happens first, always
    assert _wait_until(lambda: len(peer_a.sent) == 1 and len(peer_b.sent) == 1)
    time.sleep(0.1)  # settle: an (incorrect) echo would have landed by now
    assert rec.of(RPC_MESSAGE) == [{"msg": msg}]
    assert sender.sent == []  # the sending device never receives its own echo
    assert [json.loads(raw) for raw in peer_a.sent] == [msg]  # exact payload
    assert [json.loads(raw) for raw in peer_b.sent] == [msg]


def test_relay_covers_clear_and_resize_but_never_other_types(server_env: Any) -> None:
    _, server, rec = server_env
    sender, peer = _FakeConn("sender"), _FakeConn("peer")
    server._clients.update({sender, peer})
    relayed = [
        _envelope(type="ELEMENT_COMMIT", action="CLEAR_CANVAS", payload={}),
        _envelope(type="ARTBOARD_RESIZE", action="UPGRADE_SIZE", payload={"preset": "A4"}),
    ]
    not_relayed = [
        _envelope(
            type="CANVAS_LIFECYCLE",
            action="CANVAS_PUT",
            payload={"canvas": {"canvas_id": "c-1"}, "source": "device"},
        ),
        _envelope(
            type="ASSET_UPLOAD",
            action="ASSET_START",
            payload={"transfer_id": "t", "filename": "f", "total_chunks": 1, "size_bytes": 1},
        ),
        _envelope(
            type="EXPORT_JOB",
            action="START_EXPORT",
            payload={"job_id": "j", "format": "PNG", "dpi": 300, "target": "PC"},
        ),
    ]

    for msg in relayed + not_relayed:
        server._dispatch_text(json.dumps(msg), sender=sender)

    assert rec.wait_for(RPC_MESSAGE, count=len(relayed) + len(not_relayed))
    assert _wait_until(lambda: len(peer.sent) == len(relayed))
    time.sleep(0.1)  # settle: non-mutation types must never trickle through
    assert [json.loads(raw) for raw in peer.sent] == relayed  # in order, exact
    assert sender.sent == []


def test_broadcast_json_exclude_is_connection_identity(server_env: Any) -> None:
    _, server, _ = server_env
    excluded, equal_peer, bystander = (
        _FakeConn("excluded"),
        _FakeConn("equal-peer"),
        _FakeConn("bystander"),
    )
    server._clients.update({excluded, equal_peer, bystander})
    msg = _envelope(type="ELEMENT_COMMIT", action="DELETE_NODE", payload={"node_id": "gone"})

    server.broadcast_json(msg, exclude=excluded)

    assert _wait_until(lambda: equal_peer.sent and bystander.sent)
    time.sleep(0.1)
    assert excluded.sent == []  # only the excluded connection identity is skipped
    assert all(json.loads(raw) == msg for raw in equal_peer.sent + bystander.sent)
    assert excluded == equal_peer  # ...even though "==" cannot tell the fakes apart


def test_relay_skips_dead_client(server_env: Any) -> None:
    _, server, _ = server_env
    sender, peer, dead = _FakeConn("sender"), _FakeConn("peer"), _FakeConn("dead", broken=True)
    server._clients.update({sender, peer, dead})
    msg = _envelope(type="ELEMENT_COMMIT", action="CLEAR_CANVAS", payload={})

    server._dispatch_text(json.dumps(msg), sender=sender)

    assert _wait_until(lambda: len(peer.sent) == 1)  # dead client never blocks peers
    assert _wait_until(lambda: dead not in server._clients)  # discarded, best-effort
    time.sleep(0.1)
    assert json.loads(peer.sent[0]) == msg
    assert sender.sent == []


def test_concurrent_relay_sends_are_safe(server_env: Any) -> None:
    _, server, _ = server_env
    a, b, c = _FakeConn("a"), _FakeConn("b"), _FakeConn("c")
    server._clients.update({a, b, c})
    per_sender = 25

    def relay(fake: _FakeConn) -> None:
        for index in range(per_sender):
            server.broadcast_json(
                _envelope(
                    type="ELEMENT_COMMIT",
                    action="ADD_STROKE",
                    payload={"node_id": f"{fake.name}-{index}"},
                ),
                exclude=fake,
            )

    threads = [threading.Thread(target=relay, args=(fake,)) for fake in (a, b, c)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(_WAIT_S)
        assert not thread.is_alive()

    expected = per_sender * 2  # every fake must hear the OTHER two senders
    assert _wait_until(lambda: all(len(fake.sent) == expected for fake in (a, b, c)))
    time.sleep(0.1)
    for fake in (a, b, c):
        assert len(fake.sent) == expected  # no drops, no duplicates under load
        node_ids = [json.loads(raw)["payload"]["node_id"] for raw in fake.sent]
        assert len(set(node_ids)) == expected
        assert not any(nid.startswith(f"{fake.name}-") for nid in node_ids)  # no self-echo


def test_relay_end_to_end_between_two_real_connections(server_env: Any) -> None:
    """Handler wiring proof: ``_handler`` passes ``sender=websocket`` through."""
    _, server, rec = server_env
    msg = _envelope(type="ELEMENT_COMMIT", action="CLEAR_CANVAS", payload={})

    async def scenario() -> None:
        async with (
            websockets.connect(_ws_url(server)) as device_a,
            websockets.connect(_ws_url(server)) as device_b,
        ):
            assert await _async_wait_until(lambda: len(rec.of(CONNECTION_STATE)) >= 2)
            await device_a.send(json.dumps(msg))
            raw = await asyncio.wait_for(device_b.recv(), _WAIT_S)
            assert json.loads(raw) == msg  # peer got the exact payload...
            with pytest.raises(asyncio.TimeoutError):
                await asyncio.wait_for(device_a.recv(), 0.4)  # ...sender got no echo

    asyncio.run(scenario())
    assert rec.wait_for(RPC_MESSAGE)
    assert rec.of(RPC_MESSAGE) == [{"msg": msg}]


# -- Round 7: PC-authority relay gate ----------------------------------------


def test_relay_filter_can_veto_a_mutation(server_env: Any) -> None:
    """Issue 03: the hub decides which mutations reach the other devices."""
    _, server, rec = server_env
    sender, peer = _FakeConn("sender"), _FakeConn("peer")
    server._clients.update({sender, peer})
    server._dispatch_before_relay_cut = None  # noqa: F841 — documents intent only
    server._relay_filter = lambda msg, connection_id: False

    msg = _envelope(type="ELEMENT_COMMIT", action="ADD_SHAPE", payload={"node_id": "n"})
    server._dispatch_text(json.dumps(msg), sender=sender)

    # The PC still applied it locally (apply-then-relay ordering)…
    assert rec.wait_for(RPC_MESSAGE)
    assert rec.of(RPC_MESSAGE) == [{"msg": msg}]
    time.sleep(0.2)
    # …but nothing was fanned out to the peers.
    assert peer.sent == []
    assert sender.sent == []


def test_relay_filter_receives_the_sender_connection_id(server_env: Any) -> None:
    _, server, rec = server_env
    sender, peer = _FakeConn("sender"), _FakeConn("peer")
    server._clients.update({sender, peer})
    server._connection_ids[sender] = "conn-42"
    seen: list[tuple[dict, str | None]] = []
    server.set_relay_filter(lambda msg, cid: seen.append((msg, cid)) or True)

    msg = _envelope(type="ELEMENT_COMMIT", action="ADD_STROKE", payload={})
    server._dispatch_text(json.dumps(msg), sender=sender)

    assert rec.wait_for(RPC_MESSAGE)
    assert _wait_until(lambda: len(peer.sent) == 1)
    assert seen == [(msg, "conn-42")]


def test_server_emits_rpc_origin_after_rpc_message(server_env: Any) -> None:
    """Round 7: the hub needs the sender identity, but never before the apply."""
    bus, server, rec = server_env
    order: list[str] = []
    bus.on(RPC_ORIGIN, lambda **kw: order.append("origin"))
    sender = _FakeConn("sender")
    server._clients.add(sender)
    server._connection_ids[sender] = "conn-1"

    msg = _envelope(type="CANVAS_LIFECYCLE", action="OPEN_CANVAS", payload={"canvas": {}})
    server._dispatch_text(json.dumps(msg), sender=sender)

    assert rec.wait_for(RPC_MESSAGE)
    assert _wait_until(lambda: order == ["origin"])


def test_set_relay_filter_none_restores_legacy_relay(server_env: Any) -> None:
    _, server, _ = server_env
    sender, peer = _FakeConn("sender"), _FakeConn("peer")
    server._clients.update({sender, peer})
    server.set_relay_filter(lambda msg, cid: False)
    server.set_relay_filter(None)

    msg = _envelope(type="ELEMENT_COMMIT", action="CLEAR_CANVAS", payload={})
    server._dispatch_text(json.dumps(msg), sender=sender)
    assert _wait_until(lambda: len(peer.sent) == 1)