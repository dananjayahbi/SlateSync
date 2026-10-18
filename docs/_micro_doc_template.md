# SlateSync Micro-Document Template & Shared Contract Freeze

*Phase 0 support file — NOT one of the 28 micro-documents. Owned by the Main Orchestrator. Doc-Generator subagents: **READ ONLY**. Implementation subagents: read Section 4–5 before coding any module.*

---

## 1. Required Section Structure (every `docs/micro/NN_*.md`)

```markdown
# Doc NN: <Title>

## 1. Objective & Scope
## 2. File Ownership
### Creates (implementation subagent writes these paths)
### Read-only dependencies (imports, each cited as "Doc NN")
### Never touches (paths owned by concurrent docs — write-conflict guard)
## 3. Contract References
## 4. Interface Freeze
## 5. Implementation Plan
## 6. Testing & Acceptance Criteria
## 7. Parallel Execution Notes
```

* **Section 2 "Creates"** must match the ownership matrix in Section 6 of this template EXACTLY.
* **Section 4** must reproduce, verbatim, every interface from Sections 4–5 of this template that this doc exports or consumes, then add doc-specific API.
* **Section 5** = numbered steps, each producing one small component. Max ~20 illustrative lines per step. Prefer signatures, formulas, tables, JSON fragments, bullets. **No lengthy code.**
* **Section 7** = wave assignment from Section 6 + explicit no-overlap confirmation.
* Length target: **120–200 lines per doc.** Relative repo paths only. No README/extra files.

---

## 2. Global Writing Rules

1. Follow `overview.md` §3 tree EXACTLY (plus `qa/`, `viewport/shaders/`, `core/protocol.py`, `core/events.py`, `core/models/canvas_models.dart` as amended).
2. All numbers must match Section 3 below and `overview.md` §4 **verbatim**.
3. Cite sibling micro-docs by number (`Doc 09`, `Doc 25` …) at every cross-module reference.
4. Modular & component-based: a doc specifies small classes/functions, never monolithic listings.
5. Tests: each implementation doc owns `pc_agent/tests/test_<module>.py` (pytest) or `mobile_app/test/<feature>_test.dart` (flutter test) as listed in Section 6.
6. Python 3.11+, type-hinted signatures. Dart/Flutter 3.x, sound null safety.
7. Wave assignment comes from Section 6; two docs in the same wave must have **zero** overlapping "Creates" paths.

---

## 3. Master Constants (copy exactly — single source of truth)

