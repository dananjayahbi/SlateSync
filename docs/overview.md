# SlateSync: Infinite Vector Note-Taking & Real-Time OpenGL PC Mirror
**Master Architecture & Multi-Agent Orchestration Plan (`overview.md`)**

---

## 1. Executive Summary & System Vision
**SlateSync** is an asymmetric, hardware-accelerated note-taking and infinite whiteboard ecosystem engineered specifically to turn a resource-constrained **Samsung Galaxy Tab A 10.1 (2016) (SM-T580, $2\text{ GB}$ RAM)** with a standard capacitive stylus and two-finger artist glove into a pro-grade digital canvas paired with a **Windows PC** over local Wi-Fi.

By streaming lightweight vector deltas and camera matrices over the local network, the tablet maintains a locked $60\text{ FPS}$ touch response under strict memory ceilings while offloading real-time anti-aliased OpenGL viewport mirroring, massive scene-graph storage, and ultra-high-resolution ($300\text{--}1200\text{ DPI}$) raster/vector exports to the desktop PC.

### Core Architectural Pillars
1. **Dual-Frame Vector & Transform Streaming:**
   * **Binary Live-Pen & Camera Frames (`16 Bytes` Fixed):** Streams in-flight stylus coordinates (`x, y, pressure`) and live pinch-to-zoom/pan camera matrices (`scale, tx, ty`) at $60\text{ Hz}$ with $< 4\text{ ms}$ LAN latency so the PC monitor mirrors every stroke in real time.
   * **WebSocket JSON RPC Envelope:** Handles committed cubic Bézier stroke objects, graph/shape primitives, binary-chunked image attachments, canvas size upgrades, and PC-offloaded export jobs.
2. **2GB-RAM Survival Engine on Flutter (Spatial Tiling & Picture Caching):**
   * Partitions the infinite world coordinate space into $1024 \times 1024$ unit spatial chunks indexed by an R-Tree.
   * Bakes static strokes into GPU-cached `ui.Picture` tiles and renders only the active in-flight stroke on an isolated top-level foreground canvas, preventing quadratic redraw slowdown on the Exynos 7870 GPU.
3. **Pure Python Modern OpenGL Viewport & Offloaded Ultra-High-Res Export (PC Agent):**
   * Embeds a hardware-accelerated `moderngl` / `pyglet` OpenGL 3.3+ viewport directly inside a modern dark-mode `CustomTkinter` shell, rendering anti-aliased spline tessellations and alpha-blended highlighters at native desktop monitor refresh rates.
   * Executes tile-chunked `pycairo` and `reportlab` background workers on the PC to export massive infinite canvases to lossless Vector PDFs or multi-megapixel PNG/JPG files without risking `OutOfMemoryError` crashes on the tablet.
4. **Unified Infinite & Bounded Artboard Model with Non-Destructive Upgrades:**
   * Treats all canvases internally as infinite 2D world spaces while enforcing optional **A5**, **A4**, and **Letter** page boundaries.
   * Supports upgrading smaller canvases to larger presets or Infinite scale at any time, while mathematically blocking downsizing transitions if the target artboard rectangle would clip existing `contentBounds`.

---

## 2. Multi-Agent Parallel Execution Strategy

This project is decomposed into **28 isolated micro-documents**. To maximize token throughput and allow the **Main Orchestrator Agent** to spawn **5 to 6 Subagents in parallel** without file-lock conflicts or circular dependency breakages, the architecture enforces three rules:

1. **Contract-First Freeze:** The 16-byte binary live-stream frame, WebSocket JSON RPC schemas, and the `.slatesync` Canvas Document schema are locked in Phase 0 (`02_vector_stream_protocol_spec.md` and `03_canvas_document_schema_spec.md`). Once locked, Python PC Subagents and Dart Flutter Subagents build in $100\%$ parallel.
2. **Strict File-Per-Micro-Doc Ownership:** Every micro-document maps to a dedicated file or isolated module path. Two concurrent subagents will **never** edit the same file in the same wave.
3. **3-Session Execution Cadence:**
   * **Session 1 (Foundation, Core Spatial Engines & Network Transport):** Scaffolding + 2 parallel waves of 5–6 subagents building the wire protocols, PC OpenGL viewport core, R-Tree spatial scene graph, and Flutter tiled canvas engine.
   * **Session 2 (Drawing Toolsets, Artboard Upgrader, High-Res Exporters & Desktop GUI):** 2 parallel waves of 5–6 subagents building all drawing tools (pens, highlighters, graphs, shapes, images), canvas gallery, PC `CustomTkinter` studio window, and the tiled PNG/JPG/PDF export engines.
   * **Session 3 (System Tray, PyInstaller, InnoSetup & E2E QA):** 1 parallel wave of 5 subagents wiring the root entry points, compiling the standalone Windows installer (`SlateSync_Setup.exe`), building the release Android APK, and running E2E memory and latency benchmarks.

