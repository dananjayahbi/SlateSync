/// Wave 3.A — Infinite Canvas Studio glue screen (Flutter master wiring).
///
/// Sanctioned integration surface for `overview.md` §6 Session 3 Wave 3.A
/// item 3: this screen connects the Doc 22 `TiledCanvasView` engine layer,
/// Doc 20 camera gestures, Doc 21 stroke pipeline, Doc 24 `ToolDock`, Doc 25
/// `VectorSyncClient` stream/RPC path, Doc 27 export sheet and the Doc 26
/// home/save flow into one route.
///
/// Path deviation (reported): no micro-document owns
/// `mobile_app/lib/features/canvas/**` — the Wave 3.A charter assigns this
/// glue to the master-wiring subagent, so the page lives here rather than
/// under any sibling doc's `Creates` paths. Everything else is consumed
/// read-only through the frozen template §5 APIs; where a frozen surface
/// blocks integration (for example Doc 21's `@visibleForTesting` pressure
/// seam or Doc 22's lack of a single-node remove), a small adapter lives in
/// this file instead of editing sibling modules.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart'; // Doc 23
import 'package:mobile_app/canvas_engine/camera_controller.dart'; // Doc 20
import 'package:mobile_app/canvas_engine/stroke_processor.dart'; // Doc 21
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart'; // Doc 22
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/storage/local_db.dart'; // Doc 26
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/canvas/canvas_shape_conventions.dart';
import 'package:mobile_app/features/canvas/image_source_popup.dart';
import 'package:mobile_app/features/canvas/remote_mutation_applier.dart';
import 'package:mobile_app/features/export/export_modal_sheet.dart'; // Doc 27
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'; // Doc 26
import 'package:mobile_app/features/pairing/pairing_screen.dart'; // Issue 03
import 'package:mobile_app/features/tools/tool_palette_dock.dart'; // Doc 24
import 'package:mobile_app/network/vector_sync_client.dart'; // Doc 25

/// Template §3 asset-chunk cap (raw bytes per `ASSET_CHUNK`).
const int kAssetChunkRawCap = 262144;

/// Infinite Canvas Studio: full-screen drawing surface + floating dock.
///
/// [document] is handed off by Doc 26 `HomeCanvasDashboard.onOpenDocument`;
/// [client] is the app-lifetime Doc 25 client owned by `main.dart`. [db] and
/// [baseDir] mirror the Doc 26 test seams so widget tests never touch
/// path_provider.
class CanvasStudioPage extends StatefulWidget {
  const CanvasStudioPage({
    super.key,
    required this.document,
    required this.client,
    this.db,
    this.baseDir,
    this.pickImageFromSource,
  });

  final CanvasDocumentModel document;
  final VectorSyncClient client;

  /// Optional [LocalDb] injection (tests); `null` ⇒ opened on first save.
  final LocalDb? db;

  /// Optional `.slatesync` cache directory (tests).
  final String? baseDir;

  /// Issue 05 — image-tool picker override (tests); `null` ⇒ the default
  /// `image_picker` implementation in image_source_popup.dart.
  final ImageSourcePickFn? pickImageFromSource;

  @override
  State<CanvasStudioPage> createState() => _CanvasStudioPageState();
}

