# Doc 03: Canvas Document Schema Spec

## 1. Objective & Scope
Locks the `.slatesync` canvas document model (`overview.md` §4.3): snake_case document keys, the artboard preset matrix at 300-DPI world units, element kinds/style/geometry, the §4.4 non-destructive upgrade rule, `content_bounds` recomputation, and the ZIP container layout. Deliverable is the complete `shared_specs/canvas_document_schema.json` body embedded in §5; Docs 05/09/10 and Dart Docs 22/23/26 implement against it.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `shared_specs/canvas_document_schema.json`

### Read-only dependencies (imports, each cited as "Doc NN")
- `docs/overview.md` §4.3–§4.4 (Phase 0 orchestrator file — document/upgrade source of truth)
- `docs/_micro_doc_template.md` §3–§5 (Phase 0 orchestrator file — presets, upgrade rule, frozen models)
- `pc_agent/engine/scene_graph.py` (Doc 09), `pc_agent/engine/document_store.py` (Doc 10) — PC serializers/consumers
- `mobile_app/lib/core/models/canvas_models.dart` (Doc 05), `mobile_app/lib/canvas_engine/tiled_canvas_painter.dart` (Doc 22), `mobile_app/lib/canvas_engine/artboard_manager.dart` (Doc 23), `mobile_app/lib/features/home/home_canvas_dashboard.dart` (Doc 26) — Dart mirrors/consumers
- `shared_specs/validate_specs.py` (Doc 01) — validates this output

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` (Doc 01)
- `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` (Doc 02)
- `pc_agent/**` (Docs 04+), `mobile_app/**` (Docs 05+), `qa/**` (Doc 28)
- `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator)

## 3. Contract References
- `overview.md` §4.3 (document JSON), §4.4 (preset matrix & validation rule), `.slatesync` row of §5/§6, §5 catalog entry 3, §6 Wave 1.A Subagent 3
- `_micro_doc_template.md` §3 rows: Artboard presets, Upgrade rule, Backgrounds, Blend modes, `.slatesync` container, Autosave; §4 `NodeStyle`/`NodeGeometry`/`CanvasNode`/`Artboard`/`CanvasDocument` blocks; §5 Dart model blocks; §6 matrix row 03

## 4. Interface Freeze
Wave 1.A artifacts — consume, never redefine (verbatim from `_micro_doc_template.md` §4–§5; serialization follows the keys of this doc's schema):

```python
# pc_agent/engine/scene_graph.py (Doc 09)
@dataclass
class NodeStyle:
    color: str = "#1E1E1E"; stroke_width: float = 2.5
    opacity: float = 1.0; blend_mode: str = "SRC_OVER"
@dataclass
class NodeGeometry:
    pts: list[list[float]] = field(default_factory=list)
    shape_type: str | None = None            # RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE
    graph_config: dict | None = None
    asset_ref: str | None = None
@dataclass
class CanvasNode:
    node_id: str; kind: str                  # STROKE|HIGHLIGHT|LINE|SHAPE|GRAPH_AXES|IMAGE
    layer: int = 0
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    style: NodeStyle = field(default_factory=NodeStyle)
    geometry: NodeGeometry = field(default_factory=NodeGeometry)
    def content_bounds(self) -> dict[str, float]: ...      # {min_x,min_y,max_x,max_y}
    def validate_artboard_upgrade(self, target_preset: str, target_w: float | None, target_h: float | None) -> bool: ...
```

```python
# pc_agent/engine/document_store.py (Doc 10)
@dataclass
class Artboard:
    preset: str                               # A5|A4|LETTER|INFINITE
    width: float | None = None; height: float | None = None
    is_infinite: bool = False
    background_style: str = "BLANK"; background_color: str = "#FFFFFF"
@dataclass
class CanvasDocument:
    canvas_id: str; title: str
    created_at: int; updated_at: int
    artboard: Artboard
    content_bounds: dict[str, float]
    elements: list[CanvasNode]
class DocumentStore:
    def new(self, preset: str, title: str) -> CanvasDocument: ...
    def open(self, path: Path) -> CanvasDocument: ...       # unzips .slatesync
    def save(self, doc: CanvasDocument, path: Path | None = None) -> Path: ...
    def autosave_tick(self) -> None: ...                    # called every 10 s by main.py
```

```dart
// lib/core/models/canvas_models.dart (Doc 05) — wire JSON keys are snake_case
class Presets { static const a5=(w:1748.0,h:2480.0), a4=(2480.0,3508.0),
                      letter=(2550.0,3300.0); }               // INFINITE = null dims
class NodeStyleModel { String color; double strokeWidth; double opacity; String blendMode; }
class NodeGeometryModel { List<List<double>> pts; String? shapeType;
                          Map<String,dynamic>? graphConfig; String? assetRef; }
class CanvasNodeModel { String nodeId; String kind; int layer; List<double> bbox;
                        NodeStyleModel style; NodeGeometryModel geometry; }
class CanvasDocumentModel { String canvasId, title; int createdAt, updatedAt;
                            Artboard artboard; Map<String,double> contentBounds;
                            List<CanvasNodeModel> elements; }
class Artboard { String preset; double? width; double? height; bool isInfinite;
                 String backgroundStyle; String backgroundColor; }
class UpgradeResult { final bool allowed; final String? reasonKey; }  // Doc 23
class ArtboardManager {                                           // Doc 23
  Artboard get current; Rect get contentBounds; bool get isInfinite;
  void noteContent(Rect r);                                       // content_bounds union tracking
  UpgradeResult tryUpgrade(String targetPreset);                  // §4.4 rule
}
```

Doc-specific frozen contract (top-level keys of the created file): `schema keys $schema/$id/title/description/type/required/properties/$defs/x_upgrade_rule/x_presets/x_content_bounds_rule/x_container` — document instances use exactly the §4.3 snake_case keys; `x_*` keys annotate the schema itself, never document data.

## 5. Implementation Plan

**Step 1 — Freeze document top-level keys** (required, `overview.md` §4.3): `canvas_id` (uuid-v4), `title`, `created_at`/`updated_at` (unix seconds), `artboard` (→ `$defs/Artboard`), `content_bounds` (→ `$defs/ContentBounds`), `elements` (array of → `$defs/Element`).

**Step 2 — Preset matrix (template §3, 300-DPI world units, top-left origin (0,0)→(w,h))** — `is_infinite=false` for presets, `width`/`height` `null` for INFINITE:

| Preset | width | height | Extent |
|---|---|---|---|
| A5 | `1748.0` | `2480.0` | (0,0) → (1748, 2480) |
| A4 | `2480.0` | `3508.0` | (0,0) → (2480, 3508) |
| LETTER | `2550.0` | `3300.0` | (0,0) → (2550, 3300) |
| INFINITE | `null` | `null` | unbounded −∞…+∞ on both axes |

**Step 3 — Freeze element vocabulary:** kinds `STROKE | HIGHLIGHT | LINE | SHAPE | GRAPH_AXES | IMAGE`; `shape_type` `RECT | CIRCLE | TRIANGLE | ARROW | CARTESIAN_2D | NUMBER_LINE`; `background_style` `BLANK | RULED | DOT_GRID | ISO_GRID`; `blend_mode` `SRC_OVER | MULTIPLY` (all template §3 rows); `bbox = [min_x, min_y, max_x, max_y]` world units.

**Step 4 — Drop `shared_specs/canvas_document_schema.json` (complete body, Wave 1.A writes verbatim):**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "shared_specs/canvas_document_schema.json",
  "title": "SlateSync Canvas Document",
  "description": "Locked .slatesync document.json body (overview §4.3). All document keys snake_case.",
  "type": "object",
  "required": ["canvas_id", "title", "created_at", "updated_at", "artboard", "content_bounds", "elements"],
  "properties": {
    "canvas_id": {"type": "string", "description": "uuid-v4"},
    "title": {"type": "string"},
    "created_at": {"type": "integer", "description": "unix seconds"},
    "updated_at": {"type": "integer", "description": "unix seconds"},
    "artboard": {"$ref": "#/$defs/Artboard"},
    "content_bounds": {"$ref": "#/$defs/ContentBounds"},
    "elements": {"type": "array", "items": {"$ref": "#/$defs/Element"}}
  },
  "$defs": {
    "Artboard": {
      "description": "Page frame in 300-DPI world units; top-left origin (0,0) -> (w,h); INFINITE keeps width/height null.",
      "type": "object",
      "required": ["preset", "width", "height", "is_infinite", "background_style", "background_color"],
      "properties": {
        "preset": {"enum": ["A5", "A4", "LETTER", "INFINITE"]},
        "width": {"type": ["number", "null"], "description": "A5 1748.0 | A4 2480.0 | LETTER 2550.0 | null if INFINITE"},
        "height": {"type": ["number", "null"], "description": "A5 2480.0 | A4 3508.0 | LETTER 3300.0 | null if INFINITE"},
        "is_infinite": {"type": "boolean"},
        "background_style": {"enum": ["BLANK", "RULED", "DOT_GRID", "ISO_GRID"]},
        "background_color": {"type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"}
      }
    },
    "ContentBounds": {
      "description": "Union of all element bboxes recomputed after every mutation; empty document => all zeros (owners: PC Doc 09, Dart Docs 22+23).",
      "type": "object",
      "required": ["min_x", "min_y", "max_x", "max_y"],
      "properties": {"min_x": {"type": "number"}, "min_y": {"type": "number"},
                     "max_x": {"type": "number"}, "max_y": {"type": "number"}}
    },
    "NodeStyle": {
      "description": "Per-element paint settings (mirror: template §4 NodeStyle / Dart NodeStyleModel).",
      "type": "object",
      "required": ["color", "stroke_width", "opacity", "blend_mode"],
      "properties": {
        "color": {"type": "string", "pattern": "^#[0-9A-Fa-f]{6}$"},
        "stroke_width": {"type": "number", "minimum": 0},
        "opacity": {"type": "number", "minimum": 0, "maximum": 1},
        "blend_mode": {"enum": ["SRC_OVER", "MULTIPLY"]}
      }
    },
    "NodeGeometry": {
      "description": "Point list plus kind-specific fields; unused fields are null (mirror: template §4 NodeGeometry / Dart NodeGeometryModel).",
      "type": "object",
      "required": ["pts"],
      "properties": {
        "pts": {"type": "array", "items": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2},
                "description": "world-space points/Bézier controls; empty for IMAGE elements"},
        "shape_type": {"enum": ["RECT", "CIRCLE", "TRIANGLE", "ARROW", "CARTESIAN_2D", "NUMBER_LINE", null],
                       "description": "set for SHAPE/GRAPH_AXES, else null"},
        "graph_config": {"type": ["object", "null"],
          "properties": {"origin": {"type": "array", "items": {"type": "number"}},
                         "x_range": {"type": "array", "items": {"type": "number"}},
                         "y_range": {"type": "array", "items": {"type": "number"}},
                         "grid_step": {"type": "number"}, "show_labels": {"type": "boolean"}}},
        "asset_ref": {"type": ["string", "null"], "pattern": "^assets/",
                      "description": "ZIP entry path of the attached file, e.g. assets/img_9921.png"}
      }
    },
    "Element": {
      "description": "One vector node (overview §4.3); kind selects how geometry is interpreted.",
      "type": "object",
      "required": ["node_id", "kind", "layer", "bbox", "style", "geometry"],
      "properties": {
        "node_id": {"type": "string", "description": "uuid per node"},
        "kind": {"enum": ["STROKE", "HIGHLIGHT", "LINE", "SHAPE", "GRAPH_AXES", "IMAGE"]},
        "layer": {"type": "integer"},
        "bbox": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4,
                 "description": "[min_x, min_y, max_x, max_y] world units"},
        "style": {"$ref": "#/$defs/NodeStyle"},
        "geometry": {"$ref": "#/$defs/NodeGeometry"}
      }
    }
  },
  "x_presets": {"origin": "top_left_0_0", "units": "world_units_at_300_dpi",
    "A5": {"width": 1748.0, "height": 2480.0}, "A4": {"width": 2480.0, "height": 3508.0},
    "LETTER": {"width": 2550.0, "height": 3300.0}, "INFINITE": {"width": null, "height": null}},
  "x_upgrade_rule": "ALLOW = (target == \"INFINITE\") OR (content_bounds.min_x >= 0 AND content_bounds.min_y >= 0 AND content_bounds.max_x <= target.width AND content_bounds.max_y <= target.height)",
  "x_content_bounds_rule": "union of element bboxes after every mutation; empty document => {min_x:0,min_y:0,max_x:0,max_y:0}",
  "x_container": ".slatesync = ZIP: document.json (this schema) + assets/*"
}
```

**Step 5 — §4.4 upgrade rule as an exact boolean expression** (changing `artboard.preset` to `target`, whose `width`/`height` come from the Step 2 matrix):

```text
ALLOW(target) = (target == "INFINITE")
  OR ( content_bounds.min_x >= 0
   AND content_bounds.min_y >= 0
   AND content_bounds.max_x <= target.width
   AND content_bounds.max_y <= target.height )
```

Consequences: any in-bounds content may grow A5→A4→LETTER→INFINITE; INFINITE→preset downsizing is blocked iff content is out of bounds (negative or beyond target edges); empty docs (all-zero bounds) always pass. PC enforcement: Doc 09 `SceneGraph.validate_artboard_upgrade`; Dart enforcement: Doc 23 `ArtboardManager.tryUpgrade`.

**Step 6 — `content_bounds` recompute algorithm** (after **every** mutation — element insert/delete/transform, undo/redo, document load):
1. If `elements` is empty → `content_bounds = {min_x: 0.0, min_y: 0.0, max_x: 0.0, max_y: 0.0}`.
2. Else `min_x = min(e.bbox[0])`, `min_y = min(e.bbox[1])`, `max_x = max(e.bbox[2])`, `max_y = max(e.bbox[3])` over all elements.
3. Persist into `document.content_bounds` on save; emit `ARTBOARD_CHANGED(artboard, content_bounds)` (template §4 event matrix).
Owners: PC Doc 09 `SceneGraph.content_bounds()`; Dart Doc 22 (`TiledCanvasEngine.addCommitted`/`setDocument` forwards node bboxes) + Doc 23 (`ArtboardManager.noteContent` union tracking).

**Step 7 — `.slatesync` container layout (template §3 row):** ZIP archive with extension `.slatesync` (git-ignored per Doc 01); entries = `document.json` (this schema) + `assets/*` (binary attachments addressed by `geometry.asset_ref = "assets/<filename>"`). Writers/readers: PC Doc 10 `DocumentStore.open/save` (unzip/zip, autosave every 10 s via `autosave_tick`); tablet Doc 26 (`archive` package from Doc 05 `pubspec.yaml`).

**Step 8 — Worked example A5 document (stroke + graph):**

```json
{
  "canvas_id": "9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71",
  "title": "Control Systems Lecture 04",
  "created_at": 1760760000,
  "updated_at": 1760763600,
  "artboard": {"preset": "A5", "width": 1748.0, "height": 2480.0, "is_infinite": false,
               "background_style": "RULED", "background_color": "#FFFFFF"},
  "content_bounds": {"min_x": 120.0, "min_y": 300.0, "max_x": 1040.0, "max_y": 760.0},
  "elements": [
    {"node_id": "3a7c9d15-5e84-4f0b-a2c6-8b1d7e4f9a03", "kind": "STROKE", "layer": 0,
     "bbox": [120.0, 300.0, 450.0, 620.0],
     "style": {"color": "#1E1E1E", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER"},
     "geometry": {"pts": [[120.4, 301.2], [124.8, 309.5], [131.0, 318.0]],
                  "shape_type": null, "graph_config": null, "asset_ref": null}},
    {"node_id": "c4e8b2a7-91d3-4c56-b0f8-7d2a5e6c1f44", "kind": "GRAPH_AXES", "layer": 0,
     "bbox": [520.0, 300.0, 1040.0, 760.0],
     "style": {"color": "#1E1E1E", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER"},
     "geometry": {"pts": [[520.0, 300.0], [520.0, 760.0], [1040.0, 760.0]],
                  "shape_type": "CARTESIAN_2D",
                  "graph_config": {"origin": [520.0, 760.0], "x_range": [-10, 10],
                                   "y_range": [-10, 10], "grid_step": 25.0, "show_labels": true},
                  "asset_ref": null}}
  ]
}
```
`content_bounds` = union of the two bboxes `[120,300,450,620] ∪ [520,300,1040,760]` = `[120,300,1040,760]` ⊂ A5 ⇒ `ALLOW(A4)=true`, `ALLOW(INFINITE)=true`.

**Step 9 — Worked example INFINITE document (image):**

```json
{
  "canvas_id": "e5b0f7d3-2c81-4a94-9d17-6f3b8a0e2c55",
  "title": "Sensor Fusion Whiteboard",
  "created_at": 1760760000,
  "updated_at": 1760767200,
  "artboard": {"preset": "INFINITE", "width": null, "height": null, "is_infinite": true,
               "background_style": "BLANK", "background_color": "#FFFFFF"},
  "content_bounds": {"min_x": -200.0, "min_y": -100.0, "max_x": 800.0, "max_y": 640.0},
  "elements": [
    {"node_id": "7f2a9c6b-4d10-4e88-a3b5-1c9e0d7f6a28", "kind": "IMAGE", "layer": 0,
     "bbox": [-200.0, -100.0, 800.0, 640.0],
     "style": {"color": "#FFFFFF", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER"},
     "geometry": {"pts": [], "shape_type": null, "graph_config": null,
                  "asset_ref": "assets/img_9921.png"}}
  ]
}
```
Negative bounds are legal only for INFINITE: `ALLOW(A5/A4/LETTER)=false` (min_x<0), `ALLOW(INFINITE)=true`.

## 6. Testing & Acceptance Criteria
1. File parses as JSON; `python shared_specs/validate_specs.py` (Doc 01) exits 0 (presets, 4 backgrounds, 2 blend modes, 6 kinds, upgrade-rule present).
2. Both Step 8/Step 9 example documents validate against the schema (all required keys, enums, bbox arity 4).
3. `content_bounds` checks: A5 example union recomputes to `[120,300,1040,760]`; empty document ⇒ all zeros.
4. Upgrade-rule truth table: A5→A4 with A5-fit content = allow; INFINITE→LETTER with negative bounds = deny; empty doc → any preset = allow (Doc 09 `test_scene_graph.py`, Doc 23 `artboard_manager_test.dart`).
5. Container round-trip: Doc 10 save→open preserves `document.json` + `assets/*`; Doc 26 reads the same ZIP.
6. Element JSON emitted by Doc 21 `ProcessedStroke.toRpcPayload()` and Doc 05 `toJson()` matches these keys exactly (snake_case, no extras).

## 7. Parallel Execution Notes
**Wave:** 1.A — Subagent 3 (Document Schema Lock), parallel with Doc 01 (root configs), Doc 02 (wire JSONs), Doc 04 (PC boilerplate), Doc 05 (Flutter boilerplate).

**Never touches (write-conflict guard):** `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` (Doc 01); `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` (Doc 02); `pc_agent/**` incl. `engine/scene_graph.py`, `engine/document_store.py`, `pc_agent/tests/*` (Docs 04+); `mobile_app/**` incl. `lib/core/models/canvas_models.dart`, `mobile_app/test/*` (Docs 05+); `qa/**` (Doc 28); `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator).

**No-overlap confirmation:** the Creates path matches template §6 row 03 exactly and appears in no other Wave 1.A row; Docs 05/09/10/22/23/26 *consume* this schema (read-only from Doc 03's perspective — they may never edit this JSON); `validate_specs.py` (Doc 01) reads it only after the Wave 1.A barrier.

---

## 8. Round-9 Amendment — `fill`, `groups`, `PATH` and `TABLE` (NORMATIVE)

Round 9 needed four things the frozen v1 schema could not express. All four are **additive**: every
pre-round-9 document still validates, loads and re-saves byte-identically.

### 8.1 `NodeStyle.fill` — OPTIONAL interior colour (issue 04)

```json
"fill": {"type": ["string", "null"], "pattern": "^#[0-9A-Fa-f]{6}$"}
```

The paint bucket keeps the outline and paints the interior, so the fill cannot ride on `color` or on
`stroke_width`. The key is **omitted** (never `null`) when a node has no fill, which is what makes the
round trip byte-identical. `stroke_width == 0` remains the legacy spelling of "solid in `color`" and is
honoured identically by all four renderers (`pc_agent/viewport/shape_fill.py`).

A malformed `fill` is DROPPED on load (the node keeps its outline) rather than rejecting the document.

### 8.2 Document-level `groups` — OPTIONAL lock groups (issue 05)

```json
"groups": {"type": "object", "additionalProperties": {"type": "array", "items": {"type": "string"}, "minItems": 1}}
```

`group_id → [node_id, ...]`. A locked group behaves as ONE object in the selector until unlocked.
`NodeStyle` is frozen and a group is a document-level relation anyway (a node belongs to at most one
group), so a per-node flag was never an option. Omitted when empty; a malformed map drops.

### 8.3 `shape_type` gains `PATH` and `TABLE`

```json
"shape_type": {"enum": ["RECT","CIRCLE","TRIANGLE","ARROW","CARTESIAN_2D","NUMBER_LINE","PATH","TABLE", null]}
```

* **`PATH`** — a closed polygon in `pts`. Rotation output: a rotated RECT/CIRCLE/TRIANGLE cannot stay
  that type because `bbox` is axis-aligned by contract. It also renders a pen loop that the fill tool
  closed. Filled when `fill` (or `stroke_width == 0`) says so; stroked along its full outline.
  A 2-point PATH renders as the open segment it is rather than being dropped.
* **`TABLE`** — a grid described by `graph_config` (`rows`, `cols`, `header_row`, `header_col`).
  `rows`/`cols` are TOTAL cell counts, header band included, clamped to 1..200 × 1..40. Header bands are
  filled rectangles; every grid segment (borders included) is stroked.

### 8.4 Why not new `kind` values

`kind` (`STROKE|HIGHLIGHT|LINE|SHAPE|GRAPH_AXES|IMAGE`) selects how geometry is INTERPRETED; both round-9
additions are shapes with a different geometry interpretation, which is exactly what `shape_type`
already discriminates (CARTESIAN_2D / NUMBER_LINE prove the pattern). Adding kinds would have forced
every `_addActionForKind` / `_DEFAULT_KINDS` / exporter branch to grow a case for no gain.

### 8.5 PC mirror parity

* `pc_agent/viewport/vector_geometry.py` — polygon/ellipse/triangle builders, closure test,
  point-in-polygon, ear-clipping triangulation, table grid. Shared by the GL viewport and all three
  exporters, so the four renderers cannot drift.
* `pc_agent/export/cairo_shapes.py` — the cairo outline/fill builder the raster, PDF and thumbnail
  exporters now share (they had already drifted once over arrow geometry).
* `CanvasDocument.groups` round-trips through `_doc_to_json` / `_doc_from_json`.

### 8.6 Acceptance

* `shared_specs/validate_specs.py` pins the extended `shape_type` enum and asserts `fill` stays
  OPTIONAL (`NodeStyle.required` must not list it).
* `pc_agent/tests/test_document_store.py` — `fill`/`groups` optional, round-tripped, and a hostile
  value never fails a load.
