/// Doc 21 — stylus stroke pipeline: palm/glove rejection ([PalmGuard]),
/// velocity pseudo-pressure, 2.0 dp distance decimation + jitter EMA, and a
/// Catmull-Rom → cubic Bézier fit in world coordinates emitting the Doc 03
/// element JSON. The camera conversion is injected (`toWorld`) so this module
/// never imports Doc 20 (decoupling, Doc 21 §4).
library;

import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/gestures.dart';

import 'package:mobile_app/core/models/canvas_models.dart';

// Doc 21 §4 / template §3 master constants — single source of truth.
const double _kDecimationDp = 2.0;
const double _kPalmAxisDp = 18.0;
const double _kVelocityFull = 1200.0;
const double _kPressureFloor = 0.25;
const double _kJitterAlpha = 0.35;
const double _kTension = 0.5;
const double _kAnchorMergePx = 8.0;

/// Doc 21 §5 freeze — contact-size + two-pointer palm/glove rejection.
class PalmGuard {
  final Map<int, PointerEvent> _active = <int, PointerEvent>{};
  final Map<int, double> _areas = <int, double>{};
  int? _flagged;

  /// Tracks a pointer-down contact; area = bounding box of the contact
  /// ellipse (`2·radiusMajor × 2·radiusMinor`, logical pixels).
  void noteDown(PointerEvent e) {
    _active[e.pointer] = e;
    _areas[e.pointer] = 4.0 * e.radiusMajor * e.radiusMinor;
    _recomputeFlag();
  }

  /// Removes a lifted pointer; the palm flag recomputes over what remains.
  void noteUp(int pointer) {
    _active.remove(pointer);
    _areas.remove(pointer);
    _recomputeFlag();
  }

  /// Largest-contact pointer flagged palm/glove while ≥2 pointers overlap
  /// (ties keep the first); null otherwise (Doc 21 §4).
  int? get flaggedPointer => _flagged;

  bool shouldReject(PointerEvent e, {double minorAxisDp = _kPalmAxisDp}) =>
      _wideContact(e, minorAxisDp) || e.pointer == _flagged;

  /// Doc 21 §5.6 — true while any tracked pointer is currently rejected.
  bool get rejecting => _active.values.any(
        (PointerEvent e) =>
            _wideContact(e, _kPalmAxisDp) || e.pointer == _flagged,
      );

  void _recomputeFlag() {
    if (_areas.length < 2) {
      _flagged = null;
      return;
    }
    int? largest;
    double maxArea = -1.0;
    double minArea = double.infinity;
    _areas.forEach((int pointer, double area) {
      if (area > maxArea) {
        // Strict `>` ⇒ among equal maxima the first inserted wins.
        maxArea = area;
        largest = pointer;
      }
      if (area < minArea) {
        minArea = area;
      }
    });
    // Doc 21 §4: only a *strictly larger* contact is flagged palm/glove —
    // on ties nobody is flagged, so the first (stylus) pointer keeps drawing.
    _flagged = maxArea > minArea ? largest : null;
  }

  /// Doc 21 §4 width rule: either contact axis (`2 × radius`, dp) reaching
  /// the threshold rejects. The minor-axis clause `min ≥ t` is subsumed
  /// (`min ≥ t ⇒ max ≥ t`), and §6's palm matrix additionally requires wide
  /// contacts to reject whose minor axis alone is below the threshold
  /// (24×8 dp ⇒ rejected) — hence the larger axis decides. Note: Flutter
  /// ≥3.47 reports the contact ellipse via `radiusMajor`/`radiusMinor`;
  /// `PointerEvent.size` is a normalized 0..1 area, not a dp [Size].
  bool _wideContact(PointerEvent e, double minorAxisDp) {
    final double axisA = 2.0 * e.radiusMajor;
    final double axisB = 2.0 * e.radiusMinor;
    return max(axisA, axisB) >= minorAxisDp;
  }
}

/// Doc 21 §5 freeze — committed stroke element; [toRpcPayload] matches the
/// Doc 03 / overview §4.3 element JSON exactly.
class ProcessedStroke {
  ProcessedStroke({
    required this.nodeId,
    required this.kind,
    required this.pts,
    required this.bbox,
    required this.color,
    required this.strokeWidth,
    this.opacity = 1.0,
  });

  final String nodeId;

  /// `"STROKE"` or `"HIGHLIGHT"`.
  final String kind;

  /// World-space Bézier control chain `[P0, c1, c2, P1, c1, c2, P2, …]`.
  final List<List<double>> pts;

  /// `[minX, minY, maxX, maxY]` — union of all control + endpoint coords.
  final List<double> bbox;

