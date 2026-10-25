# Doc 08: Graph / Shape / Image Renderer

## 1. Objective & Scope
* Renders everything in the committed scene **except** strokes (those are Doc 07): procedural
  backgrounds (RULED / DOT_GRID / ISO_GRID / BLANK), artboard boundary + feathered drop-shadow,
  Cartesian/number-line graph axes with glyph-atlas labels, geometric shapes, and image quads.
* `PrimitiveRenderer` receives the node list from Doc 06 each frame and draws in frozen order:
  **background → shadow → images → shapes → graphs**.
* Performs its own frustum gate (`node.bbox ∩ camera world-rect`, computed with the template §3
  transform) — **no `scene_graph` dependency**; Doc 09's R-Tree remains the heavy pre-cull.
* Imports **only** the `CanvasNode`/`Artboard` models (Docs 09/10) — read-only contract types,
  never engine internals, never network/export code.
* Owns three shader pairs under `pc_agent/viewport/shaders/`:
  `primitive.*` (lines/shapes/graphs), `grid.*` (fullscreen background patterns),
  `texture.*` (image quads + glyph labels) — loaded via Doc 06's `ProgramRegistry`.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/viewport/primitive_renderer.py`
* `pc_agent/viewport/shaders/primitive.vert`
* `pc_agent/viewport/shaders/primitive.frag`
* `pc_agent/viewport/shaders/grid.vert`
* `pc_agent/viewport/shaders/grid.frag`
* `pc_agent/viewport/shaders/texture.vert`
* `pc_agent/viewport/shaders/texture.frag`
* `pc_agent/tests/test_primitive_renderer.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/engine/scene_graph.py` — `CanvasNode`, `NodeStyle`, `NodeGeometry` **models only** (Doc 09)
* `pc_agent/engine/document_store.py` — `Artboard` model (Doc 10)
* `pc_agent/viewport/gl_canvas_host.py` — `ProgramRegistry` + camera/viewport uniforms (Doc 06)
* `pc_agent/core/config_manager.py` — `AppConfig` (Doc 04)
* `DocumentStore.assets_dir(canvas_id)` path contract (Doc 10) — `assets_root` injected at
  `set_document` time by Doc 06 (read-only; this doc never writes assets)
