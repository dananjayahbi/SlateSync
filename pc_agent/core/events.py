"""Synchronous caller-thread ``EventBus`` + the 12 event-name constants (Doc 04 §4)."""

from __future__ import annotations

import logging
from typing import Callable

logger = logging.getLogger(__name__)

LIVE_FRAME = "LIVE_FRAME"
CAMERA_DELTA = "CAMERA_DELTA"
RPC_MESSAGE = "RPC_MESSAGE"
CONNECTION_STATE = "CONNECTION_STATE"
DOCUMENT_LOADED = "DOCUMENT_LOADED"
COMMITTED_NODE = "COMMITTED_NODE"
ARTBOARD_CHANGED = "ARTBOARD_CHANGED"
EXPORT_STARTED = "EXPORT_STARTED"
EXPORT_PROGRESS = "EXPORT_PROGRESS"
EXPORT_FINISHED = "EXPORT_FINISHED"
PAIRING_INFO = "PAIRING_INFO"
#: Round 4/5 (Doc 02 §8.1/§9) — merged canvas cache + live device count.
#: Frozen payload shape (round 5): ``{canvases: [{id, title, preset,
#: background, updated_at}, ...], devices: int}`` where ``canvases`` is the
#: hub-merged store (updated_at DESC) and ``devices`` is the live connection
#: count. Handlers must tolerate unknown keys (``**extra``).
CANVAS_LIST_UPDATED = "CANVAS_LIST_UPDATED"


class EventBus:
    """Synchronous emit on the caller's thread (template §4, Doc 04 §4).

    ``on()`` drops duplicate (event, handler) registrations; ``off()`` on a
    missing registration is a no-op; a handler exception is logged and does
    not prevent the remaining handlers from running.
    """

    def __init__(self) -> None:
        self._handlers: dict[str, list[Callable[..., None]]] = {}

    def on(self, event: str, handler: Callable[..., None]) -> None:
        handlers = self._handlers.setdefault(event, [])
        if handler not in handlers:
            handlers.append(handler)

    def off(self, event: str, handler: Callable[..., None]) -> None:
        handlers = self._handlers.get(event)
        if handlers is None:
            return
        try:
            handlers.remove(handler)
        except ValueError:
            pass

    def emit(self, event: str, **payload) -> None:
        for handler in list(self._handlers.get(event, [])):
            try:
                handler(**payload)
            except Exception:  # handler failures are logged, never raised (Doc 04 §4)
                logger.exception("EventBus handler failed for %r", event)
