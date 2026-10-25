# Doc 07: Stroke Tessellator & Shaders

## 1. Objective & Scope
* Converts committed/in-flight point arrays into GPU meshes:
  Catmull-Rom → cubic Bézier (tension 0.5) → adaptive sampling (~8 px/segment) →
  variable-width triangle strip (2 offset verts/segment) → round end caps (8-seg fans).
* Owns the `stroke` program files: `stroke.vert` (camera transform from template §3),
  `stroke.geom` (**minimal pass-through — explicit decision, see §4**),
  `stroke.frag` (`fwidth`-based smoothstep AA over analytic edge distance; uniform `u_blendMode`
  `0`=SRC_OVER / `1`=MULTIPLY with `glBlendFunc(GL_DST_COLOR, GL_ZERO)` per template §3).
* Interleaved VBO layout `[x, y, half_width]` float32 (stride 12 bytes).
* Two mesh regimes: **in-flight stroke** = append/rewrite a dynamic VBO (`GL_DYNAMIC_DRAW`);
  **committed stroke** = immutable one-shot upload returning a `TessellatedMesh` (Doc 06 stores it).
* Consumed by Doc 06 (same Wave 1.B subagent): `StrokeTessellator(ctx)` +
  `ProgramRegistry.get("stroke")`.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
* `pc_agent/viewport/stroke_tessellator.py`
* `pc_agent/viewport/shaders/stroke.vert`
* `pc_agent/viewport/shaders/stroke.geom`
* `pc_agent/viewport/shaders/stroke.frag`
* `pc_agent/tests/test_stroke_tessellator.py`

### Read-only dependencies (imports, each cited as "Doc NN")
* `pc_agent/core/protocol.py` (`LiveFrame.f3` = `width_pressure_factor`;
  `TOOL_HIGHLIGHTER` ⇒ MULTIPLY) — Doc 04
* `moderngl` context object handed in by Doc 06 — **no import of Doc 06** (keeps the graph acyclic)
* Camera transform + blend-mode constants of `_micro_doc_template.md` §3
* Pressure semantics of `overview.md` §4.1 (`f3 = width_pressure_factor` for `0x01` LIVE_POINT)
* Shader stem loaded by `ProgramRegistry` — Doc 06 (loader), file contents owned here
* Optional `numpy` for vertex-array math (requirements, Doc 04); stdlib `math`, `dataclasses`

### Never touches (paths owned by concurrent docs — write-conflict guard)
* `pc_agent/viewport/gl_canvas_host.py`, `pc_agent/viewport/__init__.py`,
  `tests/test_gl_canvas_host.py` (Doc 06)
* `pc_agent/viewport/primitive_renderer.py`, `shaders/primitive.*`, `shaders/grid.*`,
  `shaders/texture.*`, `tests/test_primitive_renderer.py` (Doc 08)
* `pc_agent/core/*`, `pc_agent/main.py` (Doc 04); `pc_agent/engine/*` (Docs 09/10);
  `pc_agent/network/*` (Docs 11/12); `pc_agent/export/*` (Docs 13–15); `pc_agent/gui/*` (Docs 16/17);
  `shared_specs/*` (Docs 01–03); `mobile_app/*` (Docs 05, 20–27); `qa/*` (Doc 28); `docs/**`

## 3. Contract References
* `_micro_doc_template.md` §3 — camera transform
  `screen = (world − camera_center) * scale + viewport/2`; FrameType `0x01` LIVE_POINT
  (f1=x, f2=y, f3=`width_pressure_factor`), `0x02` LIVE_END; ToolId `0x01` Pen ⇒ SRC_OVER,
  `0x02` Highlighter ⇒ MULTIPLY (`glBlendFunc(GL_DST_COLOR, GL_ZERO)`); stroke decimation `2.0 dp`
  is the tablet side (Doc 21) — the PC tessellator consumes the already-decimated points.
