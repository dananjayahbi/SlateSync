/// Doc 22 — Tiled Picture Cache Engine (2 GB-safe).
///
/// Partitions world space into 1024×1024 tiles, bakes static strokes into
/// bucketed `ui.Picture` tiles behind an LRU byte-budget cache, keeps an
/// in-file R-tree over committed nodes, and makes every commit dirty only its
/// containing tiles (event-driven rebake — the anti-quadratic core). Also
/// hosts the dual-layer `RepaintBoundary` widget separating static tiles from
/// live strokes.
///
/// Wave 1.B note: Doc 20's `CameraController` and Doc 21's `ProcessedStroke`
/// are written concurrently by sibling agents, so [TiledCanvasEngine] accepts
/// them structurally (an object exposing `double scale` / an object exposing
/// `bbox` + `toRpcPayload()`) instead of importing those types. All frozen
/// names, arities and behaviors from template §5 are reproduced exactly.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mobile_app/canvas_engine/asset_image_cache.dart'; // round-8 issue 05
import 'package:mobile_app/canvas_engine/tile_chunks.dart'; // Issue 05
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

// ---------------------------------------------------------------------------
// Master constants (template §3 / Doc 22 §4)
// ---------------------------------------------------------------------------

/// Tile edge length in world units (1024×1024 tiles).
const double tileSize = 1024.0;

/// Default LRU byte budget: ~120 MB of the <180 MB Flutter heap gate
/// (Doc 22 §4).
const int defaultCacheMaxBytes = 120 * 1048576;

/// Eviction hysteresis floor: overflow evicts LRU entries down to ~96 MB
/// (80 % of the cap, Doc 22 §4).
const int defaultCacheEvictToBytes = 96 * 1048576;

/// Aggressive trim target on OS memory pressure (Issue 05 §4): drop the
/// tile cache to ~64 MB and invalidate offscreen tiles.
const int defaultCachePressureBytes = 64 * 1048576;

/// Base retained bytes per baked tile: RGBA `1024·1024·4` with the 4:1
/// picture-retention factor ⇒ 1 MB (Doc 22 §4 `approxBytes` formula).
const int pictureRetentionBaseBytes = (1024 * 1024 * 4) ~/ 4;

/// Zoom-bucket exponent `k = round(log2(scale))` so the bucket factor is
/// `b = 2^k` (Doc 22 §4 "bucket rasterization"). Non-positive scales fall
/// back to `k = 0`.
int bucketExponentForScale(double scale) {
  if (!(scale > 0)) {
    return 0;
  }
  return (math.log(scale) / math.ln2).round();
}

/// Bucket factor `b = 2^k` for an exponent produced by
/// [bucketExponentForScale].
double bucketFactorForExponent(int exponent) => math.pow(2.0, exponent).toDouble();

// ---------------------------------------------------------------------------
// TileKey (template §5 freeze)
// ---------------------------------------------------------------------------

/// Immutable tile coordinate value: `TileKey(floor(x/1024), floor(y/1024))`.
class TileKey {
  const TileKey(this.tx, this.ty);

  final int tx;
  final int ty;

  /// Dart's `floor()` handles negatives: `x=-500 ⇒ tx=-1` (Doc 22 §4).
  static TileKey forPoint(num x, num y) =>
      TileKey((x / tileSize).floor(), (y / tileSize).floor());

  /// World-space square covered by this tile, `(tx·1024, ty·1024)` →
  /// `((tx+1)·1024, (ty+1)·1024)`; adjacency is exact (Doc 22 §4).
  Rect get worldRect => Rect.fromLTWH(
        tx * tileSize,
        ty * tileSize,
        tileSize,
        tileSize,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TileKey && other.tx == tx && other.ty == ty);

  @override
  int get hashCode => Object.hash(tx, ty);

  @override
  String toString() => 'TileKey($tx, $ty)';
}

// ---------------------------------------------------------------------------
// TileCache (template §5 freeze)
// ---------------------------------------------------------------------------

class _CacheEntry {
  _CacheEntry(this.key, ui.Picture picture, this.bucket, int bytes)
      : chunks = TileChunkEntry.single(picture, bytes: bytes);

  final TileKey key;

  /// Issue 05 §1 — one consolidated base picture + ≤ K tail pictures.
  final TileChunkEntry chunks;

  /// Zoom-bucket exponent recorded when the entry was put (Doc 22 §4).
  final int bucket;

  /// Recency chain: `prev` ⇒ newer (towards MRU head), `next` ⇒ older
  /// (towards LRU tail).
  _CacheEntry? prev;
  _CacheEntry? next;
}

/// Map + doubly-linked LRU of baked `ui.Picture` tiles behind a byte budget
/// (Doc 22 §4): cap ~120 MB, evict oldest-first down to ~96 MB on overflow,
/// `get` promotes to MRU.
class TileCache {
  TileCache({
    this.maxBytes = defaultCacheMaxBytes,
    this.evictToBytes = defaultCacheEvictToBytes,
    this.pressureBytes = defaultCachePressureBytes,
  }) : assert(evictToBytes <= maxBytes) {
    policy = CacheMemoryPolicy(
      highWaterBytes: maxBytes,
      lowWaterBytes: evictToBytes,
      pressureBytes: pressureBytes,
    );
  }

  final int maxBytes;
  final int evictToBytes;

  /// Issue 05 §4 — watermark used by [trimTo] under OS memory pressure.
  final int pressureBytes;

  /// Issue 05 §3 — shared watermark math for [TrimOutcome]-style reporting
  /// (high/low/pressure triples are only coherent as one policy object).
  late final CacheMemoryPolicy policy;

  /// Zoom-bucket exponent used for entries [put] from now on: pictures put
  /// while this is `k` count `approxBytes` as `1 MB / 4^max(0,-k)` bytes
  /// (Doc 22 §4 formula). Engine-managed; default `0` (bucket factor 1).
  int bucket = 0;

  final Map<TileKey, _CacheEntry> _entries = <TileKey, _CacheEntry>{};
  _CacheEntry? _head; // MRU
  _CacheEntry? _tail; // LRU
  int _totalBytes = 0;
  int _generation = 0;

  /// Bumped on every structural change; painters compare it in
  /// `shouldRepaint` (Doc 22 §4).
  int get generation => _generation;

  /// Retained bytes for one tile baked at [bucketExponent]
  /// (`1 MB / 4^L`, `L = max(0, −k)` — Doc 22 §4).
  static int bytesForBucket(int bucketExponent) {
    final int levels = bucketExponent < 0 ? -bucketExponent : 0;
    // `4^L` shift; clamp keeps at least 1 byte for degenerate zooms (the
    // 0.05…20.0 camera range ⇒ L ≤ 4 in practice).
    final int shift = 2 * (levels > 10 ? 10 : levels);
    return pictureRetentionBaseBytes >> shift;
  }

  ui.Picture? get(TileKey k) {
    final _CacheEntry? e = _entries[k];
    if (e == null) {
      return null;
    }
    _promote(e);
    // Issue 05 §1: base picture when the tail is empty (identity-stable —
    // frozen `put`/`get` contract), combined base∘tail snapshot otherwise.
    return e.chunks.snapshot;
  }

  /// Issue 05 §1 — pictures a painter replays for [k] (≤ K+1: one base
  /// plus the stroke tail). Empty on a miss.
  List<ui.Picture> picturesOf(TileKey k) {
    final _CacheEntry? e = _entries[k];
    if (e == null) {
      return const <ui.Picture>[];
    }
    _promote(e);
    return e.chunks.pictures;
  }

  /// Issue 05 §1 — append one stroke picture to [k]'s tail (O(1) bookkeeping).
  /// Returns the new tail length (0 on a miss, for flush decisions).
  int appendStroke(TileKey k, ui.Picture p, int pictureBytes) {
    final _CacheEntry? e = _entries[k];
    if (e == null) {
      return 0;
    }
    e.chunks.append(p, pictureBytes);
    _totalBytes += pictureBytes;
    _promote(e);
    _generation++;
    _enforceBudget();
    return e.chunks.tailLength;
  }

  /// Issue 05 §1 — fold [k]'s full tail into the base picture (O(K); over a
  /// K-commit window the amortized cost is O(1) per commit).
  void consolidate(TileKey k, {required int mergedBaseBytes}) {
    final _CacheEntry? e = _entries[k];
    if (e == null) {
      return;
    }
    final int before = e.chunks.bytes;
    e.chunks.consolidate(mergedBaseBytes: mergedBaseBytes);
    _totalBytes += e.chunks.bytes - before;
    _generation++;
    _enforceBudget();
  }

  /// Issue 05 §1 — longest current tail across entries (proof/tests).
  int maxTailLength() {
    int max = 0;
    for (final _CacheEntry e in _entries.values) {
      if (e.chunks.tailLength > max) max = e.chunks.tailLength;
    }
    return max;
  }

  /// Non-promoting membership test used by the engine's bake paths.
  bool contains(TileKey k) => _entries.containsKey(k);

  void put(TileKey k, ui.Picture p) {
    final _CacheEntry? old = _entries[k];
    if (old != null) {
      _drop(old, disposePicture: !identical(old.chunks.base, p));
    }
    final _CacheEntry entry =
        _CacheEntry(k, p, bucket, bytesForBucket(bucket));
    _entries[k] = entry;
    _pushHead(entry);
    _totalBytes += entry.chunks.bytes;
    _enforceBudget();
  }

