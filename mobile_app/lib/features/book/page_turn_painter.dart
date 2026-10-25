/// Round-13 issue 04 — the page-turn painter.
///
/// Draws one paper fold above the canvas; it never touches engine state. The
/// sheet is split at the crease into a still-flat half and a half folded back
/// over it, and the folded half is shaded with a horizontal gradient taken from
/// [foldGradientStops] — a raised cosine plus a specular band, NOT a linear
/// ramp (see `page_turn_geometry.dart` for why that distinction is the whole
/// feature). A soft shadow trails the crease onto the page below so the lifted
/// sheet reads as casting something, which is what sells the depth.
///
/// Everything is driven by one `t` in `0..1`, so the painter is a pure function
/// of its inputs and can be asserted at `t = 0 / 0.5 / 1` without an animation.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mobile_app/features/book/page_turn_geometry.dart';

/// Which way the sheet travels.
enum PageTurnDirection {
  /// Reading forward: the sheet lifts off the right-hand side.
  forward,

  /// Reading back: mirrored, so the sheet lifts off the left-hand side.
  backward,
}

/// Paint one fold of a page turn.
///
/// [pageRect] is where the page sits in the painter's own coordinate space
/// (screen pixels, after the caller's transform); [t] is the turn progress.
/// [outgoing] and [incoming] are optional page snapshots — when absent the
/// sheet is drawn in paper colour, which is deliberate: the engine must not be
/// re-rendered per frame, so a caller with a cheap snapshot supplies it and a
/// caller without one still gets a correct fold.
class PageTurnPainter extends CustomPainter {
  const PageTurnPainter({
    required this.pageRect,
    required this.t,
    this.direction = PageTurnDirection.forward,
    this.paperColor = const Color(0xFFFFFFFF),
    this.outgoing,
    this.incoming,
    this.creaseColor = const Color(0x33607D9B),
    super.repaint,
  });

  final Rect pageRect;
  final double t;
  final PageTurnDirection direction;
  final Color paperColor;
  final ui.Image? outgoing;
  final ui.Image? incoming;
  final Color creaseColor;

  /// Fold geometry in page-local units (0,0 → pageRect.size).
  PageFoldGeometry get fold => PageFoldGeometry.at(
        width: pageRect.width,
        height: pageRect.height,
        t: t,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final PageFoldGeometry geometry = fold;
    if (pageRect.isEmpty || geometry.isEmpty || geometry.t <= 0) {
      return;
    }
    canvas.save();
    canvas.clipRect(pageRect);
    _applyDirection(canvas, geometry);

    _paintPageBelow(canvas, geometry);
    _paintShadowTrail(canvas, geometry);
    _paintFlatHalf(canvas, geometry);
    _paintFoldedHalf(canvas, geometry);
    _paintCrease(canvas, geometry);

    canvas.restore();
  }

  /// Mirror the whole turn for a backwards page, so one set of maths serves
  /// both directions (the crease travels right-to-left either way).
  void _applyDirection(Canvas canvas, PageFoldGeometry geometry) {
    if (direction == PageTurnDirection.forward) {
      canvas.translate(pageRect.left, pageRect.top);
      return;
    }
    canvas.translate(pageRect.right, pageRect.top);
    canvas.scale(-1, 1);
  }

