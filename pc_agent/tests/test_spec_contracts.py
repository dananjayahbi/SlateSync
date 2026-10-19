"""Round-4 contract tests (Doc 02 §8) — schema ⇄ validator ⇄ protocol ⇄ doc.

* ``validate_specs.py`` derives the expected action set from
  ``ws_rpc_schema.json`` itself (no hardcoded 13/14/17) — proven both ways:
  corrupted action sets are rejected, consistently-removed ones still pass.
* The embedded JSON body in Doc 02 §5 (Step 8) stays byte-identical with the
  schema file (mechanical sync required by §8.5).
* ``pc_agent.core.protocol.RPC_ACTIONS`` mirrors the schema's 17 actions.
"""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path

import pytest

from pc_agent.core.protocol import RPC_ACTIONS

_ROOT = Path(__file__).resolve().parents[2]
_SCHEMA_PATH = _ROOT / "shared_specs" / "ws_rpc_schema.json"
_DOC02_PATH = _ROOT / "docs" / "micro" / "02_vector_stream_protocol_spec.md"


def _load_validator():
    spec = importlib.util.spec_from_file_location(
        "slatesync_validate_specs", _ROOT / "shared_specs" / "validate_specs.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_VALIDATOR = _load_validator()


@pytest.fixture(scope="module")
def schema() -> dict:
    return json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))


def _validate(mutate) -> list[str]:
    """Validate a deep-copied schema after ``mutate(spec)``; returns errors."""
    spec = copy.deepcopy(json.loads(_SCHEMA_PATH.read_text(encoding="utf-8")))
    mutate(spec)
    return _VALIDATOR.validate_ws_rpc(spec)


def test_real_schema_validates_clean() -> None:
    spec = json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
    assert _VALIDATOR.validate_ws_rpc(spec) == []
    assert _VALIDATOR.main([str(_SCHEMA_PATH.parent)]) == 0


def test_seventeen_actions_in_enum_and_canvas_lifecycle_group(schema: dict) -> None:
    actions = schema["envelope"]["action"]["enum"]
    assert len(actions) == 17
    assert set(actions) == set(RPC_ACTIONS)
    canvas_actions = set(schema["type_actions"]["CANVAS_LIFECYCLE"])
    assert canvas_actions == {
        "OPEN_CANVAS",
        "CANVAS_LIST_REQUEST",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
    }
    # §8.1: the union of the groups IS the enum (validator self-derivation).
    union = {a for group in schema["type_actions"].values() for a in group}
    assert union == set(actions)


def test_payload_schemas_cover_the_canvas_sync_actions(schema: dict) -> None:
    schemas = schema["payload_schemas"]
    assert set(schemas) == {
        "OPEN_CANVAS",
        "CANVAS_LIST_REQUEST",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
    }
    open_canvas = schemas["OPEN_CANVAS"]
    assert open_canvas["discriminator"] == "canvas"
    assert set(open_canvas["dialects"]) == {"canvas", "path"}
    assert open_canvas["dialects"]["path"]["direction"] == "pc_internal_only"
    for action in ("CANVAS_LIST_REQUEST", "CANVAS_LIST", "CANVAS_OPEN_REQUEST"):
        assert schemas[action]["direction"] in ("pc_to_tablet", "tablet_to_pc")


# ---------------------------------------------------------------------------
# Validator self-derivation: corrupt → rejected, consistent edits → accepted
# ---------------------------------------------------------------------------


def test_corrupted_enum_missing_action_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].remove("CANVAS_LIST")

    errors = _validate(mutate)
    assert errors and any("missing ['CANVAS_LIST']" in e for e in errors)


def test_corrupted_enum_renamed_action_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        enum = spec["envelope"]["action"]["enum"]
        enum[enum.index("CANVAS_OPEN_REQUEST")] = "CANVAS_OPEN_REQUESTS"

    errors = _validate(mutate)
    assert any("missing ['CANVAS_OPEN_REQUEST']" in e for e in errors)
    assert any("unexpected ['CANVAS_OPEN_REQUESTS']" in e for e in errors)


def test_corrupted_enum_duplicate_action_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].append("CANVAS_LIST")

    errors = _validate(mutate)
    assert any("duplicate" in e for e in errors)


def test_corrupted_enum_invalid_entry_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].append(42)

    errors = _validate(mutate)
    assert any("invalid entries" in e for e in errors)


def test_action_in_two_groups_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["type_actions"]["ELEMENT_COMMIT"].append("CANVAS_LIST")

    errors = _validate(mutate)
    assert any("more than one group" in e for e in errors)


def test_group_missing_from_enum_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["type_actions"]["EXPORT_JOB"].append("EXPORT_SUMMARY")

    errors = _validate(mutate)
    assert any("missing ['EXPORT_SUMMARY']" in e for e in errors)


def test_payload_schema_for_unknown_action_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["payload_schemas"]["CANVAS_LIST_X"] = {"type": "object"}

    errors = _validate(mutate)
    assert any("payload_schemas" in e and "CANVAS_LIST_X" in e for e in errors)


def test_consistent_removal_stays_valid_no_hardcoded_count() -> None:
    """Drop an action from BOTH the enum and its group → still valid: the
    expected set is derived from the schema itself, never hardcoded."""

    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].remove("EXPORT_PROGRESS")
        spec["type_actions"]["EXPORT_JOB"].remove("EXPORT_PROGRESS")

    assert _validate(mutate) == []


# ---------------------------------------------------------------------------
# Mechanical sync: Doc 02 §5 embedded body == ws_rpc_schema.json bytes
# ---------------------------------------------------------------------------


def _embedded_body() -> str:
    doc = _DOC02_PATH.read_text(encoding="utf-8")
    step8 = doc.index("**Step 8")
    fence_start = doc.index("```json", step8) + len("```json\n")
    fence_end = doc.index("\n```", fence_start)
    return doc[fence_start:fence_end]


def test_doc02_step5_body_is_byte_identical_to_schema_file() -> None:
    file_body = _SCHEMA_PATH.read_text(encoding="utf-8").rstrip("\n")
    embedded = _embedded_body()
    assert embedded == file_body, (
        "docs/micro/02_vector_stream_protocol_spec.md §5 body drifted from "
        "shared_specs/ws_rpc_schema.json — re-sync mechanically"
    )


def test_doc02_embedded_body_parses_and_carries_the_17_actions() -> None:
    embedded = json.loads(_embedded_body())
    assert embedded == json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
    assert len(embedded["envelope"]["action"]["enum"]) == 17
