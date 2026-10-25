# Doc 15: Export Stream Coordinator

## 1. Objective & Scope

Orchestrate export jobs triggered by the tablet or PC: a job registry + `ThreadPoolExecutor(max_workers=2)` running the frozen exporters (Docs 13/14), RPC-driven start/cancel, rate-limited progress envelopes over WebSocket (injected `push`) mirrored as bus events for the GUI, and a streamed chunk pusher that ships finished files back to the tablet without ever loading them whole in RAM.
* In scope: registry, executor, `EXPORT_JOB` RPC subscription, envelope builder (≤10 Hz + per strip/batch), `ASSET_START/CHUNK/DONE` chunk pusher (≤262144 raw bytes each), cooperative cancellation, error path.
* Out of scope: rendering math (Docs 13/14), GUI presentation (Doc 16), file chunk schema definition (Doc 02), WS transport itself (Doc 11).

## 2. File Ownership

### Creates (implementation subagent writes these paths)
* `pc_agent/export/export_coordinator.py`
* `pc_agent/tests/test_export_coordinator.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/events.py` → `EventBus` + event constants (Doc 04)
* `pc_agent/core/config_manager.py` → `AppConfig` (Doc 04)
* `pc_agent/export/tiled_raster_exporter.py` → `TiledRasterExporter` (Doc 13)
* `pc_agent/export/vector_pdf_exporter.py` → `VectorPdfExporter` (Doc 14)
* `pc_agent/network/ws_stream_server.py` → `WsStreamServer.broadcast_json` as injected `push`, wired in `main.py` (Docs 11/04)
* `pc_agent/engine/document_store.py` → `CanvasDocument`, `Artboard` (Doc 10); `pc_agent/engine/scene_graph.py` → `CanvasNode` (Doc 09)

### Never touches (paths owned by concurrent docs — write-conflict guard)
`pc_agent/viewport/**` (Docs 06–08) · `pc_agent/network/**` (Docs 11–12) · `pc_agent/engine/**` (Docs 09–10) · `pc_agent/gui/**` (Docs 16–17) · `pc_agent/core/**`, `pc_agent/main.py` (Doc 04) · `pc_agent/export/tiled_raster_exporter.py`, `vector_pdf_exporter.py`, `thumbnail_renderer.py`, `export/__init__.py` (Docs 13/14) · `pc_agent/installer/**` · `mobile_app/**` · `shared_specs/**` · `docs/**` except this file.

## 3. Contract References

* Template §3 constants: RPC envelope per `overview.md` §4.2 — types `EXPORT_JOB, ASSET_UPLOAD`, actions `START_EXPORT, CANCEL_EXPORT, EXPORT_PROGRESS, ASSET_START, ASSET_CHUNK, ASSET_DONE`; asset chunks `data_b64 ≤ 262144` bytes raw with fields `transfer_id, filename, total_chunks, size_bytes, index, data_b64`; WebSocket port `50606` (push path — Doc 11); `.slatesync` container (Doc 03); E2E gates `600 DPI` infinite export lossless, PDF `6400%` zoom (Docs 13/14 acceptance).
* Event matrix (template §4): this doc **emits** `EXPORT_STARTED / EXPORT_PROGRESS / EXPORT_FINISHED` (subscribed by Doc 16) and **subscribes** `RPC_MESSAGE` (emitted by Doc 11).
* Out of scope (Doc 02 §10.6): PC gallery thumbnails — `render_thumbnail` in `pc_agent/export/thumbnail_renderer.py` (Doc 13) is invoked on-demand by Doc 16's gallery via lazy import, **not** by this coordinator's job registry; Doc 02 §10.4 extent rules live inside Docs 13/14.
* Threading (template §4): exporters run in `ThreadPoolExecutor(2)` here; `EventBus.emit` is synchronous on the caller's thread — Doc 16 marshals Tk mutations with `after(0, ...)`; `WsStreamServer.broadcast_json` is thread-safe.

