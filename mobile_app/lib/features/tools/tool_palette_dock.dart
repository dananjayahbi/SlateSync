// Doc 24: Flutter drawing toolset palette — floating, collapsible tool dock.
//
// Pure UI state: owns ValueNotifiers and emits DTOs (ToolConfig, PendingImage,
// graph-config maps) plus callbacks. It never imports network or camera code —
// the canvas page (Wave 3.A) wires sendRpc / ASSET_* / DELETE_NODE per Doc 02.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/theme/studio_theme.dart';

/// Tools exposed by the dock rail (Doc 24 §4).
enum StudioTool {
  pen,
  highlighter,
  eraser,
  line,
  rect,
  circle,
  triangle,
  arrow,
  cartesianGraph,
  numberLine,
  image,
}

/// Eraser behavior (Doc 24 §4). Both modes commit via DELETE_NODE of the
/// hit-tested node; the hit-test itself lives in the canvas page (Doc 22).
enum EraserMode { precision, stroke }

/// Mutable tool styling with Doc 24 §6 defaults: `#1E1E1E` @ `2.5` @ `1.0`,
/// `SRC_OVER`, non-highlighter, precision eraser. `blendMode` is forced to
/// `MULTIPLY` while [highlighter] is true.
class ToolConfig {
  String color = '#1E1E1E';
  double width = 2.5;
  double opacity = 1.0;
  String blendMode = 'SRC_OVER';
  bool highlighter = false;
  EraserMode eraserMode = EraserMode.precision;
}

/// Doc 05 `ToolId` byte for [tool]. Pen streams `LIVE_POINT`, highlighter
/// streams MULTIPLY frames, eraser streams nothing (RPC only), every other
/// tool streams `ToolId.shapePreview` previews — image streams no frames
/// either, but shares byte `0x04` as its placement identifier.
int toolIdFor(StudioTool tool) => switch (tool) {
  StudioTool.pen => ToolId.pen,
  StudioTool.highlighter => ToolId.highlighter,
  StudioTool.eraser => ToolId.eraser,
  StudioTool.line ||
  StudioTool.rect ||
  StudioTool.circle ||
  StudioTool.triangle ||
  StudioTool.arrow ||
  StudioTool.cartesianGraph ||
  StudioTool.numberLine ||
  StudioTool.image => ToolId.shapePreview,
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
    this.pickImage,
    this.planWorldRect,
    this.snapEnabled,
  });

  /// Injected; dock mutates `value` in place (Doc 24 §4).
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

  /// Gallery picker override; defaults to `image_picker`.
  final ImagePickFn? pickImage;

  /// World-rect planner override; defaults to a 600-unit long-side fit.
  final WorldRectPlanner? planWorldRect;

  /// Dock-local 15° snapping flag; a notifier is created when omitted.
  final ValueNotifier<bool>? snapEnabled;

  @override
  State<ToolDock> createState() => _ToolDockState();
}

class _ToolDockState extends State<ToolDock> {
  static const double _panelWidth = 260.0;
  static const Duration _anim = Duration(milliseconds: 180);
  static const ValueKey<String> _toggleKey = ValueKey<String>('dock-toggle');

  static const List<String> _swatchColors = <String>[
    '#1E1E1E',
    '#F0546F',
    '#4F8EF7',
    '#2ECC71',
    '#F1C40F',
    '#E67E22',
    '#9B59B6',
    '#FFFFFF',
  ];

