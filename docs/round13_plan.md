# Round 13 — Implementation Plan

Four tasks: fix the broken OCR pipeline, add an **image library** shared with the
PC agent, and add **multi-page books** with a realistic page-turn.

Written before any code, because the last round proved that guessing at causes
is how a "fix" ships without fixing anything.

Guiding constraints carried over from every previous round:

* the wire schema is **frozen by intent** — an RPC/action may only be added with
  lockstep updates in `shared_specs/ws_rpc_schema.json`,
  `shared_specs/validate_specs.py`, `pc_agent/core/protocol.py` and the four
  contract tests (`test_protocol.py`, `test_contract_cross_specs.py`,
  `mobile_app/test/contract_specs_test.dart`, and the Doc 02 embedded copy);
* mutations that cannot be expressed with an existing action reuse
  `DELETE_NODE` + per-kind `ADD_*` (there is no `UPDATE_NODE`);
* new behaviour lives in its own module, never appended to a monolith;
* the lock guard and the frozen `StudioTool` contract must keep working;
* both distributables are rebuilt at the end, version-bumped.

---

## 02 — OCR is broken: queued, never answers, cannot cancel

**Status:** DONE. Root cause confirmed by inspection before writing any fix;
all fixes implemented and verified.

**Verification:** `--ocr-selftest` reports `provider: DmlExecutionProvider`
(GPU, 3.2 s) with correct words; 27 tablet client tests pass; 85 PC OCR tests
pass; the cancel-progress regression test was mutation-checked (reverting the
fix makes it fail).

**Root cause — a one-word mismatch.** `EventBus.emit` dispatches with
`handler(**payload)` and the WebSocket server emits
`bus.emit(RPC_MESSAGE, msg=msg)`. Every other subscriber is declared
`def _on_rpc(self, msg=None, **_extra)`. Mine was declared
`def _on_rpc(self, message=None, **kwargs)` and then read
`kwargs.get("envelope")`.

That means `_on_rpc` was called with `msg=<the envelope>`, matched **neither**
`message` nor `envelope`, and returned early. Both `START_OCR` and
`CANCEL_OCR` were **silently discarded**:

* the tablet waits forever → the timeout the user saw;
* cancel is a no-op → the reason it could not be stopped.

The `EventBus` deliberately swallows handler exceptions (`logger.exception`), so
nothing was ever logged. This is the whole class of bug that a "does the handler
get called at all?" test catches and nothing else does.

**Why the tests passed anyway.** My coordinator tests called `_run_job`
directly, and the one `_on_rpc` test constructed the envelope itself and passed
it positionally — so it never exercised the real bus dispatch convention. The
new tests drive a real `EventBus` with the exact keyword the server uses.

**Fixes:**

1. `_on_rpc(self, msg=None, **_extra)` — the same signature every other
   subscriber uses, reading `msg`.
2. A regression test that emits through a real `EventBus` with `msg=`, so a
   future rename cannot pass silently.
3. Cancellation must be *observable*: `CANCEL_OCR` sets the flag, and because
   `TiledRasterExporter.export` only reports progress *between* strips, a cancel
   that lands during a long strip would otherwise wait. Add a cancel check
   inside the progress callback **and** before the model runs (already present),
   plus make the tablet's Cancel button work while the PC is still queued.
