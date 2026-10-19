"""Hub-side canvas sync — PC participant of Doc 02 §8 + §9 (round 5, v2).

``CanvasSyncManager`` owns the PC hub half of the round-5 contract
(Doc 02 §9 — NORMATIVE):

* Per-device registry keyed by ``device_id`` from CANVAS_LIST v2 payloads;
  a missing ``device_id`` falls back to ``legacy-<conn>`` (§9.2).
* Merge = union by id + LWW on ``updated_at`` (§9.1): a strictly-newer row
  displaces the local copy, equal keeps local (no churn), older loses.
* ``CONNECTION_STATE(connected)`` → broadcast ``CANVAS_LIST (origin:hub)``
  (§9.2: hub list on each new connection) + ``CANVAS_LIST_REQUEST``
  (§8.3 flow 2); the live connection count is the ``devices`` payload field.
* Device ``CANVAS_LIST`` → merge → emit ``CANVAS_LIST_UPDATED`` with the
  frozen ``{canvases, devices}`` payload → broadcast ``CANVAS_LIST
  (origin:hub)`` → enqueue ``CANVAS_PULL`` for every id the hub lacks or has
  older (one id per message, sequential and throttled — §9.4 flow 2).
* ``CANVAS_PUT`` received → LWW → ``index.save_document_if_newer`` → on an
  actual store change emit ``CANVAS_LIST_UPDATED`` + rebroadcast the hub list.
  A ``source:"hub"`` PUT is an echo of our own broadcast and is ignored.
* ``CANVAS_PULL`` received → reply ``CANVAS_PUT {source:"hub"}`` only when
  the stored copy is strictly newer than ``have_updated_at`` (§9.1).
* ``OPEN_CANVAS {canvas}`` (§8.2 cross-device dialect) → persist-on-open
  (§9.3 — done inside ``DocumentStore.open_payload`` via its attached
  ``LocalCanvasIndex``, BEFORE the switch) → ``store.open_payload(...)`` so
  the mirror switches; the hub list is rebroadcast when the store changed.
  The legacy ``path`` dialect is PC-internal and is ignored here (§8.2).
* ``put_canvas(doc)`` (§9.4 flow 4 — PC File→New): silent ``CANVAS_PUT``
  broadcast + hub list broadcast — devices persist WITHOUT switching.

Construction stays ``(bus, config, push, store)``; round-5 additions are
keyword-only: ``index`` (a ``LocalCanvasIndex`` — attached to the store when
given, else ``store.index`` is used) and ``pull_interval_s`` (drain throttle;
0 = sequential synchronous drain, used by tests). With no index, persistence
is a no-op and only the in-memory merge is kept; with 0 connections every
push fans out to nobody, so browsing and sync actions are safe no-ops.
Call :meth:`shutdown` during teardown to unsubscribe symmetrically and to
cancel any pending pull drain.
"""

from __future__ import annotations

import logging
import os
import platform
import threading
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

#: A CANVAS_PULL we sent is re-planned after this many seconds (device silent).
_PULL_PENDING_TTL_S = 15.0


