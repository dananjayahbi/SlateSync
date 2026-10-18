# Doc 26: Home Canvas Dashboard + SQLite

## 1. Objective & Scope
Build the Home screen: a searchable `sqflite`-backed gallery of canvas thumbnails, the New Canvas creation modal (A5/A4/Letter/Infinite presets + background templates), open/rename/delete actions, the `.slatesync` tablet save/load cache via the `archive` package, and the non-destructive Canvas Upgrade dialog wrapping Doc 23 `ArtboardManager.tryUpgrade`. The dashboard prepares and hands `CanvasDocumentModel`s to the canvas route — network wiring lands in Wave 3.A.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/features/home/home_canvas_dashboard.dart`
- `mobile_app/lib/core/storage/local_db.dart`
- `mobile_app/test/home_dashboard_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- Doc 05 `mobile_app/lib/core/models/canvas_models.dart` — `CanvasDocumentModel`, `Artboard`, `Presets`, `NodeStyleModel`, uuid note (Doc 25 `uuidV4()` helper may be imported read-only)
- Doc 05 `mobile_app/lib/core/theme/studio_theme.dart` — colors/typography
- Doc 05 pubspec — `sqflite`, `path_provider`, `archive`
- Doc 03 `shared_specs/canvas_document_schema.json` — document JSON keys, presets, upgrade rule §4.4
- Doc 23 `mobile_app/lib/canvas_engine/artboard_manager.dart` — `UpgradeResult`, `ArtboardManager.tryUpgrade`
- Doc 25 `mobile_app/lib/network/vector_sync_client.dart` — `uuidV4()` helper (Wave 1.B prerequisite)

