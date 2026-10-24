import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/stroke_eraser.dart';
import 'package:mobile_app/canvas_engine/stroke_eraser_controller.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Round-8 issue 03 — the brush eraser.
///
/// The old eraser deleted whole nodes, so a stroke could only be removed
/// entirely. These tests pin the new model: a brush pass SPLITS a stroke into
/// the fragments outside the swept disc, while element mode keeps the old
/// whole-node delete.
void main() {
  CanvasNodeModel stroke(List<List<double>> pts, {String kind = 'STROKE'}) =>
      CanvasNodeModel(
        nodeId: 'n1',
        kind: kind,
        layer: 0,
        bbox: polylineBounds(
          pts.map((List<double> p) => Offset(p[0], p[1])).toList(),
        ),
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 2.5,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(pts: pts),
      );

  CanvasNodeModel box(String shape) => CanvasNodeModel(
        nodeId: 's1',
        kind: 'SHAPE',
        layer: 0,
        bbox: <double>[0, 0, 100, 100],
        style: NodeStyleModel(
          color: '#1E1E1E',
          strokeWidth: 2.5,
          opacity: 1.0,
          blendMode: 'SRC_OVER',
        ),
        geometry: NodeGeometryModel(pts: <List<double>>[], shapeType: shape),
      );

  // A 10-point horizontal line at y = 0, x = 0..9.
  final List<List<double>> line = <List<double>>[
    for (int i = 0; i < 10; i++) <double>[i.toDouble(), 0],
  ];

  group('EraseDisc', () {
    test('contains() is inclusive of its own radius', () {
      const EraseDisc d = EraseDisc(Offset(0, 0), 5);
      expect(d.contains(const Offset(5, 0)), isTrue);
      expect(d.contains(const Offset(0, 5)), isTrue);
      expect(d.contains(const Offset(5.0001, 0)), isFalse);
    });

    test('uses squared distance (diagonal point outside a square but inside)',
        () {
      const EraseDisc d = EraseDisc(Offset(0, 0), 5);
      // (3,3) is 4.24 away → inside the circle, outside the [0,5] box.
      expect(d.contains(const Offset(3, 3)), isTrue);
    });
  });

  group('splitPolyline', () {
    test('a disc in the middle yields two fragments either side', () {
      final List<List<Offset>> parts = splitPolyline(
        line.map((List<double> p) => Offset(p[0], p[1])).toList(),
        <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1.0)],
      );
      expect(parts, hasLength(2));
      // The disc spans x ∈ [3.5, 5.5], so vertices 4 AND 5 are erased:
      // 0..3 survive on the left, 6..9 on the right.
      expect(parts[0].map((Offset p) => p.dx), <double>[0, 1, 2, 3]);
      expect(parts[1].map((Offset p) => p.dx), <double>[6, 7, 8, 9]);
    });

    test('a disc off the polyline changes nothing', () {
      final List<List<Offset>> parts = splitPolyline(
        line.map((List<double> p) => Offset(p[0], p[1])).toList(),
        <EraseDisc>[const EraseDisc(Offset(4.5, 500), 1.0)],
      );
      expect(parts, hasLength(1));
      expect(parts.first, hasLength(line.length));
    });

    test('a disc swallowing everything yields no fragments', () {
      expect(
        splitPolyline(
          line.map((List<double> p) => Offset(p[0], p[1])).toList(),
          <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1000)],
        ),
        isEmpty,
      );
    });

    test('fragments shorter than minPoints are dropped', () {
      // Only point 0 survives on the left → a 1-point fragment is discarded.
      final List<List<Offset>> parts = splitPolyline(
        line.map((List<double> p) => Offset(p[0], p[1])).toList(),
        <EraseDisc>[const EraseDisc(Offset(1.5, 0), 1.0)],
      );
      expect(parts, hasLength(1));
      expect(parts.first.first.dx, 3.0);
    });

    test('empty discs returns the whole polyline untouched', () {
      final List<Offset> pts =
          line.map((List<double> p) => Offset(p[0], p[1])).toList();
      expect(splitPolyline(pts, const <EraseDisc>[]), hasLength(1));
    });

    test('no discs and too few points yields no fragments', () {
      expect(
        splitPolyline(<Offset>[const Offset(0, 0)], const <EraseDisc>[]),
        isEmpty,
      );
    });
  });

  group('subtractDiscsFromBox', () {
    test('a disc centred inside the box clears it', () {
      expect(
        subtractDiscsFromBox(<double>[0, 0, 100, 100],
            <EraseDisc>[const EraseDisc(Offset(50, 50), 2)]),
        BoxErase.cleared,
      );
    });

    test('a small disc clipping an edge leaves the box alone', () {
      expect(
        subtractDiscsFromBox(<double>[0, 0, 100, 100],
            <EraseDisc>[const EraseDisc(Offset(-3, 50), 2)]),
        BoxErase.untouched,
      );
    });

    test('a disc big enough to swallow the box clears it', () {
      expect(
        subtractDiscsFromBox(<double>[40, 40, 60, 60],
            <EraseDisc>[const EraseDisc(Offset(-100, -100), 500)]),
        BoxErase.cleared,
      );
    });

    test('a malformed bbox is never cleared', () {
      expect(
        subtractDiscsFromBox(<double>[0, 0],
            <EraseDisc>[const EraseDisc(Offset(0, 0), 100)]),
        BoxErase.untouched,
      );
    });
  });

  group('polylineBounds', () {
    test('returns min/max on both axes plus padding', () {
      expect(
        polylineBounds(<Offset>[
          const Offset(3, 9),
          const Offset(-1, 4),
          const Offset(7, -2),
        ], padding: 1),
        <double>[-2, -3, 8, 10],
      );
    });

    test('empty input is the degenerate origin box', () {
      expect(polylineBounds(const <Offset>[]), <double>[0, 0, 0, 0]);
    });
  });

  group('StrokeEraser — brush mode splits strokes', () {
    const StrokeEraser eraser = StrokeEraser();

    test('a mid-stroke disc produces two ADD_STROKE fragments', () {
      final EraseOutcome out = eraser.apply(
        stroke(line),
        <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1.0)],
        elementMode: false,
      );
      expect(out.removed, isTrue, reason: 'the original node is replaced');
      expect(out.fragments, hasLength(2));
      expect(out.fragments[0].first, <double>[0, 0]);
      expect(out.fragments[1].last, <double>[9, 0]);
    });

    test('a disc missing the stroke is untouched (no RPCs emitted)', () {
      final EraseOutcome out = eraser.apply(
        stroke(line),
        <EraseDisc>[const EraseDisc(Offset(4.5, 500), 1.0)],
        elementMode: false,
      );
      expect(out.changesAnything, isFalse);
    });

    test('erasing nearly everything removes the node outright', () {
      final EraseOutcome out = eraser.apply(
        stroke(line),
        <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1000)],
        elementMode: false,
      );
      expect(out.removed, isTrue);
      expect(out.fragments, isEmpty);
    });

    test('LINE and HIGHLIGHT split like strokes', () {
      for (final String kind in <String>['LINE', 'HIGHLIGHT']) {
        final EraseOutcome out = eraser.apply(
          stroke(line, kind: kind),
          <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1.0)],
          elementMode: false,
        );
        expect(out.fragments, hasLength(2), reason: kind);
      }
    });

    test('a shape is cleared only when the disc lands on it', () {
      expect(
        eraser
            .apply(box('RECT'),
                <EraseDisc>[const EraseDisc(Offset(50, 50), 3)],
                elementMode: false)
            .removed,
        isTrue,
      );
      expect(
        eraser
            .apply(box('RECT'),
                <EraseDisc>[const EraseDisc(Offset(-50, 50), 3)],
                elementMode: false)
            .removed,
        isFalse,
      );
    });

    test('an IMAGE is never split — it is cleared or untouched', () {
      final CanvasNodeModel image = CanvasNodeModel(
        nodeId: 'i1',
        kind: 'IMAGE',
        layer: 0,
        bbox: <double>[0, 0, 50, 50],
        style: box('RECT').style,
        geometry: NodeGeometryModel(pts: <List<double>>[], assetRef: 'assets/a.png'),
      );
      final EraseOutcome out = eraser.apply(
        image,
        <EraseDisc>[const EraseDisc(Offset(25, 25), 2)],
        elementMode: false,
      );
      expect(out.removed, isTrue);
      expect(out.fragments, isEmpty);
    });
  });

  group('StrokeEraser — element mode keeps the old delete', () {
    const StrokeEraser eraser = StrokeEraser();

    test('any contact deletes the whole stroke, no fragments', () {
      final EraseOutcome out = eraser.apply(
        stroke(line),
        <EraseDisc>[const EraseDisc(Offset(4.5, 0), 1.0)],
        elementMode: true,
      );
      expect(out.removed, isTrue);
      expect(out.fragments, isEmpty,
          reason: 'element mode must never split');
    });

    test('a miss still changes nothing', () {
      expect(
        eraser
            .apply(stroke(line),
                <EraseDisc>[const EraseDisc(Offset(4.5, 900), 1.0)],
                elementMode: true)
            .changesAnything,
        isFalse,
      );
    });
  });
}
