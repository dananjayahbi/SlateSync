# Doc 27: Flutter High-Res Export Sheet

## 1. Objective & Scope
Build the Export bottom sheet: format (PNG/JPG/PDF), DPI (300/600/1200, hidden+disabled for PDF), target (PC/Tablet/Both with connection-aware disabling), job submission via Doc 25 `sendRpc`, live progress from `SyncEvent.Progress`, cancellation, and finished-file handling (`FileChunk`/`FileReceived` → tablet `Download/SlateSync/`, or PC-path snackbar). The sheet is **pure presentation + client calls** — it imports no PC modules and performs no socket code beyond calling the injected `VectorSyncClient` (Doc 25).

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `mobile_app/lib/features/export/export_modal_sheet.dart`
- `mobile_app/test/export_sheet_test.dart`

### Read-only dependencies (imports, each cited as "Doc NN")
- Doc 25 `mobile_app/lib/network/vector_sync_client.dart` — `VectorSyncClient.sendRpc`, `isConnected`, `Stream<SyncEvent>` (`Progress`, `FileChunk`, `FileReceived`, `RpcReceived`, `StateChanged`)
- Doc 02 `shared_specs/ws_rpc_schema.json` — `EXPORT_JOB` + `START_EXPORT`/`CANCEL_EXPORT`/`EXPORT_PROGRESS` envelope shapes; asset chunk fields for tablet file receipt
- Doc 05 `mobile_app/lib/core/theme/studio_theme.dart` — sheet styling
- Doc 05 pubspec — `path_provider` (Download/SlateSync destination)

### Never touches (paths owned by concurrent docs — write-conflict guard)
`mobile_app/lib/network/**` (Doc 25 — consumed, never edited), `mobile_app/lib/features/tools/**` (Doc 24), `mobile_app/lib/features/home/**` + `lib/core/storage/**` (Doc 26), `mobile_app/lib/canvas_engine/**` (Docs 20–23), `mobile_app/lib/core/**` + `lib/main.dart` (Doc 05), `pc_agent/**` (Docs 13/14/15 exporters live server-side)

> The sheet never imports `pc_agent/**` or any Python-side artifact; finished-export results arrive **only** through Doc 25 `SyncEvent` envelopes relayed by Doc 11 (`Doc 15` emits its PC-side `EXPORT_FINISHED` bus event, pushed to the tablet inside a `type: "EXPORT_JOB"` envelope; the sheet matches the terminal payload `{job_id, percent, path, ok}` — see discrepancy note in §7).

## 3. Contract References
- Template §3: DPI choices `300, 600, 1200` (PNG/JPG; **PDF is vector**); export strips `2048×2048` px (PC-side); `.slatesync` asset convention; RPC type `EXPORT_JOB`, actions `START_EXPORT`, `CANCEL_EXPORT`, `EXPORT_PROGRESS`
- Doc 02 §4.2: `START_EXPORT` payload keys **`{canvas_id, format, dpi, target}`** (exact); `CANCEL_EXPORT` payload **`{job_id}`**; `type: "EXPORT_JOB"`; `id` uuid-v4, `timestamp` unix seconds
- Doc 15 behaviors (read-only, Doc 11 relay): progress pushed as `EXPORT_PROGRESS {job_id, percent, stage}` ≤10 Hz; finish push carries `path`, `ok`; `ASSET_UPLOAD` chunks (`data_b64` ≤ `262144`) deliver tablet-target files
- Doc 25 receive events: `Progress{jobId, percent}`, `FileChunk{transferId, index, data}`, `FileReceived{path}`