  void invalidate(TileKey k) {
    final _CacheEntry? e = _entries[k];
    if (e != null) {
      _drop(e, disposePicture: true);
    }
  }

  /// Issue 05 §3 — drop every zoom bucket except [keepBucket] wholesale: a
  /// scale step makes all other buckets useless, so retaining their bytes
  /// (and re-baking on the way back) is not worth it.
  void invalidateExceptBucket(int keepBucket) {
    final List<_CacheEntry> stale = _entries.values
        .where((_CacheEntry e) => e.bucket != keepBucket)
        .toList();
    for (final _CacheEntry e in stale) {
      _drop(e, disposePicture: true);
    }
  }

  /// Issue 05 §4 — drop every tile outside [keep] (offscreen invalidation
  /// under memory pressure).
  void invalidateOutside(Set<TileKey> keep) {
    final List<_CacheEntry> stale = _entries.values
        .where((_CacheEntry e) => !keep.contains(e.key))
        .toList();
    for (final _CacheEntry e in stale) {
      _drop(e, disposePicture: true);
    }
  }

  /// Issue 05 §4 — evict LRU entries until [approxBytes] ≤ [targetBytes].
  /// Returns the number of entries dropped.
  int trimTo(int targetBytes) {
    int dropped = 0;
    while (_totalBytes > targetBytes && _tail != null) {
      _drop(_tail!, disposePicture: true);
      dropped++;
    }
    return dropped;
  }

  void invalidateAll() {
    for (final _CacheEntry e in _entries.values) {
      e.chunks.disposeAll();
    }
    _entries.clear();
    _head = null;
    _tail = null;
    _totalBytes = 0;
    _generation++;
  }

  /// Issue 05 §3 — single enforcement point: over the high watermark evict
  /// LRU entries down to the low watermark (same hysteresis `put` used).
  void _enforceBudget() {
    if (_totalBytes > maxBytes) {
      while (_totalBytes > evictToBytes && _tail != null) {
        _drop(_tail!, disposePicture: true);
      }
    }
  }

  int approxBytes() => _totalBytes;

  void _promote(_CacheEntry e) {
    if (identical(_head, e)) {
      return;
    }
    _unlink(e);
    _pushHead(e);
  }

  void _unlink(_CacheEntry e) {
    final _CacheEntry? p = e.prev;
    final _CacheEntry? n = e.next;
    if (p != null) {
      p.next = n;
    } else {
      _head = n;
    }
    if (n != null) {
      n.prev = p;
    } else {
      _tail = p;
    }
    e.prev = null;
    e.next = null;
  }

  void _pushHead(_CacheEntry e) {
    e.prev = null;
    e.next = _head;
    if (_head != null) {
      _head!.prev = e;
    } else {
      _tail = e;
    }
    _head = e;
  }

  void _drop(_CacheEntry e, {required bool disposePicture}) {
    _unlink(e);
    if (identical(_entries[e.key], e)) {
      _entries.remove(e.key);
    }
    _totalBytes -= e.chunks.bytes;
    // Tail/combined pictures are exclusively owned ⇒ always disposed; the
    // base is kept only when the caller says it is shared with an
    // incoming picture (legacy `put` identity case).
    e.chunks.disposeAll(
      keepBase: disposePicture ? null : e.chunks.base,
    );
    _generation++;
  }
}

// ---------------------------------------------------------------------------
// SpatialRTree (template §5 freeze — in-file classic R-tree, Doc 22 §4)
// ---------------------------------------------------------------------------

class _RtEntry {
  _RtEntry(this.node, this.rect);

  final CanvasNodeModel node;
  final Rect rect;

  _RtLeaf? leaf;
}

class _RtLeaf {
  _RtInternal? parent;
  final List<_RtEntry> entries = <_RtEntry>[];
  Rect? bbox;

  Rect fit() {
    Rect? r;
    for (final _RtEntry e in entries) {
      r = r == null ? e.rect : r.expandToInclude(e.rect);
    }
    bbox = r;
    return r ?? Rect.zero;
  }
}

class _RtInternal {
  _RtInternal? parent;
  final List<Object> children = <Object>[]; // _RtLeaf | _RtInternal
  Rect? bbox;

  Rect fit() {
    Rect? r;
    for (final Object c in children) {
      final Rect? cb = c is _RtLeaf ? c.bbox : (c as _RtInternal).bbox;
      if (cb == null) {
        continue;
      }
      r = r == null ? cb : r.expandToInclude(cb);
    }
    bbox = r;
    return r ?? Rect.zero;
  }
}

/// In-file classic R-tree over [CanvasNodeModel]: leaf/internal nodes with
/// capacity 8, sorted mid-split bulk load, bbox search with `Rect.overlaps`,
/// `remove(nodeId)` via an id lookup table (template §5 / Doc 22 §4).
class SpatialRTree {
  SpatialRTree();

  static const int capacity = 8;

  Object? _root; // _RtLeaf | _RtInternal | null
  final Map<String, _RtEntry> _byId = <String, _RtEntry>{};

  /// Sorted mid-split bulk load: sort by bbox center x, split at the midpoint
  /// of the longer axis, each half ≈ n/2 (Doc 22 §4). Replaces all contents.
  void bulkLoad(List<CanvasNodeModel> nodes) {
    clear();
    if (nodes.isEmpty) {
      return;
    }
    final List<_RtEntry> entries = <_RtEntry>[];
    for (final CanvasNodeModel n in nodes) {
      final _RtEntry e = _RtEntry(n, _rectOfNode(n));
      entries.add(e);
      _byId[n.nodeId] = e;
    }
    entries.sort((_RtEntry a, _RtEntry b) =>
        a.rect.center.dx.compareTo(b.rect.center.dx));
    _root = _build(entries, 0, entries.length);
  }

  void insert(CanvasNodeModel n) {
    remove(n.nodeId); // id table stays unique — replace semantics
    final _RtEntry entry = _RtEntry(n, _rectOfNode(n));
    _byId[n.nodeId] = entry;
    if (_root == null) {
      final _RtLeaf leaf = _RtLeaf()..entries.add(entry);
      leaf.fit();
      entry.leaf = leaf;
      _root = leaf;
      return;
    }
    Object node = _root!;
    while (node is _RtInternal) {
      node = _chooseChild(node, entry.rect);
    }
    final _RtLeaf leaf = node as _RtLeaf;
    leaf.entries.add(entry);
    entry.leaf = leaf;
    _refit(leaf);
    _splitOverflow(leaf);
  }

  /// Id-table read (Issue 05 §2): the indexed model for [nodeId], or null —
  /// lets [TiledCanvasEngine.removeCommitted] compute a removal's tiles
  /// without a full reindex.
  CanvasNodeModel? nodeById(String nodeId) => _byId[nodeId]?.node;

  void remove(String nodeId) {
    final _RtEntry? entry = _byId.remove(nodeId);
    if (entry == null) {
      return;
    }
    final _RtLeaf? leaf = entry.leaf;
    if (leaf == null) {
      return;
    }
    leaf.entries.remove(entry);
    entry.leaf = null;
    _prune(leaf);
  }

  /// bbox search with `Rect.overlaps` pruning (Doc 22 §4). Result order is
  /// unspecified; consumers compare id sets or sort by layer themselves.
  List<CanvasNodeModel> query(Rect worldRect) {
    final List<CanvasNodeModel> out = <CanvasNodeModel>[];
    if (_root == null) {
      return out;
    }
    final List<Object> stack = <Object>[_root!];
    while (stack.isNotEmpty) {
      final Object node = stack.removeLast();
      if (node is _RtLeaf) {
        final Rect? bb = node.bbox;
        if (bb == null || !bb.overlaps(worldRect)) {
          continue;
        }
        for (final _RtEntry e in node.entries) {
          if (e.rect.overlaps(worldRect)) {
            out.add(e.node);
          }
        }
      } else if (node is _RtInternal) {
        final Rect? bb = node.bbox;
        if (bb == null || !bb.overlaps(worldRect)) {
          continue;
        }
        stack.addAll(node.children);
      }
    }
    return out;
  }

  /// Drop every entry (document switch, Doc 22 §4 "clear … tree").
  void clear() {
    _root = null;
    _byId.clear();
  }

  Object _build(List<_RtEntry> entries, int start, int end) {
    final int count = end - start;
    if (count <= capacity) {
      final _RtLeaf leaf = _RtLeaf();
      for (int i = start; i < end; i++) {
        leaf.entries.add(entries[i]);
        entries[i].leaf = leaf;
      }
      leaf.fit();
      return leaf;
    }
    // Mid-split on the longer axis; halves ≈ n/2 (Doc 22 §4).
    final Rect span = _spanOf(entries, start, end);
    final bool byX = span.width >= span.height;
    final List<_RtEntry> sorted = entries.sublist(start, end);
    sorted.sort((_RtEntry a, _RtEntry b) {
      final double ca = byX ? a.rect.center.dx : a.rect.center.dy;
      final double cb = byX ? b.rect.center.dx : b.rect.center.dy;
      return ca.compareTo(cb);
    });
    for (int i = 0; i < sorted.length; i++) {
      entries[start + i] = sorted[i];
    }
    final int mid = start + count ~/ 2;
    final Object left = _build(entries, start, mid);
    final Object right = _build(entries, mid, end);
    final _RtInternal internal = _RtInternal();
    internal.children.addAll(<Object>[left, right]);
    if (left is _RtLeaf) {
      left.parent = internal;
    } else {
      (left as _RtInternal).parent = internal;
    }
    if (right is _RtLeaf) {
      right.parent = internal;
    } else {
      (right as _RtInternal).parent = internal;
    }
    internal.fit();
    return internal;
  }

