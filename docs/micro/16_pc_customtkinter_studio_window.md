# Doc 16: CustomTkinter Studio Window

## 1. Objective & Scope
Builds the dark-mode `CustomTkinter` desktop shell of the PC agent: TOP HUD (connection badge, zoom/artboard labels, QR pairing button — the Pair/QR button is **hidden while a device is paired**), LEFT gallery strip (Doc 02 §10.6 thumbnail cards, shown only while paired with a non-empty canvas list), CENTER OpenGL viewport via Doc 06 `GLCanvasHost.mount`, BOTTOM export bar (format/DPI/target/Start/progress/Open-in-Explorer) and the File/View/Help menu. All export execution goes through the **injected** `export_submit: Callable[[dict], str]` (wired by `main.py` to Doc 15 `ExportCoordinator.submit`); this doc **never imports Doc 15**. `EventBus.emit` runs synchronously on the caller's thread (WS/worker threads), so every widget mutation is marshalled with `self.after(0, …)`.

**Frozen behavior summary:** badge `CONNECTED` (green) / `WAITING` (grey) / `ERROR` (red) fed by `CONNECTION_STATE`; zoom `%` label + artboard preset label refreshed by `update_hud` on `ARTBOARD_CHANGED` / `DOCUMENT_LOADED`; on every `DOCUMENT_LOADED`, `main.py` first calls `gl_host.fit_viewport()` (Doc 02 §10.5 fit-on-open, 48-unit padding) and then refreshes `window.update_hud(scale=gl_host.camera_scale, preset=…)`; the gallery strip renders the hub's `CANVAS_LIST_UPDATED` rows as a two-column **thumbnail-card grid** with preset badge chips overlaid (A5/A4/LETTER/INFINITE — UI overlays, never baked into the image, Doc 02 §10.6); QR pairing dialog renders `PAIRING_INFO.qr_png_path` via `CTkImage` plus ipv4/token text; the export bar drives a `EXPORT_JOB`/`START_EXPORT` envelope through `export_submit` while a `CTkProgressBar` tracks `EXPORT_PROGRESS` and Open-in-Explorer reveals `EXPORT_FINISHED.path` via `os.startfile`.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `pc_agent/gui/__init__.py`
- `pc_agent/gui/studio_window.py`
- `pc_agent/gui/canvas_gallery_panel.py` (gallery strip — Doc 02 §9.5/§10.8 `pc_agent/gui/**`)
- `pc_agent/tests/test_studio_window.py`
- `pc_agent/tests/test_canvas_gallery_panel.py`

### Read-only dependencies (imports, each cited as "Doc NN")
- `pc_agent/core/config_manager.py` — `AppConfig` (Doc 04)
- `pc_agent/core/events.py` — `EventBus` + event-name constants incl. `CANVAS_LIST_UPDATED` (Doc 04)
- `pc_agent/viewport/gl_canvas_host.py` — `GLCanvasHost`, `ProgramRegistry` (Doc 06)
- `pc_agent/export/thumbnail_renderer.py` — `render_thumbnail(doc, out_path, size=192)` reached only through the gallery's **lazy in-function import** (Doc 02 §10.6; never imported at module top, so the strip works before the renderer lands)
- Doc 15 `ExportCoordinator.submit(job) -> job_id` — reached **only** via the injected `export_submit` callable (signature cited, never imported)
- Doc 10/09 payload shapes arriving via `DOCUMENT_LOADED(doc)` / `ARTBOARD_CHANGED(artboard, content_bounds)`
- `customtkinter`, `Pillow` (`Image`, `CTkImage`) from requirements (Doc 04)

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `pc_agent/gui/tray_daemon.py`, `pc_agent/tests/test_tray_daemon.py` (Doc 17)
- `pc_agent/main.py` (Doc 04 bootstrap; finalized in Wave 3.A)
- `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*` (Docs 06–08), `pc_agent/engine/*` (Docs 09/10), `pc_agent/network/*` (Docs 11/12), `pc_agent/export/*` (Docs 13–15), `pc_agent/installer/*` (Docs 18/19)
- Other docs' test files, `mobile_app/**`, `qa/**`, `docs/overview.md`, `docs/_micro_doc_template.md`

