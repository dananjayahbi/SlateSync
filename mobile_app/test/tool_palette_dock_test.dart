import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';

/// Doc 24 §6 acceptance: `ToolConfig` defaults, the `StudioTool` → `ToolId`
/// byte table, Doc 03 `graph_config` builders (both example objects), the
/// dock expand/collapse flow, eraser mode toggle, highlighter blend switching,
/// snapping, the pluggable image flow and the Graph Builder dialogs — all
/// pure UI: no sockets, no `sendRpc`, no platform plugins.
void main() {
  const ValueKey<String> dockToggle = ValueKey<String>('dock-toggle');
  const ValueKey<String> dockPanel = ValueKey<String>('dock-panel');

  Future<void> pumpDock(
    WidgetTester tester, {
    required ValueNotifier<ToolConfig> config,
    required ValueNotifier<StudioTool> tool,
    ValueNotifier<bool>? snap,
    ImagePickFn? pickImage,
    void Function(PendingImage img)? onPickImage,
    void Function(String shapeType, Map<String, dynamic> graphConfig)?
    onGraphCommitted,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ToolDock(
              config: config,
              tool: tool,
              snapEnabled: snap,
              pickImage: pickImage,
              onPickImage: onPickImage,
              onGraphCommitted: onGraphCommitted,
            ),
          ),
        ),
      ),
    );
  }

  group('ToolConfig defaults (Doc 24 §6)', () {
    test('exact frozen defaults', () {
      final ToolConfig cfg = ToolConfig();
      expect(cfg.color, '#1E1E1E');
      expect(cfg.width, 2.5);
      expect(cfg.opacity, 1.0);
      expect(cfg.blendMode, 'SRC_OVER');
      expect(cfg.highlighter, isFalse);
      expect(cfg.eraserMode, EraserMode.precision);
    });
  });

  group('issue 02B: tip size, palette, opacity', () {
    const ValueKey<String> widthSlider = ValueKey<String>('width-slider');
    const ValueKey<String> previewDot = ValueKey<String>('tip-preview-dot');
    const ValueKey<String> tipLabel = ValueKey<String>('tip-size-label');
    const ValueKey<String> opacitySlider = ValueKey<String>('opacity-slider');

    testWidgets(
      'width slider spans 0.5–20 dp, snaps 0.5 steps, clamps and writes '
      'config.width',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);
        await tester.tap(find.byKey(dockToggle));
        await tester.pumpAndSettle();

        final Slider slider = tester.widget<Slider>(find.byKey(widthSlider));
        expect(slider.min, 0.5);
        expect(slider.max, 20.0);
        expect(slider.divisions, 39, reason: '0.5 dp fine steps');
        expect(slider.value, 2.5, reason: 'default tip width');

        // Snaps to the nearest 0.5 dp step.
        slider.onChanged!(7.4);
        await tester.pump();
        expect(config.value.width, 7.5);

        // Clamps at the top of the range.
        slider.onChanged!(50);
        await tester.pump();
        expect(config.value.width, 20.0);
        expect(tester.widget<Slider>(find.byKey(widthSlider)).value, 20.0);

        // Clamps at the bottom of the range.
        slider.onChanged!(0.1);
        await tester.pump();
        expect(config.value.width, 0.5);

        // Live value label reflects the clamped width.
        expect(tester.widget<Text>(find.byKey(tipLabel)).data, 'Width 0.5 dp');
      },
    );

    testWidgets('preview dot scales with config.width', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      // Default 2.5 dp → 2.5 × 2.5 dp dot.
      Size size = tester.getSize(find.byKey(previewDot));
      expect(size.width, closeTo(2.5, 0.001));
      expect(size.height, closeTo(2.5, 0.001));

      tester.widget<Slider>(find.byKey(widthSlider)).onChanged!(12);
      await tester.pump();
      size = tester.getSize(find.byKey(previewDot));
      expect(size.width, closeTo(12.0, 0.001));
      expect(size.height, closeTo(12.0, 0.001));
    });

    testWidgets('palette sets exact hexes and shows the check indicator', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      const List<String> palette = <String>[
        '#1E1E1E',
        '#F0546F',
        '#4F8EF7',
        '#2ECC71',
        '#F1C40F',
        '#D64550',
        '#9B59B6',
        '#FFFFFF',
      ];
      expect(palette, hasLength(8));

      for (final String hex in palette) {
        await tester.tap(find.byKey(ValueKey<String>('swatch-$hex')));
        await tester.pump();
        expect(config.value.color, hex, reason: 'swatch $hex');
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('swatch-$hex')),
            matching: find.byIcon(Icons.check),
          ),
          findsOneWidget,
          reason: 'check indicator on $hex',
        );
      }

      // White swatch must carry a fixed gray ring when unselected.
      await tester.tap(find.byKey(const ValueKey<String>('swatch-#1E1E1E')));
      await tester.pump();
      final Container white = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('swatch-#FFFFFF')),
          matching: find.byType(Container),
        ),
      );
      final BoxDecoration whiteDeco = white.decoration! as BoxDecoration;
      expect(whiteDeco.border?.top.color, const Color(0xFF9E9E9E));
      expect(config.value.color, '#1E1E1E');
    });

    testWidgets(
      'opacity slider lives on the highlighter panel only, spans 10–100%, '
      'clamps and writes config.opacity',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);
        await tester.tap(find.byKey(dockToggle));
        await tester.pumpAndSettle();

        // Pen panel: no opacity slider (issue 02B: highlighter only).
        expect(find.byKey(opacitySlider), findsNothing);

        await tester.tap(
          find.byKey(const ValueKey<String>('tool-highlighter')),
        );
        await tester.pumpAndSettle();

        final Slider opacity = tester.widget<Slider>(find.byKey(opacitySlider));
        expect(opacity.min, 0.1);
        expect(opacity.max, 1.0);
        expect(opacity.value, 1.0, reason: 'default opacity');

        opacity.onChanged!(0.05);
        await tester.pump();
        expect(config.value.opacity, 0.1, reason: 'clamp to 10%');

        opacity.onChanged!(9);
        await tester.pump();
        expect(config.value.opacity, 1.0, reason: 'clamp to 100%');

        opacity.onChanged!(0.42);
        await tester.pump();
        expect(config.value.opacity, 0.42, reason: '1% fine steps');

        // Multiply note stays glued to the highlighter panel.
        expect(
          find.byKey(const ValueKey<String>('multiply-note')),
          findsOneWidget,
        );
      },
    );

    testWidgets('eraser precision reuses ToolConfig.width as hit radius', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);
      await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
      await tester.pump();
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      final Slider slider = tester.widget<Slider>(find.byKey(widthSlider));
      expect(slider.min, 0.5);
      expect(slider.max, 20.0);
      expect(
        tester.widget<Text>(find.byKey(tipLabel)).data,
        'Hit radius 2.5 dp',
      );

      slider.onChanged!(8);
      await tester.pump();
      expect(config.value.width, 8.0);
      expect(
        tester.widget<Text>(find.byKey(tipLabel)).data,
        'Hit radius 8.0 dp',
      );
      // Preview dot reuses the same scaled size for the eraser.
      expect(tester.getSize(find.byKey(previewDot)).width, closeTo(8.0, 0.001));
    });
  });

  group('StudioTool → ToolId byte table (Doc 24 §4)', () {
    const Map<StudioTool, int> expected = <StudioTool, int>{
      StudioTool.pen: 0x01,
      StudioTool.highlighter: 0x02,
      StudioTool.eraser: 0x03,
      StudioTool.line: 0x04,
      StudioTool.rect: 0x04,
      StudioTool.circle: 0x04,
      StudioTool.triangle: 0x04,
      StudioTool.arrow: 0x04,
      StudioTool.cartesianGraph: 0x04,
      StudioTool.numberLine: 0x04,
      StudioTool.image: 0x04,
    };

    test('all 11 StudioTool values map to the expected byte', () {
      expect(StudioTool.values.length, 11);
      expect(expected.keys, containsAll(StudioTool.values));
      expected.forEach((StudioTool tool, int byte) {
        expect(toolIdFor(tool), byte, reason: 'toolIdFor($tool)');
      });
    });

    test('matches Doc 05 ToolId constants', () {
      expect(toolIdFor(StudioTool.pen), ToolId.pen);
      expect(toolIdFor(StudioTool.highlighter), ToolId.highlighter);
      expect(toolIdFor(StudioTool.eraser), ToolId.eraser);
      expect(toolIdFor(StudioTool.line), ToolId.shapePreview);
      expect(toolIdFor(StudioTool.cartesianGraph), ToolId.shapePreview);
      expect(toolIdFor(StudioTool.image), ToolId.shapePreview);
    });
  });

  group('graph_config builders (Doc 03)', () {
    test('buildCartesianConfig: key set + Doc 03 example fidelity', () {
      final Map<String, dynamic> cfg = buildCartesianConfig(
        origin: const <double>[250.0, 450.0],
        xRange: const <int>[-10, 10],
        yRange: const <int>[-10, 10],
        gridStep: 25.0,
      );
      expect(
        cfg.keys,
        unorderedEquals(<String>[
          'origin',
          'x_range',
          'y_range',
          'grid_step',
          'show_labels',
        ]),
      );
      expect(cfg['origin'], const <double>[250.0, 450.0]);
      expect(cfg['origin'], isA<List<double>>());
      expect(cfg['x_range'], const <int>[-10, 10]);
      expect(cfg['y_range'], const <int>[-10, 10]);
      expect(cfg['grid_step'], 25.0);
      expect(cfg['grid_step'], isA<double>(), reason: 'no int truncation');
      expect(cfg['show_labels'], isTrue);
      expect(cfg['show_labels'], isA<bool>());
    });

    test('buildCartesianConfig: showLabels false round-trips', () {
      final Map<String, dynamic> cfg = buildCartesianConfig(
        origin: const <double>[0.0, 0.0],
        xRange: const <int>[-5, 5],
        yRange: const <int>[-5, 5],
        gridStep: 10.5,
        showLabels: false,
      );
      expect(cfg['show_labels'], isFalse);
      expect(cfg['grid_step'], 10.5);
      expect(cfg['grid_step'], isA<double>());
    });

    test('buildNumberLineConfig: key set + Doc 03 example fidelity', () {
      final Map<String, dynamic> cfg = buildNumberLineConfig(
        range: const <int>[-10, 10],
        step: 1.0,
      );
      expect(
        cfg.keys,
        unorderedEquals(<String>['range', 'step', 'show_labels']),
      );
      expect(cfg['range'], const <int>[-10, 10]);
      expect(cfg['step'], 1.0);
      expect(cfg['step'], isA<double>(), reason: 'no int truncation');
      expect(cfg['show_labels'], isTrue);
    });

    test('buildNumberLineConfig: showLabels false round-trips', () {
      final Map<String, dynamic> cfg = buildNumberLineConfig(
        range: const <int>[0, 100],
        step: 0.5,
        showLabels: false,
      );
      expect(cfg['show_labels'], isFalse);
      expect(cfg['step'], 0.5);
    });
  });

  group('pure UI guarantee (Doc 24 §6)', () {
    test('dock source imports no network code', () {
      final String src = File('lib/features/tools/tool_palette_dock.dart')
          .readAsStringSync();
      expect(src, isNot(contains('web_socket_channel')));
      expect(src, isNot(contains('vector_sync_client.dart')));
    });
  });

  group('dock widget flow', () {
    testWidgets('toggle expands and collapses the sub-panel', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);

      expect(find.byKey(dockPanel), findsNothing);

      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(dockPanel), findsOneWidget);

      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();
      expect(find.byKey(dockPanel), findsNothing);
    });

    testWidgets('highlighter forces MULTIPLY; pen restores SRC_OVER', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('tool-highlighter')));
      await tester.pump();
      expect(config.value.highlighter, isTrue);
      expect(config.value.blendMode, 'MULTIPLY');
      expect(find.textContaining('GL_DST_COLOR'), findsOneWidget);
      expect(find.textContaining('CAIRO_OPERATOR_MULTIPLY'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('tool-pen')));
      await tester.pump();
      expect(config.value.highlighter, isFalse);
      expect(config.value.blendMode, 'SRC_OVER');
      expect(find.textContaining('GL_DST_COLOR'), findsNothing);
    });

    testWidgets('eraser segmented toggle writes eraserMode', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);

      await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
      await tester.pump();
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      expect(config.value.eraserMode, EraserMode.precision);
      expect(find.textContaining('DELETE_NODE'), findsOneWidget);

      await tester.tap(find.text('stroke'));
      await tester.pump();
      expect(config.value.eraserMode, EraserMode.stroke);

      await tester.tap(find.text('precision'));
      await tester.pump();
      expect(config.value.eraserMode, EraserMode.precision);
    });

    testWidgets('width slider and color swatch mutate ToolConfig in place', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      tester
          .widget<Slider>(find.byKey(const ValueKey<String>('width-slider')))
          .onChanged!(7.5);
      await tester.pump();
      expect(config.value.width, 7.5);

      await tester.tap(find.byKey(const ValueKey<String>('swatch-#F0546F')));
      await tester.pump();
      expect(config.value.color, '#F0546F');
    });

    testWidgets('line panel flips the dock-local snap flag', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.line,
      );
      final ValueNotifier<bool> snap = ValueNotifier<bool>(true);
      await pumpDock(tester, config: config, tool: tool, snap: snap);
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      expect(find.textContaining('15'), findsOneWidget);
      expect(snap.value, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('snap-toggle')));
      await tester.pump();
      expect(snap.value, isFalse);
    });

    testWidgets('image flow yields a PendingImage with planned world rect', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      PendingImage? captured;
      await pumpDock(
        tester,
        config: config,
        tool: tool,
        pickImage: () async => PickedImage(
          bytes: Uint8List(4),
          filename: 'shot.png',
          widthPx: 400,
          heightPx: 200,
        ),
        onPickImage: (PendingImage img) => captured = img,
      );

      await tester.tap(find.byKey(const ValueKey<String>('tool-image')));
      await tester.pump();
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('pick-image')));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.filename, 'shot.png');
      expect(captured!.widthPx, 400);
      expect(captured!.heightPx, 200);
      expect(captured!.plannedWorldRect, const Rect.fromLTWH(0, 0, 600, 300));
    });

    testWidgets('Cartesian dialog emits the exact Doc 03 object', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      String? shapeType;
      Map<String, dynamic>? graphConfig;
      await pumpDock(
        tester,
        config: config,
        tool: tool,
        onGraphCommitted: (String t, Map<String, dynamic> c) {
          shapeType = t;
          graphConfig = c;
        },
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('tool-cartesianGraph')),
      );
      await tester.pump();
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('open-cartesian')));
      await tester.pumpAndSettle();
      expect(find.text('Cartesian Graph Builder'), findsOneWidget);

      // Invalid grid step must block the commit.
      await tester.enterText(
        find.byKey(const ValueKey<String>('graph-grid-step')),
        'abc',
      );
      await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
      await tester.pumpAndSettle();
      expect(shapeType, isNull);
      expect(find.text('Cartesian Graph Builder'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('graph-grid-step')),
        '25.0',
      );
      await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
      await tester.pumpAndSettle();

      expect(shapeType, 'CARTESIAN_2D');
      expect(graphConfig, <String, dynamic>{
        'origin': <double>[250.0, 450.0],
        'x_range': <int>[-10, 10],
        'y_range': <int>[-10, 10],
        'grid_step': 25.0,
        'show_labels': true,
      });
      expect(graphConfig!['grid_step'], isA<double>());
      expect(find.text('Cartesian Graph Builder'), findsNothing);
    });

    testWidgets('Number Line dialog emits the exact Doc 03 object', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      String? shapeType;
      Map<String, dynamic>? graphConfig;
      await pumpDock(
        tester,
        config: config,
        tool: tool,
        onGraphCommitted: (String t, Map<String, dynamic> c) {
          shapeType = t;
          graphConfig = c;
        },
      );

      await tester.tap(find.byKey(const ValueKey<String>('tool-numberLine')));
      await tester.pump();
      await tester.tap(find.byKey(dockToggle));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('open-numberline')));
      await tester.pumpAndSettle();
      expect(find.text('Number Line Builder'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('graph-confirm')));
      await tester.pumpAndSettle();

      expect(shapeType, 'NUMBER_LINE');
      expect(graphConfig, <String, dynamic>{
        'range': <int>[-10, 10],
        'step': 1.0,
        'show_labels': true,
      });
      expect(graphConfig!['step'], isA<double>());
      expect(find.text('Number Line Builder'), findsNothing);
    });
  });
}
