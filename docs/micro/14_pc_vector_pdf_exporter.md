# Doc 14: Vector PDF Exporter (pycairo PDFSurface)

## 1. Objective & Scope

Generate resolution-independent vector PDFs of bounded or INFINITE canvases on the PC via **pycairo `PDFSurface`** (the sole backend of this module — `reportlab` remains a declared dependency in `pc_agent/requirements.txt` (Doc 04) but is deliberately unused here), so viewers can zoom to `6400%` with razor-sharp curves and text labels (E2E gate, template §3).
* In scope: page policy (bounded / INFINITE / >14400 pt tiling fallback), world→pt transform, backgrounds, strokes as cubic Bézier curves, multiply highlighter, shapes/axes/graph labels, images, artboard boundary, node-batch progress.
* Out of scope: raster PNG/JPG (Doc 13), job lifecycle / push (Doc 15), OpenGL rendering (Docs 06–08).

## 2. File Ownership

### Creates (implementation subagent writes these paths)
* `pc_agent/export/vector_pdf_exporter.py`
* `pc_agent/tests/test_vector_pdf_exporter.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/config_manager.py` → `AppConfig` (Doc 04)
* `pc_agent/engine/document_store.py` → `CanvasDocument`, `Artboard` (Doc 10)
* `pc_agent/engine/scene_graph.py` → `CanvasNode`, `NodeStyle`, `NodeGeometry` (Doc 09)
* Element kinds + `graph_config` per `overview.md` §4.3 (Doc 03); `pc_agent/export/__init__.py` package marker (Doc 13)
* Third-party: `pycairo` (Doc 04 requirements)

### Never touches (paths owned by concurrent docs — write-conflict guard)
`pc_agent/viewport/**` (Docs 06–08) · `pc_agent/network/**` (Docs 11–12) · `pc_agent/engine/**` (Docs 09–10) · `pc_agent/gui/**` (Docs 16–17) · `pc_agent/core/**`, `pc_agent/main.py`, `pc_agent/requirements.txt` (Doc 04) · `pc_agent/export/__init__.py`, `tiled_raster_exporter.py`, `thumbnail_renderer.py` (Doc 13) · `pc_agent/export/export_coordinator.py` (Doc 15) · `pc_agent/installer/**` · `mobile_app/**` · `shared_specs/**` · `docs/**` except this file.

## 3. Contract References

