// Round-6 (Doc 02 §10.7): per-tool property panels for the tool dock.
//
// This file owns the CONTENT of a tool's property panel — the round-5
// controls (tip slider + preview dot, palette swatches, highlighter opacity,
// eraser mode, snapping, graph/image entries) plus the round-6 per-tool
// additions (snap toggle on shapes, graph label/grid hints). The dock file
// (`tool_palette_dock.dart`) stays the orchestrator: it owns the per-tool
// config store, the 2000 ms hold gesture, the overlay anchoring and the
// Clear-canvas confirmation, and renders [ToolPropertyPanel] both in its
// expanded sub-panel and in the long-press overlay.
//
// Pure UI: no network, no platform plugins (Doc 24 §6).

import 'package:flutter/material.dart';
import 'package:mobile_app/core/theme/studio_theme.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart'
    show EraserMode, StudioTool, ToolConfig, toolIdFor;

/// Overlay/sub-panel width shared by the dock's expanded sub-panel and the
/// long-press property overlay (260 dp, frozen from round-5).
const double toolPanelWidth = 260.0;

/// Round-5 issue 02B tip-size control: 0.5–20 dp in 0.5 dp fine steps.
const double tipWidthMin = 0.5;
const double tipWidthMax = 20.0;
const int tipWidthDivisions = 39;

/// Round-5 issue 02B opacity control: 10–100% in 1% steps.
const double opacityMin = 0.1;
const double opacityMax = 1.0;

/// Issue 02B palette: 8 swatches — ink black, theme red, accent blue,
/// green, yellow, true red, purple, white (ring-protected below).
const List<String> swatchColors = <String>[
  '#1E1E1E',
  '#F0546F',
  '#4F8EF7',
  '#2ECC71',
  '#F1C40F',
  '#D64550',
  '#9B59B6',
  '#FFFFFF',
];

const TextStyle toolPanelCaptionStyle = TextStyle(
  color: StudioTheme.text,
  fontSize: StudioTheme.captionSize,
);

const TextStyle toolPanelBodyStyle = TextStyle(
  color: StudioTheme.text,
  fontSize: StudioTheme.bodySize,
);

/// Write-back hook: the dock routes every panel edit through this so the
/// mutation lands on the live `config.value` AND into the per-tool store
/// (`_perTool[current]`), then notifies listeners (Doc 02 §10.7).
typedef ToolConfigCommit = void Function(void Function(ToolConfig) mutate);

/// Property panel body for [tool]: title row (label + `ToolId` byte) plus
/// the per-tool control rows. Rendered both by the dock's expanded sub-panel
/// and by the long-press overlay — identical controls, one implementation.
class ToolPropertyPanel extends StatelessWidget {
  const ToolPropertyPanel({
    super.key,
    required this.tool,
    required this.config,
    required this.snap,
    required this.commit,
    this.onOpenCartesian,
    this.onOpenNumberLine,
    this.onImportImage,
  });

  /// Tool whose rows are rendered (the held tool for the overlay — the hold
  /// gesture also selects it, so this always equals the active tool).
  final StudioTool tool;

  /// Live config notifier (already replaced with this tool's config on
  /// selection); the panel rebuilds on every commit.
  final ValueNotifier<ToolConfig> config;

  /// Dock-local 15° snapping flag (not part of the frozen ToolConfig).
  final ValueNotifier<bool> snap;

  /// Dock write-back (mutate + persist into the per-tool store + notify).
  final ToolConfigCommit commit;

  /// Opens the Doc 03 Cartesian Graph Builder dialog.
  final VoidCallback? onOpenCartesian;

  /// Opens the Doc 03 Number Line Builder dialog.
  final VoidCallback? onOpenNumberLine;

