/// Round-13 issue 04 — the geometry and shading maths of a paper page turn.
///
/// Pure functions only: no widgets, no canvas, no state. The painter draws what
/// this describes, and the tests assert the properties that decide whether the
/// turn reads as PAPER rather than as a rotating card:
///
/// * **Fold, not slide.** The sheet bends at a fold line; the part past the
///   fold is mirrored back over the sheet, so the leading edge travels twice as
///   fast as the fold. That 2:1 relationship is the single strongest cue that a
///   flat sheet is folding, and it falls out of the mirror for free.
/// * **The shading curve is not linear.** A bent sheet is a cylinder, so the
///   light it catches varies as a raised cosine across the folded half, with a
///   narrow specular band where the sheet is tangent to the viewer. A linear
///   gradient is the tell that makes a turn look like a recoloured rectangle.
/// * **The shadow trails the fold.** The lifted sheet throws a soft shadow onto
///   the page underneath; it has to grow from nothing as the sheet lifts and
///   fall back to nothing as it lands, so it is driven by `sin(πt)`.
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Fold a page is turning at, plus every derived rect the painter needs.
///
/// `t == 0` is "flat, nothing turned"; `t == 1` is "fully turned, old page
/// gone". All widths are the page's own width, so the same maths works at any
/// zoom — the painter maps it through a scale matrix.
class PageFoldGeometry {
  const PageFoldGeometry({
    required this.width,
    required this.height,
    required this.t,
  })  : foldX = width * (1 - t),
        leadingEdgeX = 2 * (width * (1 - t)) - width;

  /// Page width in the painter's units (screen px after scaling).
  final double width;

  /// Page height in the painter's units.
  final double height;

  /// Normalised progress, clamped to `0..1` by [PageFoldGeometry.at].
  final double t;

  /// Build a geometry with `t` clamped into range.
  factory PageFoldGeometry.at({
    required double width,
    required double height,
    required double t,
  }) {
    final double safeT = t.isFinite ? t.clamp(0.0, 1.0) : 0.0;
    return PageFoldGeometry(
      width: width.isFinite && width > 0 ? width : 0.0,
      height: height.isFinite && height > 0 ? height : 0.0,
      t: safeT,
    );
  }

  /// X of the crease. Sweeps from the right edge (`t == 0`) to the spine
  /// (`t == 1`).
  final double foldX;

  /// X of the sheet's leading edge — always `2·foldX − width`, i.e. twice the
  /// fold's speed, which is what a real fold looks like.
  final double leadingEdgeX;

  /// Width of the part of the sheet that is still face-up and flat.
  double get flatWidth => foldX;

  /// Width of the part folded back over it.
  double get foldedWidth => width - foldX;

  /// The still-flat half, anchored at the spine.
  Rect get flatRect => Rect.fromLTRB(0, 0, foldX, height);

  /// The folded-back half. Runs off the left edge once `t > 0.5`, which is
  /// correct: by then the leading edge has passed the spine and the sheet is
  /// leaving the page. The painter clips it.
  Rect get foldedRect => Rect.fromLTRB(leadingEdgeX, 0, foldX, height);

  /// True while any of the sheet is still face-up.
  bool get hasFlatHalf => flatWidth > 0;

  /// True while any of the sheet is folded back over the page.
  bool get hasFoldedHalf => foldedWidth > 0;

  /// Out-of-page travel of the leading edge (0 at `t == 0`, `width` at `t == 1`).
  double get leadingEdgeTravel => width - leadingEdgeX;

  /// Soft curl of the crease: the fold line bows by this much at mid-turn and
  /// is dead straight at both ends. A ruler-straight crease is the other tell
  /// that a turn is procedural.
  double get foldBow => width * 0.02 * math.sin(math.pi * t);

  /// Peak opacity of the shadow the lifted sheet casts on the page below.
  ///
  /// Zero at both ends (nothing is lifted at `t == 0`, nothing is overhead at
  /// `t == 1`) and strongest at the halfway point.
  double get shadowOpacity => 0.30 * math.sin(math.pi * t);

  /// How far the shadow reaches past the crease, in painter units.
  double get shadowTrailWidth => width * 0.34 * math.sin(math.pi * t);

  /// Band the shadow occupies: from the crease rightwards over the flat page.
  Rect get shadowRect => Rect.fromLTRB(
        foldX,
        0,
        math.min(width, foldX + shadowTrailWidth),
        height,
      );

  /// True when there is nothing to draw (fully turned either way).
  bool get isEmpty => width <= 0 || height <= 0 || t >= 1;
}

/// Luminance of the folded half at [u] across it, `0` at the crease and `1` at
/// the leading edge.
///
/// Raised cosine (a cylinder catches light that way) plus a narrow specular
/// band just past the crease where the sheet is tangent to the viewer. Explicitly
/// NON-linear — see [foldShadingIsLinear] for the assertion that proves it.
double foldShadeAt(double u) {
  final double c = u.isFinite ? u.clamp(0.0, 1.0) : 0.0;
  final double body = 0.48 + 0.36 * (1 - math.cos(math.pi * c)) / 2;
  final double specular = 0.20 * math.exp(-math.pow((c - 0.12) / 0.10, 2).toDouble());
  return (body + specular).clamp(0.0, 1.0);
}

/// One stop of the folded half's horizontal gradient.
class FoldShadeStop {
  const FoldShadeStop(this.position, this.luminance);

  /// 0 at the crease … 1 at the leading edge.
  final double position;

  /// 0 = black, 1 = white.
  final double luminance;

  @override
  String toString() =>
      'FoldShadeStop(${position.toStringAsFixed(3)}, '
      '${luminance.toStringAsFixed(3)})';
}

/// Gradient stops for the folded half, sampled from [foldShadeAt].
///
/// [samples] is the number of intervals (so 8 samples ⇒ 9 stops); a painter
/// that used two stops would produce the linear ramp this feature exists to
/// avoid.
List<FoldShadeStop> foldGradientStops({int samples = 8}) {
  final int n = samples < 2 ? 2 : samples;
  return <FoldShadeStop>[
    for (int i = 0; i <= n; i++)
      FoldShadeStop(i / n, foldShadeAt(i / n)),
  ];
}

/// True when the shading is (numerically) the straight line between its ends —
/// i.e. when the fold would look like a flat recolour. Always false for
/// [foldShadeAt]; the tests assert it stays false.
bool foldShadingIsLinear({double tolerance = 1e-3}) {
  for (int i = 1; i < 10; i++) {
    final double u = i / 10;
    final double linear = foldShadeAt(0) + (foldShadeAt(1) - foldShadeAt(0)) * u;
    if ((foldShadeAt(u) - linear).abs() > tolerance) {
      return false;
    }
  }
  return true;
}
