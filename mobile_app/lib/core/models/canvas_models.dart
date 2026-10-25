/// SlateSync shared canvas models (Doc 05) — frozen interface consumed by
/// Docs 20–27. Wire JSON keys are snake_case; Dart fields are camelCase.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Offset, Rect;

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

  /// Round-13 issue 04 — a book is a bounded multi-page canvas sized at one of
  /// [kBookPageSizes]. These are its DEFAULT page dims (A4), kept in the same
  /// record shape so every bounded code path treats a book like a page.
  static const book = (w: 2480.0, h: 3508.0);
}

/// Book preset key (bounded; never INFINITE).
const String kBookPreset = 'BOOK';

/// Page sizes a book may be created at — deliberately no `INFINITE` entry:
/// an unbounded book has no pages to turn.
const List<String> kBookPageSizes = <String>['A4', 'A5', 'LETTER'];

/// Default book page size.
const String kDefaultBookPageSize = 'A4';

/// Reserved `page_id` carrying the cover image ([BookPage]s never use it).
///
/// The cover is an ordinary IMAGE element with this page address, so it rides
/// the existing asset-embedding save path instead of needing new plumbing.
const String kBookCoverPageId = '__cover__';

/// Background styles (round-9: `DOT_GRID` / `ISO_GRID` retired in favour of
/// `SQUARE_GRID`). Legacy documents that still carry a retired style are
/// mapped to [kBackgroundBlank] by [normalizeBackgroundStyle] on load.
const String kBackgroundBlank = 'BLANK';
const String kBackgroundRuled = 'RULED';
const String kBackgroundSquareGrid = 'SQUARE_GRID';

/// The three selectable styles, in picker order.
const List<String> kBackgroundStyles = <String>[
  kBackgroundBlank,
  kBackgroundRuled,
  kBackgroundSquareGrid,
];

/// Retired Doc 03 styles (still present in pre-round-9 documents).
const List<String> kRetiredBackgroundStyles = <String>['DOT_GRID', 'ISO_GRID'];

/// Default rule gap / square side in world units (Doc 03 `background_spacing`).
const double kDefaultBackgroundSpacing = 32.0;

/// Selectable spacing steps for RULED / SQUARE_GRID (world units).
const List<double> kBackgroundSpacingPresets = <double>[8, 16, 24, 32, 48, 64, 96];

/// Maps any stored style onto one of [kBackgroundStyles].
///
/// Unknown or retired values become [kBackgroundBlank] so a round-8 document
/// ("DOT_GRID") still opens instead of failing to parse.
String normalizeBackgroundStyle(Object? value) {
  final String style = (value ?? '').toString().trim().toUpperCase();
  return kBackgroundStyles.contains(style) ? style : kBackgroundBlank;
}

/// Clamps a stored spacing into the sane range used by every renderer.
double normalizeBackgroundSpacing(Object? value) {
  if (value is num) {
    final double spacing = value.toDouble();
    if (spacing.isFinite && spacing >= 1 && spacing <= 2000) {
      return spacing;
    }
  }
  return kDefaultBackgroundSpacing;
}

/// Human-readable name for a background style key.
String backgroundLabel(Object? value) => switch (normalizeBackgroundStyle(value)) {
      kBackgroundRuled => 'Ruled',
      kBackgroundSquareGrid => 'Square grid',
      _ => 'Blank',
    };

class Artboard {
  String preset;
  double? width;
  double? height;
  bool isInfinite;
  String backgroundStyle;
  String backgroundColor;

  /// Gap between rules (RULED) or cell side (SQUARE_GRID), world units.
  double backgroundSpacing;

  Artboard({
    required this.preset,
    required this.width,
    required this.height,
    required this.isInfinite,
    required this.backgroundStyle,
    required this.backgroundColor,
    this.backgroundSpacing = kDefaultBackgroundSpacing,
  });

  /// INFINITE artboard: null dims, `is_infinite == true`.
  factory Artboard.infinite({
    String backgroundStyle = kBackgroundBlank,
    String backgroundColor = '#FFFFFF',
    double backgroundSpacing = kDefaultBackgroundSpacing,
  }) =>
      Artboard(
        preset: 'INFINITE',
        width: null,
        height: null,
        isInfinite: true,
        backgroundStyle: normalizeBackgroundStyle(backgroundStyle),
        backgroundColor: backgroundColor,
        backgroundSpacing: normalizeBackgroundSpacing(backgroundSpacing),
      );

