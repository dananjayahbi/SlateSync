import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';

/// Issue 02 — the app moved from the Doc 05 dark stub palette to a coherent
/// LIGHT scheme (token names frozen, values converted; Doc 05 §3's dark hex
/// line is superseded by this issue). These assertions pin the light values
/// so a dark regression fails loudly.
void main() {
  test('Issue 02 light palette values (token names unchanged)', () {
    expect(StudioTheme.bg, const Color(0xFFF5F7FA));
    expect(StudioTheme.surface, const Color(0xFFFFFFFF));
    expect(StudioTheme.strokeCanvas, const Color(0xFFFFFFFF));
    expect(StudioTheme.text, const Color(0xFF1A1A1E));
    expect(StudioTheme.subText, const Color(0xFF5A5F6B));
    expect(StudioTheme.accent, const Color(0xFF4F8EF7)); // unchanged
    expect(StudioTheme.danger, const Color(0xFFD64550));
  });

  test('light scheme keeps ink and text readable on their backgrounds', () {
    // Doc 24 default ink #1E1E1E on white paper — clearly visible.
    const Color ink = Color(0xFF1E1E1E);
    expect(
      StudioTheme.strokeCanvas.computeLuminance() - ink.computeLuminance(),
      greaterThan(0.5),
    );
    // Near-black text/sub-text on the light surfaces.
    expect(
      StudioTheme.surface.computeLuminance() -
          StudioTheme.text.computeLuminance(),
      greaterThan(0.5),
    );
    expect(
      StudioTheme.surface.computeLuminance() -
          StudioTheme.subText.computeLuminance(),
      greaterThan(0.5),
    );
    // Chrome (bg) stays distinguishable from cards/panels (surface).
    expect(StudioTheme.bg == StudioTheme.surface, isFalse);
  });
}
