# Doc 22: Tiled Picture Cache Engine (2 GB-safe)

## 1. Objective & Scope
The $2\text{ GB}$-RAM rendering core: partition world space into $1024\times1024$ tiles, bake static
strokes into bucketed `ui.Picture` tiles behind an LRU byte-budget cache, keep an in-file R-Tree over
committed nodes, and make every commit dirty **only** its containing tiles (event-driven rebake — the
anti-quadratic guarantee for $10\,000$ strokes @ 60 FPS, Flutter heap $< 180\text{ MB}$). Also the
dual-layer `RepaintBoundary` widget separating static tiles from live strokes. Documentation only.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/canvas_engine/tiled_canvas_painter.dart`
- `mobile_app/test/tiled_canvas_painter_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- `mobile_app/lib/core/models/canvas_models.dart` — `TileKey` inputs `CanvasNodeModel`,
  `CanvasDocumentModel` (Doc 05)
- `mobile_app/lib/canvas_engine/camera_controller.dart` — `CameraController` ctor arg (Doc 20)
- `mobile_app/lib/canvas_engine/stroke_processor.dart` — `ProcessedStroke` input (Doc 21)
- `docs/_micro_doc_template.md` §5 `TileKey/TileCache/SpatialRTree/TiledCanvasEngine` freeze +
  §3 constants (tiles `1024×1024`, `TileKey(floor(x/1024), floor(y/1024))`, LRU ≤ ~120 MB)
- `docs/overview.md` §3 tree (`tiled_canvas_painter.dart`), §6 Wave 1.B subagent 5

### Never touches (paths owned by concurrent docs — write-conflict guard)
- Doc 05 files (scaffold, `lib/core/**`, Doc 05 tests); Doc 20 `camera_controller.dart` (+ test);
  Doc 21 `stroke_processor.dart` (+ test); Doc 23 `artboard_manager.dart` (+ test);
  Docs 24–27 paths, `lib/network/**` (Doc 25), `pc_agent/**`, `qa/**` (Doc 28)

## 3. Contract References
- Template §3 Master Constants: `TileKey(tx=floor(x/1024), ty=floor(y/1024))`; LRU Picture cache
  ≤ ~120 MB; camera transform `screen = (world − camera_center) * scale + viewport/2`; zoom `0.05…20.0`;
  E2E gates 60 FPS @ 10 000 strokes, Flutter heap < 180 MB
- `overview.md` §4.3 node JSON (R-Tree payloads), §6 Wave 1.B (subagent 5 owns Docs 22+23)

## 4. Interface Freeze
Verbatim from template §5 (consumers: Docs 24, 26 — reproduce exactly):

```dart
class TileKey { final int tx, ty; }                               // Doc 22
class TileCache {                                                 // Doc 22
  ui.Picture? get(TileKey k); void put(TileKey k, ui.Picture p);
  void invalidate(TileKey k); void invalidateAll(); int approxBytes();
}
class SpatialRTree {                                              // Doc 22 (in-file R-Tree)
  void insert(CanvasNodeModel n); void remove(String nodeId);
  List<CanvasNodeModel> query(Rect worldRect);
}
class TiledCanvasEngine {                                         // Doc 22
  TiledCanvasEngine({required CameraController camera});
  void addCommitted(ProcessedStroke s);                           // index + dirty-tile rebake
  void setDocument(CanvasDocumentModel doc);
  List<CanvasNodeModel> queryVisible(Rect worldRect);
}
```

**Doc-specific API (on top of the freeze):**

* **Tile math:** `TileKey.forPoint(x, y) => TileKey((x/1024).floor(), (y/1024).floor())`
  (Dart `floor()` handles negatives: `x=-500 ⇒ tx=-1`); `TileKey.worldRect =>
  Rect(tx*1024.0, ty*1024.0, (tx+1)*1024.0, (ty+1)*1024.0)`; value equality + `hashCode`.
* **Bucket rasterization:** bucket `b = 2^round(log2(scale))`; `ui.PictureRecorder` bake draws the
  tile's nodes scaled by `b` (≈1 device px per world unit at that zoom); painter replays each picture
  under the current canvas transform scaled by `scale/b`, so a zoom step within a bucket needs **no**
  re-bake; a scale change crossing a bucket boundary re-bakes the affected tiles only.
* **`approxBytes()` heuristic (formula):** per cached tile
  `bytes = (1024·1024·4)/4 / 4^L` — RGBA bytes `1024·1024·4` with the `4:1` picture-retention
  factor ⇒ `1 MB` base, divided by `4^L` where `L = max(0, −round(log2(b)))` decimation levels
  (each power-of-two coarser bucket halves resolution per axis). Cache cap ≈ `120 MB`
  (`<= ~120 MB` of the `< 180 MB` heap gate); on `put` overflow, evict LRU entries until
  `approxBytes() <= 96 MB` (80 % hysteresis).
* **LRU:** `Map<TileKey, _Entry>` + doubly-linked recency list; `get` promotes to MRU; eviction
  order = oldest first. `invalidate(k)` drops one tile (commit path); `invalidateAll()` drops all
  (document switch / bucket storm).
* **Hot window:** `void bakeVisible(Rect worldViewport)` eagerly bakes the 5×5 tile window centered
  on the viewport tile (misses fall back to synchronous single-tile bake in `get`-path).
