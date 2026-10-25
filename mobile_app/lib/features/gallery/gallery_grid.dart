/// Round-13 §03 — the library grid card and its pure layout helpers.
///
/// Cards are deliberately dumb: every decision they need (ordering, preview
/// scaling, the "no thumbnail yet" placeholder) is a function or an injected
/// value, so the grid can be pumped in a widget test without a socket or a
/// decode. The stateful part lives in `gallery_screen.dart`.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/gallery/gallery_client.dart';
import 'package:mobile_app/features/gallery/use_as_canvas.dart';
import 'package:mobile_app/features/home/thumbnail_cache.dart'; // round-12 issue 08

/// Column count for a grid of [width] logical pixels.
///
/// Fixed thresholds rather than `maxCrossAxisExtent` because the card height
/// must stay in step with the count: a library is mostly 16:9 screenshots, and
/// a card that inherits the grid's square aspect would letterbox them into
/// slivers.
int galleryGridColumns(double width) {
  if (width >= 1200) {
    return 5;
  }
  if (width >= 900) {
    return 4;
  }
  if (width >= 600) {
    return 3;
  }
  return 2;
}

/// `PASTE / DROP / CANVAS` chip label.
String gallerySourceLabel(GallerySource source) => switch (source) {
      GallerySource.paste => 'Pasted',
      GallerySource.drop => 'Dropped',
      GallerySource.canvas => 'Canvas',
    };

/// Icon for a [GallerySource] chip.
IconData gallerySourceIcon(GallerySource source) => switch (source) {
      GallerySource.paste => Icons.content_paste,
      GallerySource.drop => Icons.file_download_outlined,
      GallerySource.canvas => Icons.brush_outlined,
    };

/// One card in the library grid.
class GalleryGridCard extends StatelessWidget {
  const GalleryGridCard({
    super.key,
    required this.image,
    required this.onTap,
    required this.onUseAsCanvas,
    this.thumbnailPath,
    this.selected = false,
  });

  final LibraryImage image;

  /// Quick preview (tap on the thumbnail).
  final VoidCallback onTap;

  /// Opens the image as its own canvas.
  final VoidCallback onUseAsCanvas;

  /// Local path of the reassembled bytes, or `null` while they are still being
  /// fetched from the PC — the card shows a spinner-ish placeholder instead of a
  /// broken image box.
  final String? thumbnailPath;

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final String? path = thumbnailPath;
    return InkWell(
      key: Key('gallery_card_${image.imageId}'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: StudioTheme.surface,
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(
            color: selected
                ? StudioTheme.accent
                : StudioTheme.text.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _Thumb(image: image, path: path)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          image.title,
                          key: Key('gallery_title_${image.imageId}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: StudioTheme.text,
                            fontSize: StudioTheme.bodySize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${gallerySizeLabel(image.width, image.height)} · '
                          '${gallerySourceLabel(image.source)}',
                          key: Key('gallery_meta_${image.imageId}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: StudioTheme.subText,
                            fontSize: StudioTheme.captionSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('gallery_use_${image.imageId}'),
                    tooltip: 'Use as canvas',
                    onPressed: onUseAsCanvas,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    color: StudioTheme.accent,
                    visualDensity: VisualDensity.compact,
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

class _Thumb extends StatelessWidget {
  const _Thumb({required this.image, required this.path});

  final LibraryImage image;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final String? file = path;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(StudioTheme.radiusSmall),
      ),
      child: Container(
        color: const Color(0xFFECEEF2),
        child: file == null
            // A static placeholder, not a spinner: a library of twenty cards
            // would otherwise animate twenty progress indicators at once, and
            // an idle grid should cost no frames.
            ? const Center(
                key: Key('gallery_thumb_placeholder'),
                child: Icon(
                  Icons.image_outlined,
                  color: StudioTheme.subText,
                  size: 28,
                ),
              )
            : Image.file(
                File(file),
                // round-12 issue 08: the file is rewritten in place, so the
                // version stamp is what makes a re-decoded thumbnail appear.
                key: Key('gallery_thumb_${image.imageId}_${thumbnailVersion(file)}'),
                fit: BoxFit.contain,
                errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
                    const Center(
                  child: Icon(Icons.broken_image_outlined, color: StudioTheme.subText),
                ),
              ),
      ),
    );
  }
}

/// Quick preview dialog for one library image.
///
/// A dialog rather than a route: the preview is a glance, and keeping the grid
/// mounted underneath means dismissing it does not re-fetch the whole index.
class GalleryPreviewDialog extends StatelessWidget {
  const GalleryPreviewDialog({
    super.key,
    required this.image,
    required this.onUseAsCanvas,
    this.imagePath,
  });

  final LibraryImage image;
  final VoidCallback onUseAsCanvas;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final String? path = imagePath;
    return Dialog(
      key: const Key('gallery_preview_dialog'),
      backgroundColor: StudioTheme.surface,
      insetPadding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    image.title,
                    key: const Key('gallery_preview_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: StudioTheme.text,
                      fontSize: StudioTheme.titleSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('gallery_preview_close'),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: path == null
                  ? const SizedBox(
                      height: 180,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.contain,
                      errorBuilder: (BuildContext context, Object error, StackTrace? _) =>
                          const SizedBox(
                        height: 180,
                        child: Center(
                          child: Icon(Icons.broken_image_outlined,
                              color: StudioTheme.subText),
                        ),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${image.sizeLabel} · ${gallerySourceLabel(image.source)}',
                    key: const Key('gallery_preview_meta'),
                    style: const TextStyle(
                      color: StudioTheme.subText,
                      fontSize: StudioTheme.captionSize,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  key: const Key('gallery_preview_use'),
                  onPressed: onUseAsCanvas,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Use as canvas'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty-library body.
class GalleryEmptyState extends StatelessWidget {
  const GalleryEmptyState({super.key, this.offline = false});

  /// Distinguishes "the PC has nothing" from "we never reached the PC", which
  /// are very different problems for the user to act on.
  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('gallery_empty_state'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              offline ? Icons.wifi_off : Icons.photo_library_outlined,
              size: 48,
              color: StudioTheme.subText,
            ),
            const SizedBox(height: 12),
            Text(
              offline
                  ? 'The image library lives on your PC — connect to it first.'
                  : 'No images yet. Paste or drop an image on the PC and it '
                      'shows up here.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: StudioTheme.subText,
                fontSize: StudioTheme.bodySize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