  final String color;
  final double strokeWidth;
  final double opacity;

  Map<String, dynamic> toRpcPayload() => CanvasNodeModel(
        nodeId: nodeId,
        kind: kind,
        layer: 0,
        bbox: bbox,
        style: NodeStyleModel(
          color: color,
          strokeWidth: strokeWidth,
          opacity: opacity,
          blendMode: kind == 'HIGHLIGHT' ? 'MULTIPLY' : 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(pts: pts),
      ).toJson();
}

/// Doc 21 §5 freeze — raw pointer stream → decimated, smoothed, fitted stroke.
class StrokeProcessor {
  StrokeProcessor({
    required this.toWorld,
    required this.color,
    required this.width,
    required this.highlighter,
  });

  /// Injected world conversion — bound to the Doc 20 camera at stroke start
  /// by the caller; this module never imports the camera (Doc 21 §4).
  final Offset Function(Offset) toWorld;
  final String color;
  final double width;
  final bool highlighter;

  /// Palm input surface: the pointer plumbing feeds Doc 21 events here;
  /// [rejecting] and the [addPoint] flag gate mirror it (§5.3/§5.6).
  final PalmGuard palmGuard = PalmGuard();

  final List<Offset> _live = <Offset>[]; // world, EMA-smoothed
  final List<Offset> _rawAccepted = <Offset>[]; // raw screen of accepted points
  final List<Offset> _qScreen = <Offset>[]; // EMA screen of accepted points

  Offset? _q; // jitter low-pass carrier (α = 0.35)
  Offset? _lastAccepted; // decimation + velocity reference (raw screen)
  Offset? _lastSeenRaw; // newest raw position — finish() force-accepts it
  int? _lastAcceptMs;
  double _pressure = 1.0; // EMA-smoothed pseudo-pressure (α = 0.25)
  int Function()? _clock; // test seam; wall clock otherwise

  List<Offset> get livePoints => List<Offset>.unmodifiable(_live);

  bool get rejecting => palmGuard.rejecting;

  /// Doc 21 §5.4 — smoothed half-width factor `pS ∈ [0.25, 1.0]`; feeds the
  /// live half-width and Doc 25's `f3` (width_pressure_factor).
  @visibleForTesting
  double get liveHalfWidthFactor => _pressure;

  /// Doc 21 §5.4 quantity — committed payloads keep the base [width].
  @visibleForTesting
  double get liveWidth => width * _pressure;

  /// Velocity-clock seam for deterministic tests (wall clock by default).
  @visibleForTesting
  void debugSetClock(int Function()? clock) {
    _clock = clock;
  }

  void addPoint(Offset screenPos, double? pressure, int pointer) {
    if (palmGuard.flaggedPointer == pointer) {
      return; // flagged palm/glove emits no points (§5.3)
    }
    if (!screenPos.dx.isFinite || !screenPos.dy.isFinite) {
      return;
    }
    _lastSeenRaw = screenPos;
    final int nowMs =
        _clock != null ? _clock!() : DateTime.now().millisecondsSinceEpoch;

    final Offset? last = _lastAccepted;
    final double dist =
        last == null ? 0.0 : (screenPos - last).distance;

    // Velocity since the last accepted point (dp/s; first point v = 0).
    double v = 0.0;
    if (last != null) {
      final int dt = nowMs - (_lastAcceptMs ?? nowMs);
      if (dt > 0) {
        v = dist / dt * 1000.0;
      } else {
        v = dist > 0 ? double.infinity : 0.0;
      }
    }

    // Pseudo-pressure: real pressure when supplied, velocity fallback
    // `p = clamp(1 − v/1200, 0.25, 1.0)` (§4), smoothed EMA α = 0.25.
    final double p = pressure != null && pressure.isFinite
        ? pressure.clamp(_kPressureFloor, 1.0).toDouble()
        : (1.0 - v / _kVelocityFull).clamp(_kPressureFloor, 1.0).toDouble();
    _pressure = 0.75 * _pressure + 0.25 * p;

    // 2.0 dp decimation gate (§4) — pressure state still advanced above.
    if (last != null && dist < _kDecimationDp) {
      return;
    }

    // Jitter low-pass EMA (first point accepted raw), then inject → world.
    final Offset smoothed = _q == null
        ? screenPos
        : Offset(
            _q!.dx * 0.65 + screenPos.dx * _kJitterAlpha,
            _q!.dy * 0.65 + screenPos.dy * _kJitterAlpha,
          );
    _q = smoothed;
    _lastAccepted = screenPos;
    _lastAcceptMs = nowMs;
    _rawAccepted.add(screenPos);
    _qScreen.add(smoothed);
    _live.add(toWorld(smoothed));
  }

