// Doc 24: Flutter drawing toolset palette — floating, collapsible tool dock.
//
// Pure UI state: owns ValueNotifiers and emits DTOs (ToolConfig, PendingImage,
// graph-config maps) plus callbacks. It never imports network or camera code —
// the canvas page (Wave 3.A) wires sendRpc / ASSET_* / DELETE_NODE per Doc 02.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/theme/studio_theme.dart';
import 'package:mobile_app/features/tools/tool_property_panels.dart';

/// Tools exposed by the dock rail (Doc 24 §4; round-8 issue 07 added
/// [select] as the FIRST tool, round-9 issues 04/06 added [fill] and [table]).
enum StudioTool {
  select,
  pen,
  highlighter,
  eraser,
  fill,
  line,
  rect,
  circle,
  triangle,
  arrow,
  polygon,
  text,
  cartesianGraph,
  numberLine,
  table,
  image,
  ocr,
}

/// Eraser behavior (Doc 24 §4; round-8 issue 03 changed the default).
///
/// * [brush] — **the default.** A real eraser: strokes are SPLIT around the
///   swept disc so a bite is taken out of the line, leaving the rest intact.
///   Bbox-based elements (shapes/images/graphs) are cleared only when the disc
///   actually lands on them.
/// * [element] — the previous behaviour: the whole hit element is deleted
///   (one DELETE_NODE per node per drag). Kept as an explicit choice because
///   "remove this object" is genuinely useful for shapes.
enum EraserMode { brush, element }

/// Mutable tool styling with Doc 24 §6 defaults: `#1E1E1E` @ `2.5` @ `1.0`,
/// `SRC_OVER`, non-highlighter, **brush** eraser (round-8 issue 03 — the
/// destructive whole-element mode is no longer the default). `blendMode` is
/// forced to `MULTIPLY` while [highlighter] is true.
class ToolConfig {
  String color = '#1E1E1E';
  double width = 2.5;
  double opacity = 1.0;
  String blendMode = 'SRC_OVER';
  bool highlighter = false;
  EraserMode eraserMode = EraserMode.brush;
}

/// Doc 05 `ToolId` byte for [tool]. Pen streams `LIVE_POINT`, highlighter
/// streams MULTIPLY frames, eraser streams nothing (RPC only), every other
/// tool streams `ToolId.shapePreview` previews — image streams no frames
/// either, but shares byte `0x04` as its placement identifier.
int toolIdFor(StudioTool tool) => switch (tool) {
  StudioTool.select => ToolId.shapePreview,
  StudioTool.pen => ToolId.pen,
  StudioTool.highlighter => ToolId.highlighter,
  StudioTool.eraser => ToolId.eraser,
  StudioTool.line ||
  StudioTool.rect ||
  StudioTool.circle ||
  StudioTool.triangle ||
  StudioTool.arrow ||
  StudioTool.polygon ||
  StudioTool.text ||
  StudioTool.cartesianGraph ||
  StudioTool.numberLine ||
  StudioTool.table ||
  StudioTool.fill ||
  StudioTool.image ||
  StudioTool.ocr => ToolId.shapePreview,
};

/// Doc 03 `CARTESIAN_2D` `graph_config` object.
Map<String, dynamic> buildCartesianConfig({
  required List<double> origin,
  required List<int> xRange,
  required List<int> yRange,
  required double gridStep,
  bool showLabels = true,
}) {
  return <String, dynamic>{
    'origin': origin,
    'x_range': xRange,
    'y_range': yRange,
    'grid_step': gridStep,
    'show_labels': showLabels,
  };
}

/// Doc 03 `NUMBER_LINE` `graph_config` object.
Map<String, dynamic> buildNumberLineConfig({
  required List<int> range,
  required double step,
  bool showLabels = true,
}) {
  return <String, dynamic>{
    'range': range,
    'step': step,
    'show_labels': showLabels,
  };
}

/// Bytes returned by the pluggable gallery pick, before world planning.
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.filename,
    required this.widthPx,
    required this.heightPx,
  });

  final Uint8List bytes;
  final String filename;
  final int widthPx;
  final int heightPx;
}

/// Doc 24 §4 — image handed to the canvas page, which performs
/// `ASSET_START/CHUNK/DONE` (≤ 262144 raw bytes/chunk) then `ADD_IMAGE`.
class PendingImage {
  const PendingImage({
    required this.bytes,
    required this.filename,
    required this.widthPx,
    required this.heightPx,
    required this.plannedWorldRect,
  });

  final Uint8List bytes;
  final String filename;
  final int widthPx;
  final int heightPx;
  final Rect plannedWorldRect;
}

