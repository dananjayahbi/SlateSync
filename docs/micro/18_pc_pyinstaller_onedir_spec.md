# Doc 18: PyInstaller onedir Spec

## 1. Objective & Scope
Authors `pc_agent/installer/slatesync_agent.spec` — a PyInstaller spec described **field-by-field** (not a monolithic code dump) that produces a windowless **onedir** bundle of the PC agent: GLSL shaders, CustomTkinter assets, Cairo/giflib DLLs, and all runtime hidden imports packed into `dist/SlateSyncAgent/`. The spec is authored in Wave 3.A and executed by the Wave 3.A PC Master Wiring subagent. This doc creates **no** Python module and **no** pytest file (not listed in the template §6 matrix) — acceptance lives in the Wave 3.A build steps.

**Packaging goals:** single-folder (onedir) layout for fast startup and easy DLL resolution; windowless (`console=False`) so the agent never flashes a terminal; every runtime-discovered asset (shaders, CustomTkinter themes, Cairo native libraries) travels inside the bundle; the frozen app still resolves `AppConfig.shader_dir` / `assets_dir` / `export_dir` (Doc 04) unmodified.

**In scope:** authoring the spec file only. **Out of scope:** executing the build (Wave 3.A PC Master Wiring subagent), the InnoSetup script (Doc 19), and any change to Python sources or `requirements.txt`. The produced bundle doubles as Doc 19's `[Files]` compile input (Wave 3.B).

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `pc_agent/installer/slatesync_agent.spec`