| Key | Value |
|---|---|
| WebSocket port | `50606`, path `/ws`, token URL `ws://<ipv4>:50606/ws?token=<session_token>`, close code `4001` |
| mDNS service | `_slatesync._tcp.local.`, name `SlateSync`, TXT `{v:"1", token:<session_token>}` |
| Binary frame | 16 bytes little-endian `struct "<BBHfff"` (byte0 frame_type, byte1 tool_id, bytes2–3 u16 seq, then f1,f2,f3 float32) |
| FrameType | `0x01` LIVE_POINT (f1=x, f2=y, f3=width_pressure_factor), `0x02` LIVE_END (all 0.0), `0x03` CAMERA (f1=scale, f2=tx, f3=ty), `0x04` LASER (f1=x, f2=y, f3=0.0) |
| ToolId | `0x01` Pen, `0x02` Highlighter, `0x03` Eraser, `0x04` Line/Shape Preview |
| Seq rule | u16 **single per-connection counter shared by ALL frame types** (client increments once per frame sent); receivers keep one `last_seq` per connection and drop frames whose seq is not newer (mod 2^16 window) |
| RPC envelope | `overview.md` §4.2 incl. actions `OPEN_CANVAS, ADD_STROKE, ADD_GRAPH, ADD_SHAPE, ADD_IMAGE, DELETE_NODE, UPGRADE_SIZE, START_EXPORT, CANCEL_EXPORT, EXPORT_PROGRESS, EXPORT_FINISHED, ASSET_START, ASSET_CHUNK, ASSET_DONE`; types `CANVAS_LIFECYCLE, ELEMENT_COMMIT, ARTBOARD_RESIZE, ASSET_UPLOAD, EXPORT_JOB` |
| Asset chunks | `data_b64` ≤ `262144` bytes raw per chunk; fields `transfer_id, filename, total_chunks, size_bytes, index, data_b64` (`transfer_id` required on START, CHUNK and DONE for correlation) |
| Artboard presets (300 DPI world units, **top-left origin (0,0)→(w,h)**) | A5 `1748×2480`, A4 `2480×3508`, Letter `2550×3300`, INFINITE unbounded |
| Upgrade rule (§4.4) | allow iff `target==INFINITE` OR (`min_x>=0 AND min_y>=0 AND max_x<=target.w AND max_y<=target.h`) |
| Camera transform (Dart AND Python use identically) | `screen = (world − camera_center) * scale + viewport/2` (tx,ty = world coord at viewport center); live camera frame f1=scale, f2=tx, f3=ty |
| Zoom range | `0.05× … 20.0×` |
| Flutter tiles | `1024×1024` world units, `TileKey(tx=floor(x/1024), ty=floor(y/1024))`, LRU Picture cache ≤ ~120 MB |
| Export strips | `2048×2048` px; px = `world_units * dpi / 300`; PDF points = `world_units * 72 / 300` |
| DPI choices | `300, 600, 1200` (PNG/JPG); PDF is vector |
| Stroke decimation | `2.0 dp` min distance + jitter low-pass |
| Autosave | every `10 s` when dirty |
| Backgrounds | `BLANK, RULED, DOT_GRID, ISO_GRID` |
| Blend modes | `SRC_OVER`, `MULTIPLY` (GL highlighter: `glBlendFunc(GL_DST_COLOR, GL_ZERO)`; cairo: `CAIRO_OPERATOR_MULTIPLY`) |
| E2E gates | stylus→PC-GL p95 `≤ 8 ms`; LAN portion `≤ 4 ms`; tablet `60 FPS` @ `10 000` strokes; Flutter heap `< 180 MB`; `600 DPI` infinite export lossless; PDF vector zoom `6400%` |
| `.slatesync` container | ZIP: `document.json` (Doc 03 schema) + `assets/*` |
| Firewall / installer / smoke | firewall rule name `SlateSync WS` (netsh advfirewall, TCP 50606); installer output `dist/SlateSync_Setup.exe`; PC bundle smoke flag `--smoke` (exit 0) |

---

## 4. Shared PC (Python) Interface Freeze

**Wave 1.A artifacts (Docs 04) — consume, never redefine:**

```python
# pc_agent/core/config_manager.py (Doc 04)
@dataclass(frozen=True)
class AppConfig:
    ws_port: int = 50606
    mdns_service_type: str = "_slatesync._tcp.local."
    mdns_service_name: str = "SlateSync"
    autosave_interval_s: float = 10.0
    shader_dir: Path          # pc_agent/viewport/shaders
    assets_dir: Path          # %APPDATA%/SlateSync/assets
    export_dir: Path          # %APPDATA%/SlateSync/exports
    appdata_dir: Path         # %APPDATA%/SlateSync
    log_level: str = "INFO"
class ConfigManager:
    def __init__(self, root_dir: Path | None = None) -> None: ...
    @property
    def config(self) -> AppConfig: ...
    def load(self) -> None: ...      # reads %APPDATA%/SlateSync/config.json
    def save(self) -> None: ...

# pc_agent/core/events.py (Doc 04)
class EventBus:                      # synchronous emit on the CALLER'S thread
    def on(self, event: str, handler: Callable[..., None]) -> None: ...
    def off(self, event: str, handler: Callable[..., None]) -> None: ...
    def emit(self, event: str, **payload) -> None: ...
# Event name constants (same module):
# "LIVE_FRAME" "CAMERA_DELTA" "RPC_MESSAGE" "CONNECTION_STATE" "DOCUMENT_LOADED"
# "COMMITTED_NODE" "ARTBOARD_CHANGED" "EXPORT_STARTED" "EXPORT_PROGRESS"
# "EXPORT_FINISHED" "PAIRING_INFO"

# pc_agent/core/protocol.py (Doc 04 — mirrors Doc 02; import, never re-declare)
FRAME_LIVE_POINT, FRAME_LIVE_END, FRAME_CAMERA, FRAME_LASER = 0x01, 0x02, 0x03, 0x04
TOOL_PEN, TOOL_HIGHLIGHTER, TOOL_ERASER, TOOL_SHAPE_PREVIEW = 0x01, 0x02, 0x03, 0x04
@dataclass(frozen=True)
class LiveFrame:
    frame_type: int; tool_id: int; seq: int
    f1: float; f2: float; f3: float
def pack_live_frame(frame: LiveFrame) -> bytes: ...    # "<BBHfff", exactly 16 bytes
def unpack_live_frame(data: bytes | memoryview) -> LiveFrame: ...
```

