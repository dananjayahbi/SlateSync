"""JSON row index for the PC image library (mirrors ``LocalCanvasIndex``).

Layout: one file per image at ``<dir>/<image_id>.<ext>`` plus ``<dir>/index.json``
holding an array of rows. Two properties matter and both are deliberate:

* **atomic** — the file is written to ``index.json.tmp`` and moved with
  ``os.replace``, so a crash mid-write can never leave half a JSON document as
  the real index. A failed write unlinks the tmp file rather than leaving
  residue.
* **tolerant** — a missing, unreadable, corrupt or wrongly-shaped index reads as
  an EMPTY library. A user whose index was hand-edited (or truncated by a power
  cut) must still be able to open the agent and add images; refusing to start
  would be a worse failure than losing metadata for files that are still on
  disk.

Rows are kept as plain dicts on purpose: the wire payload (``GALLERY_LIST``) is
exactly the row shape, so no translation layer can drift from the contract.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from pathlib import Path

logger = logging.getLogger("slatesync.gallery")

SOURCE_PASTE = "PASTE"
SOURCE_DROP = "DROP"
SOURCE_CANVAS = "CANVAS"

#: Wire enum of ``source`` (Doc 02 §13.1). Anything else is coerced to PASTE.
SOURCES: tuple[str, ...] = (SOURCE_PASTE, SOURCE_DROP, SOURCE_CANVAS)

#: Row keys, in wire order (Doc 02 §13.1 ``GALLERY_LIST.images[]``).
ROW_KEYS: tuple[str, ...] = (
    "image_id",
    "title",
    "width",
    "height",
    "source",
    "created_at",
    "updated_at",
    "mime",
    "filename",
)

INDEX_FILENAME = "index.json"


def default_gallery_dir() -> Path:
    """``%APPDATA%/SlateSync/gallery`` — beside ``canvases/`` and ``thumbs/``.

    Deliberately not under the canvas assets folder: the library outlives any
    single canvas, and an image can be used by several documents at once.
    """
    return Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "gallery"


def normalise_source(value: object) -> str:
    """Coerce ``value`` onto the wire enum; unknown/missing becomes ``PASTE``.

    A foreign or hand-edited row must never make :class:`GalleryIndex` raise: the
    worst case is that the source is reported as the generic "pasted" one.
    """
    token = str(value or "").strip().upper()
    return token if token in SOURCES else SOURCE_PASTE


def sort_rows(rows: list[dict]) -> list[dict]:
    """Newest first by ``updated_at``, ties broken by ``image_id`` for stability.

    Stability matters: the window redraws on every ``GALLERY_CHANGED``, and an
    unstable order would make cards swap places under the user's cursor.
    """
    return sorted(
        rows,
        key=lambda row: (-int(row.get("updated_at", 0) or 0), str(row.get("image_id", ""))),
    )


def coerce_row(entry: object) -> dict | None:
    """Normalise one stored row; ``None`` when it cannot identify an image.

    Numeric fields are repaired rather than rejected (a string ``"640"`` is what
    a hand-edited index usually looks like), but a row without a usable
    ``image_id`` is dropped — it could never be fetched, copied or deleted.
    """
    if not isinstance(entry, dict):
        return None
    image_id = entry.get("image_id")
    if not isinstance(image_id, str) or not image_id.strip():
        return None
    row = dict(entry)
    row["image_id"] = image_id.strip()
    row["title"] = str(row.get("title") or row["image_id"])
    for key in ("width", "height"):
        row[key] = _positive_int(row.get(key))
    for key in ("created_at", "updated_at"):
        row[key] = _int_or_zero(row.get(key))
    row["source"] = normalise_source(row.get("source"))
    row["mime"] = str(row.get("mime") or "image/png")
    row["filename"] = str(row.get("filename") or row["image_id"])
    return row


def _positive_int(value: object) -> int:
    """``>= 1``; anything unusable becomes 1 (a 0-size image cannot be drawn)."""
    try:
        parsed = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 1
    return parsed if parsed >= 1 else 1


def _int_or_zero(value: object) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


class GalleryIndex:
    """CRUD over ``<dir>/index.json`` (one row per stored image)."""

    def __init__(self, directory: Path | None = None) -> None:
        self._dir = Path(directory) if directory is not None else default_gallery_dir()
        self._lock = threading.RLock()

    @property
    def directory(self) -> Path:
        return self._dir

    @property
    def index_path(self) -> Path:
        return self._dir / INDEX_FILENAME

    # ------------------------------------------------------------------ reads

    def list(self) -> list[dict]:
        """All rows, newest first. Copies, so a caller cannot mutate the store."""
        with self._lock:
            rows = list(self._read().values())
        return [dict(row) for row in sort_rows(rows)]

    def get(self, image_id: str) -> dict | None:
        with self._lock:
            row = self._read().get(str(image_id))
        return dict(row) if row is not None else None

    def count(self) -> int:
        with self._lock:
            return len(self._read())

    # ----------------------------------------------------------------- writes

    def put(self, row: dict) -> dict:
        """Upsert one row (``image_id`` is the key) and flush atomically."""
        coerced = coerce_row(row)
        if coerced is None:
            raise ValueError(f"gallery row needs an image_id: {row!r}")
        with self._lock:
            rows = self._read()
            rows[coerced["image_id"]] = coerced
            self._write(rows)
        return dict(coerced)

    def remove(self, image_id: str) -> bool:
        """Drop one row; ``True`` when a row was actually removed."""
        image_id = str(image_id)
        with self._lock:
            rows = self._read()
            if rows.pop(image_id, None) is None:
                return False
            self._write(rows)
        return True

    def replace_all(self, rows: list[dict]) -> None:
        """Rewrite the whole index (used by a full resync from the tablet)."""
        collected: dict[str, dict] = {}
        for row in rows:
            coerced = coerce_row(row)
            if coerced is not None:
                collected[coerced["image_id"]] = coerced
        with self._lock:
            self._write(collected)

    # ------------------------------------------------------------------- disk

    def _read(self) -> dict[str, dict]:
        """``image_id -> row``; every failure mode degrades to an empty index."""
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
            # A corrupt index is recoverable by re-adding images; refusing to
            # start is not. Log loudly so the cause is diagnosable.
            logger.warning("corrupted %s (%s); treating as empty", self.index_path, exc)
            return {}
        if not isinstance(data, list):
            logger.warning(
                "%s: expected a JSON array of rows; treating as empty", self.index_path
            )
            return {}
        rows: dict[str, dict] = {}
        for entry in data:
            coerced = coerce_row(entry)
            if coerced is not None:
                rows[coerced["image_id"]] = coerced
        return rows

    def _write(self, rows: dict[str, dict]) -> None:
        """Atomic flush: write ``index.json.tmp`` then ``os.replace``.

        An exception unlinks the tmp file and re-raises so a caller can report
        the failure; the previous index on disk is never damaged.
        """
        path = self.index_path
        tmp = Path(str(path) + ".tmp")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            text = json.dumps(sort_rows(list(rows.values())), ensure_ascii=False, indent=2)
            tmp.write_text(text + "\n", encoding="utf-8")
            os.replace(tmp, path)
        except Exception:
            tmp.unlink(missing_ok=True)
            logger.exception("gallery index flush to %s failed; original untouched", path)
            raise
