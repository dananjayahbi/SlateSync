/// SlateSync shared canvas models (Doc 05) — frozen interface consumed by
/// Docs 20–27. Wire JSON keys are snake_case; Dart fields are camelCase.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Wire frame half (mirrors shared_specs/binary_stream_frame.json, Doc 02)
// ---------------------------------------------------------------------------

class FrameType {
  static const int livePoint = 0x01;
  static const int liveEnd = 0x02;
  static const int camera = 0x03;
  static const int laser = 0x04;
}

class ToolId {
  static const int pen = 0x01;
  static const int highlighter = 0x02;
  static const int eraser = 0x03;
  static const int shapePreview = 0x04;
}

class LiveFrame {
  final int frameType;
  final int toolId;
  final int seq;
  final double f1;
  final double f2;
  final double f3;

  const LiveFrame({
    required this.frameType,
    required this.toolId,
    required this.seq,
    required this.f1,
    required this.f2,
    required this.f3,
  });
}

/// 16-byte little-endian `<BBHfff` binary frame codec (Doc 02 / template §3).
class WireCodec {
  WireCodec._();

  static const int frameSize = 16;

  /// Packs a frame into 16 little-endian bytes:
  /// offset 0 u8 frameType, 1 u8 toolId, 2–3 u16 seq, 4–7 f1, 8–11 f2, 12–15 f3.
  static ByteData buildFrame({
    required int frameType,
    required int toolId,
    required int seq,
    required double f1,
    double f2 = 0,
    double f3 = 0,
  }) {
    final data = ByteData(frameSize);
    data.setUint8(0, frameType);
    data.setUint8(1, toolId);
    data.setUint16(2, seq, Endian.little);
    data.setFloat32(4, f1, Endian.little);
    data.setFloat32(8, f2, Endian.little);
    data.setFloat32(12, f3, Endian.little);
    return data;
  }

  /// Unpacks a 16-byte frame; throws [ArgumentError] on any other length.
  static LiveFrame decodeFrame(Uint8List bytes) {
    if (bytes.length != frameSize) {
      throw ArgumentError.value(
        bytes.length,
        'bytes.length',
        'Live frame must be exactly $frameSize bytes',
      );
    }
    final data = ByteData.sublistView(bytes);
    return LiveFrame(
      frameType: data.getUint8(0),
      toolId: data.getUint8(1),
      seq: data.getUint16(2, Endian.little),
      f1: data.getFloat32(4, Endian.little),
      f2: data.getFloat32(8, Endian.little),
      f3: data.getFloat32(12, Endian.little),
    );
  }
}

// ---------------------------------------------------------------------------
// Document half (mirrors shared_specs/canvas_document_schema.json, Doc 03)
// ---------------------------------------------------------------------------

/// Artboard presets in 300-DPI world units, top-left origin (0,0)→(w,h).
/// INFINITE carries null dims (see [Artboard]).
class Presets {
  Presets._();

  static const a5 = (w: 1748.0, h: 2480.0);
  static const a4 = (2480.0, 3508.0);
  static const letter = (2550.0, 3300.0);
}

class Artboard {
  String preset;
  double? width;
  double? height;
  bool isInfinite;
  String backgroundStyle;
  String backgroundColor;

  Artboard({
    required this.preset,
    required this.width,
    required this.height,
    required this.isInfinite,
    required this.backgroundStyle,
    required this.backgroundColor,
  });

  /// INFINITE artboard: null dims, `is_infinite == true`.
  factory Artboard.infinite({
    String backgroundStyle = 'BLANK',
    String backgroundColor = '#FFFFFF',
  }) =>
      Artboard(
        preset: 'INFINITE',
        width: null,
        height: null,
        isInfinite: true,
        backgroundStyle: backgroundStyle,
        backgroundColor: backgroundColor,
      );

  factory Artboard.fromJson(Map<String, dynamic> json) => Artboard(
        preset: json['preset'] as String,
        width: (json['width'] as num?)?.toDouble(),
        height: (json['height'] as num?)?.toDouble(),
        isInfinite: json['is_infinite'] as bool,
        backgroundStyle: json['background_style'] as String,
        backgroundColor: json['background_color'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'preset': preset,
        'width': width,
        'height': height,
        'is_infinite': isInfinite,
        'background_style': backgroundStyle,
        'background_color': backgroundColor,
      };
}

class NodeStyleModel {
  String color;
  double strokeWidth;
  double opacity;
  String blendMode;

