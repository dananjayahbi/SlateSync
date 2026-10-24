# Doc 28: E2E Sync, Latency & Memory QA Harness

## 1. Objective & Scope

Single source of truth for automated end-to-end verification of SlateSync. Owns three `qa/` scripts that execute every gate in the `E2E gates` row of `_micro_doc_template.md` §3 — stylus→PC-GL p95 `≤ 8 ms`, LAN portion `≤ 4 ms`, tablet `60 FPS` @ `10 000` strokes, Flutter heap `< 180 MB`, `600 DPI` infinite export lossless, PDF vector zoom `6400%` — plus the packaging and suite-green gates of `overview.md` §7, printing one PASS/FAIL summary table. Pure verification: it adds no product features, imports product modules read-only, and runs **Wave 3.B** strictly after the Wave 3.A builds (PC `--onedir` bundle, release APK) and the Wave 3.B ISCC installer compile.

## 2. File Ownership

### Creates (implementation subagent writes these paths)
* `qa/run_all.ps1`
* `qa/latency_probe.py`
* `qa/export_verify.py`

### Read-only dependencies (imports / executed, each cited as "Doc NN")
* `pc_agent/core/events.py` — `EventBus` (Doc 04); `pc_agent/core/protocol.py` — `pack_live_frame`, frame/tool constants (Doc 04, mirrors Doc 02); `pc_agent/core/config_manager.py` — `AppConfig` (Doc 04).
* `pc_agent/network/ws_stream_server.py` — `WsStreamServer` (Doc 11); `pc_agent/network/discovery_pairing.py` — session token + QR payload (Doc 12).
* `pc_agent/engine/scene_graph.py` — `SceneGraph.validate_artboard_upgrade` (Doc 09); `pc_agent/engine/document_store.py` — fixture documents (Doc 10).
* `pc_agent/export/tiled_raster_exporter.py` — `TiledRasterExporter` (Doc 13); `pc_agent/export/vector_pdf_exporter.py` — `VectorPdfExporter` (Doc 14).
* `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` (Doc 02); `shared_specs/canvas_document_schema.json` (Doc 03).
* Acceptance suites executed, never edited: `pc_agent/tests/test_*.py` (Docs 04–19), `mobile_app/test/*_test.dart` (Docs 05, 20–27); lint/test config from Doc 01 (`pytest.ini`, `ruff.toml`).
* Flutter runtime only: `StrokeProcessor` loop + `TiledCanvasEngine` fixture path (Docs 21/22), `ArtboardManager.tryUpgrade` suite (Doc 23), `VectorSyncClient` suite (Doc 25).

### Never touches (paths owned by concurrent docs — write-conflict guard)
* Every path in the template §6 ownership matrix except the three `qa/` paths above — all of `pc_agent/**`, `mobile_app/**`, `shared_specs/**`, `.gitignore`/`pytest.ini`/`ruff.toml` (Doc 01), `docs/**` (incl. `overview.md`, `_micro_doc_template.md`, every other `docs/micro/*`).
* QA runtime outputs go outside the repo: exports to `%APPDATA%/SlateSync/exports/` (`AppConfig.export_dir`, Doc 04); the 10 000-stroke fixture is generated on-device into the app sandbox by the benchmark procedure in §6.

## 3. Contract References

* **Doc 02 schemas** — 16-byte `<BBHfff` frame, `FrameType`/`ToolId` constants, seq rule, `ws://<ipv4>:50606/ws?token=<session_token>` URL + close `4001`; probe frames and pairing checks must round-trip against `shared_specs/binary_stream_frame.json` / `ws_rpc_schema.json`; `envelope.action.enum` = 20 actions incl. `CLEAR_CANVAS` (Round-6 freeze, §4 step 1).
* **Doc 02 §10.4/§10.6 (Round-6)** — frozen strip-padded export dims fed into §4's extent matrix: @300 → A5 `2048×4096`, A4/Letter `4096×4096`; @600 → A5 `4096×6144`, A4/Letter `6144×8192`; INFINITE content-derived (2048-strip) and distinct from every bounded row; thumbnail contract `≤192²` PNG for the §4 smoke.
* **Doc 03 schema** — fixture documents, A5 `1748×2480` / A4 `2480×3508` / Letter `2550×3300` / INFINITE presets and the §4.4 upgrade rule validated by §6's matrix.
* **Template §3 master constants** — verbatim, especially the `E2E gates` row: p95 `≤ 8 ms`, LAN `≤ 4 ms`, `60 FPS` @ `10 000` strokes, heap `< 180 MB`, `600 DPI` lossless, PDF zoom `6400%`; export math `px = world_units * dpi / 300`, PDF points = `world_units * 72 / 300`, strips `2048×2048`, DPI `300, 600, 1200`, tiles `1024×1024` LRU `≤ ~120 MB`.
* **All module acceptance suites** (Docs 04–27) — this doc runs them; it never restates their assertions. `overview.md` §7 milestones are mapped to commands in §6.