## 3. Contract References
- overview §4.2 RPC envelope (`id, type, action, canvas_id, payload, timestamp`); types `EXPORT_JOB`, `CANVAS_LIFECYCLE`; actions `START_EXPORT`, `OPEN_CANVAS`
- template §3 constants: DPI `300, 600, 1200` (PDF is vector → DPI not applicable); zoom range `0.05× … 20.0×`; presets `A5|A4|LETTER|INFINITE`; port `50606`; export strips `2048×2048` (coordinator-internal, never shown in GUI)
- template §4 freezes consumed here: `EventBus`, event-name constants, `GLCanvasHost`/`ProgramRegistry`, Doc 16 event-matrix rows, threading rule (`after(0, …)` for all Tk mutations)
- Doc 12 emits `PAIRING_INFO(ipv4, port, token, qr_png_path)`; Doc 15 emits `EXPORT_STARTED` / `EXPORT_PROGRESS` (≤10 Hz + per strip) / `EXPORT_FINISHED(job_id, percent, path, ok)`
- Doc 02 §9 hub sync (`network/canvas_sync.py`) emits `CANVAS_LIST_UPDATED(canvases, devices)` — merged rows + live device count driving the gallery strip and the Pair/QR visibility
- Doc 02 §10.5 fit-on-open: `main.py`'s `DOCUMENT_LOADED` subscriber calls `gl_host.fit_viewport()` **then** `window.update_hud(scale=gl_host.camera_scale, preset=…)`; Doc 02 §10.6 thumbnail contract (192² source, preset badges as UI overlays, thumbs cached under `%APPDATA%/SlateSync/thumbs/`)
- Doc 01 test layout: `pc_agent/tests/test_<module>.py` (pytest)

## 4. Interface Freeze
**Exported — template §4 signature, plus the additive round-4/6 ctor params (Doc 02 §8, §10.6):**
```python
class StudioWindow:                                     # Doc 16
    def __init__(self, config: AppConfig, bus: EventBus, gl_host: GLCanvasHost,
                 export_submit: Callable[[dict], str],
                 open_request: Callable[[str], None] | None = None,   # round-4 additive
                 *, thumbnail_fn: Callable[[dict, Path, int], object] | None = None,
                 thumbs_dir: str | Path | None = None,               # round-6 additive (Doc 02 §10.6)
                 canvases_dir: str | Path | None = None) -> None: ...
    def build(self, parent: tk.Misc) -> None: ...
    def show(self) -> None: ...
    def hide(self) -> None: ...
    def set_connection_state(self, connected: bool, peer: str | None) -> None: ...
    def open_qr_dialog(self) -> None: ...
    def update_hud(self, scale: float, preset: str) -> None: ...
    def on_live_activity(self) -> None: ...              # tray auto-foreground, throttled ≥1 s
# round-6 additive ctor params are keyword-only and default to None:
#   thumbnail_fn/thumbs_dir/canvases_dir forward to the gallery's §10.6
#   pipeline (tests inject a fake renderer; main.py leaves them None ⇒
#   lazy render_thumbnail import, %APPDATA%/SlateSync/thumbs|canvases).
```
**Consumed (template §4 — never redefined):**
```python
class EventBus:                      # synchronous emit on the CALLER'S thread
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
# Event name constants (same module) used here:
# "CONNECTION_STATE" "DOCUMENT_LOADED" "ARTBOARD_CHANGED"
# "EXPORT_STARTED" "EXPORT_PROGRESS" "EXPORT_FINISHED" "PAIRING_INFO"
# "CANVAS_LIST_UPDATED"                    # Doc 02 §9 — {canvases, devices}
def mount(self, parent_widget: tk.Misc) -> None: ...    # GLCanvasHost (Doc 06) — CENTER viewport
def get(self, stem: str) -> "moderngl.Program": ...     # ProgramRegistry (Doc 06) — context only; Doc 16 loads no GL
export_submit: Callable[[dict], str]                    # Doc 15 submit — injected, never imported
```
**Subscriptions — template §4 event matrix rows (verbatim):**
| Event | Emitted by | Subscribed by |
|---|---|---|
| `CONNECTION_STATE(connected, peer)` | Doc 11 | Doc 16 |
| `DOCUMENT_LOADED(doc)` | Doc 10 | Docs 06, 16 |
| `ARTBOARD_CHANGED(artboard, content_bounds)` | Doc 09 | Docs 06, 08, 16 |
| `EXPORT_STARTED / EXPORT_PROGRESS / EXPORT_FINISHED` | Doc 15 | Doc 16 (GUI); tablet receives via `broadcast_json` envelope |
| `PAIRING_INFO(ipv4, port, token, qr_png_path)` | Doc 12 | Doc 16 |
| `CANVAS_LIST_UPDATED(canvases, devices)` | Doc 02 §9 hub sync (`network/canvas_sync.py`) | Doc 16 |

