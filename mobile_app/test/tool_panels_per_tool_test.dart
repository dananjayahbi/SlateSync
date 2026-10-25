import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';

/// Round-6 (Doc 02 §10.7): the per-tool property store — the exact defaults
/// table, value-REPLACEMENT of the exposed `config` notifier on tool
/// switching (pen → highlighter → pen round-trip preserving edits), panel
/// edits writing back into the store, and tap-outside closing of the
/// long-press property overlay. Pure UI — no sockets, no plugins.
void main() {
  const ValueKey<String> widthSlider = ValueKey<String>('width-slider');
  const ValueKey<String> overlayPanel = ValueKey<String>(
    'property-overlay-panel',
  );

  Future<void> pumpDock(
    WidgetTester tester, {
    required ValueNotifier<ToolConfig> config,
    required ValueNotifier<StudioTool> tool,
  }) {
    // Round-12 added polygon, text and OCR to the rail; on the default
    // 800x600 surface the tools near the bottom — and the property overlay,
    // which is stacked under the dock — no longer fit alongside a "tap
    // outside" point. Give the fixture room so those taps mean what they say.
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ToolDock(config: config, tool: tool),
          ),
        ),
      ),
    );
  }

  /// Press [toolKey], hold for exactly 500 ms on the fake test clock, and
  /// release — the Doc 02 §10.7 gesture that opens the property overlay.
  Future<TestGesture> holdOpenPanel(
    WidgetTester tester,
    ValueKey<String> toolKey,
  ) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(toolKey)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(); // build the overlay entry
    await gesture.up();
    await tester.pump();
    return gesture;
  }

  group('per-tool defaults table (Doc 02 §10.7)', () {
    test('defaultToolConfig matches the frozen round-6 table', () {
      final ToolConfig pen = defaultToolConfig(StudioTool.pen);
      expect(pen.color, '#1E1E1E');
      expect(pen.width, 2.5);
      expect(pen.opacity, 1.0);
      expect(pen.blendMode, 'SRC_OVER');
      expect(pen.highlighter, isFalse);
      expect(pen.eraserMode, EraserMode.brush);

      final ToolConfig highlighter = defaultToolConfig(
        StudioTool.highlighter,
      );
      expect(highlighter.color, '#F1C40F');
      expect(highlighter.width, 8.0);
      expect(highlighter.opacity, 0.4);
      expect(highlighter.highlighter, isTrue);
      expect(highlighter.blendMode, 'MULTIPLY');

      final ToolConfig eraser = defaultToolConfig(StudioTool.eraser);
      expect(eraser.width, 10.0, reason: 'hit radius');
      expect(eraser.eraserMode, EraserMode.brush);
      expect(eraser.color, '#1E1E1E');

      for (final StudioTool tool in <StudioTool>[
        StudioTool.line,
        StudioTool.rect,
        StudioTool.circle,
        StudioTool.triangle,
        StudioTool.arrow,
        StudioTool.image, // unchanged
      ]) {
        final ToolConfig cfg = defaultToolConfig(tool);
        expect(cfg.color, '#1E1E1E', reason: '$tool color');
        expect(cfg.width, 2.5, reason: '$tool width');
        expect(cfg.opacity, 1.0, reason: '$tool opacity');
        expect(cfg.highlighter, isFalse, reason: '$tool highlighter');
      }

      for (final StudioTool tool in <StudioTool>[
        StudioTool.cartesianGraph,
        StudioTool.numberLine,
      ]) {
        final ToolConfig cfg = defaultToolConfig(tool);
        expect(cfg.color, '#4F8EF7', reason: '$tool color');
        expect(cfg.width, 2.0, reason: '$tool width');
        expect(cfg.opacity, 1.0, reason: '$tool opacity');
      }

      // Fresh instance per call — selection must swap references.
      expect(
        identical(
          defaultToolConfig(StudioTool.pen),
          defaultToolConfig(StudioTool.pen),
        ),
        isFalse,
      );
    });
  });

  group('value replacement on tool switch (Doc 02 §10.7)', () {
    testWidgets(
      'selecting a tool REPLACES config.value with its stored config',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        final ToolConfig boot = config.value;
        expect(boot.color, '#1E1E1E');
        expect(boot.width, 2.5);

        await tester.tap(find.byKey(const ValueKey<String>('tool-highlighter')));
        await tester.pump();
        expect(
          identical(config.value, boot),
          isFalse,
          reason: 'switching must REPLACE the notifier value',
        );
        expect(config.value.color, '#F1C40F');
        expect(config.value.width, 8.0);
        expect(config.value.opacity, 0.4);
        expect(config.value.highlighter, isTrue);
        expect(config.value.blendMode, 'MULTIPLY');

        await tester.tap(find.byKey(const ValueKey<String>('tool-pen')));
        await tester.pump();
        expect(config.value.color, '#1E1E1E');
        expect(config.value.width, 2.5);
        expect(config.value.opacity, 1.0);
        expect(config.value.highlighter, isFalse);
        expect(config.value.blendMode, 'SRC_OVER');

        // Eraser: 10 dp hit radius, precision mode.
        await tester.tap(find.byKey(const ValueKey<String>('tool-eraser')));
        await tester.pump();
        expect(config.value.width, 10.0);
        expect(config.value.eraserMode, EraserMode.brush);

        // Graph tools: accent blue @ 2.0.
        //
        // Round-12 issue 04: selecting a graph tool opens its builder dialog,
        // which is modal and covers the dock — so it must be dismissed before
        // another tool can be tapped (exactly what a user does).
        await tester.tap(
          find.byKey(const ValueKey<String>('tool-cartesianGraph')),
        );
        await tester.pumpAndSettle();
        expect(config.value.color, '#4F8EF7');
        expect(config.value.width, 2.0);
        await tester.tap(find.byKey(const ValueKey<String>('graph-cancel')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const ValueKey<String>('tool-numberLine')),
        );
        await tester.pumpAndSettle();
        expect(config.value.color, '#4F8EF7');
        expect(config.value.width, 2.0);
        await tester.tap(find.byKey(const ValueKey<String>('graph-cancel')));
        await tester.pumpAndSettle();

        // Image: unchanged defaults.
        await tester.tap(find.byKey(const ValueKey<String>('tool-image')));
        await tester.pump();
        expect(config.value.color, '#1E1E1E');
        expect(config.value.width, 2.5);
        expect(config.value.opacity, 1.0);
      },
    );

    testWidgets(
      'pen edits survive a highlighter round-trip and highlighter edits '
      'survive back (per-tool store)',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);
        await holdOpenPanel(tester, const ValueKey<String>('tool-pen'));

        // Round-5 controls write into the pen entry of the store.
        tester.widget<Slider>(find.byKey(widthSlider)).onChanged!(7.5);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('swatch-#F0546F')),
        );
        await tester.pump();
        expect(config.value.width, 7.5);
        expect(config.value.color, '#F0546F');
        final ToolConfig penCfg = config.value;

        // pen → highlighter: value replaced by the stored default.
        await tester.tap(find.byKey(const ValueKey<String>('tool-highlighter')));
        await tester.pump();
        expect(identical(config.value, penCfg), isFalse);
        expect(config.value.width, 8.0);
        expect(config.value.color, '#F1C40F');

        // Edit the highlighter through its (still-open) panel — writes back
        // into the highlighter entry of the store.
        tester.widget<Slider>(find.byKey(widthSlider)).onChanged!(9.0);
        await tester.pump();
        expect(config.value.width, 9.0);

        // highlighter → pen: the SAME stored pen instance comes back with
        // its edits intact.
        await tester.tap(find.byKey(const ValueKey<String>('tool-pen')));
        await tester.pump();
        expect(identical(config.value, penCfg), isTrue);
        expect(config.value.width, 7.5);
        expect(config.value.color, '#F0546F');

        // pen → highlighter again: the highlighter edit persisted too.
        await tester.tap(find.byKey(const ValueKey<String>('tool-highlighter')));
        await tester.pump();
        expect(config.value.width, 9.0);
        expect(config.value.color, '#F1C40F');
      },
    );
  });

  group('property overlay tap-outside (Doc 02 §10.7)', () {
    testWidgets(
      'tap outside closes the panel; tap on the panel keeps it open',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        await holdOpenPanel(tester, const ValueKey<String>('tool-pen'));
        expect(find.byKey(overlayPanel), findsOneWidget);

        // Tap ON the panel (top-center of its bounds, over the title row):
        // the panel absorbs the hit — the barrier never sees it.
        final Rect panelRect = tester.getRect(find.byKey(overlayPanel));
        await tester.tapAt(Offset(panelRect.center.dx, panelRect.top + 14));
        await tester.pump();
        expect(
          find.byKey(overlayPanel),
          findsOneWidget,
          reason: 'tap inside the panel must not close it',
        );

        // Tap far outside the panel: the barrier hit-test closes it.
        await tester.tapAt(const Offset(20, 20));
        await tester.pump();
        expect(find.byKey(overlayPanel), findsNothing);
      },
    );
  });
}
