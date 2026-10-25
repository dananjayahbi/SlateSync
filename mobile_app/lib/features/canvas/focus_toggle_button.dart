/// Round-12 issue 03 — the one control that survives focus mode.
///
/// It floats over the canvas rather than sitting in an app bar, because in
/// focus mode there is no app bar: the whole point is that the page gets the
/// screen. A small, semi-transparent target in the corner is the least
/// intrusive way to keep an exit reachable.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';
import 'package:mobile_app/features/canvas/focus_mode_controller.dart';

/// Floating focus-mode trigger/exit button.
///
/// When unfocused it lives in the header; when focused it floats in the
/// top-right corner at reduced opacity so it does not compete with the page.
class FocusToggleButton extends StatelessWidget {
  const FocusToggleButton({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final FocusModeController controller;

  /// Header variant (smaller, aligned with the other top-bar actions).
  final bool compact;

  static const ValueKey<String> enterKey = ValueKey<String>('focus-enter');
  static const ValueKey<String> exitKey = ValueKey<String>('focus-exit');

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final bool focused = controller.isFocused;
        final double size = compact ? 40 : 44;
        return Semantics(
          button: true,
          label: focused ? 'Exit focus mode' : 'Enter focus mode',
          child: Tooltip(
            message: focused ? 'Exit focus mode' : 'Focus mode',
            child: Material(
              color: focused
                  ? StudioTheme.surface.withValues(alpha: 0.72)
                  : Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: focused ? exitKey : enterKey,
                onTap: controller.toggle,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Icon(
                    focused ? Icons.close_fullscreen : Icons.fullscreen,
                    size: compact ? 20 : 22,
                    color: focused ? StudioTheme.accent : StudioTheme.text,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The floating exit affordance shown over the canvas while focused.
///
/// Kept as its own widget so the page can stack it without rebuilding the
/// header, and so it can fade in/out rather than popping.
class FocusOverlayButton extends StatelessWidget {
  const FocusOverlayButton({super.key, required this.controller});

  final FocusModeController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        return IgnorePointer(
          ignoring: !controller.isFocused,
          child: AnimatedOpacity(
            opacity: controller.isFocused ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: Align(
                alignment: Alignment.topRight,
                child: FocusToggleButton(controller: controller),
              ),
            ),
          ),
        );
      },
    );
  }
}