**Doc-specific API (added by Doc 16; wired by `main.py` in Wave 3.A):**
```python
def bind_actions(self, *, rpc: Callable[[dict], None], save: Callable[[], None],
                 zoom_to_fit: Callable[[], None]) -> None: ...
# Badge states: CONNECTED #2ECC71 (green) | WAITING #9E9E9E (grey) | ERROR #E74C3C (red)
# Start-button envelope (overview §4.2) handed to export_submit:
# {"id": uuid4, "type": "EXPORT_JOB", "action": "START_EXPORT", "canvas_id": <loaded doc>,
#  "payload": {"format": "PNG|JPG|PDF", "dpi": 300|600|1200|None,   # None for PDF (vector)
#              "target": "PC|TABLET|BOTH"}, "timestamp": <unix int>}
```
**Event → handler routing (every handler body marshals with `after(0, …)`):**
| Bus event | Handler | Effect on the Tk thread |
|---|---|---|
| `CONNECTION_STATE(connected, peer)` | `_on_connection_state` | `set_connection_state(connected, peer)` — badge text+colour |
| `PAIRING_INFO(ipv4, port, token, qr_png_path)` | `_on_pairing_info` | cache `_pairing`; refresh dialog if open |
| `DOCUMENT_LOADED(doc)` | `_on_document_loaded` | store `canvas_id`, `update_hud`, enable Start, highlight gallery card; then `main.py`'s §10.5 subscriber runs `gl_host.fit_viewport()` + refreshes `update_hud(camera_scale, preset)` |
| `ARTBOARD_CHANGED(artboard, content_bounds)` | `_on_artboard_changed` | `update_hud(self._last_scale, artboard["preset"])` |
| `CANVAS_LIST_UPDATED(canvases, devices)` | `_on_canvas_list_updated` | cache hub rows + device count, `gallery.set_rows(...)`, re-evaluate Pair/QR visibility + gallery strip visibility |
| `EXPORT_STARTED(…)` | `_on_export_started` | progress → 0.0, Start disabled |
| `EXPORT_PROGRESS(…, percent)` | `_on_export_progress` | `self._progress.set(percent / 100)` |
| `EXPORT_FINISHED(job_id, percent, path, ok)` | `_on_export_finished` | re-enable Start, keep `path`, enable Open iff `ok and path` |

**Gallery strip freeze (Doc 02 §10.6 / §10.8 — `pc_agent/gui/canvas_gallery_panel.py`):**
```python
class CanvasGalleryPanel:                               # Doc 16 (gallery)
    def __init__(self, parent, *, open_request=None, thumbnail_fn=None,
                 thumbs_dir=None, canvases_dir=None) -> None: ...
    def mount(self, **grid_kwargs) -> None: ...         # docked col 0, hidden until paired
    def set_visible(self, visible: bool) -> None: ...   # StudioWindow decides (paired AND non-empty)
    def set_rows(self, canvases: list[dict]) -> None: ...   # frozen CANVAS_LIST_UPDATED rows
    def set_current(self, canvas_id) -> None: ...       # accent-highlight the open canvas card
    def activate(self, canvas_id: str) -> None: ...     # forwards to open_request (Doc 02 §8.3 flow 3)
# cards = 2-column grid of thumbnail boxes (192² source, 80 px display) with the
# preset badge chip (A5/A4/LETTER/INFINITE) OVERLAID as a widget — never baked
# into the image; missing/stale PNGs (<thumbs>/<id>.png, mtime < updated_at) are
# regenerated on a shared ThreadPoolExecutor(2) via LAZY render_thumbnail import,
# marshalled back with after(0); decoded images live in a 64-entry LRU keyed
# (canvas_id, updated_at); neutral placeholder box until the PNG lands.
```

