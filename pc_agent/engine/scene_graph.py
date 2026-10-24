"""Spatial R-Tree scene graph (Doc 09) — the authoritative PC-side spatial index.

Freeze source: ``docs/micro/09_pc_spatial_rtree_scene_graph.md`` §4 and
``docs/_micro_doc_template.md`` §4. The ``dict[node_id, CanvasNode]`` is the
source of truth; the ``rtree.Index`` only maps bboxes to node ids. One
``threading.RLock`` guards every mutation and query; ``EventBus.emit`` always
runs on the caller's thread *outside* the lock so synchronous handlers may
re-enter store code without lock-order cycles.
"""

from __future__ import annotations

import logging
import threading
import uuid
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Callable

import rtree

from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    CANVAS_CLEARED,
    COMMITTED_NODE,
    RPC_MESSAGE,
    EventBus,
)

if TYPE_CHECKING:
    from pc_agent.engine.document_store import Artboard

logger = logging.getLogger("slatesync.scene_graph")

#: Command-stack cap; the oldest command is dropped when exceeded (Doc 09 §4).
MAX_UNDO = 200

#: §3 artboard preset table (300-DPI world units, top-left origin).
_PRESETS: dict[str, tuple[float | None, float | None]] = {
    "A5": (1748.0, 2480.0),
    "A4": (2480.0, 3508.0),
    "LETTER": (2550.0, 3300.0),
    "INFINITE": (None, None),
}

_ZERO_BOUNDS: dict[str, float] = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
_BOUND_KEYS = ("min_x", "min_y", "max_x", "max_y")

#: Default ``kind`` per ELEMENT_COMMIT add action (payload may override).
_DEFAULT_KINDS: dict[str, str] = {
    "ADD_STROKE": "STROKE",
    "ADD_GRAPH": "GRAPH_AXES",
    "ADD_SHAPE": "SHAPE",
    "ADD_IMAGE": "IMAGE",
}
_STYLE_FIELDS = ("color", "stroke_width", "opacity", "blend_mode")
_GEOM_FIELDS = ("pts", "shape_type", "graph_config", "asset_ref")


@dataclass
class NodeStyle:
    color: str = "#1E1E1E"
    stroke_width: float = 2.5
    opacity: float = 1.0
    blend_mode: str = "SRC_OVER"


@dataclass
class NodeGeometry:
    pts: list[list[float]] = field(default_factory=list)
    shape_type: str | None = None  # RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE
    graph_config: dict | None = None
    asset_ref: str | None = None


@dataclass
class CanvasNode:
    node_id: str
    kind: str  # STROKE|HIGHLIGHT|LINE|SHAPE|GRAPH_AXES|IMAGE
    layer: int = 0
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    style: NodeStyle = field(default_factory=NodeStyle)
    geometry: NodeGeometry = field(default_factory=NodeGeometry)


@dataclass
class Command:
    """One undoable mutation: the forward/inverse closures return the frozen
    ``COMMITTED_NODE`` kwargs to re-emit after the lock is released."""

    do: Callable[[], dict]
    undo: Callable[[], dict]


def _as_box(bbox: tuple[float, float, float, float]) -> tuple[float, float, float, float]:
    return (float(bbox[0]), float(bbox[1]), float(bbox[2]), float(bbox[3]))


def _bbox_from_pts(pts: list[list[float]]) -> tuple[float, float, float, float]:
    """min/max over ``geometry.pts``; no pts ⇒ ``(0, 0, 0, 0)`` (Doc 09 §4)."""
    if not pts:
        return (0.0, 0.0, 0.0, 0.0)
    xs = [float(p[0]) for p in pts]
    ys = [float(p[1]) for p in pts]
    return (min(xs), min(ys), max(xs), max(ys))


