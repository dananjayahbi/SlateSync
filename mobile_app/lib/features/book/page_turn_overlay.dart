/// Round-13 issue 04 — the page-turn overlay and its reduced-motion path.
///
/// This sits ABOVE the canvas as a non-hit-testing overlay: it never mutates
/// engine state per frame, so the tile cache, the live stroke layer and the
/// selector keep working untouched during a turn.
///
/// Reduced motion is a first-class path, not a shortened animation. A
/// full-page fold is exactly the animation that makes some people motion-sick,
/// so when the platform asks for reduced motion the page changes on the next
/// frame with no fold at all — [PageTurnOverlay.reducedMotion] then reports
/// `false` for [isAnimating] and the painter is never mounted.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mobile_app/features/book/page_turn_painter.dart';

/// How long one fold takes. Long enough to read as paper, short enough that
/// paging through a book does not feel like waiting.
const Duration kPageTurnDuration = Duration(milliseconds: 380);

/// Easing for the fold: a sheet leaves the hand quickly and settles slowly, so
/// it is a decelerating curve rather than a symmetric one.
const Curve kPageTurnCurve = Curves.easeOutCubic;

/// Overlay that animates a single page turn between two page ids.
///
/// The parent owns "which page is current"; this widget only reports the intent
/// ([onTurnCompleted]) and draws the fold. It is deliberately stateless about
/// document content: drawing page snapshots per frame would mean re-rendering
/// the engine, which the brief forbids.
class PageTurnOverlay extends StatefulWidget {
  const PageTurnOverlay({
    super.key,
    required this.pageRect,
    required this.direction,
    required this.reducedMotion,
    this.duration = kPageTurnDuration,
    this.paperColor = const Color(0xFFFFFFFF),
    this.onTurnCompleted,
    this.onTurnStarted,
  });

  /// Where the page sits in this overlay's coordinate space (screen px).
  final Rect pageRect;

  final PageTurnDirection direction;

  /// True when the platform asked for reduced motion — the instant path.
  final bool reducedMotion;

  final Duration duration;
  final Color paperColor;

  /// Fired once, when the fold reaches its end (or immediately when instant).
  final VoidCallback? onTurnCompleted;

  /// Fired when the fold starts, so a parent can freeze input for its length.
  final VoidCallback? onTurnStarted;

  @override
  State<PageTurnOverlay> createState() => _PageTurnOverlayState();
}

class _PageTurnOverlayState extends State<PageTurnOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// Latest completed turn, latched so a rebuild cannot fire it twice.
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(PageTurnOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.direction != widget.direction ||
        oldWidget.reducedMotion != widget.reducedMotion ||
        oldWidget.pageRect != widget.pageRect) {
      _start();
    }
  }

  void _start() {
    _completed = false;
    widget.onTurnStarted?.call();
    if (widget.reducedMotion) {
      // No fold at all: jump to the end and never mount the painter. Completion
      // is deferred to the next frame because `_start` also runs from
      // `initState`, where the parent must not be asked to setState.
      _controller.value = 1.0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
      return;
    }
    _controller
      ..stop()
      ..value = 0.0
      ..forward().whenCompleteOrCancel(_finish);
  }

  void _finish() {
    if (_completed || !mounted) {
      return;
    }
    _completed = true;
    widget.onTurnCompleted?.call();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// True while a visible fold is on screen (always false under reduced motion).
  bool get isAnimating =>
      !widget.reducedMotion && _controller.isAnimating && _controller.value < 1.0;

  @override
  Widget build(BuildContext context) {
    if (widget.reducedMotion || widget.pageRect.isEmpty) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            final double t = kPageTurnCurve.transform(
              _controller.value.clamp(0.0, 1.0),
            );
            return CustomPaint(
              painter: PageTurnPainter(
                pageRect: widget.pageRect,
                t: t,
                direction: widget.direction,
                paperColor: widget.paperColor,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

/// Apply the fold easing to a raw `0..1` progress (shared with tests).
double pageTurnProgress(double raw) =>
    kPageTurnCurve.transform(raw.clamp(0.0, 1.0)).toDouble();

/// Milliseconds a turn should take, honouring reduced motion (`0` = instant).
int pageTurnMillisFor({required bool reducedMotion, Duration? duration}) =>
    reducedMotion ? 0 : (duration ?? kPageTurnDuration).inMilliseconds;

/// Pick the turn direction for a step from [fromIndex] to [toIndex].
///
/// Forward when reading right; backwards otherwise, including a "turn" to the
/// same page (which paints nothing anyway).
PageTurnDirection pageTurnDirection(int fromIndex, int toIndex) =>
    toIndex >= fromIndex ? PageTurnDirection.forward : PageTurnDirection.backward;

/// Fold progress at a fraction of the turn, so callers can assert the shape of
/// the animation without owning a controller: `0 → 0`, `1 → 1`, monotonic and
/// accelerating away from zero.
double pageTurnProgressForFrame(int frame, int totalFrames) {
  if (totalFrames <= 0) {
    return 1.0;
  }
  final double raw = (frame / totalFrames).clamp(0.0, 1.0);
  return pageTurnProgress(raw);
}

/// Largest fold bow a page of [width] produces (used to size the shadow).
double pageTurnMaxBow(double width) => math.max(0.0, width) * 0.02;
