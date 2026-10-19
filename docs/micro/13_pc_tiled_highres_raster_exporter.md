# Doc 13: Tiled High-Res Raster Exporter (pycairo PNG/JPG)

## 1. Objective & Scope

Export bounded or INFINITE canvases to PNG/JPG at `300 / 600 / 1200 DPI` on the PC **without exhausting RAM**: render a row-major grid of `2048×2048` px strips with pycairo into a disk-backed `np.memmap` RGBA buffer (`.part` temp sibling in `config.export_dir`), then encode exactly once with PIL. Peak Python RAM = O(one strip) + OS page cache; a full-canvas RGBA Python copy is never materialized.
* In scope: extent resolution (Doc 02 §10.4: **bounded preset ⇒ EXACT artboard rect**, `px = world * dpi / 300` then strip-padded to the 2048 grid — never content-derived, distinct & proportionally-correct per preset per DPI; INFINITE ⇒ `content_bounds` padded 64 world units) → world→px scaling → strip grid → memmap allocation → per-strip draw (background patterns, strokes, shapes/graphs, images) → PNG/JPG encode → progress callback; plus the Doc 02 §10.6 PC thumbnail renderer `render_thumbnail` (192², sibling module in this package).
* Out of scope: vector PDF (Doc 14), job lifecycle / progress push / chunk transfer (Doc 15), OpenGL viewport rendering (Docs 06–08).

## 2. File Ownership

