# Doc 23: Artboard Bounds Upgrader

## 1. Objective & Scope
Unify infinite and bounded canvases on the tablet: `ArtboardManager` renders A5/A4/Letter boundaries
(`null` ⇒ infinite), tracks `content_bounds` by incremental union, and enforces the overview §4.4
non-destructive upgrade rule via `tryUpgrade` returning a frozen `UpgradeResult{allowed, reasonKey}`.
Never silently downsizes — Doc 26 renders the warning overlay from `reasonKey`; Doc 22 painters read
`boundaryRect()` for page edges. Lives in `mobile_app/lib/canvas_engine/artboard_manager.dart`.
Documentation only.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/canvas_engine/artboard_manager.dart`
- `mobile_app/test/artboard_manager_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- `mobile_app/lib/core/models/canvas_models.dart` — `Artboard`, `Presets` (Doc 05)
- `docs/_micro_doc_template.md` §5 `ArtboardManager`/`UpgradeResult` freeze + §3 Artboard presets
  and Upgrade rule (§4.4 line) verbatim
- `docs/overview.md` §4.3 `content_bounds`, §4.4 size matrix & validation rule, §6 Wave 1.B subagent 5

### Never touches (paths owned by concurrent docs — write-conflict guard)
- Doc 05 files (scaffold, `lib/core/**`, Doc 05 tests); Doc 20 `camera_controller.dart` (+ test);
  Doc 21 `stroke_processor.dart` (+ test); Doc 22 `tiled_canvas_painter.dart` (+ test);
  Docs 24–27 paths, `lib/network/**` (Doc 25), `pc_agent/**`, `qa/**` (Doc 28)

