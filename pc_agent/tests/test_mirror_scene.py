"""Round 7 — ``MirrorScene`` (issue 06: live mirrored element registry)."""

from __future__ import annotations

from dataclasses import dataclass

from pc_agent.viewport.mirror_scene import MirrorArtboard, MirrorScene


@dataclass
class _Node:
    node_id: str
    kind: str = "SHAPE"
    layer: int = 0
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 10.0, 10.0)


def test_reset_replaces_everything_and_sorts_by_layer_then_id() -> None:
    scene = MirrorScene()
    scene.reset([_Node("b", layer=2), _Node("a", layer=1), _Node("c", layer=1)])
    assert [node.node_id for node in scene.nodes()] == ["a", "c", "b"]
    assert len(scene) == 3

    scene.reset([_Node("only")])
    assert [node.node_id for node in scene.nodes()] == ["only"]

    scene.reset(None)  # None ⇒ empty (document closed)
    assert scene.nodes() == []
    assert len(scene) == 0


def test_upsert_replaces_same_id_and_ignores_none() -> None:
    scene = MirrorScene()
    scene.upsert(_Node("n1", kind="STROKE"))
    scene.upsert(_Node("n1", kind="SHAPE"))
    scene.upsert(None)  # tolerated
    nodes = scene.nodes()
    assert len(nodes) == 1 and nodes[0].kind == "SHAPE"


def test_remove_and_clear_are_idempotent() -> None:
    scene = MirrorScene()
    scene.reset([_Node("a"), _Node("b")])
    scene.remove("a")
    scene.remove("a")  # second remove is a no-op
    scene.remove(None)
    assert [node.node_id for node in scene.nodes()] == ["b"]
    scene.clear()
    assert len(scene) == 0


def test_bounds_union_and_empty_fallback() -> None:
    scene = MirrorScene()
    assert scene.bounds() == {
        "min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0,
    }
    scene.reset([
        _Node("a", bbox=(10.0, 20.0, 30.0, 40.0)),
        _Node("b", bbox=(-5.0, 0.0, 5.0, 60.0)),
    ])
    assert scene.bounds() == {
        "min_x": -5.0, "min_y": 0.0, "max_x": 30.0, "max_y": 60.0,
    }


def test_nodes_without_ids_or_bboxes_are_tolerated() -> None:
    class _Anon:
        kind = "SHAPE"

    scene = MirrorScene()
    scene.upsert(_Anon())  # no node_id / bbox at all
    assert len(scene) == 1
    assert scene.bounds() == {
        "min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0,
    }


def test_mirror_artboard_is_an_infinite_white_board() -> None:
    board = MirrorArtboard()
    assert board.is_infinite is True
    assert board.background_color == "#FFFFFF"
    assert board.width is None and board.height is None
