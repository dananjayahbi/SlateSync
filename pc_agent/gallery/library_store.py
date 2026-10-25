"""Bytes + metadata for the PC image library (Doc 02 §13.1).

:class:`LibraryStore` owns two things that must never disagree: the file for an
image and its row in :class:`GalleryIndex`. Everything that adds an image goes
through :meth:`add` / :meth:`save_canvas`, so a row cannot exist without its
bytes and bytes cannot land un-indexed.

Two decisions worth stating:

* **The image's pixel size is measured, not trusted.** ``GALLERY_ADD`` from a
  peer carries ``width``/``height``, but the artboard of an "open as canvas"
  document must equal the REAL pixel size, so the bytes are decoded and the
  authoritative values win. A sender that mismeasures a screenshot would
  otherwise produce a canvas whose artboard clips its own image.
* **The extension follows the bytes, not the filename.** A file called
  ``screenshot.png`` holding JPEG data is stored as ``.jpg``; the clipboard
  encoder and every viewer key off the extension.
"""

from __future__ import annotations

import io
import logging
import os
import time
from pathlib import Path
from typing import Any
from uuid import uuid4

from PIL import Image, UnidentifiedImageError

from pc_agent.gallery.gallery_index import (
    SOURCE_CANVAS,
    SOURCE_DROP,
    SOURCE_PASTE,
    GalleryIndex,
    default_gallery_dir,
    normalise_source,
)

logger = logging.getLogger("slatesync.gallery")

#: Save-back modes (Doc 02 §13.1 ``GALLERY_SAVE.mode``).
MODE_REPLACE = "REPLACE"
MODE_COPY = "COPY"
SAVE_MODES: tuple[str, ...] = (MODE_REPLACE, MODE_COPY)

#: Canonical extension + MIME per decoded PIL format. Anything else is stored as
#: PNG so a label never lies about bytes the viewer cannot open.
_FORMAT_BY_PIL = {
    "PNG": ("png", "image/png"),
    "JPEG": ("jpg", "image/jpeg"),
    "MPO": ("jpg", "image/jpeg"),
    "GIF": ("gif", "image/gif"),
    "BMP": ("bmp", "image/bmp"),
    "WEBP": ("webp", "image/webp"),
    "TIFF": ("tiff", "image/tiff"),
}

#: Formats kept byte-for-byte on disk: re-encoding them would change what the
#: user pasted for no gain, and PNG/JPEG are what every consumer expects.
_PASSTHROUGH_FORMATS = frozenset({"PNG", "JPEG", "MPO", "GIF", "BMP", "WEBP"})


def extension_for(mime: str | None, filename: str | None = None) -> str:
    """Storage extension for an image: MIME first, then the filename's suffix.

    Always returns something (``png`` last), so ``<image_id>.<ext>`` is a valid
    path for every row including a hand-edited one.
    """
    token = str(mime or "").strip().lower()
    known = {
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/gif": "gif",
        "image/bmp": "bmp",
        "image/webp": "webp",
        "image/tiff": "tiff",
    }
    if token in known:
        return known[token]
    suffix = Path(str(filename or "")).suffix.lower().lstrip(".")
    aliases = {"jpeg": "jpg"}
    suffix = aliases.get(suffix, suffix)
    if suffix in {"png", "jpg", "gif", "bmp", "webp", "tiff"}:
        return suffix
    return "png"


def inspect_image(data: bytes) -> tuple[str, str, int, int]:
    """Decode just enough to report ``(mime, extension, width, height)``.

    Raises :class:`ValueError` for bytes that are not a readable image: storing a
    row whose thumbnail can never render would put a permanently blank card in
    the window and an undecodable file behind every one of its buttons.
    """
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            pil_format = (image.format or "PNG").upper()
            width, height = image.size
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise ValueError(f"not a readable image: {exc}") from exc
    if width < 1 or height < 1:
        raise ValueError(f"image has no area: {width}x{height}")
    ext, mime = _FORMAT_BY_PIL.get(pil_format, ("png", "image/png"))
    return mime, ext, int(width), int(height)


