"""Image library ⇄ tablet sync for the PC agent (Doc 02 §13.1).

Wire shape, in one place:

* the tablet asks with ``GALLERY_LIST_REQUEST {}`` → this module answers
  ``GALLERY_LIST {images: [...]}`` (newest first);
* the tablet registers an image with ``GALLERY_ADD`` and saves a canvas with
  ``GALLERY_SAVE``; both carry only metadata because the BYTES arrive through the
  existing ``ASSET_START``/``ASSET_CHUNK``/``ASSET_DONE`` transfer, keyed by the
  image's ``image_id`` as ``transfer_id``.

**The transfer has to be captured, not ignored.** ``DocumentStore`` claims every
``ASSET_*`` envelope for the open canvas's asset folder, which is the right place
for canvas images but the wrong place for a library upload. So this module
subscribes FIRST (the store is constructed later in ``main.py``), buffers the
chunks for a ``transfer_id`` that a ``GALLERY_ADD``/``GALLERY_SAVE`` announced,
and commits the library row on ``ASSET_DONE``. Transfers it does not recognise are
left untouched for the other handler: the two consumers are distinguished by
declared intent, never by guessing from a filename.

Threading: envelopes arrive on the WebSocket thread. All store access is
serialised by an internal lock, and the only Tk interaction is a bus event, so
nothing here touches widgets.
"""

from __future__ import annotations

import base64
import binascii
import logging
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable
from uuid import uuid4

from pc_agent.core.events import RPC_MESSAGE, EventBus
from pc_agent.gallery.events import GALLERY_CHANGED, REASON_ADDED, REASON_SAVED
from pc_agent.gallery.library_store import MODE_COPY, LibraryStore

logger = logging.getLogger("slatesync.gallery.sync")

#: Template §3 chunk cap in raw bytes; a chunk above it is a protocol violation.
CHUNK_RAW = 262144

#: How long an announced upload may sit incomplete before it is forgotten. A
#: stalled transfer must not pin memory for the rest of the session.
TRANSFER_TTL_S = 120.0

#: Bound on concurrently buffered uploads, so a hostile/buggy peer cannot grow
#: memory without limit.
MAX_PENDING_TRANSFERS = 8

INCOMING = "incoming"
OUTGOING = "outgoing"


class _Transfer:
    """One chunked upload (or download) keyed by ``transfer_id``."""

    __slots__ = ("filename", "total_chunks", "size_bytes", "chunks", "started_at", "meta")

    def __init__(
        self,
        filename: str,
        total_chunks: int,
        size_bytes: int,
        started_at: float,
        meta: dict | None = None,
    ) -> None:
        self.filename = filename
        self.total_chunks = total_chunks
        self.size_bytes = size_bytes
        self.chunks: list[bytes | None] = [None] * max(total_chunks, 0)
        self.started_at = started_at
        self.meta: dict = dict(meta or {})

    @property
    def complete(self) -> bool:
        return bool(self.chunks) and all(chunk is not None for chunk in self.chunks)

    def assemble(self) -> bytes | None:
        if not self.complete:
            return None
        data = b"".join(chunk for chunk in self.chunks if chunk is not None)
        return data if len(data) == self.size_bytes else None