4. **GPU must be provable.** The selftest already reports the bound provider;
   surface that in the UI (the panel's result summary names GPU vs CPU) and add
   a startup log line, so a silent CPU fallback is visible without a manual run.
5. **PC agent must show queued jobs and progress.** A live OCR jobs panel:
   `pc_agent/gui/ocr_jobs_panel.py`, fed by bus events, listing each job with
   canvas, scope, stage, percent and a Cancel button.

**Files:** `pc_agent/ocr/ocr_coordinator.py`, `pc_agent/ocr/ocr_events.py` (new
event constants), `pc_agent/gui/ocr_jobs_panel.py` (new),
`pc_agent/gui/studio_window.py`, mobile `features/ocr/*`,
`pc_agent/tests/test_round13_ocr_rpc.py` (new).

**Acceptance:** a real `EventBus` + `msg=` dispatch starts a job; cancel stops
it mid-flight and the tablet gets a terminal `OCR_RESULT` with `error`;
`--ocr-selftest` reports `DmlExecutionProvider`; the PC panel lists jobs,
updates percent, and can cancel; no job can hang without a terminal message.

---

## 03 — Image library

**Status:** DONE (delegated; independently verified). 95 PC + 107 Dart tests.
One bug found on review and fixed here — see "IMAGE preset" below.

**IMAGE preset — a real crash found while verifying.** The gallery's "use as
canvas" builds a document with `artboard.preset = "IMAGE"` and the image's exact
pixel dims. Three things rejected that:

* `ArtboardManager._initialFor` threw `ArgumentError` for any preset outside
  A5/A4/LETTER/BOOK/INFINITE, so *opening* such a canvas crashed the studio;
* `presetDims`/`presetDimsLabel` threw the same way from the home card;
* the published `Artboard.preset` enum did not list it, so the document the app
  wrote was outside its own contract.

Fixed by making the marker preset first-class: `ArtboardManager.forDocument()`
adopts the document's own dims for presets outside the table (table presets still
win, so the Doc 23 matrix is untouched); `IMAGE` joined the schema enum and
`validate_specs` now *enforces* that the enum equals `PRESETS + IMAGE`, with a
guard that `IMAGE` never gains table dims. `BOOK` was also missing from
`ArtboardManager._dimsFor`, which would have crashed on every book open — added.

**The scenario drives the design.** A developer screenshots a bug, marks up
areas in the mobile app, and wants that annotated image back on the PC to paste
into a ticket. A designer grabs a template reference, annotates changes, and
wants it back. So the library is a **shared, two-way asset collection**, not just
a file list.

**Model.** One `LibraryImage` record per item: `image_id`, `title`, `width`,
`height`, `source` (PASTE / DROP / CANVAS), `created_at`, `updated_at`,
`mime`, and the stored file. Bytes live under
`<appdata>/gallery/<image_id>.<ext>`; metadata in a JSON index beside it
(`gallery/index.json`) so it survives restarts and is diffable. This mirrors how
`LocalCanvasIndex` already works on the PC.

**New RPC type `GALLERY` (lockstep, 4 actions initially):**

| action | direction | purpose |
|---|---|---|
| `GALLERY_LIST_REQUEST` | tablet → PC | ask for the index |
| `GALLERY_LIST` | PC → tablet | `images[]` metadata, newest first |
| `GALLERY_ADD` | both | register an image (bytes by the existing `ASSET_*` transfer) |
| `GALLERY_SAVE` | tablet → PC | upload a rendered canvas back into the library |

`GALLERY_ADD` / `GALLERY_SAVE` reuse the `ASSET_START/CHUNK/DONE` chunked
transfer that already exists for images and exports — no new byte transport.

**PC agent window.** A separate `GalleryWindow` (`CTkToplevel`) so the agent and
the gallery are usable **independently**, as asked. It must not block the studio
window: no `grab_set`, and closing it must not exit the app. It supports
paste (`Ctrl+V`) and drag-and-drop of files, shows a thumbnail grid newest-first,
and every item gets **Download** (save-as) and **Copy to clipboard**.

Two platform details that decide whether "copy to clipboard" works at all:

* an image on the Windows clipboard is `CF_DIB`, **not** PNG bytes — writing a
  PNG leaves an entry that most apps cannot paste. Needs a small
  `CF_DIB` encoder (`pc_agent/gallery/clipboard_image.py`), and `PIL` can build
  it from the decoded image.
* drag-and-drop in Tk needs `tkinterdnd2`; if it is unavailable the feature
  degrades to paste + a file picker rather than crashing.

**Mobile side.** Gallery entry on the home page opens a grid, newest first, with
a quick preview. The key action is **Use as canvas**: build a document whose
artboard is the image's **exact pixel size** and whose single element is that
image. Then the normal tools, export and save all work unchanged.

**Saving back.** When saving a canvas that came from the library, the app asks
**Replace** (same `image_id`) or **Copy** (new `image_id`) — as specified.

**Files:** `pc_agent/gallery/` (`__init__.py`, `library_store.py`,
`gallery_index.py`, `clipboard_image.py`), `pc_agent/gui/gallery_window.py`,
`pc_agent/network/gallery_sync.py`; mobile `features/gallery/`
(`gallery_screen.dart`, `gallery_grid.dart`, `gallery_client.dart`,
`use_as_canvas.dart`, `save_to_gallery_sheet.dart`), home entry point,
`use_as_canvas` document builder. Contract + docs.