def to_png_bytes(data: bytes) -> bytes:
    """Normalise exotic bytes (TIFF and friends) to PNG for the clipboard/web.

    Re-encoding only happens for formats the viewers and the clipboard cannot
    take directly, so a normal screenshot keeps the exact bytes the user pasted.
    """
    try:
        with Image.open(io.BytesIO(data)) as image:
            pil_format = (image.format or "PNG").upper()
            if pil_format in _PASSTHROUGH_FORMATS:
                return data
            buffer = io.BytesIO()
            image.convert("RGBA").save(buffer, format="PNG")
            return buffer.getvalue()
    except (UnidentifiedImageError, OSError, ValueError):
        return data  # callers validate first; a re-encode must never crash


def _now() -> int:
    return int(time.time())


def _safe_name(value: object, fallback: str) -> str:
    """Filesystem/UI-safe display name; never a path, never empty."""
    raw = str(value or "").replace("\\", "/")
    name = raw.rsplit("/", 1)[-1].replace("..", "").strip(" .")
    return name or fallback


def _text_or_empty(value: object) -> str:
    return value if isinstance(value, str) else ""


class LibraryStore:
    """The library's bytes, its index and the add/replace/copy rules."""

    def __init__(self, directory: Path | None = None, index: GalleryIndex | None = None) -> None:
        self._dir = Path(directory) if directory is not None else default_gallery_dir()
        self._index = index if index is not None else GalleryIndex(self._dir)

    @property
    def directory(self) -> Path:
        return self._dir

    @property
    def index(self) -> GalleryIndex:
        return self._index

    # ------------------------------------------------------------------ reads

    def list(self) -> list[dict]:
        """Rows newest first; rows whose file vanished are filtered out.

        A row without bytes is worse than a missing row: every action on its card
        would fail *after* the user clicked it. Filtering keeps the window honest
        without rewriting the index behind the user's back.
        """
        return [row for row in self._index.list() if self.path_for(row).is_file()]

    def get(self, image_id: str) -> dict | None:
        row = self._index.get(image_id)
        if row is None or not self.path_for(row).is_file():
            return None
        return row

    def path_for(self, row: dict) -> Path:
        """Stored file for ``row``; derived from the row, so it cannot drift."""
        image_id = str(row.get("image_id") or "")
        ext = extension_for(row.get("mime"), row.get("filename"))
        return self._dir / f"{image_id}.{ext}"

    def read_bytes(self, image_id: str) -> bytes | None:
        row = self.get(image_id)
        if row is None:
            return None
        try:
            return self.path_for(row).read_bytes()
        except OSError:
            logger.warning("gallery image %s unreadable", image_id, exc_info=True)
            return None

    # ----------------------------------------------------------------- writes

    def add(
        self,
        data: bytes,
        *,
        title: str | None = None,
        filename: str | None = None,
        source: str = SOURCE_PASTE,
        image_id: str | None = None,
        created_at: int | None = None,
    ) -> dict:
        """Store ``data`` as a library image and return its row.

        ``image_id`` is honoured when given because the tablet mints ids: it lets
        the sender correlate the ``ASSET_*`` transfer with the ``GALLERY_ADD``, and
        it makes re-adding the same id a replace rather than a duplicate.
        """
        mime, ext, width, height = inspect_image(data)
        payload = to_png_bytes(data)
        if payload is not data:
            # A re-encoded PNG is a different byte stream; measure it again so the
            # row always describes the file that is actually on disk.
            mime, ext, width, height = inspect_image(payload)
        if not image_id:
            image_id = str(uuid4())
        image_id = str(image_id).strip()
        if not image_id:
            raise ValueError("image_id must not be empty")

        name = _safe_name(filename, f"{image_id}.{ext}")
        now = _now()
        existing = self._index.get(image_id) or {}
        created = created_at if created_at is not None else existing.get("created_at")
        row = {
            "image_id": image_id,
            # Only an EXPLICIT filename may name the image: the fallback name is
            # derived from the id, so using it here would put a uuid in the grid.
            "title": _safe_title(title, _text_or_empty(filename), image_id),
            "width": width,
            "height": height,
            "source": normalise_source(source),
            "created_at": int(created or now),
            "updated_at": self._next_stamp(now, image_id),
            "mime": mime,
            "filename": name,
        }
        path = self.path_for(row)
        self._write_bytes(path, payload)
        # A previous copy under another extension (png -> jpg) would otherwise
        # linger as an orphan and win a later read.
        self._drop_other_extensions(image_id, keep=path)
        return self._index.put(row)

    def save_canvas(
        self,
        data: bytes,
        *,
        mode: str = MODE_COPY,
        image_id: str | None = None,
        title: str | None = None,
        filename: str | None = None,
    ) -> dict:
        """Upload a rendered canvas back into the library (Doc 02 §13.1).

        ``REPLACE`` keeps ``image_id`` so the library item becomes the new render
        and moves to the front on its ``updated_at``; ``COPY`` mints a fresh id and
        leaves the original untouched. Replace is destructive, so it only happens
        when explicitly requested — a missing or unknown mode is a copy.
        """
        token = str(mode or "").strip().upper()
        if token == MODE_REPLACE and image_id:
            return self.add(
                data,
                title=title,
                filename=filename,
                source=SOURCE_CANVAS,
                image_id=image_id,
            )
        return self.add(
            data,
            title=title,
            filename=filename,
            source=SOURCE_CANVAS,
            image_id=None,
        )

    def import_file(self, path: str | Path, *, source: str = SOURCE_DROP) -> dict:
        """Add a file from disk (drag-and-drop, or "Add from file…")."""
        source_path = Path(path)
        data = source_path.read_bytes()
        return self.add(
            data,
            title=source_path.stem,
            filename=source_path.name,
            source=source,
        )

    def remove(self, image_id: str) -> bool:
        """Delete bytes then the row; ``True`` when anything was removed."""
        row = self._index.get(image_id)
        removed_file = False
        if row is not None:
            try:
                self.path_for(row).unlink(missing_ok=True)
                removed_file = True
            except OSError:
                logger.warning("cannot delete gallery file for %s", image_id, exc_info=True)
        removed_row = self._index.remove(image_id)
        return removed_file or removed_row

    def save_as(self, image_id: str, destination: str | Path) -> Path:
        """Copy the stored bytes to ``destination`` ("Download" in the window)."""
        row = self.get(image_id)
        if row is None:
            raise FileNotFoundError(f"gallery image {image_id!r} not found")
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".tmp")
        try:
            tmp.write_bytes(self.path_for(row).read_bytes())
            os.replace(tmp, target)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise
        return target

    # ------------------------------------------------------------------- disk

    def _next_stamp(self, now: int, image_id: str) -> int:
        """A strictly increasing ``updated_at``, so "just added" really is first.

        Unix seconds are too coarse for a burst of pastes: two images stored in
        the same second would tie and the grid's newest-first order would fall back
        to an id comparison, putting the older image on top. Bumping past the
        current maximum keeps every new or replaced row at the front.
        """
        rows = self._index.list()
        highest = max((int(row.get("updated_at", 0) or 0) for row in rows), default=0)
        return max(int(now), highest + 1)

    def _write_bytes(self, path: Path, data: bytes) -> None:
        """Atomic write (``<name>.tmp`` → ``os.replace``); tmp removed on failure."""
        tmp = path.with_name(path.name + ".tmp")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_bytes(data)
            os.replace(tmp, path)
        except Exception:
            tmp.unlink(missing_ok=True)
            raise

    def _drop_other_extensions(self, image_id: str, *, keep: Path) -> None:
        for ext in ("png", "jpg", "gif", "bmp", "webp", "tiff"):
            candidate = self._dir / f"{image_id}.{ext}"
            if candidate == keep:
                continue
            try:
                candidate.unlink(missing_ok=True)
            except OSError:  # pragma: no cover - file held open by a viewer
                logger.debug("cannot remove stale %s", candidate, exc_info=True)

    # ----------------------------------------------------------------- helpers

    @staticmethod
    def row_for_wire(row: dict) -> dict[str, Any]:
        """The ``GALLERY_LIST.images[]`` shape (row keys, no extras)."""
        return {
            "image_id": str(row.get("image_id", "")),
            "title": str(row.get("title", "")),
            "width": int(row.get("width", 1) or 1),
            "height": int(row.get("height", 1) or 1),
            "source": normalise_source(row.get("source")),
            "created_at": int(row.get("created_at", 0) or 0),
            "updated_at": int(row.get("updated_at", 0) or 0),
            "mime": str(row.get("mime", "image/png")),
            "filename": str(row.get("filename", "")),
        }


def _safe_title(title: object, filename: str, image_id: str) -> str:
    """Display title: explicit → filename stem → short id.

    Better than showing a uuid in the grid when the user never named the image.
    """
    given = str(title or "").strip()
    if given:
        return given[:120]
    stem = Path(filename).stem.strip()
    if stem:
        return stem[:120]
    return image_id[:8]
