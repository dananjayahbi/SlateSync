# Doc 09: Spatial R-Tree Scene Graph

## 1. Objective & Scope
* Owns the authoritative PC-side spatial index: an `rtree.Index` keyed by node bbox with `node_id` as payload, paired with a parallel `dict[node_id, CanvasNode]` that is the **source of truth** (the index never holds geometry).
* Provides instant `query_bbox` frustum culling for Docs 06/08, incremental global `content_bounds`, §4.4 non-destructive artboard upgrade validation, and a bounded undo/redo command stack.
* Subscribes `RPC_MESSAGE` and routes `ELEMENT_COMMIT` / `ARTBOARD_RESIZE` envelopes through `apply_rpc`; emits `COMMITTED_NODE` and `ARTBOARD_CHANGED` on the Doc 04 `EventBus`.
* Thread safety: one `threading.RLock` guards every mutation and query — the WS thread (Doc 11 handlers) inserts/deletes while the Tk thread calls `query_bbox`/`content_bounds`; `EventBus.emit` itself stays synchronous on the caller's thread (template threading model).
* v1 limitations (frozen): **no ACK/NACK envelopes** — a refused `UPGRADE_SIZE` is logged and emits nothing; artboard changes are not undoable; undo history caps at 200 commands and is discarded on document reload.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/engine/__init__.py`
* `pc_agent/engine/scene_graph.py`
* `pc_agent/tests/test_scene_graph.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/events.py` — `EventBus` + event-name constants (Doc 04)
* `rtree` package (requirements, Doc 04); stdlib `uuid`, `logging`, `dataclasses`, `typing`
* Element/preset JSON shapes of `shared_specs/canvas_document_schema.json` (Doc 03); RPC envelope of Doc 02
* `Artboard` dataclass from `pc_agent/engine/document_store.py` (Doc 10) — **`TYPE_CHECKING`-only** import so the runtime import graph stays one-way (Doc 10 → Doc 09)

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/engine/document_store.py`, `pc_agent/tests/test_document_store.py` (Doc 10)
* `pc_agent/core/*`, `pc_agent/main.py` (Doc 04); `pc_agent/viewport/*` (Docs 06/07/08); `pc_agent/network/*` (Docs 11/12); `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27)

## 3. Contract References
* `overview.md` §4.2 (envelope types/actions), §4.3 (element JSON), §4.4 (upgrade rule), §5 Doc 09 entry, §6 Wave 1.B.
* `_micro_doc_template.md` §3 (artboard presets `1748×2480`/`2480×3508`/`2550×3300`/INFINITE, upgrade rule, RPC types/actions), §4 (SceneGraph + data models reproduced verbatim below; `EventBus` from Doc 04), §6 ownership matrix.
* Envelopes arrive from Doc 11 (bus). Emits consumed by: Doc 06 (`COMMITTED_NODE`), Docs 06/08/16 (`ARTBOARD_CHANGED`). Doc 10 persists via `nodes()`, `content_bounds()`, `replace_all()`, `set_artboard()`.

## 4. Interface Freeze
**Verbatim from template §4 — data models + `SceneGraph`, do not modify:**

```python
# pc_agent/engine/scene_graph.py (Doc 09)
@dataclass
class NodeStyle:
    color: str = "#1E1E1E"; stroke_width: float = 2.5
    opacity: float = 1.0; blend_mode: str = "SRC_OVER"
@dataclass
class NodeGeometry:
    pts: list[list[float]] = field(default_factory=list)
    shape_type: str | None = None            # RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE
    graph_config: dict | None = None
    asset_ref: str | None = None
@dataclass
class CanvasNode:
    node_id: str; kind: str                  # STROKE|HIGHLIGHT|LINE|SHAPE|GRAPH_AXES|IMAGE
    layer: int = 0
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    style: NodeStyle = field(default_factory=NodeStyle)
    geometry: NodeGeometry = field(default_factory=NodeGeometry)
class SceneGraph:
    def __init__(self, bus: EventBus) -> None: ...
    def insert(self, node: CanvasNode) -> None: ...
    def delete(self, node_id: str) -> None: ...
    def get(self, node_id: str) -> CanvasNode | None: ...
    def query_bbox(self, min_x, min_y, max_x, max_y) -> list[CanvasNode]: ...
    def content_bounds(self) -> dict[str, float]: ...      # {min_x,min_y,max_x,max_y}
    def apply_rpc(self, msg: dict) -> None: ...            # routes ELEMENT_COMMIT / ARTBOARD_RESIZE
    def validate_artboard_upgrade(self, target_preset: str, target_w: float | None, target_h: float | None) -> bool: ...
    def undo(self) -> bool: ...
    def redo(self) -> bool: ...
