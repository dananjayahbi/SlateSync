# Doc 05: Flutter App Boilerplate, Theme & Shared Models

## 1. Objective & Scope
Scaffold `mobile_app/` with `flutter create` (org `com.slatesync`, project `mobile_app`), lock the exact
dependency set, the dark Studio theme constants, and the Dart mirror of the Doc 02/03 wire + document
models (`FrameType`, `ToolId`, `WireCodec`, `Presets`, `Artboard`, `CanvasDocumentModel`, …).
This module is the import floor for every Flutter doc: Docs 20–27 consume these frozen types and never
redefine them. Wave 1.A artifact; generated documentation only — no code exists until Session 1 runs.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/` scaffold via `flutter create --org com.slatesync --project-name mobile_app mobile_app`:
  `pubspec.yaml`, `analysis_options.yaml`, `lib/main.dart` (stub)
- `mobile_app/lib/core/theme/studio_theme.dart`
- `mobile_app/lib/core/models/canvas_models.dart`
- `mobile_app/test/canvas_models_test.dart`
- `mobile_app/test/wire_codec_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- `docs/_micro_doc_template.md` §3 Master Constants + §5 Dart freeze (Main Orchestrator) — source of truth
- `shared_specs/binary_stream_frame.json` (Doc 02) — 16-byte `<BBHfff` layout mirrored by `WireCodec`
- `shared_specs/canvas_document_schema.json` (Doc 03) — §4.3 JSON keys mirrored by `toJson()/fromJson()`
- `docs/overview.md` §3 tree, §4.1–§4.4 schemas (contract source)

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `shared_specs/**` (Docs 02, 03), `pc_agent/**` (Docs 04, 06–19), `qa/**` (Doc 28)
- `mobile_app/lib/main.dart` beyond creating the stub — final wiring is a Wave 3.A sequential
  cross-wave edit by subagent 3 (allowed; no same-wave writer exists)
- `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/network/**` (Doc 25),
  `mobile_app/lib/features/**` + `mobile_app/lib/core/storage/**` (Docs 24, 26, 27)
- any `mobile_app/test/*_test.dart` other than the two listed under Creates

## 3. Contract References
- `overview.md` §3 blueprint (`mobile_app/lib/core/theme`, `lib/core/models`), §4.1 frame layout,
  §4.2 RPC envelope, §4.3 document/artboard schema, §4.4 presets, §6 Wave 1.A subagent 5
- Template §1 required section structure; §3 Master Constants (binary frame, FrameType, ToolId,
  Artboard presets, Backgrounds, Blend modes); §5 "Wave 1.A artifacts (Doc 05)" freeze; §6 matrix row 05

## 4. Interface Freeze
Verbatim from template §5 (consumed by Docs 20–27 — reproduce exactly, never renegotiate):

```dart
// lib/core/models/canvas_models.dart (Doc 05) — wire JSON keys are snake_case
class FrameType { static const livePoint=0x01, liveEnd=0x02, camera=0x03, laser=0x04; }
class ToolId    { static const pen=0x01, highlighter=0x02, eraser=0x03, shapePreview=0x04; }
class LiveFrame { final int frameType, toolId, seq; final double f1, f2, f3; }
class WireCodec {
  static ByteData buildFrame({required int frameType, required int toolId,
      required int seq, required double f1, double f2=0, double f3=0}); // 16B LE <BBHfff
  static LiveFrame decodeFrame(Uint8List bytes);
}
class Presets { static const a5=(w:1748.0,h:2480.0), a4=(2480.0,3508.0),
                      letter=(2550.0,3300.0); }               // INFINITE = null dims
class NodeStyleModel { String color; double strokeWidth; double opacity; String blendMode; }
class NodeGeometryModel { List<List<double>> pts; String? shapeType;
                          Map<String,dynamic>? graphConfig; String? assetRef; }
class CanvasNodeModel { String nodeId; String kind; int layer; List<double> bbox;
                        NodeStyleModel style; NodeGeometryModel geometry; }
class CanvasDocumentModel { String canvasId, title; int createdAt, updatedAt;
                            Artboard artboard; Map<String,double> contentBounds;
                            List<CanvasNodeModel> elements; }
class Artboard { String preset; double? width; double? height; bool isInfinite;
                 String backgroundStyle; String backgroundColor; }
// all models: Map<String,dynamic> toJson() / fromJson() per overview §4.3 keys

// lib/core/theme/studio_theme.dart (Doc 05): StudioTheme — dark palette consts, radii, typography
// pubspec.yaml deps (Doc 05): flutter_riverpod, web_socket_channel, multicast_dns,
//   mobile_scanner, sqflite, path_provider, image_picker, pdf, archive, flutter_lints
```