  /// Doc 21 §4 — force-accepts the final raw position (endpoints preserved
  /// exactly), fits Catmull-Rom → cubic Bézier controls in world coords,
  /// resets to idle, and returns null when fewer than 2 points remain.
  ProcessedStroke? finish() {
    final Offset? finalRaw = _lastSeenRaw;
    if (finalRaw != null) {
      if (_rawAccepted.isEmpty) {
        _rawAccepted.add(finalRaw);
        _qScreen.add(finalRaw);
        _live.add(toWorld(finalRaw));
      } else if (_rawAccepted.last == finalRaw) {
        // Endpoint already accepted through the EMA — pin it exactly (§4).
        _qScreen[_qScreen.length - 1] = finalRaw;
        _live[_live.length - 1] = toWorld(finalRaw);
      } else {
        // Force-accept final raw (bypasses distance gate + EMA, §4).
        _rawAccepted.add(finalRaw);
        _qScreen.add(finalRaw);
        _live.add(toWorld(finalRaw));
      }
    }

    if (_rawAccepted.length < 2) {
      _reset();
      return null;
    }

    // Merge anchors closer than 8 px; first and last stay exact (§4).
    final int n = _qScreen.length;
    final List<int> kept = <int>[0];
    for (int i = 1; i < n - 1; i++) {
      if ((_qScreen[i] - _qScreen[kept.last]).distance >= _kAnchorMergePx) {
        kept.add(i);
      }
    }
    if (kept.last != n - 1) {
      kept.add(n - 1);
    }

    final List<Offset> anchors = <Offset>[
      for (final int i in kept) _live[i],
    ];
    final List<List<double>> pts = catmullRomToCubic(anchors);

    // bbox = axis-aligned union of all control + endpoint coordinates (§4).
    double minX = pts[0][0];
    double minY = pts[0][1];
    double maxX = pts[0][0];
    double maxY = pts[0][1];
    for (final List<double> c in pts) {
      if (c[0] < minX) minX = c[0];
      if (c[0] > maxX) maxX = c[0];
      if (c[1] < minY) minY = c[1];
      if (c[1] > maxY) maxY = c[1];
    }

    final ProcessedStroke stroke = ProcessedStroke(
      nodeId: _uuidV4(),
      kind: highlighter ? 'HIGHLIGHT' : 'STROKE',
      pts: pts,
      bbox: <double>[minX, minY, maxX, maxY],
      color: color,
      strokeWidth: width,
      opacity: 1.0,
    );
    _reset();
    return stroke;
  }

  /// Doc 21 §4 — Catmull-Rom (τ = 0.5) → cubic chain laid out as
  /// `[P0, c1, c2, P1, c1, c2, P2, …]` in world coords: per segment
  /// `c1 = Pi + (τ/3)(Pi+1 − Pi−1)`, `c2 = Pi+1 − (τ/3)(Pi+2 − Pi)`,
  /// terminals clamped by duplicating the endpoint.
  @visibleForTesting
  static List<List<double>> catmullRomToCubic(List<Offset> anchors) {
    if (anchors.isEmpty) {
      return <List<double>>[];
    }
    final List<List<double>> out = <List<double>>[
      <double>[anchors.first.dx, anchors.first.dy],
    ];
    final int k = anchors.length;
    final double t = _kTension / 3.0;
    for (int i = 0; i + 1 < k; i++) {
      final Offset p = anchors[i];
      final Offset pNext = anchors[i + 1];
      final Offset pPrev = i > 0 ? anchors[i - 1] : anchors.first;
      final Offset pNext2 = i + 2 < k ? anchors[i + 2] : anchors.last;
      final Offset c1 = p + (pNext - pPrev) * t;
      final Offset c2 = pNext - (pNext2 - p) * t;
      out.add(<double>[c1.dx, c1.dy]);
      out.add(<double>[c2.dx, c2.dy]);
      out.add(<double>[pNext.dx, pNext.dy]);
    }
    return out;
  }

  void _reset() {
    _live.clear();
    _rawAccepted.clear();
    _qScreen.clear();
    _q = null;
    _lastAccepted = null;
    _lastSeenRaw = null;
    _lastAcceptMs = null;
    _pressure = 1.0;
  }
}

/// RFC 4122 v4 via `Random.secure()` (Doc 21 §5.2 — no uuid dependency,
/// helper kept private to this file).
String _uuidV4() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final String h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}'
      '-${h.substring(16, 20)}-${h.substring(20)}';
}
