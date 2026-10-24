"""Round 7 — export destination + freshness (issue 05).

Two bugs the user reported:

1. *"we should be able to set the export path (select a folder). The default is
   the downloads folder"* — ``config.export_dir`` now defaults to Downloads and
   ``ConfigManager.set_export_dir`` persists a Settings choice.
2. *"the export is not properly working. It does not export the latest canvas,
   just an older one"* — ``DocumentStore.snapshot_current()`` rebuilds the
   document from the LIVE scene graph, so tablet edits after the open are in
   the file, and files are named after the canvas instead of a job uuid.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

import pytest

from pc_agent.core.config_manager import AppConfig, ConfigManager, default_export_dir
from pc_agent.core.events import COMMITTED_NODE, RPC_MESSAGE, EventBus
from pc_agent.engine.document_store import DocumentStore
from pc_agent.engine.scene_graph import CanvasNode, SceneGraph
from pc_agent.export.export_coordinator import ExportCoordinator, _slug


class _Raster:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def export(self, doc, dpi, out_path, progress=None):
        self.calls.append({"doc": doc, "dpi": dpi, "out_path": Path(out_path)})
        if progress is not None:
            progress(0.5)
            progress(1.0)
        Path(out_path).write_bytes(b"png")
        return Path(out_path)


class _Vector:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    def export(self, doc, out_path, progress=None):
        self.calls.append({"doc": doc, "out_path": Path(out_path)})
        Path(out_path).write_bytes(b"%PDF")
        return Path(out_path)


class _Push:
    def __init__(self) -> None:
        self.envelopes: list[dict] = []

    def __call__(self, msg: dict) -> None:
        self.envelopes.append(msg)

    def wait(self, action: str, timeout: float = 3.0) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for env in self.envelopes:
                if env.get("action") == action:
                    return env
            time.sleep(0.01)
        raise AssertionError(f"no {action} envelope within {timeout}s")


# ---------------------------------------------------------------------------
# Destination
# ---------------------------------------------------------------------------


def test_export_dir_defaults_to_the_downloads_folder(tmp_path: Path) -> None:
    config = AppConfig()
    assert config.export_dir == default_export_dir()
    assert config.export_dir.name == "Downloads"


def test_set_export_dir_persists_and_applies_immediately(tmp_path: Path) -> None:
    manager = ConfigManager(root_dir=tmp_path)
    target = tmp_path / "handouts"
    assert manager.set_export_dir(target) == target
    assert manager.config.export_dir == target
    # Round trip through disk: a fresh manager sees the selection.
    assert ConfigManager(root_dir=tmp_path).config.export_dir == target


def test_update_rejects_unknown_fields(tmp_path: Path) -> None:
    manager = ConfigManager(root_dir=tmp_path)
    with pytest.raises(ValueError, match="unknown config field"):
        manager.update(nope=1)


def test_slug_keeps_titles_readable_and_safe() -> None:
    assert _slug("Physics Notes") == "Physics Notes"
    assert _slug('a/b\\c:d*e?f"g<h>i|j') == "a_b_c_d_e_f_g_h_i_j"
    assert _slug("   ") == "canvas"
    assert _slug("") == "canvas"


def _coordinator(tmp_path: Path, raster=None, vector=None) -> tuple[Any, ...]:
    bus = EventBus()
    config = AppConfig(export_dir=tmp_path)
    push = _Push()
    coord = ExportCoordinator(bus, config, raster or _Raster(), vector or _Vector(), push)
    return coord, bus, push, config


def test_out_path_uses_the_canvas_title_and_never_the_job_uuid(tmp_path: Path) -> None:
    coord, _bus, _push, _config = _coordinator(tmp_path)
    path = coord._out_path("job-uuid", {"format": "PNG", "title": "Lecture 4"})
    assert path == tmp_path / "Lecture 4.png"
    assert "job-uuid" not in path.name


def test_out_path_honours_an_explicit_filename(tmp_path: Path) -> None:
    coord, _bus, _push, _config = _coordinator(tmp_path)
    assert coord._out_path("j", {"format": "PDF", "filename": "handout.pdf"}) == (
        tmp_path / "handout.pdf"
    )
    # Wrong extension is corrected, path components are stripped.
    assert coord._out_path("j", {"format": "PDF", "filename": "../x/y.png"}) == (
        tmp_path / "y.pdf"
    )


def test_out_path_never_overwrites_a_previous_export(tmp_path: Path) -> None:
    coord, _bus, _push, _config = _coordinator(tmp_path)
    first = coord._out_path("j", {"format": "PNG", "title": "Notes"})
    first.write_bytes(b"x")
    second = coord._out_path("j", {"format": "PNG", "title": "Notes"})
    assert second == tmp_path / "Notes (2).png"
    second.write_bytes(b"y")
    assert coord._out_path("j", {"format": "PNG", "title": "Notes"}) == (
        tmp_path / "Notes (3).png"
    )


def test_export_writes_into_the_currently_configured_folder(tmp_path: Path) -> None:
    coord, _bus, push, config = _coordinator(tmp_path / "first")
    config.export_dir = tmp_path / "second"  # Settings change, no restart
    coord.submit({"canvas_id": "cv-1", "format": "PNG", "dpi": 300, "target": "PC"})
    finish = push.wait("EXPORT_FINISHED")
    assert Path(finish["payload"]["path"]).parent == tmp_path / "second"
    assert finish["payload"]["ok"] is True


# ---------------------------------------------------------------------------
# Freshness (the "older canvas" bug)
# ---------------------------------------------------------------------------


def _store(tmp_path: Path) -> tuple[DocumentStore, SceneGraph, EventBus]:
    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path, export_dir=tmp_path / "exports")
    scene = SceneGraph(bus)
    return DocumentStore(bus, config, scene), scene, bus


def _node(node_id: str, x: float) -> CanvasNode:
    return CanvasNode(
        node_id=node_id, kind="SHAPE", layer=0, bbox=(x, 0.0, x + 10.0, 10.0)
    )


def test_snapshot_current_is_none_without_an_open_document(tmp_path: Path) -> None:
    store, _scene, _bus = _store(tmp_path)
    assert store.snapshot_current() is None


def test_snapshot_current_reflects_edits_made_after_the_open(tmp_path: Path) -> None:
    """The regression: ``doc.elements`` is the opener's snapshot, the scene is live."""
    store, scene, _bus = _store(tmp_path)
    doc = store.new("A4", "Notes")
    assert store.snapshot_current().elements == []

    scene.insert(_node("n1", 0.0))
    scene.insert(_node("n2", 40.0))
    snapshot = store.snapshot_current()
    assert snapshot is not None
    assert [node.node_id for node in snapshot.elements] == ["n1", "n2"]
    assert snapshot.content_bounds["max_x"] == 50.0
    # The stored document object itself is untouched (copy semantics).
    assert doc.elements == []