* **R-Tree (in-file, classic):** node capacity `8`, sorted mid-split bulk load (`setDocument`
  sorts by bbox center x, recursively splits at midpoint of the longer axis, each half ≈ n/2),
  bbox search with `Rect.overlaps`, `remove(nodeId)` via id lookup table.
* **`TiledCanvasEngine` extras:** `void markDirtyFor(ProcessedStroke s)` computes intersecting tiles
  (`worldRect(s.bbox)` ∩ tile rects); rebakes exactly that dirty set; `void onScaleBucketChanged()`
  re-bakes the hot window at the new bucket; `@visibleForTesting int get rebakeCount` (per-operation
  counter, reset at op start — the ≤4-tiles/commit assertion hook).
* **Rendering (dual-layer widget):** `class TiledCanvasView extends StatefulWidget` builds
  `Stack[ RepaintBoundary(StaticTilePainter(engine, cache)), RepaintBoundary(ForegroundStrokePainter) ]`;
  static painter draws `engine.queryVisible(worldRectOfViewport)` tiles via `cache.get` + picture
  replay under the current transform; foreground painter draws **only** live/in-flight strokes
  (Doc 21 `livePoints` + Doc 24 previews) — never triggers tile rebakes.

## 5. Implementation Plan
1. **`TileKey`:** immutable value type with `forPoint`, `worldRect`, `==`/`hashCode` (§4).
2. **`TileCache`:** map + LRU list, `approxBytes()` per the §4 formula, `put` with cap/hysteresis
   eviction, `invalidate`/`invalidateAll`, `ui.Picture` disposal on eviction (`picture.dispose()`).
3. **`SpatialRTree`:** leaf/internal nodes (cap 8, bbox `Rect`), bulk-load builder (sorted
   mid-split), `insert`/`remove`/`query(Rect)` with overlap pruning + id table.
4. **`TiledCanvasEngine` fields:** `camera`, `TileCache`, `SpatialRTree`, dirty-set
   `Set<TileKey>`, `Map<TileKey, int> bakedBucket`, `rebakeCount`.
5. **`setDocument(doc)`:** clear cache + tree; bulk-load every `doc.elements` node; full bake pass
   over all tiles containing nodes plus the 5×5 hot window; reset counters.
6. **Bake core:** `ui.Picture _bakeTile(TileKey k, int bucket)` — replay `tree.query(k.worldRect)`
   clipped to the tile, scaled by `bucket`; store picture + bucket.
7. **`addCommitted(s)`:** `tree.insert`-style index from `s` (convert to `CanvasNodeModel` via
   Doc 05 models + `toRpcPayload`); compute dirty tile set from `s.bbox` (≤ 4 for normal strokes);
   `_bakeTile` each dirty tile at the current bucket; increment `rebakeCount` per tile — **no**
   full-canvas redraw anywhere (event-driven anti-quadratic core).
8. **`queryVisible(worldRect)`:** `tree.query` + filter bbox to viewport (static layer culling).
9. **`TiledCanvasView` painters:** static painter draws visible tiles (picture + `scale(scale/b)`
   correction under `camera.viewMatrix`); foreground painter repaints on each `livePoints` tick via
   its own `RepaintBoundary`; both `shouldRepaint` compare engine/tile generations only.
10. **Tests** (`test/tiled_canvas_painter_test.dart`) — see §6; heavy paths tested headlessly.

## 6. Testing & Acceptance Criteria
- **Tile key math:** `(0,0)→(0,0)`; `(1023.9,1023.9)→(0,0)`; `(1024,1024)→(1,1)`; negatives
  `(-1,-1)→(-1,-1)`, `(-1024,-1024)→(-1,-1)`, `(-1025,0)→(-2,0)`; `worldRect` adjacency exact.
- **LRU + cap:** fill cache until `approxBytes() > cap` ⇒ oldest keys evicted first, MRU retained,
  final `approxBytes() <= 96 MB`; `get` promotes recency; `invalidateAll` ⇒ `approxBytes() == 0`.
- **R-Tree vs brute force:** 500 random nodes (seeded), 50 random query rects ⇒
  `tree.query(r)` id-set == linear-scan filter result (order-insensitive).
- **Dirty-set bound:** one `addCommitted` of a bbox crossing ≤ 2 tile boundaries ⇒
  `rebakeCount <= 4`; a commit never invalidates tiles outside its bbox range; `setDocument` then
  one commit rebakes ≤ 4 tiles (not the full document).
- **Acceptance:** `flutter test` green; `flutter analyze` clean; static/foreground split present in
  `TiledCanvasView` (two `RepaintBoundary` children).

## 7. Parallel Execution Notes
**Wave 1.B — Subagent 5 (Flutter Tiled Cache & Artboards)**: Doc 22 executes alongside Doc 23 in the
same subagent (overview §6 pairing) with disjoint files; parallel with Docs 06/07/09/10/11/12/20/21/25 —
zero shared Creates paths. Blocked by the Wave 1.A barrier and contract-wise by the frozen Doc 20/21
interfaces (available immediately — they are Phase 0 freezes). Consumed read-only by Doc 24 (paint
preview), Doc 26 (open document → `setDocument`), Doc 23 (reads `boundaryRect()` for page edges).
**Never touches:** only `tiled_canvas_painter.dart` + its test are written; Docs 05/20/21/23/24–27
files and `pc_agent/**` remain untouched.