### Never touches (paths owned by concurrent docs — write-conflict guard)
`mobile_app/lib/features/tools/**` (Doc 24), `mobile_app/lib/features/export/**` (Doc 27), `mobile_app/lib/network/**` (Doc 25), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/core/models/**` + `lib/core/theme/**` + `lib/main.dart` (Doc 05), `pc_agent/**`, `shared_specs/**`

> Path note: this doc owns `features/home/home_canvas_dashboard.dart` exactly as mandated by the template §6 ownership matrix (and matching the `26_flutter_home_canvas_dashboard.md` catalog title in overview §5).

## 3. Contract References
- Template §3: artboard presets (300 DPI world units, top-left origin) A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`, INFINITE unbounded; backgrounds `BLANK, RULED, DOT_GRID, ISO_GRID`; autosave every `10 s` when dirty; `.slatesync` container = ZIP: `document.json` (Doc 03 schema) + `assets/*`
- Doc 03 §4.4 upgrade rule: allow iff `target==INFINITE` OR (`min_x>=0 AND min_y>=0 AND max_x<=target.w AND max_y<=target.h`)
- Doc 03 example element/style keys per `overview.md` §4.3 for the initial empty document
- Doc 23 freeze: `UpgradeResult { final bool allowed; final String? reasonKey; }` — reason keys `"clips_content"`, `"invalid_target"`

## 4. Interface Freeze
**Consumed — Doc 05 (verbatim, template §5):**
```dart
class Presets { static const a5=(w:1748.0,h:2480.0), a4=(2480.0,3508.0),
                      letter=(2550.0,3300.0); }               // INFINITE = null dims
class CanvasDocumentModel { String canvasId, title; int createdAt, updatedAt;
                            Artboard artboard; Map<String,double> contentBounds;
                            List<CanvasNodeModel> elements; }
class Artboard { String preset; double? width; double? height; bool isInfinite;
                 String backgroundStyle; String backgroundColor; }
// all models: Map<String,dynamic> toJson() / fromJson() per overview §4.3 keys
```
**Consumed — Doc 25 (signatures only):** `String uuidV4();` — the `Random.secure()` v4 helper exported by Doc 25 (Wave 1.B); used for `canvasId` in the New Canvas flow. Do not re-declare it here.
**Consumed — Doc 23 (verbatim, template §5):**
```dart
class UpgradeResult { final bool allowed; final String? reasonKey; }  // Doc 23
class ArtboardManager {                                           // Doc 23
  Artboard get current; Rect get contentBounds; bool get isInfinite;
  void noteContent(Rect r);                                       // content_bounds union tracking
  UpgradeResult tryUpgrade(String targetPreset);                  // §4.4 rule
  Rect? boundaryRect();                                           // null ⇒ infinite canvas
}
```
**Doc-specific API (added):**
```dart
// mobile_app/lib/core/storage/local_db.dart
class CanvasRecord {
  final String id, title, preset, background, thumbPath, filePath; final int updatedAt;
}
class LocalDb {
  static Future<LocalDb> open({String? pathOverride});   // pathOverride used by ffi tests
  Future<void> insertCanvas(CanvasRecord r);
  Future<List<CanvasRecord>> list({String? query});      // title LIKE %query%, ORDER BY updated_at DESC
  Future<CanvasRecord?> get(String id);
  Future<void> update(CanvasRecord r);
  Future<void> delete(String id);
  Future<void> close();
}
Future<String> saveDocument(CanvasDocumentModel doc);    // ZIP document.json+assets →
                                                         // path_provider app-documents/SlateSync/<canvasId>.slatesync
Future<CanvasDocumentModel> loadDocument(String id);     // unzip + CanvasDocumentModel.fromJson

// mobile_app/lib/features/home/home_canvas_dashboard.dart
class HomeCanvasDashboard extends StatefulWidget {
  const HomeCanvasDashboard({super.key, required this.onOpenDocument});
  final void Function(CanvasDocumentModel doc) onOpenDocument;   // canvas route hand-off (3.A)
}
class NewCanvasModal extends StatefulWidget { /* preset + background pickers */ }
class UpgradeDialog extends StatefulWidget {
  const UpgradeDialog({super.key, required this.manager, required this.onSaved});
  final ArtboardManager manager;                          // injected — faked in tests
  final void Function(Artboard newArtboard) onSaved;      // re-save document on allowed
}
```

## 5. Implementation Plan
1. **`LocalDb` schema** — `onCreate`: `CREATE TABLE canvases(id TEXT PRIMARY KEY, title TEXT, preset TEXT, background TEXT, thumb_path TEXT, file_path TEXT, updated_at INTEGER)`; `insertCanvas` = `insert(..., conflictAlgorithm: replace)`.
2. **CRUD + search** — `list({String? query})`: `WHERE title LIKE ?` (`%q%`) when query non-empty, always `ORDER BY updated_at DESC`; `get/update/delete` by `id`; `open()` uses `getDatabasesPath()` (tests inject `pathOverride` with `sqflite_common_ffi`).
3. **`.slatesync` cache** — `saveDocument`: `doc.toJson()` → `jsonEncode` → `ZipEncoder` writing `document.json` (+ `assets/*` if `assetRef`s present) to `getApplicationDocumentsDirectory()/SlateSync/<canvasId>.slatesync`; `loadDocument(id)` unzips and returns `CanvasDocumentModel.fromJson`. *(Doc 05 `archive` dependency — consume, never redefine.)*
4. **Gallery grid** — `HomeCanvasDashboard`: `TextField` search (debounced, calls `LocalDb.list(query)`), `GridView` of thumbnail cards (thumb image or preset-colored placeholder, title, preset chip `A5/A4/Letter/Infinite`, relative updated time like "2 h ago"); empty state: icon + "No canvases yet — tap + to start".
   Card layout contract (tested): title (ellipsis), preset chip, relative time — three visual children in one `Card`; thumbnail rendered from `thumb_path` if the file exists, else a gradient placeholder tinted by preset.
5. **New Canvas modal** — `showDialog` → `NewCanvasModal`: preset cards A5/A4/Letter/Infinite (sizes from `Presets`; Infinite ⇒ `isInfinite: true`, null dims) + four mini `CustomPainter` background previews (`BLANK/RULED/DOT_GRID/ISO_GRID`); title field (default "Untitled"); Create ⇒ build `CanvasDocumentModel` (Doc 05 defaults: `contentBounds` zeros, `elements: []`, `background_color: #FFFFFF`, uuid via Doc 25 `uuidV4()`) → `saveDocument` + `insertCanvas` row → refresh grid.
   New document seed (initial `toJson()` fragment per Doc 03):
   ```json
   { "artboard": { "preset": "A4", "width": 2480.0, "height": 3508.0, "is_infinite": false,
                   "background_style": "DOT_GRID", "background_color": "#FFFFFF" },
     "content_bounds": { "min_x": 0, "min_y": 0, "max_x": 0, "max_y": 0 }, "elements": [] }
   ```
6. **Open / rename / delete** — card tap ⇒ `loadDocument(id)` → `onOpenDocument(doc)` (canvas route wired Wave 3.A); long-press context menu: Rename (dialog → `LocalDb.update`), Delete (confirm → `LocalDb.delete` + delete `.slatesync` file + thumb).
7. **Upgrade dialog** — preset chips call injected `manager.tryUpgrade(target)`; `allowed == false` ⇒ warning overlay/banner showing `reasonKey` (`"clips_content"` → “New size would crop existing content”, `"invalid_target"` → “Invalid target size”); `allowed == true` ⇒ apply returned `Artboard` to the model, `saveDocument` again, `onSaved(newArtboard)`, pop.
8. **Relative-time & chips** — preset chip labels `A5 / A4 / Letter / Infinite`; updated time rendered as `just now` (<60 s), `N min ago`, `N h ago`, `N d ago`, else `yyyy-MM-dd`; derived purely from `updated_at` (unix seconds) — unit-testable helper `String relativeTime(int now, int updatedAt)`.
9. **Tests** — see §6.

## 6. Testing & Acceptance Criteria
- **LocalDb CRUD + ordering** (`sqflite_common_ffi` — **note: dev dependency to be added to Doc 05's `pubspec.yaml` by the Wave 1.A/3.A owner; this doc never edits `pubspec.yaml`**): insert 3 rows with staggered `updated_at`, search filters by title, list returns `updated_at DESC`; `get/update/delete` behave.
- **Search case-insensitivity**: query `"lecture"` matches title `"Control Systems LECTURE 04"` (SQLite `LIKE` default); empty query returns all rows.
- **Roundtrip**: build a `CanvasDocumentModel` (1 element) → `saveDocument` → `loadDocument` ⇒ deep-equals on `toJson()` keys incl. `artboard`, `content_bounds`, `elements`.
- **ZIP container**: produced file is a real ZIP containing `document.json` at root (template §3 `.slatesync` contract), readable by `ZipDecoder`.
- **Upgrade allowed**: fake `ArtboardManager.tryUpgrade('A4')` ⇒ `UpgradeResult(true, null)`; dialog calls `onSaved`, document re-saved with new `Artboard`.
- **Upgrade blocked**: fake ⇒ `UpgradeResult(false, 'clips_content')` ⇒ banner text visible, `onSaved` **not** called, dialog stays open.
- **Reason-key mapping**: both `"clips_content"` and `"invalid_target"` render distinct, human-readable messages.
- **New Canvas flow**: create modal with preset `A4` + `DOT_GRID` ⇒ `LocalDb` row has `preset='A4'`, `background='DOT_GRID'`, and the `.slatesync` file exists on disk.
- **Preset dimensions**: A5 ⇒ `1748×2480`, A4 ⇒ `2480×3508`, Letter ⇒ `2550×3300`, Infinite ⇒ `width/height null, isInfinite true` (template §3 table).
- **Empty state**: zero rows ⇒ empty-state widget present; after one insert, grid card appears.
- **relativeTime helper**: pure-function tests for `<60 s`, minutes, hours, days boundaries.
- `flutter analyze` clean; tests run without a device (`sqflite_common_ffi`, `path_provider` mocked/temp dir under the test bundle — never `/tmp`).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2, Subagent 7 per `overview.md` §6; template matrix row 26 → 2.A). Reads Doc 23 (1.B) and Doc 25 (1.B) — both frozen at the barrier; Doc 23 `ArtboardManager` is **injected**, so no compile-order coupling.
- Zero overlap with the other 7 Wave 2.A docs: creates `features/home/**` + `core/storage/**` exclusively (Doc 24 owns `features/tools/`, Doc 27 owns `features/export/`, Docs 08/13–17 own `pc_agent/`).
- **Never touches:** `mobile_app/lib/features/tools/**`, `mobile_app/lib/features/export/**`, `mobile_app/lib/network/**`, `mobile_app/lib/canvas_engine/**`, `mobile_app/lib/core/models/**`, `mobile_app/lib/core/theme/**`, `mobile_app/pubspec.yaml`, `mobile_app/lib/main.dart`, `pc_agent/**`, `shared_specs/**`.