  static Rect _spanOf(List<_RtEntry> entries, int start, int end) {
    Rect? r;
    for (int i = start; i < end; i++) {
      r = r == null ? entries[i].rect : r.expandToInclude(entries[i].rect);
    }
    return r ?? Rect.zero;
  }

  Object _chooseChild(_RtInternal node, Rect r) {
    Object best = node.children.first;
    double bestEnlargement = double.infinity;
    double bestArea = double.infinity;
    for (final Object c in node.children) {
      final Rect? cb = c is _RtLeaf ? c.bbox : (c as _RtInternal).bbox;
      if (cb == null) {
        continue;
      }
      final double enlargement =
          cb.expandToInclude(r).width * cb.expandToInclude(r).height -
              cb.width * cb.height;
      final double area = cb.width * cb.height;
      if (enlargement < bestEnlargement ||
          (enlargement == bestEnlargement && area < bestArea)) {
        best = c;
        bestEnlargement = enlargement;
        bestArea = area;
      }
    }
    return best;
  }

  void _refit(Object node) {
    Object? cur = node;
    while (cur != null) {
      if (cur is _RtLeaf) {
        cur.fit();
        cur = cur.parent;
      } else if (cur is _RtInternal) {
        cur.fit();
        cur = cur.parent;
      } else {
        break;
      }
    }
  }

  /// Sorted mid-split on overflow with upward propagation (Doc 22 §4): the
  /// overflowing node hands half its items to a new sibling, the sibling is
  /// inserted beside it under the same parent (parent count +1), and the
  /// parent is re-fit — repeating while it also overflows. A splitting root
  /// becomes a two-child internal root.
  void _splitOverflow(Object node) {
    Object? cur = node;
    while (cur != null) {
      if (!_overflows(cur)) {
        return;
      }
      final Object sibling = _splitNode(cur);
      final _RtInternal? parent = _parentOf(cur);
      if (parent == null) {
        final _RtInternal wrapper = _RtInternal();
        wrapper.children.addAll(<Object>[cur, sibling]);
        _setParent(cur, wrapper);
        _setParent(sibling, wrapper);
        _root = wrapper;
        return;
      }
      _setParent(sibling, parent);
      final int idx = parent.children.indexOf(cur);
      parent.children
          .insert(idx >= 0 ? idx + 1 : parent.children.length, sibling);
      _refit(parent);
      cur = parent;
    }
  }

  /// Splits [cur] at the midpoint of its longer axis (sorted mid-split,
  /// halves ≈ n/2) and returns the new sibling half.
  Object _splitNode(Object cur) {
    if (cur is _RtLeaf) {
      final int count = cur.entries.length;
      final Rect span = cur.fit();
      final bool byX = span.width >= span.height;
      cur.entries.sort((_RtEntry a, _RtEntry b) {
        final double ca = byX ? a.rect.center.dx : a.rect.center.dy;
        final double cb = byX ? b.rect.center.dx : b.rect.center.dy;
        return ca.compareTo(cb);
      });
      final int mid = count ~/ 2;
      final _RtLeaf sibling = _RtLeaf();
      final List<_RtEntry> moved = cur.entries.sublist(mid);
      cur.entries.removeRange(mid, count);
      for (final _RtEntry e in moved) {
        sibling.entries.add(e);
        e.leaf = sibling;
      }
      cur.fit();
      sibling.fit();
      return sibling;
    }
    if (cur is _RtInternal) {
      final int count = cur.children.length;
      final Rect span = cur.fit();
      final bool byX = span.width >= span.height;
      Rect childRect(Object c) => c is _RtLeaf
          ? (c.bbox ?? Rect.zero)
          : ((c as _RtInternal).bbox ?? Rect.zero);
      cur.children.sort((Object a, Object b) {
        final Rect ra = childRect(a);
        final Rect rb = childRect(b);
        final double ca = byX ? ra.center.dx : ra.center.dy;
        final double cb = byX ? rb.center.dx : rb.center.dy;
        return ca.compareTo(cb);
      });
      final int mid = count ~/ 2;
      final _RtInternal sibling = _RtInternal();
      final List<Object> moved = cur.children.sublist(mid);
      cur.children.removeRange(mid, count);
      for (final Object c in moved) {
        sibling.children.add(c);
        _setParent(c, sibling);
      }
      cur.fit();
      sibling.fit();
      return sibling;
    }
    return cur;
  }

  static bool _overflows(Object node) {
    if (node is _RtLeaf) {
      return node.entries.length > capacity;
    }
    if (node is _RtInternal) {
      return node.children.length > capacity;
    }
    return false;
  }

  static _RtInternal? _parentOf(Object node) {
    if (node is _RtLeaf) {
      return node.parent;
    }
    if (node is _RtInternal) {
      return node.parent;
    }
    return null;
  }

  static void _setParent(Object node, _RtInternal parent) {
    if (node is _RtLeaf) {
      node.parent = parent;
    } else if (node is _RtInternal) {
      node.parent = parent;
    }
  }

  void _prune(_RtLeaf leaf) {
    if (leaf.entries.isNotEmpty) {
      _refit(leaf);
      return;
    }
    if (identical(_root, leaf)) {
      _root = null;
      return;
    }
    final _RtInternal? parent = leaf.parent;
    leaf.parent = null;
    if (parent != null) {
      parent.children.remove(leaf);
      _pruneInternal(parent);
    }
  }

  /// Removes now-empty internal nodes bottom-up and re-fits the surviving
  /// ancestor chain.
  void _pruneInternal(_RtInternal? node) {
    _RtInternal? cur = node;
    while (cur != null && cur.children.isEmpty) {
      if (identical(_root, cur)) {
        _root = null;
        return;
      }
      final _RtInternal? up = cur.parent;
      up?.children.remove(cur);
      cur.parent = null;
      cur = up;
    }
    if (cur != null) {
      _refit(cur);
    }
  }
}

Rect _rectOfNode(CanvasNodeModel n) => Rect.fromLTRB(
      n.bbox[0],
      n.bbox[1],
      n.bbox[2],
      n.bbox[3],
    );

// ---------------------------------------------------------------------------
// TiledCanvasEngine (template §5 freeze)
// ---------------------------------------------------------------------------

/// Event-driven tile rebake core (Doc 22 §4): [setDocument] bulk-loads the
/// document, [addCommitted] indexes a stroke and rebakes only the tiles its
/// bbox intersects (≤ 4 per normal commit), [addNode] indexes any node kind
/// (SHAPE / GRAPH_AXES / IMAGE / LINE — Issue R6) through the same per-kind
/// draw path, [clearAll] wipes index + cache state, [queryVisible] culls the
/// static layer.
class TiledCanvasEngine {
  /// Doc 22 §4 freeze shape `TiledCanvasEngine({required CameraController
  /// camera})`; see the library doc for the Wave 1.B structural typing note —
  /// the object must expose `double scale` (Doc 20's camera).
  TiledCanvasEngine({required this.camera}) {
    wireAssetInvalidation();
  }

  final TileCache cache = TileCache();

  /// Round-8 issue 05 — decoded IMAGE assets. Populated by the canvas page
  /// (picked bytes / loaded archive), consumed by [_drawNode]'s IMAGE branch,
  /// and re-bakes the affected tiles whenever a decode completes.
  final AssetImageCache assets = AssetImageCache();

  /// Round-8 issue 05 — after an asset finishes decoding, the tiles holding
  /// its IMAGE node must be re-baked (their cached pictures predate the
  /// bitmap). Set by the constructor-adjacent `wireAssetInvalidation()` so the
  /// cache can call back without the engine capturing a stale `this`.
  void wireAssetInvalidation() {
    assets.onReady = _invalidateAssetTiles;
  }

  /// Drops every cached tile so the next paint re-bakes from the index.
  /// Used when content the bake depends on changes outside the tile
  /// dirty-set — e.g. an IMAGE asset finishing its decode.
  void invalidateAllTiles() {
    cache.invalidateAll();
    _dirty.clear();
    _bakedBucket.clear();
  }

  void _invalidateAssetTiles(String assetRef) {
    for (final CanvasNodeModel node in _tree.query(Rect.largest)) {
      if (node.kind != 'IMAGE' || node.geometry.assetRef != assetRef) {
        continue;
      }
      for (final TileKey k in tilesCovering(_rectOfNode(node))) {
        cache.invalidate(k);
        _dirty.add(k);
      }
    }
    _rebakeCount++;
  }

  /// Structural camera (Doc 20): only `scale` is read.
  final dynamic camera;

  final SpatialRTree _tree = SpatialRTree();
  final Map<TileKey, int> _bakedBucket = <TileKey, int>{};
  final Set<TileKey> _dirty = <TileKey>{};
  int _rebakeCount = 0;
  Rect? _lastViewport;

