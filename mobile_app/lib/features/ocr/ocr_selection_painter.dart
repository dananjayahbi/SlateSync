/// Round-12 issue 09 — the OCR tool's free-drawn selection.
///
/// Not a rectangle: the user circles the lines they want scanned, and the shape
/// of that outline is part of the request (the PC masks the raster to it, so
/// neighbouring text outside the loop cannot leak into the result).
///
/// This module owns the stroke bookkeeping and the preview painting, and
/// deliberately nothing else — the page decides when to start, finish and send.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colour of the OCR selection outline (distinct from the selector's blue so
/// the two tools never look the same).
const Color kOcrSelectionColor = Color(0xFF00A38B);

/// A minimum of three points is required to enclose any area at all.
const int kOcrMinPoints = 3;

/// Points closer than this to the previous point are dropped.
///
/// A stylus emits many samples per millimetre; keeping all of them would inflate
/// the request payload and add no shape information.
const double kOcrMinPointSpacing = 2.0;

/// Collects the free-drawn outline in WORLD units.
class OcrSelectionPath {
  OcrSelectionPath({this.minSpacing = kOcrMinPointSpacing});

  /// World points, in draw order.
  final List<Offset> points = <Offset>[];

  /// Minimum distance between accepted samples.
  final double minSpacing;

  bool get isEmpty => points.isEmpty;

  /// Whether the outline can enclose a region.
  bool get isUsable => points.length >= kOcrMinPoints && bounds != null;

  /// Axis-aligned bounds of the outline, or `null` when there is no area.
  Rect? get bounds {
    if (points.length < kOcrMinPoints) {
      return null;
    }
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    for (final Offset point in points) {
      if (!point.dx.isFinite || !point.dy.isFinite) {
        continue;
      }
      minX = math.min(minX, point.dx);
      minY = math.min(minY, point.dy);
      maxX = math.max(maxX, point.dx);
      maxY = math.max(maxY, point.dy);
    }
    if (!minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite) {
      return null;
    }
    if (maxX - minX < 1.0 || maxY - minY < 1.0) {
      return null;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Adds a sample. Returns true when it was accepted.
  bool add(Offset world) {
    if (!world.dx.isFinite || !world.dy.isFinite) {
      return false;
    }
    if (points.isNotEmpty) {
      final Offset last = points.last;
      final double dx = world.dx - last.dx;
      final double dy = world.dy - last.dy;
      if (dx * dx + dy * dy < minSpacing * minSpacing) {
        return false;
      }
    }
    points.add(world);
    return true;
  }

  void clear() {
    points.clear();
  }

  /// The outline as wire points `[x, y]`, ready for the request envelope.
  List<List<double>> toWire() => <List<double>>[
        for (final Offset point in points) <double>[point.dx, point.dy],
      ];
}

/// Paints the in-progress OCR outline over the canvas.
class OcrSelectionPainter extends CustomPainter {
  const OcrSelectionPainter({
    required this.viewMatrix,
    required this.points,
    this.color = kOcrSelectionColor,
  });

  /// Same camera matrix the ink layer uses, so the outline stays glued to the
  /// page at every zoom level.
  final Matrix4 viewMatrix;

  /// Outline in WORLD units.
  final List<Offset> points;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      return;
    }
    canvas.save();
    canvas.transform(viewMatrix.storage);

    // A soft wash under the line makes the enclosed area obvious, which is the
    // whole point of drawing the loop in the first place.
    if (points.length >= kOcrMinPoints) {
      final Path region = Path()..moveTo(points.first.dx, points.first.dy);
      for (final Offset point in points.skip(1)) {
        region.lineTo(point.dx, point.dy);
      }
      region.close();
      canvas.drawPath(
        region,
        Paint()..color = color.withValues(alpha: 0.12),
      );
    }

    final Path stroke = Path()..moveTo(points.first.dx, points.first.dy);
    for (final Offset point in points.skip(1)) {
      stroke.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      stroke,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(OcrSelectionPainter oldDelegate) =>
      oldDelegate.viewMatrix != viewMatrix ||
      oldDelegate.color != color ||
      !_samePoints(oldDelegate.points, points);

  static bool _samePoints(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