**Data models (Doc 09 exports / Doc 10 exports):**

```python
# pc_agent/engine/scene_graph.py (Doc 09)
@dataclass
class NodeStyle:
    color: str = "#1E1E1E"; stroke_width: float = 2.5
    opacity: float = 1.0; blend_mode: str = "SRC_OVER"
@dataclass
class NodeGeometry:
    pts: list[list[float]] = field(default_factory=list)
    shape_type: str | None = None            # RECT|CIRCLE|TRIANGLE|ARROW|CARTESIAN_2D|NUMBER_LINE
    graph_config: dict | None = None
    asset_ref: str | None = None
@dataclass
class CanvasNode:
    node_id: str; kind: str                  # STROKE|HIGHLIGHT|LINE|SHAPE|GRAPH_AXES|IMAGE
    layer: int = 0
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    style: NodeStyle = field(default_factory=NodeStyle)
    geometry: NodeGeometry = field(default_factory=NodeGeometry)
class SceneGraph:
    def __init__(self, bus: EventBus) -> None: ...
    def insert(self, node: CanvasNode) -> None: ...
    def delete(self, node_id: str) -> None: ...
    def get(self, node_id: str) -> CanvasNode | None: ...
    def query_bbox(self, min_x, min_y, max_x, max_y) -> list[CanvasNode]: ...
    def content_bounds(self) -> dict[str, float]: ...      # {min_x,min_y,max_x,max_y}
    def apply_rpc(self, msg: dict) -> None: ...            # routes ELEMENT_COMMIT / ARTBOARD_RESIZE
    def validate_artboard_upgrade(self, target_preset: str, target_w: float | None, target_h: float | None) -> bool: ...
    def undo(self) -> bool: ...
    def redo(self) -> bool: ...

# pc_agent/engine/document_store.py (Doc 10)
@dataclass
class Artboard:
    preset: str                               # A5|A4|LETTER|INFINITE
    width: float | None = None; height: float | None = None
    is_infinite: bool = False
    background_style: str = "BLANK"; background_color: str = "#FFFFFF"
@dataclass
class CanvasDocument:
    canvas_id: str; title: str
    created_at: int; updated_at: int
    artboard: Artboard
    content_bounds: dict[str, float]
    elements: list[CanvasNode]
class DocumentStore:
    def __init__(self, bus: EventBus, config: AppConfig, scene_graph: SceneGraph) -> None: ...
    def new(self, preset: str, title: str) -> CanvasDocument: ...
    def open(self, path: Path) -> CanvasDocument: ...       # unzips .slatesync
    def save(self, doc: CanvasDocument, path: Path | None = None) -> Path: ...
    def assets_dir(self, canvas_id: str) -> Path: ...
    def autosave_tick(self) -> None: ...                    # called every 10 s by main.py
```

**Network & services (Docs 11/12):**

