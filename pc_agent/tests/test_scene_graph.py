"""Tests for the spatial R-Tree SceneGraph (Doc 09 §6).

Covers the R-tree ≡ brute-force query contract, incremental content bounds,
the full §4.4 upgrade matrix, the frozen event contract, undo/redo (incl. the
200-command cap) and RLock concurrency.
"""

from __future__ import annotations

import gc
import logging
import random
import threading
import uuid
from uuid import UUID

import pytest

from pc_agent.core.events import (
    ARTBOARD_CHANGED,
    COMMITTED_NODE,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.engine.document_store import Artboard
from pc_agent.engine.scene_graph import (
    MAX_UNDO,
    CanvasNode,
    SceneGraph,
)

_ZERO = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}


@pytest.fixture
def bus() -> EventBus:
    return EventBus()


@pytest.fixture
def graph(bus: EventBus) -> SceneGraph:
    return SceneGraph(bus)


def _spy(bus: EventBus) -> list[tuple[str, dict]]:
    events: list[tuple[str, dict]] = []
    bus.on(COMMITTED_NODE, lambda **kw: events.append(("COMMITTED_NODE", kw)))
    bus.on(ARTBOARD_CHANGED, lambda **kw: events.append(("ARTBOARD_CHANGED", kw)))
    return events


def _envelope(envelope_type: str, action: str, payload: dict) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": envelope_type,
        "action": action,
        "canvas_id": "cv-test",
        "payload": payload,
        "timestamp": 1760760000,
    }


def _commit(bus: EventBus, action: str, payload: dict) -> None:
    bus.emit(RPC_MESSAGE, msg=_envelope("ELEMENT_COMMIT", action, payload))


def _node(
    node_id: str,
    bbox: tuple[float, float, float, float],
    layer: int = 0,
    kind: str = "STROKE",
) -> CanvasNode:
    return CanvasNode(node_id=node_id, kind=kind, layer=layer, bbox=bbox)


def _brute_ids(viewport: tuple[float, float, float, float], nodes: list[CanvasNode]) -> set[str]:
    """Linear closed-interval overlap scan (reference for the R-tree)."""
    qx0, qy0, qx1, qy1 = viewport
    return {
        n.node_id
        for n in nodes
        if not (n.bbox[2] < qx0 or n.bbox[0] > qx1 or n.bbox[3] < qy0 or n.bbox[1] > qy1)
    }


def test_query_bbox_matches_brute_force_including_edge_touches(graph: SceneGraph) -> None:
    rng = random.Random(42)
    nodes: list[CanvasNode] = []
    for i in range(120):
        x = rng.uniform(-500.0, 500.0)
        y = rng.uniform(-500.0, 500.0)
        nodes.append(
            _node(f"n{i}", (x, y, x + rng.uniform(0.0, 200.0), y + rng.uniform(0.0, 200.0)),
                  layer=i % 5)
        )
    # Edge-sharing neighbours: touching at x==20 / y==20 counts as intersecting.
    nodes.append(_node("edge-a", (10.0, 10.0, 20.0, 20.0)))
    nodes.append(_node("edge-b", (20.0, 10.0, 30.0, 20.0)))
    nodes.append(_node("edge-c", (10.0, 20.0, 20.0, 30.0)))
    for node in nodes:
        graph.insert(node)

    viewports = [
        (-1000.0, -1000.0, 1000.0, 1000.0),
        (10.0, 10.0, 10.0, 10.0),  # point query on a shared corner
        (20.0, 15.0, 20.0, 15.0),  # point query exactly on edge-a/edge-b border
        (0.0, 0.0, 1.0, 1.0),
    ]
    for _ in range(20):
        x = rng.uniform(-550.0, 550.0)
        y = rng.uniform(-550.0, 550.0)
        viewports.append((x, y, x + rng.uniform(0.0, 300.0), y + rng.uniform(0.0, 300.0)))

    for viewport in viewports:
        got = {n.node_id for n in graph.query_bbox(*viewport)}
        assert got == _brute_ids(viewport, nodes), viewport

    # Frozen ordering contract: (layer, node_id).
    result = graph.query_bbox(-1000.0, -1000.0, 1000.0, 1000.0)
    keys = [(n.layer, n.node_id) for n in result]
    assert keys == sorted(keys)


