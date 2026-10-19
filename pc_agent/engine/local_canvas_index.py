"""PC hub canvas storage (Doc 02 §9.3) — ``%APPDATA%/SlateSync/canvases``.

``LocalCanvasIndex`` owns the round-5 hub persistence layout:

* ``<dir>/<canvas_id>.slatesync`` — the document archive. ZIP I/O is fully
  delegated to the injected ``DocumentStore`` (``write_archive`` /
  ``read_archive`` / ``parse_document``) — no duplicate ZIP logic here.
* ``<dir>/index.json`` — a JSON array of rows
  ``{id, title, preset, background, updated_at, source_devices[]}``,
  written atomically (``index.json.tmp`` → ``os.replace``; a failure unlinks
  the tmp file so no ``.tmp`` residue remains).

LWW (§9.1) is expressed by :meth:`lww_decision` — ``apply`` for a strictly
newer or unknown copy, ``keep`` for ``updated_at`` equality (keep local, no
churn) and ``reject`` for older copies; :meth:`save_document_if_newer`
applies that guard before any disk write.

Locking: the index never calls the store while holding its own lock, so the
lock order is always ``DocumentStore._lock`` → ``LocalCanvasIndex._lock``
and cannot invert.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # runtime import-free: the index only duck-types the store
    from pc_agent.engine.document_store import CanvasDocument, DocumentStore

logger = logging.getLogger("slatesync.index")

#: §9.3 row keys of index.json (extra keys are tolerated and preserved).
ROW_KEYS = ("id", "title", "preset", "background", "updated_at", "source_devices")

#: LWW guard outcomes (Doc 02 §9.1).
LWW_APPLY = "apply"  # newer (or unknown) → store the incoming copy
LWW_KEEP = "keep"  # equal updated_at → keep local, no churn
LWW_REJECT = "reject"  # older → discard the incoming copy


def _default_directory() -> Path:
    """``%APPDATA%/SlateSync/canvases`` (Doc 02 §9.3), matching AppConfig."""
    return Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "canvases"


class LocalCanvasIndex:
    """CRUD over the hub's canvas dir + ``index.json`` (see module doc)."""

    def __init__(self, store: DocumentStore, directory: Path | None = None) -> None:
        self._store = store
        self._dir = Path(directory) if directory is not None else _default_directory()
        self._lock = threading.RLock()

    # ------------------------------------------------------------------
    # Layout
    # ------------------------------------------------------------------
    @property
    def directory(self) -> Path:
        """Hub canvases directory (created lazily on first save)."""
        return self._dir

    @property
    def index_path(self) -> Path:
        return self._dir / "index.json"

    def archive_path(self, canvas_id: str) -> Path:
        return self._dir / f"{canvas_id}.slatesync"

    # ------------------------------------------------------------------
    # index.json CRUD
    # ------------------------------------------------------------------
    def list(self) -> list[dict]:
        """All rows, sorted ``updated_at`` DESC (copies; empty when absent)."""
        with self._lock:
            rows = list(self._read().values())
        rows.sort(key=lambda row: int(row.get("updated_at", 0) or 0), reverse=True)
        return rows

    def get(self, canvas_id: str) -> dict | None:
        """One row by id, or None (missing/corrupt index tolerated)."""
        with self._lock:
            row = self._read().get(str(canvas_id))
        return dict(row) if row is not None else None

    def save_document(self, doc: CanvasDocument, source: str | None = None) -> Path:
        """Persist the archive via the store, then upsert the row atomically.

        The archive is written WITHOUT stamping ``updated_at``, splicing the
        open scene or touching the store's current-document state — the
        document's own LWW timestamp stays authoritative (§9.1). ``source``
        (a device id, or ``"hub"``/``"device"``) is unioned into the row's
        ``source_devices``.
        """
        canvas_id = str(doc.canvas_id)
        path = self.archive_path(canvas_id)
        self._dir.mkdir(parents=True, exist_ok=True)
        # Lock order (store → index): the store write happens WITHOUT the
        # index lock held, exactly like DocumentStore._refresh_index_row.
        self._store.write_archive(
            doc, path, stamp_updated=False, sync_scene=False, focus=False
        )
        with self._lock:
            rows = self._read()
            existing = rows.get(canvas_id, {})
            sources = [str(s) for s in (existing.get("source_devices") or [])]
            if source is not None and str(source) and str(source) not in sources:
                sources.append(str(source))
            rows[canvas_id] = self._row(doc, sources)
            self._write(rows)
        return path

    def save_document_if_newer(
        self, doc: CanvasDocument, source: str | None = None
    ) -> Path | None:
        """LWW-guarded :meth:`save_document` (§9.1): store only when the
        incoming copy wins (``apply``); ``keep``/``reject`` return None."""
        if self.lww_decision(str(doc.canvas_id), int(doc.updated_at)) is not LWW_APPLY:
            return None
        return self.save_document(doc, source=source)

    def refresh_row(self, doc: CanvasDocument) -> dict:
        """Upsert ONLY the row (the store already wrote the archive) — used
        by DocumentStore after focused saves so index.json never drifts from
        the ZIP it describes. ``source_devices`` of an existing row survive."""
        canvas_id = str(doc.canvas_id)
        with self._lock:
            rows = self._read()
            sources = [str(s) for s in (rows.get(canvas_id, {}).get("source_devices") or [])]
            row = self._row(doc, sources)
            rows[canvas_id] = row
            self._write(rows)
        return dict(row)

    def load(self, canvas_id: str) -> CanvasDocument | None:
        """Read the archive through the store (side-effect free — never emits
        DOCUMENT_LOADED or switches the open document). Missing → None."""
        path = self.archive_path(str(canvas_id))
        if not path.is_file():
            return None
        try:
            return self._store.read_archive(path)
        except FileNotFoundError:
            return None
        except Exception:
            logger.exception("cannot load %s", path)
            return None

    def remove(self, canvas_id: str) -> bool:
        """Delete archive + row atomically-ish; True when anything was removed."""
        canvas_id = str(canvas_id)
        path = self.archive_path(canvas_id)
        with self._lock:
            rows = self._read()
            row_present = rows.pop(canvas_id, None) is not None
            zip_present = path.is_file()
            if zip_present:
                path.unlink(missing_ok=True)
            if row_present:
                self._write(rows)
        return zip_present or row_present

    # ------------------------------------------------------------------
    # LWW guard (§9.1)
    # ------------------------------------------------------------------
    def lww_decision(self, canvas_id: str, incoming_updated_at: int) -> str:
        """Classify an incoming copy against the stored row.

        Unknown id → ``apply``; strictly newer → ``apply``; equal → ``keep``
        (keep local, no churn); older → ``reject``.
        """
        row = self.get(canvas_id)
        if row is None:
            return LWW_APPLY
        try:
            local = int(row.get("updated_at", 0))
        except (TypeError, ValueError):
            local = 0
        try:
            incoming = int(incoming_updated_at)
        except (TypeError, ValueError):
            incoming = 0
        if incoming > local:
            return LWW_APPLY
        if incoming == local:
            return LWW_KEEP
        return LWW_REJECT

    # ------------------------------------------------------------------
    # index.json I/O (atomic)
    # ------------------------------------------------------------------
    def _read(self) -> dict[str, dict]:
        """id → row; missing/corrupt/unusable index degrades to {} (never raises)."""
        try:
            raw = self.index_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return {}
        except OSError as exc:
            logger.warning("cannot read %s (%s); treating as empty", self.index_path, exc)
            return {}
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            logger.warning("corrupted %s (%s); treating as empty", self.index_path, exc)
            return {}
        if not isinstance(data, list):
            logger.warning("%s: expected a JSON array of rows; treating as empty", self.index_path)
            return {}
        rows: dict[str, dict] = {}
        for entry in data:
            if not isinstance(entry, dict):
                continue
            canvas_id = entry.get("id")
            if not isinstance(canvas_id, str) or not canvas_id:
                continue
            rows[canvas_id] = dict(entry)
        return rows

    def _write(self, rows: dict[str, dict]) -> None:
        """Atomic row flush; failure removes the tmp file (no .tmp residue)."""
        path = self.index_path
        tmp = Path(str(path) + ".tmp")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            text = json.dumps(list(rows.values()), ensure_ascii=False, indent=2)
            tmp.write_text(text + "\n", encoding="utf-8")
            os.replace(tmp, path)
        except Exception:
            tmp.unlink(missing_ok=True)
            logger.exception("index flush to %s failed; original untouched", path)
            raise

    @staticmethod
    def _row(doc: CanvasDocument, sources: list[str]) -> dict:
        return {
            "id": str(doc.canvas_id),
            "title": str(doc.title),
            "preset": str(doc.artboard.preset),
            "background": str(doc.artboard.background_style),
            "updated_at": int(doc.updated_at),
            "source_devices": list(sources),
        }