```python
class WsStreamServer:                                   # Doc 11
    def __init__(self, bus: EventBus, config: AppConfig,
                 token_provider: Callable[[], str],
                 host: str = "0.0.0.0") -> None: ...
    def start(self) -> None: ...                         # daemon thread + own asyncio loop
    def stop(self) -> None: ...
    @property
    def port(self) -> int: ...
    def broadcast_json(self, msg: dict) -> None: ...     # thread-safe push to all clients
# binary  → unpack_live_frame → emit("CAMERA_DELTA") if 0x03 else emit("LIVE_FRAME", frame=...)
# text    → json envelope      → emit("RPC_MESSAGE", msg=...)
# emits CONNECTION_STATE(connected: bool, peer: str | None)
# bad/missing token → close code 4001

class DiscoveryPairing:                                 # Doc 12
    def __init__(self, bus: EventBus, config: AppConfig) -> None: ...
    def start(self) -> None: ...                         # zeroconf register + QR render
    def stop(self) -> None: ...
    @property
    def session_token(self) -> str: ...
# emits PAIRING_INFO(ipv4: str, port: int, token: str, qr_png_path: str)
# QR payload: slatesync://connect?ip=<ipv4>&port=50606&token=<token>
```

**Viewport (Docs 06/07/08):**

```python
class GLCanvasHost:                                     # Doc 06
    def __init__(self, tk_parent: tk.Misc, config: AppConfig, bus: EventBus) -> None: ...
    def mount(self, parent_widget: tk.Misc) -> None: ... # embeds GL surface in frame
    def submit_live_frame(self, frame: LiveFrame) -> None: ...  # THREAD-SAFE: slot + after()
    def set_document(self, doc: CanvasDocument) -> None: ...
    def set_camera(self, scale: float, tx: float, ty: float) -> None: ...
    def request_redraw(self) -> None: ...                # thread-safe, coalesced
    def resize(self, w: int, h: int) -> None: ...
    def shutdown(self) -> None: ...
class ProgramRegistry:                                  # Doc 06 (generic stem loader)
    def get(self, stem: str) -> "moderngl.Program": ...  # pairs <stem>.vert + <stem>.frag in config.shader_dir
    # stems: "stroke" (Doc 07), "primitive", "grid", "texture" (Doc 08)

class StrokeTessellator:                                # Doc 07
    def __init__(self, ctx) -> None: ...
    def build_stroke(self, points: list[tuple[float, float]],
                     pressure: list[float], width: float) -> "TessellatedMesh": ...
@dataclass
class TessellatedMesh: vao: object; vertex_count: int
                      bbox: tuple[float, float, float, float]

class PrimitiveRenderer:                                # Doc 08
    def __init__(ctx, registry: ProgramRegistry) -> None: ...
    def render(self, nodes: list[CanvasNode], camera: tuple[float, float, float],
               artboard: Artboard, content_bounds: dict[str, float]) -> None: ...
```

**Export (Docs 13/14/15):**

```python
class TiledRasterExporter:                              # Doc 13
    def __init__(self, config: AppConfig) -> None: ...
    def export(self, doc: CanvasDocument, dpi: int, out_path: Path,
               progress: Callable[[float], None] | None = None) -> Path: ...
class VectorPdfExporter:                                # Doc 14
    def __init__(self, config: AppConfig) -> None: ...
    def export(self, doc: CanvasDocument, out_path: Path,
               progress: Callable[[float], None] | None = None) -> Path: ...
class ExportCoordinator:                                # Doc 15
    def __init__(self, bus: EventBus, config: AppConfig,
                 raster: TiledRasterExporter, vector: VectorPdfExporter,
                 push: Callable[[dict], None]) -> None: ...   # push = WsStreamServer.broadcast_json
    def submit(self, job: dict) -> str: ...              # returns job_id; ThreadPoolExecutor(2)
    def cancel(self, job_id: str) -> None: ...
# subscribes RPC_MESSAGE where type=="EXPORT_JOB"; emits EXPORT_STARTED / EXPORT_PROGRESS
# (≤10 Hz + per strip) / EXPORT_FINISHED(job_id, percent, path, ok)
# ASSET_UPLOAD push to tablet built here (chunks ≤262144 raw, base64)
```