### Read-only dependencies (imports, each cited as "Doc NN")
- `pc_agent/main.py` — the analyzed entry script; `--smoke` flag defined by Doc 04's bootstrap (finalized Wave 3.A)
- `pc_agent/requirements.txt` dependency set (Doc 04): `customtkinter`, `pycairo`, `Pillow`, `websockets`, `zeroconf`, `qrcode`, `pystray`
- `pc_agent/viewport/shaders/` — outputs of Docs 07/08 (`stroke.vert/.geom/.frag`, `primitive|grid|texture.*`)
- template §6 row 18 (Wave 3.A) and overview §3 tree (`pc_agent/installer/slatesync_agent.spec # Doc 18`)
- PyInstaller 6.x `PyInstaller.utils.hooks.collect_data_files` / `collect_all`; venv `Lib/site-packages` Cairo DLLs (fallback discovery)

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `pc_agent/installer/setup.iss` (Doc 19, same wave)
- All `pc_agent/**/*.py` sources owned by Docs 04–17 (cross-wave finalization of `pc_agent/main.py` belongs to the Wave 3.A PC Master Wiring subagent, not to this doc's file set)
- `pc_agent/requirements.txt` (Doc 04), `dist/**` and `build/**` outputs are regenerated — never hand-edited
- `mobile_app/**`, `qa/**`, other docs' tests, `docs/overview.md`, `docs/_micro_doc_template.md`

## 3. Contract References
- overview §3: `installer/slatesync_agent.spec # Doc 18` inside `pc_agent/installer/`; shader paths `.vert/.geom/.frag` (overview §3 tree) — template §4 `ProgramRegistry`: "pairs `<stem>.vert` + `<stem>.frag` in `config.shader_dir`"
- template §4 `AppConfig.shader_dir` / `assets_dir` / `export_dir` (Doc 04) — bundle must let the frozen app resolve these under the onedir layout
- template §6: Doc 18 → Wave 3.A; creates exactly one path (no test file); Doc 19's `ISCC.exe` compile waits for this doc's `dist/SlateSyncAgent/` (Wave 3.B)
- template §3 constants: service port `50606` (not bound during `--smoke`), no other numeric constants consumed
- Doc 04 `--smoke` contract: the flag parses before any WS/GUI startup, letting the frozen exe self-verify assets in a plain build step
- onedir chosen over onefile: native Cairo DLLs bind reliably and shader/asset paths resolve relative to `_internal/` without per-launch extraction cost

## 4. Interface Freeze
**Exact build commands (from repo root):**
```text
pyinstaller pc_agent/installer/slatesync_agent.spec
dist\SlateSyncAgent\SlateSyncAgent.exe --smoke        → exit code 0
```
**Build environment:** Python 3.11 venv with `pyinstaller` plus Doc 04's `requirements.txt` installed; the command in §4 runs from the **repo root** so every relative path resolves.

**Artifact paths:**
```text
build/SlateSyncAgent/                intermediates (regenerable)
dist/SlateSyncAgent/                 onedir bundle root (data under _internal/ on PyInstaller ≥6)
dist/SlateSyncAgent/SlateSyncAgent.exe   windowless entry point (console=False)
```
**Spec key fields:**
```python
Analysis(script=['pc_agent/main.py'], pathex=[<repo root>],
         datas=[...], hiddenimports=[...], excludes=[...], binaries=[...])   # → a
PYZ(a.binaries, a.datas, ...)
EXE(pyz, a.binaries, a.datas, name='SlateSyncAgent',
    console=False,                       # windowless: no console flash
    icon=<pc_agent/assets/slatesync.ico if present else None>)
COLLECT(exe, a.binaries, a.datas, name='SlateSyncAgent')                     # → dist/SlateSyncAgent/
# datas highlights: shaders pc_agent/viewport/shaders/*.{vert,geom,frag,glsl} → dest pc_agent/viewport/shaders
#                   + collect_data_files('customtkinter') + runtime icon if present
# excludes: pytest, tests, matplotlib     |     pycairo: collect_all('pycairo') (Cairo DLLs)
```
**Pipeline stages (top-to-bottom file order):**
| Stage | Builder call | Produces |
|---|---|---|
| Analysis | `Analysis(script=…, pathex=…, datas=…, hiddenimports=…, excludes=…)` | `a` — TOC, PYZ inputs |
| PYZ | `PYZ(a.binaries, a.datas)` | embedded pure-Python archive |
| EXE | `EXE(pyz, a.binaries, a.datas, console=False, name='SlateSyncAgent')` | bootstrap `.exe` |
| COLLECT | `COLLECT(exe, a.binaries, a.datas, name='SlateSyncAgent')` | `dist/SlateSyncAgent/` |

## 5. Implementation Plan
1. **Spec header.** `# -*- mode: python ; coding: utf-8 -*-`; import `Path`, `glob`, `exists`, and `from PyInstaller.utils.hooks import collect_data_files, collect_all`; resolve `ROOT` (repo root) from `SPECPATH` (`pc_agent/installer/../..`) so every relative path is repo-root-relative.
2. **`Analysis` entry & search path.** `script=['pc_agent/main.py']` (Doc 04 bootstrap, Wave 3.A-finalized, carries `--smoke`); `pathex=[ROOT]` so `pc_agent.*` packages resolve.
3. **`datas` — shaders.** Glob `ROOT/pc_agent/viewport/shaders/*` for `*.vert`, `*.geom`, `*.frag` (Docs 07/08 outputs per overview §3) **and** `*.glsl` (catch-all); emit tuples `(abs_path, 'pc_agent/viewport/shaders')` so `AppConfig.shader_dir` keeps its relative shape inside the bundle.
4. **`datas` — CustomTkinter & icon.** `datas += collect_data_files('customtkinter')` (themes/JSON assets); append `('pc_agent/assets/slatesync.ico', 'pc_agent/assets')` only `if` the runtime icon file exists (mirrors the EXE `icon=` guard).

   **`datas` composition summary:**
   | Source | Destination in bundle | Condition |
   |---|---|---|
   | `pc_agent/viewport/shaders/*.{vert,geom,frag,glsl}` | `pc_agent/viewport/shaders/` | always (Docs 07/08 outputs) |
   | `collect_data_files('customtkinter')` | package-relative | always |
   | `pc_agent/assets/slatesync.ico` | `pc_agent/assets/` | only if present |
5. **`hiddenimports`.** Dynamic imports invisible to static analysis — grouped by consumer (all Wave 1.A/1.B/2.A modules):

   | Group | Modules | Consuming doc |
   |---|---|---|
   | mDNS discovery | `zeroconf` | Doc 12 |
   | system tray | `pystray` | Doc 17 |
   | QR + imaging | `qrcode`, `qrcode.image.pil`, `PIL.Image`, `PIL.ImageDraw`, `PIL.ImageTk` | Doc 12 QR file, Doc 16 `CTkImage` |
   | async WebSocket | `websockets.asyncio.client`, `websockets.legacy.client`, `websockets.extensions.permessage_deflate` | Doc 11 |
6. **`excludes`.** `['pytest', 'tests', 'matplotlib']` — test runners and unused heavy plotting never enter the PYZ.
7. **Cairo DLLs (pycairo).** `d, b, h = collect_all('pycairo'); datas += d; binaries += b; hiddenimports += h` — pulls native Cairo/giflib libraries; **fallback** if the hook yields nothing: explicit `binaries` tuples for `libcairo-2.dll` and `libgif-7.dll` discovered under the venv's `Lib/site-packages` (or the GTK runtime dir shipped with the pycairo wheel), e.g. `[(str(dll), '.')] for dll in VENV_DLLS if dll.name.startswith(('libcairo', 'libgif'))`.
8. **`PYZ`.** Straightforward `PYZ(a.binaries, a.datas)` — no exclusions beyond `Analysis.excludes`.
9. **`EXE`.** `name='SlateSyncAgent'`, `console=False` (windowless agent), `icon=` set only when the runtime icon exists; receives `pyz, a.binaries, a.datas`.
10. **`COLLECT`.** `name='SlateSyncAgent'` → produces `dist/SlateSyncAgent/` (onedir). No further hooks; `--windowed` semantics come from `console=False`.

## 6. Testing & Acceptance Criteria
No pytest file (Doc 18 owns none per template §6). Acceptance executes in the **Wave 3.A build steps** (Subagent 1):
1. `pyinstaller pc_agent/installer/slatesync_agent.spec` from repo root exits 0 and writes `dist/SlateSyncAgent/`.
2. **Bundle content** — GLSL shaders present at `dist/SlateSyncAgent/_internal/pc_agent/viewport/shaders/*.vert|*.frag` (path without `_internal/` on PyInstaller <6) and Cairo/giflib DLLs (`libcairo-2.dll`, `libgif-7.dll`) present in the bundle's binary dir.
3. **Smoke** — `dist\SlateSyncAgent\SlateSyncAgent.exe --smoke` exits **0** (flag implemented by Doc 04's `main.py` bootstrap: config load + shader/asset path verification, no window, no WS bind).
4. **Windowless** — launching `SlateSyncAgent.exe` without arguments shows no console window (`console=False`).
5. **Deterministic rebuild** — a second `pyinstaller pc_agent/installer/slatesync_agent.spec` run overwrites `build/`+`dist/` without manual cleanup; the spec file (not CLI flags) is the single source of truth for the bundle.

**Expected bundle layout (PyInstaller ≥6):**
```text
dist/SlateSyncAgent/
├── SlateSyncAgent.exe                     console-free entry (Doc 04 main.py)
└── _internal/
    ├── pc_agent/viewport/shaders/stroke.vert … texture.frag   (Docs 07/08)
    ├── libcairo-2.dll, libgif-7.dll        (pycairo native deps)
    └── customtkinter/ … themes + assets    (collect_data_files)
```
**Build-step verification commands:** `Test-Path dist\SlateSyncAgent\_internal\pc_agent\viewport\shaders\stroke.vert`; `Get-ChildItem dist\SlateSyncAgent -Recurse -Filter libcairo-2.dll`; `& dist\SlateSyncAgent\SlateSyncAgent.exe --smoke; $LASTEXITCODE` → `0`.

The smoke run must finish within a few seconds, open no window, bind no port `50606`, and write nothing outside `%APPDATA%\SlateSync` — proving the frozen bundle is self-contained before Wave 3.B consumes it.

## 7. Parallel Execution Notes
- **Wave 3.A** (Session 3, Subagent 1 of 3 — PC Master Wiring & PyInstaller). Zero overlap: Doc 18 exclusively creates `pc_agent/installer/slatesync_agent.spec`; Doc 19 (same wave) exclusively creates `pc_agent/installer/setup.iss`; the Flutter master-shell subagent touches only `mobile_app/**`. Cross-wave sequential edit allowed by template §6: this wave finalizes `pc_agent/main.py` (Doc 04 bootstrap) before running the build.
- Ordering: the `dist/SlateSyncAgent/` bundle produced here is the input to Doc 19's `ISCC.exe` compile, which is **deferred to Wave 3.B** (template §6).
- **Never touches:** `pc_agent/installer/setup.iss` (Doc 19), all `pc_agent/**/*.py` sources (Docs 04–17 + Wave 3.A wiring), `pc_agent/requirements.txt` (Doc 04), `mobile_app/**`, `qa/**`, other docs' tests, `docs/overview.md`, `docs/_micro_doc_template.md`.
