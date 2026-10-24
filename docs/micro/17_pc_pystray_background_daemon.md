# Doc 17: pystray Background Daemon

## 1. Objective & Scope
Gives the PC agent a Windows system-tray presence: a `pystray` icon loop running in a **daemon thread**, a runtime-generated PIL icon (rounded square + stylus glyph at 16/32/48 px), a Show Studio / Quit menu, balloon `notify()`, and stylus auto-foreground — binds `LIVE_FRAME` on the bus and throttles raises to ≥1 s before invoking the injected `on_show`. This doc performs **zero** Tk calls: `on_show`/`on_quit` are injected by `main.py` (wired to Doc 16 `StudioWindow.show` and graceful teardown); Tk marshalling (`after(0, …)`) lives inside Doc 16.

**Behavior contract:** the tray menu exposes exactly **Show Studio** (default double-click action) and **Quit**; `start()` is idempotent (second call no-ops while running), `stop()` joins the loop thread within ≤2 s and tolerates a never-started daemon; `notify()` raises a native Windows balloon through pystray; stylus activity arrives as `LIVE_FRAME` (60 Hz from Doc 11) and can trigger at most **one** auto-foreground per second.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `pc_agent/gui/tray_daemon.py`
- `pc_agent/tests/test_tray_daemon.py`

### Read-only dependencies (imports, each cited as "Doc NN")
- `pc_agent/core/events.py` — `EventBus` + `"LIVE_FRAME"` constant (Doc 04)
- Doc 11 emit contract: `emit("LIVE_FRAME", frame=…)` on the WS thread (consumed via bus only)
- Doc 16 `StudioWindow.show()` — the ultimate target of `on_show` (injected by `main.py`; never imported here)
- `pystray`, `Pillow` (`Image`, `ImageDraw`) from requirements (Doc 04); `threading`, `time` stdlib

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `pc_agent/gui/__init__.py`, `pc_agent/gui/studio_window.py`, `pc_agent/tests/test_studio_window.py` (Doc 16)
- `pc_agent/main.py` (Doc 04 bootstrap; finalized in Wave 3.A — owns teardown order)
- `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*` (Docs 06–08), `pc_agent/engine/*` (Docs 09/10), `pc_agent/network/*` (Docs 11/12), `pc_agent/export/*` (Docs 13–15), `pc_agent/installer/*` (Docs 18/19)
- Other docs' test files, `mobile_app/**`, `qa/**`, `docs/overview.md`, `docs/_micro_doc_template.md`