def test_content_bounds_empty_incremental_and_interior_delete(graph: SceneGraph) -> None:
    assert graph.content_bounds() == _ZERO

    graph.insert(_node("a", (10.0, 20.0, 30.0, 40.0)))
    assert graph.content_bounds() == {
        "min_x": 10.0, "min_y": 20.0, "max_x": 30.0, "max_y": 40.0,
    }

    graph.insert(_node("b", (-5.0, 0.0, 100.0, 50.0)))
    assert graph.content_bounds() == {
        "min_x": -5.0, "min_y": 0.0, "max_x": 100.0, "max_y": 50.0,
    }

    # "a" is interior to "b" → deleting it must not shrink the bounds.
    graph.delete("a")
    assert graph.content_bounds() == {
        "min_x": -5.0, "min_y": 0.0, "max_x": 100.0, "max_y": 50.0,
    }

    graph.delete("b")
    assert graph.content_bounds() == _ZERO


def test_delete_extreme_node_recomputes_bounds_over_survivors(graph: SceneGraph) -> None:
    graph.insert(_node("outer", (0.0, 0.0, 1000.0, 1000.0)))
    graph.insert(_node("inner", (100.0, 100.0, 200.0, 200.0)))
    graph.insert(_node("mid", (300.0, 300.0, 400.0, 400.0)))
    assert graph.content_bounds() == {
        "min_x": 0.0, "min_y": 0.0, "max_x": 1000.0, "max_y": 1000.0,
    }

    graph.delete("outer")  # extreme node → targeted recompute over survivors
    assert graph.content_bounds() == {
        "min_x": 100.0, "min_y": 100.0, "max_x": 400.0, "max_y": 400.0,
    }


def test_upgrade_matrix_section_4_4(graph: SceneGraph) -> None:
    graph.set_artboard(Artboard(preset="A5", width=1748.0, height=2480.0))

    # Empty document (zeros) satisfies every bounded target, and INFINITE always.
    assert graph.validate_artboard_upgrade("A5", None, None)
    assert graph.validate_artboard_upgrade("A4", None, None)
    assert graph.validate_artboard_upgrade("LETTER", None, None)
    assert graph.validate_artboard_upgrade("INFINITE", None, None)
    assert not graph.validate_artboard_upgrade("A3", None, None)  # unknown ⇒ False

    graph.insert(_node("fits-a5", (10.0, 10.0, 100.0, 100.0)))
    assert graph.validate_artboard_upgrade("A4", None, None)  # A5 → A4 allowed

    # Fits A4 but exceeds A5 (2000 > 1748): A4 → A5 refused.
    graph.insert(_node("wide", (10.0, 10.0, 2000.0, 2400.0)))
    assert not graph.validate_artboard_upgrade("A5", None, None)
    assert graph.validate_artboard_upgrade("A4", None, None)
    assert graph.validate_artboard_upgrade("INFINITE", None, None)  # any → INFINITE

    # INFINITE → Letter: content outside 2550×3300 refused …
    graph.delete("wide")
    graph.insert(_node("huge", (10.0, 10.0, 3000.0, 3000.0)))
    assert not graph.validate_artboard_upgrade("LETTER", None, None)

    # … negative coordinates refused …
    graph.delete("huge")
    graph.insert(_node("negative", (-50.0, 10.0, 100.0, 100.0)))
    assert not graph.validate_artboard_upgrade("LETTER", None, None)

    # … content inside Letter allowed.
    graph.delete("negative")
    graph.insert(_node("inside", (100.0, 100.0, 2000.0, 2000.0)))
    assert graph.validate_artboard_upgrade("LETTER", None, None)


def test_upgrade_rpc_emits_artboard_changed_and_mutates_in_place(
    bus: EventBus, graph: SceneGraph
) -> None:
    artboard = Artboard(preset="A5", width=1748.0, height=2480.0)
    graph.set_artboard(artboard)
    events = _spy(bus)
    graph.insert(_node("n", (10.0, 10.0, 100.0, 100.0)))
    events.clear()

    bus.emit(RPC_MESSAGE, msg=_envelope("ARTBOARD_RESIZE", "UPGRADE_SIZE", {"preset": "A4"}))
    changed = [e for e in events if e[0] == "ARTBOARD_CHANGED"]
    assert len(changed) == 1
    payload = changed[0][1]
    assert payload["artboard"] is artboard  # shares the live instance
    assert artboard.preset == "A4"
    assert artboard.width == 2480.0
    assert artboard.height == 3508.0
    assert artboard.is_infinite is False
    assert payload["content_bounds"] == {
        "min_x": 10.0, "min_y": 10.0, "max_x": 100.0, "max_y": 100.0,
    }