class CanvasSyncManager:
    """Doc 02 §9 PC hub: per-device state, LWW merge, pull/put, hub list
    (see the module doc for the full flow map)."""

    def __init__(
        self,
        bus: EventBus,
        config: AppConfig,
        push,
        store,
        *,
        index=None,
        pull_interval_s: float = 0.05,
    ) -> None:
        self._bus = bus
        self._config = config
        self._push = push
        self._store = store
        if index is not None and hasattr(store, "attach_index"):
            store.attach_index(index)  # single source of truth: persist-on-open
        self._index = index if index is not None else getattr(store, "index", None)
        # Merge inputs: hub-authoritative rows (mirrors the index when one is
        # attached) and rows learned from devices — union by id, LWW on updated_at.
        self._local_rows: dict[str, dict] = {}
        self._device_rows: dict[str, dict] = {}
        self._devices: dict[str, dict] = {}  # registry keyed by device_id (§9.2)
        self._connections = 0  # live connection count (the `devices` field)
        self._last_peer: str | None = None  # legacy-<conn> fallback source
        self._hub_device_id: str | None = None
        self._lock = threading.Lock()
        self._pull_queue: list[dict] = []  # sequential CANVAS_PULL drain (§9.4.2)
        self._pull_pending: dict[str, tuple[str, float]] = {}  # id → (device, sent_at)
        self._pull_timer: threading.Timer | None = None
        self._last_pull_at: float | None = None
        self._pull_interval_s = max(0.0, float(pull_interval_s))
        self._stopped = False
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
        """Hub-merged store: union by id + LWW, sorted ``updated_at`` DESC."""
        return self._merged()

    @property
    def devices(self) -> int:
        """Live connection count (§9.2 — the ``devices`` field on the event)."""
        return self._connections

    @property
    def registry(self) -> dict[str, dict]:
        """Per-device state keyed by ``device_id`` (legacy-<conn> fallback):
        ``{device_id, device_name, last_list, last_seen}`` per device."""
        with self._lock:
            return {key: dict(value) for key, value in self._devices.items()}

    @property
    def hub_device_id(self) -> str:
        """Stable uuid for this PC install (§9.2): read from
        ``<appdata>/device_id``, created atomically on first use."""
        with self._lock:
            if self._hub_device_id:
                return self._hub_device_id
            path = os.path.join(str(self._config.appdata_dir), "device_id")
            device_id: str | None = None
            try:
                with open(path, encoding="utf-8") as handle:
                    device_id = handle.read().strip() or None
            except FileNotFoundError:
                pass
            except OSError as exc:
                logger.warning("cannot read %s (%s); generating a new id", path, exc)
            if not device_id:
                device_id = str(uuid.uuid4())
                tmp = path + ".tmp"
                try:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(tmp, "w", encoding="utf-8") as handle:
                        handle.write(device_id + "\n")
                    os.replace(tmp, path)
                except OSError:
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
                    logger.warning("cannot persist hub device id to %s", path, exc_info=True)
            self._hub_device_id = device_id
            return device_id

    def request_open(self, canvas_id: str) -> None:
        """§8.3 flow 3: ask the tablet to load + broadcast a document."""
        self._push(
            self._envelope(
                "CANVAS_LIFECYCLE", "CANVAS_OPEN_REQUEST", {"canvas_id": str(canvas_id)}
            )
        )

    def put_canvas(self, doc) -> None:
        """§9.4 flow 4 (PC File→New): broadcast a silent ``CANVAS_PUT`` —
        receivers persist WITHOUT switching — followed by the hub list.

        Accepts a ``CanvasDocument`` (serialized through the store) or an
        already-serialized document dict. The caller persists to the local
        index first; the row is mirrored in-memory too so the very first hub
        list already advertises it.
        """
        body = doc if isinstance(doc, dict) else None
        if body is None:
            to_json = getattr(self._store, "document_to_json", None)
            if to_json is None:
                logger.error("put_canvas needs a document dict or a DocumentStore")
                return
            try:
                body = to_json(doc)
            except Exception:
                logger.exception("put_canvas could not serialize the document")
                return
        row = _row_of(body)
        if not row["id"]:
            logger.error("put_canvas: document has no canvas_id: %r", body.get("canvas_id"))
            return
        self._local_rows[row["id"]] = row
        try:
            self._push(
                self._envelope(
                    "CANVAS_LIFECYCLE",
                    "CANVAS_PUT",
                    {"canvas": body, "source": "hub"},
                    canvas_id=row["id"],
                )
            )
        except Exception:  # never let a push failure poison the caller
            logger.exception("CANVAS_PUT push failed")
        self._emit_list()
        self.broadcast_hub_list()

    def broadcast_hub_list(self) -> None:
        """§9.2: push the merged ``CANVAS_LIST (origin:hub)`` to every device
        (a safe no-op fan-out when 0 devices are connected)."""
        try:
            self._push(
                self._envelope(
                    "CANVAS_LIFECYCLE", "CANVAS_LIST", self._hub_list_payload()
                )
            )
        except Exception:  # never let a push failure poison the bus chain
            logger.exception("hub CANVAS_LIST push failed")

    def shutdown(self) -> None:
        """Unsubscribe both bus handlers and cancel the pull drain; idempotent
        (EventBus.off is a no-op)."""
        for event, handler in self._subscriptions:
            self._bus.off(event, handler)  # type: ignore[arg-type]
        with self._lock:
            self._stopped = True
            if self._pull_timer is not None:
                self._pull_timer.cancel()
                self._pull_timer = None
            self._pull_queue.clear()
            self._pull_pending.clear()

    # ------------------------------------------------------------------
    # Bus handlers
    # ------------------------------------------------------------------
    def _on_connection_state(self, connected=None, peer=None, **_extra) -> None:
        if not connected:
            with self._lock:
                self._connections = max(0, self._connections - 1)
            self._emit_list()  # devices transition (registry rows stay cached)
            return
        with self._lock:
            self._connections += 1
            if peer:
                self._last_peer = str(peer)
        self._emit_list()
        # §9.2: hub list on each new connection, then §8.3 flow 2 asks for
        # the device's own list (it also pushes one unsolicited).
        self.broadcast_hub_list()
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
            self._on_canvas_list(payload)
        elif action == "CANVAS_PUT":
            self._on_canvas_put(payload)
        elif action == "CANVAS_PULL":
            self._on_canvas_pull(payload)
        elif action == "OPEN_CANVAS":
            self._on_open_canvas(payload)
        # OPEN_CANVAS without 'canvas' is the PC-internal path dialect (§8.2):
        # never handled here and never accepted from the wire.

    def _on_canvas_list(self, payload: dict) -> None:
        """Device CANVAS_LIST (v2) → registry + merge → emit → hub list → pulls."""
        rows: list[dict] = []
        raw_rows = payload.get("canvases")
        if isinstance(raw_rows, list):
            for entry in raw_rows:
                if isinstance(entry, dict) and isinstance(entry.get("id"), str) and entry["id"]:
                    rows.append(dict(entry))
        rows.sort(key=_updated, reverse=True)  # §8.1: sorted updated_at DESC

        if payload.get("origin") == "hub":
            return  # our own broadcast echoed back — never re-merge (no loop)

        device_id = str(payload.get("device_id") or "").strip()
        if not device_id:
            # §9.2: missing device_id ⇒ legacy-<conn> (last connected peer).
            device_id = f"legacy-{self._last_peer or 'unknown'}"
        device_name = payload.get("device_name")
        with self._lock:
            self._devices[device_id] = {
                "device_id": device_id,
                "device_name": device_name if isinstance(device_name, str) else None,
                "last_list": [dict(row) for row in rows],
                "last_seen": int(time.time()),
            }
        for row in rows:  # union by id, LWW: strictly-newer device row wins
            current = self._device_rows.get(row["id"])
            if current is None or _updated(row) > _updated(current):
                self._device_rows[row["id"]] = row

        self._emit_list()          # §9.4.1 step 2: merged store to local UI
        self.broadcast_hub_list()  # §9.4.1 step 3: merged store to every device
        self._plan_pulls(rows, device_id)  # §9.4.2: pull ids the hub lacks/older

    def _on_canvas_put(self, payload: dict) -> None:
        """CANVAS_PUT → LWW → index persist → list refresh (NO UI switch)."""
        canvas = payload.get("canvas")
        if not isinstance(canvas, dict):
            logger.error("CANVAS_PUT canvas must be a document object: %r", canvas)
            return
        if payload.get("source") == "hub":
            return  # echo of our own broadcast — hub content, nothing to store
        try:
            doc = self._store.parse_document(canvas)
        except Exception:
            logger.exception("CANVAS_PUT document rejected")
            return
        canvas_id = str(doc.canvas_id)
        pending = self._pull_pending.pop(canvas_id, None)  # reply to our pull?
        source = pending[0] if pending else None
        if source is None:
            declared = payload.get("source")
            source = str(declared) if declared else "device"

        if self._index is not None:
            try:
                stored = self._index.save_document_if_newer(doc, source=source)
            except Exception:
                logger.exception("CANVAS_PUT persistence failed for %s", canvas_id)
                return
            if stored is None:
                logger.debug("CANVAS_PUT for %s kept the local copy (LWW)", canvas_id)
                return  # keep (equal) / reject (older): no churn, no emit
        else:
            local = self._local_rows.get(canvas_id)
            if local is not None and _updated(local) >= int(doc.updated_at):
                return  # no index: same LWW rule against the in-memory row
            self._local_rows[canvas_id] = _row_of(canvas)

        self._emit_list()
        self.broadcast_hub_list()  # §9.2: the hub store changed

    def _on_canvas_pull(self, payload: dict) -> None:
        """CANVAS_PULL → serve a CANVAS_PUT only when strictly newer (§9.1)."""
        canvas_id = payload.get("canvas_id")
        if not isinstance(canvas_id, str) or not canvas_id:
            logger.warning("CANVAS_PULL without canvas_id ignored: %r", payload)
            return
        try:
            have = int(payload.get("have_updated_at", 0))
        except (TypeError, ValueError):
            have = 0
        if self._index is None:
            return  # no hub storage — nothing to serve (sync no-op)
        doc = self._index.load(canvas_id)
        if doc is None or int(doc.updated_at) <= have:
            return  # missing or not newer → stay silent (§9.1)
        try:
            body = self._store.document_to_json(doc)
        except Exception:
            logger.exception("CANVAS_PULL serialize failed for %s", canvas_id)
            return
        try:
            self._push(
                self._envelope(
                    "CANVAS_LIFECYCLE",
                    "CANVAS_PUT",
                    {"canvas": body, "source": "hub"},
                    canvas_id=canvas_id,
                )
            )
        except Exception:
            logger.exception("CANVAS_PUT push failed")

    def _on_open_canvas(self, payload: dict) -> None:
        """OPEN_CANVAS {canvas}: persist-on-open happens inside
        ``store.open_payload`` (§9.3, BEFORE the switch), then the mirror
        loads; a store change is announced via the hub list."""
        if "canvas" not in payload:
            return  # path dialect is PC-internal only (§8.2)
        data = payload.get("canvas")
        if not isinstance(data, dict):
            logger.error("OPEN_CANVAS canvas dialect must carry an object: %r", data)
            return
        canvas_id = data.get("canvas_id")
        canvas_id = canvas_id if isinstance(canvas_id, str) and canvas_id else None
        before = self._index.get(canvas_id) if (self._index and canvas_id) else None
        try:
            self._store.open_payload(data)
        except Exception:
            logger.exception("OPEN_CANVAS (canvas dialect) failed")
            return
        if self._index is None:
            return
        after = self._index.get(canvas_id) if canvas_id else None
        if after != before:  # persist-on-open actually stored something (§9.2)
            self._emit_list()
            self.broadcast_hub_list()

    # ------------------------------------------------------------------
    # Merge, emission, pull drain (§9.4)
    # ------------------------------------------------------------------
    def _merged(self) -> list[dict]:
        """Union by id with LWW: index rows (or the in-memory hub rows) are
        the base; strictly-newer device rows displace them (§9.4)."""
        base: dict[str, dict] = {}
        if self._index is not None:
            try:
                base = {str(row["id"]): dict(row) for row in self._index.list()}
            except Exception:
                logger.exception("local canvas index unreadable; using in-memory rows")
        for source in (self._local_rows, self._device_rows):
            for canvas_id, row in source.items():
                current = base.get(canvas_id)
                if current is None or _updated(row) > _updated(current):
                    base[canvas_id] = dict(row)
        return sorted(base.values(), key=_updated, reverse=True)

    def _emit_list(self) -> None:
        """Frozen round-5 payload: ``{canvases, devices}`` (§9 / events.py)."""
        self._bus.emit(
            CANVAS_LIST_UPDATED, canvases=self._merged(), devices=self._connections
        )

    def _hub_list_payload(self) -> dict:
        payload: dict = {
            "device_id": self.hub_device_id,
            "origin": "hub",
            "canvases": self._merged(),
        }
        name = platform.node()
        if name:
            payload["device_name"] = name
        return payload

    def _local_row(self, canvas_id: str) -> dict | None:
        """The hub's stored copy: the index row when attached, else the
        in-memory row saved from received PUTs."""
        if self._index is not None:
            return self._index.get(canvas_id)
        return self._local_rows.get(canvas_id)

    def _plan_pulls(self, rows: list[dict], device_key: str) -> None:
        """§9.4 flow 2: queue CANVAS_PULL (one id per message) for ids the hub
        lacks or has an older updated_at, then drain sequentially."""
        needed: list[tuple[str, int]] = []
        for row in rows:
            canvas_id = row["id"]
            local = self._local_row(canvas_id)
            have = _updated(local) if local is not None else 0
            if local is None or have < _updated(row):
                needed.append((canvas_id, have))
        if not needed:
            return
        with self._lock:
            if self._stopped:
                return
            now = time.monotonic()
            for canvas_id, (_device, sent_at) in list(self._pull_pending.items()):
                if now - sent_at > _PULL_PENDING_TTL_S:
                    self._pull_pending.pop(canvas_id, None)
            queued = {item["canvas_id"] for item in self._pull_queue} | set(
                self._pull_pending
            )
            for canvas_id, have in needed:
                if canvas_id in queued:
                    continue
                queued.add(canvas_id)
                self._pull_queue.append(
                    {
                        "canvas_id": canvas_id,
                        "have_updated_at": have,
                        "device_id": device_key,
                    }
                )
        self._drain_pulls()

    def _drain_pulls(self) -> None:
        """Send queued CANVAS_PULLs sequentially: one per envelope, throttled
        to ``pull_interval_s`` apart (0 ⇒ drain synchronously in this call)."""
        while True:
            with self._lock:
                if self._stopped or not self._pull_queue:
                    return
                now = time.monotonic()
                if (
                    self._pull_interval_s > 0.0
                    and self._last_pull_at is not None
                    and now - self._last_pull_at < self._pull_interval_s
                ):
                    self._schedule_drain_locked()
                    return
                item = self._pull_queue.pop(0)
                self._last_pull_at = now
                self._pull_pending[item["canvas_id"]] = (item["device_id"], now)
            try:
                self._push(
                    self._envelope(
                        "CANVAS_LIFECYCLE",
                        "CANVAS_PULL",
                        {
                            "canvas_id": item["canvas_id"],
                            "have_updated_at": int(item["have_updated_at"]),
                        },
                    )
                )
            except Exception:  # never let a push failure poison the bus chain
                logger.exception("CANVAS_PULL push failed")
            if self._pull_interval_s > 0.0:
                with self._lock:
                    if self._pull_queue:
                        self._schedule_drain_locked()
                return

    def _schedule_drain_locked(self) -> None:
        """Arm one daemon timer for the next pull (caller holds ``_lock``)."""
        if self._pull_timer is not None and self._pull_timer.is_alive():
            return
        timer = threading.Timer(self._pull_interval_s, self._drain_pulls)
        timer.daemon = True
        self._pull_timer = timer
        timer.start()

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    @staticmethod
    def _envelope(msg_type: str, action: str, payload: dict, canvas_id: str = "") -> dict:
        """overview §4.2 shell — list/open-request envelopes use ``canvas_id: ""``;
        PUT replies carry the document's own id."""
        return {
            "id": str(uuid.uuid4()),
            "type": msg_type,
            "action": action,
            "canvas_id": canvas_id,
            "payload": payload,
            "timestamp": int(time.time()),
        }


def _updated(row: object) -> int:
    """LWW timestamp of a row (missing/corrupt ⇒ 0, so it always loses)."""
    if isinstance(row, dict):
        value = row.get("updated_at")
        if isinstance(value, bool):
            return 0
        try:
            return int(value)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            return 0
    return 0


def _row_of(body: dict) -> dict:
    """Index/CANVAS_LIST row from a serialized document body."""
    artboard = body.get("artboard")
    artboard = artboard if isinstance(artboard, dict) else {}
    return {
        "id": str(body.get("canvas_id") or ""),
        "title": str(body.get("title") or ""),
        "preset": str(artboard.get("preset") or ""),
        "background": str(artboard.get("background_style") or ""),
        "updated_at": _updated(body),
    }
