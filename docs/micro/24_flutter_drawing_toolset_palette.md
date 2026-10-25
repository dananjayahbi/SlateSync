# Doc 24: Flutter Drawing Toolset Palette

## 1. Objective & Scope
Build the floating, collapsible **tool dock** for the infinite canvas: Pen, Multiply Highlighter, Precision/Stroke Eraser, snapping Line, geometric shapes (Rect, Circle, Triangle, Arrow), Graph Builder dialogs, and the Image importer. The dock is **pure UI state**: it owns `ValueNotifier`s and emits DTOs (`ToolConfig`, `PendingImage`, graph-config maps, erase callbacks) — it never opens a socket or imports network code. The canvas page wires `sendRpc`/`ADD_IMAGE`/`ASSET_UPLOAD`/`DELETE_NODE` per Doc 02 in Wave 3.A. Line/shape previews stream live frames tagged `ToolId.shapePreview` (0x04); committed nodes travel later as Doc 02 RPC.

**Round-6 (Doc 02 §10.7) freezes:** a **per-tool property store** — selecting a tool *replaces* `config.value` with that tool's stored config (host wiring unchanged; the boot-time active tool keeps the host's live instance) and every panel edit writes back into the store; **tap = select**, **press-and-hold 2000 ms** (custom `Timer` — Flutter's ~500 ms `onLongPress` is intentionally NOT used) opens that tool's property panel overlay (tap-outside closes); the rail's **Clear** button fires `onClearRequested` only after its confirmation dialog is accepted. All round-5 ctor params (`pickImage`, `planWorldRect`, `snapEnabled`) are preserved.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/features/tools/tool_palette_dock.dart`
- `mobile_app/lib/features/tools/tool_property_panels.dart` (round-6, Doc 02 §10.7 — property-panel contents)
- `mobile_app/test/tool_palette_dock_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- Doc 05 `mobile_app/lib/core/models/canvas_models.dart` — `ToolId`, `NodeStyleModel` style keys
- Doc 05 `mobile_app/lib/core/theme/studio_theme.dart` — dock palette/radii
- Doc 21 `mobile_app/lib/canvas_engine/stroke_processor.dart` — `StrokeProcessor(color, width, highlighter)` consumes `ToolConfig`; `ProcessedStroke.kind` is `"STROKE" | "HIGHLIGHT"`
- Doc 02 `shared_specs/ws_rpc_schema.json` — `DELETE_NODE`, `ADD_IMAGE`, `ASSET_START/CHUNK/DONE` shapes (wired by the canvas page, not this doc)
- Doc 03 `shared_specs/canvas_document_schema.json` — `graph_config` key contract
- Doc 05 pubspec — `image_picker`

### Never touches (paths owned by concurrent docs — write-conflict guard)
`mobile_app/lib/network/vector_sync_client.dart` (Doc 25), `mobile_app/lib/features/home/**` + `mobile_app/lib/core/storage/**` (Doc 26), `mobile_app/lib/features/export/**` (Doc 27), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/core/models/canvas_models.dart` (Doc 05), `shared_specs/**` (Docs 02/03), `pc_agent/**`

## 3. Contract References
- Doc 02 §4.2 envelope and actions `ADD_IMAGE`, `DELETE_NODE`, `ASSET_START`, `ASSET_CHUNK`, `ASSET_DONE`; asset chunks `data_b64` ≤ `262144` bytes raw
- Doc 02 §10.7 tool-dock API freezes: per-tool config store (`config.value` replaced on tool switch), tap = select / 2000 ms custom-Timer hold = open property panel (Flutter's ~500 ms `onLongPress` NOT used), `onClearRequested` (VoidCallback?) PRE-SEEDED in the ctor and fired only after the confirmation dialog is accepted; `onEraseRequest` / `onPickImage` / `onGraphCommitted` / `pickImage` / `planWorldRect` / `snapEnabled` semantics unchanged
- Doc 03 element JSON: `style.{color,stroke_width,opacity,blend_mode}`, `geometry.shape_type ∈ RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE`, `geometry.graph_config`
- Template §3 constants: `ToolId` `0x01` Pen / `0x02` Highlighter / `0x03` Eraser / `0x04` Line-Shape Preview; blend modes `SRC_OVER`/`MULTIPLY` (GL `GL_DST_COLOR, GL_ZERO`; cairo `CAIRO_OPERATOR_MULTIPLY`); default style `#1E1E1E` @ `2.5` @ opacity `1.0`; stroke decimation `2.0 dp` (Doc 21)

## 4. Interface Freeze
**Consumed — Doc 05 (verbatim, template §5):**
```dart
class ToolId    { static const pen=0x01, highlighter=0x02, eraser=0x03, shapePreview=0x04; }
class NodeStyleModel { String color; double strokeWidth; double opacity; String blendMode; }
```
**Consumed — Doc 21 (verbatim, template §5):**
```dart
class StrokeProcessor {                                           // Doc 21
  StrokeProcessor({required Offset Function(Offset) toWorld,
                   required String color, required double width,
                   required bool highlighter});
  void addPoint(Offset screenPos, double? pressure, int pointer);
  List<Offset> get livePoints;
  bool get rejecting;                                             // palm currently active
  ProcessedStroke? finish();                                      // decimate 2.0 dp + fit Bézier
}
```
**Exported (doc-specific API):**
```dart
enum StudioTool { pen, highlighter, eraser, line, rect, circle, triangle, arrow,
                  cartesianGraph, numberLine, image }
enum EraserMode { precision, stroke }          // both erase the hit-tested node via DELETE_NODE

class ToolConfig {
  String color = '#1E1E1E'; double width = 2.5; double opacity = 1.0;
  String blendMode = 'SRC_OVER';               // forced 'MULTIPLY' while highlighter == true
  bool highlighter = false;
  EraserMode eraserMode = EraserMode.precision;
}

class PendingImage { final Uint8List bytes; final String filename;
                     final int widthPx, heightPx; final Rect plannedWorldRect; }

int toolIdFor(StudioTool t);                   // table below; previews use ToolId.shapePreview
Map<String, dynamic> buildCartesianConfig({required List<double> origin,
    required List<int> xRange, required List<int> yRange,
    required double gridStep, bool showLabels = true});
Map<String, dynamic> buildNumberLineConfig({required List<int> range,
    required double step, bool showLabels = true});

class ToolDock extends StatefulWidget {
  const ToolDock({super.key, required this.config, required this.tool,
                  this.onEraseRequest, this.onPickImage, this.onGraphCommitted,
                  this.onClearRequested,                       // round-6 PRE-SEEDED (Doc 02 §10.7)
                  this.pickImage, this.planWorldRect, this.snapEnabled});  // round-5 params preserved
  final ValueNotifier<ToolConfig> config;      // injected; on tool switch the dock REPLACES value with
                                               // the active tool's stored config (Doc 02 §10.7);
                                               // panel edits mutate the live instance in place and
                                               // write it back into the per-tool store
  final ValueNotifier<StudioTool> tool;        // active tool; previews use toolIdFor(tool)
  final void Function(String nodeId)? onEraseRequest;     // canvas page sends DELETE_NODE
  final void Function(PendingImage img)? onPickImage;     // canvas page sends ASSET_* + ADD_IMAGE
  final void Function(String shapeType, Map<String, dynamic> graphConfig)? onGraphCommitted;
  final VoidCallback? onClearRequested;        // fires ONLY after the Clear confirmation dialog is accepted
}                                             // expand/collapse state kept internally

ToolConfig defaultToolConfig(StudioTool tool);  // §10.7 per-tool store defaults
   // pen/line/shapes/image #1E1E1E @2.5 @1.0 · highlighter #F1C40F @8.0 @0.4 MULTIPLY ·
   // eraser width 10 (hit radius, precision) · graphs #4F8EF7 @2.0
```

**`StudioTool` → `ToolId` byte mapping (tested table):**

| StudioTool | ToolId byte | Streams live preview frames? |
|---|---|---|
| `pen` | `0x01` | yes (`LIVE_POINT`) |
| `highlighter` | `0x02` | yes (`LIVE_POINT`, MULTIPLY) |
| `eraser` | `0x03` | no (hit-test → RPC only) |
| `line`, `rect`, `circle`, `triangle`, `arrow`, `cartesianGraph`, `numberLine` | `0x04` | yes (`ToolId.shapePreview`) |
| `image` | `0x04` | no (import flow only) |

## 5. Implementation Plan
1. **Enums & config model** — declare `StudioTool` (11 values), `EraserMode`, `ToolConfig` with the defaults above; add `int toolIdFor(StudioTool)` returning the Doc 02 `ToolId` byte: pen 1, highlighter 2, eraser 3, every live-preview tool (line, rect, circle, triangle, arrow, cartesianGraph, numberLine) 4, image 4 (placement only — streams no frames).
2. **Dock chrome & gestures** — `ToolDock` stateful widget: fixed left rail of tool icons; internal `_expanded` bool toggles an `AnimatedContainer` (collapsed ≈ 48 dp rail, expanded reveals sub-panel); keys `ValueKey('dock-toggle')`, `ValueKey('dock-panel')` for widget tests. **§10.7 gestures:** rail buttons use `onTapDown/onTapUp` semantics — **tap = select instantly**; a **custom `Timer` of exactly 2000 ms** armed on pointer-down opens that tool's property panel (deliberately NOT Flutter's ~500 ms `onLongPress`); the timer is cancelled on pointer-up/cancel, on drag beyond an 18 dp slop (reclassifies as scroll), on any other pointer-down in the rail, on toggle, and on dispose. A completed hold **also selects the held tool first**, then opens the overlay — so panel rows can never desync from `config.value`.
3. **Pen/Highlighter panel** — width slider (0.5–24.0 dp) writing `config.value.width`; color swatch grid + opacity field; selecting highlighter sets `highlighter=true`, `blendMode='MULTIPLY'` and shows the note: “Multiply blend (GL: `GL_DST_COLOR,GL_ZERO` / cairo: `CAIRO_OPERATOR_MULTIPLY`)”.
4. **Eraser panel** — segmented precision/stroke toggle writes `config.value.eraserMode`; caption: precision = tap a node ⇒ DELETE_NODE of the hit-tested node, stroke = drag ⇒ same action per hit node. Hit-test (Doc 22 R-Tree query) and the RPC live in the canvas page; the dock only forwards `onEraseRequest(nodeId)` — **no network calls here**.
5. **Line snapping panel** — snapping toggle + fixed increment `15°` with cardinals (0/90/180/270°) always included; held in a dock-local `ValueNotifier<bool> snapEnabled` (not part of the frozen `ToolConfig`) and read by the canvas page; the canvas preview applies the snap on long-press and streams preview frames with `toolIdFor(line) == 0x04`.
6. **Shape pickers** — Rect/Circle/Triangle/Arrow buttons set `tool.value`; while any shape or graph tool is active, in-flight previews stream `ToolId.shapePreview` frames (Doc 05 `WireCodec` is used by the canvas page, not the dock).
7. **Graph Builder dialogs** — one `showDialog` per graph type with form fields, producing exactly the Doc 03 objects:
   ```json
   { "origin": [250.0, 450.0], "x_range": [-10, 10], "y_range": [-10, 10],
     "grid_step": 25.0, "show_labels": true }
   ```
   ```json
   { "range": [-10, 10], "step": 1.0, "show_labels": true }
   ```
   validate → `onGraphCommitted('CARTESIAN_2D'|'NUMBER_LINE', config)`; canvas page builds `ADD_GRAPH`.
8. **Image importer** — `ImagePicker().pickImage(source: gallery)` → bytes + intrinsic px dims → construct `PendingImage` with `plannedWorldRect` from a page-supplied planner (Doc 20 camera converts screen fit to world units) → `onPickImage(img)`; the canvas page performs `ASSET_START/CHUNK/DONE` (≤ 262144 raw/chunk) then `ADD_IMAGE` per Doc 02. Dock returns bytes only.
9. **Per-tool property store (§10.7)** — `Map<StudioTool, ToolConfig> _perTool` seeded with `defaultToolConfig(tool)` per tool (the boot-time active tool instead keeps the host's live instance); `_selectTool` first flushes the outgoing tool's live instance into the store, then **replaces** `widget.config.value` with the stored instance for the next tool (never mutates the old instance in place on a switch), forcing `highlighter/blendMode` per tool. Every panel edit routes through a commit hook that mutates the live `config.value`, writes it back into `_perTool[current]`, and `notifyListeners()` (reference-equal `value` only notifies on change). Property-panel *contents* live in `tool_property_panels.dart` (tip slider + preview dot, 8-swatch palette, opacity, eraser mode, snapping, graph/image entries, round-6 snap/label hints) rendered both in the expanded sub-panel and in the hold overlay (260 dp, shared `toolPanelWidth`).
10. **Clear-canvas utility (§10.7)** — a `ValueKey('clear-canvas')` button in the rail's utility row opens a confirmation dialog ("Clear entire canvas?", `clear-cancel` / `clear-confirm` keys); **accepting** calls the PRE-SEEDED `onClearRequested?.call()` exactly once, cancelling is a no-op — the actual `CLEAR_CANVAS` RPC is the canvas page's job (Doc 02 §10.1), never this widget's.
11. **Tests** — `ToolConfig` defaults; `toolIdFor` byte table (pen=1, highlighter=2, eraser=3, preview tools=4); `buildCartesianConfig`/`buildNumberLineConfig` emit all required keys; widget test pumps `ToolDock`, taps `dock-toggle`, asserts panel appears/collapses.

## 6. Testing & Acceptance Criteria
- `flutter test test/tool_palette_dock_test.dart` green; `flutter analyze` clean.
- Defaults asserted exactly: `#1E1E1E`, `2.5`, `1.0`, `SRC_OVER`, `precision`.
- Mapping table test iterates all 11 `StudioTool` values against the expected byte:
  - `pen → 1`, `highlighter → 2`, `eraser → 3`
  - `line, rect, circle, triangle, arrow, cartesianGraph, numberLine → 4`, `image → 4`
- Graph builder tests assert key sets: Cartesian ⇒ `origin, x_range, y_range, grid_step, show_labels`; NumberLine ⇒ `range, step, show_labels`.
- Graph builder tests also assert value fidelity: `origin` stays `[250.0, 450.0]`, `grid_step` stays `25.0` (no int truncation), `show_labels` stays `true`.
- Widget test: toggle collapses/expands the panel without touching any socket or `sendRpc`.
- Widget test: selecting the highlighter tool sets `config.value.blendMode == 'MULTIPLY'`; switching back to pen restores `'SRC_OVER'`.
- **§10.7 per-tool store:** switching tools REPLACES `config.value` with a different instance (host observers see a reference change; a pen edit survives switching away and back); panel edits land on both the live value and the store; round-5 ctor params (`pickImage`, `planWorldRect`, `snapEnabled`) still construct and behave.
- **§10.7 gestures:** a tap on a rail button selects without opening the panel; a press held 2000 ms (fake async clock) selects the tool AND opens its property overlay; releasing before 2000 ms or dragging > 18 dp cancels the hold — the overlay never opens (Flutter's built-in ~500 ms `onLongPress` is not the mechanism); tap-outside closes the overlay.
- **§10.7 Clear:** pressing `clear-canvas` shows the confirmation dialog; `clear-cancel` fires nothing; `clear-confirm` calls `onClearRequested` exactly once; with `onClearRequested == null` the dialog still works and simply no-ops (PRE-SEEDED nullable contract).
- Acceptance: grep of `tool_palette_dock.dart` shows **no** import of `web_socket_channel` / `vector_sync_client.dart` (pure UI guarantee).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2 merged wave, Subagent 6 per `overview.md` §6; template matrix row 24 → 2.A). Depends only on Wave 1.A artifacts (Doc 05 constants/theme) and Doc 21 signatures — both frozen.
- Zero overlap with the other 7 Wave 2.A docs: Creates paths are exclusive to Doc 24 (Docs 08/13/14/15/16/17 are `pc_agent/**`; Doc 26 owns `features/home` + `core/storage`; Doc 27 owns `features/export`).
- **Never touches:** `pc_agent/**`, `shared_specs/**`, `mobile_app/lib/network/**` (Doc 25), `mobile_app/lib/features/home/**`, `mobile_app/lib/core/storage/**` (Doc 26), `mobile_app/lib/features/export/**` (Doc 27), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/core/models/**` (Doc 05). Network wiring happens in Wave 3.A, never here.

---

## 8. Round-8 Amendment — Hold-to-Configure, Brush Eraser, Selector (NORMATIVE)

### 8.1 The expandable column and its toggle are REMOVED

`dock-toggle` and the `dock-panel` scroll column no longer exist. A tool's configuration is reached
by pressing and holding that rail button for **2000 ms** (unchanged from Doc 02 §10.7; the custom
`Timer`, not Flutter's ~500 ms `onLongPress`). The panel is an `OverlayEntry` keyed
`property-overlay-panel`, anchored to the right of the rail and clamped on screen.

* Tapping a tool selects it instantly; releasing before 2000 ms is a tap.
* While a panel is open, tapping a DIFFERENT tool **re-targets** the panel to that tool (it stays
  open). This supersedes the round-6 "switch closes the panel" rule; the sync invariant it protected
  — never showing one tool's rows against another tool's config — still holds because re-targeting
  replaces `config.value` with the new tool's stored `ToolConfig`.
* The panel closes on any tap outside it, and before the Cartesian/Number-Line builder dialogs open
  (the overlay sits above the Navigator, so a dialog would otherwise be unreachable).

### 8.2 `StudioTool.select` is the FIRST tool and the new default surface for edits

Added as ordinal 0; it streams `ToolId.shapePreview` (0x04) and has no live ink. Selection semantics:

| gesture | result |
|---|---|
| tap an object | selects it (topmost by layer) |
| drag on empty space | marquee — selects every intersecting node, the only way to select free strokes |
| drag inside the selection | moves every selected node |
| drag a corner/edge handle | resizes — only when `canScaleSelection` holds |

**Free-hand strokes are move/delete only.** `kScalableKinds` excludes `STROKE`/`HIGHLIGHT`, so the
handle set is suppressed as soon as the selection contains one. The `delete-selection` FAB appears
whenever something is selected and deletes the whole selection (strokes included).

Transforms reuse the frozen action set — no schema change: each replaced node emits
`DELETE_NODE(node_id)` then its own add action (`ADD_STROKE`/`ADD_SHAPE`/`ADD_GRAPH`/`ADD_IMAGE`)
carrying the new geometry, so the PC mirrors a move/resize exactly like a fresh commit.

### 8.3 Eraser: `brush` is the DEFAULT mode

`EraserMode { brush, element }` replaces `{ precision, stroke }`.
`ToolConfig.eraserMode` now defaults to `brush`.

* **brush** — a real eraser. `canvas_engine/stroke_eraser.dart::splitPolyline` drops every vertex
  inside a swept disc and cuts the polyline into the surviving contiguous runs; each run becomes its
  own node (original `DELETE_NODE` + one `ADD_STROKE` per fragment). Bbox-based kinds
  (SHAPE/IMAGE/GRAPH_AXES) have no polyline to split, so a disc clears them only when it lands on
  them. A fragment shorter than 2 points is discarded.
* **element** — the previous behaviour: the whole hit node is deleted, one `DELETE_NODE` per node per
  drag (`_erasedInDrag` dedupe).
* BOTH modes now follow the drag (the old `precision` mode only fired on pointer-down).
* Radius writes `ToolConfig.width` and the panel labels it "Eraser radius".

### 8.4 IMAGE nodes paint their bitmap

`_drawNode` previously drew `canvas.drawRect(bbox)` for `kind == 'IMAGE'`, so a picked photo never
appeared. `canvas_engine/asset_image_cache.dart` now holds encoded→decoded `ui.Image` per
`geometry.asset_ref`; `TiledCanvasEngine.assets` is populated by the canvas page on pick
(`resolve`) and on open (`_primeArchivedAssets` reads `<base>/assets/<canvasId>/`), the bake calls
`ensureDecoded`, and `onReady` invalidates the tiles holding that node. An undecoded asset paints
nothing rather than a misleading block.

### 8.5 Acceptance
* `mobile_app/test/stroke_eraser_test.dart` — split geometry, the move-only rule, both eraser modes.
* `mobile_app/test/tool_palette_dock_test.dart` / `tool_panels_*.dart` — hold-to-open, re-targeting,
  the absence of `dock-toggle`, the `brush`/`element` segmented control.
* `mobile_app/test/engine_add_node_test.dart` — an unresolvable IMAGE paints no ink; decoded bytes
  paint inside the bbox.
---

## 9. Round-9 Amendment — Undo/Redo, Fill, Lock/Rotate, Tables (NORMATIVE)

### 9.1 `StudioTool` grows to 14 values

`StudioTool` is now:

```
enum StudioTool {
  select, pen, highlighter, eraser, fill, line, rect, circle, triangle, arrow,
  cartesianGraph, numberLine, table, image,
}
```

`fill` (issue 04) sits after `eraser` — a paint bucket belongs with the paint tools. `table` (issue 06)
sits after `numberLine` — the grid/governed-geometry family. Both stream `ToolId.shapePreview` (0x04):
`fill` sends no drag previews at all, and a `table` drag previews its rectangle exactly like a shape.

The rail is 14 × 36 dp + divider + the clear button, wrapped in a `SingleChildScrollView` so a 600 dp
viewport can never overflow it.

### 9.2 Undo / redo (issue 03)

Top-bar `studio-undo` / `studio-redo` drive `CanvasHistoryController`
(`features/canvas/canvas_history_controller.dart`) over `EditHistory`
(`canvas_engine/edit_history.dart`).

**Snapshots, not a command log.** Several gestures emit more than one RPC: a transform is
`DELETE_NODE` + `ADD_*`, and a brush erase is `DELETE_NODE` + N × `ADD_STROKE`. Each mutation helper
brackets itself with `_beginEdit()` / `_endEdit()`, and `EditHistory.commit` drops a gesture whose
before/after snapshots are equal — so a stray tap never adds an invisible step. The stack is bounded
(60 states) because undo is a convenience, not an audit log. Undo/redo reindex the engine through
`setDocument` and rebuild `doc.groups`.

### 9.3 Fill tool (issue 04)

The user's rule is exact: *"the object needs to be closed"*. There is **no raster flood fill** — it
leaks through antialiased gaps and cannot distinguish "this shape's interior" from "the gap between
two shapes". Instead `canvas_engine/region_fill.dart` resolves the tap against NODES:

* `closedPolygonFor(node)` returns the closed loop a node encloses: RECT/TRIANGLE/PATH from `pts`,
  CIRCLE from its bbox ellipse, a free-hand STROKE only when `polylineCloses` says its own first and
  last samples meet (tolerance = the larger of 6 world units and 12 % of the path diagonal).
  ARROW / LINE / IMAGE / GRAPH_AXES never enclose a region.
* `findFillTarget` picks the SMALLEST-area polygon containing the tap, so a small shape nested inside
  a big one wins.
* The fill is a **style change**, not new geometry: `NodeStyleModel.fill` (`#RRGGBB`, omitted when
  unset). Tapping a filled shape clears it.

`style.fill` is an OPTIONAL addition to the frozen Doc 03 `NodeStyle`; every earlier document
round-trips byte-identically because the key is omitted rather than nulled. The legacy spelling
`stroke_width == 0` ⇒ solid in `color` still holds (PC `shape_fill.shape_is_filled`), and the two
routes are honoured identically by the mobile painter, the GL viewport and all three exporters.

The mirror receives the change as `DELETE_NODE` + `ADD_*` — the same pair the selector's transform
uses, because the schema has no `UPDATE_NODE`.

### 9.4 Lock groups and rotation (issue 05)

`NodeStyle` is frozen, so a per-node `locked` flag is impossible. A group is document-level anyway (a
node belongs to at most one group), so `CanvasDocumentModel.groups` (`group_id → [node_id, ...]`,
OPTIONAL and omitted when empty) carries it. `canvas_engine/selection_groups.dart` is the whole
policy:

* `expandSelection` — selecting ANY member selects the entire locked group, which is what makes the
  group "act as a single object".
* `lockSelection` / `unlockGroup` — one group per node is an invariant: re-locking a node detaches it
  from its previous group (and drops that group when it empties).
* `forgetNode` — every delete path drops the id from its group, so a later selection can never expand
  to a node that no longer exists.

Chrome is anchored to the OBJECT, as the user asked: `SelectionActionBar` floats just above the
selection box (lock / unlock · rotate · fill · delete) and `LockBadge` marks a locked group.

Rotation is **shapes only** — never a free-hand stroke (that would shear the ink, exactly like scaling
it would), and never graph axes or images, whose meaning is bound to their config/pixels. A rotated
RECT/CIRCLE/TRIANGLE cannot stay that type (`bbox` is axis-aligned by contract), so it is re-emitted as
`shape_type: "PATH"` with its four rotated corners. `PATH` is simply "a closed polygon".

### 9.5 Table tool (issue 06)

A table is ONE `SHAPE` node with `shape_type: "TABLE"` and its grid in `graph_config`
(`rows`, `cols`, `header_row`, `header_col`) — the same "config object on a shape" shape the graph
tools already use, so no new node kind and every renderer gains tables by reading one more
`shape_type`. `rows`/`cols` are TOTAL cell counts (header band included) and are clamped
(1..200 × 1..40) so a corrupt document cannot emit a million gridlines.

The config popup (`features/canvas/table_config_popup.dart`) opens WITH the tool, so rows/columns and
the header flags are chosen before anything is drawn. After placement, `TableGrowHandles` shows the
add-row handle BELOW the table's bottom edge and the add-column handle to its RIGHT, exactly as the
user specified; growing one cell also grows the bbox along that axis so the cells do not silently get
thinner.

### 9.6 Acceptance

* `mobile_app/test/round9_tools_test.dart` — closure tolerance, point-in-polygon (concave),
  nested-shape precedence, rotation, group invariants, table grid, bounded undo stack.
* `mobile_app/test/round9_studio_test.dart` — undo/redo enable/disable and rewind, the fill tap
  producing `DELETE_NODE` + `ADD_SHAPE` with `style.fill`, the action bar appearing on selection, and
  the table popup + `TABLE` commit.
* `pc_agent/tests/test_vector_geometry.py` — ear-clipping area equality (a fan OVER-counts on a
  concave loop), closure, table clamps.
* `pc_agent/tests/test_round9_rendering.py` — fill vs outline colours, PATH polygon, TABLE grid and
  filled header bands, cairo `apply_fill`/`trace_shape`.
* `pc_agent/tests/test_document_store.py` — `fill`/`groups` are optional, survive a round trip, and a
  malformed value drops rather than failing the load.

## 10. Round-10 Amendment - Sealed Loops, Fill Persistence, Lock Enforcement (NORMATIVE)

### 10.1 Fill: "no leak" includes ink-sealed and self-crossing loops

Round 9 (�9.2) required the object to be *closed*. That was implemented as
"the polyline's last sample is within tolerance of its first", which rejects the
two ways people actually close a loop:

* **Under-shoot** - the gesture stops one stroke-width short. The ink is
  `strokeWidth` wide, so the two ends are already sealed by the stroke itself.
  `polylineCloses(pts, strokeWidth:)` therefore folds `strokeWidth` into the
  closure tolerance (`closureLimit`).
* **Over-shoot** - the tail crosses the head (the natural way to close a
  circle). The endpoints are far apart but the crossing point is a real seal.
  `polylineSelfIntersects(pts)` accepts the loop when the path crosses itself.

A genuinely open arc (a half circle) satisfies neither and stays unfillable.
`closedPolygonFor` passes the node's `style.strokeWidth` through, so the rule is
per-node. No new wire field: the fill is still `style.fill`.

### 10.2 A fill survives every transform

`NodeStyleModel` is rebuilt field-by-field in the transform/erase paths, so a
fill was silently dropped by the first move, resize or eraser bite. Every
rebuild MUST carry `node.style.fill`. The sites are `_applyTransform`,
`_replaceWithFragments`, `_rotateSelection`, `_growTable` and `_setNodeFill`.

### 10.3 A locked group refuses every tool

Round 9 (�9.4) only made a group *select as one object*; nothing consulted the
group before mutating. `canvas_engine/lock_guard.dart` is now the single rule:

| Helper | Use |
| --- | --- |
| `anyLocked(doc, ids)` | all-or-nothing gesture gate |
| `unlockedIds(doc, ids)` | the safe subset a gesture may mutate |
| `unlockedNodes(doc, nodes)` | eraser candidate filter |
| `gestureRefusal(...)` | hint text for full or partial blocks |

Enforcement points, all of which MUST use the guard: transform start (no
handles, no drag), `_applyTransform`, `_deleteSelection`, `_rotateSelection`,
`_fillSelection`, `_fillAt`, `_eraseAt`, `_growTable`. The selector withdraws
`showHandles` and disables the delete/rotate/fill controls for a locked
selection; only `selection-unlock` stays live, because unlocking is the sole way
out of a lock.

An honest "unlock then delete" still works: `_deleteSelection` filters through
`unlockedIds`, so after the group is removed the members are deletable.