def test_refused_upgrade_logs_warning_and_emits_nothing(
    bus: EventBus, graph: SceneGraph, caplog: pytest.LogCaptureFixture
) -> None:
    artboard = Artboard(preset="A4", width=2480.0, height=3508.0)
    graph.set_artboard(artboard)
    graph.insert(_node("huge", (10.0, 10.0, 9000.0, 9000.0)))
    events = _spy(bus)

    with caplog.at_level(logging.WARNING, logger="slatesync.scene_graph"):
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("ARTBOARD_RESIZE", "UPGRADE_SIZE", {"preset": "LETTER"}),
        )

    assert [e for e in events if e[0] == "ARTBOARD_CHANGED"] == []
    assert artboard.preset == "A4"
    assert artboard.width == 2480.0
    assert any("UPGRADE_SIZE" in r.getMessage() for r in caplog.records)

    # Unknown preset refused the same way.
    with caplog.at_level(logging.WARNING, logger="slatesync.scene_graph"):
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("ARTBOARD_RESIZE", "UPGRADE_SIZE", {"preset": "A3"}),
        )
    assert [e for e in events if e[0] == "ARTBOARD_CHANGED"] == []
    assert artboard.preset == "A4"

    # INFINITE always allowed, even for content far outside every preset.
    bus.emit(RPC_MESSAGE, msg=_envelope("ARTBOARD_RESIZE", "UPGRADE_SIZE", {"preset": "INFINITE"}))
    assert artboard.preset == "INFINITE"
    assert artboard.width is None and artboard.height is None
    assert artboard.is_infinite is True
    assert len([e for e in events if e[0] == "ARTBOARD_CHANGED"]) == 1


def test_add_actions_emit_frozen_kinds_and_uuid4_ids(bus: EventBus, graph: SceneGraph) -> None:
    events = _spy(bus)
    _commit(bus, "ADD_STROKE", {"node_id": "s1", "bbox": [1.0, 2.0, 3.0, 4.0]})
    _commit(bus, "ADD_STROKE", {"node_id": "h1", "kind": "HIGHLIGHT"})
    _commit(bus, "ADD_GRAPH", {"node_id": "g1"})
    _commit(bus, "ADD_SHAPE", {"node_id": "sh1"})
    _commit(bus, "ADD_SHAPE", {"node_id": "l1", "kind": "LINE"})
    _commit(bus, "ADD_IMAGE", {"node_id": "i1"})

    assert len(events) == 6
    kinds: dict[str, str] = {}
    for name, payload in events:
        assert name == "COMMITTED_NODE"
        assert payload["node"] is not None  # add-style sub-event
        node = payload["node"]
        kinds[node.node_id] = node.kind
    assert kinds == {
        "s1": "STROKE",
        "h1": "HIGHLIGHT",
        "g1": "GRAPH_AXES",
        "sh1": "SHAPE",
        "l1": "LINE",
        "i1": "IMAGE",
    }
    assert graph.get("s1") is not None
    assert graph.get("s1").bbox == (1.0, 2.0, 3.0, 4.0)

    events.clear()
    _commit(bus, "ADD_STROKE", {})
    generated = events[0][1]["node"].node_id
    assert UUID(generated).version == 4


def test_delete_emits_none_node_and_deleted_node_id(bus: EventBus, graph: SceneGraph) -> None:
    graph.insert(_node("gone", (0.0, 0.0, 1.0, 1.0)))
    events = _spy(bus)
    _commit(bus, "DELETE_NODE", {"node_id": "gone"})
    assert len(events) == 1
    name, payload = events[0]
    assert name == "COMMITTED_NODE"
    assert payload == {"node": None, "deleted_node_id": "gone"}
    assert graph.get("gone") is None

    # Deleting an unknown id is a silent no-op (no event, no command).
    events.clear()
    _commit(bus, "DELETE_NODE", {"node_id": "missing"})
    assert events == []
    drained = 0
    while graph.undo():
        drained += 1
    assert drained == 2  # insert(gone) + delete(gone) only — missing added none


