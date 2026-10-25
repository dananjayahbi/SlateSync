/// Round-8 issue 05 — decoded-image cache for canvas rendering.
///
/// The IMAGE tool had a broken pipeline on the tablet: `_drawNode` drew
/// `canvas.drawRect(...)` where the picture should be, so a picked photo was
/// never painted — only an empty filled box. Drawing the real thing needs a
/// `ui.Image`, and decoding is asynchronous while the tile bake is
/// synchronous (`Canvas` drawing cannot await).
///
/// This cache bridges that gap the way every canvas engine does:
///
/// 1. `resolve(ref, bytes)` registers the encoded bytes for a `geometry.asset_ref`.
/// 2. `ensureDecoded([refs])` starts decoding anything still pending.
/// 3. `imageOf(ref)` returns the decoded `ui.Image` synchronously, or `null`
///    while it is still in flight.
///
/// A node whose image is not ready yet paints nothing (never a bogus
/// placeholder), and the caller repaints once [onReady] fires. Because tile
/// bakes are cached, the caller must invalidate only the tiles touching a
/// node whose asset just became ready — [AssetImageCache.onReady] is what the
/// engine wires to that invalidation.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decoded `ui.Image` cache keyed by `geometry.asset_ref`.
class AssetImageCache {
  AssetImageCache({this.onReady});

  /// Called with the `asset_ref` that just finished decoding, so the owner can
  /// re-bake the affected tiles. Never called for an already-cached ref.
  /// Assignable so the engine can wire it after construction.
  void Function(String assetRef)? onReady;

  final Map<String, Uint8List> _encoded = <String, Uint8List>{};
  final Map<String, ui.Image> _decoded = <String, ui.Image>{};
  final Set<String> _inFlight = <String>{};
  final Set<String> _failed = <String>{};
  bool _disposed = false;

  /// Registers the encoded bytes for [assetRef] (no-op when unchanged).
  ///
  /// Registering DIFFERENT bytes for an existing ref evicts the decoded image
  /// so a replaced asset cannot keep painting the old picture.
  void resolve(String assetRef, Uint8List bytes) {
    if (_disposed || assetRef.isEmpty) {
      return;
    }
    final Uint8List? previous = _encoded[assetRef];
    if (previous != null && _sameBytes(previous, bytes)) {
      return;
    }
    _encoded[assetRef] = bytes;
    _failed.remove(assetRef);
    _disposeImage(assetRef);
  }

  /// Starts decoding every ref in [assetRefs] that has bytes but no image.
  void ensureDecoded(Iterable<String> assetRefs) {
    if (_disposed) {
      return;
    }
    for (final String ref in assetRefs) {
      if (_decoded.containsKey(ref) ||
          _inFlight.contains(ref) ||
          _failed.contains(ref)) {
        continue;
      }
      final Uint8List? bytes = _encoded[ref];
      if (bytes == null || bytes.isEmpty) {
        continue;
      }
      _inFlight.add(ref);
      _decode(ref, bytes);
    }
  }

  /// Decoded image for [assetRef], or `null` while pending/failed/unknown.
  ui.Image? imageOf(String? assetRef) {
    if (assetRef == null || assetRef.isEmpty) {
      return null;
    }
    return _decoded[assetRef];
  }

  bool isReady(String? assetRef) =>
      assetRef != null && _decoded.containsKey(assetRef);

  bool hasFailed(String? assetRef) => assetRef != null && _failed.contains(assetRef);

  /// True while [assetRef] has bytes but no image yet.
  bool isPending(String? assetRef) =>
      assetRef != null && _inFlight.contains(assetRef);

  /// Round-12 issue 06 — is ANY image still decoding?
  ///
  /// The placeholder ticker uses this to decide whether to keep requesting
  /// frames, so an idle canvas costs nothing.
  bool get hasPending => _inFlight.isNotEmpty;

  /// The refs currently decoding (used to invalidate only their tiles).
  Set<String> get pendingRefs => Set<String>.unmodifiable(_inFlight);

  /// Number of decoded images held — test/diagnostic hook.
  int get cachedCount => _decoded.length;

  Future<void> _decode(String ref, Uint8List bytes) async {
    ui.Image? image;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
    } catch (_) {
      image = null;
    }
    if (_disposed) {
      image?.dispose();
      return;
    }
    _inFlight.remove(ref);
    if (image == null) {
      _failed.add(ref);
      return;
    }
    _decoded[ref] = image;
    onReady?.call(ref);
  }

  void _disposeImage(String ref) {
    final ui.Image? existing = _decoded.remove(ref);
    existing?.dispose();
  }

  /// Releases every decoded image. Safe to call twice.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final ui.Image image in _decoded.values) {
      image.dispose();
    }
    _decoded.clear();
    _encoded.clear();
    _inFlight.clear();
    _failed.clear();
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
