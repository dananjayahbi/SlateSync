/// Round-9 issues 04/05/06 — unit tests for the new pure geometry modules.
///
/// These are the parts of the round-9 feature set that must be provably
/// correct on their own, because four renderers (mobile painter, PC viewport,
/// three exporters) share their results: point-in-polygon, closure detection,
/// rotation, table grids and the lock-group bookkeeping.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/edit_history.dart';
import 'package:mobile_app/canvas_engine/region_fill.dart';
import 'package:mobile_app/canvas_engine/selection_groups.dart';
import 'package:mobile_app/canvas_engine/selection_transform.dart';
import 'package:mobile_app/canvas_engine/table_geometry.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

CanvasNodeModel _node({
  String id = 'n1',
  String kind = 'SHAPE',
  String? shapeType = 'RECT',
  List<List<double>> pts = const <List<double>>[],
  List<double> bbox = const <double>[0, 0, 100, 100],
  Map<String, dynamic>? graphConfig,
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
      geometry: NodeGeometryModel(
        pts: pts,
        shapeType: shapeType,
        graphConfig: graphConfig,
      ),
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

void main() {
  group('region fill (issue 04)', () {
    test('a rectangle encloses its interior', () {
      final List<Offset>? polygon = closedPolygonFor(_node());
      expect(polygon, isNotNull);
      expect(pointInPolygon(const Offset(50, 50), polygon!), isTrue);
      expect(pointInPolygon(const Offset(150, 50), polygon), isFalse);
    });

    test('a circle uses its bbox ellipse, not its corners', () {
      final List<Offset>? polygon =
          closedPolygonFor(_node(shapeType: 'CIRCLE'));
      expect(pointInPolygon(const Offset(50, 50), polygon!), isTrue);
      expect(pointInPolygon(const Offset(4, 4), polygon), isFalse);
    });

    test('an open pen stroke encloses nothing; a closed one does', () {
      final CanvasNodeModel open = _node(
        kind: 'STROKE',
        shapeType: null,
        pts: <List<double>>[
          <double>[0, 0],
          <double>[50, 10],
          <double>[100, 0],
        ],
      );
      expect(closedPolygonFor(open), isNull);

      final CanvasNodeModel closed = _node(
        kind: 'STROKE',
        shapeType: null,
        pts: <List<double>>[
          <double>[0, 0],
          <double>[100, 0],
          <double>[100, 100],
          <double>[0, 100],
          <double>[2, 2],
        ],
      );
      expect(closedPolygonFor(closed), isNotNull);
      expect(pointInPolygon(const Offset(50, 50), closedPolygonFor(closed)!),
          isTrue);
    });

    test('images, graphs and lines are never fillable', () {
      expect(closedPolygonFor(_node(kind: 'IMAGE', shapeType: null)), isNull);
      expect(closedPolygonFor(_node(kind: 'LINE', shapeType: null)), isNull);
      expect(
        closedPolygonFor(_node(kind: 'GRAPH_AXES', shapeType: 'CARTESIAN_2D')),
        isNull,
      );
    });

    test('a nested shape wins over the shape containing it', () {
      final CanvasNodeModel outer = _node(id: 'outer', bbox: <double>[0, 0, 400, 400]);
      final CanvasNodeModel inner = _node(id: 'inner', bbox: <double>[100, 100, 150, 150]);
      final FillTarget? hit = findFillTarget(
        const Offset(120, 120),
        <CanvasNodeModel>[outer, inner],
      );
      expect(hit?.node.nodeId, 'inner');

      final FillTarget? onlyOuter = findFillTarget(
        const Offset(20, 20),
        <CanvasNodeModel>[outer, inner],
      );
      expect(onlyOuter?.node.nodeId, 'outer');
    });

    test('a tap outside every polygon resolves nothing', () {
      expect(findFillTarget(const Offset(-50, -50), <CanvasNodeModel>[_node()]),
          isNull);
    });
  });

  group('rotation (issue 05)', () {
    test('rotatePointsAround turns a square into a diamond', () {
      const Rect box = Rect.fromLTWH(0, 0, 100, 100);
      final List<List<double>> rotated =
          rotatedRectPoints(box, math.pi / 4);
      final List<double> bounds = pointsBounds(rotated);
      // A 45° rotation of a 100×100 square spans 100·√2 ≈ 141.4.
      expect(bounds[2] - bounds[0], closeTo(100 * math.sqrt2, 0.001));
      expect(bounds[3] - bounds[1], closeTo(100 * math.sqrt2, 0.001));
    });

    test('a full turn returns the original corners', () {
      final List<List<double>> pts = <List<double>>[
        <double>[0, 0],
        <double>[10, 0],
      ];
      final List<List<double>> turned =
          rotatePointsAround(pts, Offset.zero, 2 * math.pi);
      expect(turned[0][0], closeTo(0, 1e-9));
      expect(turned[1][0], closeTo(10, 1e-9));
      expect(turned[1][1], closeTo(0, 1e-9));
    });
  });

  group('lock groups (issue 05)', () {
    test('locking two nodes groups them and expands a later selection', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'b')]);
      final String? groupId =
          lockSelection(doc, <String>['a', 'b']);
      expect(groupId, isNotNull);
      expect(doc.groups[groupId], <String>['a', 'b']);
      expect(expandSelection(doc, <String>['a']), <String>{'a', 'b'});
      expect(selectionIsFullyLocked(doc, <String>['a', 'b']), isTrue);
    });

    test('unlocking frees the members and drops the group', () {
      final CanvasDocumentModel doc =
          _doc(<CanvasNodeModel>[_node(id: 'a'), _node(id: 'b')]);
      final String groupId = lockSelection(doc, <String>['a', 'b'])!;
      expect(unlockGroup(doc, groupId), <String>['a', 'b']);
      expect(doc.groups, isEmpty);
      expect(expandSelection(doc, <String>['a']), <String>{'a'});
    });

    test('deleting a member removes it from the group', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[
        _node(id: 'a'),
        _node(id: 'b'),
        _node(id: 'c'),
      ]);
      final String groupId = lockSelection(doc, <String>['a', 'b', 'c'])!;
      forgetNode(doc, 'b');
      expect(doc.groups[groupId], <String>['a', 'c']);
      forgetNode(doc, 'a');
      forgetNode(doc, 'c');
      expect(doc.groups, isEmpty);
    });

    test('re-locking a node moves it out of its previous group', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[
        _node(id: 'a'),
        _node(id: 'b'),
        _node(id: 'c'),
      ]);
      final String first = lockSelection(doc, <String>['a', 'b'])!;
      final String second = lockSelection(doc, <String>['b', 'c'])!;
      expect(doc.groups[first], <String>['a']);
      expect(doc.groups[second], <String>['b', 'c']);
      // A node can never be claimed by two groups.
      expect(doc.groupOf('b'), second);
    });
  });

  group('table grid (issue 06)', () {
    test('row/column edges and header bands line up', () {
      final TableGrid grid = tableGridOf(
        const Rect.fromLTWH(0, 0, 300, 200),
        buildTableConfig(rows: 4, cols: 3, headerRow: true, headerCol: true),
      );
      expect(grid.rowEdges.length, 5);
      expect(grid.colEdges.length, 4);
      expect(grid.rowEdges.first, 0);
      expect(grid.rowEdges.last, 200);
      expect(grid.colEdges.last, 300);
      // 5 horizontal (rows + 1) + 4 vertical (cols + 1) grid segments.
      expect(grid.lines.length, 9);
      expect(grid.headerRects.length, 2);
      // The corner cell belongs to the row band only.
      expect(grid.headerRects.first.top, 0);
      expect(grid.headerRects.first.bottom, closeTo(50, 1e-9));
      expect(grid.headerRects.last.top, closeTo(50, 1e-9));
    });

    test('a config with no header flags paints no bands', () {
      final TableGrid grid = tableGridOf(
        const Rect.fromLTWH(0, 0, 100, 100),
        buildTableConfig(rows: 2, cols: 2, headerRow: false, headerCol: false),
      );
      expect(grid.headerRects, isEmpty);
    });

    test('add row / add column grow the config without mutating the input', () {
      final Map<String, dynamic> base = buildTableConfig(rows: 3, cols: 2);
      final Map<String, dynamic> withRow = withExtraRow(base);
      final Map<String, dynamic> withCol = withExtraColumn(base);
      expect(base['rows'], 3);
      expect(withRow['rows'], 4);
      expect(withCol['cols'], 3);
    });

    test('a corrupt config is clamped instead of fatal', () {
      final TableGrid grid = tableGridOf(
        const Rect.fromLTWH(0, 0, 100, 100),
        <String, dynamic>{'rows': 0, 'cols': -5},
      );
      expect(grid.rows, kMinTableRows);
      expect(grid.cols, kMinTableCols);
    });
  });

  group('edit history (issue 03)', () {
    test('an unchanged gesture does not push an undo step', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[_node()]);
      final EditHistory history = EditHistory();
      history.record(snapshotOf(doc));
      expect(history.commit(snapshotOf(doc)), isFalse);
      expect(history.canUndo, isFalse);
    });

    test('undo restores the previous element list and redo replays it', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[_node(id: 'a')]);
      final EditHistory history = EditHistory();
      history.record(snapshotOf(doc));
      doc.elements.add(_node(id: 'b'));
      expect(history.commit(snapshotOf(doc)), isTrue);
      expect(history.undoDepth, 1);

      final CanvasSnapshot? before = history.undo(snapshotOf(doc));
      expect(before, isNotNull);
      expect(before!.nodeCount, 1);
      expect(before.buildNodes().single.nodeId, 'a');
      expect(history.canRedo, isTrue);

      final CanvasSnapshot? after = history.redo(snapshotOf(doc));
      expect(after, isNotNull);
      expect(after!.nodeCount, 2);
    });

    test('groups travel with the snapshot', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[_node(id: 'a')]);
      final EditHistory history = EditHistory();
      history.record(snapshotOf(doc));
      doc.groups['grp-1'] = <String>['a'];
      history.commit(snapshotOf(doc));
      final CanvasSnapshot restored = history.undo(snapshotOf(doc))!;
      expect(restored.groups, isEmpty);
      expect(restored.buildGroups(), isEmpty);
    });

    test('the undo stack is bounded by limit', () {
      final CanvasDocumentModel doc = _doc(<CanvasNodeModel>[]);
      final EditHistory history = EditHistory(limit: 2);
      for (int i = 0; i < 5; i++) {
        history.record(snapshotOf(doc));
        doc.elements.add(_node(id: 'n$i'));
        history.commit(snapshotOf(doc));
      }
      expect(history.undoDepth, 2);
    });
  });
}
