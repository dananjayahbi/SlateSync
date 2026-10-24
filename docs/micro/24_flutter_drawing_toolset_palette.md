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