---

## 3. Monorepo Directory Blueprint

All subagents must strictly adhere to this directory tree:

```text
slatesync/
├── docs/
│   ├── overview.md
│   └── micro/                                      # All 28 micro-documents live here
├── shared_specs/
│   ├── binary_stream_frame.json                    # Doc 02 (16-byte live stroke/camera layout)
│   ├── ws_rpc_schema.json                          # Doc 02 (WebSocket JSON RPC contract)
│   └── canvas_document_schema.json                 # Doc 03 (Artboards, nodes, upgrade rules)
├── pc_agent/                                       # Python 3.11+ Windows Desktop Studio & Server
│   ├── main.py                                     # Entry point & async/GUI lifecycle coordinator
│   ├── requirements.txt                            # Doc 04
│   ├── core/
│   │   └── config_manager.py                       # Doc 04
│   ├── viewport/
│   │   ├── gl_canvas_host.py                       # Doc 06 (ModernGL / Pyglet embedded frame)
│   │   ├── stroke_tessellator.py                   # Doc 07 (GLSL spline & highlighter shaders)
│   │   └── primitive_renderer.py                   # Doc 08 (Graphs, shapes, images, artboards)
│   ├── engine/
│   │   ├── scene_graph.py                          # Doc 09 (Spatial R-Tree & bounds validator)
│   │   └── document_store.py                       # Doc 10 (.slatesync persistence & assets)
│   ├── network/
│   │   ├── ws_stream_server.py                     # Doc 11 (Binary + JSON WebSocket server)
│   │   └── discovery_pairing.py                    # Doc 12 (Zeroconf mDNS & QR generator)
│   ├── export/
│   │   ├── tiled_raster_exporter.py                # Doc 13 (PyCairo 600+ DPI PNG/JPG tiler)
│   │   ├── vector_pdf_exporter.py                  # Doc 14 (ReportLab/Cairo infinite PDF)
│   │   └── export_coordinator.py                   # Doc 15 (Async export job & progress bus)
│   ├── gui/
│   │   ├── studio_window.py                        # Doc 16 (CustomTkinter main shell & HUD)
│   │   └── tray_daemon.py                          # Doc 17 (pystray background agent)
│   └── installer/
│       ├── slatesync_agent.spec                    # Doc 18 (PyInstaller --onedir spec)
│       └── setup.iss                               # Doc 19 (InnoSetup installer & firewall)
└── mobile_app/                                     # Flutter 3.x (Dart) Tablet Client
    ├── pubspec.yaml                                # Doc 05
    └── lib/
        ├── main.dart
        ├── core/
        │   ├── theme/studio_theme.dart             # Doc 05
        │   └── storage/local_db.dart               # Doc 26 (SQLite canvas index)
        ├── canvas_engine/
        │   ├── camera_controller.dart              # Doc 20 (2D affine matrix & pinch/pan)
        │   ├── stroke_processor.dart               # Doc 21 (Palm guard & Bézier decimator)
        │   ├── tiled_canvas_painter.dart           # Doc 22 (1024x1024 Picture cache & R-Tree)
        │   └── artboard_manager.dart               # Doc 23 (A5/A4/Letter/Infinite upgrader)
        ├── network/
        │   └── vector_sync_client.dart             # Doc 25 (Binary/JSON WS & mDNS/QR client)
        └── features/
            ├── home/
            │   └── canvas_gallery_screen.dart      # Doc 26 (Home notebooks & size selector)
            ├── tools/
            │   └── tool_palette_dock.dart          # Doc 24 (Pen, Highlighter, Graph, Shapes, Img)
            └── export/
                └── export_modal_sheet.dart         # Doc 27 (High-res PNG/JPG/PDF export UI)
```

---

## 4. Shared Wire Protocol & Document Schemas (Single Source of Truth)

All micro-documents must adhere to these exact wire and storage formats:

### 4.1 Binary WebSocket Frame (`16 Bytes` Fixed Length, Little-Endian `<BBHfff`)
Used for zero-allocation $60\text{ Hz}$ real-time streaming of active in-flight stylus motion and live camera pan/zoom matrices:
* `Byte 0` (`uint8`): **Frame Type**
  * `0x01`: Live Stylus Point (`f1 = world_x`, `f2 = world_y`, `f3 = width_pressure_factor`)
  * `0x02`: Live Stylus End / Flush (`f1 = 0.0`, `f2 = 0.0`, `f3 = 0.0`)
  * `0x03`: Live Camera Transform Matrix (`f1 = scale_zoom`, `f2 = translate_x`, `f3 = translate_y`)
  * `0x04`: Live Laser / Hover Pointer (`f1 = world_x`, `f2 = world_y`, `f3 = 0.0`)
* `Byte 1` (`uint8`): **Active Tool & Blend ID** (`0x01`: Pen, `0x02`: Highlighter, `0x03`: Eraser, `0x04`: Line/Shape Preview)
* `Bytes 2–3` (`uint16`): **Sequence Counter** (Monotonic counter for frame ordering)
* `Bytes 4–7` (`float32`): **Float Arg 1** (`world_x` or `scale_zoom`)
* `Bytes 8–11` (`float32`): **Float Arg 2** (`world_y` or `translate_x`)
* `Bytes 12–15` (`float32`): **Float Arg 3** (`width_pressure_factor` or `translate_y`)

### 4.2 WebSocket JSON RPC Envelope
Used for reliable state mutations, committed strokes, graph/shape creation, canvas resizing, and export orchestration:
```json
{
  "id": "uuid-v4",
  "type": "CANVAS_LIFECYCLE | ELEMENT_COMMIT | ARTBOARD_RESIZE | ASSET_UPLOAD | EXPORT_JOB",
  "action": "OPEN_CANVAS | ADD_STROKE | ADD_GRAPH | ADD_SHAPE | ADD_IMAGE | DELETE_NODE | UPGRADE_SIZE | START_EXPORT | EXPORT_PROGRESS",
  "canvas_id": "canvas-uuid-v4",
  "payload": {},
  "timestamp": 1760760000
}
```

### 4.3 Canvas Document & Artboard Schema (`canvas_document_schema.json`)
Defines page presets (at $300\text{ DPI}$ world-unit baseline) and vector elements:
```json
{
  "canvas_id": "canvas-uuid-v4",
  "title": "Control Systems Lecture 04",
  "created_at": 1760760000,
  "updated_at": 1760763600,
  "artboard": {
    "preset": "A5 | A4 | LETTER | INFINITE",
    "width": 2480.0,
    "height": 3508.0,
    "is_infinite": false,
    "background_style": "BLANK | RULED | DOT_GRID | ISO_GRID",
    "background_color": "#FFFFFF"
  },
  "content_bounds": {
    "min_x": 112.4,
    "min_y": 85.0,
    "max_x": 2140.8,
    "max_y": 3190.2
  },
  "elements": [
    {
      "node_id": "node-uuid-1",
      "kind": "STROKE | HIGHLIGHT | LINE | SHAPE | GRAPH_AXES | IMAGE",
      "layer": 0,
      "bbox": [120.0, 300.0, 450.0, 620.0],
      "style": {
        "color": "#1E1E1E",
        "stroke_width": 2.5,
        "opacity": 1.0,
        "blend_mode": "SRC_OVER | MULTIPLY"
      },
      "geometry": {
        "pts": [[120.4, 301.2], [124.8, 309.5], [131.0, 318.0]],
        "shape_type": "RECT | CIRCLE | TRIANGLE | ARROW | CARTESIAN_2D | NUMBER_LINE",
        "graph_config": {
          "origin": [250.0, 450.0],
          "x_range": [-10, 10],
          "y_range": [-10, 10],
          "grid_step": 25.0,
          "show_labels": true
        },
        "asset_ref": "assets/img_9921.png"
      }
    }
  ]
}
```

### 4.4 Artboard Size Matrix & Non-Destructive Upgrade Rules
* **A5 Preset:** $1748 \times 2480$ world units (Origin centered at $[0, 0]$ or top-left $[0, 0 \to 1748, 2480]$)
* **A4 Preset:** $2480 \times 3508$ world units
* **Letter Preset:** $2550 \times 3300$ world units
* **Infinite Preset:** Unbounded ($-\infty$ to $+\infty$ on both axes)
* **Validation Rule:** Changing `artboard.preset` to `TARGET` is permitted if and only if `TARGET == INFINITE` OR (`content_bounds.min_x >= 0` AND `content_bounds.min_y >= 0` AND `content_bounds.max_x <= TARGET.width` AND `content_bounds.max_y <= TARGET.height`).

