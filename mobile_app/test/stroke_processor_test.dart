import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/stroke_processor.dart';

/// Doc 21 §6 acceptance: palm matrix (wide contact reject, two-pointer rule,
/// stylus passes), decimation density + exact endpoints, velocity→width
/// monotonicity within [0.25, 1.0], payload key assertions, and Catmull-Rom
/// → Bézier fit goldens (mirroring Doc 07 §6, tolerance 1e-6).
void main() {
  /// Contact patch `w × h` dp, expressed through the pointer's contact
  /// ellipse (Flutter ≥3.47: `radiusMajor`/`radiusMinor` in logical pixels).
  PointerDownEvent contact(int pointer, double w, double h) =>
      PointerDownEvent(
        pointer: pointer,
        radiusMajor: w / 2,
        radiusMinor: h / 2,
      );

  StrokeProcessor processor({
    bool highlighter = false,
    Offset Function(Offset)? toWorld,
  }) =>
      StrokeProcessor(
        toWorld: toWorld ?? (Offset o) => o,
        color: '#1E1E1E',
        width: 2.5,
        highlighter: highlighter,
      );

  group('palm matrix (Doc 21 §6)', () {
    test('wide contact rejected, small contact accepted', () {
      final PalmGuard g = PalmGuard();
      expect(g.shouldReject(contact(1, 24, 8)), isTrue); // wide contact
      expect(g.shouldReject(contact(1, 24, 20)), isTrue); // both axes ≥ 18
      expect(g.shouldReject(contact(1, 18, 18)), isTrue);
      expect(g.shouldReject(contact(1, 10, 6)), isFalse);
      expect(g.shouldReject(contact(1, 17, 16)), isFalse);
    });

    test('two-pointer rule: larger flagged, stylus passes, lift clears', () {
      final PalmGuard g = PalmGuard();
      g.noteDown(contact(1, 4, 4)); // stylus down first
      expect(g.flaggedPointer, isNull);
      expect(g.shouldReject(contact(1, 4, 4)), isFalse);

      g.noteDown(contact(2, 30, 20)); // palm — larger contact area
      expect(g.flaggedPointer, 2);
      expect(g.shouldReject(contact(2, 30, 20)), isTrue);
      expect(g.shouldReject(contact(1, 4, 4)), isFalse); // stylus still draws

      g.noteUp(2);
      expect(g.flaggedPointer, isNull);
      expect(g.shouldReject(contact(3, 6, 6)), isFalse); // after lift
    });

    test('flagged pointer emits no points; rejecting mirrors the palm', () {
      final StrokeProcessor proc = processor();
      proc.palmGuard.noteDown(contact(1, 2, 2));
      proc.palmGuard.noteDown(contact(2, 30, 20));
      expect(proc.rejecting, isTrue);

      proc.addPoint(const Offset(0, 0), null, 1);
      proc.addPoint(const Offset(10, 0), null, 1);
      expect(proc.livePoints, hasLength(2));

      proc.addPoint(const Offset(50, 50), null, 2); // flagged → dropped
      expect(proc.livePoints, hasLength(2));

      proc.palmGuard.noteUp(2);
      expect(proc.rejecting, isFalse);
      proc.addPoint(const Offset(30, 0), null, 1);
      expect(proc.livePoints, hasLength(3));
    });
  });

  group('decimation (2.0 dp) + endpoint preservation', () {
    test('dense 0.4 dp wiggle drops to ≤40% of input, endpoints exact', () {
      final StrokeProcessor proc = processor();
      final List<Offset> raw = <Offset>[];
      for (int i = 0; i < 200; i++) {
        final Offset p = Offset(i * 0.35, i.isEven ? 0.1 : -0.1);
        raw.add(p);
        proc.addPoint(p, null, 1);
      }
      expect(proc.livePoints.length, lessThanOrEqualTo(80)); // ≤ 40% of 200
      expect(proc.livePoints.length, greaterThan(2));

      final ProcessedStroke? stroke = proc.finish();
      expect(stroke, isNotNull);
      expect(stroke!.pts.first, <double>[raw.first.dx, raw.first.dy]);
      expect(stroke.pts.last, <double>[raw.last.dx, raw.last.dy]);
      expect(proc.livePoints, isEmpty); // reset to idle after finish
    });

    test('finish() on 1 point (and on none) ⇒ null, then reusable', () {
      final StrokeProcessor one = processor();
      one.addPoint(const Offset(5, 5), null, 1);
      expect(one.finish(), isNull);
      expect(processor().finish(), isNull);

      one.addPoint(const Offset(1, 1), null, 1);
      one.addPoint(const Offset(21, 1), null, 1);
      expect(one.finish(), isNotNull);
    });

    test('finish pipeline: EMA smoothing, 8 px merge, bbox over controls', () {
      final StrokeProcessor proc = processor();
      for (final Offset p in const <Offset>[
        Offset(10, 10),
        Offset(30, 10),
        Offset(50, 10),
        Offset(70, 10),
      ]) {
        proc.addPoint(p, null, 1);
      }
      // livePoints (identity toWorld): first raw, then EMA α = 0.35.
      expect(proc.livePoints.first, const Offset(10, 10));
      expect(proc.livePoints[1].dx, closeTo(0.65 * 10 + 0.35 * 30, 1e-9));
      expect(proc.livePoints[2].dx, closeTo(0.65 * 17 + 0.35 * 50, 1e-9));

      final ProcessedStroke stroke = proc.finish()!;
      // (17,10) sits 7 px from the first anchor ⇒ merged away; the last raw
      // position was accepted through the EMA and is pinned exactly.
      expect(stroke.pts.first, const <double>[10.0, 10.0]);
      expect(stroke.pts.last, const <double>[70.0, 10.0]);
      expect(stroke.pts, hasLength(7)); // 3 anchors ⇒ 3·3 − 2 entries
      expect(stroke.pts[3][0], closeTo(28.55, 1e-9)); // surviving anchor
      expect(stroke.bbox, <double>[10.0, 10.0, 70.0, 10.0]);
    });
  });

  group('velocity → width (Doc 21 §4)', () {
    test('rising dp/s lowers liveHalfWidthFactor monotonically in bounds',
        () {
      final StrokeProcessor proc = processor();
      int nowMs = 0;
      proc.debugSetClock(() => nowMs);
      final List<double> factors = <double>[];
      proc.addPoint(const Offset(0, 0), null, 1);
      factors.add(proc.liveHalfWidthFactor);

      double x = 0;
      const List<int> gapsMs = <int>[
        100, 33, 20, 14, 12, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
      ];
      for (final int gapMs in gapsMs) {
        nowMs += gapMs; // fixed 10 dp spacing ⇒ rising velocity
        x += 10;
        proc.addPoint(Offset(x, 0), null, 1);
        factors.add(proc.liveHalfWidthFactor);
      }

      expect(factors.first, 1.0);
      for (int i = 1; i < factors.length; i++) {
        expect(factors[i], lessThanOrEqualTo(factors[i - 1] + 1e-12));
        expect(factors[i], inInclusiveRange(0.25, 1.0));
      }
      expect(factors.last, closeTo(0.25, 0.05)); // fast ⇒ near floor
    });

    test('slow stroke near 1.0, fast stroke near 0.25, EMA in bounds', () {
      final StrokeProcessor slow = processor();
      int t = 0;
      slow.debugSetClock(() => t);
      for (int i = 0; i < 3; i++) {
        t += 1000;
        slow.addPoint(Offset(i * 5.0, 0), null, 1); // 5 dp/s
      }
      expect(slow.liveHalfWidthFactor, closeTo(1.0, 0.01));

      final StrokeProcessor fast = processor();
      int f = 0;
      fast.debugSetClock(() => f);
      double x = 0;
      for (int i = 0; i < 20; i++) {
        f += 5;
        x += 10;
        fast.addPoint(Offset(x, 0), null, 1); // 2000 dp/s
      }
      expect(fast.liveHalfWidthFactor, inInclusiveRange(0.25, 1.0));
      expect(fast.liveHalfWidthFactor, lessThan(0.30));
    });
  });

  group('payload (overview §4.3 keys)', () {
    test('exactly the frozen key sets, snake_case, null geometry extras', () {
      final StrokeProcessor proc = processor();
      proc.addPoint(const Offset(10, 10), null, 1);
      proc.addPoint(const Offset(30, 10), null, 1);
      proc.addPoint(const Offset(50, 10), null, 1);
      final ProcessedStroke stroke = proc.finish()!;

      final Map<String, dynamic> payload = stroke.toRpcPayload();
      expect(
        payload.keys,
        unorderedEquals(<String>[
          'node_id',
          'kind',
          'layer',
          'bbox',
          'style',
          'geometry',
        ]),
      );
      expect(
        payload['node_id'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(payload['kind'], 'STROKE');
      expect(payload['layer'], 0);
      expect(payload['bbox'], stroke.bbox);

      final Map<String, dynamic> style =
          Map<String, dynamic>.from(payload['style']! as Map);
      expect(
        style.keys,
        unorderedEquals(<String>[
          'color',
          'stroke_width',
          'opacity',
          'blend_mode',
        ]),
      );
      expect(style['color'], '#1E1E1E');
      expect(style['stroke_width'], 2.5);
      expect(style['opacity'], 1.0);
      expect(style['blend_mode'], 'SRC_OVER');

      final Map<String, dynamic> geometry =
          Map<String, dynamic>.from(payload['geometry']! as Map);
      expect(
        geometry.keys,
        unorderedEquals(<String>[
          'pts',
          'shape_type',
          'graph_config',
          'asset_ref',
        ]),
      );
      expect(geometry['shape_type'], isNull);
      expect(geometry['graph_config'], isNull);
      expect(geometry['asset_ref'], isNull);
      final List<dynamic> pts = geometry['pts']! as List<dynamic>;
      expect(pts, isNotEmpty);
      expect(pts.first, isA<List<double>>());
      // World coords with exact endpoints roundtrip into the payload.
      expect(pts.first, <double>[10.0, 10.0]);
      expect(pts.last, <double>[50.0, 10.0]);
    });

    test('highlighter ⇒ kind HIGHLIGHT + blend_mode MULTIPLY', () {
      final StrokeProcessor proc = processor(highlighter: true);
      proc.addPoint(const Offset(0, 0), null, 1);
      proc.addPoint(const Offset(20, 0), null, 1);
      final ProcessedStroke stroke = proc.finish()!;
      final Map<String, dynamic> payload = stroke.toRpcPayload();
      expect(payload['kind'], 'HIGHLIGHT');
      expect(stroke.kind, 'HIGHLIGHT');
      expect((payload['style']! as Map)['blend_mode'], 'MULTIPLY');
    });
  });

  group('Bézier fit goldens (τ = 0.5, mirrors Doc 07 §6)', () {
    test('horizontal (0,0),(3,0),(6,0),(9,0) ⇒ interior c1=(4,0) c2=(5,0)',
        () {
      final List<List<double>> pts = StrokeProcessor.catmullRomToCubic(
        const <Offset>[Offset(0, 0), Offset(3, 0), Offset(6, 0), Offset(9, 0)],
      );
      expect(pts, hasLength(10)); // 4 anchors ⇒ 3·4 − 2
      expect(pts.first, const <double>[0.0, 0.0]);
      expect(pts.last, const <double>[9.0, 0.0]);
      expect(pts[4][0], closeTo(4.0, 1e-6));
      expect(pts[4][1], closeTo(0.0, 1e-6));
      expect(pts[5][0], closeTo(5.0, 1e-6));
      expect(pts[5][1], closeTo(0.0, 1e-6));
    });

    test('vertical (0,0),(0,3),(0,6),(0,9) ⇒ interior c1=(0,4) c2=(0,5)', () {
      final List<List<double>> pts = StrokeProcessor.catmullRomToCubic(
        const <Offset>[Offset(0, 0), Offset(0, 3), Offset(0, 6), Offset(0, 9)],
      );
      expect(pts[4][0], closeTo(0.0, 1e-6));
      expect(pts[4][1], closeTo(4.0, 1e-6));
      expect(pts[5][0], closeTo(0.0, 1e-6));
      expect(pts[5][1], closeTo(5.0, 1e-6));
    });

    test('mixed ⇒ interior c1=(4/3,1/6) c2=(5/3,5/6) within 1e-6', () {
      final List<List<double>> pts = StrokeProcessor.catmullRomToCubic(
        const <Offset>[
          Offset(0, 0),
          Offset(1, 0),
          Offset(2, 1),
          Offset(3, 1),
        ],
      );
      expect(pts[4][0], closeTo(4 / 3, 1e-6));
      expect(pts[4][1], closeTo(1 / 6, 1e-6));
      expect(pts[5][0], closeTo(5 / 3, 1e-6));
      expect(pts[5][1], closeTo(5 / 6, 1e-6));
    });

    test('2-point stroke clamps terminals by duplication', () {
      final List<List<double>> pts = StrokeProcessor.catmullRomToCubic(
        const <Offset>[Offset(0, 0), Offset(6, 0)],
      );
      expect(pts, hasLength(4));
      expect(pts[1], const <double>[1.0, 0.0]); // c1 = p0 + (p1 − p0)/6
      expect(pts[2], const <double>[5.0, 0.0]); // c2 = p1 − (p1 − p0)/6
    });
  });

  test('toWorld conversion boundary: camera injected, never imported', () {
    final StrokeProcessor proc = processor(
      toWorld: (Offset s) => s * 2 + const Offset(5, 7),
    );
    proc.addPoint(const Offset(10, 20), null, 1);
    proc.addPoint(const Offset(30, 20), null, 1);
    expect(proc.livePoints.first, const Offset(25, 47));
    // Second point EMA-smoothed to (17,20) before mapping: 17·2+5 = 39.
    expect(proc.livePoints[1], const Offset(39, 47));
  });
}
