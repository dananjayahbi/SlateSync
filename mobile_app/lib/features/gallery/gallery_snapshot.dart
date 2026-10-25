/// Round-13 §03 — producing the bytes a "save back to the library" upload sends.
///
/// The library stores a single picture per item, so the tablet has to hand the
/// PC something a person would recognise. Two constraints decide the approach:
///
/// * **The page, not the content bounds.** The snapshot is the artboard
///   rectangle at its own pixel size, which for a gallery canvas is exactly the
///   source image's size — so annotating a 1920 × 1080 screenshot and saving it
///   back yields a 1920 × 1080 image, not a re-fitted one.
/// * **PNG, at a bounded size.** The bytes travel through the existing
///   `ASSET_*` chunked transfer, whose per-chunk cap (262144 raw bytes) makes an
///   unbounded raster a long upload; [kGallerySnapshotMaxSide] keeps a 300-DPI
///   A4 page from becoming a 60-megapixel PNG.
///
/// Fidelity is deliberately "screen quality": the normative, pixel-exact
/// renderer is the PC export path (Doc 13), and asking the tablet to reimplement
/// it would be the second renderer this codebase has spent three rounds
/// avoiding. What is drawn here is the paper, the page border and the elements
/// at their bboxes, which is what the library grid and a paste target need.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

/// Longest side of a saved snapshot, in pixels.
///
/// 4096 keeps a full A4 page (2480 × 3508) at native size while bounding a
/// pathological infinite canvas; PNG of 4096² is ≈ 4-8 MB, comfortably inside
/// the chunked transport's patience.
const int kGallerySnapshotMaxSide = 4096;

/// Pixel size of the snapshot for [doc], preserving the page aspect ratio.
({int width, int height}) gallerySnapshotSize(
  CanvasDocumentModel doc, {
  int maxSide = kGallerySnapshotMaxSide,
}) {
  final ({double w, double h}) page = _pageSize(doc);
  final double longest = math.max(page.w, page.h);
  final double scale = longest > maxSide && longest > 0 ? maxSide / longest : 1.0;
  final int width = math.max(1, (page.w * scale).round());
  final int height = math.max(1, (page.h * scale).round());
  return (width: width, height: height);
}

/// The rectangle the snapshot covers, in world units.
///
/// Bounded page ⇒ `(0,0,w,h)`. An infinite canvas has no page, so it falls back
/// to the content bounds and finally to a 1000-unit square — the same
/// degenerate-document guard the exporters use, so a blank document still
/// produces a valid (mostly white) image instead of throwing.
({double x, double y, double w, double h}) gallerySnapshotRect(
  CanvasDocumentModel doc,
) {
  if (!doc.artboard.isInfinite) {
    final double? w = doc.artboard.width;
    final double? h = doc.artboard.height;
    if (w != null && h != null && w > 0 && h > 0) {
      return (x: 0, y: 0, w: w, h: h);
    }
  }
  final Map<String, double> bounds = doc.contentBounds;
  final double minX = bounds['min_x'] ?? 0;
  final double minY = bounds['min_y'] ?? 0;
  final double maxX = bounds['max_x'] ?? 0;
  final double maxY = bounds['max_y'] ?? 0;
  if (maxX > minX && maxY > minY) {
    return (x: minX, y: minY, w: maxX - minX, h: maxY - minY);
  }
  return (x: 0, y: 0, w: 1000, h: 1000);
}

({double w, double h}) _pageSize(CanvasDocumentModel doc) {
  final ({double x, double y, double w, double h}) rect = gallerySnapshotRect(doc);
  return (w: rect.w, h: rect.h);
}

/// Paints [doc]'s page into a PNG of [gallerySnapshotSize] pixels.
///
/// [assets] supplies decoded IMAGE bytes by `asset_ref`, because a
/// `CanvasNodeModel` only carries the reference — the caller owns the cache.
/// A missing asset paints an empty box rather than failing the save: half a
/// saved canvas is recoverable, a lost one is not.
Future<Uint8List> rasteriseCanvasDocument(
  CanvasDocumentModel doc, {
  Map<String, ui.Image> assets = const <String, ui.Image>{},
  int maxSide = kGallerySnapshotMaxSide,
}) async {
  final ({int width, int height}) size = gallerySnapshotSize(doc, maxSide: maxSide);
  final ({double x, double y, double w, double h}) rect = gallerySnapshotRect(doc);
  final double scale = size.width / (rect.w <= 0 ? 1 : rect.w);

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  // Paper first: the page colour is what the user sees behind the ink, and a
  // transparent PNG would paste as a floating scribble on the PC.
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, size.width.toDouble(), size.height.toDouble()),
    ui.Paint()..color = _colour(doc.artboard.backgroundColor, 1, fallback: Colors.white),
  );
  canvas.save();
  canvas.translate(-rect.x * scale, -rect.y * scale);
  canvas.scale(scale);

  for (final CanvasNodeModel node in doc.elements) {
    try {
      _paintNode(canvas, node, assets);
    } catch (_) {
      // One unpaintable element must not lose the whole snapshot.
      continue;
    }
  }
  canvas.restore();

  final ui.Image image = await recorder.endRecording().toImage(size.width, size.height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (data == null) {
    throw StateError('The canvas could not be rasterised for the library.');
  }
  return data.buffer.asUint8List();
}