**GUI & packaging (Docs 16/17/18/19):**

```python
class StudioWindow:                                     # Doc 16
    def __init__(self, config: AppConfig, bus: EventBus, gl_host: GLCanvasHost,
                 export_submit: Callable[[dict], str]) -> None: ...
    def build(self, parent: tk.Misc) -> None: ...
    def show(self) -> None: ...
    def hide(self) -> None: ...
    def set_connection_state(self, connected: bool, peer: str | None) -> None: ...
    def open_qr_dialog(self) -> None: ...
    def update_hud(self, scale: float, preset: str) -> None: ...
    def on_live_activity(self) -> None: ...              # tray auto-foreground, throttled ≥1 s
class TrayDaemon:                                       # Doc 17
    def __init__(self, on_show: Callable[[], None], on_quit: Callable[[], None]) -> None: ...
    def start(self) -> None: ...                         # pystray loop in daemon thread
    def stop(self) -> None: ...
    def notify(self, title: str, message: str) -> None: ...
```

**Event matrix (who emits / who subscribes):**

| Event | Emitted by | Subscribed by |
|---|---|---|
| `LIVE_FRAME(frame)` | Doc 11 | Docs 06, 17 (auto-foreground, throttled ≥1 s) |
| `CAMERA_DELTA(frame)` | Doc 11 | Doc 06 |
| `RPC_MESSAGE(msg)` | Doc 11 | Docs 09, 10, 15 |
| `CONNECTION_STATE(connected, peer)` | Doc 11 | Doc 16 |
| `DOCUMENT_LOADED(doc)` | Doc 10 | Docs 06, 16 |
| `COMMITTED_NODE(node)` | Doc 09 | Doc 06 |
| `ARTBOARD_CHANGED(artboard, content_bounds)` | Doc 09 | Docs 06, 08, 16 |
| `EXPORT_STARTED / EXPORT_PROGRESS / EXPORT_FINISHED` | Doc 15 | Doc 16 (GUI); tablet receives via `broadcast_json` envelope |
| `PAIRING_INFO(ipv4, port, token, qr_png_path)` | Doc 12 | Doc 16 |

**Threading model (all PC docs):**
* Tk **main thread** owns GUI + **all GL calls** + pyglet event pump (`after(16, tick)` — never `pyglet.app.run()`).
* WS asyncio loop runs in a **daemon thread** (Doc 11); exporters in `ThreadPoolExecutor(2)` (Doc 15); pystray in a daemon thread (Doc 17).
* `EventBus.emit` is synchronous on the caller's thread. **Any Tk/Tk-widget mutation inside a handler must be marshalled with `widget.after(0, ...)`** (GLCanvasHost/StudioWindow do this internally — other modules must do likewise).
* GL embedding (Doc 06): PRIMARY — pyglet `Window(visible=False)` reparented into the Tk frame on Windows via ctypes `user32.SetParent` + `WS_CHILD` styles; MSAA 4× (`gl.Config(sample_buffers=1, sample=4, major_version=3, minor_version=3)`). FALLBACK (documented in Doc 06) — standalone `moderngl` context + FBO → PIL/`ImageTk` blit. No pyglet app loop; manual `switch_to()/dispatch_events()/flip()` from Tk timer.
* Seq stale-drop rule lives in **both** Doc 11 (server receive) and Doc 06 (submit_live_frame latest-slot).

---

## 5. Shared Flutter (Dart) Interface Freeze