  NodeStyleModel({
    required this.color,
    required this.strokeWidth,
    required this.opacity,
    required this.blendMode,
  });

  factory NodeStyleModel.fromJson(Map<String, dynamic> json) => NodeStyleModel(
        color: json['color'] as String,
        strokeWidth: (json['stroke_width'] as num).toDouble(),
        opacity: (json['opacity'] as num).toDouble(),
        blendMode: json['blend_mode'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'color': color,
        'stroke_width': strokeWidth,
        'opacity': opacity,
        'blend_mode': blendMode,
      };
}

class NodeGeometryModel {
  List<List<double>> pts;
  String? shapeType;

  /// Raw graph configuration; inner keys (`origin`, `x_range`, `y_range`,
  /// `grid_step`, `show_labels`) stay snake_case verbatim.
  Map<String, dynamic>? graphConfig;
  String? assetRef;

  NodeGeometryModel({
    required this.pts,
    this.shapeType,
    this.graphConfig,
    this.assetRef,
  });

  factory NodeGeometryModel.fromJson(Map<String, dynamic> json) =>
      NodeGeometryModel(
        pts: _pointsFromJson(json['pts'] as List<dynamic>? ?? const []),
        shapeType: json['shape_type'] as String?,
        graphConfig: json['graph_config'] == null
            ? null
            : Map<String, dynamic>.from(json['graph_config'] as Map),
        assetRef: json['asset_ref'] as String?,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pts': pts,
        'shape_type': shapeType,
        'graph_config': graphConfig,
        'asset_ref': assetRef,
      };
}

class CanvasNodeModel {
  String nodeId;
  String kind;
  int layer;
  List<double> bbox;
  NodeStyleModel style;
  NodeGeometryModel geometry;

  CanvasNodeModel({
    required this.nodeId,
    required this.kind,
    required this.layer,
    required this.bbox,
    required this.style,
    required this.geometry,
  });

  factory CanvasNodeModel.fromJson(Map<String, dynamic> json) =>
      CanvasNodeModel(
        nodeId: json['node_id'] as String,
        kind: json['kind'] as String,
        layer: json['layer'] as int,
        bbox: _doublesFromJson(json['bbox'] as List<dynamic>),
        style: NodeStyleModel.fromJson(json['style'] as Map<String, dynamic>),
        geometry: NodeGeometryModel.fromJson(
          json['geometry'] as Map<String, dynamic>,
        ),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'node_id': nodeId,
        'kind': kind,
        'layer': layer,
        'bbox': bbox,
        'style': style.toJson(),
        'geometry': geometry.toJson(),
      };
}

class CanvasDocumentModel {
  String canvasId;
  String title;
  int createdAt;
  int updatedAt;
  Artboard artboard;

  /// Union of all element bboxes; inner keys stay snake_case verbatim
  /// (`min_x`, `min_y`, `max_x`, `max_y`).
  Map<String, double> contentBounds;
  List<CanvasNodeModel> elements;

  CanvasDocumentModel({
    required this.canvasId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.artboard,
    required this.contentBounds,
    required this.elements,
  });

  factory CanvasDocumentModel.fromJson(Map<String, dynamic> json) =>
      CanvasDocumentModel(
        canvasId: json['canvas_id'] as String,
        title: json['title'] as String,
        createdAt: json['created_at'] as int,
        updatedAt: json['updated_at'] as int,
        artboard: Artboard.fromJson(json['artboard'] as Map<String, dynamic>),
        contentBounds: _boundsFromJson(
          json['content_bounds'] as Map<String, dynamic>,
        ),
        elements: (json['elements'] as List<dynamic>)
            .map((e) => CanvasNodeModel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'canvas_id': canvasId,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'artboard': artboard.toJson(),
        'content_bounds': contentBounds,
        'elements': elements.map((e) => e.toJson()).toList(),
      };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<double> _doublesFromJson(List<dynamic> values) =>
    values.map((v) => (v as num).toDouble()).toList();

List<List<double>> _pointsFromJson(List<dynamic> values) =>
    values.map((v) => _doublesFromJson(v as List<dynamic>)).toList();

Map<String, double> _boundsFromJson(Map<String, dynamic> json) =>
    <String, double>{
      'min_x': (json['min_x'] as num).toDouble(),
      'min_y': (json['min_y'] as num).toDouble(),
      'max_x': (json['max_x'] as num).toDouble(),
      'max_y': (json['max_y'] as num).toDouble(),
    };
