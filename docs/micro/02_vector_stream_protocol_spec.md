# Doc 02: Vector Stream Protocol Spec

## 1. Objective & Scope
Locks the two SlateSync wire contracts of `overview.md` §4: (a) the fixed 16-byte little-endian binary live frame (§4.1) for 60 Hz pen/camera mirroring, and (b) the WebSocket JSON RPC envelope (§4.2) for committed elements, asset transfer, artboard upgrades, and export jobs. Deliverables are two `shared_specs/` JSON contract bodies embedded verbatim in §5; Docs 04/05 mirror them as code, Docs 11/25 implement them, Doc 01's `validate_specs.py` checks them.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `shared_specs/binary_stream_frame.json`
- `shared_specs/ws_rpc_schema.json`

### Read-only dependencies (imports, each cited as "Doc NN")
- `docs/overview.md` §4.1–§4.2 (Phase 0 orchestrator file — wire source of truth)
- `docs/_micro_doc_template.md` §3–§5 (Phase 0 orchestrator file — master constants, frozen mirrors)
- `pc_agent/core/protocol.py` (Doc 04) — Python mirror of this spec
- `mobile_app/lib/core/models/canvas_models.dart` (Doc 05) — Dart mirror of this spec
- `shared_specs/validate_specs.py` (Doc 01) — validates both outputs; `pc_agent/network/ws_stream_server.py` (Doc 11) and `mobile_app/lib/network/vector_sync_client.dart` (Doc 25) — consumers

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` (Doc 01)
- `shared_specs/canvas_document_schema.json` (Doc 03)
- `pc_agent/**` (Docs 04+), `mobile_app/**` (Docs 05+), `qa/**` (Doc 28)
- `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator)

## 3. Contract References
- `overview.md` §4.1 (16-byte frame), §4.2 (JSON envelope, handshake, asset transfer), §5 catalog entry 2, §6 Wave 1.A Subagent 2
- `_micro_doc_template.md` §3 rows: WebSocket port, Binary frame, FrameType, ToolId, Seq rule, RPC envelope, Asset chunks; §4 `pc_agent/core/protocol.py` block; §5 Dart `FrameType`/`ToolId`/`WireCodec` block; §6 matrix row 02

## 4. Interface Freeze
Wave 1.A artifacts — consume, never redefine (verbatim from `_micro_doc_template.md` §4–§5):

```python
# pc_agent/core/protocol.py (Doc 04 — mirrors Doc 02; import, never re-declare)
FRAME_LIVE_POINT, FRAME_LIVE_END, FRAME_CAMERA, FRAME_LASER = 0x01, 0x02, 0x03, 0x04
TOOL_PEN, TOOL_HIGHLIGHTER, TOOL_ERASER, TOOL_SHAPE_PREVIEW = 0x01, 0x02, 0x03, 0x04
@dataclass(frozen=True)
class LiveFrame:
    frame_type: int; tool_id: int; seq: int
    f1: float; f2: float; f3: float
def pack_live_frame(frame: LiveFrame) -> bytes: ...    # "<BBHfff", exactly 16 bytes
def unpack_live_frame(data: bytes | memoryview) -> LiveFrame: ...
```

```dart
// lib/core/models/canvas_models.dart (Doc 05) — wire JSON keys are snake_case
class FrameType { static const livePoint=0x01, liveEnd=0x02, camera=0x03, laser=0x04; }
class ToolId    { static const pen=0x01, highlighter=0x02, eraser=0x03, shapePreview=0x04; }
class LiveFrame { final int frameType, toolId, seq; final double f1, f2, f3; }
class WireCodec {
  static ByteData buildFrame({required int frameType, required int toolId,
      required int seq, required double f1, double f2=0, double f3=0}); // 16B LE <BBHfff
  static LiveFrame decodeFrame(Uint8List bytes);
}
```

Doc-specific frozen contract (top-level keys of the two files this doc creates):
`binary_stream_frame.json` → `spec, version, byte_length, byte_order, struct_format, fields, frame_type, tool_id, seq_rule, mirrors`;
`ws_rpc_schema.json` → `spec, version, transport, envelope, type_actions, asset_upload, export_job`.

## 5. Implementation Plan

**Step 1 — 16-byte frame layout (`overview.md` §4.1, struct `"<BBHfff"` little-endian):**

| Offset | Size | C type | Field | Meaning |
|---|---|---|---|---|
| 0 | 1 | uint8 | `frame_type` | FrameType enum byte |
| 1 | 1 | uint8 | `tool_id` | ToolId enum byte |
| 2–3 | 2 | uint16 | `seq` | per-connection monotonic counter |
| 4–7 | 4 | float32 | `f1` | arg 1 (per FrameType) |
| 8–11 | 4 | float32 | `f2` | arg 2 (per FrameType) |
| 12–15 | 4 | float32 | `f3` | arg 3 (per FrameType) |

**Step 2 — FrameType table (template §3):**

| Byte | Name | f1 | f2 | f3 |
|---|---|---|---|---|
| `0x01` | LIVE_POINT | `world_x` | `world_y` | `width_pressure_factor` |
| `0x02` | LIVE_END | `0.0` | `0.0` | `0.0` |
| `0x03` | CAMERA | `scale_zoom` | `translate_x` | `translate_y` |
| `0x04` | LASER | `world_x` | `world_y` | `0.0` |

**Step 3 — ToolId table (template §3):**

| Byte | `0x01` | `0x02` | `0x03` | `0x04` |
|---|---|---|---|---|
| Tool | Pen | Highlighter | Eraser | Line/Shape Preview |

**Step 4 — Seq rule (template §3):** u16, per-connection monotonic; receivers drop any frame whose `seq` is not newer than the last accepted one within a mod-2^16 window (wrap-around stays "newer"); counter resets per connection. Enforced in Doc 11 (server receive) and Doc 06 `submit_live_frame` latest-slot (template §4 threading note).

**Step 5 — Normative constant table (both mirrors):**

| Constant | Value | Python mirror — Doc 04, `pc_agent/core/protocol.py` | Dart mirror — Doc 05, `mobile_app/lib/core/models/canvas_models.dart` |
|---|---|---|---|
| Frame layout | 16 B LE `"<BBHfff"` | `pack_live_frame` / `unpack_live_frame` | `WireCodec.buildFrame` / `decodeFrame` |
| `0x01` LIVE_POINT | f1=x, f2=y, f3=width_pressure_factor | `FRAME_LIVE_POINT` | `FrameType.livePoint` |
| `0x02` LIVE_END | all 0.0 | `FRAME_LIVE_END` | `FrameType.liveEnd` |
| `0x03` CAMERA | f1=scale, f2=tx, f3=ty | `FRAME_CAMERA` | `FrameType.camera` |
| `0x04` LASER | f1=x, f2=y, f3=0.0 | `FRAME_LASER` | `FrameType.laser` |
| Tools `0x01–0x04` | Pen / Highlighter / Eraser / Line-Shape Preview | `TOOL_PEN`, `TOOL_HIGHLIGHTER`, `TOOL_ERASER`, `TOOL_SHAPE_PREVIEW` | `ToolId.pen`, `ToolId.highlighter`, `ToolId.eraser`, `ToolId.shapePreview` |
| Seq | u16 monotonic, stale-drop mod 2^16 | `LiveFrame.seq` | `LiveFrame.seq` |

**Step 6 — Drop `shared_specs/binary_stream_frame.json` (complete body, Wave 1.A writes verbatim):**

```json
{
  "spec": "slatesync.binary_stream_frame",
  "version": 1,
  "byte_length": 16,
  "byte_order": "little_endian",
  "struct_format": "<BBHfff",
  "fields": [
    {"name": "frame_type", "offset": 0,  "size": 1, "c_type": "uint8",   "description": "FrameType byte"},
    {"name": "tool_id",    "offset": 1,  "size": 1, "c_type": "uint8",   "description": "ToolId byte"},
    {"name": "seq",        "offset": 2,  "size": 2, "c_type": "uint16",  "description": "per-connection monotonic sequence"},
    {"name": "f1",         "offset": 4,  "size": 4, "c_type": "float32", "description": "float arg 1"},
    {"name": "f2",         "offset": 8,  "size": 4, "c_type": "float32", "description": "float arg 2"},
    {"name": "f3",         "offset": 12, "size": 4, "c_type": "float32", "description": "float arg 3"}
  ],
  "frame_type": {
    "0x01": {"name": "LIVE_POINT",  "f1": "world_x", "f2": "world_y", "f3": "width_pressure_factor"},
    "0x02": {"name": "LIVE_END",    "f1": 0.0, "f2": 0.0, "f3": 0.0},
    "0x03": {"name": "CAMERA",      "f1": "scale_zoom", "f2": "translate_x", "f3": "translate_y"},
    "0x04": {"name": "LASER",       "f1": "world_x", "f2": "world_y", "f3": 0.0}
  },
  "tool_id": {"0x01": "Pen", "0x02": "Highlighter", "0x03": "Eraser", "0x04": "Line/Shape Preview"},
  "seq_rule": {"type": "uint16", "scope": "per_connection", "order": "monotonic",
    "stale_drop": "receiver drops any frame whose seq is not newer than last accepted, mod 2^16 window"},
  "mirrors": ["pc_agent/core/protocol.py", "mobile_app/lib/core/models/canvas_models.dart"]
}
```

**Step 7 — JSON envelope per `overview.md` §4.2:** required keys `id` (uuid-v4), `type` (5-value enum), `action` (13-value extended list from template §3), `canvas_id` (uuid-v4), `payload` (object), `timestamp` (unix seconds). `type_actions` records the canonical pairing implied by the §4.2 grouping (enums remain the locked values).

**Step 8 — Drop `shared_specs/ws_rpc_schema.json` (complete body, Wave 1.A writes verbatim):**

```json
{
  "spec": "slatesync.ws_rpc_schema",
  "version": 1,
  "transport": {"scheme": "ws", "port": 50606, "path": "/ws", "token_param": "token",
    "url": "ws://<ipv4>:50606/ws?token=<session_token>", "bad_token_close_code": 4001},
  "envelope": {
    "required": ["id", "type", "action", "canvas_id", "payload", "timestamp"],
    "id": {"type": "string", "format": "uuid-v4"},
    "canvas_id": {"type": "string", "format": "uuid-v4"},
    "timestamp": {"type": "integer", "unit": "unix_seconds"},
    "payload": {"type": "object", "description": "shape defined by (type, action); element commits carry the overview §4.3 element object"},
    "type": {"enum": ["CANVAS_LIFECYCLE", "ELEMENT_COMMIT", "ARTBOARD_RESIZE", "ASSET_UPLOAD", "EXPORT_JOB"]},
    "action": {"enum": ["OPEN_CANVAS", "ADD_STROKE", "ADD_GRAPH", "ADD_SHAPE", "ADD_IMAGE",
      "DELETE_NODE", "UPGRADE_SIZE", "START_EXPORT", "CANCEL_EXPORT", "EXPORT_PROGRESS",
      "EXPORT_FINISHED", "ASSET_START", "ASSET_CHUNK", "ASSET_DONE",
      "CANVAS_LIST_REQUEST", "CANVAS_LIST", "CANVAS_OPEN_REQUEST",
      "CANVAS_PUT", "CANVAS_PULL", "CLEAR_CANVAS"]}
  },
  "type_actions": {
    "CANVAS_LIFECYCLE": ["OPEN_CANVAS", "CANVAS_LIST_REQUEST", "CANVAS_LIST", "CANVAS_OPEN_REQUEST",
      "CANVAS_PUT", "CANVAS_PULL"],
    "ELEMENT_COMMIT": ["ADD_STROKE", "ADD_GRAPH", "ADD_SHAPE", "ADD_IMAGE", "DELETE_NODE",
      "CLEAR_CANVAS"],
    "ARTBOARD_RESIZE": ["UPGRADE_SIZE"],
    "ASSET_UPLOAD": ["ASSET_START", "ASSET_CHUNK", "ASSET_DONE"],
    "EXPORT_JOB": ["START_EXPORT", "CANCEL_EXPORT", "EXPORT_PROGRESS", "EXPORT_FINISHED"]
  },
  "payload_schemas": {
    "OPEN_CANVAS": {
      "description": "dual dialect, discriminated by the presence of the 'canvas' key (exactly one dialect per message)",
      "discriminator": "canvas",
      "dialects": {
        "canvas": {
          "direction": "cross_device",
          "required": ["canvas"],
          "canvas": {
            "type": "object",
            "description": "complete Doc 03 CanvasDocumentModel document.json body (snake_case wire keys): canvas_id, title, created_at, updated_at, artboard, content_bounds, elements[...] — the receiver MUST load it as the currently-open document (replace scene/canvas state) and switch its UI to it"
          }
        },
        "path": {
          "direction": "pc_internal_only",
          "required": ["path"],
          "path": {
            "type": "string",
            "description": "filesystem path of a PC-local .slatesync file — MUST NEVER be sent over the wire; CanvasSyncManager (PC) ignores OPEN_CANVAS payloads lacking 'canvas', and the tablet never sends this dialect"
          }
        }
      }
    },
    "CANVAS_LIST_REQUEST": {
      "direction": "pc_to_tablet",
      "type": "object",
      "properties": {},
      "description": "request the tablet's canvas list (empty payload)"
    },
    "CANVAS_LIST": {
      "direction": "tablet_to_pc",
      "type": "object",
      "required": ["canvases"],
      "properties": {
        "canvases": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["id", "title", "preset", "background", "updated_at"],
            "properties": {
              "id": {"type": "string"},
              "title": {"type": "string"},
              "preset": {"type": "string"},
              "background": {"type": "string"},
              "updated_at": {"type": "integer", "unit": "unix_seconds"}
            }
          },
          "description": "may be EMPTY; sorted updated_at DESC; pushed unsolicited on (re)connect and after create/rename/delete, and sent in reply to CANVAS_LIST_REQUEST"
        }
      }
    },
    "CANVAS_OPEN_REQUEST": {
      "direction": "pc_to_tablet",
      "type": "object",
      "required": ["canvas_id"],
      "properties": {
        "canvas_id": {"type": "string"}
      },
      "description": "asks the tablet to load that document, switch its own UI to it, and broadcast OPEN_CANVAS {canvas: <full doc>}"
    },
    "CANVAS_PUT": {
      "direction": "any_to_any",
      "type": "object",
      "required": ["canvas", "source"],
      "properties": {
        "canvas": {
          "type": "object",
          "description": "complete Doc 03 CanvasDocumentModel document.json body (snake_case wire keys)"
        },
        "source": {"type": "string", "enum": ["device", "hub"]}
      },
      "description": "persist silently, NO UI switch: receiver stores locally first, then refreshes its list. LWW: apply only if canvas.updated_at >= local.updated_at (equal => keep local, no churn)"
    },
    "CANVAS_PULL": {
      "direction": "any_to_any",
      "type": "object",
      "required": ["canvas_id", "have_updated_at"],
      "properties": {
        "canvas_id": {"type": "string"},
        "have_updated_at": {"type": "integer", "unit": "unix_seconds"}
      },
      "description": "receiver replies CANVAS_PUT only if its stored copy has updated_at > have_updated_at"
    },
    "CLEAR_CANVAS": {
      "direction": "cross_device",
      "type": "object",
      "required": [],
      "properties": {},
      "description": "EMPTY payload {} (Doc 02 §10.1) — the target document is the envelope's canvas_id; the receiver wipes ALL elements of its open document (artboard/background/title preserved), bumps updated_at, persists (LWW), refreshes lists"
    }
  },
  "asset_upload": {
    "encoding": "base64",
    "raw_cap_bytes_per_chunk": 262144,
    "fields": {
      "transfer_id":  {"type": "string",  "actions": ["ASSET_START", "ASSET_CHUNK", "ASSET_DONE"]},
      "filename":     {"type": "string",  "actions": ["ASSET_START"]},
      "total_chunks": {"type": "integer", "actions": ["ASSET_START"]},
      "size_bytes":   {"type": "integer", "actions": ["ASSET_START"]},
      "index":        {"type": "integer", "actions": ["ASSET_CHUNK"]},
      "data_b64":     {"type": "string",  "actions": ["ASSET_CHUNK"], "raw_cap_bytes": 262144}
    },
    "abort_semantics": "only ASSET_DONE finalizes a transfer_id; an aborted transfer is never applied (partial data discarded)"
  },
  "export_job": {
    "formats": ["PNG", "JPG", "PDF"],
    "dpi_choices": [300, 600, 1200],
    "dpi_note": "required for PNG/JPG; PDF is vector and ignores dpi",
    "targets": ["PC", "TABLET", "BOTH"],
    "start":    {"direction": "tablet_to_pc", "payload": ["job_id", "format", "dpi", "target"]},
    "progress": {"direction": "pc_to_tablet", "payload": ["job_id", "percent"],
                 "rate": "<= 10 Hz plus one message per rendered strip"},
    "cancel":   {"direction": "tablet_to_pc", "payload": ["job_id"], "effect": "aborts the running export job"}
  }
}
```

**Step 9 — Handshake & close semantics:** clients connect to `ws://<ipv4>:50606/ws?token=<session_token>` (token delivered via Doc 12 mDNS/QR pairing); bad or missing token ⇒ server close code `4001` (Doc 11). Tablet→PC binary frames; JSON RPC both directions (Doc 11 `broadcast_json` for PC pushes).

**Step 10 — ASSET_UPLOAD transfer rules:** `ASSET_START` declares `transfer_id, filename, total_chunks, size_bytes`; each `ASSET_CHUNK` carries `transfer_id, index, data_b64` with ≤ `262144` raw bytes before base64 (≈349528 encoded chars); `ASSET_DONE` finalizes `transfer_id`. Used for image attachments (tablet→PC) and finished-export pushes (PC→tablet, Doc 15).

**Step 11 — EXPORT_JOB flow:** tablet sends `START_EXPORT` → Doc 15 `ExportCoordinator.submit` returns `job_id` → `EXPORT_PROGRESS` (`percent` 0–100) streams back ≤10 Hz + per strip → `CANCEL_EXPORT` aborts a running job; finished file goes back via the `ASSET_UPLOAD` path of Step 10.

**Step 12 — Four worked example messages (envelope keys per §4.2, snake_case payloads per §4.3):**

`ELEMENT_COMMIT` / `ADD_STROKE`:
```json
{"id": "6f1c2a9e-4d2b-4a77-9c5e-1b2f3d4e5a60", "type": "ELEMENT_COMMIT", "action": "ADD_STROKE",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"node_id": "3a7c9d15-5e84-4f0b-a2c6-8b1d7e4f9a03", "kind": "STROKE", "layer": 0,
   "bbox": [120.0, 300.0, 450.0, 620.0],
   "style": {"color": "#1E1E1E", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER"},
   "geometry": {"pts": [[120.4, 301.2], [124.8, 309.5], [131.0, 318.0]]}},
 "timestamp": 1760760000}
```

`EXPORT_JOB` / `START_EXPORT`:
```json
{"id": "1c9e0d7f-6a28-4b31-9f54-2e7a6c8b0d19", "type": "EXPORT_JOB", "action": "START_EXPORT",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"job_id": "b7e04c2d-8f31-4a06-9c77-5d2e1b9f8a40", "format": "PNG", "dpi": 600, "target": "TABLET"},
 "timestamp": 1760760001}
```

`EXPORT_JOB` / `EXPORT_PROGRESS`:
```json
{"id": "a2c68b1d-7e4f-49a0-8d35-6f1c2a9e4d2b", "type": "EXPORT_JOB", "action": "EXPORT_PROGRESS",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"job_id": "b7e04c2d-8f31-4a06-9c77-5d2e1b9f8a40", "percent": 42},
 "timestamp": 1760760003}
```

`ASSET_UPLOAD` / `ASSET_START` + `ASSET_CHUNK` + `ASSET_DONE` (`data_b64` elided — real chunks ≤ 262144 raw bytes):
```json
{"id": "d3b51e70-2c46-4f18-b7a9-0c4e8b2f5a37", "type": "ASSET_UPLOAD", "action": "ASSET_START",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"transfer_id": "t-5a9f", "filename": "img_9921.png", "total_chunks": 3, "size_bytes": 640000},
 "timestamp": 1760760010}
{"id": "e8c47a21-9b05-4d63-8f12-7a3e6d9c0b48", "type": "ASSET_UPLOAD", "action": "ASSET_CHUNK",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"transfer_id": "t-5a9f", "index": 0, "data_b64": "<base64 of <=262144 raw bytes>"},
 "timestamp": 1760760011}
{"id": "f0d63b58-1e72-4a94-b5c8-9e2a7f4d6c15", "type": "ASSET_UPLOAD", "action": "ASSET_DONE",
 "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
 "payload": {"transfer_id": "t-5a9f"}, "timestamp": 1760760012}
```

## 6. Testing & Acceptance Criteria
1. Both JSON files parse; `python shared_specs/validate_specs.py` (Doc 01) exits 0.
2. Enums equal template §3 exactly: 4 FrameTypes, 4 ToolIds, 5 types, 13 actions; `byte_length==16`, `struct_format=="<BBHfff"`, cap `262144`, port `50606`, close `4001`.
3. Doc 04 `test_protocol.py`: pack→unpack round-trip identity; `len(pack_live_frame(...)) == 16`; offsets per Step 1.
4. Doc 05 `wire_codec_test.dart`: `buildFrame` emits 16 LE bytes; `decodeFrame` reproduces frameType/toolId/seq/f1–f3.
5. Doc 11/25 integration: token mismatch ⇒ close `4001`; stale `seq` dropped (mod 2^16); each example message validates against `envelope.required`.
6. `ASSET_CHUNK` with 262145 raw bytes rejected; `START_EXPORT`/`CANCEL_EXPORT`/`EXPORT_PROGRESS` flow exercised end-to-end by Doc 15 (progress ≤10 Hz).

## 7. Parallel Execution Notes
**Wave:** 1.A — Subagent 2 (Wire Protocol Lock), parallel with Doc 01 (root configs), Doc 03 (`canvas_document_schema.json`), Doc 04 (`core/protocol.py` mirror), Doc 05 (`canvas_models.dart` mirror).

**Never touches (write-conflict guard):** `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` (Doc 01); `shared_specs/canvas_document_schema.json` (Doc 03); `pc_agent/**` incl. `core/protocol.py`, `core/events.py`, `main.py`, `pc_agent/tests/*` (Docs 04+); `mobile_app/**` incl. `lib/core/models/canvas_models.dart`, `mobile_app/test/*` (Docs 05+); `qa/**` (Doc 28); `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator).

**No-overlap confirmation:** Creates paths match template §6 row 02 exactly and appear in no other Wave 1.A row; Docs 04/05 *mirror* these contracts (read-only from Doc 02's perspective — they may never edit these JSONs); `validate_specs.py` (Doc 01) reads both files only after the Wave 1.A barrier.

---

## 8. Canvas Sync Extension (Round 4 — NORMATIVE, amends §4.2)

Round 4 adds **bidirectional canvas synchronization** (user issue 04). This section is binding over any earlier text in this doc. Implementation agents: apply this diff to `shared_specs/ws_rpc_schema.json` (PC sync agent), to the Python mirror `pc_agent/core/protocol.py`, to the Dart send-side validation (mobile sync agent), and to the embedded JSON body in §5 of this doc.

### 8.1 Action-set extension (14 → 17)

Add to `envelope.action.enum` and to `type_actions.CANVAS_LIFECYCLE`:

| Action | Direction | Payload schema |
|---|---|---|
| `CANVAS_LIST_REQUEST` | PC → Tablet | `{}` (request the tablet's canvas list) |
| `CANVAS_LIST` | Tablet → PC | `{canvases: [{id, title, preset, background, updated_at}]}` — may be EMPTY; sorted `updated_at` DESC; pushed unsolicited on (re)connect and after create/rename/delete, and sent in reply to `CANVAS_LIST_REQUEST` |
| `CANVAS_OPEN_REQUEST` | PC → Tablet | `{canvas_id}` — asks the tablet to broadcast that document and switch both sides to it |

Full action list after this extension (17): `OPEN_CANVAS, ADD_STROKE, ADD_GRAPH, ADD_SHAPE, ADD_IMAGE, DELETE_NODE, UPGRADE_SIZE, START_EXPORT, CANCEL_EXPORT, EXPORT_PROGRESS, EXPORT_FINISHED, ASSET_START, ASSET_CHUNK, ASSET_DONE, CANVAS_LIST_REQUEST, CANVAS_LIST, CANVAS_OPEN_REQUEST`.

### 8.2 `OPEN_CANVAS` dual dialect (critical)

`OPEN_CANVAS` now has two mutually exclusive payload dialects, discriminated by the presence of the `canvas` key:

* **`payload.path`** (legacy, PC-internal ONLY): a filesystem path for a PC-local `.slatesync` file. **Must never be sent over the wire** — `CanvasSyncManager` (PC) ignores `OPEN_CANVAS` messages whose payload lacks `canvas`; the tablet never sends this dialect.
* **`payload.canvas`** (cross-device): the **complete Doc 03 `CanvasDocumentModel` document** (`document.json` body: canvas_id, title, created_at, updated_at, artboard, content_bounds, elements[...] — snake_case wire keys). A peer receiving this MUST load it as the currently-open document (replace scene/canvas state) and switch its UI to it.

### 8.3 Canonical flows

1. **Tablet opens/creates/switches a canvas** (while connected) → broadcasts `OPEN_CANVAS {canvas: <full doc>}` → PC loads it into `DocumentStore` (new `open_payload()` path) → mirror switches (boundary, background, elements).
2. **Connect handshake** → tablet pushes `CANVAS_LIST` (current rows); PC also sends `CANVAS_LIST_REQUEST` on `CONNECTION_STATE(connected)`; PC caches the list for its File → "Open canvas…" dialog.
3. **PC opens a canvas** → dialog (from cached list) → `CANVAS_OPEN_REQUEST {canvas_id}` → tablet loads the document from its local store, **switches its own UI to it**, and broadcasts `OPEN_CANVAS {canvas: <full doc>}` → PC loads → both sides converged.
4. **Mutations** (`ELEMENT_COMMIT`, `ARTBOARD_RESIZE/UPGRADE_SIZE`, asset chunks) behave exactly as §4.2 against the currently-open document on both sides. PC is a full participant for OPEN/switch; drawing input remains tablet-originated in v1.

### 8.4 Example messages

```json
{"id":"…","type":"CANVAS_LIFECYCLE","action":"CANVAS_LIST","canvas_id":"","payload":{"canvases":[{"id":"c-1","title":"Control Systems 04","preset":"A4","background":"RULED","updated_at":1760763600}]},"timestamp":1760763601}
{"id":"…","type":"CANVAS_LIFECYCLE","action":"CANVAS_OPEN_REQUEST","canvas_id":"","payload":{"canvas_id":"c-1"},"timestamp":1760763602}
{"id":"…","type":"CANVAS_LIFECYCLE","action":"OPEN_CANVAS","canvas_id":"c-1","payload":{"canvas":{"canvas_id":"c-1","title":"Control Systems 04","created_at":1760760000,"updated_at":1760763600,"artboard":{"preset":"A4","width":2480.0,"height":3508.0,"is_infinite":false,"background_style":"RULED","background_color":"#FFFFFF"},"content_bounds":{"min_x":0,"min_y":0,"max_x":0,"max_y":0},"elements":[]}},"timestamp":1760763603}
```

### 8.5 Ownership of this round (write-conflict guard)

* **PC sync agent:** `shared_specs/ws_rpc_schema.json` (apply §8.1–8.2), the embedded JSON body inside THIS file's §5, `shared_specs/validate_specs.py` (make it derive the expected action set from `ws_rpc_schema.json` itself instead of any hardcoded count), `pc_agent/core/protocol.py` (`RPC_ACTIONS` = 17), plus its pc_agent modules/tests.
* **Mobile sync agent:** Dart send-side action validation (in `lib/network/`), receive tolerance for unknown incoming actions (never reject the three new ones), plus its mobile files.
* **Neither** may change envelope top-level keys, the 16-byte frame, `type` enum (still 5), or §4.2's existing payload shapes other than the `OPEN_CANVAS` dialect rule above.

---

## 9. Hub Sync & Multi-Device Extension (Round 5 — NORMATIVE, amends §8)

Round 5 turns the PC agent into a **sync hub** serving **any number of devices** with **PC-local storage** (user issues 03/04). All Round-5 agents implement exactly this section.

### 9.1 Action-set extension (17 → 19)

Add to `envelope.action.enum` + `type_actions.CANVAS_LIFECYCLE` (and Doc 02 §5 embedded body, PC mirrors):

| Action | Direction | Payload schema |
|---|---|---|
| `CANVAS_PUT` | any → any | `{canvas: <full Doc03 document>, source: "device"\|"hub"}` — **persist silently, NO UI switch**. Receiver stores locally first, then refreshes its list. **LWW rule: apply only if `canvas.updated_at >= local.updated_at`** (equal ⇒ keep local, no churn). |
| `CANVAS_PULL` | any → any | `{canvas_id, have_updated_at: int}` — receiver replies `CANVAS_PUT` only if its stored copy has `updated_at > have_updated_at`. |

### 9.2 `CANVAS_LIST` v2 payload (backward compatible)

`{device_id: str, device_name?: str, origin: "hub"|"device", canvases: [...]}` — `device_id` is a stable uuid generated once per app install (persisted); missing `device_id` ⇒ treat as `legacy-<conn>`.

* **Device → hub** (`origin:"device"`) on (re)connect and after create/rename/delete.
* **Hub → all devices** (`origin:"hub"`, merged store) whenever the hub store changes and on each new connection (broadcast acceptable).
* Hub keys its per-device caches by `device_id`; HUD/gallery may show `device_name` and connected-device count.

### 9.3 Persistence targets (every endpoint stores)

* **PC hub:** `%APPDATA%/SlateSync/canvases/<canvas_id>.slatesync` + `index.json` (`id,title,preset,background,updated_at,source_devices[]`) — DocumentStore save/open reused. PC browsing works **offline/read-only until a device pairs**; sync actions no-op without connections.
* **Device:** existing `LocalDb` + `.slatesync` archive (Doc 26 path).
* **Persist-on-open rule (amends §8.3):** a peer receiving `OPEN_CANVAS {canvas}` MUST persist it to its local store (LWW per 9.1) **before** switching UI. `CANVAS_PUT` persists without switching.

### 9.4 Canonical hub flows

1. **Fresh device joins:** device publishes `CANVAS_LIST (origin:device)` → hub merges (union by id, LWW on `updated_at`) → hub broadcasts `CANVAS_LIST (origin:hub)` → device diffs ids it lacks → sends `CANVAS_PULL` for each → hub replies `CANVAS_PUT` per doc → device stores silently (no navigation). Device then shows the shared canvases in its normal gallery (they are local rows now).
2. **Hub missing/older docs:** on a device list, hub PULLs ids it lacks or has older `updated_at` (device replies PUT). Sequential per id is fine (v1).
3. **Open/switch** remains §8.3 (OPEN_CANVAS switches everyone; CANVAS_OPEN_REQUEST fetches).
4. **New canvas anywhere:** device ⇒ save + `OPEN_CANVAS` broadcast + `CANVAS_LIST(device)` publish; PC (File→New) ⇒ persist to hub storage + broadcast `CANVAS_PUT` + `CANVAS_LIST(hub)`. Every endpoint ends with the same content.
5. **Mutations** (ELEMENT_COMMIT/…) unchanged; PC mirrors against the currently-open doc; multi-device writes are serialized by the hub's single WS thread; conflicts beyond LWW (concurrent same-canvas edits) ⇒ newer `updated_at` wins at receipt (v1 rule, documented limitation).

### 9.5 Round-5 ownership (write-conflict guard)

* **Protocol/hub agent (PC):** `ws_rpc_schema.json`, Doc 02 §5 embedded body, `validate_specs.py`, `core/protocol.py` (19), `core/events.py`, `network/canvas_sync.py` (v2: per-device state, merge, pull/put, hub list), `engine/document_store.py` (+ local index), NEW `engine/local_canvas_index.py`, `main.py`.
* **Studio UI agent (PC):** `gui/studio_window.py`, NEW `gui/canvas_gallery_panel.py`, `installer/slatesync_agent.spec` (bundle ico), runtime `iconbitmap`.
* **Mobile bridge agent:** `lib/features/sync/canvas_sync_bridge.dart` (+ pre-seeded `hubChanged` notifier contract) and sync tests only.
* **Mobile shell agent:** `lib/main.dart`, `lib/features/home/**` and their tests.
* Envelope top-level keys, frame layout, `type` enum and §4.2 payloads (other than 9.1/9.2 additions) remain unchanged.

---

## 10. Round-6 Extension — Clear, Live Relay, View/Export/Thumbnail Freezes (NORMATIVE)

### 10.1 Action-set (19 → 20)
Add `CLEAR_CANVAS` to `envelope.action.enum` under `type_actions.ELEMENT_COMMIT`. Payload `{}` (target identified by `canvas_id`). Receiver wipes ALL elements of the open document (artboard/background/title preserved), bumps `updated_at`, persists (LWW), refreshes lists.

### 10.2 Live mutation relay (multi-device real-time)
`WsStreamServer` must, AFTER local dispatch, re-broadcast to every **OTHER** connected device connection (sender excluded) any incoming message with `type == "ELEMENT_COMMIT"` (incl. `CLEAR_CANVAS`) or `type == "ARTBOARD_RESIZE"`. API freeze: `WsStreamStreamServer`'s `broadcast_json(msg: dict, exclude=None)` gains the additive optional `exclude` parameter (existing callers unchanged). Receiving endpoints: **PC applies always**; **devices apply only when `msg.canvas_id` equals their currently-open document** (else ignore silently).

### 10.3 Shape & graph geometry conventions
The NORMATIVE source for `geometry.pts` of `LINE | RECT | CIRCLE | TRIANGLE | ARROW | CARTESIAN_2D | NUMBER_LINE` is the PC implementation: `pc_agent/viewport/primitive_renderer.py` + `pc_agent/export/tiled_raster_exporter.py` + `vector_pdf_exporter.py` shape-drawing code (read-only reference). The mobile app MUST emit and preview the exact same point conventions — do not invent new layouts. (Thumbnails may approximate shapes; normative rendering may not.)

### 10.4 Export extent rule (issue 06 fix)
* Bounded preset ⇒ extent = EXACT artboard rect; `px = world * dpi / 300`, then strip-padded to the 2048 grid. A5/A4/Letter/Infinite must yield DISTINCT, proportionally-correct sizes per DPI.
* Infinite ⇒ content_bounds padded 64 world units (unchanged).
* Every loader/index path MUST preserve `artboard.preset/width/height/is_infinite` end-to-end; an extent resolving to content-size for a bounded doc is a bug.

### 10.5 View-fit-on-open (issue 03, both platforms)
On opening a document: zoom-to-fit with **48 world-unit padding**, centered via the §3 transform. Target rect: bounded ⇒ `(0, 0, width, height)`; infinite ⇒ `content_bounds` (empty ⇒ fallback `(-500,-500,1000,1000)`).
* PC: `GLCanvasHost.fit_viewport() -> None` + `@property camera_scale -> float` (frozen); `main.py` calls it after `DOCUMENT_LOADED` then refreshes `window.update_hud(...)`.
* Mobile: `CameraController.zoomToFit(rect, viewport)` after first layout frame in the canvas page.

### 10.6 Thumbnail contract (issue 07)
* Mobile (PRE-SEEDED, implemented): `Future<Uint8List> renderDocThumbnail(CanvasDocumentModel doc, {int size = 256})` and `Future<String> saveDocThumbnail(CanvasDocumentModel doc, String outPath, {int size = 256})` in `mobile_app/lib/canvas_engine/thumbnail_renderer.dart`.
* PC: `render_thumbnail(doc, out_path: Path, size: int = 192) -> Path` in `pc_agent/export/thumbnail_renderer.py`.
* Preset badges (A5/A4/LETTER/INFINITE) are **UI overlays**, never baked into the image. Local save paths must generate a thumbnail (mobile: inside `saveDocument`; PC: on-demand from the gallery panel, cached under `%APPDATA%/SlateSync/thumbs/`).

### 10.7 Tool-dock API freezes (issue 04)
* Per-tool property store: the exposed `config` notifier's `value` is **replaced** with the active tool's config on tool switch (existing host wiring keeps working unchanged); all round-5 ctor params preserved.
* Tool buttons: **tap = select**; **press-and-hold 2000 ms (custom Timer — Flutter's ~500 ms long-press is NOT used) = open that tool's property panel** (overlay; tap-outside closes).
* `onClearRequested` (VoidCallback?) — PRE-SEEDED in the ctor — fires only after the dock's confirmation dialog is accepted.
* Existing `onEraseRequest` / `onPickImage` / `onGraphCommitted` / `pickImage` / `planWorldRect` / `snapEnabled` semantics unchanged.

### 10.8 Round-6 ownership matrix (write-conflict guard)
PC: viewport+fit (`pc_agent/viewport/**`) · export+thumbnail renderer+extents (`pc_agent/export/**`, `engine/document_store.py`) · clear/relay/protocol mirrors+`engine/scene_graph.py`+`network/ws_stream_server.py`+`main.py`+spec JSONs (`shared_specs/**`, Doc 02 §5 body, `core/**`, `network/**`, `engine/scene_graph.py`, `main.py`) · gallery+studio (`pc_agent/gui/**`, its tests). Mobile: engine (`mobile_app/lib/canvas_engine/**` EXCEPT thumbnail_renderer which is frozen) · canvas page (`mobile_app/lib/features/canvas/**`) · dock (`mobile_app/lib/features/tools/**`) · home (`mobile_app/lib/features/home/**`, `core/storage/**`). Docs agent: `docs/overview.md` + `docs/micro/**` EXCEPT Doc 02. Contract tests: new `mobile_app/test/contract_*` files only.

## 11. Round-7 Extension — PC Authority, Device Roster, Static Pairing (NORMATIVE)

Round 7 keeps the §4–§10 wire contract byte-identical (still **20** actions, no new
envelope types, no new payload keys on existing messages) and adds **PC-side
orchestration state**. The PC agent is the single authority: a device mutation is
applied to the PC scene first, announced on the bus, and only then fanned out.

### 11.1 New bus events (additive — `core/events.py`)

| Event | Frozen payload | Emitted by |
|---|---|---|
| `RPC_ORIGIN` | `{msg: dict, connection_id: str\|None}` | Doc 11 `WsStreamServer` — right AFTER `RPC_MESSAGE` for the same envelope, only for frames that arrived off the wire |
| `DEVICES_UPDATED` | `{devices: [{connection_id, device_id, name, peer, open_canvas_id, open_canvas_title, mirrored, last_seen}], mirrored_canvas_id: str\|None, count: int}` | Doc 02 §9 hub (`DeviceRoster.emit_devices`) |
| `MIRROR_CHANGED` | `{canvas_id: str\|None, title: str, connection_id: str\|None}` | hub — first `OPEN_CANVAS` or a Settings switch |

`CONNECTION_STATE` gains an **optional** `connection_id` key (the per-connection
uuid minted by Doc 11); handlers must keep tolerating its absence.
`CANVAS_LIST_UPDATED` stays frozen at `{canvases, devices:int}` — the roster lives on
`DEVICES_UPDATED` so the round-5 payload is untouched.

### 11.2 Authority rules

1. **Apply-then-relay.** `WsStreamServer` dispatches locally (scene graph/store),
   emits `RPC_ORIGIN`, then relays through `set_relay_filter(...)`. The hub installs
   `CanvasSyncManager.allows_relay`, which returns `True` when no canvas is mirrored
   yet, and otherwise only for the mirrored `canvas_id`. Unmirrored canvases never
   cross devices.
2. **First open wins the mirror** (`DeviceRoster.note_open`). Two tablets on two
   canvases ⇒ the PC mirrors the first; the second is persisted (`CANVAS_PUT`/index)
   without moving the viewport. `select_mirror(canvas_id, title)` switches it from
   Settings and loads the stored body through `DocumentStore.open_payload`.
3. **The mirror is a canvas, not a connection.** A disconnecting device never blanks
   the PC viewport; only the source attribution is released.

### 11.3 Static pairing (Doc 12)

The session token moved from per-process to per-install: `network/pairing_store.py`
persists `{version, token, device_id, device_name, created_at, qr_payload}` in
`<appdata_dir>/pairing.json` (atomic tmp + `os.replace`). `pairing_qr.png` is written
**once** — a restart reuses the recorded `qr_payload` and skips re-encoding. The
tablet saves host/port/token and re-handshakes on every later launch (Doc 25).
`rotate_token()` (Settings → *Reset pairing*) is the only way to invalidate it.

### 11.4 Mirror rendering (Docs 06/08)

`viewport/mirror_scene.py::MirrorScene` is the live element registry: seeded from
`DOCUMENT_LOADED`, kept current by `COMMITTED_NODE` (upsert) / `CANVAS_CLEARED`
(clear). `GLCanvasHost._render` feeds `PrimitiveRenderer` from it instead of the
open-time `doc.elements`, which is why SHAPE / GRAPH_AXES / IMAGE commits from a
tablet now paint. With elements but no document/artboard, `MirrorArtboard` (infinite,
white) is substituted so primitives are never skipped.

### 11.5 Export destination & freshness (Doc 15)

`AppConfig.export_dir` defaults to the OS **Downloads** folder
(`config_manager.default_export_dir()`); `ConfigManager.set_export_dir(path)` persists
a Settings choice and takes effect on the next job (no restart). The output name is
`<slug(title)>.<ext>` (or `payload["filename"]`), collision-suffixed `(2)`, never a
job uuid and never allowed outside `export_dir`. `DocumentStore.snapshot_current()`
rebuilds the document from the **live scene graph**, so an edit made after the open
is in the file.

### 11.6 Settings panel (Doc 16)

`gui/settings_panel.py::SettingsPanel` lists connected devices (name, peer, open
canvas, which one is mirrored + a *Mirror* button), an **Export folder** row with a
native folder picker, and *Reset pairing*. `StudioWindow` owns it via
`open_settings()` (HUD **Settings** button + Tools → Settings…) with three injected
callbacks: `select_mirror`, `set_export_dir`, `rotate_pairing`.

### 11.7 Round-7 ownership matrix (write-conflict guard)
PC: `network/device_roster.py`, `network/pairing_store.py`, `network/discovery_pairing.py`,
`network/canvas_sync.py`, `network/ws_stream_server.py`, `viewport/mirror_scene.py`,
`viewport/empty_state_overlay.py`, `viewport/gl_canvas_host.py`, `gui/settings_panel.py`,
`gui/studio_window.py`, `export/export_coordinator.py`, `engine/document_store.py`,
`core/events.py`, `core/config_manager.py`, `main.py` + their tests. Mobile:
`network/vector_sync_client.dart`, `features/sync/**`, `core/storage/**` + their tests.
Docs agent: `docs/micro/**` EXCEPT the §5 body of Doc 02 (still schema-locked).

## 12. Round-10 Amendment - Mirror Follow, Sealed Loops, Lock Enforcement (NORMATIVE)

Round 10 fixed five mirror/tool defects. Only �12.1 changes observable
protocol behaviour; the rest are client-side rules with no new wire fields.

### 12.1 The PC mirror follows the device that owns it

Round 7 (�11.2, issue 07) pinned the mirror to the FIRST opened canvas so two
tablets on two canvases could not steal it. That rule also froze the *owning*
device: a tablet switching from canvas A to canvas B persisted B and left the
viewport on A, so the mirror kept A's artboard (the round-10 "background does
not refresh" report - the pattern was stale because the *document* was stale,
not the shader).

The rule is now three-part and MUST hold together:

| Actor | Result |
| --- | --- |
| First `OPEN_CANVAS` after startup | selects the mirror |
| The **owning** device opens a different canvas | mirror MOVES (document loads, `MIRROR_CHANGED` fires) |
| A **different** device opens its own canvas | persisted only, mirror untouched (round 7 preserved) |
| `select_mirror` from Settings | PINS the mirror; the owning device can no longer move it |
| `select_mirror(None)` | releases the pin; the next open claims the mirror again |

Ownership is tracked by `connection_id` and, across a reconnect (which mints a
new `connection_id`), by the tablet's announced `device_id`.

`MIRROR_CHANGED` is emitted AFTER the followed document is loaded, so listeners
that read the open document already see the new canvas.

### 12.2 The IMAGE asset root is re-resolved per mirrored canvas

`PrimitiveRenderer` resolves `geometry.asset_ref` against an injected asset
root and keeps only the basename (`resolve_asset_path`). The root used to be
injected from `DOCUMENT_LOADED` alone, so any canvas that became visible
without that event rendered every IMAGE with `assets_root is None` - the bare
filename resolved against the process working directory and the quad painted
the 1x1 magenta placeholder.

`GLCanvasHost.set_assets_root_resolver(canvas_id -> assets_dir)` now lets the
render pass re-resolve the folder whenever the mirrored canvas id changes.
`DOCUMENT_LOADED` injection stays (it is the warm path); the resolver is the
self-healing fallback and MUST NOT be removed.