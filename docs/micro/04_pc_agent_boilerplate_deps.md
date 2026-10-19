# Doc 04: PC Agent Boilerplate & Dependencies

## 1. Objective & Scope
* Scaffolds the Python 3.11+ `pc_agent/` package: dependency manifest, package `__init__`s, the frozen core contracts (`AppConfig`/`ConfigManager`, wire-protocol mirror, `EventBus`) and the `main.py` bootstrap skeleton every later PC doc plugs into.
* `core/protocol.py` is a **mirror** of the Doc 02 wire contract (constants, `LiveFrame`, `<BBHfff` pack/unpack, seq freshness) — `shared_specs/*.json` (Docs 02/03) remains the source of truth; semantics are never re-derived here.
* `core/events.py` defines the synchronous caller-thread `EventBus` plus all **13** event-name constants used by the template §4 event matrix (the original 11 plus round-4/5 `CANVAS_LIST_UPDATED` and round-6 `CANVAS_CLEARED`, Doc 02 §8/§9/§10.1).
* `main.py --smoke` proves config + bus + shader directory with **no GUI, no GL, no network** (CI-safe exit 0); the full branch sketches the complete lifecycle that Wave 3.A subagent 1 finalizes.
* Owns no rendering, network, or GUI logic — only contracts and bootstrap ordering.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/requirements.txt`
* `pc_agent/__init__.py`
* `pc_agent/core/__init__.py`
* `pc_agent/core/config_manager.py`
* `pc_agent/core/protocol.py`
* `pc_agent/core/events.py`
* `pc_agent/main.py` (bootstrap)
* `pc_agent/tests/test_config_manager.py`
* `pc_agent/tests/test_protocol.py`
* `pc_agent/tests/test_events.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` — mirrored constants and envelope actions/types (Docs 02/03)
* `_micro_doc_template.md` §3 — all numeric constants copied verbatim from there
* `pytest.ini`, `ruff.toml` at repo root (Doc 01); stdlib at import time only: `argparse`, `dataclasses`, `json`, `os`, `pathlib`, `struct`, `logging`, `sys`, `typing`
* Runtime, **lazy-imported inside the full-lifecycle branch only**: `GLCanvasHost` (Doc 06), `DocumentStore` (Doc 10), `WsStreamServer` (Doc 11), `DiscoveryPairing` (Doc 12), `StudioWindow` (Doc 16), `TrayDaemon` (Doc 17)
* `pc_agent/viewport/shaders/` (Docs 06/07/08) — `--smoke` checks the directory exists, nothing more

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/viewport/*` (Docs 06/07/08), `pc_agent/engine/*` (Docs 09/10), `pc_agent/network/*` (Docs 11/12), `pc_agent/export/*` (Docs 13–15), `pc_agent/gui/*` (Docs 16/17), `pc_agent/installer/*` (Docs 18/19)
* `shared_specs/*` (Docs 01–03), `mobile_app/*` (Docs 05, 20–27), `qa/*` (Doc 28)
* `docs/**` — strictly read-only: never edits `overview.md`, `_micro_doc_template.md`, or any sibling micro-doc

## 3. Contract References
* `overview.md` §3 (tree), §4.1 (16-byte frame layout), §4.2 (RPC envelope + 20 actions / 5 types — the 13 template actions plus Doc 02 §8.1/§9.1/§10.1 additions), §5 Doc 04 entry, §6 Wave 1.A subagent 4 and Wave 3.A subagent 1 (`main.py` final wiring).
* `_micro_doc_template.md` §3 (port `50606`, `<BBHfff`, FrameType `0x01–0x04`, ToolId `0x01–0x04`, seq rule mod 2^16, autosave `10 s`), §4 Doc 04 artifacts (reproduced verbatim below), §6 ownership matrix row 04.
* Consumed by every PC doc: `EventBus` + event constants (Docs 06, 09–17), `AppConfig` (Docs 06, 09–17), `pack/unpack_live_frame` + `is_newer_seq` (Docs 06, 11).

## 4. Interface Freeze
**Verbatim from template §4 — Wave 1.A artifacts (Doc 04), do not modify:**