## 3. Contract References
- Template §3 Master Constants: presets A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`,
  INFINITE unbounded, top-left origin `(0,0)→(w,h)`; Upgrade rule (§4.4) — allow iff
  `target==INFINITE` OR (`min_x>=0 AND min_y>=0 AND max_x<=target.w AND max_y<=target.h`)
- `overview.md` §4.4 size matrix + validation rule, §6 Wave 1.B (subagent 5 owns Docs 22+23)

## 4. Interface Freeze
Verbatim from template §5 (consumers: Docs 22, 24, 26 — reproduce exactly):

```dart
class UpgradeResult { final bool allowed; final String? reasonKey; }  // Doc 23
class ArtboardManager {                                           // Doc 23
  Artboard get current; Rect get contentBounds; bool get isInfinite;
  void noteContent(Rect r);                                       // content_bounds union tracking
  UpgradeResult tryUpgrade(String targetPreset);                  // §4.4 rule
  Rect? boundaryRect();                                           // null ⇒ infinite canvas
}
```

**Doc-specific API (on top of the freeze):**

* **Construction:** `ArtboardManager({required String preset})` — bounded presets seed dims from
  Doc 05 `Presets` records (`is_infinite: false`); `"INFINITE"` seeds `width: null, height: null,
  isInfinite: true`. Presets map: `A5 → (1748,2480)`, `A4 → (2480,3508)`, `LETTER → (2550,3300)`.
* **`boundaryRect()`:** `Rect.fromLTWH(0, 0, current.width!, current.height!)` for A5/A4/LETTER
  (top-left origin per template §3); `null` for INFINITE. Doc 22's static painter draws page edges +
  drop shadow from this getter.
* **`noteContent(Rect r)`:** incremental union into the tracked content rect (first call adopts `r`);
  empty-document state ⇒ tracked rect is `Rect.zero`/"empty" (`contentBounds` getter returns
  `Rect.zero` when nothing noted). **Reset on clear-all** via doc-specific `void resetContent()`
  (called by Doc 24/26 erase-all paths).
* **`tryUpgrade(targetPreset)` implements §4.4 exactly:**
  1. `targetPreset ∉ {A5, A4, LETTER, INFINITE}` ⇒ `UpgradeResult(false, "invalid_target")`
  2. empty document (nothing noted / `resetContent` after clear) ⇒ `UpgradeResult(true, null)`
     — allowed for **any** target
  3. `targetPreset == "INFINITE"` ⇒ `UpgradeResult(true, null)` — always allowed
  4. else allow iff `min_x >= 0 && min_y >= 0 && max_x <= w && max_y <= h` with `(w, h)` = target
     dims ⇒ `UpgradeResult(true, null)`; violation ⇒ `UpgradeResult(false, "clips_content")`
  5. on success: replace `current` with a fresh `Artboard` (dims from `Presets`,
     `backgroundStyle`/`backgroundColor` preserved) — callers read it back via `current`;
     **never** shrinks, crops, or rewrites `content_bounds` to force a pass.
* **Frozen reason keys:** `class ReasonKeys { static const clipsContent = "clips_content";
  static const invalidTarget = "invalid_target"; }` — `reasonKey` is `null` on success; Doc 26 maps
  them to overlay copy; no other key strings exist (compile-time enum of two + null).
* Preset dimension table (dims consulted on every successful upgrade, template §3):

| `targetPreset` | Resulting `current.width/height` | `isInfinite` | `boundaryRect()` |
|---|---|---|---|
| `A5` | `1748.0 / 2480.0` | `false` | `Rect(0,0,1748,2480)` |
| `A4` | `2480.0 / 3508.0` | `false` | `Rect(0,0,2480,3508)` |
| `LETTER` | `2550.0 / 3300.0` | `false` | `Rect(0,0,2550,3300)` |
| `INFINITE` | `null / null` | `true` | `null` |

* **Non-destructive guarantee:** `_content` is never narrowed by `tryUpgrade` — the only writes to
  the tracked rect are `noteContent` (expand) and `resetContent` (clear); downgrade pressure is
  surfaced as `reasonKey` for Doc 26's overlay, never resolved inside this module.

## 5. Implementation Plan
1. **State:** `Artboard _current`, `Rect? _content` (null ⇒ empty), constants for the preset map.
2. **`current`/`isInfinite`:** direct reads of `_current` (`is_infinite` flag from Doc 05 model).
3. **`boundaryRect()`:** per §4 — `null` exactly when `_current.isInfinite`.
4. **`noteContent(r)`:** `_content = _content == null ? r : _content!.expandToInclude(r)`
   (skip non-finite rects); no camera/doc coupling — painters and Doc 24 call it on every commit.
5. **`resetContent()`:** `_content = null` (clear-all ⇒ next `tryUpgrade` counts as empty doc).
6. **`contentBounds` getter:** `Rect.zero` when `_content == null`, else `_content!`.
7. **`tryUpgrade` order:** §4 steps 1→4 exactly in that precedence (`invalid_target` before emptiness
   is irrelevant — validate target first so unknown strings never consult content).
8. **Success path:** build replacement `Artboard(preset: target, width/height: dims or null for
   INFINITE, isInfinite: target=="INFINITE", background fields preserved)`; assign `_current`;
   return `UpgradeResult(true, null)`.
9. **Failure path:** mutate nothing (`_current`, `_content` untouched); return typed reason key.
10. **Tests** (`test/artboard_manager_test.dart`) — parametrized matrix, see §6.

## 6. Testing & Acceptance Criteria
Parametrized matrix (each row = independent test case, content rect noted before the call):

| # | Start | Content | Target | Expected |
|---|---|---|---|---|
| 1 | A5 | fits A5 | `A4` | ✓ allowed, `reasonKey null`, `current` = A4 (2480×3508) |
| 2 | A4 | `Rect(0,0,3000,2400)` | `A5` | ✗ `"clips_content"` |
| 3 | A5 | fits A5 | `INFINITE` | ✓ allowed, dims `null`, `isInfinite true` |
| 4 | INFINITE | `Rect(0,0,9000,9000)` | `A4` | ✗ `"clips_content"` |
| 5 | INFINITE | `Rect(10,10,2000,3000)` | `A4` | ✓ allowed |
| 6 | any (empty) | none noted | any target incl. `A4` | ✓ allowed, `reasonKey null` |
| 7 | LETTER | near Letter edge | `A4` | ✗ `"clips_content"` (2550 > 2480) |
| 8 | A4 | `max_x == 2480` / `max_y == 3508` exactly | `A4` re-upgrade / edge | ✓ allowed (`>=`/`<=` semantics; equality passes) |

- Unknown target ⇒ `"invalid_target"`; success swaps `current` dims from `Presets`; failures leave
  state untouched; `boundaryRect()` `null` ⇔ INFINITE; `resetContent()` restores "empty ⇒ any ✓".
- **Union semantics:** successive `noteContent` calls expand monotonically (`expandToInclude`);
  after `resetContent()` the same out-of-bounds content re-noted still blocks the downgrade;
  `current`'s `backgroundStyle`/`backgroundColor` survive every successful upgrade unchanged.
- **Acceptance:** all rows green via `flutter test`; `flutter analyze` clean; grep confirms no
  cropping logic (no path rewrites `content_bounds` downward).

## 7. Parallel Execution Notes
**Wave 1.B — Subagent 5 (Flutter Tiled Cache & Artboards)**: Doc 23 executes alongside Doc 22 in the
same subagent (overview §6 pairing) with disjoint files; parallel with Docs 06/07/09/10/11/12/20/21/25 —
zero shared Creates paths. Blocked by the Wave 1.A barrier (needs Doc 05 `Artboard`/`Presets`).
Consumed read-only by Doc 22 (`boundaryRect()` page edges), Doc 24 (commit → `noteContent`),
Doc 26 (New Canvas + Upgrade dialog → `tryUpgrade` + warning overlay on `reasonKey`).
**Never touches:** only `artboard_manager.dart` + its test are written; Docs 05/20/21/22/24–27 files
and `pc_agent/**` remain untouched — Doc 22 calls across (read-only), never edits this module.