def test_other_envelope_types_are_ignored(bus: EventBus, graph: SceneGraph) -> None:
    events = _spy(bus)
    bus.emit(RPC_MESSAGE, msg=_envelope("EXPORT_JOB", "START_EXPORT", {"job_id": "j"}))
    bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"path": "x"}))
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("ASSET_UPLOAD", "ASSET_START", {"transfer_id": "t", "filename": "f"}),
    )
    assert events == []
    assert graph.nodes() == []


def test_bbox_payload_wins_then_derived_from_pts_then_zeros(
    bus: EventBus, graph: SceneGraph
) -> None:
    _commit(
        bus, "ADD_STROKE",
        {"node_id": "p1", "bbox": [5.0, 6.0, 7.0, 8.0],
         "geometry": {"pts": [[0.0, 0.0], [100.0, 100.0]]}},
    )
    assert graph.get("p1").bbox == (5.0, 6.0, 7.0, 8.0)

    _commit(
        bus, "ADD_STROKE",
        {"node_id": "p2", "geometry": {"pts": [[10.0, 20.0], [30.0, 5.0]]}},
    )
    assert graph.get("p2").bbox == (10.0, 5.0, 30.0, 20.0)

    _commit(bus, "ADD_STROKE", {"node_id": "p3"})
    assert graph.get("p3").bbox == (0.0, 0.0, 0.0, 0.0)

    # The index uses the same derived boxes the brute force sees.
    found = {n.node_id for n in graph.query_bbox(10.0, 5.0, 30.0, 20.0)}
    assert "p2" in found


def test_undo_redo_insert_cycle_reemits_matching_sub_events(
    bus: EventBus, graph: SceneGraph
) -> None:
    node = _node("x", (0.0, 0.0, 10.0, 10.0))
    graph.insert(node)
    assert [n.node_id for n in graph.query_bbox(-10.0, -10.0, 10.0, 10.0)] == ["x"]

    events = _spy(bus)
    assert graph.undo() is True
    assert graph.query_bbox(-10.0, -10.0, 10.0, 10.0) == []
    assert graph.content_bounds() == _ZERO
    assert events == [("COMMITTED_NODE", {"node": None, "deleted_node_id": "x"})]

    events.clear()
    assert graph.redo() is True
    assert [n.node_id for n in graph.query_bbox(-10.0, -10.0, 10.0, 10.0)] == ["x"]
    assert len(events) == 1
    assert events[0][0] == "COMMITTED_NODE"
    assert events[0][1]["node"] is node  # add-style sub-event, same instance

    assert graph.undo() is True
    assert graph.undo() is False  # stack drained
    assert graph.redo() is True
    assert graph.redo() is False


def test_delete_undo_restores_queryable_node(bus: EventBus, graph: SceneGraph) -> None:
    graph.insert(_node("keep", (5.0, 5.0, 6.0, 6.0)))
    graph.delete("keep")
    assert graph.get("keep") is None

    assert graph.undo() is True
    assert graph.get("keep") is not None
    assert [n.node_id for n in graph.query_bbox(5.0, 5.0, 6.0, 6.0)] == ["keep"]

    assert graph.redo() is True
    assert graph.get("keep") is None
    assert graph.query_bbox(5.0, 5.0, 6.0, 6.0) == []


def test_style_change_is_undoable_and_reverts_queryable_bbox(
    bus: EventBus, graph: SceneGraph
) -> None:
    graph.insert(_node("s", (0.0, 0.0, 10.0, 10.0)))
    _commit(
        bus, "ADD_STROKE",
        {"node_id": "s", "bbox": [100.0, 100.0, 200.0, 200.0],
         "style": {"color": "#FF0000"}},
    )
    updated = graph.get("s")
    assert updated.bbox == (100.0, 100.0, 200.0, 200.0)
    assert updated.style.color == "#FF0000"
    assert [n.node_id for n in graph.query_bbox(100.0, 100.0, 200.0, 200.0)] == ["s"]

    assert graph.undo() is True
    reverted = graph.get("s")
    assert reverted.bbox == (0.0, 0.0, 10.0, 10.0)
    assert reverted.style.color == "#1E1E1E"
    assert graph.query_bbox(100.0, 100.0, 200.0, 200.0) == []
    assert [n.node_id for n in graph.query_bbox(0.0, 0.0, 10.0, 10.0)] == ["s"]

    assert graph.redo() is True
    assert graph.get("s").bbox == (100.0, 100.0, 200.0, 200.0)


