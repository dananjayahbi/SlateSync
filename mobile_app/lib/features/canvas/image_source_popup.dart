/// Round-6 issue 05 (mobile) — canvas-tap image import: the page-owned
/// Gallery/Camera source popup, the default `image_picker` implementation,
/// and the 600-world-unit long-side planner that matches the Doc 24 dock's
/// `_defaultWorldRectPlanner` math (read-only reference).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:mobile_app/features/tools/tool_palette_dock.dart' show PickedImage;

/// `image_picker` re-exported so the canvas page (the popup's only caller)
/// never needs a direct plugin import.
export 'package:image_picker/image_picker.dart' show ImageSource;

/// Injectable picker for tests: receives the user-chosen [ImageSource] and
/// returns the picked bytes (or `null` for a cancelled pick).
typedef ImageSourcePickFn = Future<PickedImage?> Function(ImageSource source);

/// Popup offering the two import sources; `null` ⇒ cancelled (including a
/// tap outside the dialog, via the default barrier dismissal).
Future<ImageSource?> showImageSourcePopup(BuildContext context) =>
    showDialog<ImageSource>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Add image'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('image-source-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            ListTile(
              key: const ValueKey<String>('image-source-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey<String>('image-source-cancel'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

/// Doc 24 planner math (600-unit long side), anchored so the planned rect
/// is **centered** on the tap's world point [at]. Invalid intrinsic sizes
/// fall back to a 600×600 square — same as the dock default.
Rect planImageWorldRect(int widthPx, int heightPx, {Offset at = Offset.zero}) {
  const double longSide = 600.0;
  double w = longSide;
  double h = longSide;
  if (widthPx > 0 && heightPx > 0) {
    final double scale = longSide / math.max(widthPx, heightPx);
    w = widthPx * scale;
    h = heightPx * scale;
  }
  return Rect.fromCenter(center: at, width: w, height: h);
}

/// Default [ImageSourcePickFn]: `image_picker` + intrinsic decode. A plugin
/// failure or cancelled pick both surface as `null` (treated as a cancel).
Future<PickedImage?> defaultPickImageFromSource(ImageSource source) async {
  try {
    final XFile? file = await ImagePicker().pickImage(source: source);
    if (file == null) {
      return null;
    }
    final Uint8List bytes = await file.readAsBytes();
    int widthPx = 0;
    int heightPx = 0;
    try {
      final ui.Image image = await decodeImageFromList(bytes);
      widthPx = image.width;
      heightPx = image.height;
      image.dispose();
    } catch (_) {
      // Undecodable bytes: keep 0×0; the planner falls back to a square.
    }
    return PickedImage(
      bytes: bytes,
      filename: file.name,
      widthPx: widthPx,
      heightPx: heightPx,
    );
  } catch (_) {
    // Plugin unavailable or picker failed — treat as a cancelled pick.
    return null;
  }
}
