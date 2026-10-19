"""Round 5 (Doc 02 §9.4) — CanvasSyncManager hub flows over a fake bus + push.

Covers: merge union-by-id + the LWW matrix (newer/older/equal), the device
registry keyed by ``device_id`` with the ``legacy-<conn>`` fallback,
pull/put request-response pairs, persist-on-open file creation, the hub list
broadcast after PUT, the PC File→New flow end-to-end, the devices-count
transitions, and 0-device read-only storage no-ops.
"""

from __future__ import annotations

import logging
import uuid
from pathlib import Path

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    CANVAS_LIST_UPDATED,
    CONNECTION_STATE,
    DOCUMENT_LOADED,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.engine.document_store import CanvasDocument, DocumentStore
from pc_agent.engine.local_canvas_index import LocalCanvasIndex
from pc_agent.engine.scene_graph import SceneGraph
from pc_agent.network.canvas_sync import CanvasSyncManager


class _PushSpy:
    def __init__(self) -> None:
        self.messages: list[dict] = []

    def __call__(self, msg: dict) -> None:
        self.messages.append(dict(msg))

    def of(self, action: str) -> list[dict]:
        return [m for m in self.messages if m.get("action") == action]


class _Hub:
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
        self.index = LocalCanvasIndex(self.store, self.config.appdata_dir / "canvases")
        self.store.attach_index(self.index)
        self.push = _PushSpy()
        self.manager = CanvasSyncManager(
            self.bus, self.config, self.push, self.store,
            index=self.index, pull_interval_s=0.0,  # synchronous sequential drain
        )
        self.events: list[dict] = []
        self.loaded: list[dict] = []
        self.bus.on(
            CANVAS_LIST_UPDATED, lambda **payload: self.events.append(dict(payload))
        )
        self.bus.on(DOCUMENT_LOADED, lambda **payload: self.loaded.append(dict(payload)))


@pytest.fixture
def env(tmp_path: Path) -> _Hub:
    return _Hub(tmp_path)


def _doc(
    env: _Hub, *, canvas_id: str, updated_at: int, title: str = "Note",
    preset: str = "A4", background: str = "RULED",
) -> CanvasDocument:
    doc = env.store.new(preset, title)
    doc.canvas_id = canvas_id
    doc.created_at = 1000
    doc.updated_at = updated_at
    doc.artboard.background_style = background
    return doc


def _row(canvas_id: str, updated_at: int, title: str = "Note") -> dict:
    return {
        "id": canvas_id,
        "title": title,
        "preset": "A4",
        "background": "RULED",
        "updated_at": updated_at,
    }


def _envelope(action: str, payload: dict) -> dict:
    return {
        "id": str(uuid.uuid4()),
        "type": "CANVAS_LIFECYCLE",
        "action": action,
        "canvas_id": "",
        "payload": payload,
        "timestamp": 1760760000,
    }


def _device_list(env: _Hub, rows: list[dict], device_id: str | None = "dev-1",
                 device_name: str | None = "Tablet", origin: str = "device") -> None:
    payload: dict = {"origin": origin, "canvases": rows}
    if device_id is not None:
        payload["device_id"] = device_id
    if device_name is not None:
        payload["device_name"] = device_name
    env.bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_LIST", payload))


def _merged(env: _Hub) -> list[dict]:
    return env.manager.canvases


# ---------------------------------------------------------------------------
# Merge: union by id + LWW matrix
# ---------------------------------------------------------------------------