---

## 5. Catalog of Micro-Documents (28 Docs)

Your specialized Doc-Generator Agents will generate the following 28 files inside `docs/micro/`:

### Category A: Foundation, Contracts & Scaffolding
1. `01_monorepo_structure.md` — Defines the root directory tree, `.gitignore`, `shared_specs/` JSON validation rules, and Python/Dart linting configurations.
2. `02_vector_stream_protocol_spec.md` — Specifies the 16-byte `<BBHfff` binary WebSocket frame layout for $60\text{ Hz}$ pen/camera mirroring and the JSON RPC command schemas.
3. `03_canvas_document_schema_spec.md` — Defines the `.slatesync` document model, A5/A4/Letter/Infinite coordinate bounds, `content_bounds` recalculation rules, and non-cropping size transition matrix.
4. `04_pc_agent_boilerplate_deps.md` — Scaffolds `pc_agent/`, `requirements.txt` (`customtkinter`, `moderngl`, `pyglet`, `pycairo`, `reportlab`, `Pillow`, `websockets`, `zeroconf`, `qrcode`, `pystray`, `rtree`), and `config_manager.py`.
5. `05_flutter_app_boilerplate_deps.md` — Scaffolds `mobile_app/`, `pubspec.yaml` (`flutter_riverpod`, `web_socket_channel`, `multicast_dns`, `mobile_scanner`, `sqflite`, `path_provider`, `image_picker`, `pdf`), and `studio_theme.dart`.

### Category B: PC Agent — OpenGL Viewport & Vector Rendering Engine
6. `06_pc_opengl_embedded_viewport.md` — Embeds a hardware-accelerated OpenGL 3.3+ context (`moderngl` / `pyglet`) inside a `CustomTkinter` frame with MSAA $4\times$ anti-aliasing and camera matrix uniform bindings.
7. `07_pc_shader_stroke_tessellator.md` — Implements GLSL vertex/geometry/fragment shaders that tessellate incoming Catmull-Rom / cubic Bézier point arrays into smooth variable-width triangle strips with multiply-blend highlighter support.
8. `08_pc_graph_shape_image_renderer.md` — Renders procedural background grids (ruled, dot, isometric), Cartesian/number-line graph axes with tick marks, geometric shapes, texture-mapped image attachments, and A5/A4/Letter page boundary drop-shadows in OpenGL.
9. `09_pc_spatial_rtree_scene_graph.md` — Maintains the authoritative PC-side spatial R-Tree index for instant frustum culling, undo/redo command stacks, global `content_bounds` tracking, and artboard resize validation.
10. `10_pc_canvas_persistence_store.md` — Serializes and loads `.slatesync` project archives (JSON scene graph + binary image attachments) on the PC disk with background auto-save every $10\text{ seconds}$.

### Category C: PC Agent — Networking, Discovery & Ultra-High-Res Export Engine
11. `11_pc_websocket_stream_server.md` — Implements the async WebSocket server on port `50606` with dual-path routing: zero-copy struct unpacking for 16-byte binary frames and async dispatching for JSON RPC envelopes.
12. `12_pc_mdns_qr_pairing_service.md` — Broadcasts `_slatesync._tcp.local.` via `zeroconf` for zero-config discovery and generates a pairing QR code containing LAN IPv4 addresses, port, and session token.
13. `13_pc_tiled_highres_raster_exporter.md` — Implements the offloaded `pycairo` tile-stepping rasterizer capable of exporting bounded or massive infinite canvases to PNG and JPG at $300$, $600$, or $1200\text{ DPI}$ by rendering $2048 \times 2048$ strips directly to disk without exhausting RAM.
14. `14_pc_vector_pdf_exporter.md` — Generates resolution-independent vector PDF files via `pycairo`/`reportlab` so infinite canvases can be zoomed to $6400\%$ in any PDF viewer with razor-sharp vector curves and text labels.
15. `15_pc_export_stream_coordinator.md` — Manages an async worker pool for export jobs triggered by the tablet or PC, streaming live progress (`0%`–`100%`) over WebSocket and optionally pushing the finished file back to the tablet or opening it in Windows Explorer.