**Wave 1.A artifacts (Doc 05) — consume, never redefine:**

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
```

```dart
// lib/core/theme/studio_theme.dart (Doc 05): StudioTheme — dark palette consts, radii, typography
// pubspec.yaml deps (Doc 05): flutter_riverpod, web_socket_channel, multicast_dns,
//   mobile_scanner, sqflite, path_provider, image_picker, pdf, archive, flutter_lints
```

```dart
class CameraSnapshot { final double scale, tx, ty; }            // Doc 20 → live frame f1,f2,f3
class CameraController {                                        // Doc 20
  CameraController({double initialScale = 1.0});
  double scale;                                                  // clamped 0.05..20.0
  CameraSnapshot get snapshot;
  Matrix4 get viewMatrix;
  void onScaleStart(ScaleStartDetails d);
  void onScaleUpdate(ScaleUpdateDetails d, Size viewport);
  Offset worldToScreen(Offset world, Size viewport);             // (world − c)*s + vp/2
  Offset screenToWorld(Offset screen, Size viewport);
  void zoomToFit(Rect bounds, Size viewport);                    // 48-unit padding
  void applyRemote(double scale, double tx, double ty);
  void Function(CameraSnapshot snap)? onCameraChanged;           // 60 Hz sync hook
}

class ProcessedStroke {                                          // Doc 21
  final String nodeId; final String kind;                         // "STROKE" | "HIGHLIGHT"
  final List<List<double>> pts;                                   // world-space Bézier controls
  final List<double> bbox;                                        // [minX,minY,maxX,maxY]
  final String color; final double strokeWidth; final double opacity;
  Map<String, dynamic> toRpcPayload();                            // matches §4.3 element JSON
}
class PalmGuard {                                                 // Doc 21
  bool shouldReject(PointerEvent e, {double minorAxisDp = 18.0});
}
class StrokeProcessor {                                           // Doc 21
  StrokeProcessor({required Offset Function(Offset) toWorld,
                   required String color, required double width,
                   required bool highlighter});
  void addPoint(Offset screenPos, double? pressure, int pointer);
  List<Offset> get livePoints;
  bool get rejecting;                                             // palm currently active
  ProcessedStroke? finish();                                      // decimate 2.0 dp + fit Bézier
}

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

class UpgradeResult { final bool allowed; final String? reasonKey; }  // Doc 23
class ArtboardManager {                                           // Doc 23
  Artboard get current; Rect get contentBounds; bool get isInfinite;
  void noteContent(Rect r);                                       // content_bounds union tracking
  UpgradeResult tryUpgrade(String targetPreset);                  // §4.4 rule
  Rect? boundaryRect();                                           // null ⇒ infinite canvas
}

class PairingInfo { final String ipv4; final int port; final String token; }  // Doc 25
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

* Dart uuid: tiny v4 via `Random.secure()` helper inside Doc 25 (no extra dependency).
* `.slatesync` tablet cache read/write uses the `archive` package (Doc 05 pubspec, Doc 26 IO).

---

## 6. Master Ownership Matrix & Wave Assignment

