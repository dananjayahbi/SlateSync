# Doc 20: World Camera Matrix

## 1. Objective & Scope
Implement the 2-D affine camera for the infinite canvas: `CameraController` in
`mobile_app/lib/canvas_engine/camera_controller.dart` — pinch-to-zoom ($0.05\times$–$20.0\times$,
focal-point anchored), two-finger pan, zoom-to-fit with 48-unit padding, world↔screen transforms, and
the `CameraSnapshot` hook that Doc 25 streams as 60 Hz binary camera frames. Documentation only —
code is written by the Wave 1.B subagent executing this doc.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/canvas_engine/camera_controller.dart`
- `mobile_app/test/camera_controller_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- `mobile_app/lib/core/models/canvas_models.dart` — `WireCodec`, `FrameType.camera` (Doc 05)
- `docs/_micro_doc_template.md` §5 `CameraSnapshot`/`CameraController` freeze + §3 transform, zoom range
- `docs/overview.md` §4.1 (camera frame mapping f1/f2/f3), §6 Wave 1.B subagent 4

### Never touches (paths owned by concurrent docs — write-conflict guard)
- Doc 05 files (`pubspec.yaml`, `lib/main.dart`, `lib/core/**`, Doc 05 tests)
- Doc 21 `stroke_processor.dart` (+ its test), Doc 22 `tiled_canvas_painter.dart` (+ its test),
  Doc 23 `artboard_manager.dart` (+ its test), Docs 24–27 paths, `lib/network/**` (Doc 25), `pc_agent/**`

## 3. Contract References
- Template §3 Master Constants: camera transform `screen = (world − camera_center) * scale + viewport/2`
  (tx,ty = world coord at viewport center); live camera frame f1=scale, f2=tx, f3=ty; zoom range `0.05× … 20.0×`
- `overview.md` §4.1 byte layout (consumed via Doc 05 `WireCodec`), §6 Wave 1.B (subagent 4 owns Docs 20+21)

## 4. Interface Freeze
Verbatim from template §5 (consumers: Docs 22, 25 — reproduce exactly):

```dart
class CameraSnapshot { final double scale, tx, ty; }            // Doc 20 → live frame f1,f2,f3
class CameraController {                                        // Doc 20
  CameraController({double initialScale = 1.0});
  double scale;                                                  // clamped 0.05..20.0
  CameraSnapshot get snapshot;
  Matrix4 get viewMatrix;
  void onScaleStart(ScaleStartDetails d);
  void onScaleUpdate(ScaleUpdateDetails d, Size viewport);
  Offset worldToScreen(Offset world, Size viewport);             // (world − c)*s + vp/2
  Offset screenToWorld(Offset screen, Size viewport);
  void zoomToFit(Rect bounds, Size viewport);                    // 48-unit padding
  void applyRemote(double scale, double tx, double ty);
  void Function(CameraSnapshot snap)? onCameraChanged;           // 60 Hz sync hook
}
```

**Doc-specific API (on top of the freeze):**

* Transform with `s = scale`, `c = (tx, ty)` — template §3 used exactly (PC mirrors it):
  `screen.x = (world.x − tx) * s + vw/2`, `screen.y = (world.y − ty) * s + vh/2`;
  inverse `world = (screen − viewport/2)/s + c`. `viewMatrix` = `T(vp/2) · S(s) · T(−c)`.
* Pinch update equations (cumulative from the `onScaleStart` baseline `s0`, `f0`, `c0`; `f` = current
  `d.focalPoint`, all in viewport-local screen coords):
  1. `s' = clamp(s0 * d.scale, 0.05, 20.0)` — `d.scale` is cumulative since gesture start
  2. `w0 = (f0 − vp/2)/s0 + c0` — world point captured under the initial focal point
  3. `c' = w0 − (f − vp/2)/s'` — so `w0` stays fixed under the current focal point
  4. commit `scale = s'`, `tx = c'.x`, `ty = c'.y`
  When the gesture is a pure two-finger pan (`d.scale ≈ 1.0` within 1e-6), step 3 reduces to
  `c' = c0 − (f − f0)/s` — translation only, same code path.
* `zoomToFit(bounds, viewport)`: `s = clamp(min(vw/(bw + 96), vh/(bh + 96)), 0.05, 20.0)`
  (48 units padding per side ⇒ +96 total per axis); `tx = bounds.center.dx`, `ty = bounds.center.dy`.
* `applyRemote(scale, tx, ty)`: clamps scale into `[0.05, 20.0]`, assigns `scale/tx/ty`, and does
  **not** fire `onCameraChanged` (remote-origin frames must not echo back; sender throttling lives in Doc 25).
* `onCameraChanged` fires once per accepted gesture frame with `snapshot`
  (`f1 = scale`, `f2 = tx`, `f3 = ty` → `FrameType.camera` frame built by Doc 05 `WireCodec`, sent by Doc 25).