### Category D: PC Agent — CustomTkinter GUI, System Tray & InnoSetup Packaging
16. `16_pc_customtkinter_studio_window.md` — Builds the modern dark-mode `CustomTkinter` desktop window featuring the embedded OpenGL mirror viewport, live connection badge, current zoom/artboard indicator, QR pairing dialog, and one-click Export bar.
17. `17_pc_pystray_background_daemon.md` — Integrates `pystray` so the PC agent can run silently in the Windows System Tray and automatically bring the mirror viewport to the foreground when the stylus touches the tablet.
18. `18_pc_pyinstaller_onedir_spec.md` — Configures `slatesync_agent.spec` for PyInstaller (`--onedir --noconsole`), packaging GLSL shader files, native Cairo shared libraries, and `CustomTkinter` assets.
19. `19_pc_innosetup_installer_script.md` — Provides the `setup.iss` InnoSetup installer script that packages `dist/SlateSyncAgent/`, registers `.slatesync` file icons, injects Windows Firewall rules (`netsh advfirewall`) for port `50606`, and creates shortcuts.

### Category E: Flutter App — Memory-Safe Infinite Canvas & Spatial Engine
20. `20_flutter_world_camera_matrix.md` — Implements the 2D affine `Matrix4` camera controller supporting two-finger pinch-to-zoom ($0.05\times$ to $20.0\times$), two-finger pan, zoom-to-fit artboard, and $60\text{ Hz}$ binary camera sync frames.
21. `21_flutter_bezier_stroke_decimator.md` — Captures raw stylus `Listener` pointer events, applies contact-major-axis palm rejection fallback heuristics, filters jitter via $2.0\text{ dp}$ distance decimation, and fits continuous cubic Bézier splines.
22. `22_flutter_tiled_picture_cache_engine.md` — Implements the $2\text{ GB}$-RAM-safe dual-canvas renderer: partitions world space into $1024 \times 1024$ tiles backed by a spatial R-Tree, caches static tiles as `ui.Picture`, and isolates active pen strokes on a zero-lag foreground `CustomPainter`.
23. `23_flutter_artboard_bounds_upgrader.md` — Renders A5, A4, Letter, and Infinite canvas boundaries on the tablet, tracks real-time `content_bounds`, and enforces the non-cropping size upgrade/change rules with visual warning overlays.

### Category F: Flutter App — Drawing Tools, Home Gallery & PC Sync Client
24. `24_flutter_drawing_toolset_palette.md` — Builds the floating, collapsible tool dock: Pressure/Velocity Pen, Multiply Highlighter, Precision/Stroke Eraser, Snapping Line & Geometric Shapes (Rect, Circle, Arrow), Configurable Graph Builder (2D Cartesian Axes, Polar, Grids), and Image Attachment importer/transformer.
25. `25_flutter_ws_vector_sync_client.md` — Implements the Dart WebSocket synchronization engine with `ByteData` binary frame packing, offline stroke queue buffering, mDNS auto-discovery, and QR pairing scanner (`mobile_scanner`).
26. `26_flutter_home_canvas_dashboard.md` — Builds the Home screen notebook gallery (`sqflite` + local `.slatesync` cache), New Canvas creation modal (selecting A5, A4, Letter, or Infinite + paper grid template), and Canvas Upgrade dialog.
27. `27_flutter_highres_export_sheet.md` — Builds the Export bottom sheet allowing the user to select format (`PNG`, `JPG`, `PDF`), resolution (`300 DPI`, `600 DPI`, `1200 DPI`), and target (`Save to PC`, `Save to Tablet`, `Both`) with live progress telemetry from the PC agent.

### Category G: End-to-End Integration, Latency & Memory QA
28. `28_e2e_sync_latency_and_memory_qa.md` — Defines the automated E2E verification harness benchmarking $< 8\text{ ms}$ stylus-to-OpenGL-mirror latency, verifying $< 180\text{ MB}$ Flutter heap usage at $10,000$ vector strokes, testing A5 $\to$ A4 $\to$ Infinite upgrade rules, and validating $600\text{ DPI}$ infinite canvas exports.

---

## 6. Parallel Session Execution Plan (5–6 Subagents per Wave)

Because the Main Orchestrator Agent can spawn **5 to 6 Subagents concurrently**, the implementation is organized into **3 Macro Sessions** (with 2 parallel waves in Sessions 1 and 2, and 1 final wave in Session 3).