### Creates (implementation subagent writes these paths)
* `pc_agent/export/__init__.py`
* `pc_agent/export/tiled_raster_exporter.py`
* `pc_agent/export/thumbnail_renderer.py` (round-6, Doc 02 §10.6 `render_thumbnail`)
* `pc_agent/tests/test_tiled_raster_exporter.py`
* `pc_agent/tests/test_thumbnail_renderer.py`
* `pc_agent/tests/test_export_extent_matrix.py` (round-6, Doc 02 §10.4 extent matrix)

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/config_manager.py` → `AppConfig` (Doc 04)
* `pc_agent/engine/document_store.py` → `CanvasDocument`, `Artboard` (Doc 10)
* `pc_agent/engine/scene_graph.py` → `CanvasNode`, `NodeStyle`, `NodeGeometry` (Doc 09)
* Element/preset/background schema per `overview.md` §4.3–4.4 (Doc 03); `.slatesync` asset layout `assets/*` (Docs 03/10)
* Third-party: `pycairo`, `numpy`, `Pillow` (declared in `pc_agent/requirements.txt`, Doc 04)

### Never touches (paths owned by concurrent docs — write-conflict guard)
`pc_agent/viewport/**` (Docs 06–08) · `pc_agent/network/**` (Docs 11–12) · `pc_agent/engine/**` (Docs 09–10) · `pc_agent/gui/**` (Docs 16–17) · `pc_agent/core/**`, `pc_agent/main.py` (Doc 04) · `pc_agent/export/vector_pdf_exporter.py`, `pc_agent/export/export_coordinator.py` (Docs 14/15) · `pc_agent/installer/**` · `mobile_app/**` · `shared_specs/**` · `docs/**` except this file.

## 3. Contract References

* Template §3 constants (single source of truth): export strips `2048×2048 px`; `px = world_units * dpi / 300`; DPI choices `300, 600, 1200` (PNG/JPG; PDF is vector); artboard presets (300 DPI world units, top-left origin `(0,0)→(w,h)`) A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`, INFINITE unbounded; backgrounds `BLANK, RULED, DOT_GRID, ISO_GRID`; blend modes `SRC_OVER`, `MULTIPLY` (cairo: `CAIRO_OPERATOR_MULTIPLY`); `.slatesync` container = ZIP `document.json` + `assets/*`; E2E gate `600 DPI` infinite export lossless.
* `overview.md` §4.2 RPC envelope — `type: EXPORT_JOB`, actions `START_EXPORT / CANCEL_EXPORT / EXPORT_PROGRESS` (Doc 02); §4.3 element kinds `STROKE | HIGHLIGHT | LINE | SHAPE | GRAPH_AXES | IMAGE` (Doc 03).
* Frozen consumer: `ExportCoordinator` (Doc 15) instantiates this class and forwards `progress` to its ≤10 Hz envelope/event builder.

## 4. Interface Freeze

**Exports (verbatim from template §4):**

```python
class TiledRasterExporter:                              # Doc 13
    def __init__(self, config: AppConfig) -> None: ...
    def export(self, doc: CanvasDocument, dpi: int, out_path: Path,
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
STRIP_PX: int = 2048                                   # template §3 "Export strips"
def resolve_extent(doc: CanvasDocument) -> tuple[float, float, float, float]: ...
    # bounded ⇒ (0.0, 0.0, w, h) — EXACT artboard rect, never content-derived (Doc 02 §10.4);
    #   boundedness from artboard_is_infinite(artboard) (Doc 10 preset table): A5/A4/LETTER are
    #   ALWAYS bounded and INFINITE always unbounded — an extent resolving to content size for a
    #   bounded preset is a BUG, whatever the is_infinite flag says; distinct per preset per DPI
    # INFINITE ⇒ content_bounds padded +64 world units per side;
    # empty canvas ⇒ raise ValueError("empty canvas")   # frozen policy
def extent_to_px(extent, dpi: int) -> tuple[int, int]: ...   # ceil(w*dpi/300), ceil(h*dpi/300), padded to 2048 multiples
def _catmull_rom_sample(pts: list[list[float]], steps: int = 8) -> list[tuple[float, float]]: ...
    # local ~15-line sampler — intentional duplicate of Doc 07 spline math (avoids GL deps)
def _draw_background(ctx, artboard: Artboard, strip_world: tuple) -> None: ...  # fill + RULED/DOT_GRID/ISO_GRID pattern helper
def _draw_node(ctx, node: CanvasNode, assets_root: Path) -> None: ...           # HIGHLIGHT ⇒ CAIRO_OPERATOR_MULTIPLY
# progress contract: progress(strips_done / strips_total) ∈ [0.0, 1.0]; any exception raised by
# `progress` aborts the export and propagates (Doc 15 raises its cancel signal here); `.part` temp
# removed in `finally`. Images resolve at `config.assets_dir / doc.canvas_id` (Doc 10 layout); missing file ⇒ skip node.

# pc_agent/export/thumbnail_renderer.py (round-6, Doc 02 §10.6 freeze)
def render_thumbnail(doc, out_path: Path, size: int = 192) -> Path: ...
    # square PNG of the SAME artboard extent rule as resolve_extent (§10.4 — bounded ⇒
    # exact artboard, INFINITE ⇒ padded content_bounds); preset badges are NEVER baked
    # in (UI overlays only); shapes may approximate (§10.3 thumbnails-exception); used
    # on-demand by Doc 16's gallery via lazy import (default target: %APPDATA%/SlateSync/thumbs/)
```

## 5. Implementation Plan

1. **Module scaffold + constants** — create `pc_agent/export/__init__.py` (empty) and `tiled_raster_exporter.py`; `STRIP_PX = 2048`; validate `dpi in {300, 600, 1200}`; `_part_path(out_path)` → `out_path.parent / f".{out_path.stem}.{uuid4().hex}.part"` (sibling temp inside `config.export_dir`).
2. **Extent resolution** — `resolve_extent(doc)`: bounded ⇒ `(0.0, 0.0, float(artboard.width), float(artboard.height))`; INFINITE ⇒ `(min_x−64, min_y−64, max_x+64, max_y+64)` from `content_bounds`; INFINITE with missing/degenerate `content_bounds` ⇒ `raise ValueError("empty canvas")` (Doc 15 converts this into `EXPORT_FINISHED ok:false`). **§10.4 rules:** boundedness is decided by `artboard_is_infinite(artboard)` (Doc 10 preset table — `A5/A4/LETTER` ALWAYS bounded, `INFINITE` always unbounded, the raw `is_infinite` flag only consulted for unknown presets); Doc 10's loader normalizes `preset/width/height/is_infinite` end-to-end (dims backfilled from the preset table, strict bool coercion) so the exact artboard survives every load/index path; content-derived extents for bounded docs are a bug, and A5/A4/Letter/INFINITE must yield **distinct, proportionally-correct** pixel sizes at every DPI.
3. **Pixel sizing + strip grid** — `extent_to_px`: `px_w = ceil(world_w * dpi / 300)`, `px_h = ceil(world_h * dpi / 300)`; pad `canvas_w = ceil(px_w/2048)*2048`, `canvas_h = ceil(px_h/2048)*2048`; build row-major index list `[(sx, sy) …]` with `strips_x = canvas_w//2048`, `strips_y = canvas_h//2048`; JPG pre-check `max(canvas_w, canvas_h) <= 65535`.
4. **Disk-backed buffer** — `buf = np.memmap(part_path, dtype=np.uint8, mode="w+", shape=(canvas_h, canvas_w, 4))`; `buf[:] = 0`; only this memmap (OS page cache) represents the full canvas — no `np.zeros((h, w, 4))`, no `bytes(buf)`.
5. **Strip render loop** — for each `(sx, sy)`: `surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 2048, 2048)`; `ctx.scale(dpi/300, dpi/300)`; `ctx.translate(-world_x0, -world_y0)` with `world_x0 = extent.min_x + sx*2048*300/dpi`; clear → `_draw_background` (fill `background_color` + grid pattern, small local duplication of Doc 08 math is OK) → pre-filter `[n for n in doc.elements if bbox ∩ strip_world_rect]` preserving layer order → `_draw_node` (strokes: `_catmull_rom_sample(pts)` polyline, width/opacity/`SRC_OVER`; highlighter: `CAIRO_OPERATOR_MULTIPLY`; shapes/graphs per Doc 03 `shape_type`/`graph_config`; images: `cairo.ImageSurface.create_from_png` + `set_source_surface`).
6. **Strip flush → memmap** — `surface.flush()`; `view = np.frombuffer(surface.get_data(), np.uint8).reshape(2048, 2048, 4)` (keep `surface` referenced); assign the strip slice `buf[sy*2048:(sy+1)*2048, sx*2048:(sx+1)*2048] = view`; `progress((i+1) / total_strips)` — copy size is O(one strip).
7. **Encode + cleanup** — `img = Image.frombuffer("RGBA", (canvas_w, canvas_h), buf, "raw", "BGRA", 0, 1)` (zero-copy over the contiguous memmap; reorder only — every covered pixel is opaque, so premultiplied == straight); PNG ⇒ `img.save(out_path, "PNG")`; JPG ⇒ `img.convert("RGB").save(out_path, "JPEG")` — if either dimension exceeded `65535`, raise early advising PNG or PDF (Doc 14); in `finally`: `buf.flush()`, `del buf`, unlink `.part`; return `out_path`.
8. **RAM-gate documentation** — module docstring: resident set ≈ one 2048² ARGB32 surface + memmap page cache + PIL row encoder; full-RGBA Python copies are forbidden; JPG beyond `65535` px ⇒ use PNG or vector PDF.

## 6. Testing & Acceptance Criteria

Owned test files (pytest): `pc_agent/tests/test_tiled_raster_exporter.py`, `pc_agent/tests/test_thumbnail_renderer.py`, `pc_agent/tests/test_export_extent_matrix.py`
1. `test_dim_formula_a5` — A5 fixture `1748×2480`: `300→1748×2480`, `600→3496×4960`, `1200→6992×9920` px (pre-pad), padded canvas always a multiple of 2048 per axis.
2. `test_png_magic` / `test_jpg_magic` — export a small fixture; file starts with `\x89PNG\r\n\x1a\n` / `\xFF\xD8\xFF`.
3. `test_bounded_extent` ⇒ `(0, 0, w, h)`; `test_infinite_extent_padded_64` — content `(100,100,200,200)` ⇒ `(36,36,264,264)`.
4. `test_empty_canvas_raises` — INFINITE doc with degenerate `content_bounds` ⇒ `pytest.raises(ValueError, match="empty canvas")`.
5. **Extent matrix (§10.4, `test_export_extent_matrix.py`)** — A5/A4/Letter/INFINITE × `300/600/1200` DPI yield distinct, proportionally-correct sizes; bounded extent always equals the exact artboard @dpi strip-padded (never content-derived) even with a stale/mistyped `is_infinite` flag or a `document.json` where the flag was stored as the string `"false"` (loader normalization).
6. **Thumbnail (§10.6, `test_thumbnail_renderer.py`)** — `render_thumbnail` writes a `size²` PNG following the same §10.4 extent rule, contains no preset badge pixels, and its default size is `192`.

Acceptance: progress is monotonic `strips_done/strips_total` ending at `1.0`; `.part` temp removed on success **and** failure; no full-RGBA Python copy anywhere (memory gate); `600 DPI` infinite export lossless (E2E gate, Doc 28).

## 7. Parallel Execution Notes

**Wave 2.A** (template §6 — Subagent 2 executes Docs 13 + 14; Subagent 3 executes Doc 15) alongside Docs 08, 14, 15, 16, 17, 24, 26, 27 in one merged parallel wave. Zero path overlap: this doc alone owns `pc_agent/export/__init__.py`, `tiled_raster_exporter.py`, `thumbnail_renderer.py` (Doc 02 §10.6), and its tests (`test_tiled_raster_exporter.py`, `test_thumbnail_renderer.py`, `test_export_extent_matrix.py`); Docs 14/15 only create sibling files. All cross-module contact points (`TiledRasterExporter.export` → `ExportCoordinator`, Doc 15) are frozen in template §4, so no intra-wave ordering constraints exist.
**Never touches:** this doc never edits `pc_agent/viewport/`, `pc_agent/network/`, `pc_agent/engine/`, `pc_agent/gui/`, `pc_agent/core/`, `pc_agent/main.py`, or any `mobile_app/` file — those trees are read-only references (Docs 04, 06–12, 16, 17) or owned by other same-wave subagents.