  void _paintPageBelow(Canvas canvas, PageFoldGeometry geometry) {
    final Rect page = Rect.fromLTWH(0, 0, geometry.width, geometry.height);
    final ui.Image? below = incoming;
    if (below != null) {
      canvas.drawImageRect(
        below,
        Rect.fromLTWH(0, 0, below.width.toDouble(), below.height.toDouble()),
        page,
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    canvas.drawRect(page, Paint()..color = paperColor);
  }

  /// Soft shadow on the page below, strongest at the crease and fading out over
  /// [PageFoldGeometry.shadowTrailWidth]. Opacity peaks at mid-turn.
  void _paintShadowTrail(Canvas canvas, PageFoldGeometry geometry) {
    final double peak = geometry.shadowOpacity;
    if (peak <= 0 || geometry.shadowTrailWidth <= 0) {
      return;
    }
    final Rect trail = geometry.shadowRect;
    if (trail.width <= 0) {
      return;
    }
    final Paint shadow = Paint()
      ..shader = ui.Gradient.linear(
        Offset(trail.left, 0),
        Offset(trail.right, 0),
        <Color>[
          Color.fromRGBO(0, 0, 0, peak),
          Color.fromRGBO(0, 0, 0, peak * 0.45),
          const Color(0x00000000),
        ],
        <double>[0.0, 0.45, 1.0],
      );
    canvas.drawRect(trail, shadow);
  }

  void _paintFlatHalf(Canvas canvas, PageFoldGeometry geometry) {
    if (!geometry.hasFlatHalf) {
      return;
    }
    final Rect flat = geometry.flatRect;
    final ui.Image? page = outgoing;
    if (page != null) {
      final double scale = page.width / geometry.width;
      canvas.drawImageRect(
        page,
        Rect.fromLTWH(0, 0, page.width.toDouble(), math.min(
          page.height.toDouble(),
          geometry.height * scale,
        )),
        flat,
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    canvas.drawRect(flat, Paint()..color = paperColor);
  }

  /// The folded half: a Path (bowed at the crease) filled with the non-linear
  /// shading gradient, so it reads as a bent cylinder rather than a card.
  void _paintFoldedHalf(Canvas canvas, PageFoldGeometry geometry) {
    if (!geometry.hasFoldedHalf) {
      return;
    }
    final Path sheet = foldedPath(geometry);
    // foldShadeAt() is parameterised from the crease (0) to the leading edge
    // (1), which runs right-to-left on screen, so the stops are reversed here.
    final List<FoldShadeStop> stops = foldGradientStops().reversed.toList();
    final double left = geometry.leadingEdgeX;
    final double right = geometry.foldX;
    final Paint paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(left, 0),
        Offset(right, 0),
        <Color>[
          for (final FoldShadeStop stop in stops)
            Color.lerp(const Color(0xFF3A4048), paperColor, stop.luminance)!,
        ],
        <double>[for (final FoldShadeStop stop in stops) 1 - stop.position],
      );
    canvas.drawPath(sheet, paint);
    // A whisper of the page's own ink through the back of the sheet: paper is
    // translucent, and the absence of any show-through is what makes a
    // procedurally shaded fold look like painted card.
    canvas.drawPath(
      sheet,
      Paint()..color = paperColor.withValues(alpha: 0.18),
    );
  }

  void _paintCrease(Canvas canvas, PageFoldGeometry geometry) {
    final Path crease = Path()
      ..moveTo(geometry.foldX, 0)
      ..quadraticBezierTo(
        geometry.foldX - geometry.foldBow,
        geometry.height / 2,
        geometry.foldX,
        geometry.height,
      );
    canvas.drawPath(
      crease,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, geometry.width * 0.002)
        ..color = creaseColor,
    );
  }

  @override
  bool shouldRepaint(PageTurnPainter oldDelegate) =>
      oldDelegate.pageRect != pageRect ||
      oldDelegate.t != t ||
      oldDelegate.direction != direction ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.outgoing != outgoing ||
      oldDelegate.incoming != incoming ||
      oldDelegate.creaseColor != creaseColor;
}

/// Outline of the folded-back half in page-local units.
///
/// Pulled out of the painter so the geometry can be asserted without a canvas:
/// the crease bows by [PageFoldGeometry.foldBow] at mid-height, which is what
/// stops the fold looking like a straight cut.
Path foldedPath(PageFoldGeometry geometry) {
  final double bow = geometry.foldBow;
  return Path()
    ..moveTo(geometry.foldX, 0)
    ..lineTo(geometry.leadingEdgeX, 0)
    ..lineTo(geometry.leadingEdgeX, geometry.height)
    ..lineTo(geometry.foldX, geometry.height)
    ..quadraticBezierTo(
      geometry.foldX - bow,
      geometry.height / 2,
      geometry.foldX,
      0,
    )
    ..close();
}