def test_merge_union_by_id(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-hub", updated_at=1000), source="hub")
    _device_list(env, [_row("c-dev", 500)], device_id="dev-1")

    assert {row["id"] for row in _merged(env)} == {"c-hub", "c-dev"}
    # updated_at DESC ordering.
    assert [row["id"] for row in _merged(env)] == ["c-hub", "c-dev"]


@pytest.mark.parametrize(
    ("device_updated_at", "expected_title"),
    [
        (1500, "Device wins"),  # newer → device row displaces the hub copy
        (1000, "Hub wins"),  # equal → keep local (no churn)
        (999, "Hub wins"),  # older → hub copy survives
    ],
    ids=["newer", "equal", "older"],
)
def test_merge_lww_matrix(env: _Hub, device_updated_at: int, expected_title: str) -> None:
    hub_doc = _doc(env, canvas_id="c-1", updated_at=1000, title="Hub wins")
    env.index.save_document(hub_doc, source="hub")
    _device_list(env, [_row("c-1", device_updated_at, title="Device wins")])

    rows = [row for row in _merged(env) if row["id"] == "c-1"]
    assert len(rows) == 1
    assert rows[0]["title"] == expected_title
    expected_updated = device_updated_at if device_updated_at > 1000 else 1000
    assert rows[0]["updated_at"] == expected_updated


# ---------------------------------------------------------------------------
# Device registry: device_id keying + legacy fallback
# ---------------------------------------------------------------------------


def test_registry_keyed_by_device_id_with_independent_lists(env: _Hub) -> None:
    _device_list(env, [_row("c-1", 1000)], device_id="dev-1", device_name="Tab A")
    _device_list(env, [_row("c-2", 2000)], device_id="dev-2", device_name="Tab B")

    registry = env.manager.registry
    assert set(registry) == {"dev-1", "dev-2"}
    assert registry["dev-1"]["device_name"] == "Tab A"
    assert [row["id"] for row in registry["dev-1"]["last_list"]] == ["c-1"]
    assert [row["id"] for row in registry["dev-2"]["last_list"]] == ["c-2"]
    # Merged view is the union while each device's list stays independent.
    assert {row["id"] for row in _merged(env)} == {"c-1", "c-2"}


def test_registry_legacy_fallback_key_uses_last_peer(env: _Hub) -> None:
    env.bus.emit(CONNECTION_STATE, connected=True, peer="10.0.0.5:40000")
    _device_list(env, [_row("c-1", 1000)], device_id=None, device_name=None)

    registry = env.manager.registry
    assert set(registry) == {"legacy-10.0.0.5:40000"}
    assert registry["legacy-10.0.0.5:40000"]["last_list"] == [_row("c-1", 1000)]


def test_origin_hub_echo_is_ignored(env: _Hub) -> None:
    _device_list(env, [_row("c-1", 1000)], origin="hub")  # our own broadcast
    assert _merged(env) == []
    assert env.manager.registry == {}


# ---------------------------------------------------------------------------
# §9.4 flow 1/2: hub list broadcast + sequential CANVAS_PULL → CANVAS_PUT
# ---------------------------------------------------------------------------


def test_device_list_triggers_hub_broadcast_and_sequential_pulls(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-known", updated_at=1000), source="hub")
    env.push.messages.clear()

    _device_list(
        env,
        [_row("c-new", 2000), _row("c-known", 500), _row("c-older", 1500)],
        device_id="dev-1",
    )

    # merge → emit → hub list broadcast → pulls (§9.4 flow 1/2).
    assert env.events and env.events[-1]["canvases"] == _merged(env)
    assert [m["action"] for m in env.push.messages[:4]] == [
        "CANVAS_LIST",  # origin:hub broadcast of the merged store
        "CANVAS_PULL",  # c-new: hub lacks it
        "CANVAS_PULL",  # c-older: hub lacks it
        # c-known (device copy 500 < hub 1000) is NOT pulled — hub is newer.
    ]
    hub_list = env.push.messages[0]
    assert hub_list["payload"]["origin"] == "hub"
    assert hub_list["payload"]["device_id"] == env.manager.hub_device_id
    assert {row["id"] for row in hub_list["payload"]["canvases"]} == {
        "c-new", "c-known", "c-older",
    }

    pulls = env.push.of("CANVAS_PULL")
    assert [(p["payload"]["canvas_id"], p["payload"]["have_updated_at"]) for p in pulls] == [
        ("c-new", 0),
        ("c-older", 0),
    ]


def test_pull_older_local_uses_have_updated_at(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000), source="hub")
    env.push.messages.clear()

    _device_list(env, [_row("c-1", 2500)])
    pulls = env.push.of("CANVAS_PULL")
    assert len(pulls) == 1
    assert pulls[0]["payload"] == {"canvas_id": "c-1", "have_updated_at": 1000}


def test_device_put_replies_to_hub_pull_and_stores_silently(env: _Hub) -> None:
    _device_list(env, [_row("c-1", 2000)], device_id="dev-7")
    assert len(env.push.of("CANVAS_PULL")) == 1
    env.push.messages.clear()
    env.events.clear()

    # The device answers the pull with a full document (request-response pair).
    doc = _doc(env, canvas_id="c-1", updated_at=2000)
    body = env.store.document_to_json(doc)
    env.bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_PUT", {"canvas": body, "source": "device"}),
    )

    # Stored under the index (no UI switch), attributed to the pulled device.
    path = env.index.archive_path("c-1")
    assert path.is_file()
    row = env.index.get("c-1")
    assert row["updated_at"] == 2000
    assert row["source_devices"] == ["dev-7"]  # pending-pull attribution
    assert env.loaded == []  # CANVAS_PUT never switches the open document
    # Emission + hub list rebroadcast (§9.2: the hub store changed).
    assert env.events and env.events[-1]["devices"] == 0
    assert [m["action"] for m in env.push.messages] == ["CANVAS_LIST"]
    assert env.push.messages[0]["payload"]["origin"] == "hub"