```python
# pc_agent/core/config_manager.py (Doc 04)
@dataclass(frozen=True)
class AppConfig:
    ws_port: int = 50606
    mdns_service_type: str = "_slatesync._tcp.local."
    mdns_service_name: str = "SlateSync"
    autosave_interval_s: float = 10.0
    shader_dir: Path          # pc_agent/viewport/shaders
    assets_dir: Path          # %APPDATA%/SlateSync/assets
    export_dir: Path          # %APPDATA%/SlateSync/exports
    appdata_dir: Path         # %APPDATA%/SlateSync
    log_level: str = "INFO"
class ConfigManager:
    def __init__(self, root_dir: Path | None = None) -> None: ...
    @property
    def config(self) -> AppConfig: ...
    def load(self) -> None: ...      # reads %APPDATA%/SlateSync/config.json
    def save(self) -> None: ...

# pc_agent/core/events.py (Doc 04)
class EventBus:                      # synchronous emit on the CALLER'S thread
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
# Event name constants (same module):
# "LIVE_FRAME" "CAMERA_DELTA" "RPC_MESSAGE" "CONNECTION_STATE" "DOCUMENT_LOADED"
# "COMMITTED_NODE" "ARTBOARD_CHANGED" "EXPORT_STARTED" "EXPORT_PROGRESS"
# "EXPORT_FINISHED" "PAIRING_INFO"
# "CANVAS_LIST_UPDATED"   # round-4/5, Doc 02 §8.1/§9 — {canvases, devices}
# "CANVAS_CLEARED"        # round-6, Doc 02 §10.1 — {canvas_id}

# pc_agent/core/protocol.py (Doc 04 — mirrors Doc 02; import, never re-declare)
FRAME_LIVE_POINT, FRAME_LIVE_END, FRAME_CAMERA, FRAME_LASER = 0x01, 0x02, 0x03, 0x04
TOOL_PEN, TOOL_HIGHLIGHTER, TOOL_ERASER, TOOL_SHAPE_PREVIEW = 0x01, 0x02, 0x03, 0x04
@dataclass(frozen=True)
class LiveFrame:
    frame_type: int; tool_id: int; seq: int
    f1: float; f2: float; f3: float
def pack_live_frame(frame: LiveFrame) -> bytes: ...    # "<BBHfff", exactly 16 bytes
def unpack_live_frame(data: bytes | memoryview) -> LiveFrame: ...
```

**Doc-specific API & semantics (frozen):**

```python
# pc_agent/core/protocol.py (Doc 04) — seq freshness (template §3 rule, mod 2^16)
def is_newer_seq(seq: int, last: int | None) -> bool: ...   # None → True; delta = (seq - last) & 0xFFFF; True iff 0 < delta < 0x8000
FRAME_STRUCT: Final = struct.Struct("<BBHfff")              # 16 bytes little-endian
RPC_TYPES: Final = frozenset({"CANVAS_LIFECYCLE", "ELEMENT_COMMIT", "ARTBOARD_RESIZE",
                              "ASSET_UPLOAD", "EXPORT_JOB"})
RPC_ACTIONS: Final = frozenset({"OPEN_CANVAS", "ADD_STROKE", "ADD_GRAPH", "ADD_SHAPE",
    "ADD_IMAGE", "DELETE_NODE", "UPGRADE_SIZE", "START_EXPORT", "CANCEL_EXPORT",
    "EXPORT_PROGRESS", "EXPORT_FINISHED", "ASSET_START", "ASSET_CHUNK", "ASSET_DONE",
    "CANVAS_LIST_REQUEST", "CANVAS_LIST", "CANVAS_OPEN_REQUEST",     # Doc 02 §8.1
    "CANVAS_PUT", "CANVAS_PULL",                                     # Doc 02 §9.1
    "CLEAR_CANVAS"})                                                 # Doc 02 §10.1 — 20 total, mirrors Doc 02
```

* `ConfigManager.__init__` calls `self.load()` (**load-on-init**); default `root_dir = Path(os.environ["APPDATA"]) / "SlateSync"`; `load()` reads `<root>/config.json`, creates it with defaults when absent or invalid (warn + defaults, never raise); `save()` creates parent dirs and writes indented JSON. `AppConfig.shader_dir` resolves to `<repo>/pc_agent/viewport/shaders` relative to `main.py`.
* `EventBus` internals: `dict[str, list[Callable[..., None]]]`; `on()` **drops duplicate (event, handler) registrations** (second `on()` is a no-op); `off()` removes if present (missing = no-op); `emit(event, **payload)` runs handlers synchronously in registration order **on the caller's thread**; a handler exception is logged and does not prevent remaining handlers. The 13 constants: `LIVE_FRAME, CAMERA_DELTA, RPC_MESSAGE, CONNECTION_STATE, DOCUMENT_LOADED, COMMITTED_NODE, ARTBOARD_CHANGED, EXPORT_STARTED, EXPORT_PROGRESS, EXPORT_FINISHED, PAIRING_INFO, CANVAS_LIST_UPDATED, CANVAS_CLEARED`.
* `main.py --smoke`: construct `ConfigManager` + `EventBus`, assert `config.shader_dir` exists, print `OK`, `sys.exit(0)` — **no Tk, no GL, no sockets**.

## 5. Implementation Plan
1. **`pc_agent/requirements.txt`** — two blocks:
   ```
   # runtime (overview.md §5 Doc 04 + numpy for Docs 07/08 math)
   customtkinter  moderngl  pyglet  pycairo  reportlab  Pillow
   websockets  zeroconf  qrcode  pystray  rtree  numpy
   # dev (Doc 01 pytest.ini / ruff.toml)
   pytest  ruff
   ```
