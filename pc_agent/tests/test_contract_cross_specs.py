"""Round-6 cross-artifact contract test (TEST 3) — machine-verifies the PC
mirrors against the JSON ground truth in ``shared_specs/`` and Doc 02:

* ``core.protocol.RPC_TYPES`` / ``RPC_ACTIONS`` == dynamically-loaded
  ``ws_rpc_schema.json`` enums (both directions, no hardcoded count).
* ``pack_live_frame`` byte layout == ``binary_stream_frame.json`` offsets
  table (sentinel values asserted against every spec row's byte range).
* The fenced JSON body embedded in Doc 02 §5 == ``shared_specs/
  ws_rpc_schema.json`` (byte-identical after parse — catches doc/schema
  drift). Every ```json block is parsed; at least one must equal the file.
* ``canvas_document_schema.json`` required top-level keys ⊆ what
  ``DocumentStore.parse_document`` / ``read_archive`` produce for a
  round-tripped document (store constructed with ``tmp_path``).
"""

from __future__ import annotations

import json
import re
import struct
from pathlib import Path

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import EventBus
from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LASER,
    FRAME_LIVE_END,
    FRAME_LIVE_POINT,
    FRAME_STRUCT,
    RPC_ACTIONS,
    RPC_TYPES,
    TOOL_ERASER,
    TOOL_HIGHLIGHTER,
    TOOL_PEN,
    TOOL_SHAPE_PREVIEW,
    LiveFrame,
    pack_live_frame,
)
from pc_agent.engine.document_store import DocumentStore
from pc_agent.engine.scene_graph import SceneGraph

_ROOT = Path(__file__).resolve().parents[2]
_SPECS = _ROOT / "shared_specs"
_WS_SCHEMA = _SPECS / "ws_rpc_schema.json"
_FRAME_SPEC = _SPECS / "binary_stream_frame.json"
_DOC_SCHEMA = _SPECS / "canvas_document_schema.json"
_DOC02 = _ROOT / "docs" / "micro" / "02_vector_stream_protocol_spec.md"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# TEST 3.1 — protocol mirrors ⇄ ws_rpc_schema.json
# ---------------------------------------------------------------------------


def test_rpc_types_match_schema_enum_both_directions() -> None:
    schema = _load(_WS_SCHEMA)
    schema_types = set(schema["envelope"]["type"]["enum"])
    assert set(RPC_TYPES) == schema_types  # both directions, no hardcoded count
    assert len(RPC_TYPES) == len(schema_types)


def test_rpc_actions_match_schema_enum_both_directions() -> None:
    schema = _load(_WS_SCHEMA)
    schema_actions = set(schema["envelope"]["action"]["enum"])
    assert set(RPC_ACTIONS) == schema_actions  # both directions
    assert len(RPC_ACTIONS) == len(schema_actions)
    # The enum's size is derived from the file itself — the type_actions
    # grouping must cover exactly the same action universe.
    grouped = {
        action
        for group in schema["type_actions"].values()
        for action in group
    }
    assert grouped == schema_actions


def test_type_actions_reference_master_enums() -> None:
    schema = _load(_WS_SCHEMA)
    schema_types = set(schema["envelope"]["type"]["enum"])
    schema_actions = set(schema["envelope"]["action"]["enum"])
    assert set(schema["type_actions"]) <= schema_types
    for type_name, actions in schema["type_actions"].items():
        assert actions, f"group {type_name} is empty"
        assert set(actions) <= schema_actions, (
            f"group {type_name} lists actions missing from the master enum: "
            f"{sorted(set(actions) - schema_actions)}"
        )


# ---------------------------------------------------------------------------
# TEST 3.2 — pack_live_frame ⇄ binary_stream_frame.json offsets table
# ---------------------------------------------------------------------------


def test_pack_live_frame_matches_offsets_table() -> None:
    spec = _load(_FRAME_SPEC)
    sentinels = {
        "frame_type": 0x04,
        "tool_id": 0x02,
        "seq": 0x1234,
        "f1": -1.5,
        "f2": 2.25,
        "f3": 0.0,
    }
    frame = LiveFrame(
        frame_type=sentinels["frame_type"],
        tool_id=sentinels["tool_id"],
        seq=sentinels["seq"],
        f1=sentinels["f1"],
        f2=sentinels["f2"],
        f3=sentinels["f3"],
    )
    data = pack_live_frame(frame)

    assert spec["byte_order"] == "little_endian"
    assert len(data) == spec["byte_length"] == FRAME_STRUCT.size
    assert spec["struct_format"] == FRAME_STRUCT.format == "<BBHfff"

    readers = {
        "uint8": (1, lambda raw: raw[0]),
        "uint16": (2, lambda raw: struct.unpack("<H", raw)[0]),
        "float32": (4, lambda raw: struct.unpack("<f", raw)[0]),
    }
    cursor = 0
    for row in spec["fields"]:
        name, offset, size, c_type = (
            row["name"],
            row["offset"],
            row["size"],
            row["c_type"],
        )
        # The rows must tile the frame contiguously: no gaps, no overlaps.
        assert offset == cursor, (
            f'field "{name}" offset {offset} does not follow previous row '
            f"({cursor})"
        )
        cursor = offset + size
        assert c_type in readers, f'unknown c_type "{c_type}" for "{name}"'
        expected_size, read = readers[c_type]
        assert size == expected_size, (
            f'field "{name}" size {size} != {expected_size} for {c_type}'
        )
        assert offset + size <= spec["byte_length"]
        raw = data[offset : offset + size]
        assert len(raw) == size
        got = read(raw)
        want = sentinels[name]
        if isinstance(want, float):
            assert got == want, f'field "{name}" @ {offset}: {got} != {want}'
        else:
            assert got == want, f'field "{name}" @ {offset}: {got} != {want}'
    assert cursor == spec["byte_length"], "spec rows must cover the frame"


