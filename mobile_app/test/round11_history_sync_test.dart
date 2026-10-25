/// Round 11 — issue 02: an undo/redo must reach the PC mirror.
///
/// The bug: undo/redo only rewrote the local document, so the tablet rewound
/// while the PC kept showing the pre-undo canvas. The frozen wire schema has
/// no document-replace action, so a history step is replayed as a minimal
/// node diff (`DELETE_NODE` for what vanished, `DELETE_NODE` + per-kind
/// `ADD_*` for what changed or appeared).
///
/// These tests pin the diff itself — the page-level plumbing only forwards it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_history_sync.dart';

CanvasNodeModel _node(
  String id, {
  String kind = 'STROKE',
  int layer = 0,
  String? fill,
  String? shapeType,
}) =>
    CanvasNodeModel(
      nodeId: id,
      kind: kind,
      layer: layer,
      bbox: <double>[0, 0, 10, 10],
      style: NodeStyleModel(
        color: '#1E1E1E',
        strokeWidth: 2.5,
        opacity: 1.0,
        blendMode: 'SRC_OVER',
        fill: fill,
      ),
      geometry: NodeGeometryModel(
        pts: <List<double>>[
          <double>[0, 0],
          <double>[10, 0],
          <double>[10, 10],
        ],
        shapeType: shapeType,
        graphConfig: null,
        assetRef: null,
      ),
    );

List<String> _actions(List<HistoryRpc> rpcs) =>
    rpcs.map((HistoryRpc r) => r.action).toList();

void main() {
  group('addActionForKind', () {
    test('maps every node kind to its frozen ADD_* action', () {
      expect(addActionForKind('STROKE'), 'ADD_STROKE');
      expect(addActionForKind('HIGHLIGHT'), 'ADD_STROKE');
      expect(addActionForKind('LINE'), 'ADD_STROKE');
      expect(addActionForKind('SHAPE'), 'ADD_SHAPE');
      expect(addActionForKind('GRAPH_AXES'), 'ADD_GRAPH');
      expect(addActionForKind('IMAGE'), 'ADD_IMAGE');
    });
  });

  group('diffNodes', () {
    test('identical documents produce no traffic', () {
      final List<CanvasNodeModel> nodes = <CanvasNodeModel>[
        _node('a'),
        _node('b', layer: 1),
      ];
      expect(diffNodes(before: nodes, after: nodes), isEmpty);
    });

    test('a redone stroke is a single ADD_STROKE', () {
      final CanvasNodeModel a = _node('a');
      final CanvasNodeModel b = _node('b', layer: 1);
      final List<HistoryRpc> rpcs = diffNodes(
        before: <CanvasNodeModel>[a],
        after: <CanvasNodeModel>[a, b],
      );
      expect(_actions(rpcs), <String>['ADD_STROKE']);
      expect(rpcs.single.payload['node_id'], 'b');
    });

    test('an undone stroke is a single DELETE_NODE', () {
      final CanvasNodeModel a = _node('a');
      final CanvasNodeModel b = _node('b', layer: 1);
      final List<HistoryRpc> rpcs = diffNodes(
        before: <CanvasNodeModel>[a, b],
        after: <CanvasNodeModel>[a],
      );
      expect(_actions(rpcs), <String>['DELETE_NODE']);
      expect(rpcs.single.payload['node_id'], 'b');
    });

    test('an undone fill re-creates the node without the fill', () {
      final CanvasNodeModel plain = _node('a');
      final CanvasNodeModel filled = _node('a', fill: '#22AA55');
      final List<HistoryRpc> rpcs = diffNodes(
        before: <CanvasNodeModel>[filled],
        after: <CanvasNodeModel>[plain],
      );
      // The frozen schema has no UPDATE_NODE: delete-then-add is the update.
      expect(_actions(rpcs), <String>['DELETE_NODE', 'ADD_STROKE']);
      expect(rpcs.first.payload['node_id'], 'a');
      expect(rpcs.last.payload['style'], isNot(containsPair('fill', '#22AA55')));
    });

    test('a SHAPE round-trips through ADD_SHAPE, not ADD_STROKE', () {
      final CanvasNodeModel shape = _node('s', kind: 'SHAPE', shapeType: 'RECT');
      final List<HistoryRpc> rpcs = diffNodes(
        before: <CanvasNodeModel>[],
        after: <CanvasNodeModel>[shape],
      );
      expect(_actions(rpcs), <String>['ADD_SHAPE']);
    });

    test('a missing baseline re-sends the whole document in layer order', () {
      final CanvasNodeModel top = _node('top', layer: 2);
      final CanvasNodeModel bottom = _node('bottom', layer: 0);
      final List<HistoryRpc> rpcs = diffNodes(
        before: null,
        after: <CanvasNodeModel>[top, bottom],
      );
      expect(rpcs.map((HistoryRpc r) => r.payload['node_id']).toList(),
          <String>['bottom', 'top']);
    });

    test('ordering is layer-sorted so the PC appends in the same order', () {
      final CanvasNodeModel a = _node('a', layer: 5);
      final CanvasNodeModel b = _node('b', layer: 1);
      final List<HistoryRpc> rpcs = diffNodes(
        before: null,
        after: <CanvasNodeModel>[a, b],
      );
      expect(rpcs.map((HistoryRpc r) => r.payload['node_id']).toList(),
          <String>['b', 'a']);
    });
  });

  group('groupsDiffer', () {
    test('equal maps compare equal regardless of key insertion order', () {
      final Map<String, List<String>> a = <String, List<String>>{
        'g2': <String>['n2'],
        'g1': <String>['n1', 'n3'],
      };
      final Map<String, List<String>> b = <String, List<String>>{
        'g1': <String>['n1', 'n3'],
        'g2': <String>['n2'],
      };
      expect(groupsDiffer(a, b), isFalse);
    });

    test('a lock or unlock is a change', () {
      final Map<String, List<String>> before = <String, List<String>>{};
      final Map<String, List<String>> after = <String, List<String>>{
        'g1': <String>['n1'],
      };
      expect(groupsDiffer(before, after), isTrue);
      expect(groupsDiffer(after, before), isTrue);
    });

    test('swapping membership is a change', () {
      final Map<String, List<String>> before = <String, List<String>>{
        'g1': <String>['n1'],
      };
      final Map<String, List<String>> after = <String, List<String>>{
        'g1': <String>['n2'],
      };
      expect(groupsDiffer(before, after), isTrue);
    });
  });
}