/// Pluggable gallery pick; defaults to `image_picker`. Widget tests inject a
/// fake so they never touch a platform plugin.
typedef ImagePickFn = Future<PickedImage?> Function();

/// Maps intrinsic pixel size to the planned world rect (Doc 20 may inject its
/// own screen-fit planner).
typedef WorldRectPlanner = Rect Function(int widthPx, int heightPx);

/// Doc 02 §10.7 (Round-6) per-tool defaults. Selection REPLACES the exposed
/// `config.value` with a fresh instance of this (except the dock's boot-time
/// active tool, which keeps the host's live instance):
///
/// | tool | color | width | opacity | notes |
/// |---|---|---|---|---|
/// | pen | `#1E1E1E` | 2.5 | 1.0 | frozen Doc 24 §6 defaults |
/// | highlighter | `#F1C40F` | 8.0 | 0.4 | MULTIPLY |
/// | eraser | `#1E1E1E` | 10.0 | 1.0 | 10 dp hit radius, precision mode |
/// | line | `#1E1E1E` | 2.5 | 1.0 | snap on (dock-local `_snap`) |
/// | rect/circle/triangle/arrow | `#1E1E1E` | 2.5 | 1.0 | |
/// | cartesianGraph/numberLine | `#4F8EF7` | 2.0 | 1.0 | |
/// | image | `#1E1E1E` | 2.5 | 1.0 | unchanged (import flow only) |
ToolConfig defaultToolConfig(StudioTool tool) {
  final ToolConfig cfg = ToolConfig();
  switch (tool) {
    case StudioTool.select:
    case StudioTool.pen:
    case StudioTool.line:
    case StudioTool.rect:
    case StudioTool.circle:
    case StudioTool.triangle:
    case StudioTool.arrow:
    case StudioTool.polygon:
    case StudioTool.text:
    case StudioTool.table:
    case StudioTool.image:
    case StudioTool.ocr:
      break; // Frozen Doc 24 §6 defaults: #1E1E1E / 2.5 / 1.0.
    case StudioTool.fill:
      cfg.width = 2.5; // fill only changes the interior colour
      break;
    case StudioTool.highlighter:
      cfg.color = '#F1C40F';
      cfg.width = 8.0;
      cfg.opacity = 0.4;
      cfg.highlighter = true;
      cfg.blendMode = 'MULTIPLY';
      break;
    case StudioTool.eraser:
      cfg.width = 10.0; // Hit radius (ToolConfig.width); precision mode.
      break;
    case StudioTool.cartesianGraph:
    case StudioTool.numberLine:
      cfg.color = '#4F8EF7';
      cfg.width = 2.0;
      break;
  }
  return cfg;
}

/// Collapsible tool dock: fixed 48 dp left rail + per-tool sub-panel.
///
/// [config] and [tool] are injected [ValueNotifier]s the canvas page also
/// observes; the dock mutates `config.value` in place. Expand/collapse state
/// stays internal. Optional [pickImage] / [planWorldRect] / [snapEnabled]
/// injections keep widget tests plugin-free and let the canvas page read the
/// dock-local snap flag.
class ToolDock extends StatefulWidget {
  const ToolDock({
    super.key,
    required this.config,
    required this.tool,
    this.onEraseRequest,
    this.onPickImage,
    this.onGraphCommitted,
    this.onClearRequested,
    this.pickImage,
    this.planWorldRect,
    this.snapEnabled,
    this.ocrPanelBuilder,
  });

  /// Injected; on tool switch the dock REPLACES `value` with the active
  /// tool's stored config (Doc 02 §10.7); panel edits still mutate the live
  /// instance in place and write it back into the per-tool store.
  final ValueNotifier<ToolConfig> config;

  /// Active tool; previews use `toolIdFor(tool)`.
  final ValueNotifier<StudioTool> tool;

  /// Canvas page sends DELETE_NODE for the hit-tested node (never the dock).
  final void Function(String nodeId)? onEraseRequest;

  /// Canvas page sends ASSET_* + ADD_IMAGE for the picked bytes.
  final void Function(PendingImage img)? onPickImage;

  /// Graph Builder dialog result: `CARTESIAN_2D` / `NUMBER_LINE` + config.
  final void Function(String shapeType, Map<String, dynamic> graphConfig)?
  onGraphCommitted;

  /// Round-6 (Doc 02 §10.7): fired only after the dock's Clear-canvas
  /// confirmation dialog is accepted. PRE-SEEDED contract — never remove;
  /// the canvas page passes its clear handler.
  final VoidCallback? onClearRequested;