  /// Issue 05 §5 — cumulative bake instrumentation for the bounded-rebuild
  /// proofs (`strokeReplays` per committed stroke must stay O(1) amortized,
  /// never quadratic). Lives for the engine's lifetime; tests snapshot
  /// deltas around the operation they measure.
  @visibleForTesting
  final BakeInstrumentation bakeStats = BakeInstrumentation();

  /// Per-operation rebake counter, reset at op start — the ≤4-tiles-per-
  /// commit assertion hook (Doc 22 §4, `@visibleForTesting`).
  @visibleForTesting
  int get rebakeCount => _rebakeCount;

  /// Current zoom-bucket exponent of the camera (Doc 22 §4).
  int get currentBucket => bucketExponentForScale(currentScale);

  /// Camera scale from the structural camera; 1.0 when unavailable.
  double get currentScale {
    final dynamic c = camera;
    if (c == null) {
      return 1.0;
    }
    final dynamic s = c.scale;
    return s is num ? s.toDouble() : 1.0;
  }

  /// Zoom-bucket exponent a cached picture was baked at (`null` = uncached).
  int? bakedBucketOf(TileKey k) => _bakedBucket[k];

  /// Clear cache + tree, bulk-load `doc.elements`, then bake every tile
  /// containing a node plus the 5×5 hot window (Doc 22 §5 step 5).
  void setDocument(CanvasDocumentModel doc) {
    _rebakeCount = 0;
    cache.invalidateAll();
    _bakedBucket.clear();
    _tree.bulkLoad(doc.elements);
    final int bucket = currentBucket;
    for (final CanvasNodeModel n in doc.elements) {
      for (final TileKey k in tilesCovering(_rectOfNode(n))) {
        _bakeAndStore(k, bucket);
      }
    }
    final Rect hot = _lastViewport ?? _unionOf(doc.elements) ?? Rect.fromLTWH(0, 0, tileSize, tileSize);
    _lastViewport ??= hot;
    _bakeWindow(hot, bucket);
  }

  /// Issue R6 (Doc 02 §10.1 engine half) — wipe ALL canvas state: the
  /// spatial index, the dirty set, the per-tile bucket map and every cached
  /// picture. Each entry's base, chunk tails and combined snapshot are
  /// DISPOSED by [TileCache.invalidateAll] (`chunks.disposeAll`) — no
  /// picture leaks — and a single cache-generation bump repaints every
  /// static-layer painter with an empty canvas.
  ///
  /// Deliberately preserved: camera/viewport state ([bakeVisible] window)
  /// and the cumulative [bakeStats] counters — neither is document state.
  /// RPC/broadcast of CLEAR_CANVAS stays with the canvas page (§10.1); the
  /// engine only clears state. Subsequent [addCommitted] / [addNode] /
  /// [setDocument] calls operate on the empty engine exactly as on a fresh
  /// one (miss ⇒ synchronous full bake).
  void clearAll() {
    _rebakeCount = 0;
    _tree.clear();
    _dirty.clear();
    _bakedBucket.clear();
    cache.invalidateAll();
  }

  /// Index a committed stroke (Doc 21) and rebake exactly its dirty tiles.
  ///
  /// Structural input: an object exposing `bbox` and `toRpcPayload()`
  /// (Doc 21's `ProcessedStroke`); see the library doc.
  void addCommitted(dynamic s) {
    _rebakeCount = 0;
    final CanvasNodeModel node = _nodeFrom(s);
    _tree.remove(node.nodeId);
    _tree.insert(node);
    _dirtyCommit(node);
  }

  /// Issue R6 (Doc 02 §10.3 / Doc 22 §4) — index one node of ANY kind
  /// (`SHAPE` / `GRAPH_AXES` / `IMAGE` / `LINE` / stroke) and render it
  /// through the exact same per-kind `_drawNode` dispatch [setDocument]
  /// uses, dirtying only `tilesCovering(node.bbox)` (≤ 4 tiles; never a
  /// full-cache invalidation).
  ///
  /// Fresh/missed/stale tiles take a synchronous full bake; tiles already
  /// baked at the current zoom bucket take the O(1) chunk-append path — one
  /// recorded node picture + a fold only at the K=32 tail threshold (Issue
  /// 05 §1) — so a node coexists with chunked stroke bakes in one tile.
  ///
  /// Re-inserting an existing `nodeId` replaces the indexed copy
  /// ([SpatialRTree.insert] replace semantics): the union of the previous
  /// and new tiles is force-rebaked from the index so no ghost ink survives
  /// the replacement.
  void addNode(CanvasNodeModel node) {
    _rebakeCount = 0;
    final CanvasNodeModel? prev = _tree.nodeById(node.nodeId);
    if (prev == null) {
      _tree.insert(node);
      _dirtyCommit(node);
      return;
    }
    _tree.insert(node); // replace semantics — id table stays unique
    final int bucket = currentBucket;
    _dirty
      ..clear()
      ..addAll(tilesCovering(_rectOfNode(prev)))
      ..addAll(tilesCovering(_rectOfNode(node)));
    for (final TileKey k in _dirty) {
      if (cache.contains(k) && bakedBucketOf(k) == bucket) {
        _ensureBaked(k, bucket, force: true); // re-record WITHOUT old copy
      }
    }
  }

  /// Compute the tiles intersecting `s.bbox` and rebake that dirty set only
  /// (Doc 22 §4 `markDirtyFor`).
  ///
  /// Issue 05 §1: tiles already baked at the current bucket take the O(1)
  /// chunk-append path — one recorded stroke picture (+ an O(K) fold only
  /// when the tail hits K=32) instead of re-walking every stroke in the
  /// tile; missing/stale tiles fall back to a full bake.
  void markDirtyFor(dynamic s) {
    _rebakeCount = 0;
    _dirtyCommit(_nodeFrom(s));
  }

  CanvasNodeModel _nodeFrom(dynamic s) {
    final dynamic payload = s.toRpcPayload();
    return CanvasNodeModel.fromJson(
      Map<String, dynamic>.from(payload as Map),
    );
  }

  void _dirtyCommit(CanvasNodeModel node) {
    final Rect r = _rectOfNode(node);
    _dirty
      ..clear()
      ..addAll(tilesCovering(r));
    final int bucket = currentBucket;
    final double b = bucketFactorForExponent(bucket);
    for (final TileKey k in _dirty) {
      if (cache.contains(k) && bakedBucketOf(k) == bucket) {
        final ui.Picture pic = _recordStrokeForTile(node, k, bucket);
        bakeStats.strokeReplays++;
        bakeStats.chunkAppends++;
        _rebakeCount++;
        final int tailLength = cache.appendStroke(
          k,
          pic,
          TileChunkPolicy.strokePictureBytes(
            factor: b,
            worldExtent: r,
            tile: k.worldRect,
          ),
        );
        if (tailLength >= TileChunkPolicy.flushThreshold) {
          cache.consolidate(
            k,
            mergedBaseBytes: TileCache.bytesForBucket(bucket),
          );
          bakeStats.consolidations++;
        }
      } else {
        _ensureBaked(k, bucket); // miss/stale ⇒ full bake (includes node)
      }
    }
  }

  /// Issue 05 §2 — incremental eraser: remove ONE node from the spatial
  /// index and force-rebake only the tiles it occupies (cached + current
  /// bucket). No document reindex, no cache wipe: [rebakeCount] after this
  /// call is bounded by `tilesCovering(nodeRect)`.
  void removeCommitted(String nodeId) {
    _rebakeCount = 0;
    final CanvasNodeModel? node = _tree.nodeById(nodeId);
    if (node == null) {
      return;
    }
    final Rect r = _rectOfNode(node);
    _tree.remove(nodeId);
    final int bucket = currentBucket;
    _dirty
      ..clear()
      ..addAll(tilesCovering(r));
    for (final TileKey k in _dirty) {
      if (cache.contains(k) && bakedBucketOf(k) == bucket) {
        _ensureBaked(k, bucket, force: true); // re-record WITHOUT the node
      }
    }
  }

  /// Static-layer culling: [SpatialRTree.query] overlap filter, paint order
  /// by layer (Doc 22 §5 step 8).
  List<CanvasNodeModel> queryVisible(Rect worldRect) {
    final List<CanvasNodeModel> nodes = _tree.query(worldRect);
    nodes.sort((CanvasNodeModel a, CanvasNodeModel b) =>
        a.layer.compareTo(b.layer));
    return nodes;
  }

  /// Eagerly bake the 5×5 tile window centered on [worldViewport]'s tile;
  /// misses/stale-bucket tiles fall back to a synchronous bake (Doc 22 §4).
  void bakeVisible(Rect worldViewport) {
    _rebakeCount = 0;
    _lastViewport = worldViewport;
    _bakeWindow(worldViewport, currentBucket);
  }

