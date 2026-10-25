/// Round-13 §03 — the tablet image library screen.
///
/// The screen is a thin coordinator over three injected futures, so it can be
/// pumped in a widget test with no socket, no decode and no file system:
///
/// * [loadImages] — the current index (newest first);
/// * [loadBytes] — the local path of one item's reassembled bytes, which the PC
///   streams on demand through the existing `ASSET_*` transfer;
/// * [onUseAsCanvas] — hands the chosen image to the shell, which builds the
///   exact-pixel document and pushes the studio.
///
/// Thumbnails are fetched lazily and one at a time per card, because asking the
/// PC for 200 full-size images at once is exactly the kind of burst that makes a
/// WebSocket link feel broken.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/gallery/gallery_client.dart';
import 'package:mobile_app/features/gallery/gallery_grid.dart';

/// Signature of a library index loader.
typedef GalleryListLoader = Future<List<LibraryImage>> Function();

/// Signature of a single image's byte fetch (returns a local file path).
typedef GalleryBytesLoader = Future<String?> Function(String imageId);

/// Opens the library.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.loadImages,
    required this.loadBytes,
    required this.onUseAsCanvas,
    this.onRefresh,
  });

  /// Builds a screen backed by a live [GalleryClient].
  factory GalleryScreen.fromClient({
    Key? key,
    required GalleryClient client,
    required void Function(LibraryImage image, String path) onUseAsCanvas,
  }) =>
      GalleryScreen(
        key: key,
        loadImages: client.fetchList,
        loadBytes: client.fetchImageBytes,
        onRefresh: client.fetchList,
        onUseAsCanvas: (LibraryImage image, String? path) =>
            onUseAsCanvas(image, path ?? ''),
      );

  final GalleryListLoader loadImages;
  final GalleryBytesLoader loadBytes;

  /// The chosen image plus the local path of its bytes (empty when the fetch
  /// failed — the shell can still open the canvas and let the studio resolve the
  /// asset from the `ASSET_*` cache once it arrives).
  final void Function(LibraryImage image, String? path) onUseAsCanvas;

  /// Optional pull-to-refresh source; `null` ⇒ reuse [loadImages].
  final GalleryListLoader? onRefresh;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<LibraryImage> _images = const <LibraryImage>[];
  final Map<String, String> _paths = <String, String>{};
  final Set<String> _fetching = <String>{};
  bool _loading = true;
  bool _offline = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<LibraryImage> images = await widget.loadImages();
      if (!mounted) {
        return;
      }
      setState(() {
        _images = sortLibraryNewestFirst(images);
        _loading = false;
        _offline = false;
      });
      // Kick the first row's thumbnails; the rest follow as the user scrolls.
      for (final LibraryImage image in _images.take(8)) {
        unawaited(_ensureBytes(image.imageId));
      }
    } on GalleryRequestError catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _offline = true;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Fetches the bytes for one item, at most once per screen lifetime.
  ///
  /// A failure is remembered as an empty path so a permanently broken item does
  /// not re-request on every rebuild (the PC would log a timeout per frame).
  /// An empty cached value is therefore a *failure marker*, reported as `null`
  /// so callers cannot mistake it for a usable file name.
  Future<String?> _ensureBytes(String imageId) async {
    final String? cached = _paths[imageId];
    if (cached != null) {
      return cached.isEmpty ? null : cached;
    }
    if (!_fetching.add(imageId)) {
      return null;
    }
    try {
      final String? path = await widget.loadBytes(imageId);
      if (!mounted) {
        return path;
      }
      setState(() {
        _paths[imageId] = path ?? '';
      });
      return path;
    } catch (_) {
      if (mounted) {
        setState(() {
          _paths[imageId] = '';
        });
      }
      return null;
    } finally {
      _fetching.remove(imageId);
    }
  }

  Future<void> _preview(LibraryImage image) async {
    unawaited(_ensureBytes(image.imageId));
    final bool opened = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => GalleryPreviewDialog(
            image: image,
            imagePath: _usablePath(image.imageId),
            onUseAsCanvas: () => Navigator.of(context).pop(true),
          ),
        ) ??
        false;
    if (opened && mounted) {
      await _useAsCanvas(image);
    }
  }

  /// Empty string from [_paths] means "fetch failed", which is not a path.
  String? _usablePath(String imageId) {
    final String? path = _paths[imageId];
    return path == null || path.isEmpty ? null : path;
  }

  Future<void> _useAsCanvas(LibraryImage image) async {
    final String? path = _usablePath(image.imageId) ?? await _ensureBytes(image.imageId);
    if (!mounted) {
      return;
    }
    widget.onUseAsCanvas(image, path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('gallery_screen'),
      backgroundColor: StudioTheme.bg,
      appBar: AppBar(
        backgroundColor: StudioTheme.surface,
        title: const Text('Image library', key: Key('gallery_title')),
        actions: <Widget>[
          IconButton(
            key: const Key('gallery_refresh'),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _images.isEmpty) {
      return const Center(
        key: Key('gallery_loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_images.isEmpty) {
      if (_error != null) {
        return Column(
          key: const Key('gallery_error'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            GalleryEmptyState(offline: _offline),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: StudioTheme.danger,
                  fontSize: StudioTheme.captionSize,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              key: const Key('gallery_retry'),
              onPressed: _load,
              child: const Text('Try again'),
            ),
          ],
        );
      }
      return const GalleryEmptyState();
    }
    return RefreshIndicator(
      onRefresh: () async {
        final GalleryListLoader refresh = widget.onRefresh ?? widget.loadImages;
        try {
          final List<LibraryImage> images = await refresh();
          if (mounted) {
            setState(() {
              _images = sortLibraryNewestFirst(images);
            });
          }
        } catch (_) {
          // Keeping the stale grid beats blanking it on a transient failure.
        }
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = galleryGridColumns(constraints.maxWidth);
          return GridView.builder(
            key: const Key('gallery_grid'),
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.82,
            ),
            itemCount: _images.length,
            itemBuilder: (BuildContext context, int index) {
              final LibraryImage image = _images[index];
              return GalleryGridCard(
                image: image,
                thumbnailPath: _usablePath(image.imageId),
                onTap: () => _preview(image),
                onUseAsCanvas: () => _useAsCanvas(image),
              );
            },
          );
        },
      ),
    );
  }
}
