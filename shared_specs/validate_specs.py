#!/usr/bin/env python3
"""Validate the three Phase 0 shared-spec JSON locks (Doc 01, steps 5-7).

Usage: python shared_specs/validate_specs.py [spec_dir]

Exit 0 only when binary_stream_frame.json, ws_rpc_schema.json and
canvas_document_schema.json all parse and pass the Doc 01 section 6 check
matrix (master constants from docs/_micro_doc_template.md section 3).
Otherwise print per-file MISSING/INVALID diagnostics plus precise
"file: check: expected X got Y" lines and exit 1. Stdlib only.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# --- Master constants (docs/_micro_doc_template.md section 3, Doc 01 section 6) ---

BINARY_FRAME_KEYS = (
    "spec",
    "version",
    "byte_length",
    "byte_order",
    "struct_format",
    "fields",
    "frame_type",
    "tool_id",
    "seq_rule",
    "mirrors",
)
FRAME_OFFSETS = [0, 1, 2, 4, 8, 12]
FRAME_TYPE_KEYS = ["0x01", "0x02", "0x03", "0x04"]
TOOL_ID_KEYS = ["0x01", "0x02", "0x03", "0x04"]

WS_RPC_KEYS = (
    "spec",
    "version",
    "transport",
    "envelope",
    "type_actions",
    "asset_upload",
    "export_job",
)
WS_PORT = 50606
WS_PATH = "/ws"
WS_URL_TEMPLATE = "ws://<ipv4>:50606/ws?token=<session_token>"
WS_CLOSE_CODE = 4001
RAW_CAP_BYTES_PER_CHUNK = 262144
RPC_TYPES = [
    "CANVAS_LIFECYCLE",
    "ELEMENT_COMMIT",
    "ARTBOARD_RESIZE",
    "ASSET_UPLOAD",
    "EXPORT_JOB",
    "OCR_JOB",
]
# Doc 02 round 4 (§8): the expected action set is DERIVED from ws_rpc_schema.json
# itself — envelope.action.enum must exactly equal the union of the type_actions
# groups (disjoint, unique, non-empty). No hardcoded action names or counts here;
# corrupted/renamed/dropped actions are caught by the cross-check below.


def _derive_action_set(spec: dict) -> tuple[set[str] | None, list[str]]:
    """Cross-check envelope.action.enum against type_actions; None = derivation failed.

    Returns (expected_set, errors): the expected set is the union of the
    type_actions groups, or None when type_actions is unusable.
    """
    errors: list[str] = []
    groups = spec.get("type_actions", _MISSING)
    if groups is _MISSING:
        errors.append("type_actions: expected object got <missing>")
        return None, errors
    if not isinstance(groups, dict):
        errors.append(f"type_actions: expected object got {groups!r}")
        return None, errors
    expected: set[str] = set()
    for group, actions in groups.items():
        if group not in RPC_TYPES:
            errors.append(f"type_actions: unexpected group {group!r} (type enum {RPC_TYPES})")
        if not isinstance(actions, list) or not actions:
            errors.append(f"type_actions.{group}: expected non-empty list got {actions!r}")
            continue
        for action in actions:
            if not isinstance(action, str) or not action:
                errors.append(f"type_actions.{group}: invalid action entry {action!r}")
                continue
            if action in expected:
                errors.append(f"type_actions: action {action!r} listed in more than one group")
            expected.add(action)
    return expected, errors

CANVAS_KEYS = (
    "$schema",
    "$id",
    "title",
    "description",
    "type",
    "required",
    "properties",
    "$defs",
    "x_upgrade_rule",
    "x_presets",
    "x_content_bounds_rule",
    "x_container",
)
PRESETS = {
    "A5": (1748.0, 2480.0),
    "A4": (2480.0, 3508.0),
    "LETTER": (2550.0, 3300.0),
    "INFINITE": (None, None),
}
PRESET_ORIGIN = "top_left_0_0"
BACKGROUND_STYLES = ["BLANK", "RULED", "SQUARE_GRID"]
#: Round-9: legacy styles removed from the enum but still accepted on LOAD
#: (mapped to BLANK by every normaliser) so pre-round-9 documents open.
LEGACY_BACKGROUND_STYLES = ["DOT_GRID", "ISO_GRID"]
#: Default world-unit gap between rules / square side (Artboard.background_spacing).
DEFAULT_BACKGROUND_SPACING = 32.0
BLEND_MODES = ["SRC_OVER", "MULTIPLY"]
ELEMENT_KINDS = ["STROKE", "HIGHLIGHT", "LINE", "SHAPE", "GRAPH_AXES", "IMAGE"]
#: Round-9: PATH (closed polygon — rotation output and pen-loop fills) and
#: TABLE (grid described by graph_config) joined the shape_type enum.
#: Round-12: TEXT (a text box whose content lives in graph_config) joined it.
SHAPE_TYPES = [
    "RECT",
    "CIRCLE",
    "TRIANGLE",
    "ARROW",
    "CARTESIAN_2D",
    "NUMBER_LINE",
    "PATH",
    "TABLE",
    "TEXT",
]

SPEC_CHECKS = (
    ("binary_stream_frame.json", "validate_binary_frame"),
    ("ws_rpc_schema.json", "validate_ws_rpc"),
    ("canvas_document_schema.json", "validate_canvas_document"),
)

_MISSING = object()


class SpecError(Exception):
    """Spec load failure that was already reported to stderr."""


def _dig(obj: object, *keys: str) -> object:
    """Walk nested dicts; return _MISSING at the first absent/non-dict hop."""
    current = obj
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return _MISSING
        current = current[key]
    return current


def _eq(errors: list[str], check: str, expected: object, got: object) -> None:
    if got is _MISSING:
        errors.append(f"{check}: expected {expected!r} got <missing>")
    elif got != expected:
        errors.append(f"{check}: expected {expected!r} got {got!r}")


def _require_keys(errors: list[str], spec: dict, keys: tuple[str, ...]) -> None:
    for key in keys:
        if key not in spec:
            errors.append(f"missing required key {key!r}")


def _enum(errors: list[str], check: str, expected: list[str], spec: dict, *path: str) -> None:
    got = _dig(spec, *path)
    if got is _MISSING:
        errors.append(f"{check}: expected {expected!r} got <missing>")
        return
    if not isinstance(got, list):
        errors.append(f"{check}: expected list {expected!r} got {got!r}")
        return
    try:
        ordered = sorted(got)
    except TypeError:
        ordered = None
    if ordered != sorted(expected):
        errors.append(f"{check}: expected {sorted(expected)!r} got {got!r}")


def load_spec(path: Path) -> dict:
    """json.load one spec; on error print "path: <msg>" to stderr and raise."""
    if not path.is_file():
        print(f"{path}: spec not yet written (Wave 1.A barrier)", file=sys.stderr)
        raise SpecError(str(path))
    try:
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"{path}: {exc}", file=sys.stderr)
        raise SpecError(str(path)) from exc
    if not isinstance(data, dict):
        kind = type(data).__name__
        print(f"{path}: expected a JSON object at top level, got {kind}", file=sys.stderr)
        raise SpecError(str(path))
    return data


def validate_binary_frame(spec: dict) -> list[str]:
    """Doc 01 section 6: byte_length, struct_format, offsets, FrameType/ToolId keys."""
    errors: list[str] = []
    _require_keys(errors, spec, BINARY_FRAME_KEYS)
    _eq(errors, "byte_length", 16, spec.get("byte_length", _MISSING))
    _eq(errors, "struct_format", "<BBHfff", spec.get("struct_format", _MISSING))

    fields = spec.get("fields", _MISSING)
    if fields is _MISSING:
        errors.append(f"fields offsets: expected {FRAME_OFFSETS} got <missing>")
    elif not isinstance(fields, list):
        errors.append(f"fields offsets: expected list {FRAME_OFFSETS} got {fields!r}")
    else:
        offsets = [f.get("offset") if isinstance(f, dict) else f for f in fields]
        try:
            got = sorted(offsets)
        except TypeError:
            got = offsets
        if got != FRAME_OFFSETS:
            errors.append(f"fields offsets: expected {FRAME_OFFSETS} got {got}")

    frame_type = spec.get("frame_type", _MISSING)
    if frame_type is _MISSING:
        errors.append(f"frame_type keys: expected {FRAME_TYPE_KEYS} got <missing>")
    elif not isinstance(frame_type, dict):
        errors.append(f"frame_type keys: expected object {FRAME_TYPE_KEYS} got {frame_type!r}")
    else:
        keys = sorted(frame_type)
        if keys != FRAME_TYPE_KEYS:
            errors.append(f"frame_type keys: expected {FRAME_TYPE_KEYS} got {keys}")

    tool_id = spec.get("tool_id", _MISSING)
    if tool_id is _MISSING:
        errors.append(f"tool_id keys: expected {TOOL_ID_KEYS} got <missing>")
    elif not isinstance(tool_id, dict):
        errors.append(f"tool_id keys: expected object {TOOL_ID_KEYS} got {tool_id!r}")
    else:
        keys = sorted(tool_id)
        if keys != TOOL_ID_KEYS:
            errors.append(f"tool_id keys: expected {TOOL_ID_KEYS} got {keys}")
    return errors


def validate_ws_rpc(spec: dict) -> list[str]:
    """Doc 01 section 6: port/path/url/close code, type+action enums, chunk cap."""
    errors: list[str] = []
    _require_keys(errors, spec, WS_RPC_KEYS)

    transport = spec.get("transport", _MISSING)
    if transport is _MISSING:
        errors.append("transport: expected object got <missing>")
    elif not isinstance(transport, dict):
        errors.append(f"transport: expected object got {transport!r}")
    else:
        _eq(errors, "transport.port", WS_PORT, transport.get("port", _MISSING))
        _eq(errors, "transport.path", WS_PATH, transport.get("path", _MISSING))
        _eq(errors, "transport.url", WS_URL_TEMPLATE, transport.get("url", _MISSING))
        _eq(
            errors,
            "transport.bad_token_close_code",
            WS_CLOSE_CODE,
            transport.get("bad_token_close_code", _MISSING),
        )

    _enum(errors, "envelope.type.enum", RPC_TYPES, spec, "envelope", "type", "enum")

    # Action set: envelope.action.enum ⇄ type_actions union (Doc 02 §8 — the
    # expected set is derived from the schema itself, never hardcoded here).
    actions = _dig(spec, "envelope", "action", "enum")
    derived, derive_errors = _derive_action_set(spec)
    errors.extend(derive_errors)
    if actions is _MISSING:
        errors.append("envelope.action.enum: expected list of actions got <missing>")
    elif not isinstance(actions, list):
        errors.append(f"envelope.action.enum: expected list of actions got {actions!r}")
    else:
        problems: list[str] = []
        enum_set: set[str] = set()
        duplicates: set[str] = set()
        invalid: list[object] = []
        for action in actions:
            if not isinstance(action, str) or not action:
                invalid.append(action)
                continue
            if action in enum_set:
                duplicates.add(action)
            enum_set.add(action)
        if invalid:
            problems.append(f"invalid entries {invalid!r}")
        if duplicates:
            problems.append(f"duplicate entries {sorted(duplicates)!r}")
        if derived is not None:
            missing = sorted(derived - enum_set)
            unexpected = sorted(enum_set - derived)
            if missing:
                problems.append(f"missing {missing}")
            if unexpected:
                problems.append(f"unexpected {unexpected}")
        if problems:
            errors.append(
                "envelope.action.enum does not match the type_actions union: "
                + "; ".join(problems)
            )

    # Payload schemas (Doc 02 §8): when present, every keyed action must exist.
    schemas = spec.get("payload_schemas", _MISSING)
    if schemas is not _MISSING:
        if not isinstance(schemas, dict):
            errors.append(f"payload_schemas: expected object got {schemas!r}")
        elif derived is not None:
            for action in schemas:
                if action not in derived:
                    errors.append(
                        f"payload_schemas: action {action!r} not present in type_actions"
                    )

    _eq(
        errors,
        "asset_upload.raw_cap_bytes_per_chunk",
        RAW_CAP_BYTES_PER_CHUNK,
        _dig(spec, "asset_upload", "raw_cap_bytes_per_chunk"),
    )
    return errors


def validate_canvas_document(spec: dict) -> list[str]:
    """Doc 01 section 6: preset matrix, backgrounds, blend modes, kinds, upgrade rule."""
    errors: list[str] = []
    _require_keys(errors, spec, CANVAS_KEYS)

    presets = spec.get("x_presets", _MISSING)
    if presets is _MISSING:
        errors.append("x_presets: expected object got <missing>")
    elif not isinstance(presets, dict):
        errors.append(f"x_presets: expected object got {presets!r}")
    else:
        _eq(errors, "x_presets.origin", PRESET_ORIGIN, presets.get("origin", _MISSING))
        for name, (width, height) in PRESETS.items():
            entry = presets.get(name, _MISSING)
            if entry is _MISSING:
                errors.append(f"x_presets.{name}: expected width/height got <missing>")
            elif not isinstance(entry, dict):
                errors.append(f"x_presets.{name}: expected object got {entry!r}")
            else:
                _eq(errors, f"x_presets.{name}.width", width, entry.get("width", _MISSING))
                _eq(errors, f"x_presets.{name}.height", height, entry.get("height", _MISSING))

    _enum(
        errors,
        "$defs.Artboard.properties.background_style.enum",
        BACKGROUND_STYLES,
        spec,
        "$defs",
        "Artboard",
        "properties",
        "background_style",
        "enum",
    )
    # Round-9: background_spacing is REQUIRED and must be a positive number.
    spacing = _dig(
        spec, "$defs", "Artboard", "properties", "background_spacing"
    )
    if spacing is _MISSING:
        errors.append("$defs.Artboard.properties.background_spacing: missing")
    elif not isinstance(spacing, dict):
        errors.append(
            f"$defs.Artboard.properties.background_spacing: expected object got {spacing!r}"
        )
    else:
        _eq(
            errors,
            "$defs.Artboard.properties.background_spacing.minimum",
            1,
            spacing.get("minimum", _MISSING),
        )
        required = _dig(spec, "$defs", "Artboard", "required")
        if not isinstance(required, list) or "background_spacing" not in required:
            errors.append(
                "$defs.Artboard.required: 'background_spacing' must be listed"
            )
    _enum(
        errors,
        "$defs.NodeStyle.properties.blend_mode.enum",
        BLEND_MODES,
        spec,
        "$defs",
        "NodeStyle",
        "properties",
        "blend_mode",
        "enum",
    )
    _enum(
        errors,
        "$defs.Element.properties.kind.enum",
        ELEMENT_KINDS,
        spec,
        "$defs",
        "Element",
        "properties",
        "kind",
        "enum",
    )
    # Round-9: PATH and TABLE joined the shape_type enum. Round-12 added TEXT.
    # The enum also carries a null member (shape_type is null for
    # stroke/image/line nodes), so the comparison drops it on both sides.
    shape_enum = _dig(
        spec, "$defs", "NodeGeometry", "properties", "shape_type", "enum"
    )
    if shape_enum is _MISSING:
        errors.append("$defs.NodeGeometry.properties.shape_type.enum: missing")
    elif not isinstance(shape_enum, list):
        errors.append(
            f"$defs.NodeGeometry.properties.shape_type.enum: expected list got {shape_enum!r}"
        )
    else:
        non_null = [value for value in shape_enum if value is not None]
        _eq(errors, "$defs.NodeGeometry.properties.shape_type.enum", SHAPE_TYPES, non_null)
    # Round-9: `fill` is OPTIONAL (a node without a fill omits the key so every
    # pre-round-9 document round-trips byte-identically).
    style_required = _dig(spec, "$defs", "NodeStyle", "required")
    if not isinstance(style_required, list):
        errors.append("$defs.NodeStyle.required: expected list")
    elif "fill" in style_required:
        errors.append("$defs.NodeStyle.required: 'fill' must stay OPTIONAL")

    rule = spec.get("x_upgrade_rule", _MISSING)
    if rule is _MISSING:
        errors.append("x_upgrade_rule: expected non-empty expression got <missing>")
    elif not isinstance(rule, str) or not rule.strip():
        errors.append(f"x_upgrade_rule: expected non-empty expression got {rule!r}")
    elif "INFINITE" not in rule:
        errors.append(f"x_upgrade_rule: expression must cover the INFINITE case got {rule!r}")
    return errors


def main(argv: list[str] | None = None) -> int:
    """Validate all three specs in argv[0] (default: this directory). 0 = all valid."""
    args = list(sys.argv[1:] if argv is None else argv)
    spec_dir = Path(args[0]) if args else Path(__file__).resolve().parent
    validators = {
        "validate_binary_frame": validate_binary_frame,
        "validate_ws_rpc": validate_ws_rpc,
        "validate_canvas_document": validate_canvas_document,
    }
    failed = False
    for name, validator_name in SPEC_CHECKS:
        path = spec_dir / name
        if not path.is_file():
            print(f"{path}: spec not yet written (Wave 1.A barrier)", file=sys.stderr)
            print(f"{name}: MISSING", flush=True)
            failed = True
            continue
        try:
            spec = load_spec(path)
        except SpecError:
            print(f"{name}: INVALID", flush=True)
            failed = True
            continue
        errors = validators[validator_name](spec)
        if errors:
            for error in errors:
                print(f"{name}: {error}", file=sys.stderr)
            print(f"{name}: INVALID", flush=True)
            failed = True
        else:
            print(f"{name}: VALID", flush=True)
    if failed:
        return 1
    print("OK: 3 specs valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
