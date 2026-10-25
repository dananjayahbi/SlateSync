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
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart'; // Doc 23
import 'package:mobile_app/canvas_engine/camera_controller.dart'; // Doc 20
import 'package:mobile_app/canvas_engine/image_placeholder_ticker.dart'; // round-12 issue 06
import 'package:mobile_app/canvas_engine/lock_guard.dart'; // round-10 issue 05
import 'package:mobile_app/canvas_engine/region_fill.dart'; // round-9 issue 04
import 'package:mobile_app/canvas_engine/selection_groups.dart'; // round-9 issue 05
import 'package:mobile_app/canvas_engine/selection_transform.dart'; // round-8 issue 07
import 'package:mobile_app/canvas_engine/stroke_eraser.dart'; // round-8 issue 03
import 'package:mobile_app/canvas_engine/stroke_eraser_controller.dart';
import 'package:mobile_app/canvas_engine/stroke_processor.dart'; // Doc 21
import 'package:mobile_app/canvas_engine/table_geometry.dart'; // round-9 issue 06
import 'package:mobile_app/canvas_engine/tiled_canvas_painter.dart'; // Doc 22
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/storage/local_db.dart'; // Doc 26
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/canvas/canvas_history_controller.dart'; // round-9 issue 03
import 'package:mobile_app/features/canvas/canvas_history_sync.dart'; // round-11 issue 02
import 'package:mobile_app/features/canvas/canvas_publish.dart'; // round-9 issue 08
import 'package:mobile_app/features/canvas/canvas_shape_conventions.dart';
import 'package:mobile_app/features/canvas/image_source_popup.dart';
import 'package:mobile_app/features/canvas/remote_mutation_applier.dart';
import 'package:mobile_app/features/canvas/selection_actions.dart'; // round-9 05/06
import 'package:mobile_app/features/canvas/selection_overlay.dart'; // round-8 issue 07
import 'package:mobile_app/features/canvas/table_config_popup.dart'; // round-9 issue 06
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
/// Round-8 issue 07 — the topmost node under a selector tap (`null` = empty
/// space, which starts a marquee).
class _SelectHit {
  const _SelectHit(this.node);

  final CanvasNodeModel? node;

  /// True when the tap landed on empty space rather than an object.
  bool get belongsToNewNode => node == null;
}

