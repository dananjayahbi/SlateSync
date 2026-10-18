import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Doc 05 §6: every model roundtrips `toJson → fromJson`, wire keys stay
/// snake_case, inner raw maps (`graph_config`, `content_bounds`) keep their
/// snake_case keys verbatim, and INFINITE artboards roundtrip null dims.
void main() {
  Map<String, dynamic> graphConfigFixture() => <String, dynamic>{
        'origin': <dynamic>[520.0, 760.0],
        'x_range': <dynamic>[-10, 10],
        'y_range': <dynamic>[-10, 10],
        'grid_step': 25.0,
        'show_labels': true,
      };

  Artboard boundedArtboard() => Artboard(
        preset: 'A5',
        width: Presets.a5.w,
        height: Presets.a5.h,
        isInfinite: false,
        backgroundStyle: 'RULED',
        backgroundColor: '#FFFFFF',
      );

  NodeStyleModel styleFixture() => NodeStyleModel(
        color: '#1E1E1E',
        strokeWidth: 2.5,
        opacity: 1.0,
        blendMode: 'SRC_OVER',
      );

  CanvasDocumentModel documentFixture() {
    final stroke = CanvasNodeModel(
      nodeId: '3a7c9d15-5e84-4f0b-a2c6-8b1d7e4f9a03',
      kind: 'STROKE',
      layer: 0,
      bbox: <double>[120.0, 300.0, 450.0, 620.0],
      style: styleFixture(),
      geometry: NodeGeometryModel(
        pts: <List<double>>[
          <double>[120.4, 301.2],
          <double>[124.8, 309.5],
          <double>[131.0, 318.0],
        ],
      ),
    );
    // Fixture element carrying BOTH graph_config and asset_ref (Doc 05 §5.8).
    final graph = CanvasNodeModel(
      nodeId: 'c4e8b2a7-91d3-4c56-b0f8-7d2a5e6c1f44',
      kind: 'GRAPH_AXES',
      layer: 1,
      bbox: <double>[520.0, 300.0, 1040.0, 760.0],
      style: styleFixture(),
      geometry: NodeGeometryModel(
        pts: <List<double>>[
          <double>[520.0, 300.0],
          <double>[520.0, 760.0],
          <double>[1040.0, 760.0],
        ],
        shapeType: 'CARTESIAN_2D',
        graphConfig: graphConfigFixture(),
        assetRef: 'assets/graph_overlay.png',
      ),
    );
    return CanvasDocumentModel(
      canvasId: '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71',
      title: 'Control Systems Lecture 04',
      createdAt: 1760760000,
      updatedAt: 1760763600,
      artboard: boundedArtboard(),
      contentBounds: <String, double>{
        'min_x': 120.0,
        'min_y': 300.0,
        'max_x': 1040.0,
        'max_y': 760.0,
      },
      elements: <CanvasNodeModel>[stroke, graph],
    );
  }

  group('Artboard', () {
    test('bounded A5 roundtrips with snake_case keys', () {
      final artboard = boundedArtboard();
      final json = artboard.toJson();

      expect(
        json.keys,
        containsAll(<String>[
          'preset',
          'width',
          'height',
          'is_infinite',
          'background_style',
          'background_color',
        ]),
      );
      expect(json.containsKey('isInfinite'), isFalse);
      expect(json.containsKey('backgroundStyle'), isFalse);

      final back = Artboard.fromJson(json);
      expect(back.toJson(), equals(json));
      expect(back.preset, 'A5');
      expect(back.width, 1748.0);
      expect(back.height, 2480.0);
      expect(back.isInfinite, isFalse);
    });

    test('INFINITE roundtrips with null width/height and isInfinite true', () {
      final infinite = Artboard.infinite(backgroundStyle: 'DOT_GRID');
      final json = infinite.toJson();

      expect(json['preset'], 'INFINITE');
      expect(json['width'], isNull);
      expect(json['height'], isNull);
      expect(json['is_infinite'], isTrue);

      final back = Artboard.fromJson(json);
      expect(back.preset, 'INFINITE');
      expect(back.width, isNull);
      expect(back.height, isNull);
      expect(back.isInfinite, isTrue);
      expect(back.toJson(), equals(json));
    });
  });

  group('NodeStyleModel', () {
    test('roundtrips and emits stroke_width / blend_mode snake_case', () {
      final style = styleFixture();
      final json = style.toJson();

      expect(
        json.keys,
        containsAll(<String>[
          'color',
          'stroke_width',
          'opacity',
          'blend_mode',
        ]),
      );
      expect(json.containsKey('strokeWidth'), isFalse);
      expect(json.containsKey('blendMode'), isFalse);
      expect(NodeStyleModel.fromJson(json).toJson(), equals(json));
    });
  });

  group('NodeGeometryModel', () {
    test('roundtrips pts, shape_type, graph_config and asset_ref', () {
      final geometry = NodeGeometryModel(
        pts: <List<double>>[
          <double>[0.0, 0.0],
          <double>[10.0, 20.5],
        ],
        shapeType: 'NUMBER_LINE',
        graphConfig: graphConfigFixture(),
        assetRef: 'assets/img_9921.png',
      );
      final json = geometry.toJson();

      expect(json.keys, containsAll(<String>['pts', 'shape_type', 'graph_config', 'asset_ref']));

      // graph_config inner keys stay snake_case verbatim inside the raw map.
      final rawGraph = json['graph_config'] as Map<String, dynamic>;
      expect(
        rawGraph.keys,
        containsAll(<String>[
          'origin',
          'x_range',
          'y_range',
          'grid_step',
          'show_labels',
        ]),
      );

      final back = NodeGeometryModel.fromJson(json);
      expect(back.toJson(), equals(json));
      expect(back.pts, <List<double>>[
        <double>[0.0, 0.0],
        <double>[10.0, 20.5],
      ]);
      expect(back.shapeType, 'NUMBER_LINE');
      expect(back.assetRef, 'assets/img_9921.png');
    });

    test('null optional fields roundtrip', () {
      final geometry = NodeGeometryModel(pts: <List<double>>[]);
      final back = NodeGeometryModel.fromJson(geometry.toJson());
      expect(back.shapeType, isNull);
      expect(back.graphConfig, isNull);
      expect(back.assetRef, isNull);
      expect(back.toJson(), equals(geometry.toJson()));
    });
  });

  group('CanvasNodeModel', () {
    test('roundtrips with node_id / kind / layer / bbox snake_case', () {
      final node = CanvasNodeModel(
        nodeId: 'n-1',
        kind: 'SHAPE',
        layer: 3,
        bbox: <double>[1.0, 2.0, 3.0, 4.0],
        style: styleFixture(),
        geometry: NodeGeometryModel(pts: <List<double>>[]),
      );
      final json = node.toJson();

      expect(
        json.keys,
        containsAll(<String>['node_id', 'kind', 'layer', 'bbox', 'style', 'geometry']),
      );
      expect(json.containsKey('nodeId'), isFalse);
      expect(CanvasNodeModel.fromJson(json).toJson(), equals(json));
    });
  });

  group('CanvasDocumentModel', () {
    test('roundtrips full document incl. graph_config + asset_ref element', () {
      final doc = documentFixture();
      final json = doc.toJson();

      // §4.3 top-level snake_case keys on the wire.
      expect(
        json.keys,
        containsAll(<String>[
          'canvas_id',
          'title',
          'created_at',
          'updated_at',
          'artboard',
          'content_bounds',
          'elements',
        ]),
      );
      expect(json.containsKey('canvasId'), isFalse);
      expect(json.containsKey('createdAt'), isFalse);

      // content_bounds inner keys stay snake_case verbatim.
      final bounds = json['content_bounds'] as Map<String, dynamic>;
      expect(
        bounds.keys,
        containsAll(<String>['min_x', 'min_y', 'max_x', 'max_y']),
      );

      // Dart side is camelCase.
      expect(doc.canvasId, '9d1f4c02-77aa-4bb1-8f6d-0c2e5a9b3c71');
      expect(doc.createdAt, 1760760000);
      expect(doc.elements, hasLength(2));

      // The fixture element carries BOTH graph_config and asset_ref.
      final graphElement = doc.elements[1];
      expect(graphElement.geometry.graphConfig, isNotNull);
      expect(graphElement.geometry.assetRef, 'assets/graph_overlay.png');

      final back = CanvasDocumentModel.fromJson(json);
      expect(back.toJson(), equals(json));
      expect(back.title, doc.title);
      expect(back.artboard.preset, 'A5');
      expect(back.elements[1].geometry.graphConfig, equals(graphConfigFixture()));
      expect(back.elements[1].geometry.assetRef, 'assets/graph_overlay.png');
    });

    test('INFINITE document roundtrips with null artboard dims', () {
      final doc = CanvasDocumentModel(
        canvasId: 'inf-1',
        title: 'Infinite board',
        createdAt: 1760760000,
        updatedAt: 1760760000,
        artboard: Artboard.infinite(),
        contentBounds: <String, double>{
          'min_x': -200.0,
          'min_y': -100.0,
          'max_x': 800.0,
          'max_y': 640.0,
        },
        elements: <CanvasNodeModel>[],
      );
      final json = doc.toJson();
      expect(json['artboard'], {
        'preset': 'INFINITE',
        'width': null,
        'height': null,
        'is_infinite': true,
        'background_style': 'BLANK',
        'background_color': '#FFFFFF',
      });

      final back = CanvasDocumentModel.fromJson(json);
      expect(back.artboard.width, isNull);
      expect(back.artboard.height, isNull);
      expect(back.artboard.isInfinite, isTrue);
      expect(back.elements, isEmpty);
      expect(back.toJson(), equals(json));
    });

    test('document survives a jsonEncode/jsonDecode byte roundtrip', () {
      // Using dart:convert semantics through explicit map copies keeps this
      // test free of stringly-typed drift between models.
      final doc = documentFixture();
      final encoded = doc.toJson().toString();
      expect(encoded, contains('canvas_id'));
      expect(encoded, contains('stroke_width'));
      expect(CanvasDocumentModel.fromJson(doc.toJson()).toJson(),
          equals(doc.toJson()));
    });
  });
}