void _paintNode(ui.Canvas canvas, CanvasNodeModel node, Map<String, ui.Image> assets) {
  final List<double> bbox = node.bbox;
  if (bbox.length < 4) {
    return;
  }
  final ui.Rect box = ui.Rect.fromLTRB(bbox[0], bbox[1], bbox[2], bbox[3]);
  if (node.kind == 'IMAGE') {
    final ui.Image? asset = assets[node.geometry.assetRef];
    if (asset != null) {
      final ui.Rect src = ui.Rect.fromLTWH(
        0,
        0,
        asset.width.toDouble(),
        asset.height.toDouble(),
      );
      canvas.drawImageRect(
        asset,
        src,
        box,
        ui.Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    canvas.drawRect(box, ui.Paint()..color = const ui.Color(0xFFE3E7EE));
    return;
  }
  final Paint stroke = ui.Paint()
    ..color = _colour(node.style.color, node.style.opacity)
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.round
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeWidth = node.style.strokeWidth <= 0 ? 1 : node.style.strokeWidth;
  final String? fill = node.style.fill;
  if (fill != null && fill.isNotEmpty) {
    final ui.Path path = _pathOf(node);
    canvas.drawPath(path, ui.Paint()..color = _colour(fill, node.style.opacity));
  }
  canvas.drawPath(_pathOf(node), stroke);
}

ui.Path _pathOf(CanvasNodeModel node) {
  final List<List<double>> pts = node.geometry.pts;
  if (pts.isEmpty) {
    final List<double> bbox = node.bbox;
    if (bbox.length < 4) {
      return ui.Path();
    }
    return ui.Path()..addRect(ui.Rect.fromLTRB(bbox[0], bbox[1], bbox[2], bbox[3]));
  }
  final ui.Path path = ui.Path();
  path.moveTo(pts.first[0], pts.first[1]);
  for (int i = 1; i < pts.length; i++) {
    path.lineTo(pts[i][0], pts[i][1]);
  }
  return path;
}

/// `#RRGGBB` / `#AARRGGBB` → [Color]; unparseable values fall back.
ui.Color _colour(Object? value, double opacity, {Color fallback = Colors.black}) {
  final String text = (value ?? '').toString().trim().replaceFirst('#', '');
  int? parsed;
  if (text.length == 6) {
    parsed = int.tryParse(text, radix: 16);
    if (parsed != null) {
      return ui.Color(0xFF000000 | parsed).withValues(
        alpha: opacity.clamp(0.0, 1.0),
      );
    }
  } else if (text.length == 8) {
    parsed = int.tryParse(text, radix: 16);
    if (parsed != null) {
      return ui.Color(parsed).withValues(alpha: opacity.clamp(0.0, 1.0));
    }
  }
  return fallback.withValues(alpha: opacity.clamp(0.0, 1.0));
}

/// Deterministic file name for a canvas saved into the library.
///
/// `<sanitised title>-<canvas id prefix>.png`: stable across retries (so a
/// Replace overwrites the same PC file) and unique enough that a Copy cannot
/// collide with the item it was copied from.
String gallerySaveFilename(String title, String canvasId) {
  final String safeTitle = sanitiseGalleryName(title);
  final String stem = canvasId.length >= 8 ? canvasId.substring(0, 8) : canvasId;
  final String name = safeTitle.isEmpty ? stem : '$safeTitle-$stem';
  return '${name.isEmpty ? 'canvas' : name}.png';
}

/// Filesystem-safe version of a user title (no separators, no control chars).
String sanitiseGalleryName(String value) {
  final StringBuffer buffer = StringBuffer();
  for (final int unit in value.trim().runes) {
    final String char = String.fromCharCode(unit);
    final bool bad = unit < 0x20 || r'<>:"/\|?*'.contains(char);
    buffer.write(bad ? '-' : char);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}