```

**Doc-specific API & event payloads (frozen):**

```python
# SceneGraph.__init__ registers: bus.on("RPC_MESSAGE", self.apply_rpc)
def nodes(self) -> list[CanvasNode]: ...            # all nodes sorted (layer, node_id) — Doc 10 save() source of truth
def replace_all(self, nodes: list[CanvasNode]) -> None: ...   # Doc 10 open(): fresh rtree.Index; clears dict, bounds, undo+redo; emits nothing
def set_artboard(self, artboard: Artboard) -> None: ...       # Doc 10 new()/open(): shares the live doc.artboard instance (mutated in place)
MAX_UNDO = 200                                      # command cap; oldest dropped when exceeded
# emissions (EventBus.emit kwargs — frozen sub-event contract):
#   add/update  → emit("COMMITTED_NODE", node=<CanvasNode>)
#   delete      → emit("COMMITTED_NODE", node=None, deleted_node_id=<str>)   # Doc 06 must drop deleted_node_id when node is None
#   undo/redo   → re-emit the matching COMMITTED_NODE sub-event (add-style or delete-style)
#   upgrade ok  → emit("ARTBOARD_CHANGED", artboard=<Artboard>, content_bounds=<dict>)
#   upgrade refused → log warning only, NO emit (v1 has no ACK envelope)
```

**`apply_rpc` routing table (frozen):**

| type | action | handling |
|---|---|---|
| `ELEMENT_COMMIT` | `ADD_STROKE` | build `CanvasNode` `kind="STROKE"` (payload may override `HIGHLIGHT`), `uuid4()` id if absent, insert, emit add |
| `ELEMENT_COMMIT` | `ADD_GRAPH` | build `kind="GRAPH_AXES"` (or payload override), insert, emit add |
| `ELEMENT_COMMIT` | `ADD_SHAPE` | build `kind="SHAPE"` (payload may set `LINE`), insert, emit add |
| `ELEMENT_COMMIT` | `ADD_IMAGE` | build `kind="IMAGE"`, insert, emit add |
| `ELEMENT_COMMIT` | `DELETE_NODE` | `delete(payload.node_id)`, emit `node=None, deleted_node_id=` |
| `ARTBOARD_RESIZE` | `UPGRADE_SIZE` | `validate_artboard_upgrade(...)` → mutate + emit / log-only |

* **Style change (undoable):** an `ADD_*` whose `payload.node_id` already exists is an in-place update (style/geometry/bbox patch + re-index) recorded as a style-change command.
* `bbox`: payload `bbox` wins; else min/max over `geometry.pts` (no pts ⇒ `(0,0,0,0)`). `UPGRADE_SIZE` width/height come from payload, else the §3 preset table; unknown preset ⇒ `False`.
* `validate_artboard_upgrade` implements §4.4 verbatim: allow iff `target==INFINITE` OR (`min_x>=0 AND min_y>=0 AND max_x<=target.w AND max_y<=target.h`) over current `content_bounds()`; zeros (empty doc) satisfy any bounded target.
* Other envelope types (`EXPORT_JOB`, `ASSET_UPLOAD`, `CANVAS_LIFECYCLE`) are ignored here — their subscribers are Docs 15/10.
* `content_bounds()` returns `{min_x, min_y, max_x, max_y}` floats: union fold on insert, targeted recompute on delete, zeros when empty — Doc 10 writes this dict into `document.json` verbatim.
* `replace_all` is deliberately **not** undoable and emits nothing, so Doc 10's `open()` cannot pollute undo history or re-trigger dirty marks.

## 5. Implementation Plan
1. **Scaffold state.** `self._nodes: dict[str, CanvasNode]`, `self._index = rtree.Index()`, `self._boxes: dict[str, tuple]` (exact boxes required by `rtree.delete`), `self._bounds`, `self._artboard`, `self._undo/_redo: list[Command]`, `self._bus`, `self._lock = threading.RLock()` (guards all index/dict/bounds/stack access); register `RPC_MESSAGE` subscription.
2. **insert/delete/get.** insert: dict-set + `self._index.insert(box, obj=node_id)` + fold into `_bounds`. delete: `self._index.delete(box, obj=node_id)`; if removed box touches `_bounds`, recompute union over remaining nodes; empty ⇒ zeros.
3. **query_bbox.** `self._index.intersection((minx, miny, maxx, maxy))` → map ids through `_nodes` → `sorted(key=lambda n: (n.layer, n.node_id))`.
4. **Command stack.** `Command` holds `do`/`undo` closures; `_push` clears `_redo`, appends, drops oldest past `MAX_UNDO`; `undo()`/`redo()` run inverse, re-emit `COMMITTED_NODE`, return `bool`.
5. **Routing — adds.** Filter `type=="ELEMENT_COMMIT"`; build node per table; existing id ⇒ style-change command, else insert-command; emit `COMMITTED_NODE(node=...)`.
6. **Routing — delete.** Capture node, apply delete, emit delete sub-event; inverse command re-inserts the exact `CanvasNode`.
7. **Artboard upgrade.** Resolve preset/w/h; on `True` mutate shared `_artboard` (`preset/width/height/is_infinite`) and emit `ARTBOARD_CHANGED`; on `False` `logging.getLogger("slatesync.scene_graph").warning(...)` and return with no emit.
8. **Doc 10 hand-off.** Implement `nodes()` / `replace_all()` / `set_artboard()` exactly as frozen; `replace_all` swaps in a fresh `rtree.Index` and resets bounds + both stacks (no stale undo history after load).
9. **Registration surface.** The constructor’s `bus.on("RPC_MESSAGE", self.apply_rpc)` is the only wiring this class performs; exactly one `SceneGraph` per `EventBus` exists (app: `main.py` in Wave 3.A; tests: per-test fixture) so routes are never double-registered.

## 6. Testing & Acceptance Criteria (`pc_agent/tests/test_scene_graph.py`)
* **Index vs brute force:** N random boxes; `query_bbox` id-set equals a linear scan for ≥20 random viewports, including edge-touching boxes.
* **Bounds union:** empty ⇒ `{0,0,0,0}`; incremental unions across inserts; deleting an extreme node recomputes; deleting an interior node preserves bounds.
* **Upgrade matrix (§4.4):** A5→A4 allowed; A4→A5 refused when content exceeds A5; any→INFINITE always allowed; INFINITE→Letter refused when content lies outside `2550×3300` (incl. negative coords); empty doc → any target allowed; unknown preset refused.
* **Event contract:** adds emit `node=<CanvasNode>`; delete emits `node=None, deleted_node_id`; refused upgrade emits nothing (bus spy).
* **Undo/redo sequences:** insert→undo→empty→redo→restored; delete→undo→query finds node; style change→undo reverts queryable bbox; cap drops oldest beyond 200; new command clears redo; `replace_all` empties both stacks.
* **Concurrency smoke:** a worker thread inserts/deletes while the main thread runs `query_bbox`/`content_bounds` — no exceptions, no torn bounds (RLock coverage).
* **Bbox derivation:** payload `bbox` wins; otherwise min/max over `geometry.pts` (empty ⇒ `(0,0,0,0)`) — index and brute-force reference agree on every query.

## 7. Parallel Execution Notes
* **Wave 1.B** — Session 1, Subagent 2 (“PC Scene Graph & Storage”) executes Doc 09 + Doc 10; all four Batch-3 docs (09/10/11/12) are Wave 1.B per template §6.
* Zero overlap confirmed: Creates (`engine/__init__.py`, `engine/scene_graph.py`, `tests/test_scene_graph.py`) belong solely to Doc 09 — Docs 06/07/10/11/12/20/21/22/23/25 share no path with it.
* **Never touches:** Doc 10’s `document_store.py`/tests, `pc_agent/core/*` (Doc 04), `pc_agent/viewport/*` (Docs 06/07/08), `pc_agent/network/*` (Docs 11/12), `shared_specs/*` (Docs 01–03), `pc_agent/main.py`, `mobile_app/*` — read-only citations or Wave 3.A wiring only.
* Intra-batch contracts (all authored in this batch): Doc 10 calls `replace_all`/`set_artboard`/`nodes` after `open()`; Doc 11 delivers the envelopes this router consumes; neither Doc 09 nor Doc 10 imports `network/*`.