2. **Package inits** — `pc_agent/__init__.py` (`__version__ = "0.1.0"`); `pc_agent/core/__init__.py` re-exports `AppConfig`, `ConfigManager`, `EventBus`, `LiveFrame`, `pack_live_frame`, `unpack_live_frame`, `is_newer_seq`.
3. **`core/config_manager.py`** — frozen `AppConfig` (template §4) + `ConfigManager`: load-on-init, JSON round-trip at `%APPDATA%/SlateSync/config.json`, defaults fallback, `save()`.
4. **`core/protocol.py`** — `FRAME_*`/`TOOL_*` constants, frozen `LiveFrame`, `FRAME_STRUCT.pack/unpack` (exactly 16 bytes), `is_newer_seq`, `RPC_TYPES`/`RPC_ACTIONS` mirrors of Doc 02.
5. **`core/events.py`** — `EventBus` (`on`/`off`/`emit`, duplicate-handler guard, sync caller-thread emit, isolated handler errors) + the 13 event-name constants as module-level `str` finals.
6. **`main.py --smoke`** — `argparse` handles `--smoke` before any heavy import: config + bus + shader-dir existence → print `OK` → exit 0.
7. **`main.py` full lifecycle** (order frozen): `ConfigManager()` → `EventBus()` → `DiscoveryPairing.start()` → `WsStreamServer.start()` (daemon thread) → Tk `root` → `StudioWindow.build(root)` + `GLCanvasHost.mount(frame)` → `TrayDaemon(on_show, on_quit)` → `.bind_bus(bus)` → `.start()` → `root.after(int(autosave_interval_s * 1000), tick)` wrapping `DocumentStore.autosave_tick()` → `root.mainloop()`; teardown: tray → ws → discovery → `gl.shutdown()`.
   > **NOTE — Wave 3.A subagent 1 finalizes this same file** (`overview.md` §6): a sequential cross-wave edit of `pc_agent/main.py`, explicitly allowed by template §6 ("Sequential (cross-wave) edits are allowed"). Wave 1.A writes only the skeleton + `--smoke` path.
8. **venv bootstrap** (commands, executed once by Wave 1.A):
   ```
   py -3.11 -m venv .venv
   .venv\Scripts\python -m pip install -U pip
   .venv\Scripts\python -m pip install -r pc_agent\requirements.txt
   ```
9. **Tests** — `test_config_manager.py`, `test_protocol.py`, `test_events.py` (pytest, headless-safe; see §6).

## 6. Testing & Acceptance Criteria
* `test_config_manager.py`: first run creates `config.json` under a tmp `root_dir`; save→load round-trip preserves every `AppConfig` field; corrupted JSON falls back to defaults without raising; `shader_dir` points at `pc_agent/viewport/shaders`.
* `test_protocol.py`: `pack`→`unpack` round-trip equality; `len == 16` and byte offsets (type@0, tool@1, seq u16 LE @2, f32 @4/8/12); `is_newer_seq` wrap cases — `65535→0` True, equal False, `100→99` False, `0→32768` False (half-window), `last=None` True; `RPC_ACTIONS` has exactly the 20 Doc 02 actions (`ws_rpc_schema.json` enum), `RPC_TYPES` the 5.
* `test_events.py`: emit delivers payload kwargs to all handlers; `off` stops delivery; duplicate `on` → single invocation; handler exception logged while later handlers still run; the 13 constants are unique — the original 11 match template §4 names, `CANVAS_LIST_UPDATED`/`CANVAS_CLEARED` follow Doc 02 §8/§9/§10.1.
* Acceptance: venv bootstrap succeeds on Windows; `python pc_agent/main.py --smoke` exits 0 with no GUI/GL/network; `pytest pc_agent/tests -q` green; `ruff check pc_agent` clean.

## 7. Parallel Execution Notes
* **Wave 1.A** — subagent 4 of 5 (alongside Docs 01/02/03/05; zero overlapping "Creates" paths, template §6 row 04). Barrier: `core/protocol.py`, `core/events.py`, `core/config_manager.py` must exist before Wave 1.B (Docs 06/09/11/12 import them).
* **Wave 3.A** — subagent 1 **finalizes `pc_agent/main.py`**: same file as the Wave 1.A bootstrap, a *sequential* cross-wave edit allowed by template §6; never concurrent with Wave 1.A and never shared inside a wave.
* **Never touches (no-overlap confirmation):** Doc 04 creates only the ten paths listed in §2. It never writes `pc_agent/viewport/*` (Docs 06/07/08), `pc_agent/engine/*` (Docs 09/10), `pc_agent/network/*` (Docs 11/12), `pc_agent/export/*` (Docs 13–15), `pc_agent/gui/*` (Docs 16/17), `pc_agent/installer/*` (Docs 18/19), `shared_specs/*` (Docs 01–03), `mobile_app/*` (Docs 05, 20–27), `qa/*` (Doc 28), or anything under `docs/` — matching template §6 row 04 exactly.