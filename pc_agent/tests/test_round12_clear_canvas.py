"""Round 12 — issue 11: clearing the canvas must clear the PC mirror.

Report: the tablet's "clear canvas" emptied the tablet but the PC mirror kept
showing every stroke.

The transport was never the problem - ``SceneGraph.apply_rpc`` handles
``CLEAR_CANVAS``, emits ``CANVAS_CLEARED``, and ``GLCanvasHost._on_canvas_cleared``
cleared ``self._scene``. The defect was in ``_draw``:

    nodes = self._scene.nodes()
    if not nodes:
        nodes = list(getattr(self._doc, "elements", None) or [])

An EMPTY scene was indistinguishable from "the scene has not been synced yet",
so the stale document snapshot was drawn straight back over the clear. Emptiness
is now meaningful: ``_scene_authoritative`` flips on the first scene sync and on
an explicit clear, and from then on the scene alone decides what paints.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import CANVAS_CLEARED, EventBus
from pc_agent.engine.document_store import DocumentStore
from pc_agent.engine.scene_graph import SceneGraph


class _FakeTk:
    """Minimal Tk stand-in: records ``after``, never fires it (headless)."""

    def __init__(self) -> None:
        self.scheduled: list[object] = []

    def after(self, _ms: int, callback: Any = None, *args: Any) -> str:
        self.scheduled.append(callback)
        return f"after#{len(self.scheduled)}"

    def after_cancel(self, _after_id: str) -> None:
        return None

#: One stroke, enough to prove the mirror is not empty before the clear.
_NODE: dict[str, Any] = {
    "node_id": "n-clear-1",
    "kind": "STROKE",
    "layer": 0,
    "bbox": [100.0, 100.0, 400.0, 300.0],
    "style": {
        "color": "#1E1E1E",
        "stroke_width": 4.0,
        "opacity": 1.0,
        "blend_mode": "SRC_OVER",
    },
    "geometry": {
        "pts": [[100.0, 100.0], [250.0, 200.0], [400.0, 300.0]],
        "shape_type": None,
        "graph_config": None,
        "asset_ref": None,
    },
}


def _canvas(canvas_id: str = "cv-clear") -> dict[str, Any]:
    return {
        "canvas_id": canvas_id,
        "title": canvas_id,
        "created_at": 1760760000,
        "updated_at": 1760760000,
        "artboard": {
            "preset": "A4",
            "width": 2480.0,
            "height": 3508.0,
            "is_infinite": False,
            "background_style": "BLANK",
            "background_color": "#FFFFFF",
            "background_spacing": 32.0,
        },
        "content_bounds": {
            "min_x": 100.0,
            "min_y": 100.0,
            "max_x": 400.0,
            "max_y": 300.0,
        },
        "elements": [_NODE],
    }


@pytest.fixture()
def env(tmp_path: Path) -> Any:
    bus = EventBus()
    config = AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    return bus, store, scene, config


def _cleared(bus: EventBus, canvas_id: str) -> None:
    bus.emit(
        CANVAS_CLEARED,
        canvas_id=canvas_id,
    )


# ---------------------------------------------------------------------------
# Store + scene: the authoritative element source empties
# ---------------------------------------------------------------------------
def test_clear_canvas_rpc_empties_the_scene(env: Any) -> None:
    from pc_agent.core.events import RPC_MESSAGE

    bus, store, scene, _config = env
    store.open_payload(_canvas())
    assert len(scene.nodes()) == 1

    bus.emit(
        RPC_MESSAGE,
        msg={
            "id": "rpc-clear",
            "type": "ELEMENT_COMMIT",
            "action": "CLEAR_CANVAS",
            "canvas_id": "cv-clear",
            "payload": {},
            "timestamp": 1760760001,
        },
    )
    assert len(scene.nodes()) == 0, "CLEAR_CANVAS must empty the mirrored scene"


def test_clear_emits_canvas_cleared(env: Any) -> None:
    from pc_agent.core.events import RPC_MESSAGE

    bus, store, _scene, _config = env
    store.open_payload(_canvas())
    seen: list[dict] = []
    bus.on(CANVAS_CLEARED, lambda **kw: seen.append(kw))

    bus.emit(
        RPC_MESSAGE,
        msg={
            "id": "rpc-clear",
            "type": "ELEMENT_COMMIT",
            "action": "CLEAR_CANVAS",
            "canvas_id": "cv-clear",
            "payload": {},
            "timestamp": 1760760001,
        },
    )
    assert seen, "the viewport needs CANVAS_CLEARED to drop its tessellated meshes"
    assert seen[-1]["canvas_id"] == "cv-clear"


# ---------------------------------------------------------------------------
# Viewport host: the DRAW decision (the actual defect)
# ---------------------------------------------------------------------------
def _host(env: Any) -> Any:
    """A GLCanvasHost on a fake Tk parent — no window, no GL context.

    Mirrors the harness in ``test_gl_canvas_host``/``test_pure_tk_embed``: the
    document/scene bookkeeping under test never touches GL, so the GL guards
    simply leave ``_ctx``/``_primitive`` as ``None``.
    """
    from pc_agent.viewport.gl_canvas_host import GLCanvasHost

    bus, _store, _scene, config = env
    return GLCanvasHost(_FakeTk(), config, bus)


def test_fresh_host_still_uses_the_document_snapshot(env: Any) -> None:
    """The fallback must survive for the first frame of a freshly opened doc."""
    bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    assert host._scene_authoritative is True
    assert len(host._scene) == 1
    assert len(host._nodes_to_render()) == 1


def test_clear_makes_the_empty_scene_authoritative(env: Any) -> None:
    """Issue 11 — the regression itself, asserted at the draw decision."""
    bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    assert len(host._nodes_to_render()) == 1

    _cleared(bus, "cv-clear")

    assert len(host._scene) == 0
    assert host._scene_authoritative is True, (
        "an empty scene after a clear must NOT fall back to the stale snapshot"
    )
    assert host._nodes_to_render() == [], (
        "the frame must draw NOTHING after a clear; the whole defect was that "
        "the stale doc.elements snapshot was painted back over the clear"
    )


def test_clear_empties_the_document_snapshot_too(env: Any) -> None:
    """Defence in depth: a repaint cannot resurrect the cleared elements."""
    bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    _cleared(bus, "cv-clear")
    assert not host._doc.elements
    assert host._nodes_to_render() == []


def test_an_unsynced_empty_scene_still_falls_back(env: Any) -> None:
    """The bootstrap fallback must survive for a document never synced to a scene.

    This is the case the old emptiness check was written for, and it is why the
    fix keys off a FLAG rather than off emptiness.
    """
    _bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    host._scene.clear()  # scene lost its nodes...
    host._scene_authoritative = False  # ...and was never synced
    assert len(host._nodes_to_render()) == 1, "the snapshot is still the bootstrap"



def test_authoritative_empty_scene_beats_a_populated_snapshot(env: Any) -> None:
    """THE regression, isolated to the flag.

    ``test_clear_empties_the_document_snapshot_too`` empties ``doc.elements`` as
    well, which would make an empty result pass even with the buggy
    "is the scene empty?" test. This case keeps the snapshot POPULATED and only
    clears the scene, so the only thing that can suppress the nodes is
    ``_scene_authoritative``. That is exactly the state a ``CLEAR_CANVAS``
    produces if any later repaint repopulates the snapshot.
    """
    _bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    assert len(host._doc.elements) == 1, "precondition: snapshot is populated"

    host._scene.clear()  # the clear happens...
    host._scene_authoritative = True  # ...and the scene is the authority

    assert host._nodes_to_render() == [], (
        "an authoritative scene must win over a populated snapshot; keying the "
        "fallback on emptiness is the round-12 issue-11 defect"
    )


def test_clear_is_idempotent(env: Any) -> None:
    bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    _cleared(bus, "cv-clear")
    _cleared(bus, "cv-clear")
    assert len(host._scene) == 0
    assert not host._doc.elements


def test_clear_before_any_document_is_safe(env: Any) -> None:
    """A CLEAR_CANVAS can arrive before the first OPEN_CANVAS."""
    bus, _store, _scene, _config = env
    host = _host(env)
    assert host._doc is None
    _cleared(bus, "cv-clear")  # must not raise
    assert len(host._scene) == 0
    assert host._scene_authoritative is True


def test_closing_the_document_releases_authority(env: Any) -> None:
    """set_document(None) must re-open the snapshot fallback for the next doc."""
    bus, store, _scene, _config = env
    host = _host(env)
    host.set_document(store.open_payload(_canvas()))
    host.set_document(None)
    assert host._scene_authoritative is False
    assert host._artboard is None