## 4. Interface Freeze

**Exports (verbatim from template §4):**

```python
class ExportCoordinator:                                # Doc 15
    def __init__(self, bus: EventBus, config: AppConfig,
                 raster: TiledRasterExporter, vector: VectorPdfExporter,
                 push: Callable[[dict], None]) -> None: ...   # push = WsStreamServer.broadcast_json
    def submit(self, job: dict) -> str: ...              # returns job_id; ThreadPoolExecutor(2)
    def cancel(self, job_id: str) -> None: ...
# subscribes RPC_MESSAGE where type=="EXPORT_JOB"; emits EXPORT_STARTED / EXPORT_PROGRESS
# (≤10 Hz + per strip) / EXPORT_FINISHED(job_id, percent, path, ok)
# ASSET_UPLOAD push to tablet built here (chunks ≤262144 raw, base64)
```

**Consumed (verbatim from template §4; the `WsStreamServer.broadcast_json` line carries the Doc 02 §10.2 round-6 `exclude` amendment):**

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

# pc_agent/core/events.py (Doc 04)
class EventBus:                      # synchronous emit on the CALLER'S thread
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
# Event name constants (same module):
# "LIVE_FRAME" "CAMERA_DELTA" "RPC_MESSAGE" "CONNECTION_STATE" "DOCUMENT_LOADED"
# "COMMITTED_NODE" "ARTBOARD_CHANGED" "EXPORT_STARTED" "EXPORT_PROGRESS"
# "EXPORT_FINISHED" "PAIRING_INFO"

# pc_agent/network/ws_stream_server.py (Doc 11)
class WsStreamServer:                                   # Doc 11
    def __init__(self, bus: EventBus, config: AppConfig,
                 token_provider: Callable[[], str],
                 host: str = "0.0.0.0") -> None: ...
    def start(self) -> None: ...                         # daemon thread + own asyncio loop
    def stop(self) -> None: ...
    @property
    def port(self) -> int: ...
    def broadcast_json(self, msg: dict, exclude=None) -> None: ...  # thread-safe push to all clients; §10.2 additive `exclude` skips the sender

# pc_agent/engine/document_store.py (Doc 10)
@dataclass
class Artboard:
    preset: str                               # A5|A4|LETTER|INFINITE
    width: float | None = None; height: float | None = None
    is_infinite: bool = False
    background_style: str = "BLANK"; background_color: str = "#FFFFFF"
@dataclass
class CanvasDocument:
    canvas_id: str; title: str
    created_at: int; updated_at: int
    artboard: Artboard
    content_bounds: dict[str, float]
    elements: list[CanvasNode]
# CanvasNode / NodeStyle / NodeGeometry frozen in pc_agent/engine/scene_graph.py (Doc 09)
```

**Doc-specific API (added):**

```python
CHUNK_RAW: int = 262144                               # template §3 asset chunks
STAGES = ("QUEUED", "EXPORTING", "TRANSFERRING", "DONE", "ERROR")
class ExportCancelled(Exception): ...                 # raised from the progress callback to abort Docs 13/14
def attach_document_loader(self, loader: Callable[[dict], CanvasDocument]) -> None: ...
    # payload → CanvasDocument; wired to DocumentStore (Doc 10) in main.py (Doc 04/Wave 3.A)
# registry entry: self._jobs: dict[str, dict]  # {status, percent, stage, out_path, cancel_flag}, Lock-guarded
def _on_rpc(self, msg: dict) -> None: ...             # type=="EXPORT_JOB": START_EXPORT ⇒ submit(payload); CANCEL_EXPORT ⇒ cancel(job_id)
def _envelope(self, action: str, canvas_id: str, job_id: str,
              percent: float, stage: str) -> dict: ...
    # {id: uuid4, type: "EXPORT_JOB", action, canvas_id, payload: {job_id, percent, stage}, timestamp: int}