  bool _expanded = false;
  late final ValueNotifier<bool> _snap;
  bool _ownsSnap = false;

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
  }

  @override
  void dispose() {
    if (_ownsSnap) {
      _snap.dispose();
    }
    super.dispose();
  }

  /// Doc 24 §4: mutate the injected config in place, then nudge listeners —
  /// `ValueNotifier.value` only notifies on reference change.
  void _commit(void Function(ToolConfig update) mutate) {
    mutate(widget.config.value);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    widget.config.notifyListeners();
  }

  void _selectTool(StudioTool next) {
    widget.tool.value = next;
    final bool wantHighlighter = next == StudioTool.highlighter;
    _commit((ToolConfig cfg) {
      cfg.highlighter = wantHighlighter;
      cfg.blendMode = wantHighlighter ? 'MULTIPLY' : 'SRC_OVER';
    });
  }

  void _toggleDock() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  void _showCartesianDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _CartesianGraphDialog(
        onConfirm: (Map<String, dynamic> config) =>
            widget.onGraphCommitted?.call('CARTESIAN_2D', config),
      ),
    );
  }

  void _showNumberLineDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _NumberLineDialog(
        onConfirm: (Map<String, dynamic> config) =>
            widget.onGraphCommitted?.call('NUMBER_LINE', config),
      ),
    );
  }

  Future<void> _pickAndDeliverImage() async {
    final ImagePickFn pick = widget.pickImage ?? _pickImageFromGallery;
    final PickedImage? picked = await pick();
    if (!mounted || picked == null) {
      return;
    }
    final WorldRectPlanner plan = widget.planWorldRect ?? _defaultWorldRectPlanner;
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildRail(),
        AnimatedContainer(
          duration: _anim,
          curve: Curves.easeOut,
          width: _expanded ? _panelWidth : 0,
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: StudioTheme.surface,
            borderRadius: BorderRadius.circular(StudioTheme.radiusLarge),
          ),
          child: _expanded
              ? OverflowBox(
                  fit: OverflowBoxFit.deferToChild,
                  alignment: Alignment.topLeft,
                  minWidth: _panelWidth,
                  maxWidth: _panelWidth,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Material(
                    type: MaterialType.transparency,
                    child: SingleChildScrollView(
                      key: const ValueKey<String>('dock-panel'),
                      child: _buildPanelContent(),
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildRail() {
    return Material(
      color: StudioTheme.surface,
      elevation: 6,
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            key: _toggleKey,
            tooltip: _expanded ? 'Collapse tools' : 'Expand tools',
            onPressed: _toggleDock,
            icon: Icon(
              _expanded ? Icons.chevron_left : Icons.chevron_right,
              size: 22,
              color: StudioTheme.text,
            ),
          ),
          const Divider(height: 1, thickness: 1, indent: 6, endIndent: 6),
          const SizedBox(height: 4),
          for (final StudioTool t in StudioTool.values) _buildToolButton(t),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildToolButton(StudioTool tool) {
    return ValueListenableBuilder<StudioTool>(
      valueListenable: widget.tool,
      builder: (BuildContext context, StudioTool active, Widget? child) {
        final bool selected = active == tool;
        return IconButton(
          key: ValueKey<String>('tool-${tool.name}'),
          tooltip: _toolLabel(tool),
          onPressed: () => _selectTool(tool),
          style: selected
              ? IconButton.styleFrom(backgroundColor: StudioTheme.bg)
              : null,
          icon: Icon(
            _toolIcon(tool),
            size: 22,
            color: selected ? StudioTheme.accent : StudioTheme.text,
          ),
        );
      },
    );
  }

  Widget _buildPanelContent() {
    return ValueListenableBuilder<StudioTool>(
      valueListenable: widget.tool,
      builder: (BuildContext context, StudioTool tool, Widget? child) {
        return ValueListenableBuilder<ToolConfig>(
          valueListenable: widget.config,
          builder: (BuildContext context, ToolConfig cfg, Widget? child) {
            return _panelBody(tool, cfg);
          },
        );
      },
    );
  }

  Widget _panelBody(StudioTool tool, ToolConfig cfg) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _toolLabel(tool),
                  style: const TextStyle(
                    color: StudioTheme.text,
                    fontSize: StudioTheme.titleSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '0x${toolIdFor(tool).toRadixString(16).padLeft(2, '0')}',
                style: const TextStyle(
                  color: StudioTheme.accent,
                  fontSize: StudioTheme.captionSize,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._panelRows(tool, cfg),
        ],
      ),
    );
  }

  List<Widget> _panelRows(StudioTool tool, ToolConfig cfg) {
    switch (tool) {
      case StudioTool.pen:
      case StudioTool.highlighter:
        return _strokeRows(tool, cfg);
      case StudioTool.eraser:
        return <Widget>[
          SegmentedButton<EraserMode>(
            segments: const <ButtonSegment<EraserMode>>[
              ButtonSegment<EraserMode>(
                value: EraserMode.precision,
                label: Text('precision'),
              ),
              ButtonSegment<EraserMode>(
                value: EraserMode.stroke,
                label: Text('stroke'),
              ),
            ],
            selected: <EraserMode>{cfg.eraserMode},
            showSelectedIcon: false,
            onSelectionChanged: (Set<EraserMode> next) =>
                _commit((ToolConfig c) => c.eraserMode = next.first),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap a node: DELETE_NODE of the hit-tested node. Drag: same '
            'action per hit node. Hit-test and RPC live in the canvas page.',
            style: _captionStyle,
          ),
        ];
      case StudioTool.line:
        return <Widget>[
          ValueListenableBuilder<bool>(
            valueListenable: _snap,
            builder: (BuildContext context, bool enabled, Widget? child) {
              return Row(
                children: <Widget>[
                  Switch(
                    key: const ValueKey<String>('snap-toggle'),
                    value: enabled,
                    onChanged: (bool v) => _snap.value = v,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Snapping', style: _bodyStyle),
                  ),
                ],
              );
            },
          ),
          const Text(
            'Fixed 15° increment; cardinals 0/90/180/270° always included.',
            style: _captionStyle,
          ),
        ];
      case StudioTool.rect:
      case StudioTool.circle:
      case StudioTool.triangle:
      case StudioTool.arrow:
        return <Widget>[
          Text(
            '${_toolLabel(tool)} selected — drag on the canvas; the live '
            'preview streams ToolId 0x04 (shapePreview).',
            style: _captionStyle,
          ),
          const SizedBox(height: 8),
          Text(
            'Style: ${cfg.color} · ${cfg.width.toStringAsFixed(1)} dp · '
            'opacity ${(cfg.opacity * 100).round()}% · ${cfg.blendMode}',
            style: _captionStyle,
          ),
        ];
      case StudioTool.cartesianGraph:
        return <Widget>[
          FilledButton(
            key: const ValueKey<String>('open-cartesian'),
            onPressed: _showCartesianDialog,
            child: const Text('Open Graph Builder…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inserts CARTESIAN_2D with Doc 03 graph_config (origin, x_range, '
            'y_range, grid_step, show_labels).',
            style: _captionStyle,
          ),
        ];
      case StudioTool.numberLine:
        return <Widget>[
          FilledButton(
            key: const ValueKey<String>('open-numberline'),
            onPressed: _showNumberLineDialog,
            child: const Text('Open Number Line Builder…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inserts NUMBER_LINE with Doc 03 graph_config (range, step, '
            'show_labels).',
            style: _captionStyle,
          ),
        ];
      case StudioTool.image:
        return <Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('pick-image'),
            onPressed: _pickAndDeliverImage,
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Import from gallery…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Bytes only — the canvas page streams ASSET_START/CHUNK/DONE then '
            'ADD_IMAGE.',
            style: _captionStyle,
          ),
        ];
    }
  }

  List<Widget> _strokeRows(StudioTool tool, ToolConfig cfg) {
    return <Widget>[
      Text(
        'Width ${cfg.width.toStringAsFixed(1)} dp',
        style: _captionStyle,
      ),
      Slider(
        key: const ValueKey<String>('width-slider'),
        value: cfg.width.clamp(0.5, 24.0).toDouble(),
        min: 0.5,
        max: 24.0,
        onChanged: (double v) => _commit((ToolConfig c) => c.width = v),
      ),
      Text(
        'Opacity ${(cfg.opacity * 100).round()}%',
        style: _captionStyle,
      ),
      Slider(
        key: const ValueKey<String>('opacity-slider'),
        value: cfg.opacity.clamp(0.1, 1.0).toDouble(),
        min: 0.1,
        max: 1.0,
        onChanged: (double v) => _commit((ToolConfig c) => c.opacity = v),
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final String hex in _swatchColors) _swatch(hex, cfg),
        ],
      ),
      if (tool == StudioTool.highlighter) _multiplyNote(),
    ];
  }

  Widget _swatch(String hex, ToolConfig cfg) {
    final bool selected = cfg.color == hex;
    return InkWell(
      key: ValueKey<String>('swatch-$hex'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => _commit((ToolConfig c) => c.color = hex),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: _colorFromHex(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? StudioTheme.accent : StudioTheme.text,
            width: selected ? 2 : 0.5,
          ),
        ),
      ),
    );
  }

  Widget _multiplyNote() {
    return Container(
      key: const ValueKey<String>('multiply-note'),
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: StudioTheme.bg,
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      ),
      child: const Text(
        'Multiply blend (GL: GL_DST_COLOR,GL_ZERO / cairo: '
        'CAIRO_OPERATOR_MULTIPLY)',
        style: _captionStyle,
      ),
    );
  }
}

