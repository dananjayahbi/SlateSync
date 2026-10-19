"""Bidirectional canvas sync — PC side of Doc 02 §8 (Canvas Sync Extension).

``CanvasSyncManager`` owns the PC's half of the round-4 contract:

* ``CONNECTION_STATE(connected=True)`` → ``push(CANVAS_LIST_REQUEST)``
  (§8.3 flow 2 — the tablet replies, and also pushes unsolicited).
* ``RPC_MESSAGE`` / ``CANVAS_LIST`` → cache the rows and emit the bus event
  ``CANVAS_LIST_UPDATED`` (StudioWindow's File → "Open synced canvas…"
  dialog reads the cache through it).
* ``RPC_MESSAGE`` / ``OPEN_CANVAS`` **with the ``canvas`` key** (§8.2
  cross-device dialect) → ``store.open_payload(...)`` so the mirror switches.
  The legacy ``path`` dialect is PC-internal only — DocumentStore handles it
  on the same bus, so this manager ignores it here (§8.2).

Construction is ``(bus, config, push, store)``; ``push`` is main.py's
``server.broadcast_json``. Call :meth:`shutdown` during teardown to
unsubscribe symmetrically.
"""

from __future__ import annotations

import logging
import time
import uuid

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    RPC_MESSAGE,
    EventBus,
)

logger = logging.getLogger(__name__)


class CanvasSyncManager:
    """Doc 02 §8 PC participant: list cache + open hand-off (see module doc)."""

    def __init__(
        self,
        bus: EventBus,
        config: AppConfig,
        push,
        store,
    ) -> None:
        self._bus = bus
        self._config = config
        self._push = push
        self._store = store
        self._canvases: list[dict] = []
        self._subscriptions: list[tuple[str, object]] = [
            (CONNECTION_STATE, self._on_connection_state),
            (RPC_MESSAGE, self._on_rpc),
        ]
        for event, handler in self._subscriptions:
            bus.on(event, handler)  # type: ignore[arg-type]

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    @property
    def canvases(self) -> list[dict]:
        """Cached CANVAS_LIST rows (may be empty until the tablet replies)."""
        return list(self._canvases)

    def request_open(self, canvas_id: str) -> None:
        """§8.3 flow 3: ask the tablet to load + broadcast a document."""
        self._push(
            self._envelope(
                "CANVAS_LIFECYCLE", "CANVAS_OPEN_REQUEST", {"canvas_id": str(canvas_id)}
            )
        )

    def shutdown(self) -> None:
        """Unsubscribe both bus handlers; idempotent (EventBus.off is a no-op)."""
        for event, handler in self._subscriptions:
            self._bus.off(event, handler)  # type: ignore[arg-type]

    # ------------------------------------------------------------------
    # Bus handlers
    # ------------------------------------------------------------------
    def _on_connection_state(self, connected=None, peer=None, **_extra) -> None:
        if not connected:
            return
        try:
            self._push(self._envelope("CANVAS_LIFECYCLE", "CANVAS_LIST_REQUEST", {}))
        except Exception:  # never let a push failure poison the bus chain
            logger.exception("CANVAS_LIST_REQUEST push failed")

    def _on_rpc(self, msg=None, **_extra) -> None:
        if not isinstance(msg, dict):
            return
        if msg.get("type") != "CANVAS_LIFECYCLE":
            return
        action = msg.get("action")
        payload = msg.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        if action == "CANVAS_LIST":
            rows = payload.get("canvases")
            self._canvases = [dict(row) for row in rows] if isinstance(rows, list) else []
            self._bus.emit(CANVAS_LIST_UPDATED, canvases=list(self._canvases))
        elif action == "OPEN_CANVAS" and "canvas" in payload:
            data = payload.get("canvas")
            if not isinstance(data, dict):
                logger.error("OPEN_CANVAS canvas dialect must carry an object: %r", data)
                return
            try:
                self._store.open_payload(data)
            except Exception:
                logger.exception("OPEN_CANVAS (canvas dialect) failed")
        # OPEN_CANVAS without 'canvas' is the PC-internal path dialect (§8.2):
        # never handled here and never accepted from the wire.

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _envelope(msg_type: str, action: str, payload: dict) -> dict:
        """overview §4.2 shell — list/open-request envelopes use ``canvas_id: ""``."""
        return {
            "id": str(uuid.uuid4()),
            "type": msg_type,
            "action": action,
            "canvas_id": "",
            "payload": payload,
            "timestamp": int(time.time()),
        }
