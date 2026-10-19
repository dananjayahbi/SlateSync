import 'package:flutter/material.dart';

/// SlateSync Studio light theme constants (Doc 05, Issue 02 light conversion).
///
/// Token names stay exactly as frozen by Doc 05; Issue 02 ("the canvas is so
/// dark — use the light theme") switches the values to a coherent light
/// scheme: white paper canvas, near-black ink, readable sub-text. Pure
/// constants only — no widgets, no ThemeData builders. Consumers (Docs
/// 20–27) compose these into their own ThemeData.
abstract final class StudioTheme {
  // Palette (light)
  static const Color bg = Color(0xFFF5F7FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color strokeCanvas = Color(0xFFFFFFFF);
  static const Color accent = Color(0xFF4F8EF7); // unchanged
  static const Color danger = Color(0xFFD64550);
  static const Color text = Color(0xFF1A1A1E);

  /// Secondary/caption ink — light-scheme sub-text (Issue 02).
  static const Color subText = Color(0xFF5A5F6B);

  // Radii
  static const double radiusSmall = 12;
  static const double radiusLarge = 18;

  // Typography scale
  static const double titleSize = 18;
  static const double bodySize = 14;
  static const double captionSize = 12;
}