## 3. Contract References
- template §4: `TrayDaemon` freeze (§4 below, verbatim); threading model — "pystray in a daemon thread (Doc 17)"; `EventBus.emit` is synchronous on the caller's thread
- template §4 event matrix: `LIVE_FRAME(frame)` | emitted Doc 11 | subscribed Doc 06 — **doc-sanctioned extension:** Doc 17 additionally binds `LIVE_FRAME` for auto-foreground; Doc 06 remains the rendering subscriber
- Overview §5 Doc 17: "automatically bring the mirror viewport to the foreground when the stylus touches the tablet"
- template §4 `StudioWindow.on_live_activity` comment (`tray auto-foreground, throttled ≥1 s`) — same ≥1 s throttle contract, applied here at the tray layer
- template §3 numeric constants: none consumed (throttle `1.0 s` from the §4 freeze comment; `join ≤ 2 s` is this doc's stop budget)
- Doc 06 also subscribes `LIVE_FRAME` for rendering — `EventBus` fan-out lets both subscriptions coexist with no intra-wave ordering constraint (Docs 06/17 are separate Wave 2.A files)
- Doc 04 `requirements.txt` (Wave 1.A) already ships `pystray` and `Pillow` — this doc introduces **no** new dependency.
- Thread boundary: tray thread and WS thread call only the injected `on_show`/`on_quit`; every Tk write happens inside Doc 16 via `after(0, …)` (template §4 threading model)

## 4. Interface Freeze
**Exported — verbatim from template §4:**
```python
class TrayDaemon:                                       # Doc 17
    def __init__(self, on_show: Callable[[], None], on_quit: Callable[[], None]) -> None: ...
    def start(self) -> None: ...                         # pystray loop in daemon thread
    def stop(self) -> None: ...
    def notify(self, title: str, message: str) -> None: ...
```
**Consumed (template §4 — never redefined):**
```python
class EventBus:                      # synchronous emit on the CALLER'S thread
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
# Event name constants (same module): "LIVE_FRAME"   # payload: frame=LiveFrame (Doc 04)
```
**Doc-specific API (added by Doc 17 — the frozen ctor carries no bus):**
```python
def bind_bus(self, bus: EventBus) -> None: ...          # bus.on("LIVE_FRAME", self._on_live_frame)
# internals: self._clock: Callable[[], float] = time.monotonic   # test-patchable
#             self._running: bool = False; self._icon / self._thread lazily created
# throttle: on_show fires at most once per 1.0 s (LIVE_FRAME ≈ 60 Hz ⇒ ≤1 raise/s)
# menu: MenuItem("Show Studio", …, default=True) / MenuItem("Quit", …)
# icon: PIL RGBA rounded square + stylus glyph at 16/32/48 px wrapped as ImageAsset
```
**Lifecycle states:**
| State | Entered by | Invariants |
|---|---|---|
| created | ctor returns | no thread, no pystray icon object, `_running is False` |
| bound | `bind_bus(bus)` | `LIVE_FRAME` handler registered (loop may still be off) |
| running | `start()` | `_icon.run()` executing on daemon thread `SlateSyncTray` |
| stopped | `stop()` | `icon.stop()` + `join(2.0)` done; `start()` may run again |

**Wiring reference (owned by `main.py`, Wave 3.A — not by this doc):**
```python
tray = TrayDaemon(on_show=studio.show, on_quit=teardown)   # studio.show is after(0,…)-safe
tray.bind_bus(bus); tray.start()                            # after StudioWindow.build(...)
```

## 5. Implementation Plan
1. **Scaffold & state.** `tray_daemon.py` imports `threading`, `time`, `pystray`, `PIL.Image/ImageDraw`; store `_on_show/_on_quit`, `_running = False`, `_icon = None`, `_thread = None`, `_bus = None`, `_last_fire = -inf`, `_clock = time.monotonic`. **Invariant: no `tkinter`/`customtkinter` import in this module** (grep-enforced).
2. **`_build_image()`.** 48×48 RGBA: dark rounded square (`ImageDraw.rounded_rectangle`, radius ≈10), stylus glyph (light diagonal stroke + nib triangle); downsample nearest-neighbour copies at 16 and 32 → `ImageAsset` (Windows shell sizes).
3. **`_build_menu()`.** pystray passes the activated icon as first arg — thin wrappers ignore it and call the injected callbacks:
```text
pystray.Menu(MenuItem("Show Studio", self._handle_show, default=True),
             MenuItem("Quit",        self._handle_quit))
self._handle_show(_) → self._on_show()     self._handle_quit(_) → self._on_quit()
```
4. **`_ensure_icon()`.** Lazily compose `pystray.Icon("SlateSync", icon=asset, title="SlateSync", menu=self._build_menu())`; called from `start()`/`notify()` only.
5. **`start()` — idempotent.** `if self._running: return`; `_ensure_icon()`; `self._thread = threading.Thread(target=self._icon.run, name="SlateSyncTray", daemon=True)`; start it; `_running = True`.
6. **`stop()` — idempotent.** Early-return when never started; bounded join so the Tk thread is never blocked long:
```python
if not self._running: return          # stop() without start() is a no-op
self._icon.stop()                     # signals the pystray loop to exit its message pump
self._thread.join(timeout=2.0)        # ≤2 s budget (template §4 / Wave 2.A contract)
self._running = False                 # second stop() repeats the early-return
```
7. **`notify(title, message)`.** `self._icon.notify(message, title)` (pystray Windows notify/balloon); guarded no-op when the daemon was never started or already stopped.
8. **`bind_bus(bus)`.** Retains the bus and registers the foreground trigger:
```python
self._bus = bus
bus.on("LIVE_FRAME", self._on_live_frame)        # handler fires on the WS thread (Doc 11)
```
   an `off()` on the same handler is issued inside `stop()` when a bus was bound.
9. **Throttle core `_on_live_frame(frame=None)`.** Pure state machine, no Tk, no pystray import needed in tests:
```python
t = self._clock()                               # time.monotonic, patchable in tests
if t - self._last_fire >= 1.0:                  # ≥1 s since last raise
    self._last_fire = t
    self._on_show()                             # → StudioWindow.show: deiconify+lift (Doc 16)
# else: drop — a 60 Hz stylus stream therefore yields ≤1 on_show per second
```
10. **Quit path.** `_handle_quit` → `self._on_quit()` — this doc stops only its own loop; `main.py` owns the graceful teardown order: `WsStreamServer.stop()` → `DiscoveryPairing.stop()` → `GLCanvasHost.shutdown()` → window destroy → `TrayDaemon.stop()`.
11. **Tests.** Owned file per §6.

## 6. Testing & Acceptance Criteria
Owned file: `pc_agent/tests/test_tray_daemon.py` (pytest, Doc 01 layout).
1. **Construction without the loop** — `TrayDaemon(on_show, on_quit)` succeeds with no pystray `Icon.run` invoked, `_running is False`, no thread created.
2. **Throttle** — patch `d._clock` with a fake clock; fire `d._on_live_frame(None)` 100× at the same timestamp → `on_show` called exactly **1** time; advance clock ≥1.0 s → next event fires (count 2).
3. **start/stop idempotency** — inject a fake icon object before `start()`; `start(); start()` launches exactly one loop thread; `stop(); stop()` returns without error or hang (join budget ≤2 s); `stop()` without `start()` is a no-op.
4. **Quit wiring** — `_handle_quit()` invokes the injected `on_quit` once (teardown stays in `main.py`).
5. **bind_bus registration** — recording `EventBus` spy asserts `on("LIVE_FRAME", …)` was called exactly once; `stop()` never touches Tk and never joins the caller's thread.
6. **notify safety** — `notify("t", "m")` before `start()` and after `stop()` raises nothing (guarded no-op on the not-yet-created icon).
Command: `pytest pc_agent/tests/test_tray_daemon.py -q` (no display/pystray loop required — icon is faked).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2 merged wave, Subagent 5 of 8). Zero overlap: Doc 17 exclusively creates `pc_agent/gui/tray_daemon.py` and `pc_agent/tests/test_tray_daemon.py`; `pc_agent/gui/__init__.py` belongs to Doc 16 in this same wave (read-only here — Python 3.11 namespace packages keep imports working regardless). Peers Docs 08/13/14/15/16/24/26/27 share no paths; `TrayDaemon` and the `LIVE_FRAME`/throttle contract are frozen in §4 — no intra-wave ordering constraint.
- **Never touches:** `pc_agent/gui/__init__.py` + `studio_window.py` + its test (Doc 16), `pc_agent/main.py` (Doc 04 / Wave 3.A), `pc_agent/installer/*` (Docs 18/19), `pc_agent/{core,viewport,engine,network,export}/*` (Docs 04–15), other docs' tests, `mobile_app/**`, `qa/**`, `docs/overview.md`, `docs/_micro_doc_template.md`.
