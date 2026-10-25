# Round 12 — Implementation Plan

Ten reported tasks (02–11). Each entry records the **confirmed root cause or
design decision**, the **files owned**, and the **acceptance criteria** so
nothing is lost mid-implementation.

Guiding constraints carried over from every previous round:

* the wire schema is **frozen by intent** — an RPC/action may only be added with
  lockstep updates in `shared_specs/ws_rpc_schema.json`,
  `shared_specs/validate_specs.py`, `pc_agent/core/protocol.py` and the four
  contract tests (`test_protocol.py`, `test_contract_cross_specs.py`);
* mutations that cannot be expressed with an existing action reuse
  `DELETE_NODE` + per-kind `ADD_*` (no `UPDATE_NODE` exists);
* new behaviour lives in its own module, not appended to a monolith;
* the lock guard (`mobile_app/lib/canvas_engine/lock_guard.dart`) and the
  frozen `StudioTool` contract must keep working;
* both distributables are rebuilt at the end.

---

## 02 — Tool config panel: 2 s hold → 0.5 s

**Status:** implemented.

**Root cause:** a constant, not a bug. `_ToolDockState._holdDuration` was
`Duration(milliseconds: 2000)`.

**Change:** `mobile_app/lib/features/tools/tool_palette_dock.dart` —
`_holdDuration = Duration(milliseconds: 500)`.

**Why keep the custom `Timer` and not `onLongPress`:** the timer is cancelled on
pointer-up, on drag-slop and on any other pointer-down inside the rail. That is
what preserves "a quick tap still selects the tool"; Flutter's own long-press
recogniser claims the gesture arena and sacrifices the tap.

**Acceptance:** a 500 ms hold opens the property panel; a release before 500 ms
selects the tool and opens nothing; a >slop drag cancels the pending hold.

---

## 03 — Focus mode

**Design:** a boolean in the studio header. While active, every chrome element
(tool rail, header buttons, zoom cluster, selection overlays, property panels)
is hidden and only the focus toggle remains; toggling back restores them.

**Approach:** introduce a small `FocusModeController` (`ValueNotifier<bool>`)
rather than threading a bool through every widget. Widgets that must vanish read
it and return `SizedBox.shrink()`. State is **not** persisted — leaving a canvas
must never strand the user in a chrome-less screen.

**Files:**
* new `mobile_app/lib/features/canvas/focus_mode_controller.dart`
* new `mobile_app/lib/features/canvas/focus_toggle_button.dart`
* `canvas_studio_page.dart` — own the controller, gate the chrome.

**Acceptance:** toggling hides/restores all chrome; the toggle itself is always
reachable; canvas pan/zoom/draw still works while focused; leaving the page
resets to unfocused; the toggle has an accessible label and tooltip.

---

## 04 — Number Line / Cartesian Graph tools "not working"

**Root cause (confirmed by subagent trace + verified locally):** the commit path
is **not** broken. `_onGraphCommitted` builds a valid `GRAPH_AXES` node,
`_commitElement` emits `ADD_GRAPH`, the tablet painter has a `GRAPH_AXES` branch
and the PC has `_draw_graphs`. The defect is **reachability**:

* `IconButton.onPressed` only calls `_selectTool`, which flips `StudioTool`;
* the canvas dispatch deliberately ignores a drag for these tools
  (`shapeTypeForTool` returns `null` for both), so tap-then-drag does nothing;
* `_onToolStateChanged` auto-opens a popup for `table` **only**;
* the builder was reachable only via press-and-hold → property panel →
  "Open Graph Builder…". A normal tap therefore looked like a dead button.

**Fix:** `_ToolDockState._openBuilderFor` opens the builder dialog directly when
a graph tool is selected, mirroring how the table already behaves. Guarded by
`_builderOpenFor` because one tap reaches `_selectTool` twice (pointer-up hold
cancel + `onPressed`), which otherwise stacked two identical dialogs. Added the
missing `graph-cancel` key so the dialog is dismissible in tests/UI.

**Files:** `mobile_app/lib/features/tools/tool_palette_dock.dart`.

**Acceptance:** tapping Number Line or Cartesian Graph opens the builder;
confirming commits exactly one `GRAPH_AXES`; cancelling commits nothing; a
non-graph tool pops no dialog. **Verified** by
`mobile_app/test/round12_graph_tools_test.dart` (5 tests).