## 4. Interface Freeze

The three artifacts are scripts, not importable modules — the frozen public surface is their CLI. Consumed product interfaces (template §4–5, never redefined):

```python
class EventBus:    # Doc 04
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
def pack_live_frame(frame: LiveFrame) -> bytes: ...          # Doc 04, "<BBHfff", 16 bytes
class WsStreamServer:                                        # Doc 11
    def __init__(self, bus, config, token_provider, host="0.0.0.0") -> None: ...
    def start(self) -> None: ...; def stop(self) -> None: ...
    port: int; broadcast_json(msg: dict, exclude=None) -> None: ...  # bad token → close 4001 (§10.2 additive exclude)
class TiledRasterExporter:  # Doc 13
    def export(self, doc, dpi: int, out_path, progress=None) -> Path: ...
class VectorPdfExporter:    # Doc 14
    def export(self, doc, out_path, progress=None) -> Path: ...
def validate_artboard_upgrade(self, target_preset, target_w, target_h) -> bool: ...  # Doc 09
# Doc 21 (Dart): StrokeProcessor.addPoint(...); ProcessedStroke? finish()
```

**`qa/run_all.ps1`** — no required parameters; emits a fixed **13-row** step table:

| # | Step | Gate (PASS iff) |
|---|---|---|
| 1 | `validate_specs (20 actions)` | `shared_specs\validate_specs.py` exit 0 **and** `ws_rpc_schema.json` `envelope.action.enum` parses to exactly 20 actions incl. `CLEAR_CANVAS` |
| 2 | `pytest pc_agent/tests` | `python -m pytest pc_agent/tests -q -rA` exit 0; `-rA` PASSED names feed row 6 |
| 3 | `ruff check .` | exit 0 |
| 4 | `flutter analyze` | exit 0 (cwd `mobile_app`) |
| 5 | `flutter test` | `flutter test --reporter json` exit 0 **and** `done.success`; JSON events give suite-id → file attribution (compact reporter omits paths) |
| 6 | `gate citations` | test names harvested from rows 2/5 output only — **never re-run**; FAIL unless PC contract = 7, Dart contract = 14, CLEAR ≥ 1 each side, relay ≥ 1 each side, trail-pan present, thumb group present |
| 7 | `latency_probe.py` | run_all generates a per-run `--token` (no `session_token.txt` dependency); exit 0 |
| 8 | `export_verify.py` | exit 0; `RESULT:` line parsed into DETAIL |
| 9 | `exe --smoke` | `dist\SlateSyncAgent\SlateSyncAgent.exe --smoke` exit 0 |
| 10 | `installer artifact` | `dist\SlateSync_Setup.exe` exists, size ≥ 1 MB |
| 11 | `release APK artifact` | `mobile_app\build\app\outputs\flutter-apk\app-release.apk` exists, size ≥ 1 MB |
| 12 | `firewall setup.iss lines` | `pc_agent\installer\setup.iss` contains `show rule` + `add rule` (`localport=50606`) + `delete rule` lines for `SlateSync WS` — the live rule registers at install time (§6 matrix row 6) |
| 13 | `memory benchmark` | `flutter devices --machine` gate: Android device attached → `SKIP` (run §5 DevTools procedure manually); absent → `SKIP` with device detail; **never FAIL** |

* Output: UTF-8 table `STEP | RESULT (PASS/FAIL/SKIP) | SECONDS | DETAIL` (one row per step), then the `GATE CITATIONS` block (labelled test-name groups with counts), then `TOTAL: n FAILED`; per-step DETAIL carries exit codes, suite counts and parsed metrics (e.g. `p50 … ms; p95 …; transport …`, `RESULT: …`). Any FAIL prints the tail of that step's captured output before the run continues (flutter test: first 15 `file :: name` failures, else suite errors / raw tail).
* Exit code: **FAIL counter** = number of FAILed steps — `0` = green (SKIP never counts as failure).

