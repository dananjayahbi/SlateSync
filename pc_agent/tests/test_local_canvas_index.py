"""Round 5 (Doc 02 §9.3) — LocalCanvasIndex: hub dir layout, index.json CRUD,
atomic writes, the LWW guard matrix and DocumentStore ZIP-IO delegation."""

from __future__ import annotations

import json
import os
import zipfile
from pathlib import Path

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import DOCUMENT_LOADED, EventBus
from pc_agent.engine.document_store import CanvasDocument, DocumentStore
from pc_agent.engine.local_canvas_index import (
    LWW_APPLY,
    LWW_KEEP,
    LWW_REJECT,
    LocalCanvasIndex,
)
from pc_agent.engine.scene_graph import SceneGraph


class _Env:
    def __init__(self, tmp_path: Path) -> None:
        self.bus = EventBus()
        self.config = AppConfig(
            shader_dir=tmp_path / "shaders",
            assets_dir=tmp_path / "assets",
            export_dir=tmp_path / "exports",
            appdata_dir=tmp_path / "appdata",
        )
        self.graph = SceneGraph(self.bus)
        self.store = DocumentStore(self.bus, self.config, self.graph)
        self.index = LocalCanvasIndex(
            self.store, self.config.appdata_dir / "canvases"
        )
        self.store.attach_index(self.index)


@pytest.fixture
def env(tmp_path: Path) -> _Env:
    return _Env(tmp_path)


def _doc(env: _Env, *, canvas_id: str, updated_at: int, title: str = "Note",
         preset: str = "A4", background: str = "RULED") -> CanvasDocument:
    doc = env.store.new(preset, title)
    doc.canvas_id = canvas_id
    doc.created_at = 1000
    doc.updated_at = updated_at
    doc.artboard.background_style = background
    return doc


def _row_ids(env: _Env) -> list[str]:
    return [row["id"] for row in env.index.list()]


# ---------------------------------------------------------------------------
# save_document: ZIP via the store + row upsert
# ---------------------------------------------------------------------------


def test_save_document_writes_archive_and_row_with_exact_fields(env: _Env) -> None:
    doc = _doc(env, canvas_id="c-1", updated_at=1760760000)
    path = env.index.save_document(doc, source="hub")

    assert path == env.index.directory / "c-1.slatesync"
    assert path.is_file()
    with zipfile.ZipFile(path) as archive:
        body = json.loads(archive.read("document.json"))
    assert body["canvas_id"] == "c-1"
    assert body["updated_at"] == 1760760000  # NOT re-stamped (LWW authority)

    rows = env.index.list()
    assert rows == [
        {
            "id": "c-1",
            "title": "Note",
            "preset": "A4",
            "background": "RULED",
            "updated_at": 1760760000,
            "source_devices": ["hub"],
        }
    ]


def test_list_sorted_updated_at_desc_get_and_load(env: _Env) -> None:
    env.index.save_document(_doc(env, canvas_id="c-old", updated_at=1000), source="hub")
    env.index.save_document(_doc(env, canvas_id="c-new", updated_at=2000), source="dev-1")

    assert _row_ids(env) == ["c-new", "c-old"]
    assert env.index.get("c-new")["title"] == "Note"
    assert env.index.get("nope") is None

    loaded = env.index.load("c-old")
    assert isinstance(loaded, CanvasDocument)
    assert loaded.canvas_id == "c-old"
    assert loaded.updated_at == 1000
    assert env.index.load("nope") is None  # missing file → None, never raises


def test_load_never_switches_the_open_document(env: _Env) -> None:
    loaded_events: list[dict] = []
    env.bus.on(DOCUMENT_LOADED, lambda **payload: loaded_events.append(payload))
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    focus_before = env.store.current_path
    dirty_before = env.store.is_dirty

    assert env.index.load("c-1") is not None
    assert loaded_events == []
    assert env.store.current_path == focus_before  # focus untouched (focus=False)
    assert env.store.is_dirty is dirty_before


def test_source_devices_union_dedupes_and_preserves_order(env: _Env) -> None:
    doc = _doc(env, canvas_id="c-1", updated_at=1000)
    env.index.save_document(doc, source="dev-1")
    env.index.save_document(doc, source="dev-1")  # duplicate → no second entry
    env.index.save_document(doc, source="hub")
    assert env.index.get("c-1")["source_devices"] == ["dev-1", "hub"]


def test_remove_deletes_archive_and_row(env: _Env) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    path = env.index.archive_path("c-1")

    assert env.index.remove("c-1") is True
    assert not path.exists()
    assert env.index.get("c-1") is None
    assert env.index.remove("c-1") is False  # idempotent