class CanvasStudioPage extends StatefulWidget {  const CanvasStudioPage({
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

  /// Round-12 issue 06 — drives the image loading placeholder.
  ImagePlaceholderTicker? _placeholderTicker;
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

  // -- Round-8 issue 07: selector tool -------------------------------------
  /// Ids currently selected. Move/delete work on all of them; resize is
  /// blocked when any member is a free-hand stroke (see
  /// `selection_transform.dart` `canScaleSelection`).
  final Set<String> _selected = <String>{};
  /// Marquee drag in WORLD units while rubber-banding an empty-space drag.
  Rect? _marquee;
  Offset? _marqueeStart;
  /// Active move/resize drag.
  Offset? _transformStart;
  Rect? _transformFrom;
  Rect? _transformTo;
  ResizeHandle? _activeHandle;
  bool _transforming = false;

  /// Issue 05 — one Gallery/Camera popup at a time per image-tool tap.
  bool _imageFlowActive = false;

  // -- Round-9 issue 03: undo/redo -----------------------------------------
  late final CanvasHistoryController _history;

  // -- Round-9 issue 06: pending table shape -------------------------------
  /// Rows/columns/headers chosen in the popup, applied to the next drag.
  TableConfig? _tableConfig;

  // -- Round-9: transient hint line ---------------------------------------
  String? _hint;
  Timer? _hintTimer;

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
      ..backgroundColor = _doc.artboard.backgroundColor
      ..backgroundSpacing = _doc.artboard.backgroundSpacing;
    // Issue 08: the mirror was just told about this artboard by the OPEN_CANVAS
    // broadcast, so the first autosave must not re-publish the same page.
    _publishedArtboard = ArtboardFingerprint.of(_doc.artboard);
    _toolConfig = ValueNotifier<ToolConfig>(ToolConfig());
    _tool = ValueNotifier<StudioTool>(StudioTool.pen);
    _snap = ValueNotifier<bool>(true);
    _history = CanvasHistoryController();

    // Seed Doc 23 content tracking from whatever the document already holds
    // so the §4.4 upgrade rule sees pre-session strokes too.
    final Rect? seeded = _boundsRectOrNull();
    if (seeded != null) {
      _artboard.noteContent(seeded);
    }

    _engine.setDocument(_doc);
    // Round-9 issue 07a — an IMAGE asset decodes asynchronously; the tiles
    // holding it are invalidated by the engine, and this is what actually
    // schedules the repaint (before, the image only appeared after some other
    // edit forced a frame).
    _engine.onTilesRebaked = () {
      if (mounted) {
        _canvasTick.value++;
      }
    };
    // Round-12 issue 06 — animate the image loading placeholder. The ticker runs
    // only while an asset is still decoding, so an idle canvas costs nothing.
    _placeholderTicker = ImagePlaceholderTicker(
      pending: () => _engine.assets.hasPending,
      onTick: (double phase) {
        if (!mounted) {
          return;
        }
        if (_engine.advancePlaceholderPhase(phase)) {
          _canvasTick.value++;
        }
      },
    );
    _engine.assets.onReady = (String ref) {
      _engine.invalidateAllTilesForAsset(ref);
      _placeholderTicker?.onAssetReady();
      if (mounted) {
        _canvasTick.value++;
      }
    };
    unawaited(_primeArchivedAssets());
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
    _placeholderTicker?.dispose();
    _events?.cancel();
    _camera.onCameraChanged = null;
    _tool.removeListener(_onToolStateChanged);
    _toolConfig.removeListener(_onToolStateChanged);
    _tool.dispose();
    _toolConfig.dispose();
    _snap.dispose();
    _canvasTick.dispose();
    _history.dispose();
    _hintTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // State-change fan-in
  // -------------------------------------------------------------------------

  void _onToolStateChanged() {
    // Round-9 issue 06 — the table's config popup opens WITH the tool, so the
    // user configures rows/columns before drawing anything.
    if (_tool.value == StudioTool.table && _tableConfig == null) {
      unawaited(_openTableConfig());
    }
    if (mounted) {
      setState(() {});
    }
  }

  // -------------------------------------------------------------------------
  // Round-9 issue 03 — undo / redo
  //
  // Snapshots, not a command log: several gestures emit MORE than one RPC (a
  // transform is DELETE_NODE + ADD_*, a brush erase is DELETE_NODE + N×
  // ADD_STROKE), so an undo step has to cover the whole gesture. Each mutation
  // helper brackets itself with [_beginEdit] / [_endEdit].
  // -------------------------------------------------------------------------

  void _beginEdit() => _history.begin(_doc);

  void _endEdit() {
    if (_history.end(_doc)) {
      _canvasTick.value++;
    }
  }

  /// Reindexes the engine after a history step rewrote `doc.elements`.
  void _reloadFromDoc() {
    _engine.setDocument(_doc);
    final Rect? seeded = _boundsRectOrNull();
    if (seeded != null) {
      _artboard.noteContent(seeded);
    }
    setState(() => _selected.clear());
    _canvasTick.value++;
    _dirty = true;
  }

  void _undo() => _historyStep(redo: false);

  void _redo() => _historyStep(redo: true);

  /// Round-11 issue 02 — replay a history step on the mirror.
  ///
  /// An undo/redo only rewrote local state before, so the PC kept showing the
  /// pre-undo canvas. The document is snapshotted BEFORE the step, then the
  /// minimal node diff is emitted as ordinary `ELEMENT_COMMIT`s. Lock groups
  /// cannot travel in an element commit, so when they changed the whole
  /// document is published instead (`CANVAS_PUT` is the only carrier).
  void _historyStep({required bool redo}) {
    final List<CanvasNodeModel> before = List<CanvasNodeModel>.of(_doc.elements);
    final Map<String, List<String>> groupsBefore =
        <String, List<String>>{
      for (final MapEntry<String, List<String>> e in _doc.groups.entries)
        e.key: List<String>.of(e.value),
    };
    final bool moved = redo ? _history.redo(_doc) : _history.undo(_doc);
    if (!moved) {
      return;
    }
    _reloadFromDoc();
    if (groupsDiffer(groupsBefore, _doc.groups)) {
      // A lock/unlock step: node-level RPCs cannot express the group, so the
      // published document carries both the nodes and the groups.
      _publishedGroups = _groupsSignature();
      _publishedArtboard = ArtboardFingerprint.of(_doc.artboard);
      unawaited(publishCanvasDocument(widget.client, _doc));
      return;
    }
    for (final HistoryRpc rpc in diffNodes(before: before, after: _doc.elements)) {
      unawaited(
        widget.client.sendRpc(_commitEnvelope(rpc.action, rpc.payload)),
      );
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

  // -------------------------------------------------------------------------
  // Round-8 issue 07 — selector tool (tap to select, marquee for strokes,
  // drag to move, handle-drag to resize). Free-hand strokes are MOVE-ONLY:
  // scaling a drawn path would visibly distort the ink, so the handles are
  // suppressed whenever the selection contains one.
  // -------------------------------------------------------------------------

  static const double _handleHitPx = 22.0;
  static const double _tapSlopPx = 6.0;

  bool get _selectionCanScale =>
      canScaleSelection(_selected.map((String id) {
        final CanvasNodeModel? n = _nodeById(id);
        return n?.kind ?? '';
      }));

  /// Round-10 issue 05 — a locked selection exposes no transform affordance.
  ///
  /// The unlock badge stays visible (that is the ONLY way out of a lock), but
  /// handles and drag-to-move are withdrawn so "locked" reads the same as it
  /// behaves: nothing happens until it is unlocked.
  bool get _selectionEditable =>
      _selected.isNotEmpty && !anyLocked(_doc, _selected);

  /// True when a gesture on the current selection may start.
  bool get _selectionCanTransform =>
      _selectionEditable && _selectionCanScale;

  Rect get _selectionRect {
    final List<List<double>> boxes = <List<double>>[
      for (final String id in _selected)
        if (_nodeById(id) case final CanvasNodeModel n) n.bbox,
    ];
    return selectionBounds(boxes);
  }

  CanvasNodeModel? _nodeById(String id) {
    for (final CanvasNodeModel n in _doc.elements) {
      if (n.nodeId == id) {
        return n;
      }
    }
    return null;
  }

  void _onSelectDown(PointerDownEvent e) {
    final Offset world = _camera.screenToWorld(e.localPosition, _viewport);
    // 1) A resize handle of the current selection wins over everything else.
    if (_selected.isNotEmpty && _selectionCanTransform) {
      final Rect bounds = _selectionRect;
      final double grab =
          _handleHitPx / math.max(_camera.scale, 1e-6);
      for (final ResizeHandle handle in ResizeHandle.values) {
        if ((handlePosition(handle, bounds) - world).distance <= grab) {
          _activeHandle = handle;
          _transformStart = world;
          _transformFrom = bounds;
          _transformTo = bounds;
          _transforming = true;
          _canvasTick.value++;
          return;
        }
      }
    }
    // 2) Tapping inside the current selection starts a MOVE of it.
    if (_selected.isNotEmpty && _selectionEditable) {
      final Rect bounds = _selectionRect.inflate(_tapSlopPx / math.max(_camera.scale, 1e-6));
      if (bounds.contains(world) && !_hitTopmost(world).belongsToNewNode) {
        _transformStart = world;
        _transformFrom = _selectionRect;
        _transformTo = _selectionRect;
        _transforming = true;
        _canvasTick.value++;
        return;
      }
    }
    // 3) Tap on a node selects it (shift-free single selection).
    final _SelectHit hit = _hitTopmost(world);
    if (hit.node != null) {
      setState(() {
        // Round-9 issue 05 — a locked group always selects as a whole, so the
        // group behaves as a single object until it is unlocked.
        _selected
          ..clear()
          ..addAll(expandSelection(_doc, <String>[hit.node!.nodeId]));
        _marquee = null;
      });
      _canvasTick.value++;
      return;
    }
    // 4) Empty space starts a MARQUEE (the only way to select free strokes).
    setState(() => _selected.clear());
    _marqueeStart = world;
    _marquee = Rect.fromPoints(world, world);
    _canvasTick.value++;
  }

  void _onSelectMove(PointerMoveEvent e) {
    final Offset world = _camera.screenToWorld(e.localPosition, _viewport);
    if (_activeHandle != null && _transformFrom != null) {
      _transformTo = resizeRect(_transformFrom!, _activeHandle!, world);
      _canvasTick.value++;
      return;
    }
    if (_transforming && _transformStart != null) {
      final Offset delta = world - _transformStart!;
      _transformTo = _transformFrom!.shift(delta);
      _canvasTick.value++;
      return;
    }
    if (_marqueeStart != null) {
      _marquee = normalizedRect(Rect.fromPoints(_marqueeStart!, world));
      _canvasTick.value++;
    }
  }

  void _onSelectUp() {
    // --- finish a marquee: select every intersecting node ------------------
    if (_marquee != null && _marqueeStart != null) {
      final Rect box = _marquee!;
      final double slop = _tapSlopPx / math.max(_camera.scale, 1e-6);
      if (box.width <= slop && box.height <= slop) {
        setState(() => _selected.clear()); // a tap on empty space
      } else {
        final Set<String> picked = <String>{
          for (final CanvasNodeModel n in _engine.queryVisible(box))
            if (intersectsMarquee(_rectOf(n), box)) n.nodeId,
        };
        setState(() {
          // Round-9 issue 05 — a marquee that catches one member of a locked
          // group selects the whole group.
          _selected
            ..clear()
            ..addAll(expandSelection(_doc, picked));
        });
      }
      _marquee = null;
      _marqueeStart = null;
      _canvasTick.value++;
      return;
    }
    // --- commit a move / resize -------------------------------------------
    if (_transforming && _transformFrom != null && _transformTo != null) {
      final Rect from = _transformFrom!;
      final Rect to = _transformTo!;
      final bool moved = (to.topLeft - from.topLeft).distance > 1e-6;
      final bool resized = _activeHandle != null &&
          (to.width - from.width).abs() > 1e-6 ||
          _activeHandle != null && (to.height - from.height).abs() > 1e-6;
      if (moved || resized) {
        _applyTransform(
          from: from,
          to: to,
          scale: _activeHandle != null,
        );
      }
      _transforming = false;
      _transformStart = null;
      _transformFrom = null;
      _transformTo = null;
      _activeHandle = null;
      _canvasTick.value++;
    }
  }

  Rect _rectOf(CanvasNodeModel n) {
    final List<double> b = n.bbox;
    if (b.length < 4) {
      return Rect.zero;
    }
    return Rect.fromLTRB(
      math.min(b[0], b[2]),
      math.min(b[1], b[3]),
      math.max(b[0], b[2]),
      math.max(b[1], b[3]),
    );
  }

  _SelectHit _hitTopmost(Offset world) {
    CanvasNodeModel? found;
    final double slop = _tapSlopPx / math.max(_camera.scale, 1e-6);
    final Rect probe = Rect.fromCircle(center: world, radius: slop);
    for (final CanvasNodeModel n in _engine.queryVisible(probe)) {
      if (_rectOf(n).inflate(slop).contains(world)) {
        found = n; // ascending layer order ⇒ the last hit is topmost
      }
    }
    return _SelectHit(found);
  }

  /// Emits the mutation set for a move/resize: DELETE_NODE of each replaced
  /// node plus ADD_* for its replacement, so the PC mirrors the transform
  /// through the existing frozen actions (no schema change).
  void _applyTransform({
    required Rect from,
    required Rect to,
    required bool scale,
  }) {
    // Round-10 issue 05 — a locked group refuses every tool, transforms
    // included. All-or-nothing so a mixed selection never tears a group apart.
    final List<String> movable = unlockedIds(_doc, _selected);
    if (movable.isEmpty) {
      _showHint('Locked — unlock the group with the selector tool first.');
      return;
    }
    _beginEdit(); // round-9 issue 03 — the whole transform is ONE undo step
    for (final String id in movable) {
      final CanvasNodeModel? node = _nodeById(id);
      if (node == null) {
        continue;
      }
      final bool scalable = kScalableKinds.contains(node.kind);
      final bool doScale = scale && scalable;
      if (scale && !scalable) {
        continue; // resize is suppressed for this node — leave it untouched
      }
      final List<List<double>> pts = doScale
          ? scalePoints(node.geometry.pts, from, to)
          : translatePoints(node.geometry.pts, to.topLeft - from.topLeft);
      final List<double> bbox = doScale
          ? scaleBbox(node.bbox, from, to)
          : translateBbox(node.bbox, to.topLeft - from.topLeft);
      final CanvasNodeModel updated = CanvasNodeModel(
        nodeId: node.nodeId,
        kind: node.kind,
        layer: node.layer,
        bbox: bbox,
        style: NodeStyleModel(
          color: node.style.color,
          strokeWidth: node.style.strokeWidth,
          opacity: node.style.opacity,
          blendMode: node.style.blendMode,
          // Round-10 issue 04 — moving/resizing must not drop the fill the
          // paint bucket applied; the style is rebuilt field-by-field here.
          fill: node.style.fill,
        ),
        geometry: NodeGeometryModel(
          pts: pts,
          shapeType: node.geometry.shapeType,
          graphConfig: node.geometry.graphConfig,
          assetRef: node.geometry.assetRef,
        ),
      );
      _doc.elements.removeWhere((CanvasNodeModel n) => n.nodeId == node.nodeId);
      _doc.elements.add(updated);
      _engine.addNode(updated); // replace semantics: re-bakes the union
      _artboard.noteContent(_rectOf(updated));
      _dirty = true;
      final String action = _addActionForKind(node.kind);
      unawaited(
        widget.client.sendRpc(
          _commitEnvelope('DELETE_NODE', <String, dynamic>{
            'node_id': node.nodeId,
          }),
        ),
      );
      unawaited(
        widget.client.sendRpc(_commitEnvelope(action, updated.toJson())),
      );
    }
    _endEdit();
  }

  /// Frozen Doc 02 action that re-creates a node of [kind] on the PC.
  static String _addActionForKind(String kind) => addActionForKind(kind);

  /// Deletes the current selection (works for free strokes too).
  void _deleteSelection() {
    if (_selected.isEmpty) {
      return;
    }
    // Round-10 issue 05 — a locked group must survive a delete. The group is
    // removed FIRST so the honest "unlock then delete" path still works while
    // an ordinary selection that happens to include a group is refused.
    final List<String> deletable = unlockedIds(_doc, _selected);
    if (deletable.isEmpty) {
      _showHint('Locked — unlock the group with the selector tool first.');
      return;
    }
    _beginEdit(); // round-9 issue 03 — the whole selection is one undo step
    for (final String id in deletable) {
      _deleteNode(id);
    }
    setState(() => _selected.clear());
    _endEdit();
  }

  // -------------------------------------------------------------------------
  // Round-9 issue 04 — paint bucket
  //
  // "The rule is just the object needs to be closed." The tap is resolved to a
  // NODE, not to pixels (see region_fill.dart): a raster flood would leak
  // through antialiased edges and could not tell one shape's interior from the
  // gap beside it.
  // -------------------------------------------------------------------------

  void _fillAt(Offset screen) {
    final Offset world = _camera.screenToWorld(screen, _viewport);
    final double reach = 2.0 / math.max(_camera.scale, 1e-6);
    final FillTarget? target = findFillTarget(
      world,
      _engine.queryVisible(Rect.fromCircle(center: world, radius: reach)),
    );
    if (target == null) {
      _showHint('Tap inside a closed shape to fill it.');
      return;
    }
    // Round-10 issue 05 — the paint bucket must refuse a locked group.
    if (isNodeLocked(_doc, target.node.nodeId)) {
      _showHint('Locked — unlock the group with the selector tool first.');
      return;
    }
    final ToolConfig cfg = _toolConfig.value;
    final bool clearing = target.node.style.fill != null;
    _setNodeFill(
      target.node,
      clearing ? null : cfg.color,
    );
  }

  /// Replaces [node] with a copy carrying [fill] (or none) and mirrors it.
  ///
  /// The frozen schema has no UPDATE_NODE action, so the same
  /// `DELETE_NODE` + `ADD_*` pair the selector's transform uses re-creates the
  /// node on the PC — one code path, one wire dialect.
  void _setNodeFill(CanvasNodeModel node, String? fill) {
    _beginEdit(); // round-9 issue 03
    final CanvasNodeModel updated = CanvasNodeModel(
      nodeId: node.nodeId,
      kind: node.kind,
      layer: node.layer,
      bbox: List<double>.of(node.bbox),
      style: NodeStyleModel(
        color: node.style.color,
        strokeWidth: node.style.strokeWidth,
        opacity: node.style.opacity,
        blendMode: node.style.blendMode,
        fill: fill,
      ),
      geometry: NodeGeometryModel(
        pts: List<List<double>>.of(node.geometry.pts),
        shapeType: node.geometry.shapeType,
        graphConfig: node.geometry.graphConfig,
        assetRef: node.geometry.assetRef,
      ),
    );
    _replaceNode(node, updated);
    _endEdit();
  }

  /// Swaps [previous] for [updated] in the document + engine and mirrors it.
  void _replaceNode(CanvasNodeModel previous, CanvasNodeModel updated) {
    _doc.elements.removeWhere(
      (CanvasNodeModel n) => n.nodeId == previous.nodeId,
    );
    _doc.elements.add(updated);
    _engine.addNode(updated);
    _artboard.noteContent(_rectOf(updated));
    _dirty = true;
    unawaited(
      widget.client.sendRpc(
        _commitEnvelope('DELETE_NODE', <String, dynamic>{
          'node_id': previous.nodeId,
        }),
      ),
    );
    unawaited(
      widget.client.sendRpc(
        _commitEnvelope(_addActionForKind(updated.kind), updated.toJson()),
      ),
    );
    // The mirror receives the replacement through the ADD_* commit above. A
    // full `CANVAS_PUT` is only needed when the DOCUMENT-level state changed
    // (artboard or lock groups), which `_publishArtboardIfChanged` decides.
    _publishArtboardIfChanged();
    _canvasTick.value++;
  }

  // -------------------------------------------------------------------------
  // Round-9 issue 05 — lock groups and rotation
  // -------------------------------------------------------------------------

  /// True when the selection is entirely one locked group.
  bool get _selectionLocked =>
      _selected.isNotEmpty && selectionIsFullyLocked(_doc, _selected);

  /// Rotation is for SHAPES only — never a free-hand stroke (the user's own
  /// rule: strokes are move-only, and rotating a drawn path would shear the
  /// ink exactly like scaling it would).
  bool get _selectionCanRotate {
    if (_selected.isEmpty) {
      return false;
    }
    for (final String id in _selected) {
      final CanvasNodeModel? n = _nodeById(id);
      if (n == null || n.kind != 'SHAPE') {
        return false;
      }
      // Graph axes are line work anchored to their config, and an image is
      // pixel content — rotating either would change what the node MEANS,
      // not just how it looks.
      const Set<String> blocked = <String>{'CARTESIAN_2D', 'NUMBER_LINE'};
      if (blocked.contains(n.geometry.shapeType)) {
        return false;
      }
    }
    return true;
  }

  /// True when at least one selected node encloses a fillable region.
  bool get _selectionCanFill =>
      _selected.any((String id) {
        final CanvasNodeModel? n = _nodeById(id);
        return n != null && canFill(n);
      });

  void _lockSelection() {
    if (_selected.isEmpty) {
      return;
    }
    _beginEdit(); // round-9 issue 03
    lockSelection(_doc, _selected);
    setState(() {});
    _dirty = true;
    // Groups are document-level state with no RPC action of their own, so they
    // travel with the open document via `CANVAS_PUT`.
    _publishArtboardIfChanged();
    _endEdit();
  }

  void _unlockSelection() {
    final String? groupId = _selected.isEmpty ? null : _doc.groupOf(_selected.first);
    if (groupId == null) {
      return;
    }
    _beginEdit(); // round-9 issue 03
    unlockGroup(_doc, groupId);
    setState(() {});
    _dirty = true;
    _publishArtboardIfChanged();
    _endEdit();
  }

  /// Rotates the selection by 15° around its centre.
  ///
  /// A rotated RECT/CIRCLE/TRIANGLE cannot remain that shape type: `bbox` is
  /// axis-aligned by contract, so the rotated object is re-emitted as a
  /// `PATH` polygon (see [rotatedRectPoints]). A PATH is simply rotated again.
  void _rotateSelection() {
    if (!_selectionCanRotate) {
      return;
    }
    // Round-10 issue 05 — locked groups refuse rotation like every other tool.
    final List<String> rotatable = unlockedIds(_doc, _selected);
    if (rotatable.isEmpty) {
      _showHint('Locked — unlock the group with the selector tool first.');
      return;
    }
    const double step = math.pi / 12; // 15°
    _beginEdit(); // round-9 issue 03
    for (final String id in rotatable) {
      final CanvasNodeModel? node = _nodeById(id);
      if (node == null || node.kind != 'SHAPE') {
        continue;
      }
      final Rect box = _rectOf(node);
      final List<List<double>> polygon;
      if (node.geometry.shapeType == 'PATH') {
        polygon = rotatePointsAround(node.geometry.pts, box.center, step);
      } else {
        polygon = rotatedRectPoints(box, step);
      }
      final List<double> bbox = pointsBounds(polygon);
      final CanvasNodeModel updated = CanvasNodeModel(
        nodeId: node.nodeId,
        kind: 'SHAPE',
        layer: node.layer,
        bbox: bbox,
        style: NodeStyleModel(
          color: node.style.color,
          strokeWidth: node.style.strokeWidth,
          opacity: node.style.opacity,
          blendMode: node.style.blendMode,
          fill: node.style.fill,
        ),
        geometry: NodeGeometryModel(
          pts: polygon,
          shapeType: 'PATH',
          graphConfig: node.geometry.graphConfig,
          assetRef: null,
        ),
      );
      _replaceNode(node, updated);
    }
    _endEdit();
  }

  /// Fills every selected node that encloses a region (the lock badge's action).
  void _fillSelection() {
    if (!_selectionCanFill) {
      return;
    }
    final String colour = _toolConfig.value.color;
    _beginEdit(); // round-9 issue 03
    final List<String> fillable = unlockedIds(_doc, _selected);
    for (final String id in fillable) {
      final CanvasNodeModel? node = _nodeById(id);
      if (node == null || !canFill(node)) {
        continue;
      }
      final bool clearing = node.style.fill != null;
      _setNodeFill(node, clearing ? null : colour);
    }
    _endEdit();
  }

  // -------------------------------------------------------------------------
  // Round-9 issue 06 / round-11 issue 03 — table row & column handles
  // -------------------------------------------------------------------------

  /// The selected node when it is a TABLE (the grow handles key off this).
  CanvasNodeModel? get _selectedTable {
    if (_selected.length != 1) {
      return null;
    }
    final CanvasNodeModel? n = _nodeById(_selected.first);
    if (n == null || n.geometry.shapeType != 'TABLE') {
      return null;
    }
    return n;
  }

  /// Grid of the selected table, or `null` when nothing suitable is selected.
  TableGrid? get _selectedTableGrid {
    final CanvasNodeModel? table = _selectedTable;
    if (table == null) {
      return null;
    }
    return tableGridOf(_rectOf(table), table.geometry.graphConfig);
  }

  /// Round-11 issue 03 — `true` when a row can still be removed.
  bool get _tableCanRemoveRow {
    final TableGrid? grid = _selectedTableGrid;
    if (grid == null) {
      return false;
    }
    return grid.rows > kMinTableRows;
  }

  /// Round-11 issue 03 — `true` when a column can still be removed.
  bool get _tableCanRemoveColumn {
    final TableGrid? grid = _selectedTableGrid;
    if (grid == null) {
      return false;
    }
    return grid.cols > kMinTableCols;
  }

  void _addTableRow() => _resizeTable(row: true, grow: true);
  void _addTableColumn() => _resizeTable(row: false, grow: true);
  void _removeTableRow() => _resizeTable(row: true, grow: false);
  void _removeTableColumn() => _resizeTable(row: false, grow: false);

  /// Adds or removes one row/column, keeping the CURRENT cell size.
  ///
  /// Growing extends the table's bbox by one cell along that axis (otherwise
  /// the cells would just get thinner and the handle would feel inert);
  /// removing shrinks the bbox by the cell being dropped, so the remaining
  /// cells keep the size the user drew. Both directions are a single undo step
  /// and mirror through `DELETE_NODE` + `ADD_SHAPE`, like every other transform.
  void _resizeTable({required bool row, required bool grow}) {
    final CanvasNodeModel? table = _selectedTable;
    if (table == null) {
      return;
    }
    // Round-10 issue 05 — the table handles are tool actions too.
    if (isNodeLocked(_doc, table.nodeId)) {
      _showHint('Locked — unlock the group with the selector tool first.');
      return;
    }
    final Rect box = _rectOf(table);
    final TableGrid grid = tableGridOf(box, table.geometry.graphConfig);
    final Map<String, dynamic>? config = grow
        ? (row
            ? withExtraRow(table.geometry.graphConfig)
            : withExtraColumn(table.geometry.graphConfig))
        : (row
            ? withFewerRow(table.geometry.graphConfig)
            : withFewerColumn(table.geometry.graphConfig));
    if (config == null) {
      _showHint(row
          ? 'A table needs at least one row.'
          : 'A table needs at least one column.');
      return;
    }
    final double cellH = grid.box.height / grid.rows;
    final double cellW = grid.box.width / grid.cols;
    final double deltaH = row ? (grow ? cellH : -cellH) : 0.0;
    final double deltaW = row ? 0.0 : (grow ? cellW : -cellW);
    final Rect resized = Rect.fromLTRB(
      box.left,
      box.top,
      math.max(box.right + deltaW, 1.0),
      math.max(box.bottom + deltaH, 1.0),
    );
    _beginEdit(); // round-9 issue 03
    final CanvasNodeModel updated = CanvasNodeModel(
      nodeId: table.nodeId,
      kind: table.kind,
      layer: table.layer,
      bbox: <double>[resized.left, resized.top, resized.right, resized.bottom],
      style: NodeStyleModel(
        color: table.style.color,
        strokeWidth: table.style.strokeWidth,
        opacity: table.style.opacity,
        blendMode: table.style.blendMode,
        fill: table.style.fill,
      ),
      geometry: NodeGeometryModel(
        pts: List<List<double>>.of(table.geometry.pts),
        shapeType: 'TABLE',
        graphConfig: config,
        assetRef: null,
      ),
    );
    _replaceNode(table, updated);
    _endEdit();
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _palm.noteDown(e);
    final StudioTool tool = _tool.value;

    if (tool == StudioTool.select) {
      _onSelectDown(e);
      return;
    }
    if (tool == StudioTool.eraser) {
      _erasing = true;
      _erasedInDrag.clear();
      _eraseDiscs.clear();
      _eraseAt(e.localPosition);
      return;
    }
    if (tool == StudioTool.fill) {
      // Round-9 issue 04 — a paint bucket is a tap, never a drag.
      _fillAt(e.localPosition);
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
    if (tool == StudioTool.table && _tableConfig == null) {
      // Round-9 issue 06 — the config popup opens WITH the tool; a tap before
      // it is answered just re-opens it rather than drawing a default table.
      unawaited(_openTableConfig());
      return;
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
    if (_tool.value == StudioTool.select) {
      _onSelectMove(e);
      return;
    }
    if (toolIsEraser()) {
      // Round-8 issue 03: BOTH modes follow the drag. Brush needs the tail of
      // discs to erase continuously; element mode needs it to sweep across
      // several nodes in one pass (the old `precision` mode only fired once
      // on pointer-down, which felt broken).
      if (_erasing) {
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
      // Round-8 issue 07: a completed selector interaction settles here.
      if (_tool.value == StudioTool.select) {
        _onSelectUp();
      }
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
    _beginEdit(); // round-9 issue 03 — one undo step per pen stroke
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
    _endEdit();
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
  // Eraser (Doc 22 queryVisible → Doc 25 DELETE_NODE / ADD_STROKE)
  //
  // Round-8 issue 03: the DEFAULT mode is now a real brush eraser. It cannot
  // delete a stroke node — the node IS the stroke — so it replaces each
  // touched stroke with the fragments outside the swept disc. Bbox elements
  // (shapes/images/graphs) are cleared only when a disc actually lands on
  // them. `EraserMode.element` keeps the previous whole-node delete.
  // -------------------------------------------------------------------------

  /// Discs swept during the current press/drag, so a fast stroke erases a
  /// continuous swathe instead of isolated dabs.
  final List<EraseDisc> _eraseDiscs = <EraseDisc>[];
  static const StrokeEraser _strokeEraser = StrokeEraser();

  void _eraseAt(Offset screen) {
    final Offset world = _camera.screenToWorld(screen, _viewport);
    // Radius follows ToolConfig.width (dock's "Eraser radius" slider, dp).
    final double radius =
        math.max(_toolConfig.value.width, 1.0) / math.max(_camera.scale, 1e-6);
    final EraseDisc disc = EraseDisc(world, radius);
    _eraseDiscs.add(disc);
    // Discs are consumed by every candidate, so keep only those that can
    // still reach a node near this point plus the previous few (drag tail).
    if (_eraseDiscs.length > 24) {
      _eraseDiscs.removeRange(0, _eraseDiscs.length - 24);
    }
    final Rect probe = Rect.fromCircle(center: world, radius: radius);
    final bool elementMode =
        _toolConfig.value.eraserMode == EraserMode.element;
    // Round-10 issue 05 — the eraser is a tool, so a locked group must be
    // immune to it. Filtering the candidates here also keeps `_erasedInDrag`
    // clean, so a node unlocked mid-gesture is not skipped later.
    final Set<String> locked = lockedGroupIds(_doc);
    bool changed = false;
    for (final CanvasNodeModel node in _engine.queryVisible(probe)) {
      if (locked.contains(node.nodeId)) {
        continue;
      }
      final EraseOutcome outcome = _strokeEraser.apply(
        node,
        _eraseDiscs,
        elementMode: elementMode,
      );
      if (!outcome.changesAnything) {
        continue;
      }
      if (!_erasedInDrag.add(node.nodeId)) {
        continue; // already handled during this press/drag
      }
      changed = true;
      if (outcome.fragments.isEmpty) {
        _deleteNode(node.nodeId);
      } else {
        _replaceWithFragments(node, outcome.fragments);
      }
    }
    if (changed) {
      _dirty = true;
      _canvasTick.value++;
    }
  }

  /// Replaces [original] with nodes carrying its style, one per surviving
  /// fragment, and mirrors the swap to the PC (`DELETE_NODE` + `ADD_STROKE`).
  void _replaceWithFragments(
    CanvasNodeModel original,
    List<List<List<double>>> fragments,
  ) {
    _beginEdit(); // round-9 issue 03
    forgetNode(_doc, original.nodeId); // round-9 issue 05
    _doc.elements.removeWhere((CanvasNodeModel n) => n.nodeId == original.nodeId);
    _engine.removeCommitted(original.nodeId);
    unawaited(
      widget.client.sendRpc(
        _commitEnvelope('DELETE_NODE', <String, dynamic>{
          'node_id': original.nodeId,
        }),
      ),
    );
    for (final List<List<double>> pts in fragments) {
      final List<double> bbox = polylineBounds(
        pts.map((List<double> p) => Offset(p[0], p[1])).toList(growable: false),
        // Half the stroke width so the rounded caps are inside the bbox.
        padding: math.max(original.style.strokeWidth, 1.0) / 2,
      );
      final CanvasNodeModel node = CanvasNodeModel(
        nodeId: uuidV4(),
        kind: original.kind,
        layer: original.layer,
        bbox: bbox,
        style: NodeStyleModel(
          color: original.style.color,
          strokeWidth: original.style.strokeWidth,
          opacity: original.style.opacity,
          blendMode: original.style.blendMode,
          // Round-10 issue 04 — an eraser bite must not clear the fill of the
          // fragments that survive it.
          fill: original.style.fill,
        ),
        geometry: NodeGeometryModel(
          pts: pts,
          shapeType: original.geometry.shapeType,
          graphConfig: original.geometry.graphConfig,
          assetRef: original.geometry.assetRef,
        ),
      );
      _engine.addNode(node);
      _doc.elements.add(node);
      _artboard.noteContent(
        Rect.fromLTRB(bbox[0], bbox[1], bbox[2], bbox[3]),
      );
      unawaited(
        widget.client.sendRpc(
          _commitEnvelope('ADD_STROKE', node.toJson()),
        ),
      );
    }
    _endEdit(); // round-9 issue 03 — the whole swap is one undo step
  }

  void _deleteNode(String nodeId) {
    _beginEdit(); // round-9 issue 03
    // Round-9 issue 05 — a locked group must never keep a dangling member, so
    // every delete path drops the id from its group as well.
    forgetNode(_doc, nodeId);
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
    _endEdit();
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
    if (tool == StudioTool.table) {
      // Round-9 issue 06 — a table is a SHAPE with `shape_type: TABLE` and its
      // grid in `graph_config`, so every renderer gains tables by reading one
      // more shape_type instead of learning a new node kind.
      final TableConfig config = _tableConfig ??
          const TableConfig(
            rows: kDefaultTableRows,
            cols: kDefaultTableCols,
            headerRow: true,
            headerCol: false,
          );
      final Rect planned = planTableRect(
        start,
        end,
        TableGridSizeHint(rows: config.rows, cols: config.cols),
      );
      _commitElement(
        _buildNode(
          kind: 'SHAPE',
          shapeType: 'TABLE',
          pts: <List<double>>[
            <double>[planned.left, planned.top],
            <double>[planned.right, planned.bottom],
          ],
          rect: planned,
          graphConfig: buildTableConfig(
            rows: config.rows,
            cols: config.cols,
            headerRow: config.headerRow,
            headerCol: config.headerCol,
          ),
        ),
        planned,
        'ADD_SHAPE',
      );
      _canvasTick.value++;
      return;
    }
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

  /// Round-9 issue 06 — the table's initial-config popup.
  Future<void> _openTableConfig() async {
    if (_imageFlowActive) {
      return;
    }
    _imageFlowActive = true;
    try {
      final TableConfig? config = await showTableConfigPopup(context);
      if (config == null || !mounted) {
        return;
      }
      setState(() => _tableConfig = config);
      _showHint(
        'Drag on the canvas to place a ${config.rows}×${config.cols} table.',
      );
    } finally {
      _imageFlowActive = false;
    }
  }

  /// Transient one-line hint under the top bar (also the fill tool's feedback).
  void _showHint(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _hint = message);
    _hintTimer?.cancel();
    _hintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _hint = null);
      }
    });
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
    // Round-8 issue 05: hand the encoded bytes to the engine's image cache so
    // the IMAGE node can actually paint (it used to draw an empty rect).
    _engine.assets.resolve(ref, Uint8List.fromList(img.bytes));
    // Round-12 issue 06: show the loading placeholder until this decodes.
    _placeholderTicker?.ensureRunning();

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

  /// Round-8 issue 05 — restores IMAGE bytes for a document that already
  /// carries them.
  ///
  /// `loadDocument` extracts the archive's `assets/*` entries to
  /// `<base>/assets/<canvasId>/`, but nothing ever fed them to the renderer,
  /// so a REOPENED canvas showed its images as blank boxes. This reads each
  /// IMAGE node's `asset_ref` back and registers the bytes with the engine's
  /// image cache. Best effort: a missing file is skipped (the node renders
  /// nothing rather than something wrong).
  Future<void> _primeArchivedAssets() async {
    final List<String> refs = <String>[];
    for (final CanvasNodeModel n in _doc.elements) {
      final String? ref = n.geometry.assetRef;
      if (n.kind == 'IMAGE' && ref != null && ref.isNotEmpty) {
        if (!refs.contains(ref)) {
          refs.add(ref);
        }
      }
    }
    if (refs.isEmpty) {
      return;
    }
    try {
      for (final String ref in refs) {
        if (_engine.assets.isReady(ref)) {
          continue;
        }
        final File file = File(
          await canvasAssetPath(
            _doc.canvasId,
            ref,
            baseDir: widget.baseDir,
          ),
        );
        if (!await file.exists()) {
          continue;
        }
        _engine.assets.resolve(ref, await file.readAsBytes());
      }
      _engine.assets.ensureDecoded(refs);
      // Round-12 issue 06: start the placeholder animation for the decodes we
      // just kicked off, so the frames are never blank.
      _placeholderTicker?.ensureRunning();
    } catch (_) {
      // Offline/partial environment (widget tests) — images stay blank.
    }
  }

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
    _beginEdit(); // round-9 issue 03
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
    _endEdit();
  }

  /// Doc 02 §10.1 (Doc 24 §10.7 dock callback): wipe ALL elements locally,
  /// then broadcast CLEAR_CANVAS for this document (payload `{}` — the
  /// envelope's `canvas_id` identifies the target). `updated_at` bumps on
  /// the next persist, same as every other mutation here.
  void _onClearCanvas() {
    _beginEdit(); // round-9 issue 03
    wipeDocumentElements(doc: _doc, engine: _engine, artboard: _artboard);
    _doc.groups.clear(); // a cleared canvas has no locked objects left
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
    _endEdit();
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

  /// Round-9 issue 08 — the artboard the mirror was last told about.
  ArtboardFingerprint? _publishedArtboard;

  /// Round-9 issue 05 — the lock groups the mirror was last told about.
  String _publishedGroups = '';

  /// Sends the open canvas whenever the page look changed (background style,
  /// spacing, paper colour, preset/size) — or the lock groups changed, which
  /// have to travel so a `CANVAS_PULL` round-trip does not lose them. Uses
  /// `CANVAS_PUT`, the only action the frozen schema offers that carries a full
  /// document without navigating.
  void _publishArtboardIfChanged() {
    final ArtboardFingerprint next = ArtboardFingerprint.of(_doc.artboard);
    final String groups = _groupsSignature();
    if (next == _publishedArtboard && groups == _publishedGroups) {
      return;
    }
    _publishedArtboard = next;
    _publishedGroups = groups;
    unawaited(publishCanvasDocument(widget.client, _doc));
  }

  String _groupsSignature() {
    final List<String> keys = _doc.groups.keys.toList()..sort();
    return keys
        .map((String k) => '$k:${(_doc.groups[k] ?? const <String>[]).join(',')}')
        .join('|');
  }

  Future<void> _save() async {
    final bool wasDirty = _dirty;
    _dirty = false;
    _doc.updatedAt = unixNowSeconds();
    _doc.artboard = _artboard.current;
    _publishArtboardIfChanged();
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
            if (_hint != null) _buildHint(_hint!),
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
          // Round-9 issue 03 — undo/redo live at the TOP, as asked.
          ValueListenableBuilder<int>(
            valueListenable: _history.revision,
            builder: (BuildContext context, int _, Widget? child) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('studio-undo'),
                    tooltip: 'Undo',
                    onPressed: _history.canUndo ? _undo : null,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    key: const ValueKey<String>('studio-redo'),
                    tooltip: 'Redo',
                    onPressed: _history.canRedo ? _redo : null,
                    icon: const Icon(Icons.redo),
                  ),
                ],
              );
            },
          ),
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

  /// Round-9 — transient one-line hint (fill-tool feedback, table placement).
  Widget _buildHint(String message) {
    return Container(
      key: const ValueKey<String>('studio-hint'),
      width: double.infinity,
      color: StudioTheme.accent.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          const Icon(Icons.info_outline, size: 16, color: StudioTheme.accent),
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
                    spacing: _artboard.current.backgroundSpacing,
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
            // Round-8 issue 07 — selector chrome above the ink, below the dock.
            if (_tool.value == StudioTool.select)
              ValueListenableBuilder<int>(
                valueListenable: _canvasTick,
                builder: (BuildContext context, int tick, Widget? child) {
                  final Rect shown = _transforming && _transformTo != null
                      ? _transformTo!
                      : _selectionRect;
                  return CanvasSelectionOverlay(
                    viewMatrix: _camera.viewMatrix,
                    rect: shown,
                    scale: _camera.scale,
                    showHandles: _selectionCanTransform,
                    marquee: _marquee,
                  );
                },
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
            // Round-9 issues 05/06 — the selector's per-object chrome:
            // lock/unlock, rotate and fill float just above the selection box;
            // a locked group also gets a lock badge. All anchored to the
            // object, as asked, not to a global toolbar.
            if (_tool.value == StudioTool.select && _selected.isNotEmpty)
              ValueListenableBuilder<int>(
                valueListenable: _canvasTick,
                builder: (BuildContext context, int tick, Widget? child) {
                  final Rect box = _selectionRect;
                  if (box == Rect.zero) {
                    return const SizedBox.shrink();
                  }
                  final Offset screenTopLeft = _camera.worldToScreen(
                    box.topLeft,
                    _viewport,
                  );
                  return Stack(
                    children: <Widget>[
                      if (_selectionLocked)
                        LockBadge(anchor: screenTopLeft),
                      SelectionActionBar(
                        anchor: screenTopLeft,
                        locked: _selectionLocked,
                        canLock: _selected.isNotEmpty,
                        canRotate: _selectionCanRotate && _selectionEditable,
                        canFill: _selectionCanFill && _selectionEditable,
                        filled: _selected.any((String id) {
                          final CanvasNodeModel? n = _nodeById(id);
                          return n != null && n.style.fill != null;
                        }),
                        onLock: _lockSelection,
                        onUnlock: _unlockSelection,
                        onRotate: _rotateSelection,
                        onFill: _fillSelection,
                        onDelete:
                            _selectionEditable ? _deleteSelection : null,
                      ),
                      // Round-9 issue 06 — rows are added BELOW the table and
                      // columns to its RIGHT, where a spreadsheet puts them.
                      if (_selectedTable != null)
                        TableGrowHandles(
                          rowAnchor: _camera.worldToScreen(
                            Offset(box.center.dx, box.bottom),
                            _viewport,
                          ),
                          colAnchor: _camera.worldToScreen(
                            Offset(box.right, box.center.dy),
                            _viewport,
                          ),
                          onAddRow: _addTableRow,
                          onAddColumn: _addTableColumn,
                          onRemoveRow:
                              _tableCanRemoveRow ? _removeTableRow : null,
                          onRemoveColumn: _tableCanRemoveColumn
                              ? _removeTableColumn
                              : null,
                        ),
                    ],
                  );
                },
              ),
          ],
        );
      },
    );
  }
}
