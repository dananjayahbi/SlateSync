"""Live mirror element registry for the PC viewport (round 7, issue 06).

``GLCanvasHost`` used to paint elements straight from ``doc.elements`` — the
snapshot carried by the ``DOCUMENT_LOADED`` event. Edits that arrive *after*
the document is open never touch that snapshot (``SceneGraph`` mutates its own
RTree), so the mirror showed the canvas as it looked when it was opened:
strokes were patched in by the tessellator path, but SHAPE / GRAPH_AXES /
IMAGE nodes were dropped — they are drawn by ``PrimitiveRenderer`` from a node
list that was never refreshed.

``MirrorScene`` is that refresher: an ordered, thread-safe node map the host
seeds from the opened document and then keeps in step with every
``COMMITTED_NODE`` (insert/update/delete) and ``CANVAS_CLEARED``. It is a pure
in-memory structure — no GL, no Tk, no event subscriptions — so it is cheap to
unit-test.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

_ZERO_BOUNDS = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}


class MirrorScene:
    """``node_id → node`` map mirrored from the PC scene graph.

    Nodes are stored as objects (``CanvasNode``-shaped duck types are fine) and
    returned sorted by ``(layer, node_id)`` — the z-order both
    ``PrimitiveRenderer`` and ``SceneGraph.nodes()`` use.
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._nodes: dict[str, object] = {}

    # -- mutations -----------------------------------------------------
    def reset(self, nodes: object = None) -> None:
        """Replace the whole set (document load); ``None`` ⇒ empty."""
        with self._lock:
            self._nodes = {}
            for node in nodes or []:
                if node is not None:
                    self._nodes[_node_id(node)] = node

    def upsert(self, node: object) -> None:
        """Insert or replace one node (an id already present is an edit)."""
        if node is None:
            return
        with self._lock:
            self._nodes[_node_id(node)] = node

    def remove(self, node_id: object) -> None:
        """Drop ``node_id``; a missing id is a no-op."""
        if node_id is None:
            return
        with self._lock:
            self._nodes.pop(str(node_id), None)

    def clear(self) -> None:
        with self._lock:
            self._nodes = {}

    # -- queries -------------------------------------------------------
    def nodes(self) -> list[object]:
        """Snapshot sorted by ``(layer, node_id)`` — safe to iterate off-lock."""
        with self._lock:
            return sorted(
                self._nodes.values(),
                key=lambda node: (
                    int(getattr(node, "layer", 0) or 0),
                    str(getattr(node, "node_id", "")),
                ),
            )

    def __len__(self) -> int:
        with self._lock:
            return len(self._nodes)

    def bounds(self) -> dict[str, float]:
        """Union of every node bbox; empty ⇒ all zeros (Doc 09 §4 shape)."""
        with self._lock:
            nodes = list(self._nodes.values())
        if not nodes:
            return dict(_ZERO_BOUNDS)
        min_x = min_y = float("inf")
        max_x = max_y = float("-inf")
        for node in nodes:
            bbox = getattr(node, "bbox", None)
            if not bbox or len(bbox) < 4:
                continue
            min_x = min(min_x, float(bbox[0]))
            min_y = min(min_y, float(bbox[1]))
            max_x = max(max_x, float(bbox[2]))
            max_y = max(max_y, float(bbox[3]))
        if min_x > max_x or min_y > max_y:
            return dict(_ZERO_BOUNDS)
        return {"min_x": min_x, "min_y": min_y, "max_x": max_x, "max_y": max_y}


def _node_id(node: object) -> str:
    """Stable key for a node-like object (never raises)."""
    value = getattr(node, "node_id", None)
    if isinstance(value, str) and value:
        return value
    return f"__node_{id(node)}"


@dataclass
class MirrorArtboard:
    """Stand-in artboard for elements that arrive before any document loads.

    A tablet can commit a shape the moment it connects — before the hub ever
    saw an ``OPEN_CANVAS``. Without *some* artboard, ``PrimitiveRenderer`` is
    skipped entirely and those shapes never appear in the mirror (round 7
    issue 06). An infinite, white, blank board draws them exactly like the
    tablet's own infinite canvas.
    """

    preset: str = "INFINITE"
    width: float | None = None
    height: float | None = None
    is_infinite: bool = True
    background_style: str = "BLANK"
    background_color: str = "#FFFFFF"