def _run_job(self, job_id: str, payload: dict) -> None: ...
def _push_asset(self, canvas_id: str, path: Path, job_id: str) -> None: ...
```

## 5. Implementation Plan

1. **Registry + executor** — `__init__` stores bus/config/raster/vector/push, creates `ThreadPoolExecutor(max_workers=2)` and `self._jobs` guarded by `threading.Lock`; each job dict holds `status, percent, stage, out_path, cancel_flag`.
2. **RPC subscription** — `bus.on("RPC_MESSAGE", self._on_rpc)`: messages with `type == "EXPORT_JOB"` and `action == "START_EXPORT"` ⇒ `job_id = self.submit(msg["payload"])`; `CANCEL_EXPORT` ⇒ `self.cancel(payload["job_id"])`; everything else ignored.
3. **submit / cancel** — `submit(job)` generates `job_id = str(uuid4())`, inserts registry entry (`status=queued`, `percent=0.0`), emits the `START_EXPORT` envelope + `EXPORT_STARTED(job_id=…)` bus event, `executor.submit(self._run_job, …)`; `cancel(job_id)` sets `cancel_flag = True` (queued jobs skip straight to `cancelled`).
4. **Job runner** — pick exporter by `payload["format"]` (`PNG/JPG` ⇒ raster with `payload["dpi"]`, `PDF` ⇒ vector); `out_path = config.export_dir / payload["filename"]`; loader resolves the `CanvasDocument` (Doc 10 normalizes `artboard.preset/width/height/is_infinite` end-to-end — Doc 02 §10.4, so bounded exports always receive the exact artboard, never content-derived extents); the progress callback raises `ExportCancelled` when `cancel_flag` is set (cooperative check **between strips/batches** — Docs 13/14 propagate exceptions), and otherwise calls `_emit(EXPORT_PROGRESS, …)` throttled to **≤10 Hz** by monotonic clock with a guaranteed flush at `0.0`, `1.0`, and each strip/batch boundary.
5. **Envelope builder** — `_envelope` builds the Doc 02 schema dict (`id` uuid4, `type`, `action`, `canvas_id`, `payload`, `timestamp` int); `_emit` pushes it via `push` **and** mirrors it on the bus (`EXPORT_STARTED/EXPORT_PROGRESS/EXPORT_FINISHED(job_id, percent, path, ok)`).
6. **Chunk pusher** — if `target in ("TABLET", "BOTH")`: streamed `open(path, "rb")` loop — `data = f.read(CHUNK_RAW)` (never the whole file) → `base64.b64encode`; one `ASSET_START` (`transfer_id` uuid4, `filename`, `total_chunks`, `size_bytes`), `ASSET_CHUNK` per index (`transfer_id, index, data_b64`), then `ASSET_DONE` — all as `type: ASSET_UPLOAD` envelopes through `push`; `0`-byte file ⇒ `START` + `DONE` only.
7. **Error path** — any exception ⇒ `status=failed`, `EXPORT_FINISHED` envelope with `payload.ok == False` + `reason` (`"cancelled"` for `ExportCancelled`, else `str(exc)`) and matching bus event; `finally` clears registry entry after the terminal emit and keeps `out_path` for Explorer/GUI follow-up (Doc 16).

## 6. Testing & Acceptance Criteria

Owned test file (pytest): `pc_agent/tests/test_export_coordinator.py`
1. `test_progress_monotonic_0_to_100` — fake exporter with `time.sleep` calling `progress()` ⇒ pushed percents strictly non-decreasing, start `0.0`, final `1.0`, terminal `EXPORT_FINISHED ok:true`.
2. `test_cancel_mid_run` — fake exporter loops strips with sleep; `cancel(job_id)` between steps ⇒ no further `EXPORT_PROGRESS` pushes after cancel, finish has `ok:false`, `reason == "cancelled"`.
3. `test_chunk_boundaries` — chunker over temp files: `262144` B ⇒ `START + 1 CHUNK + DONE`; `262145` B ⇒ `2` chunks (sizes `262144, 1`); `0` B ⇒ `START + DONE` only.
4. `test_envelope_schema` — every pushed envelope matches Doc 02 (`overview.md` §4.2): keys `id, type, action, canvas_id, payload, timestamp`; `payload` keys `{job_id, percent, stage}`; actions ∈ `{START_EXPORT, EXPORT_PROGRESS, EXPORT_FINISHED}`.

Acceptance: progress ≤10 Hz yet complete per strip/batch; bus events and pushed envelopes always agree on `job_id/percent`; chunk payloads never exceed `262144` raw bytes; two concurrent jobs max (executor bound); empty-canvas/`ValueError` from Docs 13/14 surfaces as `EXPORT_FINISHED ok:false` + reason.

## 7. Parallel Execution Notes

**Wave 2.A** (template §6 — Subagent 3 executes Doc 15; Subagent 2 executes Docs 13 + 14) alongside Docs 08, 13, 14, 16, 17, 24, 26, 27. Zero path overlap: this doc alone owns `export_coordinator.py` and its test; it **consumes** the frozen `TiledRasterExporter`/`VectorPdfExporter` APIs (Docs 13/14) with no intra-wave ordering — constructor injection makes the dependency symmetric and compile-time safe.
**Never touches:** this doc never edits `pc_agent/viewport/`, `pc_agent/network/`, `pc_agent/engine/`, `pc_agent/gui/`, `pc_agent/core/`, `pc_agent/main.py`, or any `mobile_app/` file — those are read-only imports (Docs 04, 09–12) or owned by other same-wave subagents; `main.py` wiring of `push = WsStreamServer.broadcast_json` happens only in Wave 3.A (Doc 04/18 scope).

## 8. Round-7 Amendment — Export Destination & Document Freshness (NORMATIVE)

Round-7 fixes two user-reported defects: *"we should be able to set the export path
(select a folder), the default is the downloads folder"* and *"the export does not
export the latest canvas, just an older one"*.

### 8.1 Destination
* `AppConfig.export_dir` now defaults to `config_manager.default_export_dir()`
  (`~/Downloads`), not an appdata subfolder. Existing `config.json` files keep
  whatever path they store.
* `ConfigManager.set_export_dir(path)` / `update(**changes)` persist a Settings choice;
  `AppConfig` is no longer frozen so the running `ExportCoordinator` sees the new
  directory on the very next job (no restart). `ConfigManager._coerce` accepts both
  `str` and `Path` for the four path fields.
* `ExportCoordinator._out_path(job_id, payload)` resolves
  `Path(config.export_dir)` at job time and names the file
  `payload["filename"]` when present (title/extension sanitized, directory components
  stripped) else `<slug(payload["title"] or canvas_id)>.<ext>`. Existing files are
  never overwritten: `name (2).ext`, `name (3).ext`, … The job uuid is no longer the
  filename.
* `StudioWindow` adds `payload["title"]` to the `EXPORT_JOB`/`START_EXPORT` envelope so
  the file lands under the human canvas title.

### 8.2 Freshness
* New `DocumentStore.snapshot_current() -> CanvasDocument | None` returns a **shallow
  copy** of the open document carrying `SceneGraph.nodes()`, `SceneGraph.content_bounds()`
  and the scene's live artboard. `doc.elements` is only the opener's snapshot — every
  tablet edit after the open lives in the scene graph — which is exactly why exports
  used to serialize an older canvas.
* `main.py::document_for_export` now returns `store.snapshot_current() or current_doc["doc"]`
  and still raises `ValueError("export rejected: no document is open")` when nothing is
  open (surfaced as `EXPORT_FINISHED ok=false`).

### 8.3 Tests (`tests/test_export_coordinator.py`, `tests/test_export_destination.py`)
Default destination is Downloads; `set_export_dir` round-trips through `config.json`;
`_out_path` uses the title, honours `filename`, corrects the extension, refuses to
overwrite; a Settings change applies to the next job; the exported document contains a
node inserted after the document was opened.