**`qa/latency_probe.py --host 127.0.0.1 --port 50606 --frames 5000 --rate 60`**
* Args: `--host` (default `127.0.0.1`), `--port` (default `50606`), `--frames` (default `5000`), `--rate` (default `60` Hz), `--token <t>` (else read `%APPDATA%/SlateSync/session_token.txt` written by Doc 12; missing file = usage error), `--json <out.json>` optional.
* Behavior: in-process `EventBus` + `WsStreamServer` (source untouched; instance-level spy wraps `emit` to stamp `t_emit`, spy handler stamps `t_handler`); real WebSocket client sends `pack_live_frame` LIVE_POINT `0x01` / tool `0x01` / u16 seq at `--rate`, stamping `t_send` via `time.perf_counter_ns()` (system-wide QPC). Metrics: `end_to_end = t_handler − t_send` → p50/p95/max; `transport = t_emit − t_send` → mean; `dispatch = t_handler − t_emit` reported diagnostically.
* Output: table `p50/p95/max ms | transport mean ms | dispatch µs | PASS/FAIL`; `--json` writes `{"frames", "p50_ms", "p95_ms", "max_ms", "transport_mean_ms", "result": "PASS"|"FAIL"}`.
* Exit: `0` iff p95 `≤ 8 ms` **and** transport mean `≤ 4 ms`; `1` otherwise (connect/token failure = `1`).

**`qa/export_verify.py`**
* Args: `--out-dir <path>` (default `%APPDATA%/SlateSync/exports`), `--json <out.json>` optional.
* Fixtures (built in memory via Docs 09/10): **four** — **A5** `1748×2480`, **A4** `2480×3508`, **LETTER** `2550×3300`, each bounded and built from **ONE shared content-element list** (strokes + `GRAPH_AXES`; identical content proves extent comes from the artboard, not the content) — plus **INFINITE** — `content_bounds (−2000,−1500)–(8000,6000)` incl. a `HIGHLIGHT` (multiply) + `IMAGE` node. Each fixture has an empty twin for the non-trivial guard.
* **Ladder (56 rows; the 28 pre-Round-6 checks retained):** for each fixture × DPI `300/600/1200` × kind `PNG/JPG/PDF`, real **and** empty baseline → artifact canvas W×H `== expected_canvas_px(world, dpi) ± 1 px` i.e. content `round(world * dpi / 300)` padded up to the 2048 strip grid (template §3), PNG `\x89PNG` / JPG `\xFF\xD8\xFF` / `%PDF` magic, first-page extent `world * 72 / 300` pt, real > empty (no hardcoded byte floor).
* **Extent matrix (issue-06 tripwire, Doc 02 §10.4):** A5/A4/LETTER @ `300` **and** `600` (`MATRIX_DPIS`) re-checked against the **frozen expected strip-padded dims** @300 → A5 `2048×4096`, A4/Letter `4096×4096`; @600 → A5 `4096×6144`, A4/Letter `6144×8192`; `±1 px` tolerance; formula⇄table cross-check (`expected_canvas_px(world,dpi) == frozen row`); INFINITE rows use the content-derived 2048-strip formula and must differ from **all** bounded rows; 4 distinctness checks (content px distinct per preset; A5 padded ≠ A4/LETTER padded; per-preset @300 ≠ @600; INFINITE ≠ every bounded row).
* **Thumbnail smoke (Doc 02 §10.6):** `render_thumbnail` on the A4 fixture (+ empty baseline): file exists, `≤192²` square, PNG magic, > empty baseline. Mobile coverage stays in `thumbnail_pipeline_test.dart` (cited by `run_all` row 6, not re-run here).
* Output: ladder table `FIXTURE | KIND | DPI | W×H got/expected | BYTES | MAGIC | PASS/FAIL` plus the `EXTENT MATRIX` + `THUMBNAIL SMOKE` sections; combined verdict line `RESULT: PASS|FAIL (<pass>/72 checks; 64 rows + 8 matrix/thumb checks; <failed> failed)` — 56 ladder rows + 8 matrix rows, 4 distinctness + 4 thumbnail checks; exit `0` iff zero failed rows/checks, `1` otherwise.