class SceneGraph:
    """R-tree + dict scene index with content bounds, §4.4 upgrades and undo/redo.

    ``__init__`` registers ``bus.on("RPC_MESSAGE", self.apply_rpc)`` — the only
    wiring this class performs (Doc 09 §5 step 9).
    """

    def __init__(self, bus: EventBus) -> None:
        self._bus = bus
        self._lock = threading.RLock()
        self._nodes: dict[str, CanvasNode] = {}
        self._index = rtree.Index()
        self._boxes: dict[str, tuple[float, float, float, float]] = {}
        # rtree 1.4.x requires integer item ids → map node_id → int id; the
        # index still carries node_id only as payload (dict stays source of truth).
        self._ids: dict[str, int] = {}
        self._next_id = 0
        self._bounds: dict[str, float] = dict(_ZERO_BOUNDS)
        self._artboard: Artboard | None = None
        self._undo: list[Command] = []
        self._redo: list[Command] = []
        bus.on(RPC_MESSAGE, self.apply_rpc)

    # ------------------------------------------------------------------
    # Core mutation / query primitives (all under one RLock)
    # ------------------------------------------------------------------
    def insert(self, node: CanvasNode) -> None:
        """Insert-or-update ``node``; an existing id is an in-place style change.

        Both cases push an undo command, clear redo, and emit ``COMMITTED_NODE``.
        """
        with self._lock:
            previous = self._nodes.get(node.node_id)
            self._store(node)
            if previous is None:
                self._push(
                    Command(
                        do=lambda: self._apply_store(node),
                        undo=lambda: self._apply_remove(node.node_id),
                    )
                )
            else:
                self._push(
                    Command(
                        do=lambda: self._apply_store(node),
                        undo=lambda: self._apply_store(previous),
                    )
                )
        self._bus.emit(COMMITTED_NODE, node=node)

    def delete(self, node_id: str) -> None:
        """Remove ``node_id`` (no-op when absent); emits the delete sub-event."""
        with self._lock:
            node = self._nodes.get(node_id)
            if node is None:
                return
            self._remove(node_id)
            self._push(
                Command(
                    do=lambda: self._apply_remove(node_id),
                    undo=lambda: self._apply_store(node),
                )
            )
        self._bus.emit(COMMITTED_NODE, node=None, deleted_node_id=node_id)

    def get(self, node_id: str) -> CanvasNode | None:
        with self._lock:
            return self._nodes.get(node_id)

    def query_bbox(self, min_x, min_y, max_x, max_y) -> list[CanvasNode]:
        with self._lock:
            ids = self._index.intersection((min_x, min_y, max_x, max_y), objects="raw")
            found = [self._nodes[node_id] for node_id in ids if node_id in self._nodes]
            found.sort(key=lambda n: (n.layer, n.node_id))
            return found

    def content_bounds(self) -> dict[str, float]:
        """Global union of node bboxes; empty document ⇒ all zeros (Doc 09 §4)."""
        with self._lock:
            return dict(self._bounds)

    @property
    def artboard(self) -> Artboard | None:
        """Artboard currently bound to the scene (upgrades mutate it in place).

        Round 7: exporters take this instead of the opener's ``doc.artboard`` so
        an ``UPGRADE_SIZE`` applied after the open is reflected in the output.
        """
        with self._lock:
            return self._artboard

    # ------------------------------------------------------------------
    # Doc 10 hand-off API (frozen)
    # ------------------------------------------------------------------
    def nodes(self) -> list[CanvasNode]:
        """All nodes sorted by ``(layer, node_id)`` — Doc 10 ``save()`` source."""
        with self._lock:
            return sorted(self._nodes.values(), key=lambda n: (n.layer, n.node_id))

    def replace_all(self, nodes: list[CanvasNode]) -> None:
        """Fresh rtree + dict + bounds; clears both command stacks; emits nothing
        and records no undo history, so Doc 10's ``open()`` cannot pollute state."""
        with self._lock:
            self._nodes = {}
            self._index = rtree.Index()
            self._boxes = {}
            self._ids = {}
            self._next_id = 0
            self._bounds = dict(_ZERO_BOUNDS)
            self._undo.clear()
            self._redo.clear()
            for node in nodes:
                self._store(node)

    def set_artboard(self, artboard: Artboard) -> None:
        """Share the live ``doc.artboard`` instance (mutated in place on upgrade)."""
        with self._lock:
            self._artboard = artboard

    def clear_all(self) -> None:
        """Wipe EVERY element: fresh rtree + dict + zero bounds (Doc 02 §10.1).

        Also discards the full undo/redo history — the stacked commands hold
        closures over the removed nodes, so nothing could be restored meaningfully
        (history loss is deliberate; matching ``replace_all``, this emits nothing:
        the ``CANVAS_CLEARED`` event is emitted by ``apply_rpc``). The bound
        artboard (if any) is untouched: only elements are cleared.
        """
        with self._lock:
            self._nodes = {}
            self._index = rtree.Index()
            self._boxes = {}
            self._ids = {}
            self._next_id = 0
            self._bounds = dict(_ZERO_BOUNDS)
            self._undo.clear()
            self._redo.clear()

    # ------------------------------------------------------------------
    # RPC routing (frozen table, Doc 09 §4)
    # ------------------------------------------------------------------
    def apply_rpc(self, msg: dict) -> None:
        if not isinstance(msg, dict):
            return
        envelope_type = msg.get("type")
        action = msg.get("action")
        payload = msg.get("payload")
        if not isinstance(payload, dict):
            payload = {}
        if envelope_type == "ELEMENT_COMMIT":
            if action == "DELETE_NODE":
                node_id = payload.get("node_id")
                if not node_id:
                    logger.warning("DELETE_NODE without payload.node_id ignored: %r", msg)
                    return
                self.delete(str(node_id))
            elif action == "CLEAR_CANVAS":
                # Doc 02 §10.1: PC applies ALWAYS (no open-document gating in
                # the scene graph — it indexes the single currently-open doc).
                self.clear_all()
                canvas_id = msg.get("canvas_id")
                self._bus.emit(
                    CANVAS_CLEARED,
                    canvas_id=canvas_id if isinstance(canvas_id, str) else "",
                )
            elif action in _DEFAULT_KINDS:
                self._rpc_add(action, payload)
        elif envelope_type == "ARTBOARD_RESIZE" and action == "UPGRADE_SIZE":
            self._rpc_upgrade(payload)
        # EXPORT_JOB / ASSET_UPLOAD / CANVAS_LIFECYCLE belong to Docs 15/10.

    def validate_artboard_upgrade(
        self, target_preset: str, target_w: float | None, target_h: float | None
    ) -> bool:
        """§4.4 verbatim: allow iff ``target==INFINITE`` OR content fits the target
        (``min_x>=0 AND min_y>=0 AND max_x<=w AND max_y<=h``); unknown ⇒ ``False``;
        zeros (empty doc) satisfy any bounded target."""
        with self._lock:
            if target_preset == "INFINITE":
                return True
            if not isinstance(target_preset, str) or target_preset not in _PRESETS:
                return False
            table_w, table_h = _PRESETS[target_preset]
            try:
                width = float(target_w) if target_w is not None else table_w
                height = float(target_h) if target_h is not None else table_h
            except (TypeError, ValueError):
                return False
            if width is None or height is None:
                return False
            bounds = self._bounds
            return (
                bounds["min_x"] >= 0.0
                and bounds["min_y"] >= 0.0
                and bounds["max_x"] <= width
                and bounds["max_y"] <= height
            )

    def undo(self) -> bool:
        with self._lock:
            if not self._undo:
                return False
            command = self._undo.pop()
            payload = command.undo()
            self._redo.append(command)
        self._bus.emit(COMMITTED_NODE, **payload)
        return True

    def redo(self) -> bool:
        with self._lock:
            if not self._redo:
                return False
            command = self._redo.pop()
            payload = command.do()
            self._undo.append(command)
        self._bus.emit(COMMITTED_NODE, **payload)
        return True

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------
    def _store(self, node: CanvasNode) -> None:
        """Insert-or-replace in dict + index; incremental bounds fold (no emit)."""
        box = _as_box(node.bbox)
        old_box = self._boxes.get(node.node_id)
        if old_box is not None:
            self._index.delete(self._ids[node.node_id], old_box)
            del self._boxes[node.node_id]
            del self._ids[node.node_id]
            del self._nodes[node.node_id]
        was_empty = not self._nodes
        self._nodes[node.node_id] = node
        self._boxes[node.node_id] = box
        item_id = self._next_id
        self._next_id += 1
        self._ids[node.node_id] = item_id
        self._index.insert(item_id, box, obj=node.node_id)
        if old_box is not None and self._touches(old_box):
            # The replaced box may have anchored an extreme → targeted recompute.
            self._recompute_bounds()
        elif was_empty:
            self._bounds = dict(zip(_BOUND_KEYS, box))
        else:
            self._fold_bounds(box)

    def _remove(self, node_id: str) -> bool:
        box = self._boxes.pop(node_id, None)
        if box is None:
            return False
        del self._nodes[node_id]
        self._index.delete(self._ids.pop(node_id), box)
        if self._touches(box):
            self._recompute_bounds()
        return True

    def _apply_store(self, node: CanvasNode) -> dict:
        self._store(node)
        return {"node": node}

    def _apply_remove(self, node_id: str) -> dict:
        self._remove(node_id)
        return {"node": None, "deleted_node_id": node_id}

    def _push(self, command: Command) -> None:
        self._redo.clear()
        self._undo.append(command)
        if len(self._undo) > MAX_UNDO:
            del self._undo[0]

    def _touches(self, box: tuple[float, float, float, float]) -> bool:
        bounds = self._bounds
        return (
            box[0] <= bounds["min_x"]
            or box[1] <= bounds["min_y"]
            or box[2] >= bounds["max_x"]
            or box[3] >= bounds["max_y"]
        )

    def _fold_bounds(self, box: tuple[float, float, float, float]) -> None:
        bounds = self._bounds
        bounds["min_x"] = min(bounds["min_x"], box[0])
        bounds["min_y"] = min(bounds["min_y"], box[1])
        bounds["max_x"] = max(bounds["max_x"], box[2])
        bounds["max_y"] = max(bounds["max_y"], box[3])

    def _recompute_bounds(self) -> None:
        if not self._boxes:
            self._bounds = dict(_ZERO_BOUNDS)
            return
        self._bounds = dict(zip(_BOUND_KEYS, next(iter(self._boxes.values()))))
        for box in self._boxes.values():
            self._fold_bounds(box)

    def _rpc_add(self, action: str, payload: dict) -> None:
        try:
            node = self._build_node(action, payload)
        except (KeyError, TypeError, ValueError, IndexError) as exc:
            logger.warning("Malformed %s payload ignored (%s): %r", action, exc, payload)
            return
        self.insert(node)

    def _build_node(self, action: str, payload: dict) -> CanvasNode:
        raw_id = payload.get("node_id")
        node_id = str(raw_id) if raw_id else str(uuid.uuid4())
        kind = payload.get("kind") or _DEFAULT_KINDS[action]

        layer_raw = payload.get("layer", 0)
        layer = layer_raw if isinstance(layer_raw, int) and not isinstance(layer_raw, bool) else 0

        style_raw = payload.get("style")
        if isinstance(style_raw, dict):
            style = NodeStyle(**{k: style_raw[k] for k in _STYLE_FIELDS if k in style_raw})
        else:
            style = NodeStyle()

        geom_raw = payload.get("geometry")
        if not isinstance(geom_raw, dict):
            geom_raw = {}
        geometry = NodeGeometry(**{k: geom_raw[k] for k in _GEOM_FIELDS if k in geom_raw})
        geometry.pts = [[float(p[0]), float(p[1])] for p in geometry.pts]

        bbox = self._resolve_bbox(payload, geometry.pts)
        return CanvasNode(
            node_id=node_id, kind=str(kind), layer=layer, bbox=bbox, style=style,
            geometry=geometry,
        )

    @staticmethod
    def _resolve_bbox(
        payload: dict, pts: list[list[float]]
    ) -> tuple[float, float, float, float]:
        """Payload ``bbox`` wins; else min/max over pts; no pts ⇒ zeros (Doc 09 §4)."""
        raw = payload.get("bbox")
        if raw is not None:
            try:
                box = tuple(float(v) for v in raw)  # type: ignore[arg-type]
            except (TypeError, ValueError):
                box = ()
            if len(box) == 4:
                return box  # type: ignore[return-value]
        return _bbox_from_pts(pts)

    def _rpc_upgrade(self, payload: dict) -> None:
        preset = payload.get("preset")
        width = payload.get("width")
        height = payload.get("height")
        with self._lock:
            artboard = self._artboard
            if artboard is None:
                logger.warning("UPGRADE_SIZE ignored: no artboard bound to the scene graph")
                return
            if not self.validate_artboard_upgrade(preset, width, height):
                logger.warning(
                    "UPGRADE_SIZE refused: %r (w=%r, h=%r) does not fit content_bounds=%s",
                    preset, width, height, dict(self._bounds),
                )
                return
            artboard.preset = preset
            if preset == "INFINITE":
                artboard.width = None
                artboard.height = None
                artboard.is_infinite = True
            else:
                table_w, table_h = _PRESETS[preset]
                artboard.width = float(width) if width is not None else table_w
                artboard.height = float(height) if height is not None else table_h
                artboard.is_infinite = False
            bounds = dict(self._bounds)
        self._bus.emit(ARTBOARD_CHANGED, artboard=artboard, content_bounds=bounds)
