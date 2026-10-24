# Doc 01: Monorepo Structure

## 1. Objective & Scope
Defines the root scaffolding conventions of the SlateSync monorepo: the directory tree (authority: `overview.md` §3), the root `.gitignore`, `pytest.ini`, `ruff.toml`, and the stdlib-only `shared_specs/validate_specs.py` contract checker that validates the three Phase 0 JSON locks (Docs 02/03) after the Wave 1.A barrier. Also documents the File-Ownership and Interface-Freeze conventions every micro-doc carries and the per-module test layout. Phase 0 = documentation only; the implementation subagent later writes only the four paths in §2.

## 2. File Ownership
### Creates (implementation subagent writes these paths)
- `.gitignore`
- `pytest.ini`
- `ruff.toml`
- `shared_specs/validate_specs.py`

### Read-only dependencies (imports, each cited as "Doc NN")
- `docs/overview.md` §2–§3 (Phase 0 orchestrator file — ownership rules & frozen tree)
- `docs/_micro_doc_template.md` §1–§3, §6 (Phase 0 orchestrator file — section template, master constants, matrix)
- `shared_specs/binary_stream_frame.json` (Doc 02), `shared_specs/ws_rpc_schema.json` (Doc 02), `shared_specs/canvas_document_schema.json` (Doc 03) — validator inputs, never rewritten here
- `pc_agent/tests/` (Doc 04+) and `mobile_app/test/` (Doc 05+) — referenced by naming pattern only

### Never touches (paths owned by concurrent docs — write-conflict guard)
- `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` (Doc 02)
- `shared_specs/canvas_document_schema.json` (Doc 03)
- `pc_agent/**` (Docs 04+), `mobile_app/**` (Docs 05+), `qa/**` (Doc 28)
- `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator)

## 3. Contract References
- `overview.md` §2 rules 1–3 (Contract-First Freeze, Strict File-Per-Micro-Doc Ownership, Interface Freeze), §3 directory blueprint, §5 catalog entry 1, §6 Wave 1.A Subagent 1
- `_micro_doc_template.md` §1 (required section structure), §2 rules 1/2/5/7 (tree fidelity, number fidelity, test paths, wave isolation), §3 master-constant table (validation target), §6 ownership-matrix row 01

## 4. Interface Freeze
No Python/Dart interface from `_micro_doc_template.md` §4–5 crosses this doc (those belong to Docs 04–27). The frozen interfaces Doc 01 exports are the validator entry points and the three root-config key sets:

```python
# shared_specs/validate_specs.py (Doc 01 — stdlib only: json, sys, pathlib)
def load_spec(path: Path) -> dict: ...                    # json.load; on error print "path: <msg>" to stderr
def validate_binary_frame(spec: dict) -> list[str]: ...   # error strings; empty list = valid
def validate_ws_rpc(spec: dict) -> list[str]: ...
def validate_canvas_document(spec: dict) -> list[str]: ...
def main(argv: list[str] | None = None) -> int: ...       # 0 = all three specs valid, 1 = violations/missing file
```

* `pytest.ini` frozen keys: `[pytest]` → `testpaths = pc_agent/tests`, `addopts = --strict-markers`.
* `ruff.toml` frozen keys: `target-version = "py311"`, `line-length = 100`, `[lint] select = ["E", "F", "I"]`.
* Test-path patterns (all docs): `pc_agent/tests/test_<module>.py`, `mobile_app/test/<feature>_test.dart`.
* Doc-file naming: `docs/micro/NN_<snake_case_title>.md` (NN = 01…28).

## 5. Implementation Plan
**Step 1 — Conform to the frozen tree.** Condensed skeleton (authority remains `overview.md` §3 plus `_micro_doc_template.md` §2 rule 1 amendments — `qa/`, `viewport/shaders/`, `core/protocol.py`, `core/events.py`, `core/models/canvas_models.dart`):

```text
slatesync/
├── docs/                     overview.md, _micro_doc_template.md, micro/ (28 micro-docs)
├── shared_specs/             binary_stream_frame.json, ws_rpc_schema.json, canvas_document_schema.json, validate_specs.py
├── pc_agent/                 main.py, requirements.txt, core/, viewport/ (+ shaders/), engine/, network/, export/, gui/, installer/, tests/
├── qa/                       Doc 28 harness
└── mobile_app/               pubspec.yaml, analysis_options.yaml, lib/ (+ core/, canvas_engine/, network/, features/), test/
```

**Step 2 — Write root `.gitignore`.** Keeps virtualenvs, builds, caches, logs, and document archives out of VCS (`*.slatesync` files are user data, never committed):

```gitignore
venv/
build/
dist/
__pycache__/
.dart_tool/
*.log
*.slatesync
```

**Step 3 — Write `pytest.ini`.** Strict markers prevents typo'd/undeclared markers from silently skipping tests:

```ini
[pytest]
testpaths = pc_agent/tests
addopts = --strict-markers
```

**Step 4 — Write `ruff.toml`.** Python lint config for the whole `pc_agent/` tree; the Dart lint config (`mobile_app/analysis_options.yaml`) is owned by Doc 05 (§6 matrix row 05), not by Doc 01:

```toml
target-version = "py311"
line-length = 100

