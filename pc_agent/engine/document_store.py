"""Canvas persistence store (Doc 10) — atomic ``.slatesync`` archives.

Freeze source: ``docs/micro/10_pc_canvas_persistence_store.md`` §4 and
``docs/_micro_doc_template.md`` §4. A ``.slatesync`` file is a ZIP of
``document.json`` (Doc 03 schema, ``ensure_ascii=False``) plus ``assets/*``.
Saves go through ``<path>.tmp`` → ``os.replace`` so a failure leaves the
previous archive untouched and no ``.tmp`` residue.

Round 5 (Doc 02 §9.3) extensions: :meth:`attach_index` binds the
``LocalCanvasIndex`` (the index is constructed with this store for ZIP I/O,
then attached — no import cycle), ``open_payload`` persists wire documents
into that index BEFORE switching the UI (persist-on-open, LWW per §9.1), and
focused saves refresh the matching ``index.json`` row so the hub store never
drifts from its archives.
"""

from __future__ import annotations

import base64
import binascii
import json
import logging
import os
import threading
import time
import uuid
import zipfile
from dataclasses import dataclass, replace
from pathlib import Path

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    COMMITTED_NODE,
    DOCUMENT_LOADED,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle, SceneGraph

logger = logging.getLogger("slatesync.store")

#: §3 artboard preset table (300-DPI world units); INFINITE keeps width/height None.
_PRESETS: dict[str, tuple[float | None, float | None]] = {
    "A5": (1748.0, 2480.0),
    "A4": (2480.0, 3508.0),
    "LETTER": (2550.0, 3300.0),
    "INFINITE": (None, None),
}

#: Template §3: base64 chunk cap in raw bytes per ASSET_CHUNK.
_MAX_CHUNK_RAW = 262144

_ZERO_BOUNDS: dict[str, float] = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
_BOUND_KEYS = ("min_x", "min_y", "max_x", "max_y")
_STYLE_KEYS = ("color", "stroke_width", "opacity", "blend_mode")
_GEOM_KEYS = ("pts", "shape_type", "graph_config", "asset_ref")


@dataclass
class Artboard:
    preset: str  # A5|A4|LETTER|INFINITE
    width: float | None = None
    height: float | None = None
    is_infinite: bool = False
    background_style: str = "BLANK"
    background_color: str = "#FFFFFF"


@dataclass
class CanvasDocument:
    canvas_id: str
    title: str
    created_at: int
    updated_at: int
    artboard: Artboard
    content_bounds: dict[str, float]
    elements: list[CanvasNode]


@dataclass
class _Transfer:
    """Buffered ASSET_UPLOAD flow: fixed slot per chunk index (out-of-order OK)."""

    filename: str
    total_chunks: int
    size_bytes: int
    chunks: list[bytes | None]


def _artboard_to_json(artboard: Artboard) -> dict:
    return {
        "preset": artboard.preset,
        "width": artboard.width,
        "height": artboard.height,
        "is_infinite": artboard.is_infinite,
        "background_style": artboard.background_style,
        "background_color": artboard.background_color,
    }


