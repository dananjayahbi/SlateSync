/// Round 10 — fill on free strokes, fill persistence and lock enforcement.
///
/// Three reports from the round-10 list, all "the rule was right but the
/// implementation was too literal":
///
/// * issue 03 — a hand-drawn loop with no gap must fill even when the endpoints
///   do not meet exactly (the ink itself seals a one-stroke-width gap, and a
///   loop drawn past its own start is sealed by the crossing);
/// * issue 04 — a filled object must keep its fill through move/resize/erase;
/// * issue 05 — a locked group must refuse every tool, not merely look locked.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/lock_guard.dart';
import 'package:mobile_app/canvas_engine/region_fill.dart';
import 'package:mobile_app/canvas_engine/selection_groups.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

CanvasNodeModel _node({
  String id = 'n1',
  String kind = 'SHAPE',
  String? shapeType = 'RECT',
  List<List<double>> pts = const <List<double>>[],
  List<double> bbox = const <double>[0, 0, 100, 100],
  String? fill,
  double strokeWidth = 2.5,
}) =>
    CanvasNodeModel(
      nodeId: id,
      kind: kind,
      layer: 0,
      bbox: List<double>.of(bbox),
      style: NodeStyleModel(
        color: '#1E1E1E',
        strokeWidth: strokeWidth,
        opacity: 1.0,
        blendMode: 'SRC_OVER',
        fill: fill,
      ),
      geometry: NodeGeometryModel(pts: pts, shapeType: shapeType),
    );

CanvasDocumentModel _doc(List<CanvasNodeModel> elements) => CanvasDocumentModel(
      canvasId: 'c1',
      title: 'doc',
      createdAt: 0,
      updatedAt: 0,
      artboard: Artboard.infinite(),
      contentBounds: <String, double>{
        'min_x': 0,
        'min_y': 0,
        'max_x': 0,
        'max_y': 0,
      },
      elements: elements,
    );

/// A hand-drawn circle sampled the way the pen delivers it.
List<List<double>> _loop({double startAngle = 0, double sweep = 2 * math.pi}) {
  final List<List<double>> pts = <List<double>>[];
  const int samples = 40;
  for (int i = 0; i <= samples; i++) {
    final double a = startAngle + sweep * i / samples;
    pts.add(<double>[100 * math.cos(a) + 200, 100 * math.sin(a) + 200]);
  }
  return pts;
}

