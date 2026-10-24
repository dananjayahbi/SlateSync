"""Live device roster + PC mirror authority (round 7, issues 03/04/07).

The PC agent is the **central orchestrator**: every tablet mutation is applied
to the PC scene first, and only then fanned out to the other devices. To do
that the hub needs two pieces of state this module owns:

* **Who is connected** — one :class:`DeviceSession` per WebSocket connection,
  enriched with the ``device_id`` / ``device_name`` a tablet announces on its
  ``CANVAS_LIST`` or ``OPEN_CANVAS`` envelopes.
* **Which canvas the PC mirrors** — a single ``mirrored_canvas_id``. The first
  canvas a device opens becomes the mirrored one (issue 07); the user can then
  switch it from the Settings panel, and mutations from other canvases are not
  relayed device-to-device.

The roster is transport-agnostic: it is fed by ``CONNECTION_STATE`` /
``RPC_ORIGIN`` events and by explicit calls from :class:`CanvasSyncManager`, and
it announces itself through :data:`DEVICES_UPDATED` /
:data:`MIRROR_CHANGED`. No sockets, no Tk — unit-testable in isolation.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field

from pc_agent.core.events import DEVICES_UPDATED, MIRROR_CHANGED, EventBus

logger = logging.getLogger(__name__)


@dataclass
class DeviceSession:
    """One connected tablet (keyed by the transport connection id)."""

    connection_id: str
    peer: str | None = None
    device_id: str | None = None
    name: str | None = None
    open_canvas_id: str | None = None
    open_canvas_title: str | None = None
    connected_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)

    @property
    def label(self) -> str:
        """Human label for the Settings list (name → device id → peer)."""
        for value in (self.name, self.device_id, self.peer, self.connection_id):
            if value:
                return str(value)
        return "unknown device"

    def to_row(self, mirrored_canvas_id: str | None) -> dict:
        """Frozen ``DEVICES_UPDATED.devices`` row (see ``core/events.py``)."""
        return {
            "connection_id": self.connection_id,
            "device_id": self.device_id,
            "name": self.label,
            "peer": self.peer,
            "open_canvas_id": self.open_canvas_id,
            "open_canvas_title": self.open_canvas_title,
            "mirrored": bool(
                self.open_canvas_id is not None
                and self.open_canvas_id == mirrored_canvas_id
            ),
            "last_seen": int(self.last_seen),
        }


class DeviceRoster:
    """Connection-keyed device registry + the PC's mirrored-canvas authority."""

    def __init__(self, bus: EventBus) -> None:
        self._bus = bus
        self._lock = threading.RLock()
        self._devices: dict[str, DeviceSession] = {}
        self._mirrored: str | None = None
        self._mirrored_title: str = ""
        self._mirror_source: str | None = None  # connection that opened it

    # ------------------------------------------------------------------
    # Queries
    # ------------------------------------------------------------------
    @property
    def count(self) -> int:
        with self._lock:
            return len(self._devices)

    @property
    def mirrored_canvas_id(self) -> str | None:
        with self._lock:
            return self._mirrored

    @property
    def sessions(self) -> list[DeviceSession]:
        with self._lock:
            return list(self._devices.values())

    def roster(self) -> list[dict]:
        """Frozen ``DEVICES_UPDATED.devices`` list (newest connection last)."""
        with self._lock:
            mirrored = self._mirrored
            return [session.to_row(mirrored) for session in self._devices.values()]

    def get(self, connection_id: str | None) -> DeviceSession | None:
        if not connection_id:
            return None
        with self._lock:
            return self._devices.get(str(connection_id))

    def connection_for_canvas(self, canvas_id: str | None) -> str | None:
        """First connection that has ``canvas_id`` open (relay targeting)."""
        if not canvas_id:
            return None
        with self._lock:
            for session in self._devices.values():
                if session.open_canvas_id == canvas_id:
                    return session.connection_id
        return None

    # ------------------------------------------------------------------
    # Connection lifecycle
    # ------------------------------------------------------------------
    def attach(self, connection_id: str, peer: str | None = None) -> DeviceSession:
        """Register a freshly authenticated connection."""
        key = str(connection_id)
        with self._lock:
            session = self._devices.get(key)
            if session is None:
                session = DeviceSession(connection_id=key, peer=peer)
                self._devices[key] = session
            else:  # re-attach of the same key keeps its identity
                session.peer = peer or session.peer
                session.last_seen = time.time()
            return session

    def detach(self, connection_id: str | None) -> DeviceSession | None:
        """Drop a connection; the mirrored canvas stays on screen.

        The mirror is a *canvas*, not a connection: a tablet disconnecting must
        not blank the PC viewport (the user may be reading it). Only the source
        attribution is released so the next open can claim the mirror.
        """
        if not connection_id:
            return None
        key = str(connection_id)
        with self._lock:
            session = self._devices.pop(key, None)
            if session is None:
                return None
            if self._mirror_source == key:
                self._mirror_source = None
        return session

    def identify(
        self,
        connection_id: str | None,
        device_id: str | None = None,
        name: str | None = None,
    ) -> None:
        """Bind the tablet-announced identity to a connection."""
        session = self.get(connection_id)
        if session is None:
            return
        with self._lock:
            if isinstance(device_id, str) and device_id:
                session.device_id = device_id
            if isinstance(name, str) and name:
                session.name = name
            session.last_seen = time.time()

    def touch(self, connection_id: str | None) -> None:
        session = self.get(connection_id)
        if session is None:
            return
        with self._lock:
            session.last_seen = time.time()

    # ------------------------------------------------------------------
    # Open canvas / mirror selection
    # ------------------------------------------------------------------
    def note_open(
        self,
        connection_id: str | None,
        canvas_id: str | None,
        title: str | None = None,
    ) -> bool:
        """Record that a device opened ``canvas_id``.

        Returns ``True`` when this call *selected* the mirror — the first
        canvas opened after startup (issue 07) or the first one after the
        previous mirror owner disconnected.
        """
        session = self.get(connection_id)
        if session is not None:
            with self._lock:
                session.open_canvas_id = canvas_id or None
                session.open_canvas_title = (title or "") or None
                session.last_seen = time.time()
        if not canvas_id:
            return False
        with self._lock:
            if self._mirrored is not None:
                # Adopt the connection that owns the already-mirrored canvas
                # (the local OPEN_CANVAS handler selects it before the server's
                # RPC_ORIGIN event names the sender).
                if (
                    self._mirror_source is None
                    and connection_id
                    and str(self._mirrored) == str(canvas_id)
                ):
                    self._mirror_source = str(connection_id)
                return False
            self._mirrored = str(canvas_id)
            self._mirrored_title = (title or "") or ""
            self._mirror_source = str(connection_id) if connection_id else None
        return True

    def select_mirror(
        self, canvas_id: str | None, title: str | None = None
    ) -> bool:
        """Force the mirrored canvas (PC Settings → device/canvas switch).

        Returns ``True`` when the selection actually changed.
        """
        target = str(canvas_id) if canvas_id else None
        with self._lock:
            if target == self._mirrored:
                return False
            self._mirrored = target
            self._mirrored_title = (title or "") if target else ""
            self._mirror_source = (
                self.connection_for_canvas(target) if target else None
            )
        return True

    def mirrored_title(self) -> str:
        with self._lock:
            return self._mirrored_title

    # ------------------------------------------------------------------
    # Emission
    # ------------------------------------------------------------------
    def emit_devices(self) -> None:
        """Publish the frozen ``DEVICES_UPDATED`` payload."""
        with self._lock:
            payload = {
                "devices": self.roster(),
                "mirrored_canvas_id": self._mirrored,
                "count": len(self._devices),
            }
            source = self._mirror_source
        self._bus.emit(DEVICES_UPDATED, connection_id=source, **payload)

    def emit_mirror(self) -> None:
        """Publish the frozen ``MIRROR_CHANGED`` payload."""
        with self._lock:
            payload = {
                "canvas_id": self._mirrored,
                "title": self._mirrored_title,
                "connection_id": self._mirror_source,
            }
        self._bus.emit(MIRROR_CHANGED, **payload)