const TextStyle _captionStyle = TextStyle(
  color: StudioTheme.text,
  fontSize: StudioTheme.captionSize,
);

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

Color _colorFromHex(String hex) =>
    Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

String _toolLabel(StudioTool tool) => switch (tool) {
  StudioTool.pen => 'Pen',
  StudioTool.highlighter => 'Highlighter',
  StudioTool.eraser => 'Eraser',
  StudioTool.line => 'Line',
  StudioTool.rect => 'Rectangle',
  StudioTool.circle => 'Circle',
  StudioTool.triangle => 'Triangle',
  StudioTool.arrow => 'Arrow',
  StudioTool.cartesianGraph => 'Cartesian Graph',
  StudioTool.numberLine => 'Number Line',
  StudioTool.image => 'Image',
};

IconData _toolIcon(StudioTool tool) => switch (tool) {
  StudioTool.pen => Icons.draw,
  StudioTool.highlighter => Icons.highlight,
  StudioTool.eraser => Icons.cleaning_services,
  StudioTool.line => Icons.horizontal_rule,
  StudioTool.rect => Icons.crop_square,
  StudioTool.circle => Icons.circle,
  StudioTool.triangle => Icons.change_history,
  StudioTool.arrow => Icons.north_east,
  StudioTool.cartesianGraph => Icons.show_chart,
  StudioTool.numberLine => Icons.numbers,
  StudioTool.image => Icons.image,
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

List<int> _asIntPair(String text) => _splitPair(
  text.trim(),
)!.map((String p) => double.parse(p).round()).toList();

/// Dialog producing the exact Doc 03 `CARTESIAN_2D` graph_config object.
class _CartesianGraphDialog extends StatefulWidget {
  const _CartesianGraphDialog({required this.onConfirm});

  final void Function(Map<String, dynamic> config) onConfirm;

  @override
  State<_CartesianGraphDialog> createState() => _CartesianGraphDialogState();
}

class _CartesianGraphDialogState extends State<_CartesianGraphDialog> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _origin = TextEditingController(
    text: '250, 450',
  );
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
                validator: (String? v) =>
                    _validatePair(v, integers: false),
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
                onChanged: (bool? v) =>
                    setState(() => _showLabels = v ?? true),
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
                onChanged: (bool? v) =>
                    setState(() => _showLabels = v ?? true),
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
