/// Round-12 issue 06 — an animated placeholder while an image decodes.
///
/// Report: opening a canvas that contains images showed NOTHING in the image's
/// frame until the bytes finished decoding, so a page full of photos looked
/// broken for a moment.
///
/// Why it was blank: a tile bake is synchronous (`Canvas` drawing cannot
/// `await`), so `_drawImage` simply returned when `AssetImageCache.imageOf`
/// was null. The cache already knows the difference between "no bytes yet",
/// "decoding" and "failed" — `isPending` / `hasFailed` — the painter just never
/// asked.
///
/// This module owns the visual: a tinted panel plus a travelling sheen, with a
/// distinct look for a failed decode so the user is not left waiting forever.
/// It is pure drawing (no state), so it can be called from the tile bake as
/// often as the animation tick demands.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How the placeholder should look for one node.
enum ImagePlaceholderKind {
  /// Bytes exist and a decode is in flight — show the loading animation.
  loading,

  /// The decode failed (or the asset is missing) — show a broken-image mark.
  failed,
}

/// Colours for the placeholder, derived from the app theme.
class ImagePlaceholderTheme {
  const ImagePlaceholderTheme({
    this.panel = const Color(0x14000000),
    this.sheen = const Color(0x33FFFFFF),
    this.border = const Color(0x33000000),
    this.icon = const Color(0x99000000),
  });

  /// Backing panel behind the sheen.
  final Color panel;

  /// Moving highlight.
  final Color sheen;

  /// 1 dp outline so an empty frame still reads as "an image lives here".
  final Color border;

  /// Broken-image glyph colour.
  final Color icon;

  /// Whole-panel opacity budget, so a placeholder never fights the artwork.
  static const double opacity = 1.0;
}

/// Draws the placeholder for [rect] at animation phase [phase] (0..1).
///
/// [phase] drives the sheen; passing a constant simply freezes the animation,
/// which is what a static export/thumbnail should do.
void paintImagePlaceholder(
  Canvas canvas,
  Rect rect,
  ImagePlaceholderKind kind, {
  double phase = 0.0,
  ImagePlaceholderTheme theme = const ImagePlaceholderTheme(),
  double radius = 6.0,
}) {
  if (rect.width <= 0 || rect.height <= 0) {
    return;
  }
  final RRect panel = RRect.fromRectAndRadius(rect, Radius.circular(radius));
  canvas.drawRRect(panel, Paint()..color = theme.panel);

  if (kind == ImagePlaceholderKind.loading) {
    _paintSheen(canvas, rect, panel, phase, theme.sheen);
  } else {
    _paintBrokenMark(canvas, rect, theme.icon);
  }

  canvas.drawRRect(
    panel,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = theme.border,
  );
}

/// The travelling highlight: a soft diagonal band sweeping left → right.
void _paintSheen(
  Canvas canvas,
  Rect rect,
  RRect panel,
  double phase,
  Color colour,
) {
  final double t = phase.isFinite ? (phase % 1.0) : 0.0;
  // The band is 40% of the width and travels from fully off-left to
  // fully off-right, so the loop point is invisible.
  final double bandWidth = math.max(rect.width * 0.4, 1.0);
  final double travel = rect.width + bandWidth * 2;
  final double left = rect.left - bandWidth + travel * t;

  canvas.save();
  canvas.clipRRect(panel);
  final Rect band = Rect.fromLTWH(left, rect.top, bandWidth, rect.height);
  canvas.drawRect(
    band,
    Paint()
      ..shader = LinearGradient(
        colors: <Color>[colour.withValues(alpha: 0.0), colour, colour.withValues(alpha: 0.0)],
        stops: const <double>[0.0, 0.5, 1.0],
      ).createShader(band),
  );
  canvas.restore();
}

/// A small broken-image glyph (a "photo" frame with a diagonal slash).
void _paintBrokenMark(Canvas canvas, Rect rect, Color colour) {
  final double size = math.min(math.min(rect.width, rect.height) * 0.28, 48.0);
  if (size < 6) {
    return; // too small to read — the tinted panel alone is enough
  }
  final Offset centre = rect.center;
  final Rect frame = Rect.fromCenter(center: centre, width: size, height: size * 0.78);
  final Paint stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, size * 0.06)
    ..strokeCap = StrokeCap.round
    ..color = colour;

  canvas.drawRRect(
    RRect.fromRectAndRadius(frame, Radius.circular(size * 0.1)),
    stroke,
  );
  // A mountain line inside the frame.
  final Path path = Path()
    ..moveTo(frame.left + frame.width * 0.16, frame.bottom - frame.height * 0.2)
    ..lineTo(frame.left + frame.width * 0.42, frame.top + frame.height * 0.45)
    ..lineTo(frame.left + frame.width * 0.62, frame.bottom - frame.height * 0.2);
  canvas.drawPath(path, stroke);
  // The "broken" slash across the whole frame.
  final double inset = size * 0.08;
  canvas.drawLine(
    frame.topLeft + Offset(-inset, -inset),
    frame.bottomRight + Offset(inset, inset),
    stroke,
  );
}

/// Chooses the placeholder for a node, or `null` when a real image should paint.
///
/// Kept here (not in the painter) so the decision is unit-testable without a
/// `Canvas`.
ImagePlaceholderKind? imagePlaceholderFor({
  required bool isPending,
  required bool hasFailed,
  required bool isReady,
  required bool hasAssetRef,
}) {
  if (!hasAssetRef) {
    return null; // a node with no asset is a different defect, do not fake it
  }
  if (isReady) {
    return null; // draw the bitmap
  }
  if (hasFailed) {
    return ImagePlaceholderKind.failed;
  }
  if (isPending) {
    return ImagePlaceholderKind.loading;
  }
  // Bytes are known but neither pending nor ready: about to start. Treat as
  // loading so the frame is never blank.
  return ImagePlaceholderKind.loading;
}
