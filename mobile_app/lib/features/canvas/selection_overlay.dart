/// Round-8 issue 07 — the selector's on-canvas chrome.
///
/// Draws the three things the selector needs to communicate, in world space
/// (the painter applies the same camera matrix as the ink layer so handles
/// stay glued to the content at every zoom):
///
/// * the **selection box** around the selected objects,
/// * the **eight resize handles**, suppressed when the selection cannot be
///   scaled (it contains a free-hand stroke), and
/// * the **marquee** rectangle while rubber-banding.
///
/// Pure `CustomPainter`: no state, no hit-testing (the canvas page owns that),
/// so the geometry module stays the single source of truth for handle
/// positions via [handlePosition].
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/selection_transform.dart';

/// Screen-space size of a resize handle, so it remains finger-sized at any
/// zoom (the painter converts it back to world units).
const double kSelectionHandleSizePx = 12.0;

class CanvasSelectionPainter extends CustomPainter {
  const CanvasSelectionPainter({
    required this.viewMatrix,
    required this.rect,
    required this.scale,
    required this.showHandles,
    this.marquee,
    this.accent = const Color(0xFF3D7EFF),
  });

  /// Camera matrix (world → screen) as the camera exposes it, identical to\n  /// the ink layer's TiledCanvasView.viewMatrix.
  final Matrix4 viewMatrix;

  /// Selected bounds in WORLD units; empty (`Rect.zero` + !showHandles) when
  /// there is no selection.
  final Rect rect;

  /// Camera scale — converts [kSelectionHandleSizePx] into world units.
  final double scale;

  /// `false` while the selection must not be resized (free-hand strokes).
  final bool showHandles;

  /// Marquee rubber band in WORLD units while dragging on empty space.
  final Rect? marquee;

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.transform(viewMatrix.storage);
    final double world = kSelectionHandleSizePx / (scale <= 0 ? 1 : scale);
    final Paint box = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / (scale <= 0 ? 1 : scale)
      ..color = accent;
    if (rect != Rect.zero && (rect.width > 0 || rect.height > 0)) {
      canvas.drawRect(rect, box);
      if (showHandles) {
        final Paint fill = Paint()..color = Colors.white;
        final Paint edge = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / (scale <= 0 ? 1 : scale)
          ..color = accent;
        for (final ResizeHandle handle in ResizeHandle.values) {
          final Offset center = handlePosition(handle, rect);
          final Rect knob = Rect.fromCenter(
            center: center,
            width: world,
            height: world,
          );
          canvas.drawRect(knob, fill);
          canvas.drawRect(knob, edge);
        }
      }
    }
    final Rect? band = marquee;
    if (band != null && (band.width > 0 || band.height > 0)) {
      final Paint dash = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 / (scale <= 0 ? 1 : scale)
        ..color = accent.withValues(alpha: 0.9);
      canvas.drawRect(band, dash);
      canvas.drawRect(
        band,
        Paint()..color = accent.withValues(alpha: 0.08),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CanvasSelectionPainter old) =>
      old.rect != rect ||
      old.marquee != marquee ||
      old.showHandles != showHandles ||
      old.scale != scale ||
      !_sameMatrix(old.viewMatrix, viewMatrix);

  static bool _sameMatrix(Matrix4 a, Matrix4 b) => a == b;
}

/// Convenience wrapper: the overlay as a positioned fill layer.
///
/// Named `CanvasSelectionOverlay` (not `SelectionOverlay`) because Flutter's
/// own `SelectionOverlay` is exported by material.dart and would clash.
class CanvasSelectionOverlay extends StatelessWidget {
  const CanvasSelectionOverlay({
    super.key,
    required this.viewMatrix,
    required this.rect,
    required this.scale,
    required this.showHandles,
    this.marquee,
  });

  final Matrix4 viewMatrix;
  final Rect rect;
  final double scale;
  final bool showHandles;
  final Rect? marquee;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          key: const ValueKey<String>('selection-overlay'),
          painter: CanvasSelectionPainter(
            viewMatrix: viewMatrix,
            rect: rect,
            scale: scale,
            showHandles: showHandles,
            marquee: marquee,
          ),
        ),
      ),
    );
  }
}
