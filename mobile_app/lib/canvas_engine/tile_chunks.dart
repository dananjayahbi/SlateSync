/// Issue 05 — Mobile canvas reliability package (chunked tile bakes,
/// memory policy, bake instrumentation).
///
/// Small, self-contained collaborators for [TiledCanvasEngine] /
/// `TileCache` (see `tiled_canvas_painter.dart`):
///
/// * [TileChunkPolicy] — the flush threshold `K = 32` and the
///   bucket-resolution byte estimator for one recorded picture.
/// * [TileChunkEntry] — one tile's payload: a single consolidated base
///   `ui.Picture` plus a tail of ≤ K individual stroke pictures. Committing
///   records ONE small picture into the tail (O(1)); the tail is folded
///   into a fresh base picture only when it fills (O(K) draw-picture ops,
///   never a stroke-level re-walk). The painter replays ≤ K+1 pictures per
///   visible tile.
/// * [CacheMemoryPolicy] — the LRU high/low watermarks (trim 120 MB →
///   96 MB) plus the aggressive memory-pressure watermark (64 MB).
/// * [BakeInstrumentation] — stroke-replay / bake counters used by the
///   bounded-rebuild proof tests (Issue 05 §5).
library;

import 'dart:ui' as ui;

// ---------------------------------------------------------------------------
// Policy
// ---------------------------------------------------------------------------

/// Chunk policy constants and per-picture byte estimation (Issue 05 §1/§3).
class TileChunkPolicy {
  TileChunkPolicy._();

  /// Flush threshold `K` — the maximum number of individual stroke pictures
  /// a tile may hold in its tail before they are consolidated into the base
  /// picture. Also bounds the painter's per-tile replay to ≤ `K + 1`
  /// pictures.
  static const int flushThreshold = 32;

  /// Fixed per-picture overhead (op-list + Dart/Skia wrapper) folded into
  /// every tail-picture estimate.
  static const int pictureOverheadBytes = 256;

  /// Accurate `approxBytes` unit (Issue 05 §3): the bucket-resolution pixel
  /// estimate of one stroke picture — the picture is clipped to its tile at
  /// record time, so only the intersection can be retained — plus the
  /// per-chunk overhead. `factor` is the bucket factor `b = 2^bucket`;
  /// the Doc 22 §4 retention model (RGBA ×4, 4:1 picture retention) folds
  /// to "pixel count" exactly like `TileCache.bytesForBucket`.
  static int strokePictureBytes({
    required double factor,
    required ui.Rect worldExtent,
    required ui.Rect tile,
  }) {
    final ui.Rect clipped = worldExtent.intersect(tile);
    if (clipped.isEmpty || !clipped.isFinite) {
      return pictureOverheadBytes;
    }
    final int pw = (clipped.width * factor).ceil().clamp(1, 1 << 22);
    final int ph = (clipped.height * factor).ceil().clamp(1, 1 << 22);
    return pw * ph + pictureOverheadBytes;
  }
}

// ---------------------------------------------------------------------------
// Chunked tile payload
// ---------------------------------------------------------------------------

/// One tile's chunked content (Issue 05 §1): an optional consolidated base
/// picture + an append-only tail of ≤ [TileChunkPolicy.flushThreshold]
/// individual stroke pictures.
///
/// Commit path: [append] records nothing itself (the caller supplies the
/// freshly recorded single-stroke picture) ⇒ O(1). When the tail fills,
/// [consolidate] folds `base + tail` into a new base by recording only
/// `drawPicture` ops (O(K), no stroke re-walk) and clears the tail.
class TileChunkEntry {
  /// Entry holding a single (full-tile) picture — the `TileCache.put` /
  /// full-bake shape.
  TileChunkEntry.single(ui.Picture picture, {required int bytes})
      : base = picture,
        baseBytes = bytes,
        bytes = bytes;

  /// Consolidated picture of everything baked before the tail (`null` before
  /// the first consolidation of a put-created entry is not possible — entries
  /// are always born with a base — but `getTile` paths keep it nullable for
  /// safety).
  ui.Picture? base;

  /// Accounted bytes of [base] alone (bucket-resolution pixel estimate).
  int baseBytes;

  /// Tail pictures in commit order (Issue 05 §1) — always ≤
  /// [TileChunkPolicy.flushThreshold].
  final List<ui.Picture> tail = <ui.Picture>[];

  /// Accounted bytes per tail picture (parallel to [tail]).
  final List<int> tailBytes = <int>[];

  /// Total accounted bytes = `baseBytes + Σ(tailBytes)`.
  int bytes;

  ui.Picture? _combined;

  int get tailLength => tail.length;

  /// True once the tail reached flush threshold `K` and must be folded into
  /// the base picture.
  bool get shouldConsolidate =>
      tail.length >= TileChunkPolicy.flushThreshold;

