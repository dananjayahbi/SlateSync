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
RPC_TYPES = ["CANVAS_LIFECYCLE", "ELEMENT_COMMIT", "ARTBOARD_RESIZE", "ASSET_UPLOAD", "EXPORT_JOB"]
# Doc 01 section 6 counts 13 actions (the Doc 02 locked body); template section 3
# lists the same 13 plus EXPORT_FINISHED (14 values). Accept either exact set so
# both locked spellings validate; anything else is a violation.
RPC_ACTIONS_13 = [
    "OPEN_CANVAS",
    "ADD_STROKE",
    "ADD_GRAPH",
    "ADD_SHAPE",
    "ADD_IMAGE",
    "DELETE_NODE",
    "UPGRADE_SIZE",
    "START_EXPORT",
    "CANCEL_EXPORT",
    "EXPORT_PROGRESS",
    "ASSET_START",
    "ASSET_CHUNK",
    "ASSET_DONE",
]
RPC_ACTION_EXTRA = "EXPORT_FINISHED"

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
BACKGROUND_STYLES = ["BLANK", "RULED", "DOT_GRID", "ISO_GRID"]
BLEND_MODES = ["SRC_OVER", "MULTIPLY"]
ELEMENT_KINDS = ["STROKE", "HIGHLIGHT", "LINE", "SHAPE", "GRAPH_AXES", "IMAGE"]

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

    actions = _dig(spec, "envelope", "action", "enum")
    core = set(RPC_ACTIONS_13)
    allowed = core | {RPC_ACTION_EXTRA}
    if actions is _MISSING:
        errors.append(f"envelope.action.enum: expected {RPC_ACTIONS_13} got <missing>")
    elif not isinstance(actions, list):
        errors.append(f"envelope.action.enum: expected list of actions got {actions!r}")
    elif not set(actions) == core and not set(actions) == allowed:
        missing = sorted(core - set(actions))
        unexpected = sorted(set(actions) - allowed)
        detail = []
        if missing:
            detail.append(f"missing {missing}")
        if unexpected:
            detail.append(f"unexpected {unexpected}")
        errors.append(
            "envelope.action.enum: expected the 13 locked actions "
            f"(or 14 with {RPC_ACTION_EXTRA}), got {actions!r}"
            + (f" ({', '.join(detail)})" if detail else " (duplicate entries)")
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