  /// Re-bake the hot window at the new zoom bucket after a bucket-boundary
  /// zoom (Doc 22 §4). Issue 05 §3: evict every NON-current-bucket entry
  /// wholesale — a scale step makes those buckets useless — while keeping
  /// still-valid current-bucket tiles (the old full wipe re-baked them
  /// for nothing); the hot window then backfills synchronously.
  void onScaleBucketChanged() {
    _rebakeCount = 0;
    final int bucket = currentBucket;
    cache.invalidateExceptBucket(bucket);
    _bakedBucket.removeWhere(
      (TileKey k, int b) => b != bucket || !cache.contains(k),
    );
    final Rect hot =
        _lastViewport ?? Rect.fromLTWH(0, 0, tileSize, tileSize);
    _bakeWindow(hot, bucket);
  }

  /// Synchronous get-path: cached picture at the current bucket, otherwise a
  /// single-tile bake (Doc 22 §4 "misses fall back to synchronous
  /// single-tile bake in the get-path").
  ui.Picture getTile(TileKey k) {
    _ensureBaked(k, currentBucket);
    return cache.get(k)!;
  }

  /// Issue 05 §1 — the painter's replay list for [k]: ≤ K+1 pictures
  /// (one consolidated base + the ≤32-stroke tail), not one picture per
  /// stroke in the tile.
  List<ui.Picture> tilePictures(TileKey k) {
    _ensureBaked(k, currentBucket);
    return cache.picturesOf(k);
  }

  void _ensureBaked(TileKey k, int bucket, {bool force = false}) {
    if (!force) {
      final int? baked = _bakedBucket[k];
      if (baked == bucket && cache.contains(k)) {
        cache.get(k); // LRU promote (legacy `_bakeAndStore` behavior)
        return;
      }
    }
    final ui.Picture picture = _bakeTile(k, bucket);
    cache.bucket = bucket;
    cache.put(k, picture);
    _bakedBucket[k] = bucket;
    _rebakeCount++;
    bakeStats.fullTileBakes++;
  }

  /// Tiles whose interior intersects [r] — degenerate right/bottom edges
  /// sitting exactly on a tile boundary do not spill into the next tile.
  Set<TileKey> tilesCovering(Rect r) {
    int x0 = (r.left / tileSize).floor();
    int x1 = (r.right / tileSize).floor();
    if (x1 > x0 && r.right == x1 * tileSize) {
      x1 -= 1;
    }
    int y0 = (r.top / tileSize).floor();
    int y1 = (r.bottom / tileSize).floor();
    if (y1 > y0 && r.bottom == y1 * tileSize) {
      y1 -= 1;
    }
    final Set<TileKey> out = <TileKey>{};
    for (int tx = x0; tx <= x1; tx++) {
      for (int ty = y0; ty <= y1; ty++) {
        out.add(TileKey(tx, ty));
      }
    }
    return out;
  }

  ui.Picture _bakeAndStore(TileKey k, int bucket, {bool force = false}) {
    _ensureBaked(k, bucket, force: force);
    return cache.get(k)!;
  }

  void _bakeWindow(Rect worldViewport, int bucket) {
    final Offset c = worldViewport.center;
    final TileKey center = TileKey.forPoint(c.dx, c.dy);
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        _bakeAndStore(TileKey(center.tx + dx, center.ty + dy), bucket);
      }
    }
  }

  /// Issue 05 §1 — record ONE stroke into a tile-local picture using the
  /// exact transform/clip sequence of [_bakeTile], so it composes with the
  /// tile's base picture pixel-identically. O(1) work per commit — the tile's
  /// other strokes are never re-walked.
  ui.Picture _recordStrokeForTile(
    CanvasNodeModel node,
    TileKey k,
    int bucket,
  ) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Rect origin = k.worldRect;
    canvas.save();
    canvas.scale(bucketFactorForExponent(bucket));
    canvas.translate(-origin.left, -origin.top);
    canvas.clipRect(origin);
    _ensureAssets(<CanvasNodeModel>[node]);
    _drawNode(canvas, node, assets);
    canvas.restore();
    return recorder.endRecording();
  }

  /// Issue 05 §4 — OS memory pressure callback: trim the cache to
  /// [maxBytes] (default 64 MB) and drop every tile outside the 5×5 hot
  /// window around the last viewport. Offscreen tiles re-bake lazily
  /// through the normal get-path; visible tiles stay resident.
  void handleMemoryPressure({int maxBytes = defaultCachePressureBytes}) {
    _rebakeCount = 0;
    cache.trimTo(maxBytes);
    final Rect? vp = _lastViewport;
    if (vp == null) {
      return;
    }
    final TileKey c = TileKey.forPoint(vp.center.dx, vp.center.dy);
    final Set<TileKey> keep = <TileKey>{
      for (int dy = -2; dy <= 2; dy++)
        for (int dx = -2; dx <= 2; dx++) TileKey(c.tx + dx, c.ty + dy),
    };
    cache.invalidateOutside(keep);
    _bakedBucket.removeWhere(
      (TileKey k, int b) => !keep.contains(k) || !cache.contains(k),
    );
  }

  /// Record the tile's nodes scaled by the bucket factor `b = 2^bucket` into
  /// a `ui.Picture` (Doc 22 §4 "bake core"): translate to tile-local world
  /// coords, scale so ≈1 device px per world unit at that zoom, clip to the
  /// tile, replay nodes in layer order.
  ///
  /// Issue 02 root cause: the clip rect passed to [Canvas.clipRect] is
  /// expressed in the canvas's USER space — the same space the node
  /// geometry lives in (WORLD). `scale · translate(−origin)` maps world→device
  /// for drawing *and* clipping equally, so it never re-anchors the clip;
  /// the historic `Rect.fromLTWH(0, 0, tileSize, tileSize)` therefore cut
  /// EVERY tile picture down to the fixed world rect `(0,0,1024,1024)` (the
  /// origin tile), and committed strokes vanished outside it — "caps the
  /// content" on pen-up. Clipping with the tile's world [origin] rect is
  /// correct for every tile and every bucket (the recorded device extent
  /// becomes `[0, 1024·b]²` automatically).
  ui.Picture _bakeTile(TileKey k, int bucket) {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Rect origin = k.worldRect;
    canvas.save();
    canvas.scale(bucketFactorForExponent(bucket));
    canvas.translate(-origin.left, -origin.top);
    canvas.clipRect(origin);
    final List<CanvasNodeModel> nodes = _tree.query(origin);
    nodes.sort((CanvasNodeModel a, CanvasNodeModel b) =>
        a.layer.compareTo(b.layer));
    _ensureAssets(nodes);
    for (final CanvasNodeModel n in nodes) {
      _drawNode(canvas, n, assets);
    }
    bakeStats.strokeReplays += nodes.length;
    canvas.restore();
    return recorder.endRecording();
  }

  /// Kicks off decoding for any IMAGE node in [nodes] whose bytes are known
  /// but whose `ui.Image` is not ready yet (round-8 issue 05).
  void _ensureAssets(List<CanvasNodeModel> nodes) {
    List<String>? pending;
    for (final CanvasNodeModel n in nodes) {
      final String? ref = n.geometry.assetRef;
      if (n.kind == 'IMAGE' && ref != null && !assets.isReady(ref)) {
        (pending ??= <String>[]).add(ref);
      }
    }
    if (pending != null) {
      assets.ensureDecoded(pending);
    }
  }

  static Rect? _unionOf(List<CanvasNodeModel> nodes) {
    if (nodes.isEmpty) {
      return null;
    }
    Rect out = _rectOfNode(nodes.first);
    for (int i = 1; i < nodes.length; i++) {
      out = out.expandToInclude(_rectOfNode(nodes[i]));
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Node rasterization (Doc 22 §4 bake core / Doc 03 element semantics)
// ---------------------------------------------------------------------------

final RegExp _hexColorPattern = RegExp(r'^[0-9a-fA-F]+$');

Color _colorFrom(String hex, double opacity) {
  final String digits = hex.startsWith('#') ? hex.substring(1) : hex;
  int argb;
  if (digits.length == 6 && _hexColorPattern.hasMatch(digits)) {
    argb = 0xFF000000 | int.parse(digits, radix: 16);
  } else if (digits.length == 8 && _hexColorPattern.hasMatch(digits)) {
    argb = int.parse(digits, radix: 16);
  } else {
    argb = 0xFF1E1E1E;
  }
  final int baseAlpha = (argb >> 24) & 0xFF;
  final double o = opacity.clamp(0.0, 1.0).toDouble();
  final int alpha = (baseAlpha * o).round().clamp(0, 255).toInt();
  return Color((alpha << 24) | (argb & 0x00FFFFFF));
}

/// Paints one node. [assets] resolves `geometry.asset_ref` → decoded
/// `ui.Image`; without it an IMAGE node paints nothing (round-8 issue 05:
/// it used to paint an empty filled rect, which is why a picked photo never
/// appeared).
void _drawNode(Canvas canvas, CanvasNodeModel n, [AssetImageCache? assets]) {
  final Paint paint = _paintFor(n);
  final List<List<double>> pts = n.geometry.pts;
  switch (n.kind) {
    case 'SHAPE':
      _drawShape(canvas, n, pts, paint);
    case 'GRAPH_AXES':
      _drawGraph(canvas, n, paint);
    case 'IMAGE':
      _drawImage(canvas, n, assets);
    case 'LINE':
      _drawLine(canvas, pts, paint);
    default:
      _drawPolyline(canvas, pts, paint);
  }
}

/// IMAGE — draw the decoded bitmap stretched over the node bbox.
///
/// While the asset is still decoding this paints nothing (a placeholder box
/// would be a lie); the engine re-bakes the tile once
/// [AssetImageCache.onReady] reports it, because a tile bake is cached.
void _drawImage(Canvas canvas, CanvasNodeModel n, AssetImageCache? assets) {
  final ui.Image? image = assets?.imageOf(n.geometry.assetRef);
  final Rect rect = _rectOfNode(n);
  if (image == null) {
    return;
  }
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    ),
    rect,
    Paint()..filterQuality = FilterQuality.medium,
  );
}

