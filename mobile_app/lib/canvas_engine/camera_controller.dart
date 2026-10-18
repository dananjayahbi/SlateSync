/// Doc 20 — 2-D affine world camera for the infinite canvas: focal-anchored
/// pinch zoom (0.05×–20.0×), two-finger pan, zoom-to-fit with 48-unit padding,
/// world↔screen transforms, and the `CameraSnapshot` hook Doc 25 streams as
/// 60 Hz binary camera frames (f1 = scale, f2 = tx, f3 = ty).
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';

/// Frozen camera state → live camera frame `f1`/`f2`/`f3` (template §5).
class CameraSnapshot {
  const CameraSnapshot(this.scale, this.tx, this.ty);

  /// `f1` — zoom factor, clamped `0.05 … 20.0`.
  final double scale;

  /// `f2` — world x at the viewport center.
  final double tx;

  /// `f3` — world y at the viewport center.
  final double ty;
}

/// Template §5 `CameraController` freeze (Doc 20).
///
/// Transform (template §3): `screen = (world − c) * s + viewport/2`,
/// inverse `world = (screen − viewport/2)/s + c`.
class CameraController {
  CameraController({double initialScale = 1.0}) {
    scale = initialScale;
  }

  static const double _minZoom = 0.05;
  static const double _maxZoom = 20.0;

  double _scale = 1.0;
  Offset _txy = Offset.zero;

  // Cumulative gesture baselines captured by [onScaleStart] (Doc 20 §4).
  double _s0 = 1.0;
  Offset _f0 = Offset.zero;
  Offset _c0 = Offset.zero;
  bool _gestureStarted = false;

  // Viewport backing [viewMatrix]; last `onScaleUpdate` size, default 800×600.
  Size _viewport = const Size(800, 600);

  /// 60 Hz sync hook — fires once per accepted gesture frame (Doc 25 sender
  /// throttles); [applyRemote] stays silent so remote frames never echo back.
  void Function(CameraSnapshot snap)? onCameraChanged;

  double get scale => _scale;

  set scale(double value) {
    if (!value.isFinite) {
      return;
    }
    _scale = value.clamp(_minZoom, _maxZoom).toDouble();
  }

  CameraSnapshot get snapshot => CameraSnapshot(_scale, _txy.dx, _txy.dy);

  /// `T(viewport/2) · S(s) · T(−c)` over the viewport cached by the last
  /// [onScaleUpdate] (Doc 20 §5.2).
  Matrix4 get viewMatrix => Matrix4.identity()
    ..translateByDouble(_viewport.width / 2, _viewport.height / 2, 0, 1)
    ..scaleByDouble(_scale, _scale, _scale, 1)
    ..translateByDouble(-_txy.dx, -_txy.dy, 0, 1);

  Offset worldToScreen(Offset world, Size viewport) =>
      (world - _txy) * _scale + Offset(viewport.width / 2, viewport.height / 2);

  Offset screenToWorld(Offset screen, Size viewport) =>
      (screen - Offset(viewport.width / 2, viewport.height / 2)) / _scale + _txy;

  void onScaleStart(ScaleStartDetails d) {
    _s0 = _scale;
    _f0 = d.focalPoint;
    _c0 = _txy;
    _gestureStarted = true;
  }

  void onScaleUpdate(ScaleUpdateDetails d, Size viewport) {
    _viewport = viewport;
    // Doc 20 §5.6 — non-finite gesture data is ignored entirely.
    if (!d.scale.isFinite ||
        !d.focalPoint.dx.isFinite ||
        !d.focalPoint.dy.isFinite) {
      return;
    }
    if (!_gestureStarted) {
      // Update without a start self-heals on the current state.
      _s0 = _scale;
      _f0 = d.focalPoint;
      _c0 = _txy;
      _gestureStarted = true;
    }
    // Doc 20 §4 cumulative pinch: `d.scale` is cumulative since the start
    // baseline, then keep `w0` (the world point under the initial focal
    // point) fixed under the current focal point.
    final double s = (_s0 * d.scale).clamp(_minZoom, _maxZoom).toDouble();
    final Offset half = Offset(viewport.width / 2, viewport.height / 2);
    final Offset w0 = (_f0 - half) / _s0 + _c0;
    _scale = s;
    _txy = w0 - (d.focalPoint - half) / s;
    onCameraChanged?.call(snapshot);
  }

  /// 48-unit padding per side ⇒ `+96` total on each axis (Doc 20 §4).
  void zoomToFit(Rect bounds, Size viewport) {
    final double dw = bounds.width + 96;
    final double dh = bounds.height + 96;
    final double zx = dw > 0 ? viewport.width / dw : _maxZoom;
    final double zy = dh > 0 ? viewport.height / dh : _maxZoom;
    scale = zx < zy ? zx : zy;
    _txy = bounds.center;
    onCameraChanged?.call(snapshot);
  }

  /// Remote-origin camera frames: clamp + assign only — never echoes the
  /// [onCameraChanged] hook (echo protection, Doc 20 §5.8).
  void applyRemote(double scale, double tx, double ty) {
    this.scale = scale;
    if (tx.isFinite && ty.isFinite) {
      _txy = Offset(tx, ty);
    }
  }

  /// Test seeding bypassing gestures (Doc 20 §4) — silent like [applyRemote].
  @visibleForTesting
  void debugSet(double scale, double tx, double ty) {
    this.scale = scale;
    if (tx.isFinite && ty.isFinite) {
      _txy = Offset(tx, ty);
    }
  }
}