# ---------------------------------------------------------------------------
# CANVAS_PUT LWW reception (hub side)
# ---------------------------------------------------------------------------


def test_put_newer_is_stored_equal_and_older_are_ignored(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000), source="hub")
    original_zip = env.index.archive_path("c-1").read_bytes()

    def put(doc: CanvasDocument) -> None:
        env.bus.emit(
            RPC_MESSAGE,
            msg=_envelope(
                "CANVAS_PUT",
                {"canvas": env.store.document_to_json(doc), "source": "device"},
            ),
        )

    # Equal → keep local, no churn: no emit, no broadcast, no rewrite.
    env.events.clear()
    env.push.messages.clear()
    put(_doc(env, canvas_id="c-1", updated_at=1000, title="Clone"))
    assert env.index.archive_path("c-1").read_bytes() == original_zip
    assert env.events == [] and env.push.messages == []

    # Older → rejected outright.
    put(_doc(env, canvas_id="c-1", updated_at=999, title="Stale"))
    assert env.index.archive_path("c-1").read_bytes() == original_zip
    assert env.events == [] and env.push.messages == []
    assert env.index.get("c-1")["updated_at"] == 1000

    # Newer → stored + emitted + hub list broadcast.
    put(_doc(env, canvas_id="c-1", updated_at=1500, title="Fresh"))
    assert env.index.get("c-1")["updated_at"] == 1500
    assert env.events and env.events[-1]["canvases"][0]["title"] == "Fresh"
    assert [m["action"] for m in env.push.messages] == ["CANVAS_LIST"]
    assert env.loaded == []  # silent persistence, NO UI switch (§9.1)


def test_put_sourced_from_hub_is_treated_as_echo(env: _Hub) -> None:
    doc = _doc(env, canvas_id="c-1", updated_at=2000)
    env.bus.emit(
        RPC_MESSAGE,
        msg=_envelope(
            "CANVAS_PUT", {"canvas": env.store.document_to_json(doc), "source": "hub"}
        ),
    )
    assert env.index.get("c-1") is None  # never stores our own broadcast back


def test_malformed_put_never_raises(env: _Hub, caplog: pytest.LogCaptureFixture) -> None:
    with caplog.at_level(logging.ERROR):
        env.bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_PUT", {"canvas": "nope"}))
        env.bus.emit(RPC_MESSAGE, msg=_envelope("CANVAS_PUT", {"canvas": {"x": 1}}))
    assert env.index.list() == []
    assert env.loaded == []


# ---------------------------------------------------------------------------
# CANVAS_PULL service (hub replies with a CANVAS_PUT only when newer)
# ---------------------------------------------------------------------------


def test_pull_served_only_when_strictly_newer(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000), source="hub")
    env.push.messages.clear()

    def pull(canvas_id: str, have: int) -> None:
        env.bus.emit(
            RPC_MESSAGE,
            msg=_envelope(
                "CANVAS_PULL", {"canvas_id": canvas_id, "have_updated_at": have}
            ),
        )

    pull("c-1", 1000)  # equal → silent
    pull("c-1", 1500)  # requester is newer → silent
    pull("ghost", 0)  # unknown → silent
    assert env.push.messages == []

    pull("c-1", 999)  # strictly newer → reply
    puts = env.push.of("CANVAS_PUT")
    assert len(puts) == 1
    assert puts[0]["canvas_id"] == "c-1"
    assert puts[0]["payload"]["source"] == "hub"
    assert puts[0]["payload"]["canvas"]["updated_at"] == 1000


def test_pull_without_index_replies_nothing(env: _Hub) -> None:
    env.manager._index = None  # storage disabled: sync actions no-op
    env.bus.emit(
        RPC_MESSAGE,
        msg=_envelope("CANVAS_PULL", {"canvas_id": "c-1", "have_updated_at": 0}),
    )
    assert env.push.messages == []


# ---------------------------------------------------------------------------
# §9.3 persist-on-open: OPEN_CANVAS {canvas} stores before switching
# ---------------------------------------------------------------------------


def test_open_canvas_persists_to_index_before_switching(env: _Hub) -> None:
    body = env.store.document_to_json(_doc(env, canvas_id="c-1", updated_at=1000))
    env.bus.emit(RPC_MESSAGE, msg=_envelope("OPEN_CANVAS", {"canvas": body}))

    # File exists in the index dir + row present, and the mirror switched.
    assert env.index.archive_path("c-1").is_file()
    assert env.index.get("c-1")["updated_at"] == 1000
    assert len(env.loaded) == 1  # DOCUMENT_LOADED fired exactly once
    assert env.store.current_path is None  # wire doc never autosaved locally
    # The store changed → hub list rebroadcast (§9.2).
    assert [m["action"] for m in env.push.messages] == ["CANVAS_LIST"]