## 4. Interface Freeze
**Consumed — Doc 25 (verbatim, template §5):**
```dart
class VectorSyncClient {                                          // Doc 25
  Future<void> discover();                                        // mDNS _slatesync._tcp.local. (3 s)
  Future<void> connect(PairingInfo info);                         // ws://ip:50606/ws?token=…
  bool get isConnected;
  void sendLiveFrame(int frameType, int toolId, double f1, double f2, double f3); // via WireCodec
  Future<void> sendRpc(Map<String, dynamic> envelope);            // §4.2 envelope, uuid-v4 id
  Stream<SyncEvent> get events;                                   // EXPORT_PROGRESS, file chunks…
  void flushOfflineQueue();                                       // ring buffer ≤5000 RPC; live frames dropped offline
}
```
**Consumed — Doc 25 event surface (signatures):** `enum SyncEventKind { stateChanged, rpcReceived, progress, fileChunk, fileReceived }`; `class SyncEvent { final SyncEventKind kind; final SyncState? state; final Map<String,dynamic>? msg; final String? jobId; final double? percent; final String? transferId; final int? index; final Uint8List? data; final String? path; }` (defined in Doc 25; do not redefine).
**Doc-specific API (added):**
```dart
enum ExportFormat { png, jpg, pdf }                 // wire strings "PNG" | "JPG" | "PDF"
enum ExportTarget { pc, tablet, both }               // wire strings "PC" | "TABLET" | "BOTH"

Future<void> showExportSheet(BuildContext context, {
  required VectorSyncClient client,                  // injected — faked in tests
  required String canvasId,
});

Map<String, dynamic> buildStartExport({              // asserted by tests — exact keys
  required String canvasId, required ExportFormat format,
  required int dpi, required ExportTarget target,
});   // ⇒ {type: "EXPORT_JOB", action: "START_EXPORT", canvas_id, payload: {canvas_id, format, dpi, target}, …}

Map<String, dynamic> buildCancelExport(String jobId); // ⇒ {type:"EXPORT_JOB", action:"CANCEL_EXPORT", payload:{job_id}}

Future<String> saveToDownloads(String srcPath);       // → Download/SlateSync/<basename> via path_provider
```

**Wire value tables:**

| UI selection | `format` payload | `dpi` payload |
|---|---|---|
| PNG (default) | `"PNG"` | `300` \| `600` \| `1200` |
| JPG | `"JPG"` | `300` \| `600` \| `1200` |
| PDF | `"PDF"` | selector hidden+disabled; payload still carries `dpi` (send last/default `300`) — Doc 14 vector exporter ignores it |

| UI selection | `target` payload | Enabled when `!isConnected`? |
|---|---|---|
| PC | `"PC"` | no (disabled + hint) |
| Tablet | `"TABLET"` | yes |
| Both | `"BOTH"` | no (disabled + hint) |