## 5. Implementation Plan
1. **Scaffold & state.** `studio_window.py` imports `customtkinter as ctk`, `tkinter as tk`, `os`, `time`, `uuid`; store `_config/_bus/_gl_host/_export_submit`; widget refs (`_badge, _zoom_label, _preset_label, _dpi_combo, _progress, _start_btn, _open_btn`); data (`_pairing: dict | None`, `_canvas_id`, `_last_scale = 1.0`, `_last_raise = 0.0`, `_job_id`, `_last_path`); callbacks `_rpc/_save/_zoom_to_fit = None`.
2. **`build(parent)` grid.** 3 rows × 2 columns (col 0 fixed = gallery strip, col 1 `weight=1` = viewport; HUD and export bar span both columns), window title "SlateSync Studio"; each region is a separate small builder component:

| Grid cell | Builder | Contents | row weight |
|---|---|---|---|
| `(0,0..1)` | `_build_hud()` | badge, zoom `%` label, preset label, QR button (hidden while paired) | 0 |
| `(1,0)` | gallery strip (Doc 02 §10.6) | `CanvasGalleryPanel` thumbnail-card grid — visible only while paired **and** list non-empty | — (fixed col) |
| `(1,1)` | `_build_center()` | `CTkFrame` handed to `gl_host.mount(frame)` | 1 |
| `(2,0..1)` | `_build_export_bar()` | format/DPI/target combos, Start, progress, Open | 0 |
3. **`_build_hud()`.** `CTkFrame` row 0 (columnspan 2): badge label (default `WAITING`, grey), zoom label (`100%`), preset label (`A4`), QR pairing button (`command=self.open_qr_dialog`); badge colour/text applied only inside `set_connection_state`. **Pair/QR visibility (round-6):** `_refresh_pairing_affordance()` — paired = `devices >= 1` (`CANVAS_LIST_UPDATED`) **OR** badge `CONNECTED` ⇒ `btn.pack_forget()`; unpaired ⇒ re-pack. Same helper sets `gallery.set_visible(paired and rows)`.
4. **`_build_center()`.** Empty `CTkFrame` row 1 → `self._gl_host.mount(self._viewport)`; Doc 06 owns the `after(16, …)` pyglet pump — Doc 16 only supplies the parent widget.
5. **`_build_export_bar()`.** format combo `["PNG","JPG","PDF"]`; `_on_format_change`: PDF → `self._dpi_combo.configure(state="disabled")` (vector), otherwise `["300","600","1200"]` enabled; target combo `["PC","Tablet","Both"]`; `CTkProgressBar(min=0, max=1)`; Start and Open buttons start `state="disabled"`.
6. **Start → `export_submit`.** `_on_start()` maps labels→payload (`"Both"→"BOTH"`, PDF→`dpi=None`), builds the §4 envelope above, `self._job_id = self._export_submit(env)`, disables Start, resets progress; no other Doc 15 contact.
7. **`_build_qr_dialog()` / `open_qr_dialog()`.** `CTkToplevel` (~260×340): if `self._pairing`, `CTkImage(pil_image=Image.open(qr_png_path), size=(220, 220))` plus labels `f"{ipv4}:{port}"` and the token; else "Waiting for pairing info…"; re-renders when `PAIRING_INFO` arrives while open.
8. **`_subscribe()` + marshalling pattern.** `bus.on` for the eight matrix events (the template seven + round-4/5 `CANVAS_LIST_UPDATED`); each handler body is a single forward — no widget mutation ever runs on the WS/worker thread:
```python
def _on_connection_state(self, connected: bool, peer: str | None) -> None:
    self.after(0, self.set_connection_state, connected, peer)   # WS thread → Tk thread
```
   the remaining seven handlers follow the identical `self.after(0, self._apply_*, …)` shape.
