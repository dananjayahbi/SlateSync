"""Doc 11 — WebSocket stream server: dual-path gateway to the PC ``EventBus``.

Binding spec: ``docs/micro/11_pc_websocket_stream_server.md`` + template §3/§4.
A ``websockets`` asyncio server on ``config.ws_port`` (50606) path ``/ws`` runs
in a daemon thread with its own event loop. Dispatch is emit-only: the server
validates the §4.2 envelope shell but never interprets ``payload`` (Docs 09/10
own the payload keys). Round 6 (Doc 02 §10.2): mutation envelopes received from
a device are re-broadcast to every OTHER connection after local dispatch
(``broadcast_json(msg, exclude=None)``). One ``async for`` per connection
preserves frame order; the u16 seq gate has a single ``last_seq`` per
connection shared by all frame types (template §3).
"""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import urllib.parse
from collections.abc import Callable

from websockets.asyncio.server import Server, ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CAMERA_DELTA,
    CONNECTION_STATE,
    LIVE_FRAME,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    RPC_ACTIONS,
    RPC_TYPES,
    is_newer_seq,
    unpack_live_frame,
)

logger = logging.getLogger("slatesync.ws")

_WS_PATH = "/ws"
_CLOSE_UNAUTHORIZED = 4001
_CLOSE_BAD_PATH = 1008
_STARTUP_TIMEOUT_S = 5.0
_STOP_JOIN_TIMEOUT_S = 5.0
_REQUIRED_ENVELOPE_KEYS = ("id", "type", "action", "canvas_id")

#: Doc 02 §10.2 — envelope types re-broadcast to other devices after local
#: dispatch (mutation relay); every other type is PC-local and never relayed.
_RELAY_TYPES = frozenset({"ELEMENT_COMMIT", "ARTBOARD_RESIZE"})


