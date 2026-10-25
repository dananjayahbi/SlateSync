/// Round-13 §03 — "Save back to the library": Replace or Copy.
///
/// The sheet exists because the two outcomes are not interchangeable and one of
/// them destroys data:
///
/// * **Replace** uploads over the item the canvas came from — same `image_id`,
///   bumped `updated_at`, so the PC overwrites its file and every device's grid
///   shows the new version in place.
/// * **Copy** always mints a NEW `image_id`, leaving the original untouched —
///   the safe default, and the only option when the canvas was not built from a
///   library item at all.
///
/// Both decisions live in pure functions ([resolveSaveImageId],
/// [buildGallerySaveRequest]) so the semantics are testable without a widget,
/// and the widget is a thin sheet that asks and then calls them.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/gallery/gallery_client.dart';
import 'package:mobile_app/features/gallery/gallery_snapshot.dart';
import 'package:mobile_app/network/vector_sync_client.dart' show uuidV4;

/// What the user picked in the sheet.
enum GallerySaveChoice { replace, copy, cancel }

/// Upfront description of the save, independent of any widget.
class GallerySavePlan {
  const GallerySavePlan({
    required this.imageId,
    required this.title,
    required this.filename,
    required this.mode,
    required this.width,
    required this.height,
  });

  final String imageId;
  final String title;
  final String filename;
  final GallerySaveMode mode;
  final int width;
  final int height;
}

/// `image_id` a save must target.
///
/// Replace reuses [source]'s id — that is what makes it a replace. Copy (and
/// every save of a canvas with no library origin) takes a fresh id, so it can
/// never collide with the item it was derived from.
String resolveSaveImageId({
  required GallerySaveMode mode,
  LibraryImage? source,
  String? seedId,
}) {
  if (mode == GallerySaveMode.replace && source != null) {
    return source.imageId;
  }
  return seedId ?? uuidV4();
}

/// Title to store with a save.
///
/// Replace keeps the library item's title unless the caller renamed the canvas
/// — the image is the same picture, so its name should not silently change.
String resolveSaveTitle({
  required GallerySaveMode mode,
  LibraryImage? source,
  required String canvasTitle,
}) {
  final String canvas = sanitiseGalleryName(canvasTitle);
  if (canvas.isNotEmpty) {
    return canvas;
  }
  final String? existing = source?.title.trim();
  if (existing != null && existing.isNotEmpty) {
    return existing;
  }
  return 'Library image';
}

/// Full plan for saving [doc] into the library.
///
/// [imageId] is injectable so a test can pin it; production leaves it null and
/// gets a fresh uuid for Copy.
GallerySavePlan planGallerySave({
  required CanvasDocumentModel doc,
  required GallerySaveMode mode,
  LibraryImage? source,
  String? imageId,
  int maxSide = kGallerySnapshotMaxSide,
}) {
  final ({int width, int height}) size = gallerySnapshotSize(doc, maxSide: maxSide);
  return GallerySavePlan(
    imageId: resolveSaveImageId(mode: mode, source: source, seedId: imageId),
    title: resolveSaveTitle(
      mode: mode,
      source: source,
      canvasTitle: doc.title,
    ),
    filename: gallerySaveFilename(doc.title, doc.canvasId),
    mode: mode,
    width: size.width,
    height: size.height,
  );
}

/// The wire envelope for [plan] — a pure function, so the exact payload keys
/// stay pinned by a test rather than by a widget rebuild.
Map<String, dynamic> buildGallerySaveRequest(
  GallerySavePlan plan, {
  String? id,
  DateTime? now,
}) =>
    buildGallerySave(
      imageId: plan.imageId,
      title: plan.title,
      width: plan.width,
      height: plan.height,
      filename: plan.filename,
      mime: 'image/png',
      mode: plan.mode,
      id: id,
      now: now,
    );

/// Offers Replace / Copy and resolves to the user's choice.
///
/// Dismissal resolves to [GallerySaveChoice.cancel] — never to a destructive
/// default, because a sheet swiped away by accident must not overwrite an image.
Future<GallerySaveChoice> showSaveToGallerySheet(
  BuildContext context, {
  required LibraryImage? source,
  required String canvasTitle,
  required String sizeLabel,
}) async {
  final GallerySaveChoice? choice = await showModalBottomSheet<GallerySaveChoice>(
    context: context,
    backgroundColor: StudioTheme.surface,
    isScrollControlled: true,
    builder: (BuildContext context) => SaveToGallerySheet(
      source: source,
      canvasTitle: canvasTitle,
      sizeLabel: sizeLabel,
    ),
  );
  return choice ?? GallerySaveChoice.cancel;
}

/// The sheet body (extracted so widget tests can pump it directly).
class SaveToGallerySheet extends StatelessWidget {
  const SaveToGallerySheet({
    super.key,
    required this.source,
    required this.canvasTitle,
    required this.sizeLabel,
  });

  /// The library item this canvas came from; `null` ⇒ Copy is the only option.
  final LibraryImage? source;

  final String canvasTitle;

  /// `1920 × 1080` of what will actually be uploaded.
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final LibraryImage? origin = source;
    return SafeArea(
      child: Padding(
        key: const Key('save_to_gallery_sheet'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Save to image library',
              key: Key('save_to_gallery_title'),
              style: TextStyle(
                color: StudioTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              origin == null
                  ? '$canvasTitle · $sizeLabel · PNG'
                  : 'From “${origin.title}” · $sizeLabel · PNG',
              key: const Key('save_to_gallery_subtitle'),
              style: const TextStyle(color: StudioTheme.subText, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (origin != null)
              _ChoiceTile(
                key: const Key('save_to_gallery_replace'),
                icon: Icons.save_outlined,
                title: 'Replace',
                subtitle: 'Overwrite “${origin.title}” — its id and place in the '
                    'library stay the same.',
                destructive: true,
                onTap: () => Navigator.of(context).pop(GallerySaveChoice.replace),
              ),
            if (origin != null) const SizedBox(height: 10),
            _ChoiceTile(
              key: const Key('save_to_gallery_copy'),
              icon: Icons.copy_all_outlined,
              title: 'Copy',
              subtitle: origin == null
                  ? 'Add this canvas as a new library image.'
                  : 'Add a new library image and leave “${origin.title}” '
                      'untouched.',
              onTap: () => Navigator.of(context).pop(GallerySaveChoice.copy),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('save_to_gallery_cancel'),
                onPressed: () => Navigator.of(context).pop(GallerySaveChoice.cancel),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// Replace repaints in the danger colour: it is the one irreversible choice.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final Color tint = destructive ? StudioTheme.danger : StudioTheme.accent;
    return InkWell(
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(color: tint.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: tint, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      color: tint,
                      fontSize: StudioTheme.bodySize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: StudioTheme.subText,
                      fontSize: StudioTheme.captionSize,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