void _drawShape(
  Canvas canvas,
  CanvasNodeModel n,
  List<List<double>> pts,
  Paint paint,
) {
  final String? shapeType = n.geometry.shapeType;
  if (shapeType == 'CARTESIAN_2D' || shapeType == 'NUMBER_LINE') {
    // PC `_draw_shape` dispatches graph shapes to the graph renderer even
    // under kind SHAPE (§10.3 — same conventions either way).
    _drawGraph(canvas, n, paint);
    return;
  }
  final Rect r = _rectOfNode(n);
  switch (shapeType) {
    case 'RECT':
      canvas.drawRect(r, paint);
    case 'CIRCLE':
      canvas.drawOval(r, paint);
    case 'TRIANGLE':
      _drawTriangle(canvas, pts, r, paint);
    case 'ARROW':
      _drawArrow(canvas, pts, r, paint);
    default:
      if (pts.length < 2) {
        canvas.drawRect(r, paint);
        return;
      }
      final Path path = Path()
        ..moveTo(pts[0][0], pts[0][1]);
      for (int i = 1; i < pts.length; i++) {
        if (pts[i].length < 2) {
          continue;
        }
        path.lineTo(pts[i][0], pts[i][1]);
      }
      canvas.drawPath(path, paint);
  }
}

/// LINE — always a straight segment, first anchor → last anchor;
/// intermediate anchors are ignored (Doc 02 §10.3 / PC `_draw_stroke`).
/// < 2 usable points falls back to the polyline dot/empty handling.
void _drawLine(Canvas canvas, List<List<double>> pts, Paint paint) {
  if (pts.length >= 2 && pts.first.length >= 2 && pts.last.length >= 2) {
    canvas.drawLine(
      Offset(pts.first[0], pts.first[1]),
      Offset(pts.last[0], pts.last[1]),
      paint,
    );
    return;
  }
  _drawPolyline(canvas, pts, paint);
}

/// TRIANGLE — 3 verts from `pts` (Doc 08 §4(4) / PC `triangle_points`);
/// a geometry with < 3 usable points falls back to the PC bbox triangle
/// (top-center → bottom-right → bottom-left, PC `_draw_shape`).
void _drawTriangle(
  Canvas canvas,
  List<List<double>> pts,
  Rect r,
  Paint paint,
) {
  final List<List<double>> usable =
      pts.where((List<double> p) => p.length >= 2).toList();
  final Path path = Path();
  if (usable.length >= 3) {
    path
      ..moveTo(usable[0][0], usable[0][1])
      ..lineTo(usable[1][0], usable[1][1])
      ..lineTo(usable[2][0], usable[2][1])
      ..close();
  } else {
    path
      ..moveTo((r.left + r.right) / 2, r.top)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..close();
  }
  canvas.drawPath(path, paint);
}

/// ARROW — shaft `pts[0] → pts[-1]` plus the head (Doc 08 §4(4), PC
/// `_draw_shape`): two barbs from the tip at ±0.4 rad with
/// `head = max(12, 4·strokeWidth)`. The PC export barb geometry is used
/// (rather than the viewport's apex-beyond-end filled triangles) so the
/// head stays inside the node bbox the dirty-set math covers. < 2 usable
/// points ⇒ horizontal shaft across the bbox mid-line (PC fallback); a
/// zero-length shaft draws only its round-cap dot.
void _drawArrow(
  Canvas canvas,
  List<List<double>> pts,
  Rect r,
  Paint paint,
) {
  double ax;
  double ay;
  double bx;
  double by;
  if (pts.length >= 2 && pts.first.length >= 2 && pts.last.length >= 2) {
    ax = pts.first[0];
    ay = pts.first[1];
    bx = pts.last[0];
    by = pts.last[1];
  } else {
    final double midY = (r.top + r.bottom) / 2;
    ax = r.left;
    ay = midY;
    bx = r.right;
    by = midY;
  }
  canvas.drawLine(Offset(ax, ay), Offset(bx, by), paint);
  final double dx = bx - ax;
  final double dy = by - ay;
  final double length = math.sqrt(dx * dx + dy * dy);
  if (length <= 1e-9) {
    return;
  }
  final double ang = math.atan2(dy, dx);
  final double head = math.max(12.0, paint.strokeWidth * 4.0);
  for (final double delta in const <double>[-0.4, 0.4]) {
    canvas.drawLine(
      Offset(bx, by),
      Offset(
        bx - head * math.cos(ang + delta),
        by - head * math.sin(ang + delta),
      ),
      paint,
    );
  }
}

void _drawPolyline(Canvas canvas, List<List<double>> pts, Paint paint) {
  if (pts.isEmpty) {
    return;
  }
  if (pts.length == 1 && pts[0].length >= 2) {
    canvas.drawCircle(
      Offset(pts[0][0], pts[0][1]),
      paint.strokeWidth / 2,
      paint,
    );
    return;
  }
  final Path path = Path();
  bool moved = false;
  for (final List<double> p in pts) {
    if (p.length < 2) {
      continue;
    }
    if (!moved) {
      path.moveTo(p[0], p[1]);
      moved = true;
    } else {
      path.lineTo(p[0], p[1]);
    }
  }
  if (moved) {
    canvas.drawPath(path, paint);
  }
}

/// Degenerate-config guard for huge graph ranges (PC `MAX_GRAPH_TICKS`):
/// beyond this many data-unit ticks on one axis, gridlines/ticks/labels for
/// that axis are skipped while the axes still draw.
const int _maxGraphTicks = 4096;

/// `graph_config` numeric field with fallback (Doc 03 inner keys).
double _graphNum(Object? v, double fallback) =>
    v is num ? v.toDouble() : fallback;

/// `graph_config` two-number field (`origin` / `x_range` / `y_range` /
/// `range`) with fallback; malformed values take the default.
List<double> _graphPair(Object? v, List<double> fallback) {
  if (v is List && v.length >= 2 && v[0] is num && v[1] is num) {
    return <double>[(v[0] as num).toDouble(), (v[1] as num).toDouble()];
  }
  return fallback;
}