**Doc-specific API (on top of the freeze):**

* `StudioTheme` — pure consts, no widgets: `bg #121212`, `surface #1E1E1E`, `strokeCanvas #0E0E0E`,
  `accent #4F8EF7`, `danger #F0546F`, `text #EAEAEA`; radii `small 12`, `large 18`; a small
  typography scale (`title 18`, `body 14`, `caption 12` — `double` consts only).
* `WireCodec` byte layout (overview §4.1): `buildFrame` returns `ByteData` with
  `lengthInBytes == 16`; `decodeFrame` throws `ArgumentError` unless `bytes.length == 16`.

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 1 | `frameType` | uint8 (`FrameType.*`) |
| 1 | 1 | `toolId` | uint8 (`ToolId.*`) |
| 2–3 | 2 | `seq` | uint16 little-endian |
| 4–7 | 4 | `f1` | float32 LE |
| 8–11 | 4 | `f2` | float32 LE |
| 12–15 | 4 | `f3` | float32 LE |

* INFINITE preset semantics: `preset == "INFINITE"` ⇒ `width == null`, `height == null`,
  `isInfinite == true`; bounded presets carry dims from `Presets` records and `isInfinite == false`.
* snake_case ↔ camelCase mapping for every overview §4.3 key (`toJson()` emits the left column):

| §4.3 JSON key | Dart field |
|---|---|
| `canvas_id` / `title` / `created_at` / `updated_at` | `CanvasDocumentModel.canvasId/title/createdAt/updatedAt` |
| `artboard.preset` / `.width` / `.height` | `Artboard.preset/width/height` (nullable ⇒ INFINITE) |
| `artboard.is_infinite` / `.background_style` / `.background_color` | `Artboard.isInfinite/backgroundStyle/backgroundColor` |
| `content_bounds` (+ inner `min_x,min_y,max_x,max_y`) | `contentBounds` — **inner keys stay snake_case verbatim** |
| `elements` / `elements[].node_id` / `.kind` / `.layer` / `.bbox` | `elements/nodeId/kind/layer/bbox` (bbox = `List<double>` array unchanged) |
| `style.color` / `.stroke_width` / `.opacity` / `.blend_mode` | `NodeStyleModel.color/strokeWidth/opacity/blendMode` |
| `geometry.pts` / `.shape_type` | `NodeGeometryModel.pts/shapeType` (pts array-of-arrays unchanged) |
| `geometry.graph_config` (inner `origin,x_range,y_range,grid_step,show_labels`) | `graphConfig` — **inner keys stay snake_case verbatim** |
| `geometry.asset_ref` | `NodeGeometryModel.assetRef` |

## 5. Implementation Plan
1. **Scaffold:** run `flutter create --org com.slatesync --project-name mobile_app mobile_app`;
   delete nothing — keep generated `android/`, keep default `test/widget_test.dart` replaced by Doc 05 tests.
2. **`pubspec.yaml`:** dependencies EXACTLY `flutter_riverpod, web_socket_channel, multicast_dns,
   mobile_scanner, sqflite, path_provider, image_picker, pdf, archive`; `flutter_lints` in
   `dev_dependencies`; no other packages (`archive` = sanctioned `.slatesync` ZIP IO for Docs 05 & 26).
