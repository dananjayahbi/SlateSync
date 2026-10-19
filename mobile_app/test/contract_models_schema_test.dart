/// Round-6 cross-artifact contract test (TEST 2) — `CanvasDocumentModel`
/// ⇄ `shared_specs/canvas_document_schema.json`:
///
///  * A fully-populated document (every element kind: STROKE, HIGHLIGHT,
///    LINE, SHAPE, GRAPH_AXES with graph_config, IMAGE with asset_ref; every
///    artboard preset incl. INFINITE null dims) → `toJson()` → deep key-set
///    equality against the schema's `properties`/`$defs` nodes (Artboard,
///    ContentBounds, NodeStyle, NodeGeometry, Element + the document root).
///  * Required keys present; `toJson()` introduces NO key absent from the
///    schema (extra keys rejected by the exact key-set match).
///  * Snake_case wire keys; enum values (preset/kind/shape_type/background/
///    blend) ⊆ schema enums; bbox length 4; INFINITE ⇒ width/height null +
///    is_infinite true.
///
/// Pure Dart — reads the schema file via `File` after locating the repo root
/// by walking upward from `Directory.current`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

const String _specsDirName = 'shared_specs';

/// Robust upward search for `shared_specs/` starting at `Directory.current`.
Directory _findRepoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 12; i++) {
    final String sep = Platform.pathSeparator;
    if (Directory('${dir.path}$sep$_specsDirName').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'shared_specs/ not found above ${Directory.current.path}',
  );
}

final Directory _root = _findRepoRoot();