## 5. Implementation Plan
1. **Sheet scaffold** — `showExportSheet` presents `showModalBottomSheet` (isScrollControlled) containing `_ExportSheetState`; format chips **PNG/JPG/PDF**, default **PNG**; selected format stored locally, re-rendered via `setState`.
2. **DPI selector** — segmented 300/600/1200 (default 300). When `format == pdf`: **hide the row entirely and disable DPI** (PDF is vector — template §3); wire `format` string only.
3. **Target radios** — PC / Tablet / Both. When `!client.isConnected`: **PC and Both disabled with hint text** “PC offline — connect to pair”; Tablet stays enabled. Re-evaluate on `SyncEvent.stateChanged`.
4. **Start** — validates selection → `client.sendRpc(buildStartExport(...))`; envelope must carry exact payload keys `canvas_id, format, dpi, target` (values upper-case strings; `dpi` always present — for PDF the hidden selector keeps the default `300`, which Doc 14's vector exporter ignores). Switch UI to progress state.
5. **Start envelope (Doc 02 §4.2 — asserted verbatim in tests):**
   ```json
   { "id": "<uuid-v4>", "type": "EXPORT_JOB", "action": "START_EXPORT",
     "canvas_id": "<canvas-uuid>",
     "payload": { "canvas_id": "<canvas-uuid>", "format": "PNG", "dpi": 600, "target": "TABLET" },
     "timestamp": 1760760000 }
   ```
6. **Progress UI** — subscribe `client.events`: `kind == progress` ⇒ `LinearProgressIndicator(value: percent/100)` + stage text (`EXPORT_PROGRESS` `stage` via `msg`) + `%` label; job id captured from first `Progress{jobId}`. Material/CTk-style linear bar, no custom painters needed.
   Progress event → UI mapping (Doc 25 `SyncEvent`):

   | Event field | UI element | Notes |
   |---|---|---|
   | `percent` (0–100) | `LinearProgressIndicator(value: percent/100)` | clamped |
   | `msg["stage"]` | stage `Text` | e.g. `"tiling"`, `"encoding"`, `"pushing"` |
   | `jobId` | stored as current job | first event captures; later mismatches ignored |
7. **Cancel** — button → `client.sendRpc(buildCancelExport(jobId))` (`EXPORT_JOB`/`CANCEL_EXPORT`, payload `{job_id}`), then reset sheet on next `stateChanged`/timeout. Envelope: `{"type":"EXPORT_JOB","action":"CANCEL_EXPORT","payload":{"job_id":"…"}}`.
8. **Tablet/Both receipt** — accumulate `FileChunk{transferId, index, data}` **out-of-order** in a `Map<int, Uint8List>`; `FileReceived{path}` (Doc 25 reassembled temp) ⇒ `saveToDownloads` moves bytes into `Download/SlateSync/`; Android 10+ **SAF/scoped-storage note**: on API 29+ prefer `MediaStore.Downloads`/SAF `ACTION_CREATE_DOCUMENT` fallback when direct path write throws `FileSystemException` → success snackbar with full path.
9. **PC target & failures** — `RpcReceived` whose msg payload carries finished `path`/`ok` ⇒ PC/Both: snackbar `“Saved on PC: <path>”`; `ok == false` ⇒ error toast with `reason` text. Sheet never imports PC code — Doc 15's push arrives via Doc 25 `rpcReceived`.
10. **Lifecycle** — cancel the `events` subscription in `dispose`; ignore `progress` events whose `jobId` ≠ current job (stale jobs from a previous sheet session).
11. **UI keys for tests** — stable keys: `ValueKey('format-png'|'format-jpg'|'format-pdf')`, `ValueKey('dpi-row')`, `ValueKey('target-pc'|'target-tablet'|'target-both')`, `ValueKey('export-start')`, `ValueKey('export-cancel')`, `ValueKey('export-progress')`.
12. **Tests** — see §6; `client` is a fake implementing the Doc 25 surface.

## 6. Testing & Acceptance Criteria
- **Submit payload**: call `buildStartExport` ⇒ outer keys contain `type/action/canvas_id/payload/timestamp`; payload keys **exactly** `canvas_id, format, dpi, target` with values `A4…`/`"PNG"`/`300`/`"TABLET"`.
- **PDF hides DPI**: pump sheet, select PDF ⇒ DPI selector absent from tree; select PNG ⇒ present with 300/600/1200.
- **DPI value carried**: select 1200 + JPG + submit ⇒ payload `dpi == 1200`, `format == "JPG"`.
- **Disabled-target rule**: fake `isConnected == false` ⇒ PC & Both radios disabled (hint visible), Tablet enabled; flip to `true` ⇒ all enabled.
- **Progress updates**: fake stream emits `Progress{jobId:'j1', percent: 42.0}` ⇒ progress bar value `0.42`, label “42%”, stage text shown.
- **Stale-job filtering**: `Progress{jobId:'other', percent: 10}` after current `j1` ⇒ bar unchanged.
- **Cancel**: after capturing `job_id`, tap Cancel ⇒ fake captured envelope has `action == "CANCEL_EXPORT"`, `payload["job_id"] == "j1"`.
- **Cancel envelope shape**: `buildCancelExport('j1')` ⇒ top-level `type == "EXPORT_JOB"`, `action == "CANCEL_EXPORT"`, `payload` has exactly one key `job_id`.
- **Tablet success snackbar**: after `FileReceived`, snackbar text contains `Download/SlateSync/` and the file basename.
- Receipt test (bonus): `FileReceived` ⇒ file lands under `Download/SlateSync/` in the temp-based path root; `ok:false` ⇒ error message shown.
- `flutter analyze` clean; **no `dart:io` sockets, no PC imports** (`pc_agent/**` absent from all imports).

## 7. Parallel Execution Notes
- **Wave 2.A** (Session 2, Subagent 8 per `overview.md` §6; template matrix row 27 → 2.A). Consumes Doc 25 (Wave 1.B, frozen) through an **injected** `VectorSyncClient` — tests fake it, so no cross-wave compile ordering within the wave.
- Zero overlap with the other 7 Wave 2.A docs: creates `features/export/**` only (Doc 24 owns `features/tools/`, Doc 26 owns `features/home/` + `core/storage/`, Docs 08/13–17 own `pc_agent/`).
- Contract discrepancy note: template §3's RPC action list has **no `EXPORT_FINISHED` action**, yet Doc 15's `EXPORT_FINISHED(job_id, percent, path, ok)` push must reach the tablet (task spec: “Saved on PC” snackbar). Resolution used here: the terminal push travels as `type: "EXPORT_JOB"` with the finish payload; if Doc 02/11 instead defines a dedicated action, the sheet keys off `payload.ok`/`payload.path` regardless.
- **Never touches:** `mobile_app/lib/network/**` (Doc 25), `mobile_app/lib/features/tools/**`, `mobile_app/lib/features/home/**`, `mobile_app/lib/core/storage/**`, `mobile_app/lib/canvas_engine/**`, `mobile_app/lib/core/models/**`, `mobile_app/lib/main.dart`, `mobile_app/pubspec.yaml`, `pc_agent/**`, `shared_specs/**`.
