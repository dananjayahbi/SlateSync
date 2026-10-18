# Doc 10: Canvas Persistence Store

## 1. Objective & Scope
* Owns `.slatesync` archives on the PC: a ZIP (`document.json` per the Doc 03 schema + `assets/*`) written **atomically** (`<path>.tmp` → `os.replace`) and read back into `CanvasDocument` plus the Doc 09 `SceneGraph`.
* `new()` seeds a document from Doc 03 defaults; `open()` rebuilds `CanvasNode`s and repopulates the injected `SceneGraph`; `save()` writes doc + assets and clears dirty; `autosave_tick()` saves **only when dirty** every `10 s` (single-writer).
* Subscribes `RPC_MESSAGE` (`CANVAS_LIFECYCLE`/`OPEN_CANVAS`, `ASSET_UPLOAD` chunk flow) and marks dirty on RPC mutations; emits `DOCUMENT_LOADED(doc)` after a successful load.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/engine/document_store.py`
* `pc_agent/tests/test_document_store.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/events.py` (`EventBus`, event constants) and `pc_agent/core/config_manager.py` (`AppConfig`) — Doc 04
* `pc_agent/engine/scene_graph.py` (`SceneGraph`, `CanvasNode`, `NodeStyle`, `NodeGeometry`) — Doc 09
* `shared_specs/canvas_document_schema.json` (Doc 03); asset-chunk field names of Doc 02 (template §3)
* stdlib `zipfile`, `json`, `os`, `threading`, `time`, `uuid`, `pathlib`

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/engine/scene_graph.py`, `pc_agent/engine/__init__.py`, `pc_agent/tests/test_scene_graph.py` (Doc 09)
* `pc_agent/core/*`, `pc_agent/main.py` (Doc 04); `pc_agent/viewport/*` (Docs 06/07/08); `pc_agent/network/*` (Docs 11/12); `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27)

## 3. Contract References
* `overview.md` §4.2 (envelope + `ASSET_START/CHUNK/DONE` semantics), §4.3 (`canvas_document_schema.json` keys), §5 Doc 10 entry, §6 Wave 1.B.
* `_micro_doc_template.md` §3 (`.slatesync` ZIP layout, `262144`-byte chunk cap, autosave `10 s`, preset dims), §4 (DocumentStore freeze reproduced verbatim below; `EventBus`/`AppConfig` from Doc 04), §6 ownership matrix.
* Consumes: node source of truth from Doc 09; envelopes delivered by Doc 11. Emits `DOCUMENT_LOADED(doc)` consumed by Docs 06/16 (event matrix). `open()` payload key `payload.path` is frozen here for Doc 16/26 senders.

## 4. Interface Freeze
**Verbatim from template §4 — Doc 10 exports, do not modify:**

```python
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
class DocumentStore:
    def __init__(self, bus: EventBus, config: AppConfig, scene_graph: SceneGraph) -> None: ...
    def new(self, preset: str, title: str) -> CanvasDocument: ...
    def open(self, path: Path) -> CanvasDocument: ...       # unzips .slatesync
    def save(self, doc: CanvasDocument, path: Path | None = None) -> Path: ...
    def assets_dir(self, canvas_id: str) -> Path: ...
    def autosave_tick(self) -> None: ...                    # called every 10 s by main.py
