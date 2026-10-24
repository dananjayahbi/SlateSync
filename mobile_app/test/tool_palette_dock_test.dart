import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';

/// Doc 24 §6 acceptance: `ToolConfig` defaults, the `StudioTool` → `ToolId`
/// byte table, Doc 03 `graph_config` builders (both example objects), the
/// hold-to-configure flow (round-8 issue 04 replaced the expandable column),
/// eraser mode toggle, highlighter blend switching, snapping, the pluggable
/// image flow and the Graph Builder dialogs — all pure UI: no sockets, no
/// `sendRpc`, no platform plugins.
void main() {
  // Round-8 issue 04: the overlay panel (the old `dock-panel` in the removed
  // expandable column) is now the only configuration surface.
  const ValueKey<String> dockPanel = ValueKey<String>('property-overlay-panel');

  /// Round-8 issue 04: the expandable side panel and its `dock-toggle` are
  /// gone — a tool's configuration is reached by pressing and holding that
  /// tool for 2000 ms. Shared by every widget test that needs the panel.
  Future<void> openPanel(WidgetTester tester, [StudioTool tool = StudioTool.pen]) async {
    final Finder button = find.byKey(ValueKey<String>('tool-${tool.name}'));
    final TestGesture gesture = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 2050));
    await gesture.up();
    await tester.pumpAndSettle();
  }

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
      expect(cfg.eraserMode, EraserMode.brush);
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
        await openPanel(tester);
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
      await openPanel(tester);
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
      await openPanel(tester);
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
        await openPanel(tester);
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
        // Round-6 (Doc 02 §10.7): per-tool defaults — the highlighter's
        // stored config is #F1C40F / 8.0 / 0.4-multiply, so selection
        // REPLACES config.value with 0.4 (was 1.0 under round-5 in-place
        // mutation where no per-tool store existed).
        expect(opacity.value, 0.4, reason: 'round-6 per-tool default');

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

    testWidgets('eraser brush mode reuses ToolConfig.width as erase radius', (
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
      await openPanel(tester, StudioTool.eraser);
      await tester.pumpAndSettle();

      final Slider slider = tester.widget<Slider>(find.byKey(widthSlider));
      expect(slider.min, 0.5);
      expect(slider.max, 20.0);
      // Round-6 (Doc 02 §10.7): eraser default is a 10 dp hit radius (was
      // 2.5 in round-5, which had no per-tool store and inherited the pen
      // width); the panel now REPLACES config.value with the eraser's
      // stored config on selection.
      expect(
        tester.widget<Text>(find.byKey(tipLabel)).data,
        'Eraser radius 10.0 dp',
      );

      slider.onChanged!(8);
      await tester.pump();
      expect(config.value.width, 8.0);
      expect(
        tester.widget<Text>(find.byKey(tipLabel)).data,
        'Eraser radius 8.0 dp',
      );
      // Preview dot reuses the same scaled size for the eraser.
      expect(tester.getSize(find.byKey(previewDot)).width, closeTo(8.0, 0.001));
    });
  });

  group('StudioTool → ToolId byte table (Doc 24 §4)', () {
    const Map<StudioTool, int> expected = <StudioTool, int>{
      // Round-8 issue 07: `select` streams shape-preview frames (it has no
      // live ink of its own), reusing the shared 0x04 identifier.
      StudioTool.select: 0x04,
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

    test('all 12 StudioTool values map to the expected byte', () {
      expect(StudioTool.values.length, 12);
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
    testWidgets('hold opens the panel; the toggle button is gone', (
      WidgetTester tester,
    ) async {
      final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
        ToolConfig(),
      );
      final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
        StudioTool.pen,
      );
      await pumpDock(tester, config: config, tool: tool);

      // Round-8 issue 04: there is no expandable sub-panel and no toggle —
      // the only way in is the 2000 ms press-and-hold on the tool itself.
      expect(find.byKey(dockPanel), findsNothing);
      expect(find.byKey(const ValueKey<String>('dock-toggle')), findsNothing);

      await openPanel(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(dockPanel), findsOneWidget);

      // Tapping outside the panel dismisses it.
      await tester.tapAt(const Offset(4, 4));
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
      await openPanel(tester);
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
      await openPanel(tester, StudioTool.eraser);
      await tester.pumpAndSettle();

      expect(config.value.eraserMode, EraserMode.brush);
      // Round-8 issue 03: the caption now describes BRUSH (a real eraser) and
      // names ELEMENT as the whole-node delete alternative.
      expect(find.textContaining('split around the swept disc'), findsOneWidget);
      expect(find.textContaining('Element'), findsOneWidget);

      await tester.tap(find.text('element'));
      await tester.pump();
      expect(config.value.eraserMode, EraserMode.element);

      await tester.tap(find.text('brush'));
      await tester.pump();
      expect(config.value.eraserMode, EraserMode.brush);
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
      await openPanel(tester);
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
      await openPanel(tester, StudioTool.line);
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
      await openPanel(tester, StudioTool.image);
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
      await openPanel(tester, StudioTool.cartesianGraph);
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
      await openPanel(tester, StudioTool.numberLine);
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
