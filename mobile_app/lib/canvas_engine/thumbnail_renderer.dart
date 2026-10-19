import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Color, Rect;

import '../../core/models/canvas_models.dart';

/// Round-6 thumbnail contract (Doc 02 §10.6) — FROZEN public API.
///
/// Pure-function mini-renders of a canvas document: paper + page boundary +
/// strokes/shapes/graphs/images approximated. Preset badges are UI overlays
/// and are never baked here. Shape geometry is approximated for thumbnails
/// only; the normative geometry source is the PC renderer (§10.3).
Future<Uint8List> renderDocThumbnail(
  CanvasDocumentModel doc, {
  int size = 256,
}) async {
  final Rect target = _thumbRect(doc);
  final double scale =
      (size - 8) / (target.width > target.height ? target.width : target.height);
  final double dx = (size - target.width * scale) / 2;
  final double dy = (size - target.height * scale) / 2;

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.scale(1);

  // Neutral backdrop.
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFECEEF2),
  );

  ui.Offset map(dynamic wx, dynamic wy) => ui.Offset(
        dx + ((wx as double) - target.left) * scale,
        dy + ((wy as double) - target.top) * scale,
      );

  // Paper + boundary for bounded presets.
  if (!doc.artboard.isInfinite) {
    final ui.Rect page = ui.Rect.fromLTWH(
      dx + (0 - target.left) * scale,
      dy + (0 - target.top) * scale,
      (doc.artboard.width ?? 0) * scale,
      (doc.artboard.height ?? 0) * scale,
    );
    canvas.drawRect(
      page,
      ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF)
        ..style = ui.PaintingStyle.fill,
    );
    canvas.drawRect(
      page,
      ui.Paint()
        ..color = const ui.Color(0xFFC9CFDA)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  for (final CanvasNodeModel node in doc.elements) {
    final ui.Paint paint = ui.Paint()
      ..color = _hex(node.style.color, node.style.opacity)
      ..style = ui.PaintingStyle.stroke
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round
      ..strokeWidth =
          (node.style.strokeWidth * scale).clamp(1.0, 12.0).toDouble();
    final List<List<double>> pts = node.geometry.pts;
    if (pts.isEmpty) {
      continue;
    }
    switch (node.kind) {
      case 'IMAGE':
        if (pts.length >= 4) {
          final ui.Rect r = ui.Rect.fromPoints(
            map(pts[0][0], pts[0][1]),
            map(pts[3 - 1][0], pts[3 - 1][1]),
          );
          canvas.drawRect(
            r,
            ui.Paint()
              ..color = const ui.Color(0xFFB9C2CF)
              ..style = ui.PaintingStyle.fill,
          );
        }
        break;
      case 'GRAPH_AXES':
        // Approximate axis cross from graph_config when present.
        final Map<String, dynamic>? g = node.geometry.graphConfig;
        if (g != null && g['origin'] is List && (g['origin'] as List).length == 2) {
          final dynamic ox = (g['origin'] as List)[0];
          final dynamic oy = (g['origin'] as List)[1];
          final double ext = 400;
          canvas.drawLine(
            map(ox - ext, oy),
            map(ox + ext, oy),
            paint,
          );
          canvas.drawLine(
            map(ox, oy - ext),
            map(ox, oy + ext),
            paint,
          );
        }
        break;
      default:
        _drawPath(canvas, pts, map, paint, node.geometry.shapeType);
    }
  }

  final ui.Image image = await recorder
      .endRecording()
      .toImage(size, size);
  final ByteData? bytes =
      await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Writes a thumbnail PNG to [outPath] (parent dirs created); returns it.
Future<String> saveDocThumbnail(
  CanvasDocumentModel doc,
  String outPath, {
  int size = 256,
}) async {
  final Uint8List png = await renderDocThumbnail(doc, size: size);
  final File file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png, flush: true);
  return outPath;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

Rect _thumbRect(CanvasDocumentModel doc) {
  if (!doc.artboard.isInfinite &&
      (doc.artboard.width ?? 0) > 0 &&
      (doc.artboard.height ?? 0) > 0) {
    return Rect.fromLTWH(0, 0, doc.artboard.width!, doc.artboard.height!);
  }
  final Map<String, double> cb = doc.contentBounds;
  final double minX = cb['min_x'] ?? 0;
  final double minY = cb['min_y'] ?? 0;
  final double maxX = cb['max_x'] ?? 0;
  final double maxY = cb['max_y'] ?? 0;
  if (maxX > minX && maxY > minY) {
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
  return const Rect.fromLTWH(-500, -500, 1000, 1000);
}

Color _hex(String hex, double opacity) {
  String h = hex.replaceFirst('#', '');
  if (h.length == 6) {
    h = 'FF$h';
  }
  final int argb = int.tryParse(h, radix: 16) ?? 0xFF1E1E1E;
  final int a = ((argb >> 24) & 0xFF)
      .clamp(0, (255 * opacity.clamp(0.0, 1.0)).round())
      .toInt();
  return Color(a << 24 | (argb & 0xFFFFFF));
}

void _drawPath(
  ui.Canvas canvas,
  List<List<double>> pts,
  ui.Offset Function(dynamic, dynamic) map,
  ui.Paint paint,
  String? shapeType,
) {
  if (shapeType == 'CIRCLE' && pts.length >= 4) {
    // Convention-tolerant: first 4 points approximate the bounding box.
    final ui.Offset a = map(pts[0][0], pts[0][1]);
    final ui.Offset b = map(pts[2][0], pts[2][1]);
    final ui.Rect r = ui.Rect.fromPoints(a, b);
    canvas.drawOval(r, paint);
    return;
  }
  // Bézier chain detection (Doc 21 layout): n>=4 and (n-1) % 3 == 0.
  if (pts.length >= 4 && (pts.length - 1) % 3 == 0) {
    final ui.Path path = ui.Path()..moveTo(pts[0][0], pts[0][1]);
    ui.Offset p0 = map(pts[0][0], pts[0][1]);
    path.moveTo(p0.dx, p0.dy);
    for (int i = 1; i + 2 < pts.length; i += 3) {
      path.cubicTo(
        map(pts[i][0], pts[i][1]).dx,
        map(pts[i][0], pts[i][1]).dy,
        map(pts[i + 1][0], pts[i + 1][1]).dx,
        map(pts[i + 1][0], pts[i + 1][1]).dy,
        map(pts[i + 2][0], pts[i + 2][1]).dx,
        map(pts[i + 2][0], pts[i + 2][1]).dy,
      );
    }
    canvas.drawPath(path, paint);
    return;
  }
  final ui.Path path = ui.Path();
  final ui.Offset first = map(pts[0][0], pts[0][1]);
  path.moveTo(first.dx, first.dy);
  for (int i = 1; i < pts.length; i++) {
    final ui.Offset p = map(pts[i][0], pts[i][1]);
    path.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(path, paint);
}
