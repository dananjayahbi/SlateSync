import 'package:flutter/material.dart';

/// SlateSync Studio dark theme constants (Doc 05).
///
/// Pure constants only — no widgets, no ThemeData builders. Consumers (Docs
/// 20–27) compose these into their own ThemeData.
abstract final class StudioTheme {
  // Palette
  static const Color bg = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E);
  static const Color strokeCanvas = Color(0xFF0E0E0E);
  static const Color accent = Color(0xFF4F8EF7);
  static const Color danger = Color(0xFFF0546F);
  static const Color text = Color(0xFFEAEAEA);

  // Radii
  static const double radiusSmall = 12;
  static const double radiusLarge = 18;

  // Typography scale
  static const double titleSize = 18;
  static const double bodySize = 14;
  static const double captionSize = 12;
}