  /// Gallery picker override; defaults to `image_picker`.
  final ImagePickFn? pickImage;

  /// World-rect planner override; defaults to a 600-unit long-side fit.
  final WorldRectPlanner? planWorldRect;

  /// Dock-local 15° snapping flag; a notifier is created when omitted.
  final ValueNotifier<bool>? snapEnabled;

  /// Round-12 issue 09 — builds the OCR scan controls for the property panel.
  ///
  /// Injected rather than imported so the dock never depends on the OCR client
  /// or the WebSocket: the canvas page owns the job, the dock only renders.
  final WidgetBuilder? ocrPanelBuilder;

  @override
  State<ToolDock> createState() => _ToolDockState();
}

class _ToolDockState extends State<ToolDock> {
  static const double _panelWidth = toolPanelWidth;

  /// Round-12 issue 04 — the graph tool whose builder dialog is currently open.
  ///
  /// A single tap reaches `_selectTool` twice (pointer-up hold cancel, then
  /// `IconButton.onPressed`); this makes the second call a no-op instead of
  /// stacking a duplicate dialog.
  StudioTool? _builderOpenFor;

  /// Doc 02 §10.7: press-and-hold duration. A CUSTOM [Timer] — Flutter's
  /// `onLongPress` is intentionally never used for this flow.
  ///
  /// Round 12 issue 02: the 2000 ms hold felt like a dead press, so it is now
  /// 500 ms. Keeping the custom timer (rather than switching to
  /// `onLongPress`) matters: the timer is cancelled on pointer-up, on drag
  /// slop and on any other pointer-down, which is what lets a quick tap still
  /// select the tool.
  static const Duration _holdDuration = Duration(milliseconds: 500);

  /// Pointer-move slop that reclassifies a press as a scroll/drag and thus
  /// cancels a pending hold.
  static const double _holdSlop = 18.0;

  late final ValueNotifier<bool> _snap;
  bool _ownsSnap = false;

  /// Doc 02 §10.7 per-tool property store: one [ToolConfig] per
  /// [StudioTool]. Tool selection replaces `widget.config.value` with the
  /// stored instance; every panel edit writes back into this map.
  late final Map<StudioTool, ToolConfig> _perTool;

  // --- Round-6 hold-to-open gesture state ---
  Timer? _holdTimer;
  StudioTool? _holdPendingTool;
  Offset? _holdStart;
  StudioTool? _pressingTool;

  // --- Round-6 property overlay state ---
  OverlayEntry? _panelEntry;
  StudioTool? _panelTool;

  @override
  void initState() {
    super.initState();
    final ValueNotifier<bool>? injected = widget.snapEnabled;
    if (injected != null) {
      _snap = injected;
    } else {
      _snap = ValueNotifier<bool>(true);
      _ownsSnap = true;
    }
    _perTool = <StudioTool, ToolConfig>{
      for (final StudioTool t in StudioTool.values) t: defaultToolConfig(t),
    };
    // The host's boot-time live instance IS the active tool's entry, so any
    // custom initial values survive until the first tool switch.
    _perTool[widget.tool.value] = widget.config.value;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _panelEntry?.remove();
    _panelEntry?.dispose();
    _panelEntry = null;
    if (_ownsSnap) {
      _snap.dispose();
    }
    super.dispose();
  }

  /// Doc 24 §4 / Doc 02 §10.7: mutate the injected config in place, write it
  /// back into the per-tool store, then nudge listeners — `ValueNotifier.value`
  /// only notifies on reference change.
  void _commit(void Function(ToolConfig update) mutate) {
    mutate(widget.config.value);
    _perTool[widget.tool.value] = widget.config.value;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    widget.config.notifyListeners();
  }

  void _selectTool(StudioTool next) {
    // Flush the outgoing tool's live instance into the store FIRST.
    _perTool[widget.tool.value] = widget.config.value;
    // Round-8 issue 04: an open panel belongs to the tool it was opened for.
    // Tapping a DIFFERENT tool re-targets the panel to that tool (so the
    // "hold to configure" panel keeps tracking the active tool) rather than
    // closing it — a tap outside still closes, via the overlay barrier.
    final bool retarget = _panelTool != null && _panelTool != next;
    widget.tool.value = next;
    // Doc 02 §10.7: REPLACE the notifier's value with the stored per-tool
    // config — never mutate the old instance in place on a switch.
    final ToolConfig cfg = _perTool[next] ??= defaultToolConfig(next);
    final bool wantHighlighter = next == StudioTool.highlighter;
    cfg.highlighter = wantHighlighter;
    cfg.blendMode = wantHighlighter ? 'MULTIPLY' : 'SRC_OVER';
    widget.config.value = cfg;
    if (retarget) {
      _closePropertyPanel();
      _anchorPropertyPanel(next);
    }
    _openBuilderFor(next);
  }