---

## 05 — Polygon tool and text box tool

**Polygon:** a vertex-by-vertex polygon. N taps place vertices; closing the loop
(or confirming) commits. Stored as `SHAPE` with `shape_type: "PATH"` and the
vertex list in `geometry.pts` — the frozen enum already has `PATH`, and both
painters already render a `PATH` polygon, so **no schema change**.

**Text box:** a rect plus editable text. This genuinely needs a new field, so:
* `NodeStyle` cannot grow (frozen), and `geometry.pts` is numeric — so the text
  travels in **`graph_config`**, which is already a free-form object on a shape
  (`{"text": ..., "font_size": ...}`), exactly how `TABLE` stores its grid.
* `shape_type: "TEXT"` must be added to the enum **in lockstep** across the
  JSON schema, `validate_specs.py`, the PC tabelle and the mobile constant.
* Editing uses Flutter's real text input so the phone keyboard appears.

**Files:** new `polygon_tool.dart` / `text_box_tool.dart` / `text_node_render.dart`
under `mobile_app/lib/canvas_engine/`; PC `primitive_renderer` text pass; cairo
exporter text pass; enum updates.

**Acceptance:** a polygon closes and paints identically on both sides; a text box
opens the keyboard, commits text, renders on the PC, survives save/reload, and is
re-editable via the selector.

---

## 06 — Animated loading placeholder for images

**Root cause:** the painter draws nothing for an `IMAGE` node whose bytes are not
decoded yet, so the canvas shows a hole until decode completes.

**Fix:** while a decode is in flight, paint a placeholder (tinted rounded rect +
animated shimmer/pulse) driven by an `AnimationController` owned by the painter
host, and repaint when decode finishes. The PC already has a placeholder texture
(`_placeholder`); this brings the tablet to parity.

**Files:** `mobile_app/lib/canvas_engine/tiled_canvas_painter.dart` +
a new `image_placeholder.dart`; the decode registry gains a "pending" query.

**Acceptance:** opening a canvas with images shows an animated placeholder
immediately, replaced by the real bitmap on decode; no placeholder remains for a
failed decode (show an error glyph instead).

---

## 07 — PC agent crashes on a background-style canvas switch (MAIN ISSUE)

**Root cause chain (confirmed):** a *switch* goes through
`canvas_sync.open_payload` → `DOCUMENT_LOADED` → `GLCanvasHost.set_document`,
which calls `fit_viewport()` and installs a **new** artboard/camera. Unlike an
in-place artboard edit (`ARTBOARD_CHANGED`), the switch changes the artboard's
width/height/`background_spacing` while the viewport still holds GL state for the
previous artboard.

The render path is `try/except`-guarded twice (`_tick`, `_render`), so a Python
exception cannot kill the process — which means the reported "closes" is a
**native GL fault / hard exit**, not a Python traceback. The unguarded steps
are the `scissor` mutations:

* `_render` does `self._ctx.scissor = None` **before** its `try` block;
* `_draw_background` assigns `self._ctx.scissor = box` from a box computed
  against the new artboard, and moderngl raises/driver-faults on an
  out-of-range or zero-area rect.

**Fix (defensive, no behaviour change for the good path):**
1. never hand moderngl an empty/out-of-range box — clamp and skip instead;
2. move *all* scissor mutation inside the guarded region, and reset scissor to
   a known-good full-viewport box (not `None`) on a document switch;
3. on `set_document`, reset renderer scissor/stream state **before** the first
   frame of the new artboard;
4. add a process-level `sys.excepthook` + `report_callback_exception` so any
   unexpected native-adjacent failure is logged to the app data dir instead of
   vanishing, which is what makes this class of bug undiagnosable.

**Files:** `pc_agent/viewport/primitive_renderer.py`,
`pc_agent/viewport/gl_canvas_host.py`, `pc_agent/main.py`, new
`pc_agent/core/crash_log.py`.

**Acceptance:** switching between BLANK / RULED / SQUARE_GRID canvases, with
different spacings and different presets, never terminates the process; a
regression test drives the switch and asserts a clean render.

---