# ---------------------------------------------------------------------------
# LWW guard (§9.1): apply / keep / reject
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("incoming", "expected"),
    [(1500, LWW_APPLY), (1000, LWW_KEEP), (999, LWW_REJECT)],
    ids=["newer", "equal", "older"],
)
def test_lww_decision_matrix(env: _Env, incoming: int, expected: str) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    assert env.index.lww_decision("c-1", incoming) == expected


def test_lww_decision_unknown_id_always_applies(env: _Env) -> None:
    assert env.index.lww_decision("ghost", 0) == LWW_APPLY


def test_save_document_if_newer_gate(env: _Env) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000), source="hub")
    path = env.index.archive_path("c-1")
    before_zip = path.read_bytes()
    before_row = env.index.get("c-1")

    # Equal → keep local, no churn: nothing rewritten, row untouched.
    equal = _doc(env, canvas_id="c-1", updated_at=1000, title="Renamed clone")
    assert env.index.save_document_if_newer(equal) is None
    # Older → rejected outright.
    older = _doc(env, canvas_id="c-1", updated_at=999, title="Stale")
    assert env.index.save_document_if_newer(older) is None
    assert path.read_bytes() == before_zip
    assert env.index.get("c-1") == before_row

    # Newer → stored with its own timestamp.
    newer = _doc(env, canvas_id="c-1", updated_at=1500, title="Fresh")
    assert env.index.save_document_if_newer(newer, source="dev-2") == path
    row = env.index.get("c-1")
    assert row["updated_at"] == 1500
    assert row["title"] == "Fresh"
    assert row["source_devices"] == ["hub", "dev-2"]


# ---------------------------------------------------------------------------
# Atomicity + corruption tolerance
# ---------------------------------------------------------------------------


def test_saves_leave_no_tmp_residue(env: _Env) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    env.index.save_document(_doc(env, canvas_id="c-2", updated_at=2000))
    residue = [p.name for p in env.index.directory.glob("*.tmp")]
    assert residue == []


def test_archive_failure_leaves_index_untouched_and_no_tmp(
    env: _Env, monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(env.store, "write_archive", boom)
    with pytest.raises(OSError):
        env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))

    assert env.index.list() == []
    assert not env.index.archive_path("c-1").exists()
    assert [p.name for p in env.index.directory.glob("*.tmp")] == []


def test_index_flush_failure_unlinks_tmp_and_keeps_original(
    env: _Env, monkeypatch: pytest.MonkeyPatch
) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    original = env.index.index_path.read_bytes()

    real_replace = os.replace

    def boom(src, dst):
        if str(dst).endswith("index.json"):
            raise OSError("flush failed")
        return real_replace(src, dst)

    monkeypatch.setattr("pc_agent.engine.local_canvas_index.os.replace", boom)
    with pytest.raises(OSError):
        env.index.save_document(_doc(env, canvas_id="c-2", updated_at=2000))

    assert env.index.index_path.read_bytes() == original  # prior rows intact
    assert not env.index.index_path.with_name("index.json.tmp").exists()
    assert [p.name for p in env.index.directory.glob("*.tmp")] == []


def test_corrupted_index_json_tolerated_and_repaired(env: _Env) -> None:
    env.index.directory.mkdir(parents=True, exist_ok=True)
    env.index.index_path.write_text("{not json", encoding="utf-8")

    assert env.index.list() == []
    assert env.index.get("c-1") is None

    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000))
    assert _row_ids(env) == ["c-1"]  # repaired on the next flush


def test_row_without_id_is_dropped_on_read(env: _Env) -> None:
    env.index.directory.mkdir(parents=True, exist_ok=True)
    env.index.index_path.write_text(
        json.dumps([{"title": "orphan"}, {"id": "c-1", "updated_at": 5}]),
        encoding="utf-8",
    )
    rows = env.index.list()
    assert [row["id"] for row in rows] == ["c-1"]


# ---------------------------------------------------------------------------
# Layout contract
# ---------------------------------------------------------------------------


def test_default_directory_matches_appdata_contract() -> None:
    bus = EventBus()
    store = DocumentStore(bus, AppConfig(), SceneGraph(bus))
    expected = Path(os.environ.get("APPDATA", str(Path.home()))) / "SlateSync" / "canvases"
    assert LocalCanvasIndex(store).directory == expected
    assert LocalCanvasIndex(store, Path("x")).directory == Path("x")