  /// Replay order for the painter: base first, then tails — never more than
  /// `K + 1` pictures.
  List<ui.Picture> get pictures {
    final ui.Picture? b = base;
    if (b == null) {
      return List<ui.Picture>.of(tail);
    }
    return <ui.Picture>[b, ...tail];
  }

  /// Legacy single-picture view (Doc 22 `TileCache.get` / `getTile`
  /// contract): the base itself while the tail is empty, otherwise a
  /// combined picture whose identity is stable until the next mutation.
  ui.Picture get snapshot {
    if (tail.isEmpty) {
      return base!;
    }
    return _combined ??= _recordCombined();
  }

  /// Append one freshly recorded stroke picture (O(1)).
  void append(ui.Picture picture, int pictureBytes) {
    tail.add(picture);
    tailBytes.add(pictureBytes);
    bytes += pictureBytes;
    _combined = null;
  }

  /// Fold `base + tail` into a new base picture with O(K) `drawPicture` ops
  /// (no stroke-level re-recording) and reset the byte model to the
  /// full-tile estimate [mergedBaseBytes].
  void consolidate({required int mergedBaseBytes}) {
    if (tail.isEmpty) {
      return;
    }
    final ui.Picture oldBase = base!;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawPicture(oldBase);
    for (final ui.Picture p in tail) {
      canvas.drawPicture(p);
    }
    // The previous base is not disposed here: legacy `get`/`getTile`
    // holders may still reference it (identity contract); Skia's Dart
    // finalizer reclaims it once unreferenced.
    base = recorder.endRecording();
    baseBytes = mergedBaseBytes;
    bytes = mergedBaseBytes;
    tail.clear();
    tailBytes.clear();
    _combined = null;
  }

  ui.Picture _recordCombined() {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Picture? b = base;
    if (b != null) {
      canvas.drawPicture(b);
    }
    for (final ui.Picture p in tail) {
      canvas.drawPicture(p);
    }
    return recorder.endRecording();
  }

  /// Dispose every picture this entry owns (Issue 05 §3 eviction / §4
  /// pressure path). Pictures identical to [keepBase] survive — the
  /// `put`-replace case hands the same base picture to the incoming entry.
  void disposeAll({ui.Picture? keepBase}) {
    final ui.Picture? b = base;
    if (b != null && !identical(b, keepBase)) {
      b.dispose();
    }
    base = null;
    for (final ui.Picture p in tail) {
      p.dispose();
    }
    tail.clear();
    tailBytes.clear();
    final ui.Picture? c = _combined;
    if (c != null && !identical(c, keepBase)) {
      c.dispose();
    }
    _combined = null;
    baseBytes = 0;
    bytes = 0;
  }
}

// ---------------------------------------------------------------------------
// Memory policy
// ---------------------------------------------------------------------------

/// LRU watermark policy (Issue 05 §3/§4). Defaults mirror the frozen
/// Doc 22 §4 constants: high watermark 120 MB, eviction floor 96 MB (80 %),
/// and the aggressive OS memory-pressure trim target of 64 MB.
class CacheMemoryPolicy {
  CacheMemoryPolicy({
    required this.highWaterBytes,
    required this.lowWaterBytes,
    required this.pressureBytes,
  });

  /// LRU high watermark — exceeding it triggers eviction down to
  /// [lowWaterBytes] (Doc 22 §4 hysteresis).
  final int highWaterBytes;

  /// LRU low watermark (eviction floor).
  final int lowWaterBytes;

  /// Aggressive trim target on OS memory pressure (Issue 05 §4).
  final int pressureBytes;

  bool overHighWater(int totalBytes) => totalBytes > highWaterBytes;

  int get evictionFloorBytes => lowWaterBytes;
}

// ---------------------------------------------------------------------------
// Instrumentation
// ---------------------------------------------------------------------------

/// Bake counters for the bounded-rebuild proofs (Issue 05 §5).
///
/// * [strokeReplays] — every stroke-level recording (full-tile bakes record
///   each node once; a chunk append records its single stroke once;
///   consolidations record only `drawPicture` ops and add **zero**).
/// * [fullTileBakes] — whole-tile re-records (setDocument, bucket change,
///   incremental-eraser rebakes).
/// * [chunkAppends] — O(1) single-stroke tail appends.
/// * [consolidations] — O(K) tail folds.
class BakeInstrumentation {
  int strokeReplays = 0;
  int fullTileBakes = 0;
  int chunkAppends = 0;
  int consolidations = 0;

  @override
  String toString() =>
      'BakeInstrumentation(strokeReplays: $strokeReplays, '
      'fullTileBakes: $fullTileBakes, chunkAppends: $chunkAppends, '
      'consolidations: $consolidations)';
}