## 08 — Thumbnails not updating (both apps)

**Root cause:** thumbnails are written on first save and then treated as
immutable; the galleries load them by a stable path, so a rewritten file with the
same name never invalidates any cache.

**Fix:** regenerate the thumbnail on every save that changes the document, and
make the gallery cache key include the file's modification stamp (or bump a
revision counter) so the widget reloads. Apply on both sides: PC
`thumbnail_renderer` call site + gallery loader; mobile thumbnail writer +
home gallery loader.

**Acceptance:** editing a canvas and returning to the gallery shows the new
thumbnail on both the tablet and the PC without restarting.

---

## 09 — OCR (main new feature)

**Architecture:** the PC is the compute host. Mirrors the proven
`ExportCoordinator` job shape (submit → progress → result), because that already
handles threading, cancellation, throttled progress and chunked transfer.

**Transport (needs a frozen-contract change, done in lockstep):** add a new RPC
type `OCR_JOB` with actions `START_OCR`, `OCR_PROGRESS`, `OCR_RESULT`,
`OCR_ERROR`. Touching five places together: `ws_rpc_schema.json`,
`validate_specs.py`, `protocol.py`, `test_protocol.py`,
`test_contract_cross_specs.py`.

**PC engine — measured, not assumed.** Tesseract was the first candidate and was
**rejected on evidence**: this is a *handwriting* app, and Tesseract's LSTM models
are tuned for print. The engine chosen is **RapidOCR (PaddleOCR PP-OCRv6,
`model_type=small`, `lang=en`) on ONNX Runtime**, so no CUDA/cuDNN install is
needed on the user's machine.

Why ONNX Runtime **DirectML** and not CUDA:

* `onnxruntime-gpu` 1.31 loads but its CUDA provider **refuses to initialise**
  here — it demands `cuDNN 9.*` **and `CUDA 13.*`**, and the box has CUDA 12.4
  with no cuDNN (`cublasLt64_13.dll` missing). ORT then **silently falls back to
  CPU**, which is the worst outcome: it looks like it works and is just slow.
* `onnxruntime-directml` 1.24.4 (the only line with a cp314 wheel) exposes
  `DmlExecutionProvider`, which **binds to the GTX 1660 Ti successfully** —
  verified with a synthetic ONNX graph reporting
  `['DmlExecutionProvider', 'CPUExecutionProvider']` as the *active* providers.
  DirectML also ships the GPU backend itself (via the OS), so there is nothing
  for the user to install and nothing large to bundle.

Measured on a realistic hand-print sample (uppercase + mixed case + digits,
light Gaussian blur to mimic stylus ink bleed):

| candidate | accuracy on hand-print | first run | peak VRAM |
|---|---|---|---|
| PP-OCRv6 `medium` | **worse** (0.64–0.79 confidence) | 60.9 s | 2.5 GB |
| PP-OCRv5 `mobile` `ch` | unusable (splits lines, drops words) | 30.5 s | — |
| **PP-OCRv6 `small` `en`** | **3/3 lines exact, 0.994–0.998** | **2.06 s** | **~1.9 GB** |

`medium` being *worse* than `small` is not a fluke — the larger recogniser is
tuned for dense CJK print and over-fits, while the `en` route uses the Latin
alphabet head. So **small/en is both the most accurate and the fastest** here.

VRAM budget: baseline desktop usage on this machine is ~942 MiB, and the engine
added **~900 MiB** for a peak of ~1.9 GB — comfortably inside 6 GB, leaving room
for the OpenGL mirror. The session is still **lazy-loaded and released** after
an idle period so a 6 GB card is never permanently occupied.

RapidOCR exposes DirectML directly, so no custom provider plumbing is needed:
`RapidOCR(params={"EngineConfig.onnxruntime.use_dml": True,
"Det.model_type": ModelType.SMALL, "Rec.model_type": ModelType.SMALL,
"Det.ocr_version": OCRVersion.PPOCRV6, "Rec.ocr_version": OCRVersion.PPOCRV6,
"Det.lang_type": LangDet.EN, "Rec.lang_type": LangRec.EN})`.