class _CanvasStudioPageState extends State<CanvasStudioPage>
    with WidgetsBindingObserver {
  // -- Frozen collaborators (Docs 20–23) ----------------------------------
  late final CanvasDocumentModel _doc;
  late final CameraController _camera;
  late final TiledCanvasEngine _engine;
  late final ArtboardManager _artboard;

  /// Doc 02 §10.2 live-mutation relay receive side (shared with the local
  /// clear path through [wipeDocumentElements]).
  late final RemoteMutationApplier _remote;

  // -- Tool state (Doc 24) -------------------------------------------------
  late final ValueNotifier<ToolConfig> _toolConfig;
  late final ValueNotifier<StudioTool> _tool;
  late final ValueNotifier<bool> _snap;

  // -- Pointer input -------------------------------------------------------
  final Set<int> _pointers = <int>{};
  final PalmGuard _palm = PalmGuard();
  StrokeProcessor? _stroke;
  int? _strokePointer;
  int _lastLiveCount = 0;
  bool _erasing = false;
  final Set<String> _erasedInDrag = <String>{};
  int? _shapePointer;
  Offset? _shapeStart;
  Offset? _shapeEnd;

  /// Issue 05 — one Gallery/Camera popup at a time per image-tool tap.
  bool _imageFlowActive = false;

  // -- Repaint plumbing ----------------------------------------------------
  final ValueNotifier<int> _canvasTick = ValueNotifier<int>(0);
  final List<Offset> _liveView = <Offset>[];
  Size _viewport = Size.zero;
  bool _fitDone = false;
  bool _cameraEngaged = false;
  bool _dirty = false;

  /// Last observed engine zoom bucket (Issue 05 §3) — crossings evict
  /// every non-current bucket in the tile cache.
  int? _lastBucket;

  // -- Persistence ---------------------------------------------------------
  LocalDb? _activeDb;
  final Map<String, List<int>> _pendingAssets = <String, List<int>>{};
  StreamSubscription<SyncEvent>? _events;
  Timer? _autosave;

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _camera = CameraController();
    _engine = TiledCanvasEngine(camera: _camera);
    _artboard = ArtboardManager(preset: _doc.artboard.preset);
    // Issue 02: the studio never rendered page backgrounds before — adopt the
    // document's saved background so RULED/DOT_GRID/ISO_GRID docs paint their
    // pattern (the manager seeds BLANK/#FFFFFF on construction).
    _artboard.current
      ..backgroundStyle = _doc.artboard.backgroundStyle
      ..backgroundColor = _doc.artboard.backgroundColor;
    _toolConfig = ValueNotifier<ToolConfig>(ToolConfig());
    _tool = ValueNotifier<StudioTool>(StudioTool.pen);
    _snap = ValueNotifier<bool>(true);

    // Seed Doc 23 content tracking from whatever the document already holds
    // so the §4.4 upgrade rule sees pre-session strokes too.
    final Rect? seeded = _boundsRectOrNull();
    if (seeded != null) {
      _artboard.noteContent(seeded);
    }

    _engine.setDocument(_doc);
    _remote = RemoteMutationApplier(
      doc: _doc,
      engine: _engine,
      artboard: _artboard,
    );
    _camera.onCameraChanged = _onCameraChanged;
    // Issue 05 §4 — OS memory pressure → aggressive tile-cache trim.
    WidgetsBinding.instance.addObserver(this);
    _tool.addListener(_onToolStateChanged);
    _toolConfig.addListener(_onToolStateChanged);
    _events = widget.client.events.listen(_onSyncEvent);
    _autosave = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_dirty) {
        unawaited(_save());
      }
    });
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _events?.cancel();
    _camera.onCameraChanged = null;
    _tool.removeListener(_onToolStateChanged);
    _toolConfig.removeListener(_onToolStateChanged);
    _tool.dispose();
    _toolConfig.dispose();
    _snap.dispose();
    _canvasTick.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // State-change fan-in
  // -------------------------------------------------------------------------

  void _onToolStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onSyncEvent(SyncEvent event) {
    if (!mounted) {
      return;
    }
    if (event.kind == SyncEventKind.rpcReceived) {
      _applyRemoteMsg(event.msg);
      return;
    }
    if (event.kind != SyncEventKind.stateChanged) {
      return;
    }
    setState(() {}); // connection chip + banner follow Doc 25 transitions
  }

  /// Doc 02 §10.2 — live mutation relay: apply peer commits/renames for the
  /// OPEN document; every other envelope (incl. other `canvas_id`s) is
  /// ignored silently. The hub excludes our own echoes; the applier still
  /// guards against duplicates from a misbehaving relay.
  void _applyRemoteMsg(Map<String, dynamic>? msg) {
    if (msg == null) {
      return;
    }
    if (!_remote.apply(msg, openCanvasId: _doc.canvasId) || !mounted) {
      return;
    }
    _dirty = true;
    _canvasTick.value++;
    setState(() {});
    if (msg['type'] == 'ARTBOARD_RESIZE') {
      unawaited(_save()); // remote preset swap persists immediately (Doc 23)
    }
  }

  void _onCameraChanged(CameraSnapshot snap) {
    if (!mounted) {
      return;
    }
    // Doc 20 hook → Doc 25 camera frame (f1=scale, f2=tx, f3=ty); dropped
    // automatically while offline. setState refreshes painters + readout.
    widget.client.sendLiveFrame(
      FrameType.camera,
      toolIdFor(_tool.value),
      snap.scale,
      snap.tx,
      snap.ty,
    );
    // Issue 05 §3 — zoom-bucket crossings evict every stale bucket from
    // the tile cache and backfill the hot window at the new factor.
    final int bucket = _engine.currentBucket;
    if (_lastBucket != null && bucket != _lastBucket) {
      _engine.onScaleBucketChanged();
    }
    _lastBucket = bucket;
    setState(() {});
  }

  /// Issue 05 §4 — the OS is under memory pressure: trim the tile cache to
  /// the pressure watermark (~64 MB), invalidate offscreen tiles, and force
  /// a repaint (visible tiles re-bake lazily through the get-path).
  @override
  void didHaveMemoryPressure() {
    if (!mounted) {
      return;
    }
    _engine.handleMemoryPressure();
    _canvasTick.value++;
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // Layout + initial framing
  // -------------------------------------------------------------------------

  /// Doc 02 §10.5 fit-on-open target: bounded ⇒ page rect `(0,0,w,h)`;
  /// infinite ⇒ `content_bounds`, with the spec's `(-500,-500,1000,1000)`
  /// fallback while those bounds are empty.
  Rect _fitTarget() => _artboard.boundaryRect() ??
      _boundsRectOrNull() ??
      const Rect.fromLTWH(-500, -500, 1000, 1000);

  void _ensureInitialFit(Size size) {
    if (size.isEmpty) {
      return;
    }
    _viewport = size;
    if (_fitDone) {
      return;
    }
    _fitDone = true;
    // §10.5: `zoomToFit` runs AFTER the first layout frame (the viewport is
    // only known here, and the Doc 20 hook may not fire mid-build). The
    // camera applies the 48-unit padding (+96 per axis) and centers the
    // target via the §3 transform; the hook then repaints + baselines the
    // Issue 05 §3 zoom bucket.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _applyFit();
      _lastBucket = _engine.currentBucket; // Issue 05 §3 baseline
    });
  }

  /// Doc 02 §10.5 fit: [CameraController.zoomToFit] takes the viewport only
  /// to COMPUTE the scale — the controller's own viewport (what `viewMatrix`
  /// centers against) is fed by gestures alone, so a fresh controller still
  /// holds its 800×600 default and the page would open visibly off-centre
  /// until the first pinch. A rebase + 1× update at focal `(0, 0)` adopts
  /// the live viewport while the fixed-point math cancels exactly (scale
  /// and centre are unchanged) — safe at any point in the gesture history.
  void _applyFit() {
    _camera.zoomToFit(_fitTarget(), _viewport); // fires onCameraChanged
    _camera.onScaleStart(ScaleStartDetails(focalPoint: Offset.zero));
    _camera.onScaleUpdate(
      ScaleUpdateDetails(focalPoint: Offset.zero),
      _viewport,
    ); // fires onCameraChanged again — idempotent state, synced viewport
  }

  Rect? _boundsRectOrNull() {
    final Map<String, double> b = _doc.contentBounds;
    final double minX = b['min_x'] ?? 0;
    final double minY = b['min_y'] ?? 0;
    final double maxX = b['max_x'] ?? 0;
    final double maxY = b['max_y'] ?? 0;
    if (minX == 0 && minY == 0 && maxX == 0 && maxY == 0) {
      return null;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Map<String, double> _unionBounds(Rect r) =>
      unionContentBounds(_doc.contentBounds, r);

  // -------------------------------------------------------------------------
  // Pointer input (Listener) + camera gestures (GestureDetector)
  // -------------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _palm.noteDown(e);
    final StudioTool tool = _tool.value;

    if (tool == StudioTool.eraser) {
      _erasing = true;
      _erasedInDrag.clear();
      _eraseAt(e.localPosition);
      return;
    }
    if (tool == StudioTool.image) {
      if (_pointers.length == 1) {
        unawaited(_beginImageFlow(e.localPosition));
      }
      return; // Gallery/Camera popup flow — no direct canvas input
    }
    if (tool == StudioTool.cartesianGraph || tool == StudioTool.numberLine) {
      return; // dock graph-builder dialogs — no direct canvas input
    }
    if (_palm.shouldReject(e)) {
      return;
    }
    if (_stroke != null || _shapeStart != null) {
      // Second contact while a mark is in flight: a flagged palm contact
      // keeps the stylus alive (Doc 21 rule); anything else hands the
      // gesture to the two-finger camera.
      if (_palm.flaggedPointer == e.pointer) {
        return;
      }
      _endDrawing();
      return;
    }
    if (_pointers.length > 1) {
      return; // two-finger camera gesture — never starts a mark
    }
    if (tool == StudioTool.pen || tool == StudioTool.highlighter) {
      _startStroke(e);
    } else {
      _startShape(e);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (toolIsEraser()) {
      if (_erasing && _toolConfig.value.eraserMode == EraserMode.stroke) {
        _eraseAt(e.localPosition);
      }
      return;
    }
    if (_shapeStart != null) {
      if (e.pointer != _shapePointer) {
        return;
      }
      final Offset world = _camera.screenToWorld(e.localPosition, _viewport);
      final Offset snapped = _applyLineSnap(_shapeStart!, world);
      _shapeEnd = snapped;
      // Local preview shows the actual shape outline; the PC mirrors the
      // drag corner via ToolId.shapePreview (0x04) frames below.
      _liveView
        ..clear()
        ..addAll(shapePreviewPoints(_tool.value, _shapeStart!, snapped));
      _canvasTick.value++;
      _streamPoint(snapped, 1.0);
      return;
    }
    final StrokeProcessor? s = _stroke;
    if (s == null || e.pointer != _strokePointer) {
      return;
    }
    if (_palm.shouldReject(e)) {
      return;
    }
    s.addPoint(e.localPosition, null, e.pointer);
    final List<Offset> pts = s.livePoints;
    if (pts.isEmpty || pts.length == _lastLiveCount) {
      return; // decimator/palm gate accepted nothing new
    }
    _lastLiveCount = pts.length;
    _liveView
      ..clear()
      ..addAll(pts);
    _canvasTick.value++;
    _streamPoint(pts.last, _widthFactor(s));
  }

  void _onPointerUp(PointerUpEvent e) {
    _onPointerLifecycleEnd(e.pointer);
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _onPointerLifecycleEnd(e.pointer);
  }

  void _onPointerLifecycleEnd(int pointer) {
    _pointers.remove(pointer);
    _palm.noteUp(pointer);
    if (pointer == _shapePointer) {
      _commitShape();
    }
    if (pointer == _strokePointer) {
      _finishStroke();
    }
    if (_pointers.isEmpty) {
      _erasing = false;
      _erasedInDrag.clear();
    }
    if (_pointers.length < 2) {
      _cameraEngaged = false;
    }
  }

  void _handleScaleStart(ScaleStartDetails d) {
    _cameraEngaged = false; // engagement decided on the first update
  }

  void _handleScaleUpdate(ScaleUpdateDetails d) {
    final bool twoFingers = _pointers.length >= 2;
    if (!twoFingers || _stroke != null || _shapeStart != null) {
      _cameraEngaged = false;
      return;
    }
    if (!_cameraEngaged) {
      // Re-baseline the Doc 20 controller from the first two-finger update
      // (ScaleStartDetails may have fired while one finger was still
      // drawing, before the camera was allowed to engage).
      _camera.onScaleStart(ScaleStartDetails(focalPoint: d.focalPoint));
      _cameraEngaged = true;
    }
    _camera.onScaleUpdate(d, _viewport);
  }

  void _handleScaleEnd(ScaleEndDetails d) {
    _cameraEngaged = false;
  }

  bool toolIsEraser() => _tool.value == StudioTool.eraser;

  Offset _applyLineSnap(Offset start, Offset end) {
    if (_tool.value != StudioTool.line || !_snap.value) {
      return end;
    }
    final Offset delta = end - start;
    if (delta.distance < 1e-6) {
      return end;
    }
    final double angle = math.atan2(delta.dy, delta.dx);
    final double snapped =
        (angle * 180.0 / math.pi / 15.0).round() * 15.0 * math.pi / 180.0;
    return start +
        Offset(math.cos(snapped), math.sin(snapped)) * delta.distance;
  }

  // -------------------------------------------------------------------------
  // Stroke pipeline (Doc 21) → engine + RPC (Docs 22 / 25)
  // -------------------------------------------------------------------------

  void _startStroke(PointerDownEvent e) {
    final ToolConfig cfg = _toolConfig.value;
    _strokePointer = e.pointer;
    _lastLiveCount = 0;
    _stroke = StrokeProcessor(
      toWorld: (Offset p) => _camera.screenToWorld(p, _viewport),
      color: cfg.color,
      width: cfg.width,
      highlighter: cfg.highlighter,
    );
    _stroke!.addPoint(e.localPosition, null, e.pointer);
    _afterStrokePoint();
  }

  void _afterStrokePoint() {
    final StrokeProcessor? s = _stroke;
    if (s == null) {
      return;
    }
    final List<Offset> pts = s.livePoints;
    if (pts.isEmpty || pts.length == _lastLiveCount) {
      return;
    }
    _lastLiveCount = pts.length;
    _liveView
      ..clear()
      ..addAll(pts);
    _canvasTick.value++;
    _streamPoint(pts.last, _widthFactor(s));
  }

  void _finishStroke() {
    final StrokeProcessor? s = _stroke;
    _stroke = null;
    _strokePointer = null;
    _lastLiveCount = 0;
    _liveView.clear();
    if (s != null) {
      _streamEnd();
      final ProcessedStroke? stroke = s.finish();
      if (stroke != null) {
        _commitStroke(stroke);
      }
    }
    _canvasTick.value++;
  }

  void _endDrawing() {
    _finishStroke();
    if (_shapeStart != null) {
      _commitShape();
    }
  }

  double _widthFactor(StrokeProcessor s) {
    // Adapter: Doc 21 exposes the smoothed pseudo-pressure only through its
    // `@visibleForTesting` seam — read it here instead of editing Doc 21.
    // ignore: invalid_use_of_visible_for_testing_member
    final double factor = s.liveHalfWidthFactor;
    return factor.clamp(0.05, 2.0).toDouble();
  }

  void _commitStroke(ProcessedStroke stroke) {
    _engine.addCommitted(stroke); // Doc 22: index + dirty-tile rebake
    final Map<String, dynamic> payload = stroke.toRpcPayload();
    final CanvasNodeModel node = CanvasNodeModel.fromJson(payload);
    final Rect content = Rect.fromLTRB(
      stroke.bbox[0],
      stroke.bbox[1],
      stroke.bbox[2],
      stroke.bbox[3],
    );
    _doc.elements.add(node);
    _artboard.noteContent(content);
    _doc.contentBounds = _unionBounds(content);
    _dirty = true;
    // Doc 25: queued when offline, sent immediately when online.
    unawaited(widget.client.sendRpc(_commitEnvelope('ADD_STROKE', payload)));
    _canvasTick.value++;
  }

  Map<String, dynamic> _commitEnvelope(
    String action,
    Map<String, dynamic> payload,
  ) =>
      <String, dynamic>{
        'type': 'ELEMENT_COMMIT',
        'action': action,
        'canvas_id': _doc.canvasId,
        'payload': payload,
      };

  // -------------------------------------------------------------------------
  // Live frames (Doc 24 preview streaming)
  // -------------------------------------------------------------------------

  bool get _streamsLive {
    final StudioTool tool = _tool.value;
    return tool != StudioTool.eraser && tool != StudioTool.image;
  }

  void _streamPoint(Offset world, double factor) {
    if (!widget.client.isConnected || !_streamsLive) {
      return;
    }
    widget.client.sendLiveFrame(
      FrameType.livePoint,
      toolIdFor(_tool.value),
      world.dx,
      world.dy,
      factor,
    );
  }

  void _streamEnd() {
    if (!widget.client.isConnected || !_streamsLive) {
      return;
    }
    widget.client.sendLiveFrame(
      FrameType.liveEnd,
      toolIdFor(_tool.value),
      0,
      0,
      0,
    );
  }

  // -------------------------------------------------------------------------
  // Eraser hit-testing (Doc 22 queryVisible → Doc 25 DELETE_NODE)
  // -------------------------------------------------------------------------

  void _eraseAt(Offset screen) {
    final Offset world = _camera.screenToWorld(screen, _viewport);
    // Eraser hit radius follows ToolConfig.width (dock's "Hit radius" slider, dp).
    final double pad =
        math.max(_toolConfig.value.width, 1.0) / math.max(_camera.scale, 1e-6);
    final Rect probe = Rect.fromLTWH(
      world.dx - pad,
      world.dy - pad,
      pad * 2,
      pad * 2,
    );
    CanvasNodeModel? victim;
    // queryVisible returns ascending layer order — the last bbox hit wins.
    for (final CanvasNodeModel n in _engine.queryVisible(probe)) {
      final List<double> b = n.bbox;
      if (b.length != 4) {
        continue;
      }
      if (world.dx >= b[0] &&
          world.dx <= b[2] &&
          world.dy >= b[1] &&
          world.dy <= b[3]) {
        victim = n;
      }
    }
    if (victim == null) {
      return;
    }
    if (!_erasedInDrag.add(victim.nodeId)) {
      // One DELETE_NODE per node per press/drag (Doc 24 §4): the
      // precision/stroke down-hit records the id too, so a stroke-mode drag
      // that starts ON a node (or crosses it twice) never double-fires.
      return;
    }
    _deleteNode(victim.nodeId);
  }

  void _deleteNode(String nodeId) {
    _doc.elements.removeWhere((CanvasNodeModel n) => n.nodeId == nodeId);
    // Issue 05 §2: incremental single-node removal — dirty only the tiles
    // the node occupied instead of a full `setDocument` reindex.
    _engine.removeCommitted(nodeId);
    _dirty = true;
    unawaited(
      widget.client.sendRpc(
        _commitEnvelope('DELETE_NODE', <String, dynamic>{'node_id': nodeId}),
      ),
    );
    _canvasTick.value++;
  }

  // -------------------------------------------------------------------------
  // Shape / graph / image commits (Doc 24 callbacks → Doc 02 RPC)
  // -------------------------------------------------------------------------

  void _startShape(PointerDownEvent e) {
    final Offset world = _camera.screenToWorld(e.localPosition, _viewport);
    _shapePointer = e.pointer;
    _shapeStart = world;
    _shapeEnd = world;
    _liveView
      ..clear()
      ..add(world);
    _canvasTick.value++;
  }

  void _commitShape() {
    final Offset? start = _shapeStart;
    final Offset? end = _shapeEnd;
    final int? pointer = _shapePointer;
    _shapeStart = null;
    _shapeEnd = null;
    _shapePointer = null;
    _liveView.clear();
    if (start == null || end == null || pointer == null) {
      return;
    }
    final StudioTool tool = _tool.value;
    final Rect rect = Rect.fromPoints(start, end);
    if (rect.longestSide < 2.0) {
      _canvasTick.value++;
      return; // accidental tap — nothing to commit
    }
    // Doc 02 §10.3 — kind / shape_type / pts follow the PC conventions
    // (canvas_shape_conventions.dart); then index locally + RPC in one step.
    _streamEnd();
    _commitElement(
      _buildNode(
        kind: shapeKindForTool(tool),
        shapeType: shapeTypeForTool(tool),
        pts: shapePtsForTool(tool, start: start, end: end),
        rect: rect,
      ),
      rect,
      'ADD_SHAPE',
    );
    _canvasTick.value++;
  }

  void _onGraphCommitted(String shapeType, Map<String, dynamic> graphConfig) {
    final Rect rect;
    final List<List<double>> pts;
    if (shapeType == 'CARTESIAN_2D') {
      final double ox = _numOf(graphConfig['origin']?[0]) ?? 0;
      final double oy = _numOf(graphConfig['origin']?[1]) ?? 0;
      final double step = _numOf(graphConfig['grid_step']) ?? 25.0;
      final double x0 = ox + (_numOf(graphConfig['x_range']?[0]) ?? 0) * step;
      final double x1 = ox + (_numOf(graphConfig['x_range']?[1]) ?? 0) * step;
      final double y0 = oy + (_numOf(graphConfig['y_range']?[0]) ?? 0) * step;
      final double y1 = oy + (_numOf(graphConfig['y_range']?[1]) ?? 0) * step;
      rect = Rect.fromLTRB(
        math.min(x0, x1),
        math.min(y0, y1),
        math.max(x0, x1),
        math.max(y0, y1),
      );
      pts = <List<double>>[
        <double>[ox, oy],
      ];
    } else {
      final double step = _numOf(graphConfig['step']) ?? 1.0;
      final double x0 = (_numOf(graphConfig['range']?[0]) ?? 0) * step;
      final double x1 = (_numOf(graphConfig['range']?[1]) ?? 0) * step;
      rect = Rect.fromLTRB(math.min(x0, x1), -60, math.max(x0, x1), 60);
      pts = <List<double>>[
        <double>[math.min(x0, x1), 0],
      ];
    }
    _commitElement(
      _buildNode(
        kind: 'GRAPH_AXES',
        shapeType: shapeType,
        pts: pts,
        rect: rect,
        graphConfig: graphConfig,
      ),
      rect,
      'ADD_GRAPH',
    );
  }

  /// Issue 05 — image tool: a canvas TAP opens the page-owned Gallery /
  /// Camera popup; a completed pick places the image centred at the tap's
  /// world point (600-unit long-side planner, Doc 24 math), then streams
  /// ASSET_START/CHUNK/DONE + ADD_IMAGE through [_onPickImage].
  Future<void> _beginImageFlow(Offset screen) async {
    if (_imageFlowActive) {
      return;
    }
    _imageFlowActive = true;
    try {
      final ImageSource? source = await showImageSourcePopup(context);
      if (source == null || !mounted) {
        return; // cancelled (barrier tap / back / Cancel)
      }
      final ImageSourcePickFn pick =
          widget.pickImageFromSource ?? defaultPickImageFromSource;
      final PickedImage? picked = await pick(source);
      if (picked == null || !mounted) {
        return; // cancelled pick — nothing to place
      }
      final Offset world = _camera.screenToWorld(screen, _viewport);
      final Rect rect = planImageWorldRect(
        picked.widthPx,
        picked.heightPx,
        at: world,
      );
      await _onPickImage(
        PendingImage(
          bytes: picked.bytes,
          filename: picked.filename,
          widthPx: picked.widthPx,
          heightPx: picked.heightPx,
          plannedWorldRect: rect,
        ),
      );
    } finally {
      _imageFlowActive = false;
    }
  }

  Future<void> _onPickImage(PendingImage img) async {
    final String name =
        img.filename.split(RegExp(r'[/\\]')).last.replaceAll('..', '');
    final String safeName = name.isEmpty ? 'image.png' : name;
    final String ref = 'assets/$safeName';
    _pendingAssets[ref] = img.bytes;

    final int total =
        (img.bytes.length + kAssetChunkRawCap - 1) ~/ kAssetChunkRawCap;
    if (img.bytes.isNotEmpty) {
      final String transferId = uuidV4();
      await widget.client.sendRpc(<String, dynamic>{
        'type': 'ASSET_UPLOAD',
        'action': 'ASSET_START',
        'canvas_id': _doc.canvasId,
        'payload': <String, dynamic>{
          'transfer_id': transferId,
          'filename': safeName,
          'total_chunks': total,
          'size_bytes': img.bytes.length,
        },
      });
      for (int i = 0; i < total; i++) {
        final int start = i * kAssetChunkRawCap;
        final int end = math.min(start + kAssetChunkRawCap, img.bytes.length);
        await widget.client.sendRpc(<String, dynamic>{
          'type': 'ASSET_UPLOAD',
          'action': 'ASSET_CHUNK',
          'canvas_id': _doc.canvasId,
          'payload': <String, dynamic>{
            'transfer_id': transferId,
            'index': i,
            'data_b64': base64Encode(img.bytes.sublist(start, end)),
          },
        });
      }
      await widget.client.sendRpc(<String, dynamic>{
        'type': 'ASSET_UPLOAD',
        'action': 'ASSET_DONE',
        'canvas_id': _doc.canvasId,
        'payload': <String, dynamic>{
          'transfer_id': transferId,
          'total_chunks': total,
          'size_bytes': img.bytes.length,
        },
      });
    }

    final Rect rect = img.plannedWorldRect;
    _commitElement(
      _buildNode(
        kind: 'IMAGE',
        shapeType: null,
        pts: <List<double>>[],
        rect: rect,
        assetRef: ref,
      ),
      rect,
      'ADD_IMAGE',
    );
  }

  double? _numOf(Object? v) => v is num ? v.toDouble() : null;

  CanvasNodeModel _buildNode({
    required String kind,
    required String? shapeType,
    required List<List<double>> pts,
    required Rect rect,
    Map<String, dynamic>? graphConfig,
    String? assetRef,
  }) {
    final ToolConfig cfg = _toolConfig.value;
    return CanvasNodeModel(
      nodeId: uuidV4(),
      kind: kind,
      layer: 0,
      bbox: <double>[rect.left, rect.top, rect.right, rect.bottom],
      style: NodeStyleModel(
        color: cfg.color,
        strokeWidth: cfg.width,
        opacity: cfg.opacity,
        blendMode: cfg.blendMode,
      ),
      geometry: NodeGeometryModel(
        pts: pts,
        shapeType: shapeType,
        graphConfig: graphConfig,
        assetRef: assetRef,
      ),
    );
  }

  void _commitElement(CanvasNodeModel node, Rect content, String action) {
    // Issue 05 root cause: shape/graph/image commits landed only in the
    // document + RPC — never in the engine index — so their ink vanished on
    // mobile at pen-lift (live preview cleared, nothing rebaked) while the
    // PC, applying the same RPC, kept rendering it. Every element commit
    // now indexes the node FIRST, exactly like `_commitStroke`.
    _engine.addNode(node);
    _doc.elements.add(node);
    _artboard.noteContent(content);
    _doc.contentBounds = _unionBounds(content);
    _dirty = true;
    unawaited(widget.client.sendRpc(_commitEnvelope(action, node.toJson())));
    _canvasTick.value++;
  }

  /// Doc 02 §10.1 (Doc 24 §10.7 dock callback): wipe ALL elements locally,
  /// then broadcast CLEAR_CANVAS for this document (payload `{}` — the
  /// envelope's `canvas_id` identifies the target). `updated_at` bumps on
  /// the next persist, same as every other mutation here.
  void _onClearCanvas() {
    wipeDocumentElements(doc: _doc, engine: _engine, artboard: _artboard);
    _dirty = true;
    _canvasTick.value++;
    if (mounted) {
      setState(() {});
    }
    unawaited(
      widget.client.sendRpc(
        _commitEnvelope('CLEAR_CANVAS', <String, dynamic>{}),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Persistence (Doc 26 APIs)
  // -------------------------------------------------------------------------

  Future<LocalDb> _ensureDb() async {
    final LocalDb? injected = widget.db;
    if (injected != null) {
      return injected;
    }
    return _activeDb ??= await LocalDb.open();
  }

  Future<void> _save() async {
    final bool wasDirty = _dirty;
    _dirty = false;
    _doc.updatedAt = unixNowSeconds();
    _doc.artboard = _artboard.current;
    try {
      final String path = await saveDocument(
        _doc,
        baseDir: widget.baseDir,
        assets: _pendingAssets.isEmpty ? null : _pendingAssets,
      );
      final LocalDb db = await _ensureDb();
      final CanvasRecord? record = await db.get(_doc.canvasId);
      if (record != null) {
        await db.update(
          CanvasRecord(
            id: record.id,
            title: _doc.title,
            preset: _doc.artboard.preset,
            background: _doc.artboard.backgroundStyle,
            thumbPath: record.thumbPath,
            filePath: path,
            updatedAt: _doc.updatedAt,
          ),
        );
      }
    } catch (_) {
      // Offline/partial environment (tests without baseDir) — keep the dirty
      // flag so the next autosave/back retry persists.
      _dirty = wasDirty;
    }
  }

  Future<void> _onBack() async {
    await _save();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // -------------------------------------------------------------------------
  // Chrome actions
  // -------------------------------------------------------------------------

  void _zoomBy(double factor) {
    _camera.scale = _camera.scale * factor;
    _onCameraChanged(_camera.snapshot);
  }

  void _zoomToFit() {
    // Doc 02 §10.5 target + 48-unit padding — same math as fit-on-open.
    _applyFit(); // zoomToFit + viewport sync (fires onCameraChanged → setState)
  }

  void _onArtboardUpgraded(Artboard newArtboard) {
    _doc.artboard = newArtboard;
    _dirty = true;
    unawaited(_save());
    if (mounted) {
      setState(() {});
    }
  }

  void _openUpgrade() {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => UpgradeDialog(
          manager: _artboard,
          onSaved: _onArtboardUpgraded,
        ),
      ),
    );
  }

  void _openExport() {
    unawaited(
      showExportSheet(
        context,
        client: widget.client,
        canvasId: _doc.canvasId,
      ),
    );
  }

  void _openPairing() {
    // Top bar connection button → three-mode Pairing screen (Issue 03);
    // banner/status updates flow from `client.events` StateChanged.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PairingScreen(client: widget.client),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  Color _liveColor() {
    final String hex = _toolConfig.value.color;
    final String digits = hex.replaceFirst('#', '');
    final int? value = digits.length == 6 ? int.tryParse(digits, radix: 16) : null;
    if (value == null) {
      return StudioTheme.text;
    }
    return Color(0xFF000000 | value);
  }

  String? get _bannerText => switch (widget.client.state) {
        SyncState.online => null,
        SyncState.idle =>
          'Not paired — strokes queue locally until the PC connects',
        SyncState.discovering => 'Searching for SlateSync PC…',
        SyncState.connecting => 'Connecting to PC…',
        SyncState.backoff => 'Connection lost — retrying…',
        SyncState.authFailed => 'Pairing rejected — scan the QR again',
      };

  String get _statusLabel => switch (widget.client.state) {
        SyncState.online => 'Paired',
        SyncState.discovering => 'Searching',
        SyncState.connecting => 'Connecting',
        SyncState.backoff => 'Retrying',
        SyncState.authFailed => 'Pairing failed',
        SyncState.idle => 'Connect PC',
      };

  /// Artboard `background_color` parsed to a [Color] (Issue 02: white paper
  /// falls back to [StudioTheme.strokeCanvas] on malformed values).
  Color get _pageColor {
    final String digits =
        _artboard.current.backgroundColor.replaceFirst('#', '');
    final int? value = digits.length == 6 ? int.tryParse(digits, radix: 16) : null;
    if (value == null) {
      return StudioTheme.strokeCanvas;
    }
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    final String? banner = _bannerText;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        final NavigatorState nav = Navigator.of(context);
        unawaited(_save().whenComplete(() {
          if (mounted) {
            nav.pop();
          }
        }));
      },
      child: Scaffold(
        backgroundColor: StudioTheme.bg,
        appBar: _buildTopBar(),
        body: Column(
          children: <Widget>[
            if (banner != null) _buildBanner(banner),
            Expanded(child: _buildCanvasLayer()),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopBar() {
    return AppBar(
      backgroundColor: StudioTheme.surface,
      leading: IconButton(
        key: const ValueKey<String>('studio-back'),
        tooltip: 'Back to Home',
        onPressed: _onBack,
        icon: const Icon(Icons.arrow_back),
      ),
      titleSpacing: 0,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('studio-zoom-out'),
            tooltip: 'Zoom out',
            onPressed: () => _zoomBy(0.8),
            icon: const Icon(Icons.zoom_out),
          ),
          Text(
            '${(_camera.scale * 100).round()}%',
            key: const ValueKey<String>('studio-zoom-level'),
            style: const TextStyle(
              fontSize: StudioTheme.captionSize,
              color: StudioTheme.text,
            ),
          ),
          IconButton(
            key: const ValueKey<String>('studio-zoom-in'),
            tooltip: 'Zoom in',
            onPressed: () => _zoomBy(1.25),
            icon: const Icon(Icons.zoom_in),
          ),
          IconButton(
            key: const ValueKey<String>('studio-zoom-fit'),
            tooltip: 'Zoom to fit',
            onPressed: _zoomToFit,
            icon: const Icon(Icons.fit_screen),
          ),
          TextButton(
            key: const ValueKey<String>('studio-preset'),
            onPressed: _openUpgrade,
            child: Text(
              presetLabel(_artboard.current.preset),
              style: const TextStyle(color: StudioTheme.accent),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton.icon(
          key: const ValueKey<String>('studio-connect'),
          onPressed: _openPairing,
          icon: Icon(
            Icons.qr_code,
            size: 18,
            color: widget.client.state == SyncState.online
                ? StudioTheme.accent
                : StudioTheme.text,
          ),
          label: Text(
            _statusLabel,
            style: const TextStyle(fontSize: StudioTheme.captionSize),
          ),
        ),
        TextButton(
          key: const ValueKey<String>('studio-export'),
          onPressed: _openExport,
          child: const Text(
            'Export',
            style: TextStyle(color: StudioTheme.accent),
          ),
        ),
      ],
    );
  }

  Widget _buildBanner(String message) {
    return Container(
      key: const ValueKey<String>('studio-banner'),
      width: double.infinity,
      color: StudioTheme.danger.withValues(alpha: 0.18),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          const Icon(Icons.sync_problem, size: 16, color: StudioTheme.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: StudioTheme.captionSize,
                color: StudioTheme.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvasLayer() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _ensureInitialFit(
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        return Stack(
          children: <Widget>[
            // Issue 02 — white paper canvas: the viewport sits on
            // `strokeCanvas`, then the artboard page/pattern/shadow layer,
            // then the input + stroke layers above it.
            const Positioned.fill(
              child: ColoredBox(color: StudioTheme.strokeCanvas),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: CanvasBackgroundPainter(
                    viewMatrix: _camera.viewMatrix,
                    scale: _camera.scale,
                    boundary: _artboard.boundaryRect(),
                    style: _artboard.current.backgroundStyle,
                    pageColor: _pageColor,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerCancel,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _handleScaleStart,
                  onScaleUpdate: _handleScaleUpdate,
                  onScaleEnd: _handleScaleEnd,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _canvasTick,
                    builder: (BuildContext context, int tick, Widget? child) {
                      final ToolConfig cfg = _toolConfig.value;
                      return TiledCanvasView(
                        engine: _engine,
                        viewMatrix: _camera.viewMatrix,
                        scale: _camera.scale,
                        livePoints: _liveView,
                        liveColor: _liveColor(),
                        liveWidth: cfg.width,
                        liveOpacity: cfg.opacity,
                        repaint: _canvasTick,
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              bottom: 6,
              child: ClipRect(
                child: SingleChildScrollView(
                  child: ToolDock(
                    config: _toolConfig,
                    tool: _tool,
                    snapEnabled: _snap,
                    onEraseRequest: _deleteNode,
                    onClearRequested: _onClearCanvas,
                    onPickImage: (PendingImage img) =>
                        unawaited(_onPickImage(img)),
                    onGraphCommitted: _onGraphCommitted,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