## 5. Implementation Plan

**`qa/run_all.ps1`**
1. Resolve repo root from `$PSScriptRoot`; run the fixed 13-step sequence of §4 (child processes via `Invoke-Step`; cwd pushed per step), capturing output + exit code + elapsed seconds.
2. Map non-zero exit / failed gate → FAIL, append row; any FAIL prints that step's output tail (last N captured lines; flutter test → first 15 failures from the JSON events, else suite errors).
3. Row 6 `gate citations`: harvest test names from rows 2/5 captured output only (`-rA` PASSED lines; JSON suite-id → file map) — never re-run tests; FAIL on any count violation per §4.
4. Device gate (row 13): `flutter devices --machine`; Android attached ⇒ `SKIP` + pointer to the §5 DevTools procedure (script cannot snapshot headlessly); absent ⇒ `SKIP` with detail; **never FAIL**.
5. Print aligned summary table + `GATE CITATIONS` block + `TOTAL: n FAILED`; `exit $failCount` (FAIL counter).

**`qa/latency_probe.py`**
1. `argparse` per §4; token resolution (`--token` > `session_token.txt` > error); clock helper `now_ns = time.perf_counter_ns`.
2. Boot in-process stack: `AppConfig` → `EventBus` → `WsStreamServer(bus, config, token_provider=lambda: token)`; wrap `bus.emit` with the spy (delegate to original; record `t_emit` only for `LIVE_FRAME`); `bus.on("LIVE_FRAME", handler)` records `t_handler` against a deque of pending `t_send` stamps (FIFO, seq-ordered).
3. Synthetic client: `websockets.sync.client.connect(f"ws://{host}:{port}/ws?token={token}")`; paced loop sends `pack_live_frame(LiveFrame(0x01, 0x01, seq & 0xFFFF, x, y, pressure))` for `--frames` at `--rate` Hz (jitter-free `perf_counter` schedule). `run_all` row 7 injects a per-run `--token`; `session_token.txt` is only read when `--token` is absent.
4. Statistics: nearest-rank p50/p95/max of `end_to_end`, mean of `transport`; evaluate §4 gates; print table; optional `--json`; `server.stop()` in `finally`; exit per §4.

**`qa/export_verify.py`**
1. `argparse`; `out_dir = Path(args.out_dir) / "qa"` mkdir (existing-tree safe); `AppConfig` pointed at `out_dir` (shaders/assets/export/appdata inside it).
2. Fixtures per §4: `matrix_content()` shared element list fed to `build_a5_fixture()` / `build_preset_fixture("A4"|"LETTER")` + empty twins; `build_infinite_fixture()` with its own content (uuid `node_id`s, Doc 03 `content_bounds`, placeholder `photo.png` asset).
3. `expected_px(extent, dpi) = round(extent * dpi / 300)`; `expected_canvas_px(world, dpi) = ceil(px/2048)*2048` (strip pad); `expected_pt(extent) = extent * 72 / 300`; `expected_page_pt` = bounded ⇒ artboard, INFINITE ⇒ `content_bounds ± 48/side` (Doc 14 §4).
4. Ladder: for each fixture × dpi `(300, 600, 1200)` × kind `PNG/JPG`: export empty baseline **first**, then real → verify strip-padded dims ±1 px + covers content px + magic + real > empty; PDF row per fixture likewise (`%PDF`, MediaBox extent ±0.5 pt, real > empty) → 56 rows.
5. Matrix: re-read the ladder PNGs of A5/A4/LETTER/INFINITE @ `300/600` → frozen `MATRIX_EXPECTED` dims ±1 px + formula⇄table cross-check + PNG magic + > empty; then the 4 distinctness checks; thumbnail smoke ×2 renders (`render_thumbnail` A4 real + empty) → 4 checks.
6. Print `EXTENT MATRIX` + `THUMBNAIL SMOKE` sections, then the ladder table (+ optional `--json`); verdict line per §4 `RESULT: PASS|FAIL (<pass>/72 checks; 64 rows + 8 matrix/thumb checks; <failed> failed)`; `exit 0` iff zero failed rows/checks.