* `_micro_doc_template.md` §4 — `StrokeTessellator` + `TessellatedMesh` (verbatim below);
  `ProgramRegistry.get("stroke")` (Doc 06); flow `LIVE_FRAME` Doc 11 → Doc 06 → this module;
  committed meshes arrive via `COMMITTED_NODE` (Doc 09 → Doc 06 → this module's `build_stroke`).
* `overview.md` §3 tree (`viewport/stroke_tessellator.py`,
  `viewport/shaders/stroke.vert/.geom/.frag`), §5 Doc 07 entry,
  §6 Wave 1.B subagent 1 (Docs 06 + 07 as one unit).

## 4. Interface Freeze
**Verbatim from template §4 — do not modify:**

```python
class StrokeTessellator:                                # Doc 07
    def __init__(self, ctx) -> None: ...
    def build_stroke(self, points: list[tuple[float, float]],
                     pressure: list[float], width: float) -> "TessellatedMesh": ...
@dataclass
class TessellatedMesh: vao: object; vertex_count: int
                      bbox: tuple[float, float, float, float]
```

**Doc-specific API & algorithms (frozen):**

```python
def catmull_rom_to_bezier(p0, p1, p2, p3) -> tuple[tuple, tuple]:
    # tension 0.5: c1 = p1 + (p2 − p0)/6 ; c2 = p2 − (p3 − p1)/6  → cubic (p1, c1, c2, p2)
def sample_segment(c0, c1, c2, c3, step_px: float = 8.0, scale: float = 1.0) -> list[point]:
    # n = max(2, ceil(control_polygon_length * scale / step_px)); uniform t = i/n, de Casteljau
def build_strip(samples, half_widths) -> tuple[array, tuple]:
    # verts + bbox; strip = 2 verts/sample; caps appended as 8-seg fans
# vertex-count formula: verts = 2·S + 2·(CAP_SEGS + 1) = 2·S + 20   (S samples, CAP_SEGS = 8:
#   each cap = 9 rim verts + 1 center)
```

* **Catmull-Rom → cubic Bézier (tension 0.5):** interior segment `p1→p2` becomes
  `(p1, p1 + (p2−p0)/6, p2 − (p3−p1)/6, p2)`; first/last segments duplicate the open-polyline
  endpoints (`p_{-1} = p_0`, `p_n = p_{n-1}`).
* **Adaptive sampling:** chord metric `L = |c0−c1| + |c1−c2| + |c2−c3|`;
  `n = max(2, ceil(L·scale / 8.0))` samples at uniform `t` — ≈8 px per segment on screen.
* **Variable-width strip:** tangent by central differences per sample; unit perpendicular `n_i`;
  two verts `p_i ± n_i · hw_i`; **half-width lerp**
  `hw_i = 0.5 · width · lerp(1.0, pressure_i, width_pressure_factor)` —
  `wpf = 0` ⇒ constant width; `wpf = 1` ⇒ pressure maps linearly onto `0…width/2`.
* **Round end caps:** semicircular fan, `CAP_SEGS = 8` segments (9 rim angles from −90° to +90°
  around the end tangent) + center vertex — **built in the CPU pass** and appended to the VBO.
* **VBO regimes:** in-flight = `buffer.orphan()` + rewrite each `LIVE_POINT` (dynamic);
  committed = single `GL_STATIC_DRAW` upload; `TessellatedMesh{vao, vertex_count, bbox}` returned
  once and never mutated; bbox = sample bbox expanded by max `hw` per axis.
* **Fragment AA (analytic edge distance):** varyings `v_dist` (signed distance to centerline,
  edge verts carry `±hw`) and `v_half`; `d = abs(v_dist)`;
  `aa = fwidth(d)`; `alpha = 1 − smoothstep(v_half − aa, v_half + aa, d)`; discard `alpha < 1/255`.
* **Blend:** uniform `u_blendMode` — `0` SRC_OVER
  (`glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)`, premultiplied output);
  `1` MULTIPLY for `TOOL_HIGHLIGHTER` → `glBlendFunc(GL_DST_COLOR, GL_ZERO)` exactly per §3.
* **`stroke.geom` decision (state explicitly):** kept **minimal** — an identity/pass-through
  geometry shader with **no** `EmitVertex` expansion; **round caps are folded into the CPU pass**
  (8-seg fans baked into the vertex buffer). The `.geom` file exists only so the optional-geometry
  hook is stable for future miter/join work without changing `ProgramRegistry`'s stem contract.

## 5. Implementation Plan
1. **Spline stage (`stroke_tessellator.py`):** `catmull_rom_to_bezier` per consecutive 4-tuple with
   clamped endpoints; returns cubic control tuples.
2. **Sampling stage:** `sample_segment` derives `n` from `L / 8.0 px`, evaluates de Casteljau at
   uniform `t`, concatenates across segments and dedups shared joints.
3. **Width stage:** read `width_pressure_factor` from `LiveFrame.f3` (Doc 04); compute `hw_i` by
   the lerp rule; clamp to `≥ 1e-4` world units.
4. **Strip stage:** perpendicular offsets → `2·S` verts `[x, y, half_width]` interleaved float32.
5. **Cap stage:** append both 8-seg fans (center + 9 rim) in the same layout → one VBO, one VAO;
   draw body as `GL_TRIANGLE_STRIP` and caps as `GL_TRIANGLE_FAN` ranges from the same buffer.
6. **Mesh stage:** `build_stroke` assembles the above, computes `vertex_count` from the §4 formula
   and `bbox`; returns `TessellatedMesh`.
7. **Dynamic path (doc-specific):** `begin_live()` / `append_live(points, pressure, width)` /
   `end_live()` on the tessellator — `orphan()` + full rewrite for Doc 06's `0x01`/`0x02` frames.
8. **`stroke.vert`:** `in_vec3` (x, y, half_width); uniforms `u_camera (scale, tx, ty)` and
   `u_viewport (w, h)`; template §3 mapping → NDC; outputs `v_dist`, `v_half` varyings.
9. **`stroke.geom`:** identity pass-through (explicit §4 decision — caps live in the CPU pass).
10. **`stroke.frag`:** `fwidth` smoothstep AA; `u_blendMode` branch selecting the blend funcs;
    discard sub-threshold fragments.
11. **Tests** per §6 — pure-math tests run headless; VAO tests need a GL context (skipif).

## 6. Testing & Acceptance Criteria
* **Golden Bézier conversion (tension 0.5):**
  `(0,0),(3,0),(6,0),(9,0)` → `c1=(4,0)`, `c2=(5,0)`;
  `(0,0),(0,3),(0,6),(0,9)` → `c1=(0,4)`, `c2=(0,5)`;
  `p0=(0,0),p1=(1,0),p2=(2,1),p3=(3,1)` → `c1=(4/3, 1/6)`, `c2=(5/3, 5/6)` — tolerance `1e-6`.
* **Vertex-count formula:** `verts = 2·S + 20` — S=1 → 22, S=50 → 120; sampling
  `n = max(2, ceil(L/8))` (L=40 px ⇒ n=5; L=4 px ⇒ n=2).
* **Bbox correctness:** straight `(0,0)→(100,0)` with `hw=5` ⇒ bbox exactly `(-5,-5,105,5)`;
  curved stroke bbox contains every sampled offset vert (± max-hw padding on both axes).
* **Width-profile endpoints:** first/last `hw = 0.5·width·lerp(1, p, wpf)`;
  `wpf=0` ⇒ constant `0.5·width` at both ends; `wpf=1, p=0` ⇒ clamped `1e-4`;
  `wpf=1, p=1` ⇒ exactly `0.5·width`.
* **Shader contract (source-level):** `stroke.frag` contains `fwidth`, `smoothstep`,
  `u_blendMode`, and a `GL_DST_COLOR, GL_ZERO` reference; `stroke.geom` contains no
  `EmitVertex`/`EndPrimitive` (pass-through confirmed).
* Acceptance: `pytest pc_agent/tests -q` green headless; GL-marked tests pass on a Windows
  desktop; Doc 06 renders a live highlighter stroke in MULTIPLY with no blend-state leakage.

## 7. Parallel Execution Notes
* **Wave 1.B** — subagent 1 executes Doc 07 **together with Doc 06** (single agent owns both, so
  `GLCanvasHost` ↔ `StrokeTessellator` never races). Sibling wave members own Docs 09/10, 11/12,
  20–23, 25 — zero overlapping "Creates" paths (template §6 row 07).
* Doc 08 (Wave 2.A) writes sibling files in the same `viewport/shaders/` directory but with
  disjoint filenames (`primitive.*`, `grid.*`, `texture.*`) — no same-wave collision.
* Contracts consumed without file waits: `ProgramRegistry` API (Doc 06, frozen above),
  `LiveFrame`/`width_pressure_factor` (Doc 04 mirroring Doc 02), camera transform (template §3).
* **Never touches:** `viewport/gl_canvas_host.py` + `viewport/__init__.py` (Doc 06);
  `viewport/primitive_renderer.py` + `shaders/primitive.*`/`grid.*`/`texture.*` (Doc 08);
  `core/*` + `main.py` (Doc 04); `engine/*` (Docs 09/10); `network/*`, `export/*`, `gui/*`,
  `installer/*`, `shared_specs/*`, `mobile_app/*`, `qa/*`, `docs/**`.