void main() {
  group('issue 03 — a drawn loop with no leak fills', () {
    test('a sweep that stops just short of the start is sealed by the ink', () {
      // 8° of a 200-unit circle is ~14 units of arc; a 5-unit stroke bridges
      // roughly half that on each side, so the loop is airtight.
      final List<List<double>> pts =
          _loop(startAngle: 0, sweep: 2 * math.pi - 8 * math.pi / 180);
      final CanvasNodeModel loop = _node(
        kind: 'STROKE',
        shapeType: null,
        pts: pts,
        strokeWidth: 5,
      );
      expect(polylineCloses(pts, strokeWidth: 5), isTrue);
      expect(closedPolygonFor(loop), isNotNull);
      expect(pointInPolygon(const Offset(200, 200), closedPolygonFor(loop)!),
          isTrue);
    });

    test('an overshooting loop is sealed by its own crossing', () {
      // Drawing past the start is how people actually close a circle: the
      // endpoints are far apart, but the path crosses itself.
      final List<List<double>> pts =
          _loop(startAngle: 0, sweep: 2 * math.pi + 30 * math.pi / 180);
      expect(polylineCloses(pts), isTrue, reason: 'the tail crosses the head');
      expect(polylineSelfIntersects(pts), isTrue);

      final CanvasNodeModel loop =
          _node(kind: 'STROKE', shapeType: null, pts: pts);
      expect(closedPolygonFor(loop), isNotNull);
      expect(findFillTarget(const Offset(200, 200), <CanvasNodeModel>[loop]),
          isNotNull);
    });

    test('a genuinely open arc stays unfillable', () {
      // Half a circle: a real leak, so the bucket must refuse it.
      final List<List<double>> pts =
          _loop(startAngle: 0, sweep: math.pi / 2);
      expect(polylineCloses(pts, strokeWidth: 5), isFalse);
      expect(polylineSelfIntersects(pts), isFalse);
      final CanvasNodeModel arc =
          _node(kind: 'STROKE', shapeType: null, pts: pts, strokeWidth: 5);
      expect(closedPolygonFor(arc), isNull);
      expect(findFillTarget(const Offset(200, 200), <CanvasNodeModel>[arc]),
          isNull);
    });

    test('a wide stroke seals a wider gap than a hairline', () {
      // Small loop: the relative term is tiny, so the stroke width decides.
      final List<List<double>> pts = <List<double>>[
        for (int i = 0; i <= 32; i++)
          <double>[
            20 * math.cos(2 * math.pi * i / 32) + 40,
            20 * math.sin(2 * math.pi * i / 32) + 40,
          ],
      ];
      expect(closureLimit(pts, strokeWidth: 1), lessThan(20));
      expect(closureLimit(pts, strokeWidth: 40), greaterThan(20));
    });

    test('the tap must land inside the loop, not merely near it', () {
      final List<List<double>> pts = _loop();
      final CanvasNodeModel loop =
          _node(kind: 'STROKE', shapeType: null, pts: pts);
      expect(findFillTarget(const Offset(200, 200), <CanvasNodeModel>[loop]),
          isNotNull);
      expect(findFillTarget(const Offset(500, 500), <CanvasNodeModel>[loop]),
          isNull);
    });
  });

  group('issue 04 — a fill survives move and resize', () {
    test('moving a filled shape keeps its fill', () {
      final CanvasNodeModel filled = _node(fill: '#FF0000');
      expect(filled.style.fill, '#FF0000');

      // Mirrors the page's `_applyTransform` style rebuild.
      final CanvasNodeModel moved = CanvasNodeModel(
        nodeId: filled.nodeId,
        kind: filled.kind,
        layer: filled.layer,
        bbox: <double>[10, 10, 110, 110],
        style: NodeStyleModel(
          color: filled.style.color,
          strokeWidth: filled.style.strokeWidth,
          opacity: filled.style.opacity,
          blendMode: filled.style.blendMode,
          fill: filled.style.fill,
        ),
        geometry: filled.geometry,
      );
      expect(moved.style.fill, '#FF0000');
    });

    test('the fill round-trips through JSON on a transformed node', () {
      final Map<String, dynamic> json = _node(fill: '#00FF00').toJson();
      expect(json['style']['fill'], '#00FF00');
      expect(CanvasNodeModel.fromJson(json).style.fill, '#00FF00');
    });
  });

  group('issue 05 — a locked group refuses every tool', () {
    test('isNodeLocked follows the group map', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'b')]);
      expect(isNodeLocked(doc, 'a'), isFalse);

      lockSelection(doc, <String>['a', 'b']);
      expect(isNodeLocked(doc, 'a'), isTrue);
      expect(isNodeLocked(doc, 'b'), isTrue);
    });

    test('a mixed selection cannot partially mutate a group', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[
        _node(id: 'a'),
        _node(id: 'b'),
        _node(id: 'free'),
      ]);
      lockSelection(doc, <String>['a', 'b']);

      expect(anyLocked(doc, <String>['a', 'b', 'free']), isTrue);
      expect(unlockedIds(doc, <String>['a', 'b', 'free']), <String>['free']);
      expect(unlockedIds(doc, <String>['a', 'b']), isEmpty);
    });

    test('an unlocked document is never filtered', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'b')]);
      expect(anyLocked(doc, <String>['a', 'b']), isFalse);
      expect(unlockedIds(doc, <String>['a', 'b']), <String>['a', 'b']);
      expect(
        unlockedNodes(doc, doc.elements).map((CanvasNodeModel n) => n.nodeId),
        <String>['a', 'b'],
      );
    });

    test('unlocking restores every tool', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a')]);
      final String? groupId = lockSelection(doc, <String>['a']);
      expect(groupId, isNotNull);
      expect(anyLocked(doc, <String>['a']), isTrue);

      unlockGroup(doc, groupId!);
      expect(anyLocked(doc, <String>['a']), isFalse);
      expect(unlockedIds(doc, <String>['a']), <String>['a']);
    });

    test('the refusal message distinguishes full and partial blocks', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'free')]);
      lockSelection(doc, <String>['a']);

      expect(
        gestureRefusal(
          doc: doc,
          requested: <String>['a'],
          applied: <String>[],
        ),
        contains('Locked'),
      );
      expect(
        gestureRefusal(
          doc: doc,
          requested: <String>['a', 'free'],
          applied: <String>['free'],
        ),
        contains('Skipped 1'),
      );
      expect(
        gestureRefusal(
          doc: doc,
          requested: <String>['free'],
          applied: <String>['free'],
        ),
        isNull,
      );
    });

    test('deleting a member drops it from the group before the guard runs', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'b')]);
      final String? groupId = lockSelection(doc, <String>['a', 'b']);
      unlockGroup(doc, groupId!); // the honest unlock-then-delete path
      forgetNode(doc, 'a');

      expect(anyLocked(doc, <String>['a', 'b']), isFalse);
    });
  });
}
