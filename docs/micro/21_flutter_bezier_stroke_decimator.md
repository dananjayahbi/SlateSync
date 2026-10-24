# Doc 21: Bézier Stroke Decimator + Palm Guard

## 1. Objective & Scope
Turn raw tablet pointer input into clean, wire-ready vector strokes: `PalmGuard` (contact-size and
two-pointer palm/glove rejection), pseudo-pressure from velocity (SM-T580 capacitive stylus has no
real pressure), $2.0\text{ dp}$ distance decimation + jitter EMA, and a Catmull-Rom → cubic Bézier
fit in world coordinates with `toRpcPayload()` emitting the overview §4.3 element JSON. Lives in
`mobile_app/lib/canvas_engine/stroke_processor.dart`. Documentation only.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/canvas_engine/stroke_processor.dart`
- `mobile_app/test/stroke_processor_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- `mobile_app/lib/core/models/canvas_models.dart` — `NodeStyleModel`, kind/blend constants (Doc 05)
- `docs/_micro_doc_template.md` §5 `PalmGuard`/`StrokeProcessor`/`ProcessedStroke` freeze + §3 constants
  (decimation `2.0 dp`, blend modes `SRC_OVER|MULTIPLY`, background/style keys)
- `docs/overview.md` §4.3 element JSON (payload shape), §6 Wave 1.B subagent 4

### Never touches (paths owned by concurrent docs — write-conflict guard)
- Doc 05 files (`pubspec.yaml`, `lib/main.dart`, `lib/core/**`, Doc 05 tests), Doc 20
  `camera_controller.dart` (+ its test) — Doc 21 **injects** the camera conversion instead of importing it,
  Doc 22 `tiled_canvas_painter.dart` (+ test), Doc 23 `artboard_manager.dart` (+ test),
  Docs 24–27 paths, `lib/network/**` (Doc 25), `pc_agent/**`

## 3. Contract References
- Template §3 Master Constants: stroke decimation `2.0 dp` min distance + jitter low-pass; blend
  modes `SRC_OVER` (pen) / `MULTIPLY` (highlighter); live frame `f3 = width_pressure_factor` (overview §4.1)
- `overview.md` §4.3 element JSON (kind `STROKE | HIGHLIGHT`, style, geometry.pts), §6 Wave 1.B (subagent 4 owns Docs 20+21)

## 4. Interface Freeze
Verbatim from template §5 (consumers: Docs 22, 24, 25 — reproduce exactly):

