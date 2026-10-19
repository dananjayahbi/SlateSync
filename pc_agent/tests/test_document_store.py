"""Tests for the ``.slatesync`` DocumentStore (Doc 10 §6).

Covers new()/save()/open() roundtrips (unicode + byte-stable keys), asset
embedding over the RPC chunk flow, dirty-only autosave, atomic no-``.tmp``
saves, the OPEN_CANVAS lifecycle contract and abort semantics.
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import uuid
import zipfile
from pathlib import Path
from typing import NamedTuple

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    COMMITTED_NODE,
    DOCUMENT_LOADED,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.engine.document_store import Artboard, CanvasDocument, DocumentStore
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle, SceneGraph

_ZERO = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}
_DOC_JSON = "document.json"


class _Env(NamedTuple):
    bus: EventBus
    config: AppConfig
    graph: SceneGraph
    store: DocumentStore


class _FrozenTime:
    """Deterministic clock for byte-stability assertions."""

    @staticmethod
    def time() -> float:
        return 1760760000.0


@pytest.fixture
def env(tmp_path: Path) -> _Env:
    bus = EventBus()
    config = AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )
    graph = SceneGraph(bus)
    store = DocumentStore(bus, config, graph)
    return _Env(bus=bus, config=config, graph=graph, store=store)


def _envelope(
    envelope_type: str, action: str, payload: dict, canvas_id: str = "cv-test"
) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": envelope_type,
        "action": action,
        "canvas_id": canvas_id,
        "payload": payload,
        "timestamp": 1760760000,
    }


def _element(
    node_id: str,
    bbox: tuple[float, float, float, float],
    layer: int = 0,
    kind: str = "STROKE",
    style: NodeStyle | None = None,
    geometry: NodeGeometry | None = None,
) -> CanvasNode:
    return CanvasNode(
        node_id=node_id,
        kind=kind,
        layer=layer,
        bbox=bbox,
        style=style or NodeStyle(),
        geometry=geometry or NodeGeometry(),
    )


def _read_doc_json(path: Path) -> bytes:
    with zipfile.ZipFile(path, "r") as archive:
        return archive.read(_DOC_JSON)


@pytest.mark.parametrize(
    ("preset", "width", "height", "is_infinite"),
    [
        ("A5", 1748.0, 2480.0, False),
        ("A4", 2480.0, 3508.0, False),
        ("LETTER", 2550.0, 3300.0, False),
        ("INFINITE", None, None, True),
    ],
)
def test_new_seeds_preset_dimensions_and_defaults(
    env: _Env, preset: str, width: float | None, height: float | None, is_infinite: bool
) -> None:
    doc = env.store.new(preset, "Untitled")
    assert doc.artboard.preset == preset
    assert doc.artboard.width == width
    assert doc.artboard.height == height
    assert doc.artboard.is_infinite is is_infinite
    assert doc.artboard.background_style == "BLANK"
    assert doc.artboard.background_color == "#FFFFFF"
    assert doc.created_at == doc.updated_at
    assert isinstance(doc.created_at, int)
    assert uuid.UUID(doc.canvas_id).version == 4
    assert doc.content_bounds == _ZERO
    assert doc.elements == []
    assert env.store.is_dirty is True
    assert env.store.current_path == (
        env.config.appdata_dir / "canvases" / f"{doc.canvas_id}.slatesync"
    )
    # Scene graph reset + artboard bound.
    assert env.graph.nodes() == []


def test_new_rejects_unknown_preset(env: _Env) -> None:
    with pytest.raises(ValueError):
        env.store.new("A3", "nope")


def test_save_open_roundtrip_unicode_and_scene_rebuild(env: _Env) -> None:
    bus, _config, graph, store = env
    doc = store.new("A4", "控制论 Lecture ✨")
    doc.artboard.background_style = "RULED"
    graph.insert(
        _element(
            "n1",
            (120.0, 300.0, 450.0, 620.0),
            layer=2,
            style=NodeStyle(color="#FF0000", stroke_width=4.0, opacity=0.5,
                            blend_mode="MULTIPLY"),
            geometry=NodeGeometry(pts=[[120.4, 301.2], [124.8, 309.5]]),
        )
    )
    graph.insert(
        _element(
            "n0",
            (-10.0, -20.0, 0.0, 0.0),
            layer=0,
            kind="GRAPH_AXES",
            geometry=NodeGeometry(pts=[], shape_type="CARTESIAN_2D",
                                  graph_config={"grid_step": 25.0}),
        )
    )

    path = store.save(doc)
    assert path == store.current_path
    assert list(path.parent.glob("*.tmp")) == []
    raw = _read_doc_json(path)
    assert "控制论 Lecture ✨".encode("utf-8") in raw  # ensure_ascii=False

    loaded = store.open(path)
    assert loaded.canvas_id == doc.canvas_id
    assert loaded.title == doc.title
    assert loaded.created_at == doc.created_at
    assert loaded.updated_at == doc.updated_at
    assert loaded.artboard == doc.artboard
    assert loaded.content_bounds == doc.content_bounds
    assert loaded.elements == doc.elements
    assert loaded.content_bounds == {
        "min_x": -10.0, "min_y": -20.0, "max_x": 450.0, "max_y": 620.0,
    }
    assert store.is_dirty is False
    assert store.current_path == path

    # open() rebuilt the injected scene graph, sorted (layer, node_id).
    assert [n.node_id for n in graph.nodes()] == ["n0", "n1"]
    assert graph.query_bbox(-10.0, -20.0, 450.0, 620.0) != []

    # open() shares the live artboard instance → UPGRADE_SIZE mutates the doc.
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("ARTBOARD_RESIZE", "UPGRADE_SIZE", {"preset": "INFINITE"}),
    )
    assert loaded.artboard.preset == "INFINITE"
    assert loaded.artboard.width is None and loaded.artboard.height is None
    assert loaded.artboard.is_infinite is True


def test_second_save_is_byte_stable_with_frozen_clock(
    env: _Env, monkeypatch: pytest.MonkeyPatch
) -> None:
    _bus, _config, graph, store = env
    doc = store.new("A5", "Stable ✨")
    graph.insert(_element("s", (1.0, 2.0, 3.0, 4.0)))
    monkeypatch.setattr("pc_agent.engine.document_store.time", _FrozenTime)

    path = store.save(doc)
    first = _read_doc_json(path)
    loaded = store.open(path)
    path2 = store.save(loaded)
    second = _read_doc_json(path2)
    assert path2 == path
    assert first == second  # identical JSON bytes, incl. key order


def test_document_json_key_order_is_frozen(env: _Env) -> None:
    _bus, _config, graph, store = env
    doc = store.new("A4", "Keys")
    path = store.save(doc)
    data = json.loads(_read_doc_json(path))
    assert list(data) == [
        "canvas_id", "title", "created_at", "updated_at", "artboard",
        "content_bounds", "elements",
    ]
    assert list(data["artboard"]) == [
        "preset", "width", "height", "is_infinite", "background_style",
        "background_color",
    ]
    assert list(data["content_bounds"]) == ["min_x", "min_y", "max_x", "max_y"]

    graph.insert(_element("e", (1.0, 2.0, 3.0, 4.0)))
    path = store.save(doc)
    data = json.loads(_read_doc_json(path))
    element = data["elements"][0]
    assert list(element) == ["node_id", "kind", "layer", "bbox", "style", "geometry"]
    assert list(element["style"]) == ["color", "stroke_width", "opacity", "blend_mode"]
    assert list(element["geometry"]) == ["pts", "shape_type", "graph_config", "asset_ref"]


def test_asset_upload_flow_embeds_and_reextracts(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A4", "Assets")
    canvas_id = doc.canvas_id
    payload_png = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 8
    half = len(payload_png) // 2
    chunks = [payload_png[:half], payload_png[half:]]
    b64_chunks = [base64.b64encode(c).decode("ascii") for c in chunks]

    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
            "transfer_id": "t1", "filename": "img_9921.png",
            "total_chunks": 2, "size_bytes": len(payload_png),
        }, canvas_id=canvas_id),
    )
    # Out-of-order delivery is explicitly allowed.
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "t1", "index": 1, "data_b64": b64_chunks[1],
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "img_9921.png").exists()
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "t1", "index": 0, "data_b64": b64_chunks[0],
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "img_9921.png").exists()

    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "t1", "ok": True,
    }, canvas_id=canvas_id))
    assert (store.assets_dir(canvas_id) / "img_9921.png").read_bytes() == payload_png

    path = store.save(doc)
    with zipfile.ZipFile(path, "r") as archive:
        assert "assets/img_9921.png" in archive.namelist()
        assert archive.read("assets/img_9921.png") == payload_png

    # Fresh store (same config) → open() re-extracts; asset_path bytes match.
    bus2 = EventBus()
    graph2 = SceneGraph(bus2)
    store2 = DocumentStore(bus2, env.config, graph2)
    loaded = store2.open(path)
    assert loaded.canvas_id == canvas_id
    assert store2.asset_path(canvas_id, "assets/img_9921.png").read_bytes() == payload_png


def test_unicode_asset_filename_roundtrips(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A5", "Unicode assets")
    canvas_id = doc.canvas_id
    blob = "图片✨ payload".encode("utf-8")
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
        "transfer_id": "u1", "filename": "图片✨.png",
        "total_chunks": 1, "size_bytes": len(blob),
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "u1", "index": 0,
        "data_b64": base64.b64encode(blob).decode("ascii"),
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "u1", "ok": True,
    }, canvas_id=canvas_id))
    assert (store.assets_dir(canvas_id) / "图片✨.png").read_bytes() == blob

    path = store.save(doc)
    with zipfile.ZipFile(path, "r") as archive:
        assert archive.read("assets/图片✨.png") == blob


def test_asset_path_uses_basename_and_assets_dir_is_lazy(env: _Env) -> None:
    store = env.store
    assert store.asset_path("cv1", "assets/img_9921.png") == (
        store.assets_dir("cv1") / "img_9921.png"
    )
    lazy = env.config.assets_dir / "cv-lazy"
    assert not lazy.exists()
    store.assets_dir("cv-lazy")
    assert lazy.is_dir()


def test_autosave_noop_when_clean_then_saves_when_dirty(env: _Env) -> None:
    _bus, _config, graph, store = env
    doc = store.new("A5", "Auto")
    path = store.save(doc)
    before_bytes = path.read_bytes()
    before_mtime = path.stat().st_mtime_ns

    store.autosave_tick()  # clean → untouched
    assert path.read_bytes() == before_bytes
    assert path.stat().st_mtime_ns == before_mtime
    assert store.is_dirty is False

    # A committed node marks dirty through the COMMITTED_NODE subscription.
    graph.insert(_element("late", (0.0, 0.0, 10.0, 10.0)))
    assert store.is_dirty is True

    store.autosave_tick()
    assert store.is_dirty is False
    data = json.loads(_read_doc_json(path))
    assert [e["node_id"] for e in data["elements"]] == ["late"]
    assert data["content_bounds"] == {
        "min_x": 0.0, "min_y": 0.0, "max_x": 10.0, "max_y": 10.0,
    }


def test_autosave_without_current_state_is_noop(env: _Env) -> None:
    _bus, config, _graph, store = env
    store.autosave_tick()  # no doc, no path → no file, no dirs, no exception
    assert store.current_path is None
    assert not config.appdata_dir.exists()


def test_save_leaves_no_tmp_residue(env: _Env) -> None:
    _bus, _config, graph, store = env
    doc = store.new("A4", "Tidy")
    path = store.save(doc)
    graph.insert(_element("x", (0.0, 0.0, 1.0, 1.0)))
    store.save(doc)  # overwrite in place
    assert list(path.parent.glob("*.tmp")) == []
    assert path.exists()


def test_failed_replace_keeps_original_clears_nothing(
    env: _Env, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    _bus, _config, graph, store = env
    doc = store.new("A4", "Crash")
    path = store.save(doc)
    original = path.read_bytes()
    graph.insert(_element("extra", (0.0, 0.0, 5.0, 5.0)))  # dirty again
    assert store.is_dirty is True

    class _FailingOs:
        @staticmethod
        def replace(src: str, dst: str) -> None:
            raise OSError("simulated crash mid-save")

    monkeypatch.setattr("pc_agent.engine.document_store.os", _FailingOs)
    with caplog.at_level(logging.ERROR, logger="slatesync.store"):
        with pytest.raises(OSError):
            store.save(doc)

    assert path.read_bytes() == original  # original archive untouched
    assert list(path.parent.glob("*.tmp")) == []  # tmp residue removed
    assert store.is_dirty is True  # failure never clears the dirty flag
    assert any("failed" in r.getMessage() for r in caplog.records)


def test_open_canvas_via_bus_emits_document_loaded_once_clean(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A4", "Lifecycle")
    path = store.save(doc)

    observed: list[tuple[CanvasDocument, bool]] = []
    bus.on(DOCUMENT_LOADED, lambda doc: observed.append((doc, store.is_dirty)))

    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"path": str(path)}),
    )
    assert len(observed) == 1
    loaded, dirty_before_emit = observed[0]
    assert loaded.canvas_id == doc.canvas_id
    assert dirty_before_emit is False  # state clean BEFORE emit
    assert store.current_path == path
    assert store.is_dirty is False


def test_open_canvas_without_path_logs_and_keeps_state(
    env: _Env, caplog: pytest.LogCaptureFixture
) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A5", "Keep")
    saved_path = store.current_path
    seen: list[dict] = []
    bus.on(DOCUMENT_LOADED, lambda **kw: seen.append(kw))

    with caplog.at_level(logging.ERROR, logger="slatesync.store"):
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"canvas_id": doc.canvas_id}),
        )
    assert seen == []
    assert store.current_path == saved_path
    assert store.is_dirty is True
    assert any("payload.path" in r.getMessage() for r in caplog.records)


def test_malformed_archives_raise_state_unchanged_and_bus_survives(
    env: _Env, tmp_path: Path
) -> None:
    bus, _config, _graph, store = env
    seen: list[dict] = []
    bus.on(DOCUMENT_LOADED, lambda **kw: seen.append(kw))

    bad = tmp_path / "bad.slatesync"
    bad.write_bytes(b"this is not a zip archive")
    hollow = tmp_path / "hollow.slatesync"
    with zipfile.ZipFile(hollow, "w") as archive:
        archive.writestr("readme.txt", "no document here")

    store.new("A4", "Untouched")
    saved_path = store.current_path

    with pytest.raises(Exception):
        store.open(bad)
    with pytest.raises(ValueError):
        store.open(hollow)
    assert seen == []
    assert store.current_path == saved_path
    assert store.is_dirty is True

    # The bus-level wrapper catches and logs — the subscriber chain survives.
    bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_LIFECYCLE", "OPEN_CANVAS", {"path": str(bad)}),
    )
    assert seen == []
    assert store.current_path == saved_path


def test_asset_done_ok_false_discards_buffer(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A4", "Abort")
    canvas_id = doc.canvas_id
    blob = b"0123456789"
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
        "transfer_id": "t1", "filename": "aborted.png",
        "total_chunks": 1, "size_bytes": len(blob),
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "t1", "index": 0,
        "data_b64": base64.b64encode(blob).decode("ascii"),
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "t1", "ok": False,
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "aborted.png").exists()

    # Buffer was discarded → a retried DONE finds nothing and writes nothing.
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "t1", "ok": True,
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "aborted.png").exists()


def test_asset_done_size_mismatch_discards(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A4", "Mismatch")
    canvas_id = doc.canvas_id
    blob = b"0123456789"
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
        "transfer_id": "t2", "filename": "wrong.png",
        "total_chunks": 1, "size_bytes": 999,  # lies about the size
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "t2", "index": 0,
        "data_b64": base64.b64encode(blob).decode("ascii"),
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "t2", "ok": True,
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "wrong.png").exists()


def test_oversized_chunk_discards_transfer(env: _Env) -> None:
    bus, _config, _graph, store = env
    doc = store.new("A4", "Cap")
    canvas_id = doc.canvas_id
    oversized = base64.b64encode(b"x" * (262144 + 1)).decode("ascii")
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
        "transfer_id": "t3", "filename": "big.bin",
        "total_chunks": 1, "size_bytes": 262145,
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
        "transfer_id": "t3", "index": 0, "data_b64": oversized,
    }, canvas_id=canvas_id))
    bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
        "transfer_id": "t3", "ok": True,
    }, canvas_id=canvas_id))
    assert not (store.assets_dir(canvas_id) / "big.bin").exists()


def test_open_payload_roundtrip_replaces_scene_clean_and_emits(env: _Env) -> None:
    """Round 4 (Doc 02 §8.2): wire dict → same rebuild path as open() minus ZIP."""
    bus, _config, graph, store = env
    doc = store.new("A4", "Wire")
    graph.insert(_element("n-wire", (10.0, 20.0, 30.0, 40.0)))
    path = store.save(doc)
    payload = json.loads(_read_doc_json(path).decode("utf-8"))
    assert payload["canvas_id"] == doc.canvas_id

    # Diverge first: another preset, another node, a dirty flag — open_payload
    # must replace ALL of it (scene, artboard, current, clean state).
    store.new("A5", "Other")
    graph.insert(_element("n-old", (1.0, 1.0, 2.0, 2.0)))
    store._mark_dirty()
    assert store.is_dirty is True

    observed: list[tuple[CanvasDocument, bool]] = []
    bus.on(DOCUMENT_LOADED, lambda doc: observed.append((doc, store.is_dirty)))

    loaded = store.open_payload(payload)

    # Roundtrip: the rebuilt document equals the saved document.json body.
    assert loaded.canvas_id == doc.canvas_id
    assert loaded.title == "Wire"
    assert loaded.artboard == doc.artboard
    assert loaded.content_bounds == doc.content_bounds
    assert [n.node_id for n in loaded.elements] == ["n-wire"]
    # Scene replacement: the A5 doc's node is gone, the wire elements are in.
    assert [n.node_id for n in graph.nodes()] == ["n-wire"]
    assert graph._artboard is loaded.artboard  # noqa: SLF001 — artboard binding
    # Clean + no PC-local path (a tablet canvas is never autosaved).
    assert store.is_dirty is False
    assert store.current_path is None
    # DOCUMENT_LOADED exactly once, state clean BEFORE the emit.
    assert observed == [(loaded, False)]


def test_open_payload_rejects_non_document_without_state_change(env: _Env) -> None:
    bus, _config, _graph, store = env
    store.new("A4", "Kept")
    seen: list[dict] = []
    bus.on(DOCUMENT_LOADED, lambda **kw: seen.append(kw))

    with pytest.raises(ValueError):
        store.open_payload("not-a-dict")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        store.open_payload({"canvas_id": "x"})  # missing required keys

    assert seen == []
    assert store.is_dirty is True
    assert store.current_path is not None  # untouched


def test_save_without_any_path_raises_value_error(env: _Env) -> None:
    bus, config, _graph, store = env
    bus.emit(COMMITTED_NODE, node=None)  # dirty via subscription, no document yet
    assert store.is_dirty is True
    doc = CanvasDocument(
        canvas_id="orphan", title="t", created_at=1, updated_at=1,
        artboard=Artboard(preset="A4"), content_bounds=dict(_ZERO), elements=[],
    )
    with pytest.raises(ValueError):
        store.save(doc)
    assert store.is_dirty is True
    assert not config.appdata_dir.exists()  # no file written anywhere


def test_autosave_racing_asset_done_never_interleaves_zip_writes(env: _Env) -> None:
    bus, config, graph, store = env
    doc = store.new("A4", "Race")
    path = store.save(doc)
    errors: list[BaseException] = []

    def autosaver() -> None:
        try:
            for i in range(40):
                graph.insert(_element(f"r{i}", (float(i), 0.0, float(i) + 1.0, 1.0)))
                store.autosave_tick()
        except BaseException as exc:  # noqa: BLE001 - collected for assertion
            errors.append(exc)

    def asset_writer() -> None:
        try:
            for i in range(40):
                blob = b"race" * (i + 1)
                bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_START", {
                    "transfer_id": f"race{i}", "filename": f"race{i}.bin",
                    "total_chunks": 1, "size_bytes": len(blob),
                }, canvas_id="other-cv"))
                bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_CHUNK", {
                    "transfer_id": f"race{i}", "index": 0,
                    "data_b64": base64.b64encode(blob).decode("ascii"),
                }, canvas_id="other-cv"))
                bus.emit(RPC_MESSAGE, msg=_envelope("ASSET_UPLOAD", "ASSET_DONE", {
                    "transfer_id": f"race{i}", "ok": True,
                }, canvas_id="other-cv"))
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [
        threading.Thread(target=autosaver),
        threading.Thread(target=asset_writer),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert list(path.parent.glob("*.tmp")) == []
    with zipfile.ZipFile(path, "r") as archive:
        assert archive.testzip() is None  # archive fully consistent
    assert len(list((config.assets_dir / "other-cv").glob("race*.bin"))) == 40