def test_frame_and_tool_enum_bytes_match_spec() -> None:
    spec = _load(_FRAME_SPEC)
    frame_names = {
        entry["name"]: int(key, 16) for key, entry in spec["frame_type"].items()
    }
    # PC mirror constants == spec byte values.
    assert frame_names == {
        "LIVE_POINT": FRAME_LIVE_POINT,
        "LIVE_END": FRAME_LIVE_END,
        "CAMERA": FRAME_CAMERA,
        "LASER": FRAME_LASER,
    }
    assert set(frame_names.values()) == {0x01, 0x02, 0x03, 0x04}
    tool_names = {int(key, 16): name for key, name in spec["tool_id"].items()}
    assert tool_names == {
        0x01: "Pen",
        0x02: "Highlighter",
        0x03: "Eraser",
        0x04: "Line/Shape Preview",
    }
    assert {
        TOOL_PEN,
        TOOL_HIGHLIGHTER,
        TOOL_ERASER,
        TOOL_SHAPE_PREVIEW,
    } == {0x01, 0x02, 0x03, 0x04}


# ---------------------------------------------------------------------------
# TEST 3.3 — Doc 02 §5 embedded JSON body ⇄ shared_specs/ws_rpc_schema.json
# ---------------------------------------------------------------------------


def _json_fences(markdown: str) -> list[str]:
    return re.findall(r"```json\s*\n(.*?)```", markdown, re.S)


def test_doc02_embedded_body_equals_schema_file() -> None:
    schema = _load(_WS_SCHEMA)
    text = _DOC02.read_text(encoding="utf-8")
    fences = _json_fences(text)
    assert fences, f"no ```json fences found in {_DOC02.name}"

    parsed: list[dict] = []
    for index, fence in enumerate(fences):
        try:
            value = json.loads(fence)
        except json.JSONDecodeError:
            continue  # example blocks (e.g. §8.4) are illustrative, not bodies
        assert isinstance(value, dict), f"fence #{index} is not a JSON object"
        parsed.append(value)
    assert parsed, "no parseable ```json fence in Doc 02"

    # Byte-identical after parse: at least one fenced body must equal the
    # shared spec file exactly — catches doc ⇄ schema drift mechanically.
    matching = [value for value in parsed if value == schema]
    assert matching, (
        "Doc 02 §5 embedded JSON body drifted from "
        "shared_specs/ws_rpc_schema.json — the fenced block must parse to "
        "the exact schema object"
    )


# ---------------------------------------------------------------------------
# TEST 3.4 — canvas_document_schema.json required keys ⊆ DocumentStore I/O
# ---------------------------------------------------------------------------


def test_document_store_roundtrip_covers_required_schema_keys(
    tmp_path: Path,
) -> None:
    schema = _load(_DOC_SCHEMA)
    required = set(schema["required"])
    props = set(schema["properties"])
    assert required <= props, "schema required keys must be declared"

    bus = EventBus()
    config = AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )
    store = DocumentStore(bus, config, SceneGraph(bus))

    # Round trip: new() → save() → read_archive() → document_to_json() and
    # parse_document() of the archived body.
    doc = store.new("A4", "Round-trip contract")
    path = store.save(doc)
    assert path.exists()

    archived = store.read_archive(path)
    archived_body = DocumentStore.document_to_json(archived)
    assert required <= set(archived_body), (
        f"read_archive/document_to_json missing required keys: "
        f"{sorted(required - set(archived_body))}"
    )
    assert set(archived_body) <= props, (
        f"document_to_json emits keys absent from the schema: "
        f"{sorted(set(archived_body) - props)}"
    )

    parsed = DocumentStore.parse_document(archived_body)
    parsed_body = DocumentStore.document_to_json(parsed)
    assert required <= set(parsed_body), (
        f"parse_document round-trip missing required keys: "
        f"{sorted(required - set(parsed_body))}"
    )
    assert set(parsed_body) <= props, (
        f"parse_document round-trip emits keys absent from the schema: "
        f"{sorted(set(parsed_body) - props)}"
    )
    # Byte-stable round trip through the store's own serializer.
    assert parsed_body == archived_body