  /// Starts the gallery import flow (bytes delivered by the dock).
  final VoidCallback? onImportImage;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ToolConfig>(
      valueListenable: config,
      builder: (BuildContext context, ToolConfig cfg, Widget? child) {
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
              ..._rows(tool, cfg),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _rows(StudioTool tool, ToolConfig cfg) {
    switch (tool) {
      case StudioTool.select:
        return _selectRows();
      case StudioTool.pen:
        return _strokeRows(tool, cfg);
      case StudioTool.highlighter:
        return _strokeRows(tool, cfg);
      case StudioTool.eraser:
        return _eraserRows(cfg);
      case StudioTool.fill:
        return _fillRows(cfg);
      case StudioTool.line:
        return <Widget>[
          _tipSizeRow(cfg),
          const SizedBox(height: 4),
          _paletteRow(cfg),
          const SizedBox(height: 8),
          ..._snapRows(),
        ];
      case StudioTool.rect:
      case StudioTool.circle:
      case StudioTool.triangle:
      case StudioTool.arrow:
      case StudioTool.polygon:
        return <Widget>[
          _tipSizeRow(cfg),
          const SizedBox(height: 4),
          _paletteRow(cfg),
          const SizedBox(height: 8),
          ..._snapRows(),
          const SizedBox(height: 4),
          Text(
            '${_toolLabel(tool)} selected — drag on the canvas; the live '
            'preview streams ToolId 0x04 (shapePreview).',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.cartesianGraph:
        return <Widget>[
          _tipSizeRow(cfg),
          const SizedBox(height: 4),
          _paletteRow(cfg),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey<String>('open-cartesian'),
            onPressed: onOpenCartesian,
            child: const Text('Open Graph Builder…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inserts CARTESIAN_2D with Doc 03 graph_config (origin, x_range, '
            'y_range, grid_step, show_labels). Label visibility and grid '
            'step live in the builder dialog.',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.numberLine:
        return <Widget>[
          _tipSizeRow(cfg),
          const SizedBox(height: 4),
          _paletteRow(cfg),
          const SizedBox(height: 8),
          FilledButton(
            key: const ValueKey<String>('open-numberline'),
            onPressed: onOpenNumberLine,
            child: const Text('Open Number Line Builder…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inserts NUMBER_LINE with Doc 03 graph_config (range, step, '
            'show_labels). Label visibility and step live in the builder '
            'dialog.',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.table:
        return <Widget>[
          _tipSizeRow(cfg),
          const SizedBox(height: 4),
          _paletteRow(cfg),
          const SizedBox(height: 8),
          const Text(
            'Drag on the canvas to place the table. Rows, columns and the '
            'header bands are chosen in the popup that opens with the tool.',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.image:
        return <Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('pick-image'),
            onPressed: onImportImage,
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Import from gallery…'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Bytes only — the canvas page streams ASSET_START/CHUNK/DONE then '
            'ADD_IMAGE.',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.text:
        return <Widget>[
          _paletteRow(cfg),
          const SizedBox(height: 8),
          const Text(
            'Drag a box, then type with the keyboard. The text lives in the '
            'node\'s graph_config so it survives a round trip.',
            style: toolPanelCaptionStyle,
          ),
        ];
      case StudioTool.ocr:
        return <Widget>[
          const Text(
            'Circle the text you want scanned, or scan the whole canvas. The '
            'PC does the recognition and returns editable text.',
            style: toolPanelCaptionStyle,
          ),
        ];
    }
  }

  /// Round-9 issue 04 — the paint bucket's panel: one colour, no width (a fill
  /// has no stroke of its own; the outline keeps the node's existing colour).
  List<Widget> _fillRows(ToolConfig cfg) {
    return <Widget>[
      _paletteRow(cfg),
      const SizedBox(height: 8),
      const Text(
        'Tap inside a CLOSED shape, or inside a pen loop that ends where it '
        'started. The outline is kept and the interior takes this colour. '
        'Tap a filled shape again to clear its fill.',
        style: toolPanelCaptionStyle,
      ),
    ];
  }

  List<Widget> _strokeRows(StudioTool tool, ToolConfig cfg) {
    return <Widget>[
      _tipSizeRow(cfg),
      // Issue 02B: opacity is a highlighter-panel-only control (pen strokes
      // commit without opacity in Doc 21's StrokeProcessor; opacity drives
      // the highlighter's multiply blend).
      if (tool == StudioTool.highlighter) ...<Widget>[
        const SizedBox(height: 4),
        _opacityRow(cfg),
      ],
      const SizedBox(height: 4),
      _paletteRow(cfg),
      if (tool == StudioTool.highlighter) ...<Widget>[
        const SizedBox(height: 4),
        _multiplyNote(),
      ],
    ];
  }

  /// Round-8 issue 07 — the selector's own panel. The tool has no paint
  /// settings; it documents the gesture set (and the free-stroke resize
  /// restriction, which is the one non-obvious rule).
  List<Widget> _selectRows() {
    return <Widget>[
      const Text('Tap an object to select it', style: toolPanelCaptionStyle),
      const SizedBox(height: 6),
      const Text(
        'Drag inside the selection to move it. Drag a corner or edge '
        'handle to resize — except free-hand pen strokes, which can only '
        'be moved or deleted (drag a marquee around them to select).',
        style: toolPanelCaptionStyle,
      ),
    ];
  }

  /// Eraser: brush (default) vs whole-element mode + eraser radius
  /// (ToolConfig.width) and a caption naming the RPC contract.
  ///
  /// Round-8 issue 03: brush splits strokes into the fragments outside the
  /// swept disc (ADD_STROKE ×N + DELETE_NODE of the original) so it behaves
  /// like a real eraser; element mode keeps the old whole-node delete.
  List<Widget> _eraserRows(ToolConfig cfg) {
    return <Widget>[
      SegmentedButton<EraserMode>(
        segments: const <ButtonSegment<EraserMode>>[
          ButtonSegment<EraserMode>(
            value: EraserMode.brush,
            label: Text('brush'),
          ),
          ButtonSegment<EraserMode>(
            value: EraserMode.element,
            label: Text('element'),
          ),
        ],
        selected: <EraserMode>{cfg.eraserMode},
        showSelectedIcon: false,
        onSelectionChanged: (Set<EraserMode> next) =>
            commit((ToolConfig c) => c.eraserMode = next.first),
      ),
      const SizedBox(height: 8),
      _tipSizeRow(cfg, label: 'Eraser radius'),
      const SizedBox(height: 4),
      const Text(
        'Brush: the stroke is split around the swept disc — the rest '
        'survives. Element: the whole hit node is deleted. Radius writes '
        'ToolConfig.width; RPC lives in the canvas page.',
        style: toolPanelCaptionStyle,
      ),
    ];
  }

  /// Doc 02 §10.7: snapping is exposed on the line AND every shape panel;
  /// the flag stays dock-local (frozen ToolConfig has no snap field).
  List<Widget> _snapRows() {
    return <Widget>[
      ValueListenableBuilder<bool>(
        valueListenable: snap,
        builder: (BuildContext context, bool enabled, Widget? child) {
          return Row(
            children: <Widget>[
              Switch(
                key: const ValueKey<String>('snap-toggle'),
                value: enabled,
                onChanged: (bool v) => snap.value = v,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Snapping', style: toolPanelBodyStyle),
              ),
            ],
          );
        },
      ),
      const Text(
        'Fixed 15° increment; cardinals 0/90/180/270° always included.',
        style: toolPanelCaptionStyle,
      ),
    ];
  }

  /// Round-5 issue 02B: width slider (0.5–20 dp, 0.5 fine-step snapping)
  /// with a live value label and a preview dot scaled to the current tip
  /// width. The eraser panel reuses it for the precision hit radius.
  Widget _tipSizeRow(ToolConfig cfg, {String label = 'Width'}) {
    final double width = _clampTipWidth(cfg.width);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '$label ${width.toStringAsFixed(1)} dp',
                key: const ValueKey<String>('tip-size-label'),
                style: toolPanelCaptionStyle,
              ),
            ),
            _tipPreviewDot(width, cfg.color),
          ],
        ),
        Slider(
          key: const ValueKey<String>('width-slider'),
          value: width,
          min: tipWidthMin,
          max: tipWidthMax,
          divisions: tipWidthDivisions,
          label: '${width.toStringAsFixed(1)} dp',
          onChanged: (double v) {
            final double snapped = (_clampTipWidth(v) * 2).round() / 2;
            commit((ToolConfig c) => c.width = snapped);
          },
        ),
      ],
    );
  }

  /// Preview dot: a circle whose diameter equals the tip width in dp,
  /// tinted with the current color, in a fixed 24 dp slot so the row
  /// height never jumps while dragging.
  Widget _tipPreviewDot(double width, String hex) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Container(
          key: const ValueKey<String>('tip-preview-dot'),
          width: width,
          height: width,
          decoration: BoxDecoration(
            color: _colorFromHex(hex),
            shape: BoxShape.circle,
            border: Border.all(color: StudioTheme.text, width: 0.5),
          ),
        ),
      ),
    );
  }

  /// Round-5 issue 02B / Doc 24 §3: 10–100% opacity slider bound to
  /// `ToolConfig.opacity`, shown on the highlighter panel only.
  Widget _opacityRow(ToolConfig cfg) {
    final double opacity = _clampOpacity(cfg.opacity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Opacity ${(opacity * 100).round()}%',
          key: const ValueKey<String>('opacity-label'),
          style: toolPanelCaptionStyle,
        ),
        Slider(
          key: const ValueKey<String>('opacity-slider'),
          value: opacity,
          min: opacityMin,
          max: opacityMax,
          divisions: 90,
          label: '${(opacity * 100).round()}%',
          onChanged: (double v) {
            final double snapped = (_clampOpacity(v) * 100).roundToDouble() / 100;
            commit((ToolConfig c) => c.opacity = snapped);
          },
        ),
      ],
    );
  }

  /// Swatch row with a selected-check indicator.
  Widget _paletteRow(ToolConfig cfg) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final String hex in swatchColors) _swatch(hex, cfg),
      ],
    );
  }

  Widget _swatch(String hex, ToolConfig cfg) {
    final bool selected = cfg.color == hex;
    // White gets a fixed gray ring so it stays visible on light surfaces.
    final Color ring = hex == '#FFFFFF'
        ? const Color(0xFF9E9E9E)
        : StudioTheme.text;
    return InkWell(
      key: ValueKey<String>('swatch-$hex'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => commit((ToolConfig c) => c.color = hex),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _colorFromHex(hex),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? StudioTheme.accent : ring,
            width: selected ? 2 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 16,
                color: _colorFromHex(hex).computeLuminance() > 0.5
                    ? Colors.black87
                    : Colors.white,
              )
            : null,
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
        style: toolPanelCaptionStyle,
      ),
    );
  }
}

double _clampTipWidth(double v) => v.clamp(tipWidthMin, tipWidthMax).toDouble();

double _clampOpacity(double v) => v.clamp(opacityMin, opacityMax).toDouble();

Color _colorFromHex(String hex) =>
    Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

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
