/// Round-13 §03 — "Use as canvas": turn a library image into a document.
///
/// The rule from the plan is exact, and it is the whole point of the feature:
///
/// * the artboard is the image's **exact pixel size** (no fitting, no preset
///   arithmetic), and
/// * the single element is that image at `(0,0)` covering that whole size.
///
/// Everything downstream then works unchanged — the tools, the exporters, the
/// PC mirror all treat it as an ordinary bounded canvas, and saving it back to
/// the library asks Replace or Copy (see `save_to_gallery_sheet.dart`).
///
/// The document is built by [buildNewCanvasDocument] rather than assembled by
/// hand so it inherits Doc 26's defaults verbatim (content-bounds zeros, the
/// `#FFFFFF` paper, the timestamp convention). Only the artboard is overwritten
/// afterwards, because `presetDims` deliberately knows nothing above 300-DPI
/// preset sizes and a gallery image is a device-pixel rectangle.
library;

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/features/gallery/gallery_client.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart'
    show buildNewCanvasDocument;
import 'package:mobile_app/network/vector_sync_client.dart' show uuidV4;

/// Preset marker for a canvas whose page IS an image.
///
/// Not one of the frozen presets (`A5/A4/LETTER/BOOK/INFINITE`) on purpose: a
/// screenshot is 1920 × 1080, which no paper size describes. The document's
/// `width`/`height` are authoritative — every renderer, exporter and the PC
/// store honour explicit dims for presets outside their table — so the marker
/// only needs to be *stable* and obviously not paper-sized. The studio's
/// `ArtboardManager` seeds itself from the preset table, so it has to adopt the
/// document's dims for a marker like this (same generalisation the BOOK preset
/// needs, and both land in `canvas_engine/`, which this feature does not own).
const String kGalleryArtboardPreset = 'IMAGE';

/// Seed preset used while building, immediately replaced by the real size.
///
/// `buildNewCanvasDocument` resolves dims through `presetDims`, which throws
/// for anything outside the frozen table, so the seeded A4 is a formality whose
/// dims are overwritten two lines later. A4 (rather than INFINITE) keeps the
/// seed bounded, so no intermediate object claims to be unbounded.
const String _seedPreset = 'A4';

/// Default title for a canvas created from [image].
///
/// The item's own title, because the user already named that image in the
/// library and a second invented name would be noise in the home grid.
String galleryCanvasTitle(LibraryImage image) {
  final String title = image.title.trim();
  return title.isEmpty ? 'Library image' : title;
}

/// The artboard size a gallery canvas must carry: the image's real pixels.
({double width, double height}) galleryArtboardSize(LibraryImage image) =>
    (width: image.width.toDouble(), height: image.height.toDouble());

/// A canvas document whose page is exactly [image].
///
/// [assetRef] defaults to the library item's own reference (`assets/<file>`),
/// which is the same spelling the studio's image tool produces — so the asset
/// cache, the archive writer and the PC renderer all resolve it the usual way.
CanvasDocumentModel buildCanvasFromGalleryImage({
  required LibraryImage image,
  String? canvasId,
  int? now,
  String? title,
  String? assetRef,
  String background = kBackgroundBlank,
}) {
  final CanvasDocumentModel doc = buildNewCanvasDocument(
    title: title ?? galleryCanvasTitle(image),
    preset: _seedPreset,
    background: background,
    canvasId: canvasId,
    now: now,
  );
  final ({double width, double height}) size = galleryArtboardSize(image);
  doc.artboard
    ..preset = kGalleryArtboardPreset
    ..width = size.width
    ..height = size.height
    ..isInfinite = false;
  doc.elements = <CanvasNodeModel>[buildGalleryImageNode(image: image, assetRef: assetRef)];
  doc.contentBounds = <String, double>{
    'min_x': 0,
    'min_y': 0,
    'max_x': size.width,
    'max_y': size.height,
  };
  return doc;
}

/// The one element of a gallery canvas: the image, at `(0,0)`, full size.
///
/// `pts` stays empty exactly like the studio's own image inserts; the IMAGE
/// pipeline draws from `bbox` + `geometry.asset_ref`, and a stray `pts` list
/// would make the thumbnail renderer try to draw a polygon over the bitmap.
CanvasNodeModel buildGalleryImageNode({
  required LibraryImage image,
  String? assetRef,
  String? nodeId,
  int layer = 0,
}) {
  final ({double width, double height}) size = galleryArtboardSize(image);
  return CanvasNodeModel(
    nodeId: nodeId ?? uuidV4(),
    kind: 'IMAGE',
    layer: layer,
    bbox: <double>[0, 0, size.width, size.height],
    style: NodeStyleModel(
      color: '#000000',
      strokeWidth: 0,
      opacity: 1,
      blendMode: 'NORMAL',
    ),
    geometry: NodeGeometryModel(
      pts: const <List<double>>[],
      assetRef: assetRef ?? image.assetRef,
    ),
  );
}

/// True when [doc]'s page is exactly the library image's pixel size.
///
/// Used by the UI to decide whether "save back to this image" is meaningful
/// (it is only when the aspect ratio has not been changed by an artboard
/// upgrade in the studio).
bool canvasMatchesImage(CanvasDocumentModel doc, LibraryImage image) {
  if (doc.artboard.isInfinite) {
    return false;
  }
  return doc.artboard.width == image.width.toDouble() &&
      doc.artboard.height == image.height.toDouble();
}

/// Scale factor needed to fit [image] into a preview box of [box]².
///
/// Separated out so the grid and the quick preview agree on their maths, and so
/// the "no upscaling" rule (a 40 × 40 icon stays crisp instead of blurring to
/// 200 px) is testable without a widget.
double galleryPreviewScale(int width, int height, double box) {
  final int longest = width > height ? width : height;
  if (longest <= 0 || box <= 0) {
    return 1;
  }
  final double scale = box / longest;
  return scale > 1 ? 1 : scale;
}

/// `1920 × 1080` — the caption under a gallery card.
String gallerySizeLabel(int width, int height) => '$width × $height';
