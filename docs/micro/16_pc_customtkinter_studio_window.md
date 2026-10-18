# Doc 16: CustomTkinter Studio Window

## 1. Objective & Scope
Builds the dark-mode `CustomTkinter` desktop shell of the PC agent: TOP HUD (connection badge, zoom/artboard labels, QR pairing button), CENTER OpenGL viewport via Doc 06 `GLCanvasHost.mount`, BOTTOM export bar (format/DPI/target/Start/progress/Open-in-Explorer) and the File/View/Help menu. All export execution goes through the **injected** `export_submit: Callable[[dict], str]` (wired by `main.py` to Doc 15 `ExportCoordinator.submit`); this doc **never imports Doc 15**. `EventBus.emit` runs synchronously on the caller's thread (WS/worker threads), so every widget mutation is marshalled with `self.after(0, …)`.

**Frozen behavior summary:** badge `CONNECTED` (green) / `WAITING` (grey) / `ERROR` (red) fed by `CONNECTION_STATE`; zoom `%` label + artboard preset label refreshed by `update_hud` on `ARTBOARD_CHANGED` / `DOCUMENT_LOADED`; QR pairing dialog renders `PAIRING_INFO.qr_png_path` via `CTkImage` plus ipv4/token text; the export bar drives a `EXPORT_JOB`/`START_EXPORT` envelope through `export_submit` while a `CTkProgressBar` tracks `EXPORT_PROGRESS` and Open-in-Explorer reveals `EXPORT_FINISHED.path` via `os.startfile`.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `pc_agent/gui/__init__.py`
- `pc_agent/gui/studio_window.py`
- `pc_agent/tests/test_studio_window.py`

### Read-only dependencies (imports, each cited as "Doc NN")
- `pc_agent/core/config_manager.py` — `AppConfig` (Doc 04)
- `pc_agent/core/events.py` — `EventBus` + event-name constants (Doc 04)
- `pc_agent/viewport/gl_canvas_host.py` — `GLCanvasHost`, `ProgramRegistry` (Doc 06)
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
- Doc 01 test layout: `pc_agent/tests/test_<module>.py` (pytest)

## 4. Interface Freeze
**Exported — verbatim from template §4:**
```python
class StudioWindow:                                     # Doc 16
    def __init__(self, config: AppConfig, bus: EventBus, gl_host: GLCanvasHost,
                 export_submit: Callable[[dict], str]) -> None: ...
    def build(self, parent: tk.Misc) -> None: ...
    def show(self) -> None: ...
    def hide(self) -> None: ...
    def set_connection_state(self, connected: bool, peer: str | None) -> None: ...
    def open_qr_dialog(self) -> None: ...
    def update_hud(self, scale: float, preset: str) -> None: ...
    def on_live_activity(self) -> None: ...              # tray auto-foreground, throttled ≥1 s
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
| `DOCUMENT_LOADED(doc)` | `_on_document_loaded` | store `canvas_id`, `update_hud`, enable Start |
| `ARTBOARD_CHANGED(artboard, content_bounds)` | `_on_artboard_changed` | `update_hud(self._last_scale, artboard["preset"])` |
| `EXPORT_STARTED(…)` | `_on_export_started` | progress → 0.0, Start disabled |
| `EXPORT_PROGRESS(…, percent)` | `_on_export_progress` | `self._progress.set(percent / 100)` |
| `EXPORT_FINISHED(job_id, percent, path, ok)` | `_on_export_finished` | re-enable Start, keep `path`, enable Open iff `ok and path` |

## 5. Implementation Plan
1. **Scaffold & state.** `studio_window.py` imports `customtkinter as ctk`, `tkinter as tk`, `os`, `time`, `uuid`; store `_config/_bus/_gl_host/_export_submit`; widget refs (`_badge, _zoom_label, _preset_label, _dpi_combo, _progress, _start_btn, _open_btn`); data (`_pairing: dict | None`, `_canvas_id`, `_last_scale = 1.0`, `_last_raise = 0.0`, `_job_id`, `_last_path`); callbacks `_rpc/_save/_zoom_to_fit = None`.
2. **`build(parent)` grid.** 3 rows × 1 column (`weight=1`), window title "SlateSync Studio"; each region is a separate small builder component:

| Grid cell | Builder | Contents | row weight |
|---|---|---|---|
| `(0,0)` | `_build_hud()` | badge, zoom `%` label, preset label, QR button | 0 |
| `(1,0)` | `_build_center()` | `CTkFrame` handed to `gl_host.mount(frame)` | 1 |
| `(2,0)` | `_build_export_bar()` | format/DPI/target combos, Start, progress, Open | 0 |
3. **`_build_hud()`.** `CTkFrame` row 0: badge label (default `WAITING`, grey), zoom label (`100%`), preset label (`A4`), QR pairing button (`command=self.open_qr_dialog`); badge colour/text applied only inside `set_connection_state`.
4. **`_build_center()`.** Empty `CTkFrame` row 1 → `self._gl_host.mount(self._viewport)`; Doc 06 owns the `after(16, …)` pyglet pump — Doc 16 only supplies the parent widget.
5. **`_build_export_bar()`.** format combo `["PNG","JPG","PDF"]`; `_on_format_change`: PDF → `self._dpi_combo.configure(state="disabled")` (vector), otherwise `["300","600","1200"]` enabled; target combo `["PC","Tablet","Both"]`; `CTkProgressBar(min=0, max=1)`; Start and Open buttons start `state="disabled"`.
6. **Start → `export_submit`.** `_on_start()` maps labels→payload (`"Both"→"BOTH"`, PDF→`dpi=None`), builds the §4 envelope above, `self._job_id = self._export_submit(env)`, disables Start, resets progress; no other Doc 15 contact.
7. **`_build_qr_dialog()` / `open_qr_dialog()`.** `CTkToplevel` (~260×340): if `self._pairing`, `CTkImage(pil_image=Image.open(qr_png_path), size=(220, 220))` plus labels `f"{ipv4}:{port}"` and the token; else "Waiting for pairing info…"; re-renders when `PAIRING_INFO` arrives while open.
8. **`_subscribe()` + marshalling pattern.** `bus.on` for the seven matrix events; each handler body is a single forward — no widget mutation ever runs on the WS/worker thread:
```python
def _on_connection_state(self, connected: bool, peer: str | None) -> None:
    self.after(0, self.set_connection_state, connected, peer)   # WS thread → Tk thread
