import 'package:flutter/gestures.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/camera_controller.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Doc 20 §6 acceptance: world↔screen roundtrip at 5 zooms, clamp enforcement
/// (0.05/20.0), zoomToFit containment + centering, focal-anchor invariance
/// ≤ 1e-6, viewMatrix equivalence, and snapshot → f1/f2/f3 field order.
void main() {
  const Size vp = Size(800, 600);

  List<Offset> worldSamples() => const <Offset>[
        Offset.zero,
        Offset(123.45, -678.9),
        Offset(-4000.5, 3000.25),
        Offset(1e6, -1e6),
      ];

  group('world↔screen roundtrip', () {
    for (final double z in const <double>[0.05, 0.5, 1.0, 8.0, 20.0]) {
      test('zoom $z roundtrips within 1e-6', () {
        final CameraController cam =
            CameraController()..debugSet(z, -137.5, 42.25);
        for (final Offset w in worldSamples()) {
          final Offset rt = cam.screenToWorld(cam.worldToScreen(w, vp), vp);
          expect(rt.dx, closeTo(w.dx, 1e-6));
          expect(rt.dy, closeTo(w.dy, 1e-6));
        }
      });
    }
  });

  group('zoom clamp 0.05 … 20.0', () {
    test('constructor clamps both ends', () {
      expect(CameraController(initialScale: 0.001).scale, 0.05);
      expect(CameraController(initialScale: 100.0).scale, 20.0);
      expect(CameraController().scale, 1.0);
    });

    test('setter clamps both ends and ignores non-finite input', () {
      final CameraController cam = CameraController();
      cam.scale = 1e-6;
      expect(cam.scale, 0.05);
      cam.scale = 1e6;
      expect(cam.scale, 20.0);
      cam.scale = double.nan;
      expect(cam.scale, 20.0);
    });

    test('pinch clamps s0 × d.scale at both ends', () {
      final CameraController high = CameraController()..debugSet(10.0, 0, 0);
      high.onScaleStart(ScaleStartDetails(focalPoint: const Offset(400, 300)));
      high.onScaleUpdate(
        ScaleUpdateDetails(
          focalPoint: const Offset(400, 300),
          scale: 100.0,
        ),
        vp,
      );
      expect(high.scale, 20.0);

      final CameraController low = CameraController()..debugSet(0.1, 0, 0);
      low.onScaleStart(ScaleStartDetails(focalPoint: const Offset(400, 300)));
      low.onScaleUpdate(
        ScaleUpdateDetails(
          focalPoint: const Offset(400, 300),
          scale: 0.001,
        ),
        vp,
      );
      expect(low.scale, 0.05);
    });

    test('applyRemote clamps too', () {
      final CameraController cam = CameraController();
      cam.applyRemote(99.0, 5.0, -5.0);
      expect(cam.scale, 20.0);
      expect(cam.snapshot.tx, 5.0);
      expect(cam.snapshot.ty, -5.0);
      cam.applyRemote(1e-4, 7.0, -7.0);
      expect(cam.scale, 0.05);
      expect(cam.snapshot.tx, 7.0);
    });
  });

  group('zoomToFit (48-unit padding)', () {
    final Map<String, (double, double)> presets = <String, (double, double)>{
      'A5': (Presets.a5.w, Presets.a5.h),
      'A4': (Presets.a4.$1, Presets.a4.$2),
      'Letter': (Presets.letter.$1, Presets.letter.$2),
    };

    presets.forEach((String name, (double, double) dims) {
      test('$name: rect+48u maps inside viewport and centers exactly', () {
        final Rect bounds = Rect.fromLTWH(0, 0, dims.$1, dims.$2);
        final CameraController cam = CameraController()
          ..zoomToFit(bounds, vp);
        final Rect padded = Rect.fromLTWH(
          -48,
          -48,
          bounds.width + 96,
          bounds.height + 96,
        );
        for (final Offset corner in <Offset>[
          padded.topLeft,
          padded.topRight,
          padded.bottomLeft,
          padded.bottomRight,
        ]) {
          final Offset s = cam.worldToScreen(corner, vp);
          expect(s.dx, greaterThanOrEqualTo(-1e-6));
          expect(s.dx, lessThanOrEqualTo(vp.width + 1e-6));
          expect(s.dy, greaterThanOrEqualTo(-1e-6));
          expect(s.dy, lessThanOrEqualTo(vp.height + 1e-6));
        }
        final Offset c = cam.worldToScreen(bounds.center, vp);
        expect(c.dx, closeTo(vp.width / 2, 1e-9));
        expect(c.dy, closeTo(vp.height / 2, 1e-9));
      });
    });

    test('viewport smaller than 96+1 units clamps to 0.05', () {
      final CameraController cam = CameraController()
        ..zoomToFit(Rect.fromLTWH(0, 0, 1748, 2480), const Size(50, 50));
      expect(cam.scale, 0.05);
    });

    test('tiny bounds in a huge viewport never exceed 20.0', () {
      final CameraController cam = CameraController()
        ..zoomToFit(Rect.fromLTWH(0, 0, 1, 1), const Size(8000, 6000));
      expect(cam.scale, 20.0);
    });
  });

  group('focal-anchor invariance', () {
    test('pinch keeps w0 fixed under the current focal point (cumulative)',
        () {
      final CameraController cam = CameraController()..debugSet(1.0, 0, 0);
      const Offset f0 = Offset(200, 150);
      cam.onScaleStart(ScaleStartDetails(focalPoint: f0));
      final Offset w0 = cam.screenToWorld(f0, vp);

      const Offset f1 = Offset(260, 190);
      cam.onScaleUpdate(
        ScaleUpdateDetails(focalPoint: f1, scale: 2.0),
        vp,
      );
      Offset after = cam.screenToWorld(f1, vp);
      expect(after.dx, closeTo(w0.dx, 1e-6));
      expect(after.dy, closeTo(w0.dy, 1e-6));

      // Second update still baselines on the gesture start (d.scale
      // is cumulative since onScaleStart, not incremental).
      const Offset f2 = Offset(300, 250);
      cam.onScaleUpdate(
        ScaleUpdateDetails(focalPoint: f2, scale: 4.0),
        vp,
      );
      expect(cam.scale, 4.0);
      after = cam.screenToWorld(f2, vp);
      expect(after.dx, closeTo(w0.dx, 1e-6));
      expect(after.dy, closeTo(w0.dy, 1e-6));
    });

    test('pure two-finger pan preserves the anchor (c′ = c0 − Δf/s)', () {
      final CameraController cam = CameraController()..debugSet(1.0, 10, 20);
      const Offset f0 = Offset(200, 150);
      cam.onScaleStart(ScaleStartDetails(focalPoint: f0));
      final Offset w0 = cam.screenToWorld(f0, vp);

      const Offset f1 = Offset(300, 250);
      cam.onScaleUpdate(
        ScaleUpdateDetails(focalPoint: f1, scale: 1.0),
        vp,
      );
      expect(cam.snapshot.tx, closeTo(10 - 100, 1e-9));
      expect(cam.snapshot.ty, closeTo(20 - 100, 1e-9));
      final Offset after = cam.screenToWorld(f1, vp);
      expect(after.dx, closeTo(w0.dx, 1e-6));
      expect(after.dy, closeTo(w0.dy, 1e-6));
    });
  });

  group('viewMatrix ≡ worldToScreen', () {
    for (final double z in const <double>[0.5, 1.0, 8.0]) {
      test('zoom $z at viewport 800×600 within 1e-6', () {
        final CameraController cam = CameraController()
          ..debugSet(z, 37.5, -91.25);
        for (final Offset w in worldSamples()) {
          final Offset viaMatrix = MatrixUtils.transformPoint(
            cam.viewMatrix,
            w,
          );
          final Offset viaFn = cam.worldToScreen(w, vp);
          expect(viaMatrix.dx, closeTo(viaFn.dx, 1e-6));
          expect(viaMatrix.dy, closeTo(viaFn.dy, 1e-6));
        }
      });
    }
  });

  test('snapshot maps f1=scale, f2=tx, f3=ty in byte order', () {
    final CameraController cam = CameraController()
      ..debugSet(2.5, 11.5, -7.25);
    final CameraSnapshot snap = cam.snapshot;
    expect(snap.scale, 2.5);
    expect(snap.tx, 11.5);
    expect(snap.ty, -7.25);

    final frame = WireCodec.buildFrame(
      frameType: FrameType.camera,
      toolId: ToolId.pen,
      seq: 1,
      f1: snap.scale,
      f2: snap.tx,
      f3: snap.ty,
    );
    final LiveFrame decoded =
        WireCodec.decodeFrame(frame.buffer.asUint8List());
    expect(decoded.frameType, FrameType.camera);
    expect(decoded.toolId, ToolId.pen);
    expect(decoded.f1, 2.5); // scale → f1
    expect(decoded.f2, 11.5); // tx → f2
    expect(decoded.f3, -7.25); // ty → f3
  });

  group('onCameraChanged hook', () {
    test('fires once per gesture frame, zoomToFit fires, applyRemote silent',
        () {
      final CameraController cam = CameraController()..debugSet(1.0, 0, 0);
      final List<CameraSnapshot> seen = <CameraSnapshot>[];
      cam.onCameraChanged = seen.add;

      cam.onScaleStart(ScaleStartDetails(focalPoint: const Offset(400, 300)));
      cam.onScaleUpdate(
        ScaleUpdateDetails(focalPoint: const Offset(400, 300), scale: 2.0),
        vp,
      );
      expect(seen, hasLength(1));
      expect(seen.single.scale, cam.scale);
      expect(seen.single.tx, cam.snapshot.tx);
      expect(seen.single.ty, cam.snapshot.ty);

      cam.zoomToFit(Rect.fromLTWH(0, 0, 1748, 2480), vp);
      expect(seen, hasLength(2));

      cam.applyRemote(1.5, 3, 4);
      expect(seen, hasLength(2)); // remote frames never echo back
    });

    test('update without start self-heals; non-finite data ignored', () {
      final CameraController cam = CameraController(); // scale 1.0
      final List<CameraSnapshot> seen = <CameraSnapshot>[];
      cam.onCameraChanged = seen.add;

      cam.onScaleUpdate(
        ScaleUpdateDetails(focalPoint: const Offset(400, 300), scale: 2.0),
        vp,
      );
      expect(cam.scale, 2.0); // baseline self-healed to current state
      expect(seen, hasLength(1));

      cam.onScaleUpdate(
        ScaleUpdateDetails(
          focalPoint: const Offset(double.nan, 300),
          scale: 2.0,
        ),
        vp,
      );
      expect(seen, hasLength(1)); // non-finite focal ignored entirely
      expect(cam.scale, 2.0);
    });
  });
}