* `PIL.Image` / `PIL.ImageFont` for the glyph atlas and image decode (requirements, Doc 04);
  stdlib `math`, `logging`, `dataclasses`, `functools`

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/viewport/gl_canvas_host.py`, `viewport/__init__.py`, `tests/test_gl_canvas_host.py` (Doc 06)
* `pc_agent/viewport/stroke_tessellator.py`, `shaders/stroke.*`, `tests/test_stroke_tessellator.py` (Doc 07)
* `pc_agent/core/*`, `pc_agent/main.py` (Doc 04 — Wave 3.A finalizes `main.py`)
* `pc_agent/engine/*` (Docs 09/10); `pc_agent/network/*` (Docs 11/12)
* `pc_agent/export/*` (Docs 13–15); `pc_agent/gui/*` (Docs 16/17); `pc_agent/installer/*` (Docs 18/19)
* `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27); `qa/*` (Doc 28); `docs/**` (read-only)

## 3. Contract References
* `_micro_doc_template.md` §3 — camera transform
  `screen = (world − camera_center) * scale + viewport/2`; artboard presets **top-left origin
  (0,0)→(w,h)**: A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`, INFINITE unbounded;
  backgrounds `BLANK, RULED, DOT_GRID, ISO_GRID`; blend modes `SRC_OVER`/`MULTIPLY`.
* `_micro_doc_template.md` §4 — `PrimitiveRenderer` (verbatim below);
  `ARTBOARD_CHANGED(artboard, content_bounds)` (Doc 09 → Docs 06/08/16);
  `CanvasNode`/`NodeGeometry` shapes (`shape_type`, `graph_config`, `asset_ref`) from Doc 09;
  `Artboard` from Doc 10.
* `overview.md` §4.3 (element JSON: `kind`, `bbox`,
  `shape_type` `RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE`, `graph_config`
  `{origin, x_range, y_range, grid_step, show_labels}`, `asset_ref`),
  §4.4 (bounded/infinite matrix), §5 Doc 08 entry, §6 Wave 2.A subagent 1.

## 4. Interface Freeze
**Verbatim from template §4 — do not modify:**

```python
class PrimitiveRenderer:                                # Doc 08
    def __init__(ctx, registry: ProgramRegistry) -> None: ...
    def render(self, nodes: list[CanvasNode], camera: tuple[float, float, float],
               artboard: Artboard, content_bounds: dict[str, float]) -> None: ...
```

**Doc-specific API & semantics (frozen):**

```python
def set_assets_root(self, root: Path) -> None: ...   # injected; DocumentStore.assets_dir contract (Doc 10)
def visible_world_rect(camera, viewport_wh) -> tuple[float, float, float, float]:
    # scale, tx, ty = camera; half = (w / (2·scale), h / (2·scale))
    # → (tx − half_x, ty − half_y, tx + half_x, ty + half_y)
def is_visible(node_bbox, world_rect) -> bool: ...   # AABB intersect, inclusive edges (touching = visible)
def glyph_atlas(self) -> "moderngl.Texture": ...     # PIL-baked once: chars "0123456789-+." → 16 cells
# atlas dims (frozen): 8 cols × 2 rows × 16×32 px cells = 128 × 64 px, LINEAR-filtered RGBA
```

* **(1) Background layer** — fullscreen `grid` program; fragment reconstructs world coordinates
  via the inverse §3 transform, then evaluates the pattern **in world units**:
  * `RULED` — horizontal line wherever `world_y ≡ 0 (mod 32)` (line every **32** world units);
  * `DOT_GRID` — dots at the `(24i, 24j)` lattice (**24** u spacing), radius ≈ `0.45·24` world
    units with `fwidth` AA at the rim;
  * `ISO_GRID` — line families at **+60° and −60°**, spacing **24** u, signed line-distance test
    with `fwidth` AA;
  * `BLANK` — solid `background_color` only.
  **Clipping:** bounded artboard → `gl_Scissor` to the artboard's screen rect; `INFINITE` → no clip.
* **(2) Artboard boundary** — 1 px screen-scaled outline of `(0, 0, w, h)` plus **feathered
  drop-shadow quads** beneath the page (shadow offset ≈ `0.02·min(w,h)` world units, feather width
  ≈ 3× offset, smoothstep falloff) — **bounded presets only**; INFINITE renders neither.
* **(3) Graph axes** —
  `CARTESIAN_2D`: x/y axis lines through `graph_config["origin"]`, major gridlines every
  `grid_step` clipped to `x_range`/`y_range`, tick length `0.35·grid_step`, numeric labels at
  major ticks when `show_labels` (CPU-baked digit glyph atlas → one quad per glyph via `texture`);
  `NUMBER_LINE`: single horizontal axis across `x_range`, ticks every `grid_step`, labels below
  ticks, arrowheads at both ends. `GRAPH_AXES` nodes with other `shape_type` values are skipped.
* **(4) Shapes** — `RECT` (corner quad from `pts`/bbox), `CIRCLE` (64-segment fan, center/radius
  from `pts[0..1]`/bbox), `TRIANGLE` (3 verts from `pts`),
  `ARROW` = shaft quad + **2 head triangles** (head length `0.25·shaft_length`,
  half-width `3× style.stroke_width`); all drawn by `primitive`, outline optional.
* **(5) Images** — texture-mapped quad spanning `node.bbox`; `asset_ref`
  (e.g. `assets/img_9921.png`) resolved through the injected `assets_root` as
  `assets_root / Path(asset_ref).name`; **missing file ⇒ 1×1 magenta placeholder +
  `logging.warning`** (never raises mid-frame); decoded textures cached by path and released on
  document swap.
* **(6) Frustum culling** — `is_visible(node.bbox, visible_world_rect(camera, viewport))` per node
  before phase dispatch; viewport size read from the bound FBO/screen (Doc 06 binds first);
  no R-Tree / `scene_graph` import.
* **Render order (frozen):** background → (shadow + boundary) → images → shapes → graphs;
  within a phase sort by `(layer, node_id)` for determinism.
* **Blend:** per `node.style.blend_mode`; `MULTIPLY` ⇒ `glBlendFunc(GL_DST_COLOR, GL_ZERO)` (§3),
  default `SRC_OVER` ⇒ standard alpha blending; state restored after `render`.

## 5. Implementation Plan
1. **Skeleton** — `PrimitiveRenderer.__init__` per template §4; holds `assets_root`, glyph atlas,
   texture cache, and three reusable batches (line, triangle, textured quad).
2. **Camera helpers** — `visible_world_rect` + `is_visible` (§4, pure math; unit-tested first).
3. **`grid` shaders** — `grid.vert` fullscreen triangle; `grid.frag` inverse transform + the four
   pattern branches (32 u ruled / 24 u dot / 24 u 60° iso / blank) with `fwidth` AA and a
   `u_scissor`-style artboard-rect uniform for bounded presets.
4. **Boundary + shadow** — line-loop outline; two feathered quads in the `primitive` program with
   smoothstep alpha falloff; gated on `not artboard.is_infinite`.
5. **Glyph atlas** — `PIL.ImageFont.truetype("segoeui.ttf", 24)` (Windows builtin; `arial.ttf`
   fallback) renders `0123456789-+.` into a `128×64` sheet (16 cells of `16×32`); uploaded once.
6. **Graph axes** — config-driven tessellation into the line batch (axes, gridlines, ticks) and
   glyph quads into the texture batch; `CARTESIAN_2D` and `NUMBER_LINE` branches per §4.
7. **Shapes** — RECT / CIRCLE(64-seg) / TRIANGLE / ARROW (shaft + 2 head tris) tessellators feeding
   the triangle batch; fill vs outline decided by `node.style`.
8. **Images** — resolve `asset_ref` → cached `PIL.Image.open` → `moderngl.Texture` (Y-flipped),
   emit UV-mapped quad from bbox; magenta placeholder fallback on missing file.
9. **`render(...)`** — cull once with `is_visible`, then dispatch the five phases in frozen order,
   applying/restoring blend state per node style.
10. **Tests** per §6 — math/atlas tests headless; GL-context tests `skipif` no display.

## 6. Testing & Acceptance Criteria
* **Culling math:** `(0,0,10,10)` vs `(5,5,15,15)` → visible; `(-1,-1,0,0)` vs `(0,0,5,5)` →
  visible (inclusive edge); `(0,0,1,1)` vs `(2,2,3,3)` → culled; camera `(scale=2, tx=100, ty=50)`
  at 800×600 ⇒ world-rect exactly `(-100,-100,300,200)`; scale clamp follows `0.05…20.0`.
* **Pattern coordinate math:** RULED fires at `world_y ∈ {−64, 0, 32, 64}`, not at `16`;
  DOT_GRID peak at `(48, 72)` (= `24·2, 24·3`), half intensity at `(12, 12)`;
  ISO_GRID line-distance `= 0` along the `y = tan(60°)·x` family line.
* **Glyph atlas dimensions:** sheet exactly `128×64` with 16 cells of `16×32`; every digit `0-9`
  has non-zero alpha inside its cell; second `glyph_atlas()` call returns the cached texture object.
* **Render order & import purity (source-level):** `render` executes phases in
  background → shadow → images → shapes → graphs order; module imports no engine symbols beyond
  the `CanvasNode`/`Artboard` models (Docs 09/10).
* GL-context tests marked `skipif` no display (texture/FBO creation); pure-math tests always run.
* Acceptance: `pytest pc_agent/tests -q` green headless; with a display, an A4 RULED canvas +
  `NUMBER_LINE` graph + one image renders in a single frame with `glGetError() == 0`;
  INFINITE canvas draws no shadow/boundary and applies no scissor.

## 7. Parallel Execution Notes
* **Wave 2.A** — subagent 1 of 8 executes Doc 08 (template §6 row 08). Wave 2.A siblings own
  export/GUI/Flutter paths (Docs 13–17, 24, 26, 27) — zero overlap with `pc_agent/viewport/*`.
* Contract-only dependencies on earlier waves: `ProgramRegistry`/camera uniforms (Doc 06),
  `CanvasNode` (Doc 09), `Artboard`/`assets_dir` (Doc 10) — all frozen in template §4, so no
  ordering constraint exists inside Wave 2.A (mirrors `overview.md` §6 barrier note).
* **Never touches:** `viewport/gl_canvas_host.py` + `viewport/__init__.py` (Doc 06);
  `viewport/stroke_tessellator.py` + `shaders/stroke.*` (Doc 07); `pc_agent/core/*` + `main.py`
  (Doc 04; Wave 3.A finalizes `main.py`); `pc_agent/engine/*` (Docs 09/10);
  `network/*` (Docs 11/12); `export/*` (Docs 13–15); `gui/*` (Docs 16/17);
  `installer/*` (Docs 18/19); `shared_specs/*`; `mobile_app/*`; `qa/*`; `docs/**`.
---

## 8. Round-8 Amendment — Fill vs Outline and Image Assets (NORMATIVE)

Two defects made the PC mirror disagree with the tablet. Both are fixed here and the rules below
supersede any earlier reading of §4/§5(7)/§5(8).

### 8.1 Shapes are OUTLINES unless the style asks for a fill

`shared_specs/canvas_document_schema.json` `NodeStyle` is frozen at
`color` / `stroke_width` / `opacity` / `blend_mode` — there is no fill field and none may be added.
The fill decision is therefore derived from `stroke_width` by
`pc_agent/viewport/shape_fill.py::shape_is_filled`:

| `style.stroke_width` | RECT / CIRCLE / TRIANGLE | ARROW |
|---|---|---|
| `> 0` (default `2.5`) | **outline only** — stroked rim, no interior | stroked shaft + barbs |
| `== 0` | solid fill in `style.color` | stroked shaft only |

The tablet draws every geometric tool with a `PaintingStyle.stroke` paint and never sets a fill, so
the previous unconditional `_push_tri(...)` fill made mirrored circles/rectangles/triangles solid.
ARROW is exempt from filling at every width: the tablet strokes its shaft and both barbs
(`_drawArrow`), so the viewport now emits `arrow_outline_segments` (shaft + two barbs at ±0.4 rad,
length `max(12, 4·stroke_width)`) instead of the filled shaft quad whose apex extended past the end
point. `arrow_geometry`/`ARROW_HEAD_*` remain for the exporters, which keep their own arrow rules.

### 8.2 Mirrored IMAGE nodes need an injected `assets_root`

`PrimitiveRenderer` has always resolved `geometry.asset_ref` against `set_assets_root(...)`, but
nothing ever called it in production, so every mirrored image fell through to the 1×1 magenta
placeholder even after `ASSET_START/CHUNK/DONE` wrote the bytes.

`GLCanvasHost.set_assets_root(root)` is now public and `main.py::remember_document` calls it with
`DocumentStore.assets_dir(canvas_id)` on every `DOCUMENT_LOADED`. The host stores the root before the
GL surface exists and applies it in `_init_gl_surface`, so a document opened before mount still
resolves. Swapping roots releases cached textures.

### 8.3 Acceptance
* A `CIRCLE` with the default width produces rim line triangles and **zero** fill triangles; the
  same node with `stroke_width=0` produces fill triangles and no rim.
* An `ARROW` produces only line triangles at every width, and its head stays inside the node bbox.
* `pc_agent/tests/test_shape_fill.py` pins both tables; `test_primitive_renderer.py` and
  `test_mirror_line_node.py` assert the outline/fill split from the renderer's own API.
---

## 9. Round-9 Amendment — `fill`, `PATH`, `TABLE` (NORMATIVE)

### 9.1 The fill decision now has two inputs

Round 8 derived "filled" from `stroke_width == 0` alone. Round 9 adds an explicit
`style.fill` (`#RRGGBB`), set by the tablet's paint bucket, which means *"keep the outline, paint the
interior"*. `_tessellate_shape` therefore emits interior triangles when **either** holds:

| `style.fill` | `stroke_width` | result |
|---|---|---|
| set | > 0 | **fill with `fill`**, stroke the outline in `color` (the paint bucket) |
| set | == 0 | fill with `fill` (the explicit value wins) |
| unset | == 0 | fill with `color` (the frozen legacy rule) |
| unset | > 0 | outline only |

ARROW is exempt from both routes — the tablet strokes its shaft and barbs, so a filled wedge would be
a new bug rather than a feature. A malformed `fill` is ignored (never painted black).

### 9.2 `PATH` — a closed polygon

`_tessellate_path` fills via **ear clipping** (`vector_geometry.triangulate`) rather than a triangle
fan. A pen-drawn loop is routinely concave and a fan paints OUTSIDE the outline, which is exactly the
artefact the fill tool must not produce; `test_vector_geometry.py` asserts the triangle area equals the
polygon area to prove it. The full outline is stroked, and a 2-point PATH degenerates to the open
segment it actually is.

### 9.3 `TABLE` — grid from `graph_config`

`_tessellate_table` paints the header bands (filled) then every grid segment (stroked) from
`vector_geometry.table_geometry`, which clamps `rows`/`cols` (1..200 × 1..40) so a corrupt document
cannot emit a million gridlines. The corner cell belongs to the row band only, so the two bands never
double-paint.

### 9.4 The exporters share the cairo path

`pc_agent/export/cairo_shapes.py` now owns `apply_fill` and `trace_shape` for the raster, PDF and
thumbnail exporters. They had already drifted once (round-8 arrow geometry), and copying three more
cases into three files is how four renderers stop agreeing with the tablet. Each exporter keeps only
what legitimately differs — colour and line width (the thumbnail scales the width).

### 9.5 Acceptance

* `pc_agent/tests/test_round9_rendering.py` — fill vs outline colours, malformed fill ignored, ARROW
  never filled, PATH polygon fill/stroke, 2-point PATH segment, TABLE bands/grid, degenerate bbox, and
  `apply_fill`/`trace_shape` on a real cairo surface.
* `pc_agent/tests/test_vector_geometry.py` — closure, concave point-in-polygon, ear-clipping area
  equality, table clamps.
* `test_primitive_renderer.py::test_module_imports_only_contract_models` now whitelists
  `viewport.vector_geometry` — it is a leaf module (no GL, no engine imports), exactly like
  `shape_fill`.