```
   the remaining six handlers follow the identical `self.after(0, self._apply_*, …)` shape.
9. **HUD handlers.** `CONNECTION_STATE` → `set_connection_state(connected, peer)`; `ARTBOARD_CHANGED` → `update_hud(self._last_scale, artboard["preset"])`; `DOCUMENT_LOADED` → store `canvas_id`, `update_hud(1.0, doc["artboard"]["preset"])`, enable Start.
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
2. **Bus-spy subscriptions** — recording `EventBus` asserts `on()` registered exactly: CONNECTION_STATE, DOCUMENT_LOADED, ARTBOARD_CHANGED, EXPORT_STARTED, EXPORT_PROGRESS, EXPORT_FINISHED, PAIRING_INFO.
3. **Start button → envelope** — `_start_btn.invoke()` calls injected `export_submit` once; arg keys `id/type/action/canvas_id/payload/timestamp`, `type=="EXPORT_JOB"`, `action=="START_EXPORT"`, payload keys `format/dpi/target`.
4. **Badge flips** — `set_connection_state(True, None)` → "CONNECTED"; `(False, None)` → "WAITING"; `(False, "192.168.1.9")` → "ERROR" (colour changes green/grey/red).
5. **Bar rules** — PDF disables DPI combo and yields `dpi is None`; `EXPORT_PROGRESS(percent=42)` sets ≈0.42; `EXPORT_FINISHED(path=…, ok=True)` enables Open (`os.startfile` monkeypatched).
6. **Marshalling** — invoking any bus handler from a foreign thread schedules work through the root's `after(0, …)` (spy on `after`) and never writes a widget directly; `on_live_activity` fires at most once per second (two rapid calls → one raise).
Command: `pytest pc_agent/tests/test_studio_window.py -q` (Windows Tk main loop available).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2 merged wave, Subagent 4 of 8). Zero overlap: Doc 16 exclusively creates `pc_agent/gui/__init__.py`, `pc_agent/gui/studio_window.py`, `pc_agent/tests/test_studio_window.py`; Doc 17 (same wave) creates only `tray_daemon.py` + its test and treats `gui/__init__.py` as read-only. Peers Docs 08/13/14/15/24/26/27 share no paths; all contact points (`GLCanvasHost.mount`, `export_submit`, event matrix) are frozen in §4 — no intra-wave ordering constraint.
- **Never touches:** `pc_agent/gui/tray_daemon.py` + its test (Doc 17), `pc_agent/main.py` (Doc 04 / Wave 3.A), `pc_agent/installer/*` (Docs 18/19), `pc_agent/{core,viewport,engine,network,export}/*` (Docs 04–15), other docs' tests, `mobile_app/**`, `qa/**`, `docs/overview.md`, `docs/_micro_doc_template.md`.