| Doc | Wave | Creates (implementation paths) |
|---|---|---|
| 01 | 1.A | `.gitignore`, `pytest.ini`, `ruff.toml`, `shared_specs/validate_specs.py` |
| 02 | 1.A | `shared_specs/binary_stream_frame.json`, `shared_specs/ws_rpc_schema.json` |
| 03 | 1.A | `shared_specs/canvas_document_schema.json` |
| 04 | 1.A | `pc_agent/requirements.txt`, `pc_agent/__init__.py`, `pc_agent/core/__init__.py`, `pc_agent/core/config_manager.py`, `pc_agent/core/protocol.py`, `pc_agent/core/events.py`, `pc_agent/main.py` (bootstrap), `pc_agent/tests/test_config_manager.py`, `pc_agent/tests/test_protocol.py`, `pc_agent/tests/test_events.py` |
| 05 | 1.A | `mobile_app/` scaffold (`pubspec.yaml`, `analysis_options.yaml`, `lib/main.dart` stub), `mobile_app/lib/core/theme/studio_theme.dart`, `mobile_app/lib/core/models/canvas_models.dart`, `mobile_app/test/canvas_models_test.dart`, `mobile_app/test/wire_codec_test.dart` |
| 06 | 1.B | `pc_agent/viewport/__init__.py`, `pc_agent/viewport/gl_canvas_host.py`, `pc_agent/tests/test_gl_canvas_host.py` |
| 07 | 1.B | `pc_agent/viewport/stroke_tessellator.py`, `pc_agent/viewport/shaders/stroke.vert`, `stroke.geom`, `stroke.frag`, `pc_agent/tests/test_stroke_tessellator.py` |
| 08 | 2.A | `pc_agent/viewport/primitive_renderer.py`, `pc_agent/viewport/shaders/primitive.vert/.frag`, `grid.vert/.frag`, `texture.vert/.frag`, `pc_agent/tests/test_primitive_renderer.py` |
| 09 | 1.B | `pc_agent/engine/__init__.py`, `pc_agent/engine/scene_graph.py`, `pc_agent/tests/test_scene_graph.py` |
| 10 | 1.B | `pc_agent/engine/document_store.py`, `pc_agent/tests/test_document_store.py` |
| 11 | 1.B | `pc_agent/network/__init__.py`, `pc_agent/network/ws_stream_server.py`, `pc_agent/tests/test_ws_stream_server.py`, `pc_agent/tests/test_wave1_mirror_pipeline.py` |
| 12 | 1.B | `pc_agent/network/discovery_pairing.py`, `pc_agent/tests/test_discovery_pairing.py` |
| 13 | 2.A | `pc_agent/export/__init__.py`, `pc_agent/export/tiled_raster_exporter.py`, `pc_agent/tests/test_tiled_raster_exporter.py` |
| 14 | 2.A | `pc_agent/export/vector_pdf_exporter.py`, `pc_agent/tests/test_vector_pdf_exporter.py` |
| 15 | 2.A | `pc_agent/export/export_coordinator.py`, `pc_agent/tests/test_export_coordinator.py` |
| 16 | 2.A | `pc_agent/gui/__init__.py`, `pc_agent/gui/studio_window.py`, `pc_agent/tests/test_studio_window.py` |
| 17 | 2.A | `pc_agent/gui/tray_daemon.py`, `pc_agent/tests/test_tray_daemon.py` |
| 18 | 3.A | `pc_agent/installer/slatesync_agent.spec` |
| 19 | 3.A | `pc_agent/installer/setup.iss` |
| 20 | 1.B | `mobile_app/lib/canvas_engine/camera_controller.dart`, `mobile_app/test/camera_controller_test.dart` |
| 21 | 1.B | `mobile_app/lib/canvas_engine/stroke_processor.dart`, `mobile_app/test/stroke_processor_test.dart` |
| 22 | 1.B | `mobile_app/lib/canvas_engine/tiled_canvas_painter.dart`, `mobile_app/test/tiled_canvas_painter_test.dart` |
| 23 | 1.B | `mobile_app/lib/canvas_engine/artboard_manager.dart`, `mobile_app/test/artboard_manager_test.dart` |
| 24 | 2.A | `mobile_app/lib/features/tools/tool_palette_dock.dart`, `mobile_app/test/tool_palette_dock_test.dart` |
| 25 | 1.B | `mobile_app/lib/network/vector_sync_client.dart`, `mobile_app/test/vector_sync_client_test.dart` |
| 26 | 2.A | `mobile_app/lib/features/home/home_canvas_dashboard.dart`, `mobile_app/lib/core/storage/local_db.dart`, `mobile_app/test/home_dashboard_test.dart` |
| 27 | 2.A | `mobile_app/lib/features/export/export_modal_sheet.dart`, `mobile_app/test/export_sheet_test.dart` |
| 28 | 3.B | `qa/run_all.ps1`, `qa/latency_probe.py`, `qa/export_verify.py` |

* Sequential (cross-wave) edits are allowed: Wave 3.A finalizes `pc_agent/main.py` (Doc 04 bootstrap) and `mobile_app/lib/main.dart` (Doc 05 stub). No same-wave file is ever shared.