**Memory benchmark (documented procedure, invoked by `run_all.ps1` step 13):**
1. On-device fixture: scripted harness loops `StrokeProcessor` (Doc 21) 10 000 times → commits each `ProcessedStroke` into `TiledCanvasEngine` (Doc 22) → saves fixture `.slatesync` (Doc 03) into app sandbox.
2. `flutter run --profile` on the attached device (Wave 3.A release APK target); open fixture from Home gallery (Doc 26).
3. DevTools → Memory tab: snapshot A (post-load); pan/zoom sweep across full content bounds for 60 s at `60 Hz` (zoom `0.05×…20.0×`); snapshot B.
4. Assert: heap delta/total `< 180 MB`; `TileCache.approxBytes()` `≤ ~120 MB`; DevTools frame chart sustains `60 FPS` throughout the sweep. Recorded manually — `run_all.ps1` step 13 only gates device presence and always reports `SKIP` (never FAIL); the script cannot take DevTools snapshots headlessly.

## 6. Testing & Acceptance Criteria

**Verification matrix** — every `overview.md` §7 milestone / template §3 gate → command → pass criteria → owning doc:

| # | Gate | Command / procedure | Pass criteria | Owning source |
|---|---|---|---|---|
| 1 | Stylus→OpenGL mirror latency (§7 Session 1) | `python qa\latency_probe.py --host 127.0.0.1 --port 50606 --frames 5000 --rate 60` | exit 0: p95 `≤ 8 ms`, transport mean `≤ 4 ms` | Docs 06/11 (harness: this doc) |
| 2 | `60 FPS` @ `10 000` strokes, heap `< 180 MB` (§7 Phase 3) | memory-benchmark procedure §5 steps 1–4 (`flutter run --profile` + DevTools snapshots) | sustained `60 FPS`; heap `< 180 MB`; LRU `≤ ~120 MB` | Docs 21/22 |
| 3 | Artboard upgrade matrix (§7 Session 2) | `pytest pc_agent\tests\test_scene_graph.py` **and** `flutter test test\artboard_manager_test.dart` | both suites green; identical verdicts per case table below | Docs 09/23 |
| 4 | `600 DPI` infinite export lossless + PDF zoom `6400%` (§7 Phase 3) | `python qa\export_verify.py`; then manual viewer check: open INFINITE PDF, zoom to `6400%` — curves/labels stay sharp, no pixelation | exit 0; `RESULT: PASS (64 rows + 8 checks)`; ladder dims strip-padded ±1 px @300/600/1200; extent matrix hits frozen Doc 02 §10.4 dims + 4 distinctness checks; PNG/JPG + `%PDF` magic; thumbnail smoke ≤192²; vector sharp at `6400%` | Docs 13/14 |
| 5 | Pairing path | `pytest pc_agent\tests\test_discovery_pairing.py pc_agent\tests\test_ws_stream_server.py` + `flutter test test\vector_sync_client_test.dart` | mDNS `_slatesync._tcp.local.` name `SlateSync` visible; QR payload `slatesync://connect?ip=…&port=50606&token=…` parses; wrong token ⇒ server close `4001` | Docs 12/25/11 |
| 6 | Packaging gates (§7 Phase 3) | `dist\SlateSyncAgent\SlateSyncAgent.exe --smoke`; `dist\SlateSync_Setup.exe` exists (≥1 MB); `Test-Path mobile_app\build\app\outputs\flutter-apk\app-release.apk` (≥1 MB); grep `pc_agent\installer\setup.iss` for `netsh advfirewall firewall show/add/delete … SlateSync WS` lines | `--smoke` exit 0; installer + release APK exist with size; setup.iss show/add/delete script lines present — **the live `netsh` rule registers at install time**, so pre-install `netsh show rule` cannot be the harness gate (run_all step 12 checks the script lines; verify the live rule only on an installed machine) | Docs 18/19 + §7 |
| 7 | Full suites + harness green (§7 Session 2/3) | `powershell -File qa\run_all.ps1` (13 rows per §4) | `TOTAL: 0 FAILED`, exit 0; includes `validate_specs` 20-action freeze, `pytest`/`ruff`/`flutter analyze`/`flutter test --reporter json`, `gate citations` (PC contract 7, Dart contract 14, CLEAR/relay both sides, trail-pan, thumb group) | Doc 01 + owning docs |

**Upgrade case matrix (row 3)** — cited from existing parametrized suites, never duplicated here:

| From | To | Content | Expected |
|---|---|---|---|
| A5 | A4 | within A4 | ✓ allowed |
| A4 | A5 | exceeds A5 bounds | ✗ blocked |
| any (A5/A4/Letter/INFINITE) | INFINITE | any | ✓ always |
| INFINITE | Letter | inside Letter bounds | ✓ allowed |
| INFINITE | Letter | outside Letter bounds | ✗ blocked |
| empty canvas | any preset | none | ✓ allowed |

Asserted by `SceneGraph.validate_artboard_upgrade` parametrized pytest cases (Doc 09) **and** `ArtboardManager.tryUpgrade` parametrized flutter cases (Doc 23) — run both; a divergence between the two verdicts is a FAIL.

**Final recorded run (Round-6 acceptance evidence)** — `qa\run_all.ps1` full pass:

| Row | Result |
|---|---|
| total | `TOTAL: 0 FAILED`, exit 0 |
| validate_specs | 3 specs VALID; 20 actions (`CLEAR_CANVAS` present) |
| pytest / ruff / analyze | `pytest` 490 passed · `ruff check .` clean · `flutter analyze` clean |
| flutter test | 327 passed (`--reporter json`) |
| gate citations | PC contract 7/7 · Dart contract 14/14 · CLEAR 13/18 · relay 5/6 · trail-pan 2 · thumb 7 |
| latency probe | p50 0.508 ms · p95 1.225 ms · transport 0.612 ms (5000/5000 frames) |
| export verify | 72/72 (`RESULT: PASS … (64 rows + 8 checks)`) |
| artifacts | exe 8.46 MiB (`--smoke` OK) · installer 26.22 MB · APK 68.71 MB |
| firewall | setup.iss show/add/delete script lines present (live rule registers at install time) |
| memory benchmark | `SKIP` — no Android device attached (never FAIL) |

**Failure triage table:**

| Symptom | Likely owning doc |
|---|---|
| p95 > 8 ms, transport OK | Doc 06 pump/throttle (`after(16, tick)`, latest-slot) or Doc 11 thread hop |
| transport mean > 4 ms | Doc 11 socket/unpack path; frame layout per Doc 02 |
| heap > 180 MB @ 10 000 strokes | Doc 22 LRU cap (template: LRU `≤ ~120 MB`) |
| 60 FPS drop under load | Doc 21 decimation (2.0 dp) or Doc 22 tile rebake |
| export dims off by > 1 px | Doc 13 unit math (`px = world * dpi / 300`) |
| missing PNG/JPG magic or trivial size | Doc 13 tiler; missing `%PDF` ⇒ Doc 14 |
| PDF pixelates at `6400%` | Doc 14 (vector path) |
| `4001` reconnect loop | Doc 12 token file `%APPDATA%/SlateSync/session_token.txt` or Doc 25 URL `?token=` |
| QR/mDNS parse failure | Doc 12 payload / Doc 25 discovery |
| upgrade case verdict wrong | Doc 09 `validate_artboard_upgrade` / Doc 23 `tryUpgrade` |
| `--smoke` ≠ 0 | Doc 18 spec assets or Wave 3.A `pc_agent/main.py` wiring |
| firewall rule not listed | Doc 19 `setup.iss` `netsh` entry (`run_all` step 12 checks show/add/delete script lines; live rule appears only after install) |

## 7. Parallel Execution Notes

* **Wave 3.B** (template §6 row 28; `overview.md` §6 Session 3, Subagent 2) — runs strictly **after** the Wave 3.A barrier: `dist/SlateSyncAgent/` bundle (Doc 18), release APK (Doc 05/§7), and authored `setup.iss` (Doc 19); packaging checks (matrix row 6) execute only after Wave 3.B Subagent 1's `ISCC.exe pc_agent/installer/setup.iss` has produced `SlateSync_Setup.exe`.
* Sibling in wave: Wave 3.B Subagent 1 (Installer Compile) — zero overlap: it owns `pc_agent/installer/setup.iss` output; this doc owns only `qa/run_all.ps1`, `qa/latency_probe.py`, `qa/export_verify.py`.
* Never touches any path owned by Docs 01–27 (§2); product modules are imported/execute-only. No same-wave file is shared; no other doc may create or edit `qa/*`.