  factory Artboard.fromJson(Map<String, dynamic> json) => Artboard(
        preset: json['preset'] as String,
        width: (json['width'] as num?)?.toDouble(),
        height: (json['height'] as num?)?.toDouble(),
        isInfinite: json['is_infinite'] as bool,
        backgroundStyle: normalizeBackgroundStyle(json['background_style']),
        backgroundColor: json['background_color'] as String,
        backgroundSpacing: normalizeBackgroundSpacing(json['background_spacing']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'preset': preset,
        'width': width,
        'height': height,
        'is_infinite': isInfinite,
        'background_style': backgroundStyle,
        'background_color': backgroundColor,
        'background_spacing': backgroundSpacing,
      };
}

class NodeStyleModel {
  String color;
  double strokeWidth;
  double opacity;
  String blendMode;

  /// Round-9 issue 04 — interior paint set by the fill tool, `null` when the
  /// node has no fill. A node with a fill paints this colour inside its
  /// outline; `stroke_width == 0` is the legacy "fill with [color]" spelling.
  String? fill;

  NodeStyleModel({
    required this.color,
    required this.strokeWidth,
    required this.opacity,
    required this.blendMode,
    this.fill,
  });

  factory NodeStyleModel.fromJson(Map<String, dynamic> json) => NodeStyleModel(
        color: json['color'] as String,
        strokeWidth: (json['stroke_width'] as num).toDouble(),
        opacity: (json['opacity'] as num).toDouble(),
        blendMode: json['blend_mode'] as String,
        fill: normalizeFill(json['fill']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'color': color,
        'stroke_width': strokeWidth,
        'opacity': opacity,
        'blend_mode': blendMode,
        if (fill != null) 'fill': fill,
      };
}

/// `#RRGGBB` fill colour, or `null` when absent/malformed (Doc 03 pattern).
String? normalizeFill(Object? value) {
  if (value is! String) {
    return null;
  }
  final String token = value.trim();
  return RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(token)
      ? token.toUpperCase()
      : null;
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

  /// Round-13 issue 04 — page address inside a BOOK.
  ///
  /// `null` means the FIRST page, which is what an element of a pre-round-13
  /// document means, so no migration is needed. Emitted only when set, so
  /// every existing document keeps its frozen key list.
  String? pageId;

  CanvasNodeModel({
    required this.nodeId,
    required this.kind,
    required this.layer,
    required this.bbox,
    required this.style,
    required this.geometry,
    this.pageId,
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
        pageId: normalizePageId(json['page_id']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'node_id': nodeId,
        'kind': kind,
        'layer': layer,
        'bbox': bbox,
        'style': style.toJson(),
        'geometry': geometry.toJson(),
        if (pageId != null) 'page_id': pageId,
      };
}

/// A trimmed, non-empty page id, or `null` (= the first page).
String? normalizePageId(Object? value) {
  if (value is! String) {
    return null;
  }
  final String token = value.trim();
  return token.isEmpty ? null : token;
}

/// One entry of a book's ordered `pages` list (round-13 issue 04).
///
/// Pure data: ordering/mutation invariants live in `BookController` so this
/// stays a faithful mirror of the wire shape (`page_id`/`index`/`title`).
class BookPageModel {
  BookPageModel({
    required this.pageId,
    required this.index,
    required this.title,
  });

  String pageId;
  int index;
  String title;

  factory BookPageModel.fromJson(Map<String, dynamic> json) => BookPageModel(
        pageId: json['page_id'] as String,
        index: json['index'] as int,
        title: json['title'] as String,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'page_id': pageId,
        'index': index,
        'title': title,
      };

  BookPageModel copyWith({String? pageId, int? index, String? title}) =>
      BookPageModel(
        pageId: pageId ?? this.pageId,
        index: index ?? this.index,
        title: title ?? this.title,
      );
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

  /// Round-9 issue 05 — locked groups, `group_id → member node_ids`.
  ///
  /// A node flag cannot express this: `NodeStyle` is frozen at
  /// `color/stroke_width/opacity/blend_mode` (Doc 03), and a group is a
  /// DOCUMENT-level relation anyway (one node may only belong to one group).
  /// A group behaves as a single object until it is unlocked: selecting any
  /// member selects the whole group and transforms apply to every member.
  Map<String, List<String>> groups;

  /// Round-13 issue 04 — ordered book pages; empty for a non-book document.
  ///
  /// Omitted from the wire when empty (never emitted as `[]`), so every
  /// pre-round-13 document round-trips byte-identically.
  List<BookPageModel> pages;

  CanvasDocumentModel({
    required this.canvasId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.artboard,
    required this.contentBounds,
    required this.elements,
    Map<String, List<String>>? groups,
    List<BookPageModel>? pages,
  })  : groups = groups ?? <String, List<String>>{},
        pages = pages ?? <BookPageModel>[];

  /// True for a multi-page book (`artboard.preset == 'BOOK'`).
  bool get isBook => artboard.preset == kBookPreset;

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
        groups: _groupsFromJson(json['groups']),
        pages: _pagesFromJson(json['pages']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'canvas_id': canvasId,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'artboard': artboard.toJson(),
        'content_bounds': contentBounds,
        'elements': elements.map((e) => e.toJson()).toList(),
        if (groups.isNotEmpty) 'groups': groups,
        if (pages.isNotEmpty)
          'pages': pages.map((p) => p.toJson()).toList(),
      };

  /// The group [nodeId] belongs to, or `null` when it is free.
  String? groupOf(String nodeId) {
    for (final MapEntry<String, List<String>> e in groups.entries) {
      if (e.value.contains(nodeId)) {
        return e.key;
      }
    }
    return null;
  }
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

/// Tolerant `pages` reader (round-13): orders by `index`, drops entries with
/// no usable id, skips the reserved cover id and reindexes densely.
///
/// A hand-edited or future document must never fail to open, and two pages
/// sharing an id would make their elements indistinguishable — so the first
/// occurrence wins rather than raising.
List<BookPageModel> _pagesFromJson(Object? value) {
  if (value is! List) {
    return <BookPageModel>[];
  }
  final List<({int index, int order, BookPageModel page})> entries =
      <({int index, int order, BookPageModel page})>[];
  final Set<String> seen = <String>{};
  for (int order = 0; order < value.length; order++) {
    final Object? raw = value[order];
    if (raw is! Map) {
      continue;
    }
    final String? pageId = normalizePageId(raw['page_id']);
    if (pageId == null || pageId == kBookCoverPageId || !seen.add(pageId)) {
      continue;
    }
    final Object? rawIndex = raw['index'];
    final int index = rawIndex is int ? rawIndex : order;
    final Object? rawTitle = raw['title'];
    entries.add((
      index: index < 0 ? 0 : index,
      order: order,
      page: BookPageModel(
        pageId: pageId,
        index: index < 0 ? 0 : index,
        title: rawTitle is String && rawTitle.isNotEmpty
            ? rawTitle
            : bookPageTitle(index),
      ),
    ));
  }
  entries.sort((a, b) {
    final int byIndex = a.index.compareTo(b.index);
    return byIndex != 0 ? byIndex : a.order.compareTo(b.order);
  });
  return <BookPageModel>[
    for (int i = 0; i < entries.length; i++)
      entries[i].page.copyWith(index: i),
  ];
}

/// `Page 1`-style default title for the page at 0-based [index].
String bookPageTitle(int index) => 'Page ${(index < 0 ? 0 : index) + 1}';

/// Tolerant `groups` reader: unknown shapes are dropped rather than fatal, so
/// a hand-edited or future document still opens.
Map<String, List<String>> _groupsFromJson(Object? value) {
  if (value is! Map) {
    return <String, List<String>>{};
  }
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final MapEntry<dynamic, dynamic> e in value.entries) {
    final String id = e.key.toString();
    final Object? members = e.value;
    if (id.isEmpty || members is! List) {
      continue;
    }
    final List<String> ids = <String>[
      for (final Object? m in members)
        if (m is String && m.isNotEmpty) m,
    ];
    if (ids.isNotEmpty) {
      out[id] = ids;
    }
  }
  return out;
}

/// Rounds the four edges of [rect] into a rotation rectangle for [angle]
/// radians around the centre (round-9 issue 05 — rotated shapes are stored as
/// a `PATH` polygon, so no renderer needs a rotation field).
List<List<double>> rotatedRectPoints(Rect rect, double angle) {
  final Offset c = rect.center;
  final double cos = math.cos(angle);
  final double sin = math.sin(angle);
  Offset rotate(Offset p) {
    final double dx = p.dx - c.dx;
    final double dy = p.dy - c.dy;
    return Offset(c.dx + dx * cos - dy * sin, c.dy + dx * sin + dy * cos);
  }

  final List<Offset> corners = <Offset>[
    rotate(rect.topLeft),
    rotate(rect.topRight),
    rotate(rect.bottomRight),
    rotate(rect.bottomLeft),
  ];
  return <List<double>>[
    for (final Offset p in corners) <double>[p.dx, p.dy],
  ];
}

/// Axis-aligned bounds of [pts] (no padding).
List<double> pointsBounds(List<List<double>> pts) {
  if (pts.isEmpty) {
    return <double>[0, 0, 0, 0];
  }
  double minX = pts.first[0];
  double minY = pts.first[1];
  double maxX = minX;
  double maxY = minY;
  for (final List<double> p in pts) {
    if (p.length < 2) {
      continue;
    }
    if (p[0] < minX) {
      minX = p[0];
    }
    if (p[1] < minY) {
      minY = p[1];
    }
    if (p[0] > maxX) {
      maxX = p[0];
    }
    if (p[1] > maxY) {
      maxY = p[1];
    }
  }
  return <double>[minX, minY, maxX, maxY];
}
