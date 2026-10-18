# Doc 06: Embedded OpenGL Viewport

## 1. Objective & Scope
* Hosts a hardware-accelerated OpenGL 3.3 core surface **inside** the `CustomTkinter` shell.
* **PRIMARY embedding:** pyglet `Window(visible=False)` reparented into a Tk frame on Windows via
  ctypes `user32.SetParent(hwnd_pyglet, hwnd_tk)` with `WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN`.
* Context config: `pyglet.gl.Config(sample_buffers=1, sample=4, major_version=3, minor_version=3)`
  — MSAA 4×, GL 3.3 core.
* Pumped **manually** from Tk `after(16, tick)` (`switch_to`/`dispatch_events`/`render`/`flip`) —
  **never** `pyglet.app.run()`.
* **FALLBACK (documented escape hatch):** standalone `moderngl` context + FBO → PIL `ImageTk` blit,
  ROI ≤ 1280×720 — used only if `SetParent` fails or no display is available.
* Owns frame ingestion: the WS thread (Doc 11) calls only thread-safe `submit_live_frame` /
  `request_redraw`; a **lock-free latest-frame slot** + `after(0, …)` marshal; seq stale-drop runs
  inside `submit`/drain; **all GL calls execute on the Tk main thread**; redraws are dirty-flag coalesced.
* Exports `ProgramRegistry` — generic `<stem>.vert` + `<stem>.frag` loader from `config.shader_dir`
  (stems: `stroke` (Doc 07), `primitive`, `grid`, `texture` (Doc 08)).
* Applies the template §3 camera transform for world↔screen mapping and renders LASER `0x04` as a
  crosshair via the `stroke` program. Subscribes per the template §4 event matrix: `LIVE_FRAME`,
  `CAMERA_DELTA`, `DOCUMENT_LOADED`, `COMMITTED_NODE`, `ARTBOARD_CHANGED`.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/viewport/__init__.py`
* `pc_agent/viewport/gl_canvas_host.py`
* `pc_agent/tests/test_gl_canvas_host.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/config_manager.py` (`AppConfig`, incl. `shader_dir`) — Doc 04
* `pc_agent/core/events.py` (`EventBus`, event-name constants) — Doc 04
* `pc_agent/core/protocol.py` (`LiveFrame`, `FRAME_*`, `is_newer_seq`) — Doc 04 (mirrors Doc 02)
* `pc_agent/engine/document_store.py` (`CanvasDocument`, `Artboard`) — Doc 10
* `CanvasNode` model — Doc 09 (read-only; `COMMITTED_NODE` payload)
* `StrokeTessellator`/`TessellatedMesh` — Doc 07 (same Wave 1.B subagent)
* `PrimitiveRenderer` — Doc 08 (later wave; contract-frozen in template §4)
* Packages: `pyglet`, `moderngl`, `customtkinter`, `Pillow` (requirements, Doc 04);
  stdlib `ctypes`, `threading`, `dataclasses`

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/viewport/stroke_tessellator.py`, `pc_agent/viewport/shaders/**`,
  `tests/test_stroke_tessellator.py` (Doc 07)