class GallerySync:
    """``GALLERY_*`` RPC handling + the ``ASSET_*`` capture for library uploads."""

    def __init__(
        self,
        bus: EventBus,
        store: LibraryStore,
        *,
        push: Callable[[dict], None],
        gallery_dir: Path | None = None,
    ) -> None:
        self._bus = bus
        self._store = store
        self._push = push
        self._dir = Path(gallery_dir) if gallery_dir is not None else store.directory
        self._lock = threading.RLock()
        #: Declared-but-unfinished uploads, in arrival order (bounded, see TTL).
        self._pending: "OrderedDict[str, _Transfer]" = OrderedDict()
        #: Chunks seen before their declaration arrived; adopted on GALLERY_*.
        self._orphans: dict[str, dict[int, bytes]] = {}
        self._started = False
        self.attach()

    # ---------------------------------------------------------------- lifecycle

    def attach(self) -> None:
        """Subscribe to the bus (idempotent; ``detach`` is symmetric)."""
        if self._started:
            return
        self._started = True
        self._bus.on(RPC_MESSAGE, self._on_rpc)
        # The PC window emits GALLERY_CHANGED for its own paste/drop/delete, so
        # subscribing here is what makes "added on the PC, visible on the tablet"
        # true without the window knowing anything about the network.
        self._bus.on(GALLERY_CHANGED, self._on_gallery_changed)

    def detach(self) -> None:
        if not self._started:
            return
        self._started = False
        self._bus.off(RPC_MESSAGE, self._on_rpc)
        self._bus.off(GALLERY_CHANGED, self._on_gallery_changed)

    def shutdown(self) -> None:
        """Drop in-flight transfers; the library rows already committed stay."""
        self.detach()
        with self._lock:
            self._pending.clear()
            self._orphans.clear()

    # ------------------------------------------------------------------- bus

    def _on_rpc(self, msg: dict | None = None, **_extra: object) -> None:
        """``RPC_MESSAGE`` handler. The server emits ``msg=``, so the keyword is
        part of the contract — reading a different name silently no-ops."""
        if not isinstance(msg, dict):
            return
        envelope_type = msg.get("type")
        action = msg.get("action")
        payload = msg.get("payload")
        if envelope_type == "ASSET_UPLOAD":
            if isinstance(payload, dict):
                self._on_asset(str(action or ""), payload)
            return
        if envelope_type != "GALLERY" or not isinstance(payload, dict):
            return
        if action == "GALLERY_LIST_REQUEST":
            self.push_list()
        elif action == "GALLERY_ADD":
            self._on_add(payload)
        elif action == "GALLERY_SAVE":
            self._on_save(payload)
        else:
            logger.debug("GALLERY action %r ignored (no PC handler)", action)

    # --------------------------------------------------------- outbound pushes

    def list_payload(self) -> dict:
        """``{images: [...]}`` newest first (the only GALLERY_LIST shape)."""
        rows = [LibraryStore.row_for_wire(row) for row in self._store.list()]
        return {"images": rows}

    def push_list(self) -> None:
        """Send ``GALLERY_LIST`` to every device. Never raises."""
        try:
            self._push(self._envelope("GALLERY_LIST", self.list_payload()))
        except Exception:  # pragma: no cover - transport failure is not fatal
            logger.warning("gallery: pushing GALLERY_LIST failed", exc_info=True)

    def _on_gallery_changed(self, reason: object = None, image_id: object = None,
                            **_extra: object) -> None:
        """Any library change (local or remote) converges both sides' indexes."""
        self.push_list()

    @staticmethod
    def _envelope(action: str, payload: dict, image_id: str = "") -> dict:
        return {
            "id": str(uuid4()),
            "type": "GALLERY",
            "action": action,
            # Library messages are app-wide, so the canvas_id is the empty string
            # the schema already uses for such envelopes (cf. CANVAS_LIST).
            "canvas_id": image_id,
            "payload": payload,
            "timestamp": int(time.time()),
        }

    # ------------------------------------------------------------ inbound adds

    def _on_add(self, payload: dict) -> None:
        """Declare (or immediately satisfy) a library upload.

        Declaring first is what lets the ``ASSET_*`` stream be claimed for the
        library instead of the open canvas: by the time its ``ASSET_START``
        arrives, the ``transfer_id`` is already known to belong here.
        """
        image_id = _text(payload.get("image_id"))
        if not image_id:
            logger.warning("GALLERY_ADD without image_id ignored: %r", payload)
            return
        self._announce(image_id, payload, mode=MODE_COPY, reason=REASON_ADDED)
        inline = payload.get("bytes_b64")
        if isinstance(inline, str) and inline:
            data = _decode_b64(inline)
            if data is not None:
                self._commit(image_id, data, payload, reason=REASON_ADDED)

    def _on_save(self, payload: dict) -> None:
        """Declare a canvas save-back; ``mode`` decides replace vs copy."""
        image_id = _text(payload.get("image_id")) or str(uuid4())
        self._announce(image_id, payload, mode=_text(payload.get("mode")).upper(),
                        reason=REASON_SAVED)
        inline = payload.get("bytes_b64")
        if isinstance(inline, str) and inline:
            data = _decode_b64(inline)
            if data is not None:
                self._commit(image_id, data, payload, reason=REASON_SAVED)

    def _announce(self, transfer_id: str, payload: dict, *, mode: str, reason: str) -> None:
        """Remember what a transfer_id is FOR before its chunks arrive."""
        filename = _text(payload.get("filename")) or f"{transfer_id}.png"
        with self._lock:
            self._expire_locked()
            existing = self._pending.get(transfer_id)
            if existing is not None and existing.meta.get("mode") == mode:
                # A re-sent GALLERY_ADD keeps its buffered chunks: retries are
                # common on a flaky link and discarding progress wastes them.
                existing.meta["payload"] = dict(payload)
                existing.meta["reason"] = reason
            else:
                transfer = _Transfer(
                    filename=filename,
                    total_chunks=0,
                    size_bytes=0,
                    started_at=time.monotonic(),
                    meta={"mode": mode, "payload": dict(payload), "reason": reason},
                )
                self._pending[transfer_id] = transfer
                self._trim_locked()
            orphan = self._orphans.pop(transfer_id, None)
        if orphan and transfer_id in self._pending:
            for index, chunk in sorted(orphan.items()):
                self._store_chunk(transfer_id, index, chunk)
            # A full set of orphan chunks can already complete the upload.
            self._try_commit(transfer_id)

    # -------------------------------------------------------- asset transfer

    def _on_asset(self, action: str, payload: dict) -> None:
        transfer_id = _text(payload.get("transfer_id"))
        if not transfer_id:
            return
        if action == "ASSET_START":
            self._on_asset_start(transfer_id, payload)
        elif action == "ASSET_CHUNK":
            self._on_asset_chunk(transfer_id, payload)
        elif action == "ASSET_DONE":
            self._on_asset_done(transfer_id, payload)

    def _on_asset_start(self, transfer_id: str, payload: dict) -> None:
        with self._lock:
            transfer = self._pending.get(transfer_id)
            if transfer is None:
                # Declared AFTER the bytes started (possible if the tablet is
                # pipelining): keep the header now and let _announce adopt it.
                self._pending[transfer_id] = _Transfer(
                    filename=_text(payload.get("filename")) or f"{transfer_id}.png",
                    total_chunks=_int(payload.get("total_chunks")),
                    size_bytes=_int(payload.get("size_bytes")),
                    started_at=time.monotonic(),
                    meta={},
                )
                self._trim_locked()
                return
            # The transfer_id was declared as a library upload, so THIS header is
            # authoritative for chunk count/size.
            transfer.filename = _text(payload.get("filename")) or transfer.filename
            transfer.total_chunks = _int(payload.get("total_chunks"))
            transfer.size_bytes = _int(payload.get("size_bytes"))
            if len(transfer.chunks) != transfer.total_chunks:
                transfer.chunks = [None] * max(transfer.total_chunks, 0)

    def _on_asset_chunk(self, transfer_id: str, payload: dict) -> None:
        index = _int(payload.get("index"), default=-1)
        data = payload.get("data_b64")
        if index < 0 or not isinstance(data, str):
            return
        raw = _decode_b64(data)
        if raw is None or len(raw) > CHUNK_RAW:
            self._drop(transfer_id, f"chunk {index} rejected ({len(raw or b'')} bytes)")
            return
        with self._lock:
            known = transfer_id in self._pending
        if not known:
            # Not a library transfer (yet): remember the chunk briefly in case the
            # declaration is still in flight, so pipelined uploads are not lost.
            with self._lock:
                bucket = self._orphans.setdefault(transfer_id, {})
                bucket[index] = raw
                if len(self._orphans) > MAX_PENDING_TRANSFERS:
                    self._orphans.pop(next(iter(self._orphans)), None)
            return
        self._store_chunk(transfer_id, index, raw)

    def _store_chunk(self, transfer_id: str, index: int, raw: bytes) -> None:
        with self._lock:
            transfer = self._pending.get(transfer_id)
            if transfer is None:
                return
            if transfer.total_chunks <= 0:
                # No START yet: grow to fit, keeping earlier chunks.
                needed = index + 1
                if needed > len(transfer.chunks):
                    transfer.chunks.extend([None] * (needed - len(transfer.chunks)))
            elif index >= transfer.total_chunks:
                return
            transfer.chunks[index] = raw

    def _on_asset_done(self, transfer_id: str, payload: dict) -> None:
        if payload.get("ok") is False:
            self._drop(transfer_id, "sender aborted the transfer")
            return
        self._try_commit(transfer_id)

    def _try_commit(self, transfer_id: str) -> None:
        with self._lock:
            transfer = self._pending.get(transfer_id)
            if transfer is None or not transfer.meta:
                return  # not a library upload, or not declared yet
            data = transfer.assemble()
            if data is None:
                return  # still waiting on chunks
            self._pending.pop(transfer_id, None)
            payload = dict(transfer.meta.get("payload") or {})
            reason = str(transfer.meta.get("reason") or REASON_ADDED)
            filename = transfer.filename
        payload.setdefault("filename", filename)
        self._commit(transfer_id, data, payload, reason=reason)

    # --------------------------------------------------------------- commits

    def _commit(self, image_id: str, data: bytes, payload: dict, *, reason: str) -> dict | None:
        """Write the library row (the only place bytes reach the disk)."""
        try:
            if reason == REASON_SAVED:
                row = self._store.save_canvas(
                    data,
                    mode=_text(payload.get("mode")) or MODE_COPY,
                    image_id=image_id,
                    title=_text(payload.get("title")) or None,
                    filename=_text(payload.get("filename")) or None,
                )
            else:
                row = self._store.add(
                    data,
                    title=_text(payload.get("title")) or None,
                    filename=_text(payload.get("filename")) or None,
                    source=_text(payload.get("source")) or None,
                    image_id=image_id,
                )
        except (ValueError, OSError) as exc:
            logger.warning("gallery: rejecting image %s (%s)", image_id, exc)
            return None
        self._bus.emit(GALLERY_CHANGED, reason=reason, image_id=row.get("image_id"))
        # No direct push: the GALLERY_CHANGED subscription above broadcasts the
        # refreshed index, so local and remote changes share one code path.
        return row

    def _drop(self, transfer_id: str, reason: str) -> None:
        with self._lock:
            existed = self._pending.pop(transfer_id, None) is not None
            self._orphans.pop(transfer_id, None)
        if existed:
            logger.warning("gallery upload %r discarded: %s", transfer_id, reason)

    # -------------------------------------------------------------- housekeep

    def _expire_locked(self) -> None:
        now = time.monotonic()
        stale = [
            key
            for key, transfer in self._pending.items()
            if now - transfer.started_at > TRANSFER_TTL_S
        ]
        for key in stale:
            self._pending.pop(key, None)
            logger.warning("gallery upload %r expired before completing", key)

    def _trim_locked(self) -> None:
        while len(self._pending) > MAX_PENDING_TRANSFERS:
            evicted, _transfer = self._pending.popitem(last=False)
            logger.warning("gallery upload %r evicted (too many in flight)", evicted)

    # ------------------------------------------------------------- test hooks

    @property
    def pending_transfers(self) -> list[str]:
        """Declared, unfinished upload ids (diagnostics + tests)."""
        with self._lock:
            return list(self._pending)

    def meta_for(self, transfer_id: str) -> dict:
        with self._lock:
            transfer = self._pending.get(transfer_id)
            return dict(transfer.meta) if transfer is not None else {}

    def knows(self, transfer_id: str) -> bool:
        """True when this module has claimed ``transfer_id`` for the library."""
        with self._lock:
            return transfer_id in self._pending or transfer_id in self._orphans


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _int(value: Any, *, default: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    parsed = int(value)
    return parsed if parsed >= 0 else default


def _decode_b64(value: str) -> bytes | None:
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, TypeError, ValueError):
        return None


__all__ = [
    "CHUNK_RAW",
    "GallerySync",
    "INCOMING",
    "MAX_PENDING_TRANSFERS",
    "OUTGOING",
    "TRANSFER_TTL_S",
]