Packaging caveat that must be handled: `onnxruntime-directml` + `rapidocr` +
the PP-OCRv6 ONNX weights need to be declared in the PyInstaller spec
(`hiddenimports` for `rapidocr.*` and its yaml config/`default_models.yaml` as
`datas`), and the weights must live under the app-data dir rather than inside
the bundle so first-run download failure produces a clear error instead of a
silent hang. `numpy`/`PIL` are already present.

**Rasterise the region:** the tiled exporter already loops strips for any
origin/size, so add an optional `extent=` override to `export()` (one code path,
no duplicate renderer). A polygon request rasterises its **bounding box** and
passes the polygon as a mask so only the enclosed ink is recognised.

**Two requests:**
* **region** — a free-drawn polygon (not a rectangle) from the mobile OCR tool;
* **whole canvas** — the full artboard. Rejected for `is_infinite` canvases
  (no bounded area to scan), which the tablet must also refuse up front.

**Result:** recognised text returns to the tablet and is inserted as an editable
**text box** node (the issue-05 tool), so the user can correct it.

**Files:** new `pc_agent/ocr/` package (`ocr_coordinator.py`, `ocr_engine.py`,
`region_mask.py`), `pc_agent/export/tiled_raster_exporter.py` extent override,
mobile `features/ocr/` (tool, selection painter, request client, result
applier), studio wiring, contract/spec updates, docs.

**Acceptance:** a free-drawn region and a whole-canvas scan both return text
from a canvas with known writing; infinite canvases reject the whole-canvas
scan; a missing engine surfaces a real error, never a silent hang; the returned
text lands in an editable box; progress is reported and can be cancelled.

---

## 10 — PC popups appear behind the main window

**Root cause:** dialogs are created without a parent/`topmost` relationship, so
the OS may place them under the main window.

**Fix:** pass `parent=` to every `Toplevel`/message box, call `transient()` +
`lift()` + `focus_force()`, and `grab_set()` for modal ones. Centralise this in
one helper so a new popup cannot reintroduce the bug.

**Files:** `pc_agent/gui/` — new `dialog_utils.py`, plus every popup call site.

**Acceptance:** every popup in the agent opens above the main window and is
modal where it should be.

---

## 11 — Clear canvas does not clear the PC mirror

**Root cause (confirmed, and *not* a transport problem):**
`SceneGraph.apply_rpc` handles `CLEAR_CANVAS` correctly and emits
`CANVAS_CLEARED`; `GLCanvasHost._on_canvas_cleared` cleared `self._scene`. But
`_draw` then did:

```
nodes = self._scene.nodes()
if not nodes:
    nodes = list(getattr(self._doc, "elements", None) or [])
```

An empty scene is indistinguishable from "the scene has not been synced yet",
so the stale `_doc.elements` snapshot was drawn straight back over the clear.
The mirror therefore never visibly emptied.

**Fix:** the fallback moved into `GLCanvasHost._nodes_to_render()` and keys off
a flag, not emptiness. `_scene_authoritative` turns on when a document syncs the
scene and when a clear arrives; from then on the scene alone decides what
paints. `_on_canvas_cleared` also empties the document snapshot as defence in
depth.

**Files:** `pc_agent/viewport/gl_canvas_host.py`.

**Acceptance:** clear empties the mirror immediately and it stays empty across
repaints. **Verified** by `pc_agent/tests/test_round12_clear_canvas.py`
(10 tests). The key test keeps `doc.elements` POPULATED and clears only the
scene, so it fails if the code regresses to the emptiness check — confirmed by
temporarily reverting the fix.

---

## Verification & release

1. `pytest pc_agent` + `ruff check pc_agent shared_specs` + `validate_specs.py`;
2. `flutter analyze` + `flutter test` (restore
   `mobile_app/test/.home_card_badges_tmp` afterwards);
3. round-12 regression tests per item;
4. docs: normative sections in Docs 02 (OCR actions, TEXT shape), 03 (enum),
   08/13/14 (text + placeholder), 24 (focus mode, polygon, text, OCR tool), 16
   (dialogs);
5. version bump in all three sites → `1.0.6` / `1.0.6+7`;
6. rebuild `SlateSync_Setup.exe` (verify `--smoke` + FileVersion) and the APK
   (verify versionName/versionCode + unchanged signing cert), copy to `dist/`,
   delete the previous APK;
7. commit.