Map<String, dynamic> _loadSchema() => jsonDecode(
      File(
        '${_root.path}${Platform.pathSeparator}$_specsDirName'
        '${Platform.pathSeparator}canvas_document_schema.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;

final RegExp _snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');
final RegExp _hexColor = RegExp(r'^#[0-9A-Fa-f]{6}$');
final RegExp _assetRef = RegExp(r'^assets/');

/// Deep key-set equality: [actual] must emit exactly the keys declared in
/// the schema node's `properties`, and every `required` key must be present.
void expectKeySet(
  Map<String, dynamic> actual,
  Map<String, dynamic> schemaNode,
  String label,
) {
  final Map<String, dynamic> props =
      Map<String, dynamic>.from(schemaNode['properties'] as Map? ?? const {});
  expect(actual.keys.toSet(), props.keys.toSet(),
      reason: '$label key set must equal schema properties '
          '(actual=${actual.keys.toList()..sort()} '
          'expected=${props.keys.toList()..sort()})');
  final List<String> required =
      ((schemaNode['required'] as List?) ?? const []).cast<String>();
  for (final String key in required) {
    expect(actual.containsKey(key), isTrue,
        reason: '$label is missing required key "$key"');
  }
  for (final String key in actual.keys) {
    expect(_snakeCase.hasMatch(key), isTrue,
        reason: '$label key "$key" is not snake_case');
  }
}

void expectEnumValue(
  Object? value,
  Map<String, dynamic> schemaNode,
  String label,
) {
  expect(schemaNode.containsKey('enum'), isTrue,
      reason: '$label schema node must declare an enum');
  final List<dynamic> allowed = schemaNode['enum'] as List<dynamic>;
  expect(allowed.contains(value), isTrue,
      reason: '$label value "$value" not in enum $allowed');
}

CanvasNodeModel _node({
  required String kind,
  required List<double> bbox,
  required List<List<double>> pts,
  String? shapeType,
  Map<String, dynamic>? graphConfig,
  String? assetRef,
  String blendMode = 'SRC_OVER',
  int layer = 0,
}) =>
    CanvasNodeModel(
      nodeId: 'node-$kind-${layer}x',
      kind: kind,
      layer: layer,
      bbox: bbox,
      style: NodeStyleModel(
        color: '#1A2B3C',
        strokeWidth: 4.5,
        opacity: 0.75,
        blendMode: blendMode,
      ),
      geometry: NodeGeometryModel(
        pts: pts,
        shapeType: shapeType,
        graphConfig: graphConfig,
        assetRef: assetRef,
      ),
    );

/// One element of every schema kind — GRAPH_AXES carries a fully-populated
/// `graph_config`, IMAGE carries `asset_ref` with empty `pts`.
List<CanvasNodeModel> _allKindElements() => <CanvasNodeModel>[
      _node(
        kind: 'STROKE',
        bbox: <double>[0.0, 0.0, 20.0, 10.0],
        pts: <List<double>>[
          <double>[0.0, 0.0],
          <double>[10.0, 10.0],
          <double>[20.0, 5.0],
        ],
      ),
      _node(
        kind: 'HIGHLIGHT',
        bbox: <double>[5.0, 5.0, 45.0, 15.0],
        pts: <List<double>>[
          <double>[5.0, 5.0],
          <double>[45.0, 15.0],
        ],
        blendMode: 'MULTIPLY',
        layer: 1,
      ),
      _node(
        kind: 'LINE',
        bbox: <double>[1.0, 2.0, 30.0, 40.0],
        pts: <List<double>>[
          <double>[1.0, 2.0],
          <double>[30.0, 40.0],
        ],
        layer: 2,
      ),
      _node(
        kind: 'SHAPE',
        bbox: <double>[50.0, 50.0, 90.0, 80.0],
        pts: <List<double>>[
          <double>[50.0, 50.0],
          <double>[90.0, 50.0],
          <double>[90.0, 80.0],
          <double>[50.0, 80.0],
        ],
        shapeType: 'RECT',
        layer: 3,
      ),
      _node(
        kind: 'GRAPH_AXES',
        bbox: <double>[-100.0, -60.0, 150.0, 90.0],
        pts: <List<double>>[
          <double>[0.0, 0.0],
        ],
        shapeType: 'CARTESIAN_2D',
        graphConfig: <String, dynamic>{
          'origin': <double>[0.0, 0.0],
          'x_range': <double>[-4.0, 6.0],
          'y_range': <double>[-3.0, 3.6],
          'grid_step': 25.0,
          'show_labels': true,
        },
        layer: 4,
      ),
      _node(
        kind: 'IMAGE',
        bbox: <double>[10.0, 10.0, 110.0, 80.0],
        pts: <List<double>>[],
        assetRef: 'assets/img_9921.png',
        layer: 5,
      ),
    ];

void main() {
  final Map<String, dynamic> schema = _loadSchema();
  final Map<String, dynamic> defs =
      Map<String, dynamic>.from(schema[r'$defs'] as Map);
  final Map<String, dynamic> rootProps =
      Map<String, dynamic>.from(schema['properties'] as Map);
  final Map<String, dynamic> xPresets =
      Map<String, dynamic>.from(schema['x_presets'] as Map);

  /// Runs the full deep key-set + enum + shape contract over one document.
  void verifyDocument(Map<String, dynamic> body, String label) {
    // --- document root -----------------------------------------------------
    expectKeySet(body, schema, label);
    expect(body['canvas_id'], isA<String>());
    expect(body['title'], isA<String>());
    expect(body['created_at'], isA<int>());
    expect(body['updated_at'], isA<int>());
    expect(body['elements'], isA<List<dynamic>>());
    expect(rootProps.keys.toSet(), body.keys.toSet(),
        reason: '$label root keys');

    // --- artboard ----------------------------------------------------------
    final Map<String, dynamic> artboard =
        Map<String, dynamic>.from(body['artboard'] as Map);
    final Map<String, dynamic> artboardDef =
        Map<String, dynamic>.from(defs['Artboard'] as Map);
    expectKeySet(artboard, artboardDef, '$label.artboard');
    expectEnumValue(artboard['preset'], artboardDef['properties']['preset'],
        '$label.artboard.preset');
    expectEnumValue(
        artboard['background_style'],
        artboardDef['properties']['background_style'],
        '$label.artboard.background_style');
    expect(
      _hexColor.hasMatch(artboard['background_color'] as String),
      isTrue,
      reason: '$label.artboard.background_color must match ^#[0-9A-Fa-f]{6}\$',
    );

    // --- presets: dims from x_presets, INFINITE ⇒ null dims ---------------
    final String preset = artboard['preset'] as String;
    final Map<String, dynamic> dims =
        Map<String, dynamic>.from(xPresets[preset] as Map);
    if (preset == 'INFINITE') {
      expect(artboard['width'], isNull, reason: '$label INFINITE width');
      expect(artboard['height'], isNull, reason: '$label INFINITE height');
      expect(artboard['is_infinite'], isTrue);
      expect(dims['width'], isNull);
      expect(dims['height'], isNull);
    } else {
      expect(artboard['width'], dims['width'],
          reason: '$label $preset width must match x_presets');
      expect(artboard['height'], dims['height'],
          reason: '$label $preset height must match x_presets');
      expect(artboard['is_infinite'], isFalse);
    }

    // --- content bounds ----------------------------------------------------
    final Map<String, dynamic> bounds =
        Map<String, dynamic>.from(body['content_bounds'] as Map);
    expectKeySet(
        bounds, Map<String, dynamic>.from(defs['ContentBounds'] as Map),
        '$label.content_bounds');
    for (final String key in <String>['min_x', 'min_y', 'max_x', 'max_y']) {
      expect(bounds[key], isA<double>(),
          reason: '$label.content_bounds.$key must be a JSON number');
    }

    // --- elements ----------------------------------------------------------
    final List<dynamic> elements = body['elements'] as List<dynamic>;
    expect(elements, isNotEmpty, reason: '$label must carry all element kinds');
    final Map<String, dynamic> elementDef =
        Map<String, dynamic>.from(defs['Element'] as Map);
    final Map<String, dynamic> styleDef =
        Map<String, dynamic>.from(defs['NodeStyle'] as Map);
    final Map<String, dynamic> geometryDef =
        Map<String, dynamic>.from(defs['NodeGeometry'] as Map);
    final List<String> elementRequired =
        (elementDef['required'] as List).cast<String>();
    final Set<String> seenKinds = <String>{};

    for (final dynamic elementRaw in elements) {
      final Map<String, dynamic> element =
          Map<String, dynamic>.from(elementRaw as Map);
      final String kind = element['kind'] as String? ?? '<missing>';
      expectKeySet(element, elementDef, '$label.element[$kind]');
      expectEnumValue(element['kind'], elementDef['properties']['kind'],
          '$label.element[$kind].kind');
      seenKinds.add(kind);
      expect(element['layer'], isA<int>());

      // bbox: exactly 4 world-unit numbers.
      final List<dynamic> bbox = element['bbox'] as List<dynamic>;
      expect(bbox.length, 4,
          reason: '$label.element[$kind].bbox must be [min_x,min_y,'
              'max_x,max_y]');
      expect(schema['\$defs']['Element']['properties']['bbox']['minItems'], 4);
      for (final dynamic v in bbox) {
        expect(v, isA<double>(), reason: '$label.element[$kind].bbox nums');
      }

      // style
      final Map<String, dynamic> style =
          Map<String, dynamic>.from(element['style'] as Map);
      expectKeySet(style, styleDef, '$label.element[$kind].style');
      expect(
        _hexColor.hasMatch(style['color'] as String),
        isTrue,
        reason: '$label.element[$kind].style.color pattern',
      );
      expect(style['stroke_width'], isA<double>());
      expect(style['opacity'], isA<double>());
      expectEnumValue(style['blend_mode'], styleDef['properties']['blend_mode'],
          '$label.element[$kind].style.blend_mode');

      // geometry
      final Map<String, dynamic> geometry =
          Map<String, dynamic>.from(element['geometry'] as Map);
      expectKeySet(geometry, geometryDef, '$label.element[$kind].geometry');
      expectEnumValue(geometry['shape_type'],
          geometryDef['properties']['shape_type'],
          '$label.element[$kind].geometry.shape_type');
      final List<dynamic> pts = geometry['pts'] as List<dynamic>;
      if (kind == 'IMAGE') {
        expect(pts, isEmpty, reason: '$label IMAGE pts must be empty');
      }
      for (final dynamic pair in pts) {
        expect(pair, isA<List<dynamic>>());
        final List<dynamic> coords = pair as List<dynamic>;
        expect(coords.length, 2,
            reason: '$label.element[$kind].geometry.pts pairs are [x,y]');
        for (final dynamic c in coords) {
          expect(c, isA<double>());
        }
      }

      final Object? graphConfig = geometry['graph_config'];
      final Object? assetRef = geometry['asset_ref'];
      if (kind == 'GRAPH_AXES') {
        expect(graphConfig, isA<Map<dynamic, dynamic>>(),
            reason: '$label GRAPH_AXES requires graph_config');
        final Map<String, dynamic> gc = Map<String, dynamic>.from(
            graphConfig as Map);
        expectKeySet(gc, geometryDef['properties']['graph_config'] as Map<String, dynamic>,
            '$label.element[$kind].geometry.graph_config');
        expect(gc['show_labels'], isA<bool>());
        expect(gc['grid_step'], isA<double>());
      } else {
        expect(graphConfig, isNull,
            reason: '$label $kind must not carry graph_config');
      }
      if (kind == 'IMAGE') {
        expect(assetRef, isA<String>(),
            reason: '$label IMAGE requires asset_ref');
        expect(_assetRef.hasMatch(assetRef as String), isTrue,
            reason: '$label asset_ref must match ^assets/');
      } else {
        expect(assetRef, isNull,
            reason: '$label $kind must not carry asset_ref');
      }
      expect(elementRequired, containsAll(<String>[
        'node_id',
        'kind',
        'layer',
        'bbox',
        'style',
        'geometry',
      ]));
    }

    // Every schema kind appears in the fully-populated fixture document.
    expect(
      seenKinds,
      equals((elementDef['properties']['kind']['enum'] as List).toSet()),
      reason: '$label must exercise every element kind',
    );
  }

  group('TEST 2 canvas_document_schema.json ⇄ CanvasDocumentModel.toJson', () {
    test('fully-populated document satisfies the schema key sets', () {
      final CanvasDocumentModel doc = CanvasDocumentModel(
        canvasId: '11111111-2222-4333-8444-555555555555',
        title: 'Contract Fixture ✨ 控制论',
        createdAt: 1760760000,
        updatedAt: 1760763600,
        artboard: Artboard(
          preset: 'A4',
          width: 2480.0,
          height: 3508.0,
          isInfinite: false,
          backgroundStyle: 'RULED',
          backgroundColor: '#FFFFFF',
        ),
        contentBounds: <String, double>{
          'min_x': -100.0,
          'min_y': -60.0,
          'max_x': 150.0,
          'max_y': 90.0,
        },
        elements: _allKindElements(),
      );
      verifyDocument(doc.toJson(), 'A4-doc');
    });

    test('every artboard preset (incl. INFINITE) round-trips its key set', () {
      final List<String> presets =
          (defs['Artboard']['properties']['preset']['enum'] as List)
              .cast<String>();
      final List<String> backgrounds = (defs['Artboard']
              ['properties']['background_style']['enum'] as List)
          .cast<String>();
      expect(presets.toSet(), equals(<String>{'A5', 'A4', 'LETTER', 'INFINITE'}),
          reason: 'schema preset enum must cover all four artboards');

      for (int i = 0; i < presets.length; i++) {
        final String preset = presets[i];
        final Map<String, dynamic> dims =
            Map<String, dynamic>.from(xPresets[preset] as Map);
        final CanvasDocumentModel doc = CanvasDocumentModel(
          canvasId: 'preset-$preset-0000-4000-8000-000000000000',
          title: 'Preset $preset',
          createdAt: 1760760000,
          updatedAt: 1760763600,
          artboard: Artboard(
            preset: preset,
            width: (dims['width'] as num?)?.toDouble(),
            height: (dims['height'] as num?)?.toDouble(),
            isInfinite: preset == 'INFINITE',
            backgroundStyle: backgrounds[i % backgrounds.length],
            backgroundColor: '#F4F4F4',
          ),
          contentBounds: <String, double>{
            'min_x': 0.0,
            'min_y': 0.0,
            'max_x': 0.0,
            'max_y': 0.0,
          },
          elements: _allKindElements(),
        );
        final Map<String, dynamic> body = doc.toJson();
        verifyDocument(body, 'preset-$preset');

        final Map<String, dynamic> artboard =
            Map<String, dynamic>.from(body['artboard'] as Map);
        expect(artboard.keys.toSet(),
            (defs['Artboard']['properties'] as Map).keys.toSet(),
            reason: '$preset artboard key set');
        if (preset == 'INFINITE') {
          expect(artboard['width'], isNull);
          expect(artboard['height'], isNull);
          expect(artboard['is_infinite'], isTrue);
        }
      }
    });

    test('toJson introduces no key absent from the schema (deep)', () {
      // Explicit rejection pass: walk the whole tree and prove every key of
      // every nested object is declared by the corresponding schema node.
      final CanvasDocumentModel doc = CanvasDocumentModel(
        canvasId: 'deep-key-check',
        title: 'deep',
        createdAt: 1,
        updatedAt: 2,
        artboard: Artboard.infinite(),
        contentBounds: <String, double>{
          'min_x': 0.0,
          'min_y': 0.0,
          'max_x': 0.0,
          'max_y': 0.0,
        },
        elements: _allKindElements(),
      );
      final Map<String, dynamic> body = doc.toJson();

      void walk(Object? node, Map<String, dynamic> schemaNode, String path) {
        if (node is! Map) return;
        // Resolve any $ref chain so `properties` is always concrete.
        Map<String, dynamic> resolved = schemaNode;
        while (resolved[r'$ref'] is String) {
          final String ref = resolved[r'$ref'] as String;
          resolved = ref
              .split('/')
              .where((String part) => part.isNotEmpty && part != '#')
              .fold<dynamic>(
                schema,
                (dynamic cur, String part) => (cur as Map)[part],
              ) as Map<String, dynamic>;
        }
        final Map<String, dynamic> props =
            Map<String, dynamic>.from(resolved['properties'] as Map? ?? const {});
        for (final dynamic key in node.keys) {
          expect(props.containsKey(key as String), isTrue,
              reason: '$path emits undeclared key "$key"');
        }
        for (final MapEntry<dynamic, dynamic> e in node.entries) {
          final Object? value = e.value;
          final Object? childSchemaRaw = props[e.key];
          if (childSchemaRaw is! Map) continue;
          final Map<String, dynamic> childSchema =
              Map<String, dynamic>.from(childSchemaRaw);
          if (value is Map) {
            walk(value, childSchema, '$path.${e.key}');
          } else if (value is List) {
            final Object? items = childSchema['items'];
            if (items is! Map) continue;
            int i = 0;
            for (final dynamic item in value) {
              walk(item, Map<String, dynamic>.from(items), '$path.${e.key}[$i]');
              i++;
            }
          }
        }
      }

      walk(body, schema, r'$');
    });

    test('INFINITE artboard serializes null dims + is_infinite true', () {
      final CanvasDocumentModel doc = CanvasDocumentModel(
        canvasId: 'infinite-check',
        title: 'infinite',
        createdAt: 1,
        updatedAt: 2,
        artboard: Artboard.infinite(),
        contentBounds: <String, double>{
          'min_x': 0.0,
          'min_y': 0.0,
          'max_x': 0.0,
          'max_y': 0.0,
        },
        elements: <CanvasNodeModel>[],
      );
      final Map<String, dynamic> artboard =
          Map<String, dynamic>.from(doc.toJson()['artboard'] as Map);
      expect(artboard['preset'], 'INFINITE');
      expect(artboard['width'], isNull);
      expect(artboard['height'], isNull);
      expect(artboard['is_infinite'], isTrue);
    });
  });
}