/// GRAPH_AXES axes/grid/ticks/labels from `geometry.graphConfig`
/// (Doc 08 §4(3); the PC `_draw_graph` in `pc_agent/export/*_exporter.py`
/// is the normative reference and this mirrors it point-for-point): data y
/// is UP, world y is DOWN (`wy = oy − data·grid_step`), gridlines at every
/// integer data unit inside the ranges (CARTESIAN only), tick length
/// `0.35·grid_step` (Doc 08 §4(3)), numeric labels at major ticks when
/// `show_labels`. `NUMBER_LINE` gets a horizontal axis + ticks + labels +
/// arrowheads at both ends and NO gridlines (Doc 08 §4(3)).
///
/// Config dialects: `CARTESIAN_2D` reads Doc 03 `origin / x_range /
/// y_range / grid_step / show_labels`; `NUMBER_LINE` reads the Doc 24
/// builder keys `range / step` with `x_range / grid_step` accepted as PC
/// aliases. Unknown `shape_type` values fall back to the legacy polyline so
/// documents that predate graphs never regress their rendering.
void _drawGraph(Canvas canvas, CanvasNodeModel n, Paint paint) {
  final String? shapeType = n.geometry.shapeType;
  if (shapeType != 'CARTESIAN_2D' && shapeType != 'NUMBER_LINE') {
    _drawPolyline(canvas, n.geometry.pts, paint);
    return;
  }
  final Map<String, dynamic> cfg =
      n.geometry.graphConfig ?? const <String, dynamic>{};
  final bool numberLine = shapeType == 'NUMBER_LINE';
  final List<double> origin =
      _graphPair(cfg['origin'], const <double>[0.0, 0.0]);
  final double ox = origin[0];
  final double oy = origin[1];
  final List<double> xr =
      _graphPair(cfg['range'] ?? cfg['x_range'], const <double>[-10.0, 10.0]);
  final double xr0 = math.min(xr[0], xr[1]);
  final double xr1 = math.max(xr[0], xr[1]);
  final List<double> yr =
      _graphPair(cfg['y_range'], const <double>[-10.0, 10.0]);
  final double yr0 = math.min(yr[0], yr[1]);
  final double yr1 = math.max(yr[0], yr[1]);
  double gs = _graphNum(cfg['grid_step'] ?? cfg['step'], 25.0);
  if (!(gs > 0)) {
    gs = 25.0; // PC export fallback
  }
  final bool showLabels = cfg['show_labels'] != false;

  // World extents — PC export convention (matches the canvas page's bbox
  // math for symmetric ranges): wx = ox + data·gs, wy = oy − data·gs.
  final double wx0 = ox + xr0 * gs;
  final double wx1 = ox + xr1 * gs;
  final double wy0 = oy - yr1 * gs;
  final double wy1 = oy - yr0 * gs;

  // Integer data-unit tick sequences (one per grid_step in world units).
  final int i0 = xr0.ceil();
  final int i1 = xr1.floor();
  final int j0 = yr0.ceil();
  final int j1 = yr1.floor();
  final bool xTicksOk = i1 - i0 + 1 > 0 && i1 - i0 + 1 <= _maxGraphTicks;
  final bool yTicksOk = j1 - j0 + 1 > 0 && j1 - j0 + 1 <= _maxGraphTicks;

  // Light grid (CARTESIAN only) — PC _GRID_RGB (0.78, 0.78, 0.80).
  if (!numberLine) {
    final Path grid = Path();
    if (xTicksOk) {
      for (int i = i0; i <= i1; i++) {
        final double x = ox + i * gs;
        grid
          ..moveTo(x, wy0)
          ..lineTo(x, wy1);
      }
    }
    if (yTicksOk) {
      for (int j = j0; j <= j1; j++) {
        final double y = oy - j * gs;
        grid
          ..moveTo(wx0, y)
          ..lineTo(wx1, y);
      }
    }
    canvas.drawPath(
      grid,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = const Color(0xFFC7C7CC),
    );
  }

  // Axes through the origin, clipped to the ranges (style color/width).
  final Path axes = Path()
    ..moveTo(wx0, oy)
    ..lineTo(wx1, oy);
  if (!numberLine) {
    axes
      ..moveTo(ox, wy0)
      ..lineTo(ox, wy1);
  }
  canvas.drawPath(
    axes,
    Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, paint.strokeWidth)
      ..color = paint.color,
  );

  // Ticks: x-axis vertical downward, y-axis leftward; length 0.35·grid_step
  // (Doc 08 §4(3)), width 1.2 (PC export).
  final double tickLen = 0.35 * gs;
  final Paint tickPaint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..color = paint.color;
  if (xTicksOk) {
    final Path ticks = Path();
    for (int i = i0; i <= i1; i++) {
      final double x = ox + i * gs;
      ticks
        ..moveTo(x, oy)
        ..lineTo(x, oy + tickLen);
    }
    canvas.drawPath(ticks, tickPaint);
  }
  if (!numberLine && yTicksOk) {
    final Path ticks = Path();
    for (int j = j0; j <= j1; j++) {
      final double y = oy - j * gs;
      ticks
        ..moveTo(ox, y)
        ..lineTo(ox - tickLen, y);
    }
    canvas.drawPath(ticks, tickPaint);
  }

  // NUMBER_LINE arrowheads at both ends (Doc 08 §4(3) — mirrored triangles
  // at the axis tips, viewport proportions `0.35·step` long / `0.4×` wide).
  if (numberLine) {
    final double headLen = tickLen;
    final double headHw = tickLen * 0.4;
    final Path head = Path()
      ..moveTo(wx1, oy - headHw)
      ..lineTo(wx1, oy)
      ..lineTo(wx1 + headLen, oy)
      ..close()
      ..moveTo(wx1, oy + headHw)
      ..lineTo(wx1, oy)
      ..lineTo(wx1 + headLen, oy)
      ..close()
      ..moveTo(wx0, oy - headHw)
      ..lineTo(wx0, oy)
      ..lineTo(wx0 - headLen, oy)
      ..close()
      ..moveTo(wx0, oy + headHw)
      ..lineTo(wx0, oy)
      ..lineTo(wx0 - headLen, oy)
      ..close();
    canvas.drawPath(
      head,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.fill
        ..color = paint.color,
    );
  }

  // Numeric labels at major ticks when show_labels (Doc 08 §4(3)) — label
  // height 0.30·grid_step (viewport convention), clamped to a legible world
  // range so degenerate steps cannot explode or vanish.
  if (showLabels) {
    final double labelH = (0.30 * gs).clamp(4.0, 64.0);
    final double pad = 0.06 * gs;
    final TextStyle style = TextStyle(color: paint.color, fontSize: labelH);
    if (xTicksOk) {
      for (int i = i0; i <= i1; i++) {
        final double x = ox + i * gs;
        final TextPainter tp = TextPainter(
          text: TextSpan(text: '$i', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(x - tp.width / 2, oy + tickLen + pad - tp.height / 2),
        );
      }
    }
    if (!numberLine && yTicksOk) {
      for (int j = j0; j <= j1; j++) {
        final double y = oy - j * gs;
        final TextPainter tp = TextPainter(
          text: TextSpan(text: '$j', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(ox - tickLen - pad - tp.width, y - tp.height / 2),
        );
      }
    }
  }
}

Paint _paintFor(CanvasNodeModel n) {
  final Paint paint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = n.style.strokeWidth > 0 ? n.style.strokeWidth : 2.0
    ..blendMode = n.style.blendMode == 'MULTIPLY'
        ? BlendMode.multiply
        : BlendMode.srcOver
    ..color = _colorFrom(n.style.color, n.style.opacity);
  return paint;
}

// ---------------------------------------------------------------------------
// Rendering (Doc 22 §4 "Rendering (dual-layer widget)")
// ---------------------------------------------------------------------------

/// Inverse-transform the canvas corners back to world space so the painter
/// knows which tiles are on screen (Doc 22 "worldRectOfViewport").
Rect _worldRectOfViewport(Matrix4 viewMatrix, Size size) {
  final Matrix4 inverse = viewMatrix.clone();
  inverse.invert();
  final Float64List s = inverse.storage;
  Offset apply(Offset p) =>
      Offset(s[0] * p.dx + s[4] * p.dy + s[12], s[1] * p.dx + s[5] * p.dy + s[13]);
  final Rect out = Rect.fromPoints(
    apply(Offset.zero),
    apply(Offset(size.width, size.height)),
  );
  return out.isFinite ? out : Rect.zero;
}

/// Draw every visible tile picture under the current transform. Each picture
/// was recorded as `(world − tileOrigin) × b`, so replaying it with
/// `translate(origin) · scale(1/b)` under `viewMatrix` yields the net
/// `scale/b` correction of Doc 22 §4 — a zoom step inside one bucket needs no
/// re-bake.
void _paintTiles(
  Canvas canvas,
  Size size,
  TiledCanvasEngine engine,
  Matrix4 viewMatrix,
  double scale,
) {
  final Rect world = _worldRectOfViewport(viewMatrix, size);
  final int fallbackBucket = bucketExponentForScale(scale);
  for (final TileKey k in engine.tilesCovering(world)) {
    // Issue 05 §1: replay ≤ K+1 pictures per tile (base + stroke tail).
    final List<ui.Picture> pictures = engine.tilePictures(k);
    if (pictures.isEmpty) {
      continue;
    }
    canvas.save();
    canvas.transform(viewMatrix.storage);
    final Rect tileRect = k.worldRect;
    canvas.translate(tileRect.left, tileRect.top);
    final int baked = engine.bakedBucketOf(k) ?? fallbackBucket;
    canvas.scale(1.0 / bucketFactorForExponent(baked));
    for (final ui.Picture picture in pictures) {
      canvas.drawPicture(picture);
    }
    canvas.restore();
  }
}

/// Live/in-flight stroke layer (Doc 21 points) — never triggers rebakes.
void _paintLiveStroke(
  Canvas canvas,
  Matrix4 viewMatrix,
  List<Offset> points,
  Color color,
  double width,
  double opacity,
) {
  if (points.isEmpty) {
    return;
  }
  final Paint paint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = width > 0 ? width : 2.5
    ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0).toDouble());
  canvas.save();
  canvas.transform(viewMatrix.storage);
  if (points.length == 1) {
    canvas.drawCircle(points.first, paint.strokeWidth / 2, paint);
  } else {
    final Path path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }
  canvas.restore();
}

/// Combined `CustomPainter`: static tiles + optional foreground live stroke,
/// RepaintBoundary-friendly (Doc 22 / Wave 1.B subagent brief).
class TiledCanvasPainter extends CustomPainter {
  TiledCanvasPainter({
    required this.engine,
    required this.viewMatrix,
    required this.scale,
    this.livePoints = const <Offset>[],
    this.liveColor = const Color(0xFF1E1E1E),
    this.liveWidth = 2.5,
    this.liveOpacity = 1.0,
    super.repaint,
  }) : generation = engine.cache.generation;

  final TiledCanvasEngine engine;
  final Matrix4 viewMatrix;
  final double scale;
  final List<Offset> livePoints;
  final Color liveColor;
  final double liveWidth;
  final double liveOpacity;

  /// Tile-cache generation captured at construction (Doc 22 §4:
  /// `shouldRepaint` compares engine/tile generations).
  final int generation;

  @override
  void paint(Canvas canvas, Size size) {
    _paintTiles(canvas, size, engine, viewMatrix, scale);
    _paintLiveStroke(
      canvas,
      viewMatrix,
      livePoints,
      liveColor,
      liveWidth,
      liveOpacity,
    );
  }

  @override
  bool shouldRepaint(TiledCanvasPainter oldDelegate) =>
      oldDelegate.engine != engine ||
      oldDelegate.generation != generation ||
      oldDelegate.scale != scale ||
      !listEquals(oldDelegate.viewMatrix.storage, viewMatrix.storage) ||
      !listEquals(oldDelegate.livePoints, livePoints) ||
      oldDelegate.liveColor != liveColor ||
      oldDelegate.liveWidth != liveWidth ||
      oldDelegate.liveOpacity != liveOpacity;
}