### Pre-Session Phase: Micro-Document Generation
Before coding begins, your **Doc-Generator Agents** generate all 28 micro-documents in `docs/micro/` in batches using the exact specifications in Sections 4 and 5.

---

### SESSION 1: Foundation, Core Spatial Engines & Network Transport
**Goal:** Lock the binary/JSON wire contracts, initialize the monorepo, and build the PC OpenGL viewport core, R-Tree scene graph, WebSocket streaming pipe, and Flutter $2\text{ GB}$-RAM-safe tiled canvas engine in parallel.

#### Wave 1.A — Scaffolding & Protocol Lock (3 Subagents in Parallel)
* **Subagent 1 (Specs & Monorepo):** Executes `01_monorepo_structure.md` + `02_vector_stream_protocol_spec.md` + `03_canvas_document_schema_spec.md`
* **Subagent 2 (PC Boilerplate):** Executes `04_pc_agent_boilerplate_deps.md`
* **Subagent 3 (Flutter Boilerplate):** Executes `05_flutter_app_boilerplate_deps.md`
*(Barrier Sync: Wait for Wave 1.A to finish so `shared_specs/*.json` and package dependencies exist.)*

#### Wave 1.B — Core OpenGL Viewport, Spatial Engines & Networking (6 Subagents in Parallel)
* **Subagent 1 (PC OpenGL Host & Shaders):** Executes `06_pc_opengl_embedded_viewport.md` + `07_pc_shader_stroke_tessellator.md`
* **Subagent 2 (PC Scene Graph & Storage):** Executes `09_pc_spatial_rtree_scene_graph.md` + `10_pc_canvas_persistence_store.md`
* **Subagent 3 (PC WebSocket & Discovery):** Executes `11_pc_websocket_stream_server.md` + `12_pc_mdns_qr_pairing_service.md`
* **Subagent 4 (Flutter Camera & Stroke Math):** Executes `20_flutter_world_camera_matrix.md` + `21_flutter_bezier_stroke_decimator.md`
* **Subagent 5 (Flutter Tiled Cache & Artboards):** Executes `22_flutter_tiled_picture_cache_engine.md` + `23_flutter_artboard_bounds_upgrader.md`
* **Subagent 6 (Flutter Vector Sync Client):** Executes `25_flutter_ws_vector_sync_client.md`

---

### SESSION 2: Drawing Toolsets, High-Res Exporters & Desktop Studio GUI
**Goal:** Build all rich drawing tools (pens, highlighters, graphs, shapes, images), the PC `CustomTkinter` studio shell, the offloaded $600+\text{ DPI}$ raster/vector export engines, and the Flutter home gallery and export UI.

#### Wave 2.A — Primitives, Exporters & Tooling Surfaces (5 Subagents in Parallel)
* **Subagent 1 (PC Graph, Shape & Image OpenGL Renderer):** Executes `08_pc_graph_shape_image_renderer.md`
* **Subagent 2 (PC Tiled Raster & Vector PDF Exporters):** Executes `13_pc_tiled_highres_raster_exporter.md` + `14_pc_vector_pdf_exporter.md`
* **Subagent 3 (PC Export Coordinator):** Executes `15_pc_export_stream_coordinator.md`
* **Subagent 4 (Flutter Toolset Dock):** Executes `24_flutter_drawing_toolset_palette.md`
* **Subagent 5 (Flutter Home Gallery & SQLite):** Executes `26_flutter_home_canvas_dashboard.md`

#### Wave 2.B — Desktop GUI Shell, Tray Daemon & Mobile Export Sheet (3 Subagents in Parallel)
* **Subagent 1 (PC CustomTkinter Studio Window):** Executes `16_pc_customtkinter_studio_window.md`
* **Subagent 2 (PC System Tray Daemon):** Executes `17_pc_pystray_background_daemon.md`
* **Subagent 3 (Flutter High-Res Export Modal):** Executes `27_flutter_highres_export_sheet.md`

---

### SESSION 3: Final Wiring, Installer Packaging & E2E Verification
**Goal:** Wire `pc_agent/main.py` and `mobile_app/lib/main.dart`, package the PC agent via PyInstaller (`--onedir`) and InnoSetup (`SlateSync_Setup.exe`), build the production Android APK, and run E2E latency and memory benchmarks.