def test_open_canvas_lww_keeps_newer_local_copy(env: _Hub) -> None:
    env.index.save_document(_doc(env, canvas_id="c-1", updated_at=1000), source="hub")
    env.push.messages.clear()

    body = env.store.document_to_json(_doc(env, canvas_id="c-1", updated_at=500))
    env.bus.emit(RPC_MESSAGE, msg=_envelope("OPEN_CANVAS", {"canvas": body}))

    assert env.index.get("c-1")["updated_at"] == 1000  # newer local survives
    assert len(env.loaded) == 1  # UI still switches (§8.3)
    assert env.push.messages == []  # store unchanged → no hub broadcast


# ---------------------------------------------------------------------------
# §9.4 flow 4: PC File→New end-to-end (persist + PUT + hub list)
# ---------------------------------------------------------------------------


def test_new_flow_end_to_end(env: _Hub) -> None:
    # main.py menu_rpc: store.new() → index.save_document → put_canvas → emit.
    doc = env.store.new("A4", "Fresh canvas")
    env.index.save_document(doc, source="hub")
    env.push.messages.clear()
    env.manager.put_canvas(doc)
    env.bus.emit(DOCUMENT_LOADED, doc=doc)

    puts = env.push.of("CANVAS_PUT")
    assert len(puts) == 1
    assert puts[0]["payload"]["source"] == "hub"
    assert puts[0]["payload"]["canvas"]["canvas_id"] == doc.canvas_id
    assert puts[0]["canvas_id"] == doc.canvas_id  # envelope carries the id
    assert [m["action"] for m in env.push.messages] == ["CANVAS_PUT", "CANVAS_LIST"]
    hub_list = env.push.messages[1]
    assert hub_list["payload"]["origin"] == "hub"
    assert [row["id"] for row in hub_list["payload"]["canvases"]] == [doc.canvas_id]
    # Devices receive the PUT silently — only this PC switched (loaded by main).
    assert len(env.loaded) == 1
    assert env.index.archive_path(doc.canvas_id).is_file()


def test_put_canvas_without_index_still_broadcasts(env: _Hub) -> None:
    env.manager._index = None
    doc = env.store.new("A4", "Local only")
    env.push.messages.clear()
    env.manager.put_canvas(doc)

    assert [m["action"] for m in env.push.messages] == ["CANVAS_PUT", "CANVAS_LIST"]
    assert [row["id"] for row in env.manager.canvases] == [doc.canvas_id]


# ---------------------------------------------------------------------------
# devices count transitions + 0-device storage
# ---------------------------------------------------------------------------


def test_devices_count_transitions_in_event_payload(env: _Hub) -> None:
    env.bus.emit(CONNECTION_STATE, connected=True, peer="a:1")
    env.bus.emit(CONNECTION_STATE, connected=True, peer="b:2")
    env.bus.emit(CONNECTION_STATE, connected=False, peer=None)
    env.bus.emit(CONNECTION_STATE, connected=False, peer=None)
    env.bus.emit(CONNECTION_STATE, connected=False, peer=None)  # floor stays 0

    assert [event["devices"] for event in env.events] == [1, 2, 1, 0, 0]
    assert env.manager.devices == 0


def test_zero_devices_storage_browsing_and_sync_noop(env: _Hub) -> None:
    doc = _doc(env, canvas_id="c-1", updated_at=1000)
    env.index.save_document(doc, source="hub")

    # Read-only local browsing works with 0 devices connected.
    assert [row["id"] for row in env.manager.canvases] == ["c-1"]
    assert env.manager.devices == 0

    # Sync actions are safe no-ops (broadcast fan-out is empty, never raise).
    env.manager.put_canvas(doc)
    env.manager.request_open("c-1")
    env.manager.broadcast_hub_list()
    assert [m["action"] for m in env.push.messages] == [
        "CANVAS_PUT",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
        "CANVAS_LIST",
    ]

    # Connection with an empty store: request still goes out, no crash.
    env.bus.emit(CONNECTION_STATE, connected=True, peer="1.2.3.4:5")
    assert env.manager.devices == 1
    assert [row["id"] for row in env.manager.canvases] == ["c-1"]  # browsing stable


def test_shutdown_stops_pull_drain_and_unsubscribes(env: _Hub) -> None:
    env.manager.shutdown()
    env.manager.shutdown()  # idempotent
    env.push.messages.clear()

    _device_list(env, [_row("c-1", 1000)], device_id="dev-1")
    assert env.push.messages == []  # handlers gone: no broadcast, no pulls
    assert env.events == []
    assert env.manager._pull_queue == []