/// Static half of the dual-layer split: only baked tiles (Doc 22 §4).
class StaticTilePainter extends CustomPainter {
  StaticTilePainter({
    required this.engine,
    required this.viewMatrix,
    required this.scale,
    super.repaint,
  }) : generation = engine.cache.generation;

  final TiledCanvasEngine engine;
  final Matrix4 viewMatrix;
  final double scale;
  final int generation;

  @override
  void paint(Canvas canvas, Size size) {
    _paintTiles(canvas, size, engine, viewMatrix, scale);
  }

  @override
  bool shouldRepaint(StaticTilePainter oldDelegate) =>
      oldDelegate.engine != engine ||
      oldDelegate.generation != generation ||
      oldDelegate.scale != scale ||
      !listEquals(oldDelegate.viewMatrix.storage, viewMatrix.storage);
}

/// Foreground half of the dual-layer split: only live strokes (Doc 21
/// `livePoints` + Doc 24 previews); never triggers tile rebakes.
class ForegroundStrokePainter extends CustomPainter {
  const ForegroundStrokePainter({
    required this.viewMatrix,
    this.points = const <Offset>[],
    this.color = const Color(0xFF1E1E1E),
    this.width = 2.5,
    this.opacity = 1.0,
    super.repaint,
  });

  final Matrix4 viewMatrix;
  final List<Offset> points;
  final Color color;
  final double width;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    _paintLiveStroke(canvas, viewMatrix, points, color, width, opacity);
  }

  @override
  bool shouldRepaint(ForegroundStrokePainter oldDelegate) =>
      !listEquals(oldDelegate.points, points) ||
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.opacity != opacity ||
      !listEquals(oldDelegate.viewMatrix.storage, viewMatrix.storage);
}

/// Light-gray pattern ink for RULED / DOT_GRID / ISO_GRID on white paper
/// (Issue 02 — light canvas, matches the Doc 26 preview proportions).
const Color kPagePatternColor = Color(0xFFD9DEE7);

/// Subtle light-gray artboard frame for bounded presets (Issue 02).
const Color kPageBorderColor = Color(0xFFC6CDD8);

/// Page/background layer beneath the static tiles (Issue 02 light canvas).
///
/// Doc 22's dual-layer view only ever replayed strokes — the canvas area had
/// no page fill, no boundary and no pattern, so the app's dark scaffold
/// showed through and the artboard was invisible. This painter renders, in
/// world space under the camera transform:
///
/// * the white paper fill ([pageColor], `background_color` — #FFFFFF),
/// * Doc 08 §4.2's feathered drop shadow + 1 px screen-scaled light-gray
///   boundary for bounded presets only (INFINITE renders neither),
/// * Doc 08 §4.1's `RULED` (32 u), `DOT_GRID` (24 u lattice) and `ISO_GRID`
///   (24 u, ±30° + vertical families) in light gray, clipped to the page
///   for bounded presets and to the visible world for INFINITE.
class CanvasBackgroundPainter extends CustomPainter {
  CanvasBackgroundPainter({
    required this.viewMatrix,
    required this.scale,
    this.boundary,
    this.style = 'BLANK',
    this.pageColor = const Color(0xFFFFFFFF),
    super.repaint,
  });

  final Matrix4 viewMatrix;
  final double scale;

  /// Bounded page rect in world units — `null` ⇒ INFINITE.
  final Rect? boundary;

  /// `BLANK | RULED | DOT_GRID | ISO_GRID` (template §3).
  final String style;

  /// Artboard `background_color` — the paper itself.
  final Color pageColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double safeScale = scale > 1e-6 ? scale : 1.0;
    final Rect world = _worldRectOfViewport(viewMatrix, size);
    if (!world.isFinite) {
      return;
    }
    canvas.save();
    canvas.transform(viewMatrix.storage);
    final Rect? page = boundary;
    if (page == null || !page.isFinite) {
      canvas.drawRect(world, Paint()..color = pageColor);
      _drawPattern(canvas, world, safeScale);
    } else {
      // Doc 08 §4.2: offset ≈ 0.02·min(w,h), feather ≈ 3× offset (≈ 3σ of
      // the gaussian blur); bounded presets only, INFINITE draws none.
      final double off = 0.02 * math.min(page.width, page.height);
      if (off > 0) {
        canvas.drawRect(
          page.translate(0, off),
          Paint()
            ..color = const Color(0x38000000)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, off),
        );
      }
      canvas.drawRect(page, Paint()..color = pageColor);
      _drawPattern(canvas, page, safeScale);
      canvas.drawRect(
        page,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0 / safeScale
          ..color = kPageBorderColor,
      );
    }
    canvas.restore();
  }

  void _drawPattern(Canvas canvas, Rect area, double safeScale) {
    if (style == 'BLANK' || area.isEmpty) {
      return;
    }
    canvas.save();
    canvas.clipRect(area);
    final Paint line = Paint()
      ..color = kPagePatternColor
      ..strokeWidth = 1.0 / safeScale; // ≈1 screen px at any zoom (fwidth)
    switch (style) {
      case 'RULED':
        {
          const double step = 32;
          final double y0 = (area.top / step).floorToDouble() * step;
          for (double y = y0; y <= area.bottom; y += step) {
            canvas.drawLine(Offset(area.left, y), Offset(area.right, y), line);
          }
        }
      case 'DOT_GRID':
        {
          const double step = 24;
          final double r = step * 0.125;
          final Paint dot = Paint()..color = kPagePatternColor;
          final double x0 = (area.left / step).floorToDouble() * step;
          final double y0 = (area.top / step).floorToDouble() * step;
          for (double x = x0; x <= area.right; x += step) {
            for (double y = y0; y <= area.bottom; y += step) {
              canvas.drawCircle(Offset(x, y), r, dot);
            }
          }
        }
      case 'ISO_GRID':
        {
          // Doc 26 §5.5 isometric families (-30°, +30°, vertical), anchored
          // to the world lattice so the grid pans with the paper.
          const double step = 24;
          final double diag = area.width + area.height;
          for (final double angle in const <double>[
            -math.pi / 6,
            math.pi / 6,
            math.pi / 2,
          ]) {
            final double ux = math.cos(angle);
            final double uy = math.sin(angle);
            final double nx = -uy;
            final double ny = ux;
            double minD = double.infinity;
            double maxD = -double.infinity;
            for (final Offset c in <Offset>[
              area.topLeft,
              area.topRight,
              area.bottomLeft,
              area.bottomRight,
            ]) {
              final double d = c.dx * nx + c.dy * ny;
              if (d < minD) minD = d;
              if (d > maxD) maxD = d;
            }
            // 1e-9 slop absorbs float32 trig rounding (e.g. sin(π/6) being
            // 0.49999999999999994 would otherwise ceil past a lattice point).
            final double d0 = ((minD / step) - 1e-9).ceilToDouble() * step;
            for (double d = d0; d <= maxD; d += step) {
              final Offset base = Offset(nx * d, ny * d);
              canvas.drawLine(
                base - Offset(ux, uy) * diag,
                base + Offset(ux, uy) * diag,
                line,
              );
            }
          }
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CanvasBackgroundPainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.pageColor != pageColor ||
      oldDelegate.boundary != boundary ||
      oldDelegate.scale != scale ||
      !listEquals(oldDelegate.viewMatrix.storage, viewMatrix.storage);
}

/// Dual-layer view (Doc 22 §4): static tiles and live strokes sit in
/// separate [RepaintBoundary] layers so stroke ticks never repaint tiles and
/// tile bakes never repaint strokes.
class TiledCanvasView extends StatefulWidget {
  const TiledCanvasView({
    super.key,
    required this.engine,
    required this.viewMatrix,
    required this.scale,
    this.livePoints = const <Offset>[],
    this.liveColor = const Color(0xFF1E1E1E),
    this.liveWidth = 2.5,
    this.liveOpacity = 1.0,
    this.repaint,
  });

  final TiledCanvasEngine engine;
  final Matrix4 viewMatrix;
  final double scale;
  final List<Offset> livePoints;
  final Color liveColor;
  final double liveWidth;
  final double liveOpacity;

  /// Typically the camera's change hook (Doc 20 `onCameraChanged`).
  final Listenable? repaint;

  @override
  State<TiledCanvasView> createState() => _TiledCanvasViewState();
}

class _TiledCanvasViewState extends State<TiledCanvasView> {
  @override
  Widget build(BuildContext context) {
    return Stack(
      // Non-directional alignment keeps the view free of a Directionality
      // dependency (pure drawing widget).
      alignment: Alignment.topLeft,
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: StaticTilePainter(
              engine: widget.engine,
              viewMatrix: widget.viewMatrix,
              scale: widget.scale,
              repaint: widget.repaint,
            ),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: ForegroundStrokePainter(
              viewMatrix: widget.viewMatrix,
              points: widget.livePoints,
              color: widget.liveColor,
              width: widget.liveWidth,
              opacity: widget.liveOpacity,
              repaint: widget.repaint,
            ),
          ),
        ),
      ],
    );
  }
}