[lint]
select = ["E", "F", "I"]
```

**Step 5 — Validator load phase (`validate_specs.py`).** Resolve repo root from `Path(__file__).parent`; require `binary_stream_frame.json`, `ws_rpc_schema.json`, `canvas_document_schema.json` (missing ⇒ stderr "spec not yet written (Wave 1.A barrier)", exit 1); `json.load` each; parse failure names the file.

**Step 6 — Validator check matrix** (every check traces to `_micro_doc_template.md` §3 / `overview.md` §4):

| Spec file | Required keys / enum checks |
|---|---|
| `binary_stream_frame.json` | `byte_length == 16`, `struct_format == "<BBHfff"`, field offsets `{0,1,2,4,8,12}`, FrameType keys `0x01–0x04`, ToolId keys `0x01–0x04` |
| `ws_rpc_schema.json` | port `50606`, path `/ws`, token URL template, close code `4001`, 5 `type` values, 13 `action` values, `raw_cap_bytes_per_chunk == 262144` |
| `canvas_document_schema.json` | presets A5 `1748×2480`, A4 `2480×3508`, LETTER `2550×3300`, INFINITE null-dims + top-left origin note; 4 background styles, 2 blend modes, 6 element kinds, upgrade-rule expression present |

**Step 7 — Validator report & exit.** Accumulate all violations, print `file: check: expected X got Y` lines to stderr, exit 1 if any, else one `OK: 3 specs valid` line and exit 0. Invocation: `python shared_specs/validate_specs.py` — runs **after** the Wave 1.A barrier (Docs 02/03 must exist first).

**Step 8 — File-Ownership convention (mirrors `overview.md` §2 rule 2).** Every micro-doc carries §2 with Creates / Read-only / Never-touches; Creates must equal its `_micro_doc_template.md` §6 matrix row exactly; two docs in the same wave never share a Creates path; the subagent that creates a module also creates its test file.

**Step 9 — Interface-Freeze convention (mirrors `overview.md` §2 rule 3).** Every micro-doc §4 freezes exact public signatures (classes, methods, dataclass fields, event names); cross-module code imports frozen names and never re-declares them (e.g., Doc 04 imports Doc 02's wire constants; Doc 05 mirrors them — both consume, never redefine).

**Step 9b — Cross-reference & path conventions (template §2 rule 3, §1):** cite sibling micro-docs by number (`Doc 09`, `Doc 25` …) at every cross-module reference; use relative repo paths only; add no README or extra files beyond the 28 micro-docs.

**Step 10 — Test layout.** PC: one `pc_agent/tests/test_<module>.py` per module (pytest, collected via `testpaths`); Dart: one `mobile_app/test/<feature>_test.dart` per feature (`flutter test`); ownership = the module's subagent, so parallel waves never collide on test files (§6 matrix rows 04–27).

## 6. Testing & Acceptance Criteria
1. `python shared_specs/validate_specs.py` exits 0 once Docs 02/03 JSONs exist and match template §3; exits 1 naming file+check on any deviation (e.g., port `50607`).
2. Run before the barrier (specs missing) ⇒ exit 1 with the "missing spec" message, not a traceback.
3. `pytest` from repo root collects only `pc_agent/tests`; `--strict-markers` rejects unregistered markers.
4. `ruff check .` applies py311 / 100 columns / E,F,I from the root `ruff.toml`.
5. After scaffolding, `git status` shows no `venv/`, `build/`, `dist/`, `__pycache__/`, `.dart_tool/`, `*.log`, or `*.slatesync` paths as untracked noise.
6. Created set == template §6 row 01 exactly: `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` — nothing else.

## 7. Parallel Execution Notes
**Wave:** 1.A — Subagent 1 (Monorepo Skeleton), in parallel with Docs 02/03 (shared_specs JSONs), Doc 04 (PC boilerplate), Doc 05 (Flutter boilerplate).

**Never touches (write-conflict guard):** `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` (Doc 02); `shared_specs/canvas_document_schema.json` (Doc 03); `pc_agent/**` incl. `requirements.txt`, `core/protocol.py`, `core/events.py`, `main.py`, `pc_agent/tests/*` (Docs 04+); `mobile_app/**` incl. `pubspec.yaml`, `lib/core/models/canvas_models.dart`, `mobile_app/test/*` (Docs 05+); `qa/**` (Doc 28); `docs/overview.md`, `docs/_micro_doc_template.md`, `docs/micro/*` (Phase 0 orchestrator).

**No-overlap confirmation:** none of the four Creates paths appears in the Creates rows of Docs 02–05 (template §6); `validate_specs.py` is authored in Wave 1.A but executed only after the Wave 1.A barrier; cross-wave sequential edits (e.g., Wave 3.A finalizing `pc_agent/main.py`) follow `overview.md` §2 rule 4 and never involve Doc 01's paths.