* Template §3 constants: `PDF points = world_units * 72 / 300`; PDF is vector (no DPI); artboard presets (300 DPI world units, top-left origin `(0,0)→(w,h)`) A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`, INFINITE unbounded; backgrounds `BLANK, RULED, DOT_GRID, ISO_GRID`; blend modes `SRC_OVER`, `MULTIPLY` (cairo: `CAIRO_OPERATOR_MULTIPLY`); `.slatesync` = ZIP `document.json` + `assets/*`; E2E gate PDF vector zoom `6400%`.
* `overview.md` §4.3 element kinds `STROKE | HIGHLIGHT | LINE | SHAPE | GRAPH_AXES | IMAGE` with `geometry.shape_type` / `graph_config` / `asset_ref` (Doc 03); §4.2 `EXPORT_JOB` actions (Doc 02).
* Frozen consumer: `ExportCoordinator` (Doc 15) calls `export(...)` and forwards `progress` to its ≤10 Hz envelope/event builder.

## 4. Interface Freeze

**Exports (verbatim from template §4):**

```python
class VectorPdfExporter:                                # Doc 14
    def __init__(self, config: AppConfig) -> None: ...
    def export(self, doc: CanvasDocument, out_path: Path,
               progress: Callable[[float], None] | None = None) -> Path: ...
```

**Consumed (verbatim from template §4):**

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
```

**Doc-specific API (added):**

```python
UNIT_TO_PT: float = 72 / 300                           # points = world_units * 72/300
PAGE_PT_LIMIT: int = 14400                             # PDF maximum page dimension (pt)
def page_size_pt(doc: CanvasDocument) -> tuple[float, float]:
    # bounded ⇒ (width * 72/300, height * 72/300) — EXACT artboard page, never
    #   content-derived; boundedness via artboard_is_infinite (Doc 10 preset table,
    #   Doc 02 §10.4): A5/A4/LETTER ALWAYS bounded whatever is_infinite says, so each
    #   preset yields a distinct, proportionally-correct page in points
    # INFINITE ⇒ content_bounds padded +48 world units per side, then * 72/300
def _tile_pages(w_pt: float, h_pt: float) -> list[tuple[int, int, float, float]]: ...
    # single page iff w_pt <= 14400 and h_pt <= 14400; else split along the long axis into
    # (page_index, page_count, offset_world_x, offset_world_y) tiles
def _catmull_to_cubic(pts: list[list[float]]) -> list[tuple[float, float, float, float, float, float]]: ...
    # local ~15-line Catmull-Rom→cubic Bézier helper — intentional duplicate of Doc 07 math
def _draw_background(ctx, artboard: Artboard, w, h) -> None: ...     # fill + RULED/DOT_GRID/ISO_GRID pattern
def _draw_node(ctx, node: CanvasNode, assets_root: Path) -> None: ... # HIGHLIGHT ⇒ CAIRO_OPERATOR_MULTIPLY
# progress contract: progress(fraction) per node batch throttled ≤10 Hz; any exception raised by
# `progress` aborts and propagates (Doc 15 raises its cancel signal here); temp `.part` removed in `finally`.
```

## 5. Implementation Plan

1. **Module scaffold + constants** — `vector_pdf_exporter.py`; `UNIT_TO_PT = 72/300`, `PAGE_PT_LIMIT = 14400`; `.part` temp sibling in `config.export_dir`; module docstring states "pycairo-only; reportlab declared but unused".
2. **Page policy** — `page_size_pt(doc)`: bounded ⇒ one page = artboard in points (`w*0.24 × h*0.24`); INFINITE ⇒ single page = `content_bounds` padded `48` units/side × `72/300`; degenerate INFINITE bounds ⇒ `raise ValueError("empty canvas")` (same frozen policy as Doc 13). **§10.4 rules:** boundedness comes from `artboard_is_infinite(artboard)` (Doc 10 preset table — `A5/A4/LETTER` ALWAYS bounded, `INFINITE` always unbounded; the raw `is_infinite` flag is only consulted for unknown presets), and Doc 10's loader normalizes `preset/width/height/is_infinite` end-to-end so the exact artboard survives every load path — a bounded page that resolved to content size would be a bug; A5/A4/Letter pages stay distinct and proportionally correct.
3. **Tiling fallback** — if either page dimension would exceed `14400 pt`, split along the long axis (`_tile_pages`); one `PDFSurface` with the tile page size, `show_page()` per tile; each node is drawn on **every** page it intersects, with `ctx.translate(-offset_x, -offset_y)` in world units so strokes crossing seams are drawn once per page — vector seams are invisible.
4. **Surface setup** — `surface = cairo.PDFSurface(tmp, w_pt, h_pt)`; `ctx.scale(72/300, 72/300)` so all drawing happens in world units; per node batch: pre-filter `doc.elements` by bbox ∩ page world-rect (layer order preserved).
5. **Backgrounds & boundary** — fill `background_color`; pattern helper for `RULED/DOT_GRID/ISO_GRID` (small local duplication of Doc 08 grid math is OK); for bounded docs stroke the artboard rectangle boundary line (1 pt, `SRC_OVER`).
6. **Strokes & highlighter** — `_catmull_to_cubic(pts)`: for each interior segment `c1 = P1 + (P2−P0)/6`, `c2 = P2 − (P3−P1)/6` → `ctx.curve_to(c1, c2, P2)`; `set_line_width(stroke_width)`, round caps/joins, alpha from `opacity`; `kind == "HIGHLIGHT"` ⇒ `ctx.set_operator(cairo.OPERATOR_MULTIPLY)`.
7. **Shapes, axes, labels, images** — `SHAPE` per `shape_type` (RECT/CIRCLE/TRIANGLE/ARROW); `GRAPH_AXES` from `graph_config` (`origin`, `x_range`, `y_range`, `grid_step`, `show_labels`) with ticks; labels via cairo toy text API (`select_font_face` / `show_text`); `IMAGE` via `set_source_surface` from PNG loaded under `config.assets_dir / doc.canvas_id`; missing asset ⇒ skip node.
8. **Progress + finish** — `progress((i+1) / len(elements))` per batch throttled `≤10 Hz` (monotonic clock, always flush the final `1.0`); multi-page loop repeats 5–7 per `show_page()`; `surface.finish()`; rename `.part` → `out_path`; return `out_path`.

## 6. Testing & Acceptance Criteria

Owned test file (pytest): `pc_agent/tests/test_vector_pdf_exporter.py`
1. `test_pdf_magic` — exported file starts with `%PDF`.
2. `test_a4_page_points` — A4 fixture `2480×3508` ⇒ `595.2 × 841.9 pt` (±0.5) via `page_size_pt`.
3. `test_infinite_page_points` — fixture `content_bounds` padded `±48` units, × `72/300`, matches file page size (±0.5).
4. `test_nontrivial_size` — file with ≥1 stroke is > 1 KB (real content, not an empty header).
5. `test_tiling_fallback` — synthetic extent whose pt size exceeds `14400` ⇒ `_tile_pages` splits along the long axis into >1 page.
6. **Extent rule (§10.4)** — A5/A4/Letter produce distinct, proportionally-correct pages (`1748×2480 → 419.5×595.2 pt`, `2480×3508 → 595.2×841.9 pt`, `2550×3300 → 612×792 pt` ±0.5) regardless of a stale/mistyped `is_infinite` flag; INFINITE pages remain content_bounds-derived (padded 48 units).

Acceptance: progress monotonic ending at `1.0`, throttled ≤10 Hz; bounded docs carry the artboard boundary line; highlighter uses `CAIRO_OPERATOR_MULTIPLY`; PDF zooms to `6400%` vector-sharp (Doc 28); `.part` temp removed on success and failure.

## 7. Parallel Execution Notes

**Wave 2.A** (template §6 — Subagent 2 executes Docs 13 + 14; Subagent 3 executes Doc 15) alongside Docs 08, 13, 15, 16, 17, 24, 26, 27. Zero path overlap: this doc alone owns `vector_pdf_exporter.py` and its test; Doc 13 owns `export/__init__.py`; Doc 15 owns `export_coordinator.py`. The `VectorPdfExporter` → `ExportCoordinator` contact point is frozen (template §4) — no intra-wave ordering.
**Never touches:** this doc never edits `pc_agent/viewport/`, `pc_agent/network/`, `pc_agent/engine/`, `pc_agent/gui/`, `pc_agent/core/`, `pc_agent/main.py`, or any `mobile_app/` file — read-only references (Docs 04, 06–12, 16, 17) only; Doc 13's `export/__init__.py` is import-only.
