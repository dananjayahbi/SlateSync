"""Synchronous caller-thread ``EventBus`` + event-name constants (Doc 04 §4, Doc 02 §10.1)."""

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
# Round-13 issue 02 — OCR job lifecycle for the PC jobs panel. Separate from the
# wire envelopes on purpose: the panel must show work the tablet may never see
# (e.g. a job that failed before any reply could be sent).
OCR_JOB_STARTED = "OCR_JOB_STARTED"
OCR_JOB_PROGRESS = "OCR_JOB_PROGRESS"
OCR_JOB_FINISHED = "OCR_JOB_FINISHED"
PAIRING_INFO = "PAIRING_INFO"
#: Round 4/5 (Doc 02 §8.1/§9) — merged canvas cache + live device count.
#: Frozen payload shape (round 5): ``{canvases: [{id, title, preset,
#: background, updated_at}, ...], devices: int}`` where ``canvases`` is the
#: hub-merged store (updated_at DESC) and ``devices`` is the live connection
#: count. Handlers must tolerate unknown keys (``**extra``).
CANVAS_LIST_UPDATED = "CANVAS_LIST_UPDATED"
#: Round 6 (Doc 02 §10.1) — ``SceneGraph`` wiped every element via
#: ``CLEAR_CANVAS``. Frozen payload: ``{canvas_id: str}`` (the envelope's
#: target document id, echoed verbatim). Viewports repaint on this event;
#: handlers must tolerate unknown keys (``**extra``).
CANVAS_CLEARED = "CANVAS_CLEARED"
#: Round 7 — live device roster for the PC Settings panel. Frozen payload:
#: ``{devices: [{connection_id, device_id, name, peer, open_canvas_id,
#: open_canvas_title, mirrored, last_seen}, ...], mirrored_canvas_id: str|None,
#: count: int}``. Handlers must tolerate unknown keys (``**extra``).
DEVICES_UPDATED = "DEVICES_UPDATED"
#: Round 7 — the PC's mirrored canvas changed (device opened a canvas, or the
#: user picked one in Settings). Frozen payload: ``{canvas_id: str|None,
#: title: str, connection_id: str|None}``.
MIRROR_CHANGED = "MIRROR_CHANGED"
#: Round 7 — a wire envelope that arrived from a device, tagged with its
#: originating connection. Payload: ``{msg: dict, connection_id: str|None}``.
#: Emitted right AFTER ``RPC_MESSAGE`` for the same envelope (which stays
#: untouched so payload-owning handlers are unaffected); the hub uses it to
#: attribute canvas opens / mutations to a device in the Settings roster.
RPC_ORIGIN = "RPC_ORIGIN"
#: Round 9 (issue 07) — an ``ASSET_DONE`` upload was committed to disk.
#: Payload: ``{canvas_id: str, filename: str}``. Viewports drop their cached
#: IMAGE textures and repaint so a node drawn BEFORE its bytes landed stops
#: showing the placeholder. Handlers must tolerate unknown keys (``**extra``).
ASSET_UPLOADED = "ASSET_UPLOADED"


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