```dart
class ProcessedStroke {                                          // Doc 21
  final String nodeId; final String kind;                         // "STROKE" | "HIGHLIGHT"
  final List<List<double>> pts;                                   // world-space Bézier controls
  final List<double> bbox;                                        // [minX,minY,maxX,maxY]
  final String color; final double strokeWidth; final double opacity;
  Map<String, dynamic> toRpcPayload();                            // matches §4.3 element JSON
}
class PalmGuard {                                                 // Doc 21
  bool shouldReject(PointerEvent e, {double minorAxisDp = 18.0});
}
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

**Doc-specific API (on top of the freeze):**

* **Conversion boundary:** `toWorld` is injected (bound to the Doc 20 camera **at stroke start** by
  the caller — Doc 24/22 wire it); this module never imports Doc 20 and stays dependency-free.
* **Palm rules:** contact minor axis `min(e.size.width, e.size.height) >= 18 dp` ⇒ reject
  (width rule); two-active-pointer rule — when a second pointer appears with **larger contact area**,
  the larger pointer is flagged palm/glove and the first (stylus) pointer continues; flagged pointers
  emit no points. `PalmGuard` tracks `pointer → area` maps: `void noteDown(PointerEvent e)`,
  `void noteUp(int pointer)`, `int? get flaggedPointer`.
* **Pseudo-pressure** (the `pressure` argument is always `null` on SM-T580 — velocity fallback):
  `v` = dp/s since last accepted point, `p = clamp(1 − v/1200, 0.25, 1.0)` ⇒ half-width factor,
  smoothed EMA `α = 0.25`: `pS = 0.75·pPrev + 0.25·p`. `pS` feeds the live half-width and Doc 25's
  `f3` (`width_pressure_factor`); the committed payload keeps `style.stroke_width` as base width.
* **Decimation:** accept a point only if its screen distance to the last accepted point is
  `>= 2.0 dp`; accepted positions pass a jitter low-pass EMA `α = 0.35`
  (`q = 0.65·qPrev + 0.35·raw`, first point accepted raw); smoothed points are mapped through
  `toWorld` into `livePoints` (world coords — Doc 22's foreground painter applies the camera transform).
* **`finish()`:** force-accept the final raw position first (endpoints preserved exactly); if fewer
  than 2 accepted points ⇒ `null`. Catmull-Rom (tension `τ = 0.5`) → cubic Bézier in **world** coords:
  for control pair on segment `Pi→Pi+1`: `c1 = Pi + (τ/3)(Pi+1 − Pi−1)`,
  `c2 = Pi+1 − (τ/3)(Pi+2 − Pi)` (endpoints clamped by duplicating the terminal point); control
  density ≤ 1 control per ~8 px of polyline arc length (merge points closer than 8 px first);
  `bbox` = axis-aligned union of all control + endpoint coordinates.
* **`toRpcPayload()` exact example** (pen, `kind "STROKE"`; highlighter ⇒ `kind "HIGHLIGHT"` and
  `blend_mode "MULTIPLY"`, else `SRC_OVER`; `layer: 0`, `opacity: 1.0`):

```json
{
  "node_id": "3f9c2a7e-5d14-4b8a-9c21-0e7a6d2b41f0",
  "kind": "STROKE",
  "layer": 0,
  "bbox": [120.0, 300.0, 450.0, 620.0],
  "style": { "color": "#1E1E1E", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER" },
  "geometry": {
    "pts": [[120.0, 300.0], [186.4, 402.7], [255.1, 511.9], [330.0, 566.2], [450.0, 620.0]],
    "shape_type": null, "graph_config": null, "asset_ref": null
  }
}
```

## 5. Implementation Plan
1. **`PalmGuard`:** `shouldReject` = width rule (§4) OR `e.pointer == flaggedPointer`;
   `noteDown/noteUp` maintain the active-pointer area map and flag the largest of ≥2 simultaneous
   pointers (ties keep the first).
2. **`StrokeProcessor` state:** accepted screen points, last-accepted point, last timestamp,
   EMA carriers (`pS`, `q`), active `Set<int>` pointers, `_rejecting` flag, injected `toWorld`,
   `color/width/highlighter`, generated `nodeId` (uuid v4 via `Random.secure()`, Doc 25-style helper
   kept private to this file).
3. **`addPoint` gate order:** if `pointer` is palm-flagged ⇒ drop silently (no points emitted);
   compute `v = ΔscreenDist/Δt·1000` (dp/s, first point `v = 0`).
4. **Pseudo-pressure:** compute `p` per §4, EMA-update `pS`; keep `liveWidth = width * pS` exposed
   as `@visibleForTesting double get liveHalfWidthFactor`.
5. **Decimate + smooth:** skip if `< 2.0 dp` from last accepted; else EMA `α = 0.35` position,
   push through `toWorld`, append to `livePoints`.
6. **`rejecting` getter:** `PalmGuard` currently rejecting any active pointer.
7. **`finish()`:** force-append final raw point (bypassing distance gate, still smoothed), `< 2`
   points ⇒ `null` (after reset); subsample to ≤ 1 control / ~8 px; Catmull-Rom → cubic controls
   per §4 in world coords; compute `bbox` union; reset processor to idle; return `ProcessedStroke`
   with `kind = highlighter ? "HIGHLIGHT" : "STROKE"`.
8. **`toRpcPayload()`:** assemble exactly the §4 JSON keys (snake_case — Doc 05 models already own
   naming); `shape_type`/`graph_config`/`asset_ref` explicitly `null`.
9. **Tests** (`test/stroke_processor_test.dart`) — see §6; `toWorld = identity` for pure-math cases.

## 6. Testing & Acceptance Criteria
- **Palm-reject matrix:** contact minor axis `24×8 dp` ⇒ rejected; `10×6 dp` ⇒ accepted;
  second pointer with larger area while stylus active ⇒ larger flagged, stylus points still emit,
  flagged pointer emits none; after lift, unflagged pointer accepted.
- **Decimation density:** dense wiggly input (200 points, 0.4 dp steps) ⇒ `livePoints` count drops
  (≤ 40% of input) while first/last points are preserved exactly.
- **Velocity→width monotonicity:** feed points at rising dp/s ⇒ `liveHalfWidthFactor` non-increasing
  (and within `[0.25, 1.0]`); slow stroke ⇒ factor near `1.0`, fast ⇒ near `0.25`; EMA smoothing never
  exceeds bounds.
- **Payload key assertions:** `toRpcPayload()` contains exactly `node_id, kind, layer, bbox, style,
  geometry` with `style` keys `color, stroke_width, opacity, blend_mode` and `geometry` keys
  `pts, shape_type, graph_config, asset_ref`; `pts` is `[[x,y]…]` world coords; highlighter ⇒
  `kind == "HIGHLIGHT"`, `blend_mode == "MULTIPLY"`; `finish()` on 1 point ⇒ `null`.
- **Acceptance:** `flutter test` green; `flutter analyze` clean; no import of Doc 20 module (grep gate).

## 7. Parallel Execution Notes
**Wave 1.B — Subagent 4 (Flutter Camera & Stroke Math)**: Doc 21 executes alongside Doc 20 in the
same subagent but owns disjoint files (Docs 20+21 pair per overview §6); parallel with Docs 09/10/11/12/
22/23/25 — zero shared Creates paths. Blocked by the Wave 1.A barrier (needs Doc 05 models). Consumed
read-only by Doc 22 (`addCommitted(ProcessedStroke)`), Doc 24 (tool dock drives `addPoint/finish`),
Doc 25 (live width factor → `f3`). **Never touches:** only its two Creates files are written; Doc 20,
Doc 05, Doc 22, Doc 23 and all `pc_agent/**` paths stay untouched.