class WsStreamServer:
    """Threaded ``/ws`` gateway (template §4 freeze — signatures frozen)."""

    def __init__(
        self,
        bus: EventBus,
        config: AppConfig,
        token_provider: Callable[[], str],
        host: str = "0.0.0.0",
    ) -> None:
        self._bus = bus
        self._config = config
        self._token_provider = token_provider
        self._host = host
        self._thread: threading.Thread | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._stop_event: asyncio.Event | None = None
        self._server: Server | None = None
        self._ready = threading.Event()
        self._startup_error: BaseException | None = None
        self._clients: set[ServerConnection] = set()
        self._bound_port: int | None = None

    # -- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        """Spawn the daemon thread; blocks until the port is bound.

        Idempotent: calling ``start()`` while running is a logged no-op. A bind
        failure surfaces as ``RuntimeError`` — never a half-started server.
        """
        thread = self._thread
        if thread is not None and thread.is_alive():
            logger.warning("WsStreamServer.start() ignored: already running")
            return
        self._ready.clear()
        self._startup_error = None
        thread = threading.Thread(target=self._run, name="ws-stream-server", daemon=True)
        self._thread = thread
        thread.start()
        if not self._ready.wait(_STARTUP_TIMEOUT_S):
            self._thread = None
            raise RuntimeError("ws stream server did not become ready within 5 s")
        if self._startup_error is not None:
            error = self._startup_error
            thread.join(timeout=_STOP_JOIN_TIMEOUT_S)
            self._thread = None
            raise RuntimeError(f"ws stream server failed to start: {error}") from error

    def stop(self) -> None:
        """Close the server, stop the loop, join the thread ≤ 5 s; idempotent."""
        thread = self._thread
        if thread is None:
            return
        loop = self._loop
        stop_event = self._stop_event
        if loop is not None and stop_event is not None and loop.is_running():
            try:
                loop.call_soon_threadsafe(stop_event.set)
            except RuntimeError:  # loop closed concurrently — nothing to stop
                logger.debug("event loop already closed during stop()", exc_info=True)
        thread.join(timeout=_STOP_JOIN_TIMEOUT_S)
        if thread.is_alive():
            logger.warning(
                "ws stream server thread still alive after %.0f s join", _STOP_JOIN_TIMEOUT_S
            )
            return
        self._thread = None
        self._loop = None
        self._stop_event = None
        self._server = None
        self._bound_port = None
        self._clients.clear()

    @property
    def port(self) -> int:
        """Actually bound port while running; ``config.ws_port`` otherwise."""
        if self._bound_port is not None:
            return self._bound_port
        return self._config.ws_port

    def broadcast_json(self, msg: dict, exclude: ServerConnection | None = None) -> None:
        """Thread-safe fan-out of a JSON envelope to every live connection.

        Callable from ANY thread (Tk, executor). Never blocks and never raises
        into the caller: before ``start()`` (or after ``stop()``) the message is
        logged and dropped.

        ``exclude`` (Doc 02 §10.2, additive round-6 parameter): a connection
        object skipped by IDENTITY (``is``) — used by the live mutation relay
        so a sending device never receives its own echo. Existing single-argument
        callers are unchanged.
        """
        loop = self._loop
        if loop is None or not loop.is_running():
            logger.warning("broadcast_json called before start(); message dropped")
            return
        try:
            payload = json.dumps(msg)
        except (TypeError, ValueError):
            logger.exception("broadcast_json: message is not JSON-serializable; dropped")
            return
        try:
            future = asyncio.run_coroutine_threadsafe(self._send_all(payload, exclude), loop)
        except RuntimeError:  # loop stopped between the check and scheduling
            logger.warning("broadcast_json: event loop unavailable; message dropped")
            return
        future.add_done_callback(self._consume_broadcast_result)

    # -- thread target -------------------------------------------------------

    def _run(self) -> None:
        """Daemon-thread target: fresh event loop → serve → wait for stop."""
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._loop = loop
        stop_event = asyncio.Event()
        self._stop_event = stop_event

        async def _serve_forever() -> None:
            async with serve(self._handler, self._host, self._config.ws_port) as server:
                self._server = server
                self._bound_port = int(server.sockets[0].getsockname()[1])
                logger.info("ws stream server listening on %s:%s", self._host, self._bound_port)
                self._ready.set()
                await stop_event.wait()

        try:
            loop.run_until_complete(_serve_forever())
        except BaseException as exc:  # bind failure or loop crash — unblocks start()
            self._startup_error = exc
            self._ready.set()
            logger.exception("ws stream server stopped unexpectedly")
        finally:
            self._server = None
            try:
                if not loop.is_closed():
                    loop.run_until_complete(loop.shutdown_asyncgens())
            except Exception:
                logger.debug("shutdown_asyncgens failed", exc_info=True)
            loop.close()

    # -- connection handler --------------------------------------------------

    async def _handler(self, websocket: ServerConnection) -> None:
        request = websocket.request
        parts = urllib.parse.urlsplit(request.path if request is not None else "")
        if parts.path != _WS_PATH:
            logger.warning("closing connection with unexpected path %r", parts.path)
            await websocket.close(code=_CLOSE_BAD_PATH, reason="expected path /ws")
            return
        token = urllib.parse.parse_qs(parts.query).get("token", [None])[0]
        try:
            expected = self._token_provider()  # read lazily, once per connection
        except Exception:
            logger.exception("token_provider raised; rejecting connection")
            expected = None
        if token is None or token != expected:
            logger.warning("closing unauthorized connection (missing/mismatched token)")
            await websocket.close(code=_CLOSE_UNAUTHORIZED, reason="unauthorized")
            return

        peer = self._peer(websocket)
        self._clients.add(websocket)
        self._bus.emit(CONNECTION_STATE, connected=True, peer=peer)
        last_seq: int | None = None  # reset per connection — never shared
        try:
            async for message in websocket:  # single reader preserves frame order
                try:
                    if isinstance(message, str):
                                self._dispatch_text(message, sender=websocket)
                    else:
                        last_seq = self._dispatch_binary(message, last_seq)
                except Exception:
                    logger.exception("failed to dispatch message; connection continues")
        except ConnectionClosed:  # abrupt drop (no close frame) lands here
            pass
        finally:
            self._bus.emit(CONNECTION_STATE, connected=False, peer=None)
            self._clients.discard(websocket)

    @staticmethod
    def _peer(websocket: ServerConnection) -> str:
        address = websocket.remote_address
        if address is None:
            return "unknown"
        return f"{address[0]}:{address[1]}"

    # -- binary path ---------------------------------------------------------

    def _dispatch_binary(self, data: bytes, last_seq: int | None) -> int | None:
        view = memoryview(data)  # zero-copy unpack (Doc 11 §4)
        if len(view) != 16:
            logger.warning("dropping binary frame with %d bytes (expected 16)", len(view))
            return last_seq
        frame = unpack_live_frame(view)
        if not self._seq_accept(last_seq, frame.seq):
            return last_seq  # stale/duplicate: dropped silently (template §3)
        if frame.frame_type == FRAME_CAMERA:
            self._bus.emit(CAMERA_DELTA, frame=frame)
        else:
            self._bus.emit(LIVE_FRAME, frame=frame)
        return frame.seq

    def _seq_accept(self, last: int | None, seq: int) -> bool:
        """Mod-2^16 newer-than gate (template §3); first frame always accepted."""
        return is_newer_seq(seq, last)

    # -- text path -----------------------------------------------------------

    def _dispatch_text(self, raw: str, sender: ServerConnection | None = None) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("dropping text frame that is not valid JSON")
            return
        if not isinstance(msg, dict) or not self._valid_envelope(msg):
            logger.warning("dropping RPC envelope failing section 4.2 shell validation")
            return
        self._bus.emit(RPC_MESSAGE, msg=msg)  # payload untouched (Docs 09/10/15)
        # Doc 02 §10.2 live mutation relay: AFTER local dispatch, re-broadcast
        # ELEMENT_COMMIT (incl. CLEAR_CANVAS) / ARTBOARD_RESIZE to every OTHER
        # device — the sending connection is excluded, dead clients are skipped
        # in _send_all. Non-mutation types (CANVAS_LIFECYCLE, ASSET_UPLOAD,
        # EXPORT_JOB) are never relayed.
        if sender is not None and msg["type"] in _RELAY_TYPES:
            self.broadcast_json(msg, exclude=sender)

    @staticmethod
    def _valid_envelope(msg: dict) -> bool:
        if any(key not in msg for key in _REQUIRED_ENVELOPE_KEYS):
            return False
        return (
            isinstance(msg["id"], str)
            and isinstance(msg["canvas_id"], str)
            and isinstance(msg["type"], str)
            and msg["type"] in RPC_TYPES
            and isinstance(msg["action"], str)
            and msg["action"] in RPC_ACTIONS
        )

    # -- broadcast helpers (loop thread) -------------------------------------

    async def _send_all(self, payload: str, exclude: ServerConnection | None = None) -> None:
        for websocket in list(self._clients):  # snapshot: handlers may mutate
            if exclude is not None and websocket is exclude:
                continue  # §10.2: identity-based sender exclusion (never ==)
            try:
                await websocket.send(payload)
            except Exception:
                self._clients.discard(websocket)  # dead client dropped, best-effort
                logger.debug("dropped dead client during broadcast", exc_info=True)

    @staticmethod
    def _consume_broadcast_result(future: asyncio.Future[None]) -> None:
        try:
            error = future.exception()
        except Exception:  # cancelled — nothing to report
            return
        if error is not None:
            logger.warning("broadcast_json fan-out failed: %s", error)