9. **HUD handlers.** `CONNECTION_STATE` → `set_connection_state(connected, peer)` (which also re-evaluates Pair/QR + gallery visibility); `ARTBOARD_CHANGED` → `update_hud(self._last_scale, artboard["preset"])`; `DOCUMENT_LOADED` → store `canvas_id`, `update_hud(1.0, doc["artboard"]["preset"])`, enable Start, `gallery.set_current(canvas_id)` — **fit-on-open happens in `main.py`, not here**: its own `DOCUMENT_LOADED` subscriber calls `gl_host.fit_viewport()` (§10.5, 48-unit padding over `(0,0,w,h)` / `content_bounds`) and then `update_hud(gl_host.camera_scale, preset)` so the label shows the fitted zoom. `CANVAS_LIST_UPDATED` → cache rows + `devices`, `gallery.set_rows`, `_refresh_pairing_affordance()`.
10. **Export handlers.** `EXPORT_STARTED` → progress 0, Start disabled; `EXPORT_PROGRESS` → `self._progress.set(percent / 100)` (percent 0–100 from bus); `EXPORT_FINISHED(job_id, percent, path, ok)` → re-enable Start, store `path`, enable Open iff `ok and path`.
11. **Open-in-Explorer.** `_on_open_explorer()` → `os.startfile(self._last_path)` (Windows Explorer); guarded no-op when no path.
12. **Menu (`_build_menu`, `tk.Menu` on the CTk root).**
```text
File → New…        CANVAS_LIFECYCLE/OPEN_CANVAS envelope {preset, title} → self._rpc
     → Open…       askopenfilename("*.slatesync") → OPEN_CANVAS envelope  → self._rpc
     → Save        self._save        (§4.2 defines no SAVE action ⇒ injected Doc 10 path)
View → Zoom to Fit self._zoom_to_fit (injected callback; Doc 16 computes nothing itself)
Help → About       messagebox.showinfo("SlateSync", "PC Studio · WS port 50606")
```
    unbound callbacks are no-ops, so tests construct the window without `main.py`.
13. **Frozen methods.** `show`/`hide` (deiconify+lift / withdraw, self-marshalled); `set_connection_state` (CONNECTED when `connected`, ERROR when dropped `peer` present, else WAITING); `update_hud` (`f"{scale*100:.0f}%"`, scale clamped to 0.05–20.0, preset text); `on_live_activity` (≥1 s `time.monotonic` throttle then raise — tray wiring target); `bind_actions`.
14. **Tests.** Owned file per §6.

## 6. Testing & Acceptance Criteria
Owned file: `pc_agent/tests/test_studio_window.py` (pytest, Doc 01 layout).
1. **Smoke construct** — withdrawn `CTk()` root, stub `GLCanvasHost`, spy `export_submit`; `build(root)` yields badge/combos/progress/buttons; destroy root.
2. **Bus-spy subscriptions** — recording `EventBus` asserts `on()` registered exactly: CONNECTION_STATE, DOCUMENT_LOADED, ARTBOARD_CHANGED, EXPORT_STARTED, EXPORT_PROGRESS, EXPORT_FINISHED, PAIRING_INFO, CANVAS_LIST_UPDATED.
3. **Start button → envelope** — `_start_btn.invoke()` calls injected `export_submit` once; arg keys `id/type/action/canvas_id/payload/timestamp`, `type=="EXPORT_JOB"`, `action=="START_EXPORT"`, payload keys `format/dpi/target`.
4. **Badge flips** — `set_connection_state(True, None)` → "CONNECTED"; `(False, None)` → "WAITING"; `(False, "192.168.1.9")` → "ERROR" (colour changes green/grey/red).
5. **Bar rules** — PDF disables DPI combo and yields `dpi is None`; `EXPORT_PROGRESS(percent=42)` sets ≈0.42; `EXPORT_FINISHED(path=…, ok=True)` enables Open (`os.startfile` monkeypatched).
6. **Marshalling** — invoking any bus handler from a foreign thread schedules work through the root's `after(0, …)` (spy on `after`) and never writes a widget directly; `on_live_activity` fires at most once per second (two rapid calls → one raise).
7. **Pair/QR hidden while paired** — unpaired ⇒ `Pair / QR` packed; `CANVAS_LIST_UPDATED(devices=1)` or `set_connection_state(True, …)` ⇒ button hidden (`winfo_manager()` empty); dropping back to `devices=0` + disconnected ⇒ shown again.
8. **Gallery strip (§10.6)** — owned file `pc_agent/tests/test_canvas_gallery_panel.py`: two-column thumbnail-card grid (not text rows), preset badge chip overlaid as a widget and never present in the PNG bytes, missing/stale `<thumbs>/<id>.png` queued through the lazy `render_thumbnail` import and swapped in via `after(0)`, current-card accent highlight, `set_visible` gating (paired ∧ non-empty), `activate` → `open_request(canvas_id)`.
9. **Fit-on-open hand-off (§10.5)** — `DOCUMENT_LOADED` shows `update_hud(1.0, …)` from the window handler, then `main.py`'s fit subscriber (unit-tested in `test_main_view_fit.py` / `test_fit_viewport.py`) calls `gl_host.fit_viewport()` and refreshes `update_hud(camera_scale, preset)` — the zoom label ends at the fitted scale, not `100%`.
Command: `pytest pc_agent/tests/test_studio_window.py pc_agent/tests/test_canvas_gallery_panel.py -q` (Windows Tk main loop available).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2 merged wave, Subagent 4 of 8). Zero overlap: Doc 16 exclusively creates `pc_agent/gui/__init__.py`, `pc_agent/gui/studio_window.py`, `pc_agent/gui/canvas_gallery_panel.py`, `pc_agent/tests/test_studio_window.py`, `pc_agent/tests/test_canvas_gallery_panel.py`; Doc 17 (same wave) creates only `tray_daemon.py` + its test and treats `gui/__init__.py` as read-only. Peers Docs 08/13/14/15/24/26/27 share no paths; all contact points (`GLCanvasHost.mount`, `export_submit`, event matrix) are frozen in §4 — no intra-wave ordering constraint.
- **Never touches:** `pc_agent/gui/tray_daemon.py` + its test (Doc 17), `pc_agent/main.py` (Doc 04 / Wave 3.A), `pc_agent/installer/*` (Docs 18/19), `pc_agent/{core,viewport,engine,network,export}/*` (Docs 04–15), other docs' tests, `mobile_app/**`, `qa/**`, `docs/overview.md`, `docs/_micro_doc_template.md`.