#### Wave 3.A — Master Wiring, Packaging & QA Suite (4 Subagents in Parallel)
* **Subagent 1 (PC Master Wiring & PyInstaller):** Wires `pc_agent/main.py` connecting the `CustomTkinter` window, embedded OpenGL viewport, WebSocket server, and tray daemon; executes `18_pc_pyinstaller_onedir_spec.md`.
* **Subagent 2 (InnoSetup Windows Installer):** Executes `19_pc_innosetup_installer_script.md` and compiles `SlateSync_Setup.exe` via `ISCC.exe`.
* **Subagent 3 (Flutter Master Shell & APK Build):** Wires `mobile_app/lib/main.dart` connecting the Home Canvas Gallery, Infinite Canvas Studio, Tool Dock, and Export Sheet; runs `flutter analyze` and `flutter build apk --release`.
* **Subagent 4 (E2E Latency, Memory & Export QA):** Executes `28_e2e_sync_latency_and_memory_qa.md`.

---

## 7. Master Roadmap & Agent Progress Tracker

The Main Orchestrator Agent must update this checklist as each phase and wave completes:

### Phase 0: Micro-Document Generation
- [ ] **Batch 1 (Docs 01–07):** Monorepo, Binary/JSON Contracts, Document Schema, Boilerplates & PC OpenGL Shader Core generated.
- [ ] **Batch 2 (Docs 08–15):** PC Graph/Shape Renderer, R-Tree Scene Graph, WebSocket Server, mDNS/QR & High-Res Exporters generated.
- [ ] **Batch 3 (Docs 16–22):** PC CustomTkinter Studio UI, Tray Daemon, PyInstaller/InnoSetup & Flutter Tiled Canvas Core generated.
- [ ] **Batch 4 (Docs 23–28):** Flutter Artboard Upgrader, Drawing Toolset, Sync Client, Home Gallery, Export UI & E2E QA Suite generated.

### Phase 1: Session 1 Execution (Core Spatial Engine & Real-Time Transport)
- [ ] **Wave 1.A Complete:** Monorepo structure, `shared_specs/*.json`, Python venv, and Flutter project initialized.
- [ ] **Wave 1.B Complete (PC):** Embedded OpenGL viewport, GLSL spline tessellator, R-Tree scene graph, `.slatesync` store, and port `50606` WebSocket server operational.
- [ ] **Wave 1.B Complete (Mobile):** Affine camera matrix controller, cubic Bézier decimator, $1024 \times 1024$ `ui.Picture` tile cache, artboard bounds manager, and WebSocket sync client operational.
- [ ] **Session 1 Milestone Check:** Drawing a stroke on the tablet streams 16-byte binary frames and renders an anti-aliased OpenGL spline on the PC screen in $< 8\text{ ms}$.

### Phase 2: Session 2 Execution (Tools, Artboards, Exporters & Studio GUI)
- [ ] **Wave 2.A Complete:** OpenGL graph/shape/image rendering, `pycairo` tiled PNG/JPG exporter, `reportlab` vector PDF exporter, Flutter tool dock, and Home Canvas Gallery built.
- [ ] **Wave 2.B Complete:** `CustomTkinter` desktop studio window, `pystray` daemon, and Flutter high-res export sheet built.
- [ ] **Session 2 Milestone Check:** Upgrading an A5 canvas to A4 and Infinite succeeds non-destructively; downsizing an Infinite canvas with out-of-bounds strokes is blocked cleanly; all modules pass `pytest` and `flutter analyze`.

### Phase 3: Session 3 Execution (Integration, InnoSetup & Release)
- [ ] **PC Agent Bundled:** `pyinstaller slatesync_agent.spec` produces a clean, console-free `dist/SlateSyncAgent/` directory bundle with OpenGL shaders and Cairo DLLs.
- [ ] **InnoSetup Compiled:** `ISCC.exe pc_agent/installer/setup.iss` produces `SlateSync_Setup.exe` with automatic Windows Firewall rule registration.
- [ ] **Flutter APK Built:** `flutter build apk --release` produces the production Android APK optimized for the SM-T580 (ARMv8 / 64-bit or ARMv7).
- [ ] **E2E Benchmark Passed:** Verified $60\text{ FPS}$ rendering on the $2\text{ GB}$ RAM tablet at $10,000$ strokes, $< 8\text{ ms}$ PC OpenGL mirror latency, and lossless $600\text{ DPI}$ infinite canvas export.