**Acceptance:** an image pasted on the PC appears in the tablet gallery; an
image saved from the tablet appears on the PC with Download and Copy working; a
library image opened as a canvas has an artboard exactly matching its pixel size;
saving back offers Replace or Copy and both behave; both windows stay
independently usable.

---

## 04 — Books (multi-page canvases)

**Status:** DONE (delegated; independently verified). 74 PC + 110 Dart tests.
`BOOK` is bounded, A4/A5/LETTER only, `INFINITE` provably rejected, and legacy
non-book documents emit no `pages`/`page_id`/`groups` on the wire.

**Model decision — do not fork the document type.** A book is a normal
`CanvasDocumentModel` plus an ordered list of pages. Forking the document model
would mean a second implementation of every tool, renderer, export path and
mutation. Instead:

* `artboard.preset = "BOOK"` (bounded, like A4 — never infinite, per the brief);
* a new `pages` array in the document: `[{page_id, index, title}]`, with each
  page's elements addressed by `page_id`;
* `elements` stay in one list, each node gaining a `page_id` (default the first
  page for non-book documents, so **nothing else changes**).

This keeps one element pipeline; "which page am I on" becomes a filter, not a
second code path.

**New Canvas modal.** A "Book" preset reveals: page background (blank / ruled /
grid), rule spacing, page size (A4 / A5 / Letter — deliberately no Infinite),
and an optional cover image. If no cover is set the thumbnail is **page 1**.

**Page-turn animation.** A real paper fold, not a slide. Implemented as a
mesh-warped texture in the existing painter: the turning page is split into two
halves; the outer half is drawn as a `Path` with a simulated cylindrical fold
(horizontal gradient for shading, a soft shadow falling on the page beneath),
driven by a single `t` in `0..1`. The heuristic that makes it read as paper
rather than a flip is the **shading curve** (a fold catches light) plus the
shadow trail; without those it looks like a rotating card.

Reduced-motion must be honoured: a "turn instantly" path when the platform asks
for it, because a full-page fold is exactly the kind of animation that makes
some users motion-sick.

**Files:** `pc_agent/engine/book_model.py` (new: pages, page addressing),
`pc_agent/viewport/page_turn_animation.dart` equivalent in Flutter
(`mobile_app/lib/features/book/page_turn_painter.dart`), 
`mobile_app/lib/features/book/book_controller.dart`,
`mobile_app/lib/features/book/book_shell.dart`,
`mobile_app/lib/features/canvas/page_strip.dart` (page navigation),
`mobile_app/lib/features/home/new_canvas_modal` book branch,
PC `pc_agent/export/book_exporter.py` (multi-page PDF, one page per book page).
Contract + docs.

**Acceptance:** creating a Book offers page background/spacing/size/cover; the
thumbnail is the cover or page 1; pages can be added, turned and edited
independently; the turn animates as a fold with shading and shadow; reduced
motion skips the animation; a book exports as a multi-page PDF; infinite is not
offered.

---

## 05 — Build and verify

Version 1.0.7 / 1.0.7+8. Rebuild `SlateSync_Setup.exe` (verify
`FileVersion`), re-run `--smoke` and `--ocr-selftest` (must report
`DmlExecutionProvider`), rebuild the APK (verify `versionName`/`versionCode`,
confirm the signing cert is unchanged so it upgrades in place), replace the
previous APK in `dist/`, update docs, commit.

---

## Traps recorded from round 12 (still true)

* Subagents need an explicit `model`; omitting it returns `400`.
* `EventBus` dispatch is `handler(**payload)` — **always** declare
  `def _on_x(self, msg=None, **_extra)`; a wrong keyword silently no-ops.
* `flutter test` wipes `mobile_app/test/.home_card_badges_tmp/`; restore with
  `git checkout 602dc59 -- mobile_app/test/.home_card_badges_tmp`.
* Multi-line `git commit -m` fails in PowerShell — use `-F` with a file.
* `-replace` on CRLF files silently no-ops in PowerShell; use Python or the edit
  tool for multi-line edits.
* Adding a conditional `Stack` child above the unkeyed `ToolDock` remounts the
  dock and destroys an open property panel.
* `CustomPaint` hit-tests like any box; overlay painters need `IgnorePointer`.
* The dock rail is 17 tools tall — widget tests that tap it need a taller
  surface.