## 8. Round-7 Amendment — Settings Panel, Device Roster, Empty State (NORMATIVE)

### 8.1 Empty viewport (issue 02)
A freshly launched agent has no document, so `GLCanvasHost._background_color()` now
returns `EMPTY_STATE_BG` (`#3A3D42`) instead of white, and `mount()` builds the frame
and blit label with the same colour. `viewport/empty_state_overlay.py::EmptyStateOverlay`
adds a centred "No canvas open — pair a device or press Ctrl+N" hint that is hidden the
moment a document loads (`set_document` → `_update_empty_state`). The white page only
appears once a real artboard exists.

### 8.2 Mirror registry (issue 06)
`viewport/mirror_scene.py::MirrorScene` holds the elements the mirror paints. It is
seeded on `DOCUMENT_LOADED`, updated on every `COMMITTED_NODE` (upsert / delete),
cleared on `CANVAS_CLEARED`, and re-derives `content_bounds`. `_render` therefore feeds
`PrimitiveRenderer` current nodes — SHAPE / GRAPH_AXES / IMAGE commits from a tablet
paint immediately. `MirrorArtboard` (infinite, white) is substituted when elements
exist with no document/artboard, so primitives are never silently skipped.
`GLCanvasHost` now subscribes six events (the five frozen rows + `CANVAS_CLEARED`).

### 8.3 Settings panel (issues 03/04/05/07)
`gui/settings_panel.py::SettingsPanel(root, *, set_export_dir, select_mirror,
rotate_pairing, export_dir, on_close)`:
* **Connected devices** — one row per `DEVICES_UPDATED` entry showing name, peer and
  the canvas it has open, plus a *Mirror* / *Mirroring* button selecting which canvas
  the PC shows. Empty state: "No devices connected yet - scan the pairing QR…".
* **Export folder** — shows `config.export_dir`, *Change…* opens
  `filedialog.askdirectory` and persists through `set_export_dir`.
* **Reset pairing** — calls `rotate_pairing` (Doc 12 §8.3).
Public API: `window`, `device_rows`, `mirrored_selection`, `exists()`,
`refresh_devices(rows, mirrored_canvas_id)`, `select_mirror(canvas_id)`,
`choose_export_dir()`, `set_export_dir(path)`, `reset_pairing()`, `close()`.

`StudioWindow` gains `open_settings()` (HUD **Settings** button + Tools → Settings…),
`_on_devices_updated` / `_on_mirror_changed` (two new subscriptions, matrix now ten
rows) and three optional injected callbacks (`select_mirror`, `set_export_dir`,
`rotate_pairing`) wired by `main.py` to `CanvasSyncManager.select_mirror`,
`ConfigManager.set_export_dir` and `DiscoveryPairing.rotate_token`.

### 8.4 Tests
`tests/test_settings_panel.py` (rows, empty hint, mirror callback, folder picker,
rotation, close), `tests/test_mirror_scene.py`, `tests/test_studio_window.py`
(+6 round-7 cases) and `tests/test_gl_canvas_host.py` (six subscriptions, empty-state
clear colour).
