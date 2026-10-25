import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';

/// Round-6 (Doc 02 §10.7): the custom 500 ms hold gesture (Flutter's
/// ~500 ms onLongPress is never used), its cancellation rules, and the
/// Clear-canvas confirmation dialog gating the seeded `onClearRequested`
/// callback. All timing runs on the widget test's fake async clock.
void main() {
  const ValueKey<String> toolPen = ValueKey<String>('tool-pen');
  const ValueKey<String> toolHighlighter = ValueKey<String>(
    'tool-highlighter',
  );
  const ValueKey<String> toolRect = ValueKey<String>('tool-rect');
  const ValueKey<String> overlayPanel = ValueKey<String>(
    'property-overlay-panel',
  );
  const ValueKey<String> clearButton = ValueKey<String>('clear-canvas');
  const ValueKey<String> clearCancel = ValueKey<String>('clear-cancel');
  const ValueKey<String> clearConfirm = ValueKey<String>('clear-confirm');

  Future<void> pumpDock(
    WidgetTester tester, {
    required ValueNotifier<ToolConfig> config,
    required ValueNotifier<StudioTool> tool,
    VoidCallback? onClearRequested,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ToolDock(
              config: config,
              tool: tool,
              onClearRequested: onClearRequested,
            ),
          ),
        ),
      ),
    );
  }

  group('press-and-hold 500 ms opens the property panel (Doc 02 §10.7)', () {
    testWidgets(
      'hold for exactly 500 ms opens the panel AND selects the tool; a '
      'quick tap never opens it',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        // Quick tap: selects, and 600 fake ms later nothing has opened.
        await tester.tap(find.byKey(toolHighlighter));
        await tester.pumpAndSettle();
        expect(tool.value, StudioTool.highlighter);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(overlayPanel), findsNothing);

        // Hold pen: still closed one millisecond before the deadline…
        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(toolPen)),
        );
        await tester.pump(const Duration(milliseconds: 499));
        expect(find.byKey(overlayPanel), findsNothing);

        // …and open exactly at 500 ms (custom Timer, not onLongPress).
        // The frame from this pump already includes the fired timer.
        await tester.pump(const Duration(milliseconds: 1));
        expect(find.byKey(overlayPanel), findsOneWidget);
        expect(
          tool.value,
          StudioTool.pen,
          reason: 'the hold also SELECTS the held tool (documented choice)',
        );

        // Releasing the finger does not close the panel.
        await gesture.up();
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);
      },
    );

    testWidgets(
      'pointer-up before 500 ms cancels the pending hold timer',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(toolRect)),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pump();

        // Well past the 500 ms deadline: no panel, and the tap portion of the
        // gesture still selected the tool.
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(overlayPanel), findsNothing);
        expect(tool.value, StudioTool.rect);
      },
    );

    testWidgets(
      'a pointer-down elsewhere cancels a pending hold (tapping elsewhere)',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        // Finger A presses pen… then finger B presses highlighter.
        final TestGesture gestureA = await tester.startGesture(
          tester.getCenter(find.byKey(toolPen)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        final TestGesture gestureB = await tester.startGesture(
          tester.getCenter(find.byKey(toolHighlighter)),
        );
        await gestureA.up();
        await tester.pump();

        // A's timer was cancelled by B's pointer-down: at A's original
        // deadline nothing opens.
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(overlayPanel), findsNothing);

        // B's own hold completes at its full 500 ms and opens.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);
        expect(tool.value, StudioTool.highlighter);
        await gestureB.up();
        await tester.pump();
      },
    );

    testWidgets(
      'holding again while the panel is open for that tool is a no-op',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        // First hold opens the panel.
        final TestGesture first = await tester.startGesture(
          tester.getCenter(find.byKey(toolPen)),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);
        await first.up();
        await tester.pump();

        // Second hold on the same tool: no second panel, no state churn.
        final TestGesture second = await tester.startGesture(
          tester.getCenter(find.byKey(toolPen)),
        );
        await tester.pump(const Duration(milliseconds: 2500));
        expect(find.byKey(overlayPanel), findsOneWidget);
        await second.up();
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a different tool while the panel is open re-targets it '
      '(round-8 issue 04 supersedes the round-6 close-on-switch rule)',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(toolPen)),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);

        // The panel STAYS OPEN and now shows the newly tapped tool's rows, so
        // the panel/config sync invariant still holds (never one tool's rows
        // against another tool's config) with fewer taps.
        await tester.tap(find.byKey(toolHighlighter));
        await tester.pump();
        expect(find.byKey(overlayPanel), findsOneWidget);
        expect(tool.value, StudioTool.highlighter);
        expect(config.value.highlighter, isTrue);
      },
    );
  });

  group('clear button confirmation (Doc 02 §10.7)', () {
    testWidgets(
      'dialog → Cancel fires nothing; dialog → Clear fires exactly once',
      (WidgetTester tester) async {
        int clearCount = 0;
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(
          tester,
          config: config,
          tool: tool,
          onClearRequested: () => clearCount++,
        );

        await tester.tap(find.byKey(clearButton));
        await tester.pumpAndSettle();
        expect(find.text('Clear entire canvas?'), findsOneWidget);
        expect(
          find.text(
            'All content will be removed from every connected device.',
          ),
          findsOneWidget,
        );
        expect(clearCount, 0, reason: 'opening the dialog must not fire');

        // Cancel: nothing fires.
        await tester.tap(find.byKey(clearCancel));
        await tester.pumpAndSettle();
        expect(find.text('Clear entire canvas?'), findsNothing);
        expect(clearCount, 0);

        // Reopen → confirm: fires exactly once.
        await tester.tap(find.byKey(clearButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(clearConfirm));
        await tester.pumpAndSettle();
        expect(find.text('Clear entire canvas?'), findsNothing);
        expect(clearCount, 1);

        // The icon tap alone never fires without confirmation.
        await tester.tap(find.byKey(clearButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(clearCancel));
        await tester.pumpAndSettle();
        expect(clearCount, 1);
      },
    );

    testWidgets(
      'confirm with no onClearRequested wired does not throw',
      (WidgetTester tester) async {
        final ValueNotifier<ToolConfig> config = ValueNotifier<ToolConfig>(
          ToolConfig(),
        );
        final ValueNotifier<StudioTool> tool = ValueNotifier<StudioTool>(
          StudioTool.pen,
        );
        await pumpDock(tester, config: config, tool: tool);

        await tester.tap(find.byKey(clearButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(clearConfirm));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });
}