  /// Round-12 issue 04 — tools that have NO drag gesture must open their
  /// builder the moment they are selected.
  ///
  /// A graph has no meaningful "drag a box to create it" gesture: its geometry
  /// comes entirely from a config dialog, and `shape_type` is null for both
  /// graph tools, so the canvas dispatch deliberately ignores a drag. Before
  /// this, selecting "Number Line" or "Cartesian Graph" did nothing at all —
  /// the only way in was a press-and-hold to open the property panel and then
  /// finding "Open Graph Builder…" inside it, which reads as "the tool is
  /// broken".
  ///
  /// The table already worked this way (its popup opens with the tool).
  ///
  /// [_builderOpenFor] guards re-entry: a single tap reaches `_selectTool`
  /// TWICE (once from the pointer-up hold cancel and once from
  /// `IconButton.onPressed`), which would otherwise stack two dialogs and make
  /// every key inside them ambiguous.
  void _openBuilderFor(StudioTool tool) {
    if (!mounted || _builderOpenFor == tool) {
      return;
    }
    switch (tool) {
      case StudioTool.cartesianGraph:
        _builderOpenFor = tool;
        _showCartesianDialog();
      case StudioTool.numberLine:
        _builderOpenFor = tool;
        _showNumberLineDialog();
      default:
        break;
    }
  }

  /// Compact rail buttons: 15×40 dp + divider + the clear button must fit a
  /// 600 dp-tall viewport at the CURRENT tool count (round-9 added fill and
  /// table, so the rail is now 14 tools + clear). Shrinking to 36 dp keeps the
  /// whole dock inside 600 px without a scroller, which matters because the
  /// dock is laid out inside a fixed-height column.
  static ButtonStyle _railButtonStyle({Color? background}) =>
      IconButton.styleFrom(
        minimumSize: const Size(40, 36),
        maximumSize: const Size(48, 36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: background,
      );

  // ---------------------------------------------------------------------
  // Round-6 (Doc 02 §10.7): tap = select instantly; press-and-hold for
  // 500 ms (custom Timer armed on pointer-down — NOT Flutter's onLongPress)
  // opens that tool's property panel. The timer is cancelled on
  // pointer-up/cancel, on drag-slop, on any other pointer-down inside the
  // dock rail, on toggle, and on dispose.
  // ---------------------------------------------------------------------

  void _startHold(StudioTool tool, Offset position) {
    // A new press anywhere in the rail cancels a hold pending elsewhere.
    _cancelHold();
    if (_panelTool == tool) {
      // Panel already open for this tool: holding again is a no-op.
      return;
    }
    _holdPendingTool = tool;
    _holdStart = position;
    setState(() => _pressingTool = tool); // subtle press affordance
    _holdTimer = Timer(_holdDuration, () {
      _holdTimer = null;
      if (!mounted || _holdPendingTool != tool) {
        return;
      }
      _holdPendingTool = null;
      setState(() => _pressingTool = null);
      _openPropertyPanel(tool);
    });
  }

  void _endHold(StudioTool tool) {
    // Only the tool that OWNS the pending timer may cancel it — a second
    // finger lifting must not abort an in-flight hold elsewhere.
    if (_holdPendingTool == tool) {
      _cancelHold();
      // Release before the hold deadline resolves as a tap-select. The InkWell
      // tap alone is not enough: the button tooltip's long-press recognizer
      // claims the gesture arena and sacrifices the tap, so the aborted hold
      // must select explicitly to keep "tap = select" intact.
      _selectTool(tool);
    }
    if (_pressingTool == tool && mounted) {
      setState(() => _pressingTool = null);
    }
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPendingTool = null;
    _holdStart = null;
  }

  /// Drag-slop reclassifies the press as a scroll/drag: cancel the pending
  /// hold (owned by [tool] only; the button's tap still fires normally).
  void _watchHoldMove(StudioTool tool, PointerMoveEvent event) {
    final Offset? start = _holdStart;
    if (_holdTimer == null || _holdPendingTool != tool || start == null) {
      return;
    }
    if ((event.position - start).distance > _holdSlop) {
      _cancelHold();
      if (mounted && _pressingTool != null) {
        setState(() => _pressingTool = null);
      }
    }
  }

  /// Doc 02 §10.7 design choice (documented): the press-and-hold ALSO SELECTS
  /// the held tool first, then opens its property panel — so the overlay
  /// can never show one tool's rows against another tool's config.
  void _openPropertyPanel(StudioTool tool) {
    _selectTool(tool); // may re-target a previous panel to this tool
    if (!mounted || _panelTool == tool) {
      return;
    }
    _anchorPropertyPanel(tool);
  }

  /// Places [tool]'s panel beside the rail, clamped on-screen, and inserts
  /// the overlay. Split out of [_openPropertyPanel] so a tool switch can move
  /// an already-open panel (round-8 issue 04).
  void _anchorPropertyPanel(StudioTool tool) {
    if (!mounted) {
      return;
    }
    Offset anchor = Offset.zero;
    Size dockSize = Size.zero;
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      anchor = renderObject.localToGlobal(Offset.zero);
      dockSize = renderObject.size;
    }
    // Anchor the panel to the right of the dock, clamped on-screen.
    final Size screen = MediaQuery.sizeOf(context);
    double left = anchor.dx + dockSize.width + 8;
    final double maxLeft = screen.width - _panelWidth - 8;
    if (left > maxLeft) {
      left = maxLeft < 8 ? 8 : maxLeft;
    }
    double top = anchor.dy;
    final double maxTop = screen.height - 64;
    if (top > maxTop) {
      top = maxTop < 8 ? 8 : maxTop;
    }
    final Rect dockRect = Rect.fromLTWH(
      anchor.dx,
      anchor.dy,
      dockSize.width,
      dockSize.height,
    );
    _panelEntry = OverlayEntry(
      builder: (BuildContext overlayContext) => _buildPropertyOverlay(
        tool,
        Offset(left, top),
        dockRect,
        screen,
      ),
    );
    Overlay.of(context).insert(_panelEntry!);
    _panelTool = tool;
  }

