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
        #: Round-10 issue 02 — an explicit Settings choice wins over the
        #: automatic "follow the owning device" rule until the user (or a
        #: canvas deletion) clears it.
        self._mirror_pinned: bool = False
        #: Tablet identity behind the mirror (survives a reconnect, which gets
        #: a fresh ``connection_id``), so the owning device keeps its claim.
        self._mirror_device_id: str | None = None

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

        Returns ``True`` when this call *selected* (or *moved*) the mirror.

        Round-10 issue 02 — the mirror follows the device that owns it: when
        the connection already mirrored switches to another canvas, the mirror
        moves with it (the PC is the orchestrator, so the newest open of the
        owning device is what every other device sees). A *different* device
        still cannot steal the mirror (round-7 issue 07), and an explicit
        Settings choice pins it.
        """
        session = self.get(connection_id)
        if session is not None:
            with self._lock:
                session.open_canvas_id = canvas_id or None
                session.open_canvas_title = (title or "") or None
                session.last_seen = time.time()
        if not canvas_id:
            return False
        target = str(canvas_id)
        with self._lock:
            if self._mirrored is None:
                self._mirrored = target
                self._mirrored_title = (title or "") or ""
                self._mirror_source = str(connection_id) if connection_id else None
                self._mirror_device_id = getattr(session, "device_id", None)
                return True
            if self._mirrored == target:
                # Adopt the connection that owns the already-mirrored canvas
                # (the local OPEN_CANVAS handler selects it before the server's
                # RPC_ORIGIN event names the sender).
                if self._mirror_source is None and connection_id:
                    self._mirror_source = str(connection_id)
                    self._mirror_device_id = getattr(session, "device_id", None)
                return False
            if not self._mirror_pinned and self._owns_mirror(connection_id, session):
                # The mirrored device switched canvases — follow it.
                self._mirrored = target
                self._mirrored_title = (title or "") or ""
                self._mirror_source = str(connection_id) if connection_id else None
                self._mirror_device_id = getattr(session, "device_id", None)
                return True
            return False

    def _owns_mirror(
        self, connection_id: str | None, session: DeviceSession | None
    ) -> bool:
        """Whether ``connection_id`` is the device the mirror currently follows.

        A reconnect produces a new ``connection_id`` for the same tablet, so
        the device id is preferred over the connection key when both sides
        have one.
        """
        if not connection_id:
            return False
        if self._mirror_source == str(connection_id):
            return True
        device_id = getattr(session, "device_id", None)
        return bool(
            self._mirror_source is None
            and device_id
            and self._mirror_device_id
            and str(device_id) == str(self._mirror_device_id)
        )

    def mirror_source(self) -> str | None:
        """Connection that owns the mirrored canvas (``None`` when unattributed)."""
        with self._lock:
            return self._mirror_source

    def select_mirror(
        self, canvas_id: str | None, title: str | None = None
    ) -> bool:
        """Force the mirrored canvas (PC Settings → device/canvas switch).

        A non-``None`` selection PINS the mirror so a device switching its own
        canvas cannot silently take it back (round-10 issue 02). Clearing the
        selection releases the pin and lets the next open claim the mirror.

        Returns ``True`` when the selection actually changed.
        """
        target = str(canvas_id) if canvas_id else None
        with self._lock:
            pinned = target is not None
            if target == self._mirrored and pinned == self._mirror_pinned:
                return False
            self._mirrored = target
            self._mirrored_title = (title or "") if target else ""
            self._mirror_source = (
                self.connection_for_canvas(target) if target else None
            )
            owner = self._devices.get(self._mirror_source) if self._mirror_source else None
            self._mirror_device_id = getattr(owner, "device_id", None)
            self._mirror_pinned = pinned
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