def test_undo_cap_drops_oldest_beyond_max(graph: SceneGraph) -> None:
    for i in range(MAX_UNDO + 1):
        graph.insert(_node(f"n{i}", (float(i), 0.0, float(i) + 1.0, 1.0)))

    drained = 0
    while graph.undo():
        drained += 1
        assert drained <= MAX_UNDO
    assert drained == MAX_UNDO

    # The oldest command (n0) was dropped, so n0 alone survives.
    remaining = {n.node_id for n in graph.query_bbox(-10.0, -10.0, 1000.0, 10.0)}
    assert remaining == {"n0"}


def test_new_command_clears_redo(graph: SceneGraph) -> None:
    graph.insert(_node("a", (0.0, 0.0, 1.0, 1.0)))
    graph.insert(_node("b", (2.0, 2.0, 3.0, 3.0)))
    assert graph.undo() is True  # redo now holds b's insert
    assert graph.redo() is True
    assert graph.get("b") is not None
    assert graph.undo() is True

    graph.insert(_node("c", (4.0, 4.0, 5.0, 5.0)))  # fresh command clears redo
    assert graph.redo() is False
    assert graph.get("b") is None
    assert graph.get("c") is not None


def test_replace_all_clears_stacks_and_emits_nothing(
    bus: EventBus, graph: SceneGraph
) -> None:
    graph.insert(_node("old", (0.0, 0.0, 10.0, 10.0)))
    assert graph.undo() is True  # redo holds one command

    events = _spy(bus)
    graph.replace_all([_node("fresh", (5.0, 5.0, 6.0, 6.0), layer=3)])
    assert events == []  # Doc 10 open() must not pollute undo history or events
    assert graph.undo() is False
    assert graph.redo() is False
    assert [n.node_id for n in graph.nodes()] == ["fresh"]
    assert graph.content_bounds() == {"min_x": 5.0, "min_y": 5.0, "max_x": 6.0, "max_y": 6.0}


def test_nodes_sorted_by_layer_then_id_and_get(graph: SceneGraph) -> None:
    graph.insert(_node("b", (0.0, 0.0, 1.0, 1.0), layer=2))
    graph.insert(_node("z", (0.0, 0.0, 1.0, 1.0), layer=1))
    graph.insert(_node("a", (0.0, 0.0, 1.0, 1.0), layer=1))
    assert [n.node_id for n in graph.nodes()] == ["a", "z", "b"]
    assert graph.get("a").node_id == "a"
    assert graph.get("missing") is None


def test_concurrent_mutations_and_queries_share_the_rlock(graph: SceneGraph) -> None:
    # Collect pending garbage BEFORE the FFI window: a full generation-2
    # collection landing inside this test's rtree/ctypes calls crashes the
    # native heap on this stack (observed under full-suite load, round 4).
    gc.collect()
    errors: list[BaseException] = []

    def worker() -> None:
        try:
            for i in range(300):
                node_id = f"w{i % 50}"
                graph.insert(
                    _node(node_id, (float(i), float(i), float(i) + 5.0, float(i) + 5.0))
                )
                graph.query_bbox(0.0, 0.0, 400.0, 400.0)
                if i % 3 == 0:
                    graph.delete(node_id)
        except BaseException as exc:  # noqa: BLE001 - collected for the assertion
            errors.append(exc)

    def reader() -> None:
        try:
            for _ in range(600):
                graph.query_bbox(-10.0, -10.0, 1000.0, 1000.0)
                bounds = graph.content_bounds()
                assert set(bounds) == {"min_x", "min_y", "max_x", "max_y"}
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=worker), threading.Thread(target=reader)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == []

    # No torn bounds: the reported union matches a brute-force fold.
    survivors = graph.nodes()
    bounds = graph.content_bounds()
    if not survivors:
        assert bounds == _ZERO
    else:
        assert bounds == {
            "min_x": min(n.bbox[0] for n in survivors),
            "min_y": min(n.bbox[1] for n in survivors),
            "max_x": max(n.bbox[2] for n in survivors),
            "max_y": max(n.bbox[3] for n in survivors),
        }