3. **`analysis_options.yaml`:** `include: package:flutter_lints/flutter.yaml` only.
4. **`lib/main.dart` stub:** `runApp` → `MaterialApp(debugShowCheckedModeBanner: false, home:
   Scaffold(backgroundColor: StudioTheme.bg, body: Center(Text("SlateSync Studio"))))`
   (replaced by Wave 3.A subagent 3 — sequential cross-wave edit, allowed).
5. **`studio_theme.dart`:** `abstract final class StudioTheme` with the palette/radius/typography
   consts from §4 — pure `Color`/`double` consts, zero widget code.
6. **`canvas_models.dart` — wire half:** `FrameType`, `ToolId`, `LiveFrame`, `WireCodec`
   (`Endian.little`, `<BBHfff` via `ByteData.setUint8/setUint16/setFloat32` at the §4 offsets;
   `decodeFrame` reverses with `getFloat32(offset, Endian.little)`).
7. **`canvas_models.dart` — document half:** `Presets`, `Artboard`, `NodeStyleModel`,
   `NodeGeometryModel`, `CanvasNodeModel`, `CanvasDocumentModel`, each with
   `factory X.fromJson(Map<String,dynamic>)` + `Map<String,dynamic> toJson()` using the §4 key table;
   `graphConfig`/`contentBounds` inner keys copied verbatim (no renaming inside raw maps).
8. **`test/canvas_models_test.dart`:** roundtrip every model `toJson → fromJson` and deep-compare;
   fixture document includes an element carrying BOTH `graph_config` and `asset_ref`; asserts
   snake_case keys on the wire and camelCase fields in Dart; asserts INFINITE artboard roundtrips
   with `width/height == null`.
9. **`test/wire_codec_test.dart`:** pack→unpack identity for varied frames (seq `0` and `0xFFFF`,
   negative floats); golden-byte table for offsets 0..15 (e.g. `f1=1.0` ⇒ bytes `00 00 80 3F` at
   4..7); `size == 16`; `decodeFrame` rejects `Uint8List` of length ≠ 16.
10. **Gate:** `flutter analyze` clean under `flutter_lints`; both tests green via `flutter test`.

## 6. Testing & Acceptance Criteria
- `flutter test test/canvas_models_test.dart` — every model roundtrips; `graph_config` and
  `asset_ref` elements survive; JSON keys match overview §4.3 byte-for-byte in name.
- `flutter test test/wire_codec_test.dart` — identity roundtrip, offsets 0..15 golden bytes,
  `lengthInBytes == 16`, strict length validation.
- `flutter analyze` reports no errors/warnings with `analysis_options.yaml` (flutter_lints).
- `pubspec.yaml` dependency set equals the §4 list exactly (no extras, no omissions).
- Acceptance: Wave 1.B subagents import `canvas_models.dart`/`studio_theme.dart` with zero redefinitions.

## 7. Parallel Execution Notes
**Wave 1.A — Subagent 5 (Flutter Boilerplate)**, parallel with Docs 01–04. Barrier: Wave 1.B (Docs
20–23, 25) starts only after this doc's `pubspec.yaml` + `canvas_models.dart` exist (overview §6
Wave 1.A sync point). No same-wave file overlap: Docs 01–04 create only root/`shared_specs`/`pc_agent`
paths; Doc 05 alone creates `mobile_app/**`. **Never touches:** all paths in §2 remain exclusive to
their owners — Doc 05 writes only its Creates list, never `shared_specs/**`, `pc_agent/**`,
`lib/canvas_engine/**`, `lib/network/**`, `lib/features/**`, or sibling test files; the only later
write to a Doc 05 file is the allowed Wave 3.A `main.dart` stub finalization.

---
*Discrepancy note (reported, not fixed): overview §5 catalog item 5 lists Doc 05 deps without
`archive` and `flutter_lints`; template §5 (and this doc) mandate all ten.*