* `pc_agent/viewport/primitive_renderer.py`, `tests/test_primitive_renderer.py` (Doc 08)
* `pc_agent/core/*`, `pc_agent/main.py` (Doc 04 — Wave 3.A finalizes `main.py`)
* `pc_agent/engine/*` (Docs 09/10); `pc_agent/network/*` (Docs 11/12)
* `pc_agent/export/*` (Docs 13–15); `pc_agent/gui/*` (Docs 16/17); `pc_agent/installer/*` (Docs 18/19)
* `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27); `qa/*` (Doc 28); `docs/**` (read-only)

## 3. Contract References
* `_micro_doc_template.md` §3 — camera transform `screen = (world − camera_center) * scale + viewport/2`
  (tx,ty = world coord at viewport center); live camera frame f1=scale, f2=tx, f3=ty;
  FrameType `0x01/0x02/0x03/0x04` (LASER = `0x04`); zoom range `0.05× … 20.0×`.
* `_micro_doc_template.md` §4 — `GLCanvasHost` + `ProgramRegistry` (verbatim below); event matrix:
  `LIVE_FRAME`/`CAMERA_DELTA` (Doc 11 → Doc 06), `DOCUMENT_LOADED` (Doc 10 → Docs 06/16),
  `COMMITTED_NODE` (Doc 09 → Doc 06), `ARTBOARD_CHANGED` (Doc 09 → Docs 06/08/16).
* `_micro_doc_template.md` §4 threading model — Tk main thread owns GUI + all GL + pyglet pump;
  seq stale-drop lives in **both** Doc 11 (server receive) and Doc 06 (`submit_live_frame` slot);
  Tk/widget mutations inside handlers marshalled with `after(0, …)`.
* `overview.md` §3 tree (`viewport/gl_canvas_host.py`), §5 Doc 06 entry,
  §6 Wave 1.B subagent 1 (runs Docs 06 + 07 together).

## 4. Interface Freeze
**Verbatim from template §4 — do not modify:**

```python
class GLCanvasHost:                                     # Doc 06
    def __init__(self, tk_parent: tk.Misc, config: AppConfig, bus: EventBus) -> None: ...
    def mount(self, parent_widget: tk.Misc) -> None: ... # embeds GL surface in frame
    def submit_live_frame(self, frame: LiveFrame) -> None: ...  # THREAD-SAFE: slot + after()
    def set_document(self, doc: CanvasDocument) -> None: ...
    def set_camera(self, scale: float, tx: float, ty: float) -> None: ...
    def request_redraw(self) -> None: ...                # thread-safe, coalesced
    def resize(self, w: int, h: int) -> None: ...
    def shutdown(self) -> None: ...
class ProgramRegistry:                                  # Doc 06 (generic stem loader)
    def get(self, stem: str) -> "moderngl.Program": ...  # pairs <stem>.vert + <stem>.frag in config.shader_dir
    # stems: "stroke" (Doc 07), "primitive", "grid", "texture" (Doc 08)
```

**Doc-specific API & architecture decisions (frozen):**

```python
def _tick(self) -> None: ...        # Tk after(16): drain slot → dispatch_events → render → flip
def _drain(self) -> None: ...       # main thread: pop slot; drop unless is_newer_seq(seq, last_seq)
def set_camera_live(self, f1: float, f2: float, f3: float) -> None: ...  # 0x03 → clamp 0.05..20.0
def _embed_pyglet(self) -> bool: ...  # SetParent reparent; False ⇒ FALLBACK path
```

* **PRIMARY embedding:** create the pyglet window off-screen, then reparent:
  `ctypes.windll.user32.SetParent(hwnd_pyglet, hwnd_tk)` after merging
  `WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN` via `GetWindowLongW`/`SetWindowLongW`;
  keep geometry synced with `MoveWindow` on Tk `<Configure>`.
* **Pump:** `tk_parent.after(16, self._tick)` → `window.switch_to()` → `window.dispatch_events()`
  → render if dirty → `window.flip()`. Reschedule `after` first so an exception can't stop the pump.
* **FALLBACK:** `moderngl.create_standalone_context()` + RGBA FBO at ≤1280×720 ROI;
  each tick renders FBO → `PIL.Image` → `ImageTk.PhotoImage` blit on a Tk `Label`.
* **Threading:** ws thread may call only `submit_live_frame`/`request_redraw`;
  submit writes `self._slot = frame` (GIL-atomic attribute replace, lock-free) and schedules
  `after(0, drain)` if none pending; stale-drop via `is_newer_seq` on the main thread.
* **Redraw coalescing:** `request_redraw()` sets `_dirty` and ensures ≤1 scheduled callback;
  the 16 ms tick consumes the flag — N requests collapse into one redraw.
* **Event wiring (template §4 matrix):**
  `LIVE_FRAME → submit_live_frame`; `CAMERA_DELTA → set_camera_live(f1, f2, f3)`;
  `DOCUMENT_LOADED → set_document`; `COMMITTED_NODE → append immutable mesh + request_redraw`;
  `ARTBOARD_CHANGED → update artboard/content_bounds + request_redraw`.
* **Camera mapping (uniforms `u_camera=(scale, tx, ty)`, `u_viewport=(w, h)`):**
  vertex shader `screen = (world − vec2(tx, ty)) * scale + u_viewport / 2`;
  NDC `= screen / u_viewport * 2 − 1`;
  inverse for culling `world = (screen − u_viewport/2)/scale + vec2(tx, ty)`.
* **LASER `0x04`:** crosshair (two thin quads, ~12 px arms) drawn with the **`stroke`** program
  at `(f1, f2)` world position; cleared on `FRAME_LIVE_END` or a 500 ms timeout.
* **Render order per tick:** `PrimitiveRenderer.render(...)` (Doc 08: background → shadow →
  images → shapes → graphs) → committed stroke meshes → in-flight stroke → laser crosshair.
* **`ProgramRegistry.get`:** `dict` cache per stem; reads `<shader_dir>/<stem>.vert` + `.frag`;
  missing file → `FileNotFoundError` naming both paths; compile failure → `RuntimeError` with log.

## 5. Implementation Plan
1. **`viewport/__init__.py`** — re-export `GLCanvasHost`, `ProgramRegistry`; no side effects.
2. **`ProgramRegistry`** — stem→program cache, pair loader from `config.shader_dir`, error paths
   per §4; missing-file branch unit-testable with a tmp dir and no GL.
3. **`GLCanvasHost.__init__`** — store `tk_parent/config/bus`; init `_slot`, `_dirty`, `_pending`,
   `_last_seq`, camera `(1.0, tx, ty)`; subscribe the five matrix events.
4. **`mount(parent_widget)`** — build the Tk frame, `_embed_pyglet()` (SetParent + WS_CHILD styles),
   bind `<Configure>` → `resize`; fall back to the FBO/`ImageTk` path when embedding returns `False`.
5. **`_tick` pump** — reschedule `after(16, …)` first; `_drain()` the slot with stale-drop;
   `dispatch_events()`; render only when `_dirty`; `flip()`/blit.
6. **`submit_live_frame`** — thread-safe slot write + `after(0, drain)` scheduling;
   `FRAME_CAMERA` (0x03) routes to `set_camera_live` (clamp `0.05…20.0`).
7. **`set_document` / `COMMITTED_NODE` / `ARTBOARD_CHANGED`** — swap document context,
   append committed `TessellatedMesh`es, refresh artboard/bounds, `request_redraw()` each time.
8. **`resize(w, h)`** — resize FBO/blit target or the reparented window, update `u_viewport`, redraw.
9. **`shutdown`** — cancel pending `after` ids, unsubscribe bus handlers, destroy window / free GL.

## 6. Testing & Acceptance Criteria
* **Always-run (no GL):** stale-slot semantics — 100 rapid worker-thread submits ⇒ `_drain` applies
  only the newest frame; out-of-order `seq` dropped by `is_newer_seq` (wrap `65535→0` accepted);
  `request_redraw` coalescing — N calls ⇒ 1 scheduled tick; fake-bus test asserts exactly the five
  matrix subscriptions; `ProgramRegistry` missing pair raises `FileNotFoundError`; camera clamp at
  `0.05`/`20.0`; `visible_world_rect` inverse matches the §3 formula.
* **GL-context tests:** marked `@pytest.mark.skipif(not _display_available(), reason="no display/GL")`
  — mount/unmount smoke, requested MSAA config (`sample_buffers=1, sample=4`, `3.3` core),
  one rendered frame with `glGetError() == 0`, resize keeps FBO size == widget size.
* **Threading assertion:** a test wrapper records the thread id of every GL entry point; asserting
  all are the main thread even when frames are submitted from a background thread.
* Acceptance: `pytest pc_agent/tests -q` green headless (GL tests skip); on a Windows desktop a
  live stroke from Doc 11 renders within the p95 `≤ 8 ms` stylus→GL budget (Doc 28 verifies);
  no GL or Tk-widget mutation ever executes on the ws thread.

## 7. Parallel Execution Notes
* **Wave 1.B** — subagent 1 executes Doc 06 **and** Doc 07 together (one agent owns both files, so
  `GLCanvasHost` ↔ `StrokeTessellator` integration never races). Sibling subagents own Docs 09/10,
  11/12, 20–23, 25 — zero overlapping "Creates" paths (template §6 row 06).
* Contracts consumed without file waits: `AppConfig`/`EventBus`/`LiveFrame` from the Wave 1.A
  barrier; `CanvasDocument` (Doc 10) and `CanvasNode` (Doc 09) arrive in the same wave via the
  frozen template §4 interfaces.
* **Never touches:** `viewport/stroke_tessellator.py` + `viewport/shaders/*` (Doc 07);
  `viewport/primitive_renderer.py` (Doc 08); `core/*` + `main.py` (Doc 04; Wave 3.A finalizes
  `main.py`); `engine/*` (Docs 09/10); `network/*` (Docs 11/12); `gui/*` (Docs 16/17);
  `export/*`, `installer/*`, `shared_specs/*`, `mobile_app/*`, `qa/*`, `docs/**`.