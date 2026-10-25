"""Round-4 contract tests (Doc 02 §8) — schema ⇄ validator ⇄ protocol ⇄ doc.

* ``validate_specs.py`` derives the expected action set from
  ``ws_rpc_schema.json`` itself (no hardcoded count) — proven both ways:
  corrupted action sets are rejected, consistently-removed ones still pass.
* The embedded JSON body in Doc 02 §5 (Step 8) stays byte-identical with the
  schema file (mechanical sync required by §8.5).
* ``pc_agent.core.protocol.RPC_ACTIONS`` mirrors the schema's 24 actions.
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


def test_twenty_eight_actions_in_enum_and_canvas_lifecycle_group(schema: dict) -> None:
    actions = schema["envelope"]["action"]["enum"]
    # Round 12 §11.1 added the four OCR actions (20 -> 24); round 13 §13.1 the
    # four gallery actions (24 -> 28).
    assert len(actions) == 28
    assert set(actions) == set(RPC_ACTIONS)
    canvas_actions = set(schema["type_actions"]["CANVAS_LIFECYCLE"])
    assert canvas_actions == {
        "OPEN_CANVAS",
        "CANVAS_LIST_REQUEST",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
        # Doc 02 §9.1 — round 5 hub sync.
        "CANVAS_PUT",
        "CANVAS_PULL",
    }
    # §8.1/§9.1: the union of the groups IS the enum (validator self-derivation).
    union = {a for group in schema["type_actions"].values() for a in group}
    assert union == set(actions)


def test_clear_canvas_lands_in_element_commit_group(schema: dict) -> None:
    """§10.1: action 19 → 20 — CLEAR_CANVAS joins ELEMENT_COMMIT, payload {}."""
    assert "CLEAR_CANVAS" in schema["envelope"]["action"]["enum"]
    element_actions = set(schema["type_actions"]["ELEMENT_COMMIT"])
    assert element_actions == {
        "ADD_STROKE",
        "ADD_GRAPH",
        "ADD_SHAPE",
        "ADD_IMAGE",
        "DELETE_NODE",
        "CLEAR_CANVAS",
    }
    # One action, one group: CLEAR_CANVAS appears exactly once across type_actions.
    placements = [
        group
        for group, members in schema["type_actions"].items()
        if "CLEAR_CANVAS" in members
    ]
    assert placements == ["ELEMENT_COMMIT"]


def test_payload_schemas_cover_the_canvas_sync_actions(schema: dict) -> None:
    schemas = schema["payload_schemas"]
    assert set(schemas) == {
        "OPEN_CANVAS",
        "CANVAS_LIST_REQUEST",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
        "CANVAS_PUT",
        "CANVAS_PULL",
        # Doc 02 §10.1 — round 6 clear.
        "CLEAR_CANVAS",
        # Doc 02 §11.1 — round 12 OCR job.
        "START_OCR",
        "CANCEL_OCR",
        "OCR_PROGRESS",
        "OCR_RESULT",
        # Doc 02 §13.1 — round 13 image library.
        "GALLERY_LIST_REQUEST",
        "GALLERY_LIST",
        "GALLERY_ADD",
        "GALLERY_SAVE",
    }
    open_canvas = schemas["OPEN_CANVAS"]
    assert open_canvas["discriminator"] == "canvas"
    assert set(open_canvas["dialects"]) == {"canvas", "path"}
    assert open_canvas["dialects"]["path"]["direction"] == "pc_internal_only"
    for action in ("CANVAS_LIST_REQUEST", "CANVAS_LIST", "CANVAS_OPEN_REQUEST"):
        assert schemas[action]["direction"] in ("pc_to_tablet", "tablet_to_pc")
    # §9.1 payload schemas: CANVAS_PUT {canvas, source} / CANVAS_PULL {id, have}.
    assert schemas["CANVAS_PUT"]["direction"] == "any_to_any"
    assert schemas["CANVAS_PUT"]["required"] == ["canvas", "source"]
    assert schemas["CANVAS_PUT"]["properties"]["source"]["enum"] == ["device", "hub"]
    assert schemas["CANVAS_PULL"]["direction"] == "any_to_any"
    assert schemas["CANVAS_PULL"]["required"] == ["canvas_id", "have_updated_at"]
    assert schemas["CANVAS_PULL"]["properties"]["have_updated_at"]["unit"] == "unix_seconds"
    # §10.1 payload schema: CLEAR_CANVAS is an EMPTY object payload {}.
    assert schemas["CLEAR_CANVAS"]["type"] == "object"
    assert schemas["CLEAR_CANVAS"]["properties"] == {}
    assert schemas["CLEAR_CANVAS"]["required"] == []


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


def test_round5_action_dropped_from_group_is_rejected() -> None:
    """§9.1: losing CANVAS_PUT from the group ⇔ enum has an unexpected action."""

    def mutate(spec: dict) -> None:
        spec["type_actions"]["CANVAS_LIFECYCLE"].remove("CANVAS_PUT")

    errors = _validate(mutate)
    assert any("unexpected ['CANVAS_PUT']" in e for e in errors)


def test_round5_action_missing_from_enum_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].remove("CANVAS_PULL")

    errors = _validate(mutate)
    assert any("missing ['CANVAS_PULL']" in e for e in errors)


def test_round6_action_dropped_from_group_is_rejected() -> None:
    """§10.1: losing CLEAR_CANVAS from ELEMENT_COMMIT ⇔ an unexpected enum action."""

    def mutate(spec: dict) -> None:
        spec["type_actions"]["ELEMENT_COMMIT"].remove("CLEAR_CANVAS")

    errors = _validate(mutate)
    assert any("unexpected ['CLEAR_CANVAS']" in e for e in errors)


def test_round6_action_missing_from_enum_is_rejected() -> None:
    def mutate(spec: dict) -> None:
        spec["envelope"]["action"]["enum"].remove("CLEAR_CANVAS")

    errors = _validate(mutate)
    assert any("missing ['CLEAR_CANVAS']" in e for e in errors)


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


def test_doc02_embedded_body_parses_and_carries_the_28_actions() -> None:
    embedded = json.loads(_embedded_body())
    assert embedded == json.loads(_SCHEMA_PATH.read_text(encoding="utf-8"))
    assert len(embedded["envelope"]["action"]["enum"]) == 28
    assert set(embedded["type_actions"]["CANVAS_LIFECYCLE"]) >= {
        "CANVAS_PUT",
        "CANVAS_PULL",
    }
    assert "CLEAR_CANVAS" in embedded["type_actions"]["ELEMENT_COMMIT"]