* `@visibleForTesting void debugSet(double scale, double tx, double ty)` — test seeding bypassing gestures.
* Snapshot → wire mapping (template §3, frame built by Doc 25 via Doc 05 `WireCodec`):

| CameraSnapshot field | 16-byte frame slot | Semantic |
|---|---|---|
| `scale` | `f1` (bytes 4–7) | zoom factor, clamped `0.05…20.0` |
| `tx` | `f2` (bytes 8–11) | world x at viewport center |
| `ty` | `f3` (bytes 12–15) | world y at viewport center |

  Frame header: `byte0 = FrameType.camera (0x03)`, `bytes2–3 = seq` (Doc 25 owns the per-connection
  monotonic counter); `byte1 = ToolId` of the active tool (pen default).

## 5. Implementation Plan
1. **State:** private `double _scale`, `Offset _txy = Offset.zero`; gesture baseline fields
   `_s0`, `_f0`, `_c0`. Constructor clamps `initialScale` to `[0.05, 20.0]`.
2. **Accessors:** `snapshot => CameraSnapshot(_scale, _txy.dx, _txy.dy)`; `scale` getter/setter
   (setter clamps); `viewMatrix => Matrix4.identity()..translate(vw/2, vh/2)..scale(_scale)
   ..translate(-_txy.dx, -_txy.dy)` (viewport passed via cached size from last `onScaleUpdate`,
   defaults 800×600 for pure getter use in tests).
3. **Transforms:** `worldToScreen`/`screenToWorld` implementing the §4 formulas verbatim;
   both take `Size viewport` explicitly (no hidden global).
4. **Gesture start:** `onScaleStart` stores the baseline: `_s0 = _scale`, `_f0 = d.focalPoint`,
   `_c0 = _txy`.
5. **Gesture update:** run the 4-step §4 equations; then fire `onCameraChanged?.call(snapshot)`
   once per frame — no internal throttling (Doc 25's sender throttles).
6. **Gesture hygiene:** an update without a start self-heals (treats current state as baseline);
   non-finite `d.scale`/focal values are ignored; focal coords are viewport-local from the canvas
   `GestureDetector`, never global screen pixels.
7. **`zoomToFit`:** compute `s` per §4 with the +96 padding, set center to `bounds.center`,
   fire `onCameraChanged`. Doc 26/22 call it on first open of a preset rect.
8. **`applyRemote`:** clamp + assign only, silent (no callback) — distinguishes local gesture frames
   from PC/loopback-driven frames (echo protection for frames this device already sent).
9. **Tests** (`test/camera_controller_test.dart`) — see §6; pure Dart (`flutter_test`), no widgets.

## 6. Testing & Acceptance Criteria
- **Roundtrip identity:** for zoom levels `0.05, 0.5, 1.0, 8.0, 20.0` and assorted world points
  (incl. negative coords), `screenToWorld(worldToScreen(w, vp), vp) == w` within `1e-6`.
- **Clamp enforcement:** constructing/zooming at `0.001` ⇒ `0.05`; `100.0` ⇒ `20.0`; pinch
  `s0 * d.scale` beyond either end clamps; `applyRemote` clamps too.
- **zoomToFit containment:** for A5/A4/Letter rects (Doc 05 `Presets`) in a `Size(800, 600)`
  viewport, `worldToScreen` of the rect **expanded by 48 units** maps inside `0..vw` / `0..vh`
  on both axes; center maps to viewport center.
- **Focal anchor:** simulate a pinch (scale ×2, focal offset `(200, 150)`); the world point under the
  focal position before the update remains under it after within `1e-6`; pure-pan gesture preserves
  it too.
- **viewMatrix equivalence:** `MatrixUtils.transformPoint(viewMatrix, w)` equals `worldToScreen(w, vp)`
  within `1e-6` at 3 zoom levels; `snapshot` maps `f1=scale, f2=tx, f3=ty` (assert field order).
- **zoomToFit extremes:** a viewport smaller than `(96+1)` units ⇒ clamps to `0.05`; huge bounds ⇒
  never exceeds `20.0`.
- **Acceptance:** all green via `flutter test`; `flutter analyze` clean.

## 7. Parallel Execution Notes
**Wave 1.B — Subagent 4 (Flutter Camera & Stroke Math)**: Doc 20 is executed together with Doc 21;
independent files, zero overlap. Parallel with Docs 09/10/11/12/22/23/25 — none share a Creates path.
Blocked only by the Wave 1.A barrier (needs Doc 05 `canvas_models.dart`). Consumed read-only by
Doc 22 (`TiledCanvasEngine(camera:)`) and Doc 25 (snapshot → binary frame). **Never touches:**
Doc 05/21/22/23/24/25/26/27 paths — this doc writes only its two Creates files.