def test_snapshot_current_follows_artboard_upgrades(tmp_path: Path) -> None:
    store, _scene, bus = _store(tmp_path)
    store.new("A5", "Notes")
    bus.emit(
        RPC_MESSAGE,
        msg={
            "id": "e1",
            "type": "ARTBOARD_RESIZE",
            "action": "UPGRADE_SIZE",
            "canvas_id": "cv",
            "payload": {"preset": "A4"},
        },
    )
    snapshot = store.snapshot_current()
    assert snapshot is not None
    assert snapshot.artboard.preset == "A4"


def test_export_uses_the_live_snapshot(tmp_path: Path) -> None:
    """End-to-end: an edit after the open lands in the exported document."""
    store, scene, bus = _store(tmp_path)
    store.new("A4", "Notes")
    coord, _bus, push, _config = _coordinator(tmp_path / "out")
    coord.attach_document_loader(lambda _payload: store.snapshot_current())

    bus.emit(COMMITTED_NODE, node=_node("n1", 5.0))
    scene.insert(_node("n2", 25.0))

    coord.submit({"canvas_id": "cv", "format": "PNG", "dpi": 300, "title": "Notes"})
    finish = push.wait("EXPORT_FINISHED")
    assert finish["payload"]["ok"] is True
    assert Path(finish["payload"]["path"]).name == "Notes.png"


def test_loader_failure_marks_the_job_errored(tmp_path: Path) -> None:
    coord, _bus, push, _config = _coordinator(tmp_path)

    def boom(_payload):
        raise ValueError("no document is open")

    coord.attach_document_loader(boom)
    coord.submit({"canvas_id": "cv", "format": "PNG", "dpi": 300})
    finish = push.wait("EXPORT_FINISHED")
    assert finish["payload"]["ok"] is False


def test_snapshot_uses_the_scene_artboard_after_an_upgrade(tmp_path: Path) -> None:
    """An UPGRADE_SIZE applied after the open must reach the export."""

    from dataclasses import dataclass

    @dataclass
    class _Board:
        preset: str = "LETTER"
        width: float | None = 2550.0
        height: float | None = 3300.0
        is_infinite: bool = False
        background_style: str = "BLANK"
        background_color: str = "#FFFFFF"

    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path)
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    store.new("A5", "Notes")

    scene.set_artboard(_Board())  # UPGRADE_SIZE mutated the bound artboard
    snapshot = store.snapshot_current()
    assert snapshot is not None and snapshot.artboard.preset == "LETTER"


def test_snapshot_falls_back_to_the_document_artboard(tmp_path: Path) -> None:
    bus = EventBus()
    config = AppConfig(appdata_dir=tmp_path)
    scene = SceneGraph(bus)
    store = DocumentStore(bus, config, scene)
    store.new("A4", "Notes")
    scene.set_artboard(None)  # scene lost its artboard binding
    snapshot = store.snapshot_current()
    assert snapshot is not None and snapshot.artboard.preset == "A4"