def _coerce_bool(value: object, field: str) -> bool:
    """Doc 03 boolean with legacy-string tolerance.

    Real booleans and 0/1 numbers keep their old truthiness; the string forms
    ``"true"/"false"/"1"/"0"/"yes"/"no"`` (any case, trimmed) map explicitly —
    a naive ``bool("false")`` is ``True`` and would silently flip a bounded
    artboard onto the content-derived extent path (§10.4 issue 06).  Anything
    else violates the Doc 03 schema and is rejected.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        token = value.strip().lower()
        if token in ("true", "1", "yes"):
            return True
        if token in ("false", "0", "no", ""):
            return False
    raise ValueError(f"{field} must be a boolean, got {value!r}")


def _artboard_from_json(data: dict) -> Artboard:
    preset = data["preset"]
    width = data.get("width")
    height = data.get("height")
    is_infinite = _coerce_bool(data.get("is_infinite", False), "artboard.is_infinite")
    if preset in _PRESETS:
        # §10.4 (issue 06): the preset table is normative end-to-end.  Bounded
        # presets always carry their exact artboard dims (backfilled when a
        # sender dropped them) with ``is_infinite=False``; INFINITE always has
        # null dims with ``is_infinite=True`` — a stale or mistyped flag can
        # never send a bounded preset down the content-extent path.
        if preset == "INFINITE":
            width, height, is_infinite = None, None, True
        else:
            table_w, table_h = _PRESETS[preset]
            if width is None:
                width = table_w
            if height is None:
                height = table_h
            is_infinite = False
    return Artboard(
        preset=preset,
        width=width,
        height=height,
        is_infinite=is_infinite,
        background_style=data.get("background_style", "BLANK"),
        background_color=data.get("background_color", "#FFFFFF"),
    )


def artboard_is_infinite(artboard: Artboard) -> bool:
    """§10.4 boundedness rule used by the exporters and thumbnail renderer.

    Known presets decide by table: ``A5/A4/LETTER`` are ALWAYS bounded (their
    ``is_infinite`` flag is advisory) and ``INFINITE`` is always unbounded;
    only an unknown preset string falls back to the raw flag.
    """
    if artboard.preset in _PRESETS:
        return artboard.preset == "INFINITE"
    return bool(artboard.is_infinite)


def _style_to_json(style: NodeStyle) -> dict:
    return {
        "color": style.color,
        "stroke_width": style.stroke_width,
        "opacity": style.opacity,
        "blend_mode": style.blend_mode,
    }


def _style_from_json(data: dict | None) -> NodeStyle:
    data = data or {}
    return NodeStyle(**{k: data[k] for k in _STYLE_KEYS if k in data})


def _geometry_to_json(geometry: NodeGeometry) -> dict:
    return {
        "pts": geometry.pts,
        "shape_type": geometry.shape_type,
        "graph_config": geometry.graph_config,
        "asset_ref": geometry.asset_ref,
    }


def _geometry_from_json(data: dict | None) -> NodeGeometry:
    data = data or {}
    return NodeGeometry(**{k: data[k] for k in _GEOM_KEYS if k in data})


def _node_to_json(node: CanvasNode) -> dict:
    return {
        "node_id": node.node_id,
        "kind": node.kind,
        "layer": node.layer,
        "bbox": [float(v) for v in node.bbox],
        "style": _style_to_json(node.style),
        "geometry": _geometry_to_json(node.geometry),
    }


def _node_from_json(data: dict) -> CanvasNode:
    bbox = tuple(float(v) for v in data["bbox"])
    if len(bbox) != 4:
        raise ValueError(f"bbox must have 4 numbers, got {data['bbox']!r}")
    return CanvasNode(
        node_id=data["node_id"],
        kind=data["kind"],
        layer=int(data.get("layer", 0)),
        bbox=bbox,  # type: ignore[arg-type]
        style=_style_from_json(data.get("style")),
        geometry=_geometry_from_json(data.get("geometry")),
    )


def _doc_to_json(doc: CanvasDocument) -> dict:
    """Frozen top-level key order (overview §4.3) — byte-stable across saves."""
    return {
        "canvas_id": doc.canvas_id,
        "title": doc.title,
        "created_at": int(doc.created_at),
        "updated_at": int(doc.updated_at),
        "artboard": _artboard_to_json(doc.artboard),
        "content_bounds": {k: float(doc.content_bounds[k]) for k in _BOUND_KEYS},
        "elements": [_node_to_json(n) for n in doc.elements],
    }


def _doc_from_json(data: dict) -> CanvasDocument:
    if not isinstance(data, dict):
        raise ValueError("document.json root must be a JSON object")
    try:
        return CanvasDocument(
            canvas_id=data["canvas_id"],
            title=data["title"],
            created_at=int(data["created_at"]),
            updated_at=int(data["updated_at"]),
            artboard=_artboard_from_json(data["artboard"]),
            content_bounds={k: float(data["content_bounds"][k]) for k in _BOUND_KEYS},
            elements=[_node_from_json(e) for e in data["elements"]],
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"invalid document.json: {exc}") from exc


class DocumentStore:
    """Owns ``.slatesync`` archives, RPC asset ingestion and dirty autosave.

    Registers three subscriptions in ``__init__``: ``RPC_MESSAGE``
    (``CANVAS_LIFECYCLE``/``OPEN_CANVAS`` + the ``ASSET_UPLOAD`` chunk flow) and
    ``COMMITTED_NODE`` / ``ARTBOARD_CHANGED`` dirty marks (Doc 10 §4).
    """

    def __init__(self, bus: EventBus, config: AppConfig, scene_graph: SceneGraph) -> None:
        self._bus = bus
        self._config = config
        self._scene = scene_graph
        self._lock = threading.RLock()
        self._current: CanvasDocument | None = None
        self._current_path: Path | None = None
        self._dirty = False
        self._transfers: dict[str, _Transfer] = {}
        self._index: object | None = None  # LocalCanvasIndex (late attach, §9.3)
        bus.on(RPC_MESSAGE, self._on_rpc)
        bus.on(COMMITTED_NODE, self._mark_dirty)
        bus.on(ARTBOARD_CHANGED, self._mark_dirty)

    # ------------------------------------------------------------------
    # Frozen API (template §4)
    # ------------------------------------------------------------------
    def new(self, preset: str, title: str) -> CanvasDocument:
        """Seed a document from Doc 03 defaults; resets the scene graph."""
        if preset not in _PRESETS:
            raise ValueError(f"unknown artboard preset: {preset!r}")
        width, height = _PRESETS[preset]
        now = int(time.time())
        doc = CanvasDocument(
            canvas_id=str(uuid.uuid4()),
            title=title,
            created_at=now,
            updated_at=now,
            artboard=Artboard(
                preset=preset, width=width, height=height, is_infinite=(preset == "INFINITE")
            ),
            content_bounds=dict(_ZERO_BOUNDS),
            elements=[],
        )
        self._scene.replace_all([])
        self._scene.set_artboard(doc.artboard)
        with self._lock:
            self._current = doc
            self._current_path = (
                self._config.appdata_dir / "canvases" / f"{doc.canvas_id}.slatesync"
            )
            self._dirty = True
        return doc

    def open(self, path: Path) -> CanvasDocument:
        """Unzip ``.slatesync`` → ``CanvasDocument``; rebuild the scene graph and
        emit ``DOCUMENT_LOADED`` exactly once with clean state already set."""
        path = Path(path)
        doc, asset_entries = self._read_archive(path)
        if asset_entries:
            dest_dir = self.assets_dir(doc.canvas_id)
            for info, blob in asset_entries:
                # Zip-slip guard: only the basename ever lands on disk (Doc 10 §4).
                (dest_dir / Path(info.filename).name).write_bytes(blob)
        self._scene.replace_all(doc.elements)
        self._scene.set_artboard(doc.artboard)
        with self._lock:
            self._current = doc
            self._current_path = path
            self._dirty = False
        self._bus.emit(DOCUMENT_LOADED, doc=doc)  # state set BEFORE emit (Doc 10 §4)
        return doc

    # ------------------------------------------------------------------
    # Round 5 (Doc 02 §9.3) — side-effect-free I/O + local index binding
    # ------------------------------------------------------------------
    def _read_archive(
        self, path: Path
    ) -> tuple[CanvasDocument, list[tuple[zipfile.ZipInfo, bytes]]]:
        """Shared ZIP parse for :meth:`open`/:meth:`read_archive` (no side effects)."""
        with zipfile.ZipFile(path, "r") as archive:
            try:
                raw = archive.read("document.json")
            except KeyError as exc:
                raise ValueError(f"{path}: archive missing document.json") from exc
            doc = _doc_from_json(json.loads(raw.decode("utf-8")))
            asset_entries = [
                (info, archive.read(info))
                for info in archive.infolist()
                if not info.is_dir()
                and info.filename not in ("", ".")
                and Path(info.filename).name not in ("", ".", "..")
                and info.filename.replace("\\", "/").startswith("assets/")
            ]
        return doc, asset_entries

    def read_archive(self, path: Path) -> CanvasDocument:
        """Parse a ``.slatesync`` archive with NO state changes: no scene
        rebuild, no current-path switch, no ``DOCUMENT_LOADED`` emit and no
        asset extraction (round 5: ``LocalCanvasIndex.load`` serves
        ``CANVAS_PULL`` replies without ever touching the open document)."""
        doc, _asset_entries = self._read_archive(Path(path))
        return doc

    @staticmethod
    def parse_document(data: dict) -> CanvasDocument:
        """Validate + parse a wire/JSON document body without loading it
        (round 5: ``CANVAS_PUT`` persists through this before any switch)."""
        if not isinstance(data, dict):
            raise ValueError("parse_document() needs a document object")
        return _doc_from_json(data)

    @staticmethod
    def document_to_json(doc: CanvasDocument) -> dict:
        """Frozen ``document.json`` body for a document (round 5: ``CANVAS_PUT``
        replies carry this; key order matches :meth:`save`)."""
        return _doc_to_json(doc)

    def attach_index(self, index) -> None:
        """Bind the ``LocalCanvasIndex`` after construction (the index takes
        this store for ZIP I/O, so the reference is attached late). Enables
        persist-on-open in :meth:`open_payload` and the ``index.json`` row
        refresh after focused saves."""
        self._index = index

    @property
    def index(self):
        """The attached ``LocalCanvasIndex``, or None (persistence disabled)."""
        return self._index

    def open_payload(self, data: dict) -> CanvasDocument:
        """Load a full Doc 03 document from a wire dict (Doc 02 §8.2 dialect).

        Same rebuild path as :meth:`open` minus the ZIP: parse → replace the
        injected SceneGraph contents + artboard → mark clean → emit
        ``DOCUMENT_LOADED`` exactly once (state set before the emit). The
        document came off the wire, so ``current_path`` becomes ``None`` — a
        tablet canvas is never autosaved into a PC-local archive.

        Persist-on-open (round 5, Doc 02 §9.3): when an index is attached,
        the document is stored into the hub index FIRST — LWW per §9.1 via
        ``save_document_if_newer`` (equal keeps local, older never overwrites)
        — and only then does the scene switch below. A persistence failure is
        logged and the switch still proceeds (ordering rule, not atomicity);
        without an attached index this is a no-op.
        """
        if not isinstance(data, dict):
            raise ValueError("open_payload() needs a document object")
        doc = _doc_from_json(data)
        if self._index is not None:
            try:
                self._index.save_document_if_newer(doc, source="device")
            except Exception:
                logger.exception(
                    "persist-on-open failed for %s; document still opened", doc.canvas_id
                )
        self._scene.replace_all(doc.elements)
        self._scene.set_artboard(doc.artboard)
        with self._lock:
            self._current = doc
            self._current_path = None
            self._dirty = False
        self._bus.emit(DOCUMENT_LOADED, doc=doc)  # state set BEFORE emit (Doc 10 §4)
        return doc

    def save(self, doc: CanvasDocument, path: Path | None = None) -> Path:
        """Atomic ZIP write; ``path`` falls back to ``current_path``, else
        ``ValueError`` — never a silent destination. Failure logs + re-raises."""
        with self._lock:
            target = path if path is not None else self._current_path
            if target is None:
                raise ValueError("save() needs an explicit path: no current_path set")
            return self._save(doc, Path(target))

    def assets_dir(self, canvas_id: str) -> Path:
        dest = self._config.assets_dir / canvas_id
        dest.mkdir(parents=True, exist_ok=True)
        return dest

    def autosave_tick(self) -> bool:
        """Called every ``config.autosave_interval_s`` by main.py's single timer:
        save only when dirty AND a current doc AND a destination exist.
        Round 5: returns True when a save happened so main.py can rebroadcast
        the hub ``CANVAS_LIST`` (§9.2 — the hub store changed)."""
        with self._lock:
            if not self._dirty or self._current is None or self._current_path is None:
                return False
            self._save(self._current, self._current_path)
            return True

    # ------------------------------------------------------------------
    # Doc-specific API & contracts (frozen)
    # ------------------------------------------------------------------
    def asset_path(self, canvas_id: str, asset_ref: str) -> Path:
        return self.assets_dir(canvas_id) / Path(asset_ref).name

    @property
    def current_path(self) -> Path | None:
        with self._lock:
            return self._current_path

    @property
    def is_dirty(self) -> bool:
        with self._lock:
            return self._dirty

    def snapshot_current(self) -> CanvasDocument | None:
        """Live copy of the open document — scene graph state, not the opener's.

        Round 7 (issue 06): exporters used to serialize ``current_doc["doc"]``,
        the object captured when ``DOCUMENT_LOADED`` fired. Every tablet edit
        after that lives in the ``SceneGraph`` only (``doc.elements`` is
        refreshed on save), so exports produced the canvas as it looked when it
        was opened — the "exports an older canvas" bug. This returns a shallow
        copy carrying the CURRENT ``scene.nodes()`` + ``content_bounds()``.
        """
        with self._lock:
            current = self._current
            if current is None:
                return None
            return replace(
                current,
                elements=self._scene.nodes(),
                content_bounds=self._scene.content_bounds(),
                artboard=self._scene_artboard(current.artboard),
            )

    def _scene_artboard(self, fallback: Artboard) -> Artboard:
        """Artboard currently bound to the scene (upgrades mutate it in place)."""
        artboard = getattr(self._scene, "artboard", None)
        return artboard if artboard is not None else fallback

    # ------------------------------------------------------------------
    # Bus subscriptions
    # ------------------------------------------------------------------
    def _on_rpc(self, msg: dict) -> None:
        if not isinstance(msg, dict):
            return
        envelope_type = msg.get("type")
        action = msg.get("action")
        if envelope_type == "CANVAS_LIFECYCLE" and action == "OPEN_CANVAS":
            payload = msg.get("payload")
            if isinstance(payload, dict) and "canvas" in payload:
                # Cross-device dialect (Doc 02 §8.2): CanvasSyncManager owns it
                # and routes the body through open_payload() — never this path.
                logger.debug("OPEN_CANVAS canvas dialect routed by CanvasSyncManager")
                return
            raw_path = payload.get("path") if isinstance(payload, dict) else None
            if not raw_path:
                logger.error(
                    "OPEN_CANVAS without payload.path ignored (Docs 16/26 must send it): %r",
                    msg,
                )
                return
            try:
                self.open(Path(raw_path))
            except Exception:
                logger.exception("OPEN_CANVAS failed for %s", raw_path)
        elif envelope_type == "ASSET_UPLOAD":
            self._on_asset(msg)

    def _mark_dirty(self, **_payload) -> None:
        with self._lock:
            self._dirty = True

    # ------------------------------------------------------------------
    # ASSET_UPLOAD chunk flow (Doc 10 §4)
    # ------------------------------------------------------------------
    def _on_asset(self, msg: dict) -> None:
        payload = msg.get("payload")
        if not isinstance(payload, dict):
            logger.warning("ASSET_UPLOAD payload must be an object: %r", msg)
            return
        action = msg.get("action")
        transfer_id = payload.get("transfer_id")
        if not transfer_id:
            logger.warning("ASSET_UPLOAD %s without transfer_id ignored", action)
            return
        if action == "ASSET_START":
            self._asset_start(str(transfer_id), payload)
        elif action == "ASSET_CHUNK":
            self._asset_chunk(str(transfer_id), payload)
        elif action == "ASSET_DONE":
            self._asset_done(msg, str(transfer_id), payload)

    def _asset_start(self, transfer_id: str, payload: dict) -> None:
        filename = payload.get("filename")
        total = payload.get("total_chunks")
        size = payload.get("size_bytes")
        if (
            not isinstance(filename, str)
            or not filename
            or not isinstance(total, int)
            or isinstance(total, bool)
            or total < 0
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
        ):
            logger.warning("Malformed ASSET_START ignored: %r", payload)
            return
        with self._lock:
            self._transfers[transfer_id] = _Transfer(
                filename=filename, total_chunks=total, size_bytes=size,
                chunks=[None] * total,
            )

    def _asset_chunk(self, transfer_id: str, payload: dict) -> None:
        with self._lock:
            transfer = self._transfers.get(transfer_id)
        if transfer is None:
            logger.warning("ASSET_CHUNK for unknown transfer %r ignored", transfer_id)
            return
        index = payload.get("index")
        if not isinstance(index, int) or isinstance(index, bool) or not (
            0 <= index < transfer.total_chunks
        ):
            self._discard(transfer_id, f"chunk index {index!r} out of range")
            return
        try:
            raw = base64.b64decode(payload.get("data_b64"), validate=True)
        except (binascii.Error, TypeError, ValueError) as exc:
            self._discard(transfer_id, f"chunk {index} not decodable: {exc}")
            return
        if len(raw) > _MAX_CHUNK_RAW:
            self._discard(transfer_id, f"chunk {index} exceeds {_MAX_CHUNK_RAW} raw bytes")
            return
        with self._lock:
            if self._transfers.get(transfer_id) is transfer:
                transfer.chunks[index] = raw

    def _asset_done(self, msg: dict, transfer_id: str, payload: dict) -> None:
        with self._lock:
            transfer = self._transfers.pop(transfer_id, None)
        if transfer is None:
            logger.warning("ASSET_DONE for unknown transfer %r ignored", transfer_id)
            return
        if not payload.get("ok", True):
            logger.info("ASSET_DONE aborted transfer %r; buffer discarded", transfer_id)
            return
        if any(chunk is None for chunk in transfer.chunks):
            self._log_done_failure(transfer_id, "missing chunks")
            return
        data = b"".join(chunk for chunk in transfer.chunks if chunk is not None)
        if len(data) != transfer.size_bytes:
            self._log_done_failure(
                transfer_id, f"size mismatch: got {len(data)} != {transfer.size_bytes}"
            )
            return
        canvas_id = msg.get("canvas_id") or (
            self._current.canvas_id if self._current is not None else None
        )
        if not canvas_id:
            self._log_done_failure(transfer_id, "no canvas_id on envelope")
            return
        name = Path(transfer.filename).name
        if not name:
            self._log_done_failure(transfer_id, f"empty filename {transfer.filename!r}")
            return
        dest_dir = self.assets_dir(str(canvas_id))
        tmp = dest_dir / f"{name}.tmp"
        try:
            tmp.write_bytes(data)
            os.replace(tmp, dest_dir / name)
        except OSError:
            tmp.unlink(missing_ok=True)
            logger.exception("Atomic asset write failed for %r", name)
            return
        with self._lock:
            self._dirty = True

    def _discard(self, transfer_id: str, reason: str) -> None:
        with self._lock:
            self._transfers.pop(transfer_id, None)
        logger.warning("ASSET transfer %r discarded: %s", transfer_id, reason)

    @staticmethod
    def _log_done_failure(transfer_id: str, reason: str) -> None:
        logger.warning("ASSET_DONE transfer %r discarded: %s", transfer_id, reason)

    # ------------------------------------------------------------------
    # Atomic archive I/O
    # ------------------------------------------------------------------
    def _save(self, doc: CanvasDocument, path: Path) -> Path:
        """Doc 10 frozen save semantics — stamp + sync scene + focus (see
        :meth:`write_archive` for the round-5 knobs)."""
        return self.write_archive(doc, path)

    def write_archive(
        self,
        doc: CanvasDocument,
        path: Path,
        *,
        stamp_updated: bool = True,
        sync_scene: bool = True,
        focus: bool = True,
    ) -> Path:
        """Serialize + atomic replace (``<path>.tmp`` → ``os.replace``); failure
        logs, unlinks the tmp file and re-raises — the original stays untouched.

        Defaults reproduce the Doc 10 contract (single-writer under
        ``self._lock``): stamp ``updated_at``, pull elements/bounds from the
        injected SceneGraph, and focus the currently-open document as clean.
        ``LocalCanvasIndex.save_document`` persists received wire documents
        with ``stamp_updated=False, sync_scene=False, focus=False`` so the LWW
        timestamp stays authoritative, the open scene never leaks into a silent
        save, and current-document/autosave state is untouched. After a
        focused save the matching ``index.json`` row (when one exists, or when
        the archive lives inside the index directory) is refreshed.
        """
        with self._lock:
            if stamp_updated:
                doc.updated_at = int(time.time())
            if sync_scene:
                doc.elements = self._scene.nodes()
                doc.content_bounds = self._scene.content_bounds()
            text = json.dumps(_doc_to_json(doc), ensure_ascii=False)
            tmp = Path(str(path) + ".tmp")
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                    archive.writestr("document.json", text)
                    assets_root = self.assets_dir(doc.canvas_id)
                    for file in sorted(assets_root.rglob("*")):
                        if file.is_file():
                            arcname = "assets/" + file.relative_to(assets_root).as_posix()
                            archive.write(file, arcname=arcname)
                os.replace(tmp, path)
            except Exception:
                tmp.unlink(missing_ok=True)
                logger.exception("save to %s failed; original untouched", path)
                raise
            if focus:
                self._current = doc
                self._current_path = path
                self._dirty = False
                self._refresh_index_row(doc, path)
        return path

    def _refresh_index_row(self, doc: CanvasDocument, path: Path) -> None:
        """Keep ``index.json`` in step with a hub-store archive (§9.3).

        Runs only when the index has a row for this canvas OR the archive
        lives inside the index directory — opening/autosaving a PC-local file
        elsewhere never creates index rows (File → "Open local file…" stays
        index-free). Always called with ``self._lock`` held (lock order:
        store → index).
        """
        if self._index is None:
            return
        try:
            in_index_dir = Path(path).parent.resolve() == Path(self._index.directory).resolve()
            if not in_index_dir and self._index.get(doc.canvas_id) is None:
                return
            self._index.refresh_row(doc)
        except Exception:
            logger.exception("index row refresh failed for %s", doc.canvas_id)
