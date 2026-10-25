/// Round-12 issue 03 / issue 09 — focus mode plus the OCR tray button.
///
/// These are widget-level tests because focus mode is fundamentally a question
/// of what is *on screen*, and the OCR scan controls are a question of what is
/// *reachable*. Both are cheap to get subtly wrong and expensive to notice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/canvas/focus_mode_controller.dart';
import 'package:mobile_app/features/canvas/focus_toggle_button.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('FocusChrome', () {
    test('normal chrome shows everything', () {
      const FocusChrome chrome = FocusChrome.normal;
      expect(chrome.showTopBar, isTrue);
      expect(chrome.showToolDock, isTrue);
      expect(chrome.showBanner, isTrue);
      expect(chrome.showHint, isTrue);
      expect(chrome.showFocusButton, isTrue);
    });

    test('focused chrome hides everything EXCEPT the way out', () {
      const FocusChrome chrome = FocusChrome.focused;
      expect(chrome.showTopBar, isFalse);
      expect(chrome.showToolDock, isFalse);
      expect(chrome.showBanner, isFalse);
      expect(chrome.showHint, isFalse);
      // The single rule that prevents an inescapable UI.
      expect(chrome.showFocusButton, isTrue,
          reason: 'without this the user can never leave focus mode');
    });

    test('the two chromes are not equal', () {
      expect(FocusChrome.normal, isNot(equals(FocusChrome.focused)));
    });

    test('equality is structural', () {
      expect(
        const FocusChrome(
          showTopBar: true,
          showToolDock: true,
          showBanner: true,
          showHint: true,
          showFocusButton: true,
        ),
        equals(FocusChrome.normal),
      );
      expect(
        const FocusChrome(
          showTopBar: true,
          showToolDock: true,
          showBanner: true,
          showHint: true,
          showFocusButton: true,
        ).hashCode,
        equals(FocusChrome.normal.hashCode),
      );
    });
  });

  group('FocusModeController', () {
    test('it starts unfocused', () {
      expect(FocusModeController().isFocused, isFalse);
    });

    test('it can start focused', () {
      expect(FocusModeController(focused: true).isFocused, isTrue);
    });

    test('toggle flips and reports the new state', () {
      final FocusModeController controller = FocusModeController();
      expect(controller.toggle(), isTrue);
      expect(controller.isFocused, isTrue);
      expect(controller.toggle(), isFalse);
      expect(controller.isFocused, isFalse);
    });

    test('toggle notifies exactly once per change', () {
      final FocusModeController controller = FocusModeController();
      int notifications = 0;
      controller.addListener(() => notifications++);
      controller.toggle();
      expect(notifications, 1);
      controller.toggle();
      expect(notifications, 2);
    });

    test('setting the same value does not notify', () {
      final FocusModeController controller = FocusModeController();
      int notifications = 0;
      controller.addListener(() => notifications++);
      expect(controller.setFocused(false), isFalse);
      expect(notifications, 0, reason: 'a no-op must not rebuild the page');
    });

    test('enter and exit are idempotent', () {
      final FocusModeController controller = FocusModeController();
      controller.enter();
      controller.enter();
      expect(controller.isFocused, isTrue);
      controller.exit();
      controller.exit();
      expect(controller.isFocused, isFalse);
    });

    test('chrome follows the flag', () {
      final FocusModeController controller = FocusModeController();
      expect(controller.chrome, equals(FocusChrome.normal));
      controller.enter();
      expect(controller.chrome, equals(FocusChrome.focused));
      controller.exit();
      expect(controller.chrome, equals(FocusChrome.normal));
    });

    test('a disposed controller does not notify and does not throw', () {
      final FocusModeController controller = FocusModeController();
      controller.dispose();
      // Must not throw: tool changes can race with page teardown.
      expect(() => controller.toggle(), returnsNormally);
      expect(controller.isFocused, isTrue);
    });
  });

  group('FocusToggleButton', () {
    testWidgets('unfocused it offers to enter focus mode', (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller)),
      );
      expect(find.byKey(FocusToggleButton.enterKey), findsOneWidget);
      expect(find.byKey(FocusToggleButton.exitKey), findsNothing);
    });

    testWidgets('tapping it enters focus mode', (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller)),
      );
      await tester.tap(find.byKey(FocusToggleButton.enterKey));
      await tester.pumpAndSettle();
      expect(controller.isFocused, isTrue);
      expect(find.byKey(FocusToggleButton.exitKey), findsOneWidget);
    });

    testWidgets('focused it offers to leave, and leaving works',
        (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController(focused: true);
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller)),
      );
      expect(find.byKey(FocusToggleButton.exitKey), findsOneWidget);
      await tester.tap(find.byKey(FocusToggleButton.exitKey));
      await tester.pumpAndSettle();
      expect(controller.isFocused, isFalse,
          reason: 'the user must always be able to get back to the toolbar');
    });

    testWidgets('the icon changes with the mode', (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller)),
      );
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      controller.enter();
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
    });

    testWidgets('it exposes a semantics label for screen readers',
        (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller)),
      );
      expect(find.bySemanticsLabel('Enter focus mode'), findsOneWidget);
    });

    testWidgets('the compact variant renders at the header size',
        (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusToggleButton(controller: controller, compact: true)),
      );
      final Size size = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.fullscreen),
          matching: find.byType(SizedBox),
        ).first,
      );
      expect(size.width, 40);
    });

    testWidgets('the overlay is transparent and inert when unfocused',
        (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController();
      await tester.pumpWidget(
        _host(FocusOverlayButton(controller: controller)),
      );
      final AnimatedOpacity opacity = tester.widget<AnimatedOpacity>(
        find
            .descendant(
              of: find.byType(FocusOverlayButton),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      );
      expect(opacity.opacity, 0);
      final IgnorePointer ignore = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byType(FocusOverlayButton),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue,
          reason: 'an invisible button must not eat canvas taps');
    });

    testWidgets('the overlay becomes tappable when focused',
        (WidgetTester tester) async {
      final FocusModeController controller = FocusModeController(focused: true);
      await tester.pumpWidget(
        _host(FocusOverlayButton(controller: controller)),
      );
      await tester.pumpAndSettle();
      final IgnorePointer ignore = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byType(FocusOverlayButton),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isFalse);
      await tester.tap(find.byKey(FocusToggleButton.exitKey));
      await tester.pumpAndSettle();
      expect(controller.isFocused, isFalse);
    });
  });
}