  void _closePropertyPanel() {
    final OverlayEntry? entry = _panelEntry;
    _panelEntry = null;
    _panelTool = null;
    entry?.remove();
    entry?.dispose();
  }

  /// Tap-outside barrier (ModalBarrier-free hit test): four strips cover
  /// everything EXCEPT the dock's own rect, so taps that land on the dock
  /// still reach its buttons (tap re-selects, hold re-opens/no-ops) while
  /// any tap outside — panel included via its absorb wrapper — closes the
  /// overlay. The panel itself absorbs taps so its controls keep working.
  Widget _buildPropertyOverlay(
    StudioTool tool,
    Offset anchor,
    Rect dockRect,
    Size screen,
  ) {
    Widget barrier() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _closePropertyPanel,
      child: const SizedBox.expand(),
    );

    double nn(double v) => v < 0 ? 0 : v;

    return Stack(
      children: <Widget>[
        // Top strip (above the dock).
        Positioned(
          left: 0,
          top: 0,
          width: screen.width,
          height: nn(dockRect.top),
          child: barrier(),
        ),
        // Bottom strip (below the dock).
        Positioned(
          left: 0,
          top: dockRect.bottom,
          width: screen.width,
          height: nn(screen.height - dockRect.bottom),
          child: barrier(),
        ),
        // Left strip.
        Positioned(
          left: 0,
          top: dockRect.top,
          width: nn(dockRect.left),
          height: dockRect.height,
          child: barrier(),
        ),
        // Right strip (dock's vertical band, right of it).
        Positioned(
          left: dockRect.right,
          top: dockRect.top,
          width: nn(screen.width - dockRect.right),
          height: dockRect.height,
          child: barrier(),
        ),
        Positioned(
          left: anchor.dx,
          top: anchor.dy,
          child: GestureDetector(
            key: const ValueKey<String>('property-overlay-panel'),
            behavior: HitTestBehavior.opaque,
            child: Material(
              color: StudioTheme.surface,
              elevation: 8,
              borderRadius: BorderRadius.circular(StudioTheme.radiusLarge),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: toolPanelWidth),
                child: SingleChildScrollView(
                  child: ToolPropertyPanel(
                    tool: tool,
                    config: widget.config,
                    snap: _snap,
                    commit: _commit,
                    onOpenCartesian: _showCartesianDialog,
                    onOpenNumberLine: _showNumberLineDialog,
                    onImportImage: _pickAndDeliverImage,
                    ocrPanel: tool == StudioTool.ocr
                        ? widget.ocrPanelBuilder?.call(context)
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Round-6 (Doc 02 §10.7): Clear-canvas utility. The seeded
  // onClearRequested callback fires ONLY after the confirmation dialog is
  // accepted — never on the icon tap itself.
  // ---------------------------------------------------------------------
  Future<void> _confirmClear() async {
    _cancelHold();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Clear entire canvas?'),
        content: const Text(
          'All content will be removed from every connected device.',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('clear-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('clear-confirm'),
            style: FilledButton.styleFrom(backgroundColor: StudioTheme.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.onClearRequested?.call();
    }
  }

  void _showCartesianDialog() {
    // Round-8 issue 04: the property panel is an OverlayEntry inserted above
    // the app's Navigator, so a dialog opened from it would sit UNDERNEATH the
    // panel and be unreachable. Dismiss the panel first — the dialog replaces
    // it as the configuration surface.
    _closePropertyPanel();
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _CartesianGraphDialog(
        onConfirm: (Map<String, dynamic> config) =>
            widget.onGraphCommitted?.call('CARTESIAN_2D', config),
      ),
    ).whenComplete(_clearBuilderGuard);
  }

  void _showNumberLineDialog() {
    _closePropertyPanel(); // same ordering constraint as _showCartesianDialog
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _NumberLineDialog(
        onConfirm: (Map<String, dynamic> config) =>
            widget.onGraphCommitted?.call('NUMBER_LINE', config),
      ),
    ).whenComplete(_clearBuilderGuard);
  }

  /// Releases [_builderOpenFor] once the builder dialog is gone, so selecting
  /// the same graph tool again opens a fresh dialog.
  void _clearBuilderGuard() {
    _builderOpenFor = null;
  }

  Future<void> _pickAndDeliverImage() async {
    final ImagePickFn pick = widget.pickImage ?? _pickImageFromGallery;
    final PickedImage? picked = await pick();
    if (!mounted || picked == null) {
      return;
    }
    final WorldRectPlanner plan =
        widget.planWorldRect ?? _defaultWorldRectPlanner;
    widget.onPickImage?.call(
      PendingImage(
        bytes: picked.bytes,
        filename: picked.filename,
        widthPx: picked.widthPx,
        heightPx: picked.heightPx,
        plannedWorldRect: plan(picked.widthPx, picked.heightPx),
      ),
    );
  }

  Future<PickedImage?> _pickImageFromGallery() async {
    try {
      final XFile? file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (file == null) {
        return null;
      }
      final Uint8List bytes = await file.readAsBytes();
      int widthPx = 0;
      int heightPx = 0;
      try {
        final image = await decodeImageFromList(bytes);
        widthPx = image.width;
        heightPx = image.height;
        image.dispose();
      } catch (_) {
        // Undecodable bytes: keep 0×0; the planner falls back to a square.
      }
      return PickedImage(
        bytes: bytes,
        filename: file.name,
        widthPx: widthPx,
        heightPx: heightPx,
      );
    } catch (_) {
      // Plugin unavailable or picker failed — treat as a cancelled pick.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Round-8 issue 04: the expandable side panel and its toggle are gone —
    // a tool's configuration is reached by PRESSING AND HOLDING that tool for
    // 2000 ms, which opens a compact panel anchored beside the rail
    // (_openPropertyPanel). The dock is now just the rail.
    return _buildRail();
  }

  Widget _buildRail() {
    return Material(
      color: StudioTheme.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      clipBehavior: Clip.antiAlias,
      // Round-9: 14 tools + clear no longer fit a 600 dp-tall viewport on the
      // real device, so the rail scrolls instead of overflowing. The dock is
      // hosted inside a SingleChildScrollView by the canvas page, but a widget
      // test (and any host that sizes it to the viewport) needs its own bound.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 4),
            for (final StudioTool t in StudioTool.values) _buildToolButton(t),
            const SizedBox(height: 4),
            // Round-6 utility row (Doc 02 §10.7): destructive clear, gated by
            // a confirmation dialog before onClearRequested fires.
            const Divider(height: 1, thickness: 1, indent: 6, endIndent: 6),
            IconButton(
              key: const ValueKey<String>('clear-canvas'),
              tooltip: 'Clear canvas',
              onPressed: _confirmClear,
              style: _railButtonStyle(),
              icon: const Icon(
                Icons.layers_clear,
                size: 22,
                color: StudioTheme.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolButton(StudioTool tool) {
    return ValueListenableBuilder<StudioTool>(
      valueListenable: widget.tool,
      builder: (BuildContext context, StudioTool active, Widget? child) {
        final bool selected = active == tool;
        final bool pressing = _pressingTool == tool;
        return Listener(
          // Doc 02 §10.7: pointer-down arms the custom 2000 ms Timer;
          // IconButton.onPressed still provides the instant tap-to-select.
          onPointerDown: (PointerDownEvent e) => _startHold(tool, e.position),
          onPointerUp: (PointerUpEvent e) => _endHold(tool),
          onPointerCancel: (PointerCancelEvent e) => _endHold(tool),
          onPointerMove: (PointerMoveEvent e) => _watchHoldMove(tool, e),
          child: IconButton(
            key: ValueKey<String>('tool-${tool.name}'),
            tooltip: _toolLabel(tool),
            onPressed: () => _selectTool(tool),
            style: _railButtonStyle(
              background: selected ? StudioTheme.bg : null,
            ),
            icon: Icon(
              _toolIcon(tool),
              size: 22,
              color: selected
                  ? StudioTheme.accent
                  : (pressing
                        ? StudioTheme.text.withValues(alpha: 0.4)
                        : StudioTheme.text),
            ),
          ),
        );
      },
    );
  }
}

const TextStyle _bodyStyle = TextStyle(
  color: StudioTheme.text,
  fontSize: StudioTheme.bodySize,
);

/// Doc 24 default planner: fit the long side to 600 world units at (0, 0).
Rect _defaultWorldRectPlanner(int widthPx, int heightPx) {
  const double longSide = 600.0;
  if (widthPx <= 0 || heightPx <= 0) {
    return const Rect.fromLTWH(0, 0, longSide, longSide);
  }
  final double scale = longSide / (widthPx >= heightPx ? widthPx : heightPx);
  return Rect.fromLTWH(0, 0, widthPx * scale, heightPx * scale);
}

String _toolLabel(StudioTool tool) => switch (tool) {
  StudioTool.select => 'Select',
  StudioTool.pen => 'Pen',
  StudioTool.highlighter => 'Highlighter',
  StudioTool.eraser => 'Eraser',
  StudioTool.fill => 'Fill',
  StudioTool.line => 'Line',
  StudioTool.rect => 'Rectangle',
  StudioTool.circle => 'Circle',
  StudioTool.triangle => 'Triangle',
  StudioTool.arrow => 'Arrow',
  StudioTool.polygon => 'Polygon',
  StudioTool.text => 'Text',
  StudioTool.cartesianGraph => 'Cartesian Graph',
  StudioTool.numberLine => 'Number Line',
  StudioTool.table => 'Table',
  StudioTool.image => 'Image',
  StudioTool.ocr => 'OCR Scan',
};

IconData _toolIcon(StudioTool tool) => switch (tool) {
  StudioTool.select => Icons.near_me_outlined,
  StudioTool.pen => Icons.draw,
  StudioTool.highlighter => Icons.highlight,
  StudioTool.eraser => Icons.cleaning_services,
  StudioTool.fill => Icons.format_color_fill,
  StudioTool.line => Icons.horizontal_rule,
  StudioTool.rect => Icons.crop_square,
  StudioTool.circle => Icons.circle,
  StudioTool.triangle => Icons.change_history,
  StudioTool.arrow => Icons.north_east,
  StudioTool.polygon => Icons.pentagon_outlined,
  StudioTool.text => Icons.text_fields,
  StudioTool.cartesianGraph => Icons.show_chart,
  StudioTool.numberLine => Icons.numbers,
  StudioTool.table => Icons.table_chart,
  StudioTool.image => Icons.image,
  StudioTool.ocr => Icons.document_scanner_outlined,
};

List<String>? _splitPair(String text) {
  final List<String> parts = text
      .split(RegExp(r'[,\s]+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  return parts.length == 2 ? parts : null;
}

String? _validatePair(String? text, {required bool integers}) {
  final List<String>? parts = _splitPair((text ?? '').trim());
  if (parts == null) {
    return 'Enter exactly two numbers';
  }
  for (final String part in parts) {
    final double? value = double.tryParse(part);
    if (value == null) {
      return 'Invalid number: $part';
    }
    if (integers && value != value.truncateToDouble()) {
      return 'Enter whole numbers: $part';
    }
  }
  return null;
}

String? _validatePositiveDouble(String? text) {
  final double? value = double.tryParse((text ?? '').trim());
  if (value == null) {
    return 'Invalid number';
  }
  if (value <= 0) {
    return 'Must be greater than 0';
  }
  return null;
}

List<double> _asDoublePair(String text) =>
    _splitPair(text.trim())!.map(double.parse).toList();

List<int> _asIntPair(String text) =>
    _splitPair(text.trim())!
        .map((String p) => double.parse(p).round())
        .toList();

/// Dialog producing the exact Doc 03 `CARTESIAN_2D` graph_config object.
class _CartesianGraphDialog extends StatefulWidget {
  const _CartesianGraphDialog({required this.onConfirm});

  final void Function(Map<String, dynamic> config) onConfirm;

  @override
  State<_CartesianGraphDialog> createState() => _CartesianGraphDialogState();
}

class _CartesianGraphDialogState extends State<_CartesianGraphDialog> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _origin = TextEditingController(text: '250, 450');
  final TextEditingController _xRange = TextEditingController(text: '-10, 10');
  final TextEditingController _yRange = TextEditingController(text: '-10, 10');
  final TextEditingController _gridStep = TextEditingController(text: '25.0');
  bool _showLabels = true;

  @override
  void dispose() {
    _origin.dispose();
    _xRange.dispose();
    _yRange.dispose();
    _gridStep.dispose();
    super.dispose();
  }

  void _insert() {
    final FormState? form = _form.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    final Map<String, dynamic> config = buildCartesianConfig(
      origin: _asDoublePair(_origin.text),
      xRange: _asIntPair(_xRange.text),
      yRange: _asIntPair(_yRange.text),
      gridStep: double.parse(_gridStep.text.trim()),
      showLabels: _showLabels,
    );
    Navigator.of(context).pop();
    widget.onConfirm(config);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cartesian Graph Builder'),
      content: SizedBox(
        width: 320,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                key: const ValueKey<String>('graph-origin'),
                controller: _origin,
                decoration: const InputDecoration(labelText: 'Origin (x, y)'),
                validator: (String? v) => _validatePair(v, integers: false),
              ),
              TextFormField(
                key: const ValueKey<String>('graph-x-range'),
                controller: _xRange,
                decoration: const InputDecoration(
                  labelText: 'X range (min, max)',
                ),
                validator: (String? v) => _validatePair(v, integers: true),
              ),
              TextFormField(
                key: const ValueKey<String>('graph-y-range'),
                controller: _yRange,
                decoration: const InputDecoration(
                  labelText: 'Y range (min, max)',
                ),
                validator: (String? v) => _validatePair(v, integers: true),
              ),
              TextFormField(
                key: const ValueKey<String>('graph-grid-step'),
                controller: _gridStep,
                decoration: const InputDecoration(labelText: 'Grid step'),
                validator: _validatePositiveDouble,
              ),
              CheckboxListTile(
                key: const ValueKey<String>('graph-show-labels'),
                value: _showLabels,
                onChanged: (bool? v) => setState(() => _showLabels = v ?? true),
                title: const Text('Show labels', style: _bodyStyle),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('graph-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('graph-confirm'),
          onPressed: _insert,
          child: const Text('Insert'),
        ),
      ],
    );
  }
}

/// Dialog producing the exact Doc 03 `NUMBER_LINE` graph_config object.
class _NumberLineDialog extends StatefulWidget {
  const _NumberLineDialog({required this.onConfirm});

  final void Function(Map<String, dynamic> config) onConfirm;

  @override
  State<_NumberLineDialog> createState() => _NumberLineDialogState();
}

class _NumberLineDialogState extends State<_NumberLineDialog> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _range = TextEditingController(text: '-10, 10');
  final TextEditingController _step = TextEditingController(text: '1.0');
  bool _showLabels = true;

  @override
  void dispose() {
    _range.dispose();
    _step.dispose();
    super.dispose();
  }

  void _insert() {
    final FormState? form = _form.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    final Map<String, dynamic> config = buildNumberLineConfig(
      range: _asIntPair(_range.text),
      step: double.parse(_step.text.trim()),
      showLabels: _showLabels,
    );
    Navigator.of(context).pop();
    widget.onConfirm(config);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Number Line Builder'),
      content: SizedBox(
        width: 320,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                key: const ValueKey<String>('graph-range'),
                controller: _range,
                decoration: const InputDecoration(
                  labelText: 'Range (min, max)',
                ),
                validator: (String? v) => _validatePair(v, integers: true),
              ),
              TextFormField(
                key: const ValueKey<String>('graph-step'),
                controller: _step,
                decoration: const InputDecoration(labelText: 'Step'),
                validator: _validatePositiveDouble,
              ),
              CheckboxListTile(
                key: const ValueKey<String>('graph-show-labels'),
                value: _showLabels,
                onChanged: (bool? v) => setState(() => _showLabels = v ?? true),
                title: const Text('Show labels', style: _bodyStyle),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('graph-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('graph-confirm'),
          onPressed: _insert,
          child: const Text('Insert'),
        ),
      ],
    );
  }
}