```

**Doc-specific API & contracts (frozen):**

```python
def asset_path(self, canvas_id: str, asset_ref: str) -> Path: ...  # assets_dir(canvas_id)/Path(asset_ref).name
@property
def current_path(self) -> Path | None: ...
@property
def is_dirty(self) -> bool: ...
# ZIP: document.json (ensure_ascii=False) + assets/<filename>  — write "<path>.tmp" then os.replace (atomic);
#      failure → unlink tmp, original file untouched, exception logged and re-raised.
# new(): canvas_id=str(uuid4()), created_at=updated_at=now, artboard per template §3 preset table
#        (INFINITE → width/height None, is_infinite=True), content_bounds zeros, elements []
#        → scene_graph.replace_all([]), scene_graph.set_artboard(doc.artboard)
#        → current_path = config.appdata_dir/"canvases"/f"{canvas_id}.slatesync", dirty=True
# open(): json → CanvasDocument → extract assets/* (zip-slip-safe basename) into assets_dir(canvas_id)
#        → scene_graph.replace_all(doc.elements), scene_graph.set_artboard(doc.artboard)
#        → current_path=path, dirty=False → emit("DOCUMENT_LOADED", doc=doc)  (state set BEFORE emit)
# save(): doc.updated_at=now; doc.elements=scene_graph.nodes(); doc.content_bounds=scene_graph.content_bounds()
#        → atomic write; current_path=path; dirty=False
# subscriptions registered in __init__:
#   RPC_MESSAGE type=CANVAS_LIFECYCLE action=OPEN_CANVAS → open(Path(msg["payload"]["path"]))
#   RPC_MESSAGE type=ASSET_UPLOAD: ASSET_START(transfer_id, filename, total_chunks, size_bytes) buffers;
#     ASSET_CHUNK(transfer_id, index, data_b64 ≤262144 raw) stores at index (out-of-order OK);
#     ASSET_DONE(transfer_id, ok=true) → concat, verify size/count → atomic write assets_dir/filename, dirty=True;
#     ok=false or mismatch → discard buffer + log (abort semantics)
#   COMMITTED_NODE / ARTBOARD_CHANGED → dirty=True
# autosave_tick(): under threading.Lock — no-op unless dirty AND _current AND current_path; ONE writer only
#        (single 10 s timer in main.py using config.autosave_interval_s; never called from WS thread)
```

* `assets_dir(canvas_id)` = `config.assets_dir/<canvas_id>`, created lazily (`mkdir(parents=True, exist_ok=True)`); every filename is reduced with `Path(name).name` on write **and** on ZIP extraction (zip-slip guard).
* `save(doc, path=None)`: `path` falls back to `current_path`; both absent ⇒ `ValueError` — never a silent destination.

**Serialization mapping (document.json ↔ dataclasses):** `artboard.{preset,width,height,is_infinite,background_style,background_color}`; `elements[].{node_id,kind,layer,bbox[4],style{color,stroke_width,opacity,blend_mode},geometry{pts,shape_type,graph_config,asset_ref}}`; top level `{canvas_id,title,created_at,updated_at,artboard,content_bounds,elements}` — keys verbatim from `overview.md` §4.3.

**Minimal `document.json` fragment:**

```json
{
  "canvas_id": "6f0c…", "title": "Control Systems Lecture 04", "created_at": 1760760000, "updated_at": 1760763600,
  "artboard": {"preset": "A4", "width": 2480.0, "height": 3508.0, "is_infinite": false,
               "background_style": "RULED", "background_color": "#FFFFFF"},
  "content_bounds": {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0},
  "elements": [{"node_id": "b7e1…", "kind": "STROKE", "layer": 0, "bbox": [120.0, 300.0, 450.0, 620.0],
                "style": {"color": "#1E1E1E", "stroke_width": 2.5, "opacity": 1.0, "blend_mode": "SRC_OVER"},
                "geometry": {"pts": [[120.4, 301.2]], "shape_type": null, "graph_config": null, "asset_ref": null}}]
}
```

## 5. Implementation Plan
1. **Module scaffold.** `DocumentStore.__init__` stores `bus/config/scene_graph`, creates `self._lock = threading.Lock()`, `self._current: CanvasDocument | None`, `self._current_path`, `self._dirty` flag, `self._transfers: dict[str, _Transfer]`, and registers the three subscriptions above.
2. **JSON codecs.** `_doc_to_json(doc)` / `_doc_from_json(dict)` converting `Artboard`, `CanvasNode`, `NodeStyle`, `NodeGeometry` with the frozen key mapping; `json.dumps(..., ensure_ascii=False)` so unicode titles round-trip byte-exact.
3. **`new()`.** Seed per §4 defaults from the §3 preset table; `scene_graph.replace_all([])` + `set_artboard`; set `current_path`/`dirty`; return doc.
4. **`save()` — atomic ZIP.** Serialize doc; gather every file in `assets_dir(canvas_id)` into `assets/<name>` entries; write `path.tmp` (`zipfile.ZIP_DEFLATED`); `os.replace(tmp, path)`; on any error `tmp.unlink(missing_ok=True)` and re-raise; clear dirty under lock.
5. **`open()` — rebuild.** Read `document.json` from the ZIP, parse to `CanvasDocument`, extract `assets/*` (basename-only) into `assets_dir`, hand `doc.elements` to `scene_graph.replace_all(...)`, `set_artboard(doc.artboard)`, set state, emit `DOCUMENT_LOADED(doc=doc)`.
6. **RPC asset ingestion.** Buffer chunks per `transfer_id` (list sized `total_chunks`); `ASSET_DONE` validates count + `size_bytes`, writes the file atomically (tmp+replace) into `assets_dir`, sets dirty; failures discard + `logging.getLogger("slatesync.store")`.
7. **`OPEN_CANVAS` + dirty tracking.** `CANVAS_LIFECYCLE`/`OPEN_CANVAS` calls `open(Path(msg["payload"]["path"]))` inside try/except (bus never crashes); `COMMITTED_NODE`/`ARTBOARD_CHANGED` handlers set dirty=True under the same lock.
8. **`autosave_tick()`.** Under `self._lock`: return early unless `dirty and _current is not None and _current_path is not None`; otherwise `save(self._current, self._current_path)`; the lock makes this the single writer against WS-thread RPC handlers.

## 6. Testing & Acceptance Criteria (`pc_agent/tests/test_document_store.py`)
* **Roundtrip equality:** `new()` → `save()` → `open()` compares field-by-field, including a unicode title (e.g. `"控制论 Lecture ✨"`), artboard fields, and `content_bounds`; second save is byte-stable in JSON keys.
* **Asset embedding:** feed `ASSET_START/CHUNK/DONE` over the bus → file lands in `assets_dir`; `save()` embeds `assets/<name>`; fresh store `open()` → `asset_path()` bytes equal originals.
* **Autosave no-op when clean:** after a save, `autosave_tick()` leaves file mtime/bytes unchanged; after `COMMITTED_NODE` (dirty), tick rewrites the file and clears dirty; no `current_path` ⇒ no-op.
* **Atomic replace:** `save()` leaves **no** `<path>.tmp`; simulated failure mid-ZIP keeps the previous file intact and still no `.tmp` remains.
* **Lifecycle:** `OPEN_CANVAS` with `payload.path` loads and emits `DOCUMENT_LOADED` exactly once (state clean before emit); `ASSET_DONE ok=false` discards the buffer; `new()` default dims match A5 `1748×2480` / A4 `2480×3508` / Letter `2550×3300` / INFINITE `None+is_infinite`.
* **Malformed archive:** corrupt or missing `document.json` ⇒ `open()` raises, no `DOCUMENT_LOADED`, store state unchanged; the `OPEN_CANVAS` wrapper catches and logs — the bus subscriber chain survives.
* **Sender contract:** `OPEN_CANVAS` without `payload.path` ⇒ logged error, no state change (Docs 16/26 must always send the key).
* **Single writer:** `autosave_tick()` racing a WS-thread `ASSET_DONE` never interleaves ZIP writes (shared lock; one `10 s` timer only).
* **Unicode asset filename** round-trips; `asset_path("cv1", "assets/img_9921.png")` resolves to `assets_dir("cv1")/img_9921.png`.
* **`save()` with no path anywhere ⇒ `ValueError`**, dirty stays True, no file written.

## 7. Parallel Execution Notes
* **Wave 1.B** — Session 1, Subagent 2 (“PC Scene Graph & Storage”) executes Doc 09 + Doc 10 together; all Batch-3 docs (09/10/11/12) are Wave 1.B per template §6.
* Zero overlap confirmed: Creates (`engine/document_store.py`, `tests/test_document_store.py`) are exclusive to Doc 10 — `engine/__init__.py` and `scene_graph.py` belong to Doc 09; `network/*` to Docs 11/12; `viewport/*` to Docs 06/07.
* **Never touches:** Doc 09’s `scene_graph.py`/`engine/__init__.py`/tests (imported read-only), `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*`, `pc_agent/network/*`, `shared_specs/*`, `pc_agent/main.py`, `mobile_app/*`.
* Intra-batch contracts (all authored in this batch): Doc 10 depends on Doc 09’s `replace_all`/`set_artboard`/`nodes`; Doc 11 supplies every `RPC_MESSAGE` this store reacts to; Doc 11/12 never import `engine/*`.
