/// Doc 26 — Home Canvas Dashboard: searchable sqflite gallery, New Canvas
/// modal, `.slatesync` open/rename/delete flows and the non-destructive
/// Canvas Upgrade dialog wrapping Doc 23 `ArtboardManager.tryUpgrade`.
///
/// Consumes (never redefines): Doc 05 `CanvasDocumentModel`/`Artboard`/
/// `Presets`/`StudioTheme`, Doc 25 `uuidV4()`, Doc 23 `UpgradeResult` +
/// `ArtboardManager`, Doc 26 `LocalDb`/`saveDocument`/`loadDocument`.
/// Network/navigation wiring lands in Wave 3.A through
/// [HomeCanvasDashboard.onOpenDocument].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart'; // Doc 23
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/book/book_controller.dart'
    show bookPageDims; // round-13 issue 04
import 'package:mobile_app/features/canvas/image_source_popup.dart'
    show ImageSource, ImageSourcePickFn, defaultPickImageFromSource;
import 'package:mobile_app/features/home/thumbnail_cache.dart'; // round-12 issue 08
import 'package:mobile_app/features/pairing/pairing_screen.dart'; // Issue 03
import 'package:mobile_app/features/tools/tool_palette_dock.dart'
    show PickedImage; // Doc 24
import 'package:mobile_app/network/vector_sync_client.dart'
    show VectorSyncClient, uuidV4; // Doc 25

// ---------------------------------------------------------------------------
// Pure helpers (Doc 26 §5.8 — unit-testable)
// ---------------------------------------------------------------------------

/// Empty-gallery copy (Doc 26 §5.4), shared by widget and test.
const String kEmptyGalleryMessage = 'No canvases yet — tap + to start';

/// Card/menu chip labels: `A5 / A4 / Letter / Book / Infinite` (Doc 26 §5.4).
String presetLabel(String preset) => switch (preset) {
      'LETTER' => 'Letter',
      'BOOK' => 'Book',
      'INFINITE' => 'Infinite',
      _ => preset,
    };

/// Gradient-placeholder tint per preset (Doc 26 §5.4 card contract).
Color presetTint(String preset) => switch (preset) {
      'A5' => const Color(0xFF4F8EF7),
      'A4' => const Color(0xFF7C5CFC),
      'LETTER' => const Color(0xFF4FBF8D),
      // Rose: distinct from every page size, since a book is a different thing
      // rather than a different size.
      'BOOK' => const Color(0xFFE4577A),
      'INFINITE' => const Color(0xFFF2A93B),
      _ => StudioTheme.accent,
    };

/// Doc 02 §10.6 preset badge fill — a SOLID, distinct hue per preset with
/// white bold text, chosen ≥ 4.5:1 contrast so the overlaid badge stays
/// readable on the light theme (badges are UI overlays, never baked into
/// the thumbnail image).
Color presetBadgeColor(String preset) => switch (preset) {
      'A5' => const Color(0xFF1D4ED8), // blue-700
      'A4' => const Color(0xFF6D28D9), // violet-700
      'LETTER' => const Color(0xFF047857), // emerald-700
      'BOOK' => const Color(0xFFBE123C), // rose-700
      'INFINITE' => const Color(0xFFB45309), // amber-700
      _ => const Color(0xFF3F4654), // neutral slate
    };

/// Preset dimension table (template §3, 300-DPI world units). INFINITE ⇒
/// null dims + `infinite: true`. BOOK is BOUNDED and defaults to A4 — a book
/// page is paper, so it can never be unbounded. Unknown preset ⇒
/// [ArgumentError].
({double? w, double? h, bool infinite}) presetDims(String preset) =>
    switch (preset) {
      'A5' => (w: Presets.a5.w, h: Presets.a5.h, infinite: false),
      'A4' => (w: Presets.a4.$1, h: Presets.a4.$2, infinite: false),
      'LETTER' => (w: Presets.letter.$1, h: Presets.letter.$2, infinite: false),
      'BOOK' => (w: Presets.book.w, h: Presets.book.h, infinite: false),
      'INFINITE' => (w: null, h: null, infinite: true),
      _ => throw ArgumentError.value(
          preset,
          'preset',
          'Unknown artboard preset (expected A5, A4, LETTER, BOOK or INFINITE)',
        ),
    };

/// Human dims label: `1748 × 2480` … `Unbounded` for INFINITE. A book is
/// labelled by the page size it was created at, since its artboard dims are
/// only that size's default.
String presetDimsLabel(String preset) {
  if (preset == kBookPreset) {
    return 'Multi-page';
  }
  final ({double? w, double? h, bool infinite}) dims = presetDims(preset);
  if (dims.infinite) {
    return 'Unbounded';
  }
  return '${dims.w!.round()} × ${dims.h!.round()}';
}

/// Current unix time in seconds (Doc 26 timestamps are unix seconds).
int unixNowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Relative updated time from unix seconds (Doc 26 §5.8): `just now`
/// (<60 s), `N min ago`, `N h ago`, `N d ago` (<7 d), else `yyyy-MM-dd`.
String relativeTime(int now, int updatedAt) {
  final int delta = now - updatedAt;
  if (delta < 60) {
    return 'just now';
  }
  if (delta < 3600) {
    return '${delta ~/ 60} min ago';
  }
  if (delta < 86400) {
    return '${delta ~/ 3600} h ago';
  }
  if (delta < 7 * 86400) {
    return '${delta ~/ 86400} d ago';
  }
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(updatedAt * 1000);
  final String mm = d.month.toString().padLeft(2, '0');
  final String dd = d.day.toString().padLeft(2, '0');
  return '${d.year}-$mm-$dd';
}

/// Build the seed document for the New Canvas flow (Doc 26 §5.5): Doc 05
/// defaults (`content_bounds` zeros, `elements: []`,
/// `background_color: #FFFFFF`), uuid via Doc 25 `uuidV4()`.
///
/// A book (round-13 issue 04) is the same document plus `pages`; its artboard
/// is BOUNDED at [pageSize], so a book can never be created infinite. The
/// optional cover becomes an IMAGE element carrying [kBookCoverPageId], which
/// is why no extra document key is needed.
CanvasDocumentModel buildNewCanvasDocument({
  required String title,
  required String preset,
  required String background,
  double backgroundSpacing = kDefaultBackgroundSpacing,
  String? canvasId,
  int? now,
  String? pageSize,
  String? coverAssetRef,
  List<double>? coverBbox,
}) {
  final bool isBook = preset == kBookPreset;
  final ({double w, double h})? bookDims =
      isBook ? bookPageDims(pageSize ?? kDefaultBookPageSize) : null;
  final ({double? w, double? h, bool infinite}) dims = bookDims != null
      ? (w: bookDims.w, h: bookDims.h, infinite: false)
      : presetDims(preset);
  final int ts = now ?? unixNowSeconds();
  final List<CanvasNodeModel> elements = <CanvasNodeModel>[];
  final String? cover = normalizePageId(coverAssetRef);
  if (isBook && cover != null) {
    elements.add(_seedCoverElement(cover, bookDims ?? Presets.book, coverBbox));
  }
  return CanvasDocumentModel(
    canvasId: canvasId ?? uuidV4(),
    title: title,
    createdAt: ts,
    updatedAt: ts,
    artboard: Artboard(
      preset: preset,
      width: dims.w,
      height: dims.h,
      isInfinite: dims.infinite,
      backgroundStyle: normalizeBackgroundStyle(background),
      backgroundSpacing: normalizeBackgroundSpacing(backgroundSpacing),
      backgroundColor: '#FFFFFF',
    ),
    contentBounds: <String, double>{
      'min_x': 0,
      'min_y': 0,
      'max_x': 0,
      'max_y': 0,
    },
    elements: elements,
    pages: isBook
        ? <BookPageModel>[
            BookPageModel(pageId: uuidV4(), index: 0, title: bookPageTitle(0)),
          ]
        : <BookPageModel>[],
  );
}

/// Cover element for a new book: one IMAGE filling the page by default.
CanvasNodeModel _seedCoverElement(
  String assetRef,
  ({double w, double h}) page,
  List<double>? bbox,
) {
  final List<double> rect =
      bbox ?? <double>[0, 0, page.w, page.h];
  return CanvasNodeModel(
    nodeId: uuidV4(),
    kind: 'IMAGE',
    layer: 0,
    bbox: rect,
    style: NodeStyleModel(
      color: '#000000',
      strokeWidth: 0,
      opacity: 1,
      blendMode: 'SRC_OVER',
    ),
    geometry: NodeGeometryModel(pts: const <List<double>>[], assetRef: assetRef),
    pageId: kBookCoverPageId,
  );
}

// ---------------------------------------------------------------------------
// Mini background previews (Doc 26 §5.5)
// ---------------------------------------------------------------------------

/// Mini painter for the three background templates (round-9):
/// `BLANK / RULED / SQUARE_GRID`.
class BackgroundPreviewPainter extends CustomPainter {
  BackgroundPreviewPainter(this.style, {this.spacing = kDefaultBackgroundSpacing});

  final String style;

  /// Preview gap; larger values draw fewer lines so the mini card stays legible.
  final double spacing;

  static const Color _line = Color(0xFF8E8E8E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final String normalized = normalizeBackgroundStyle(style);
    if (normalized == kBackgroundBlank) {
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final Paint line = Paint()
      ..color = _line
      ..strokeWidth = 1;
    // Scale the world spacing down so the preview keeps roughly 4-12 cells.
    final double step = (size.height * spacing.clamp(1, 2000) / 192)
        .clamp(size.height / 12, size.height / 4);
    if (normalized == kBackgroundRuled) {
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    } else if (normalized == kBackgroundSquareGrid) {
      for (double y = step; y < size.height; y += step) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
      for (double x = step; x < size.width; x += step) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BackgroundPreviewPainter old) =>
      old.style != style || old.spacing != spacing;
}

// ---------------------------------------------------------------------------
// Dashboard shell
// ---------------------------------------------------------------------------

/// Home screen: gallery grid + search + New Canvas modal + card actions.
/// Hands loaded documents to [onOpenDocument] (Wave 3.A wires navigation).
class HomeCanvasDashboard extends StatefulWidget {
  const HomeCanvasDashboard({
    super.key,
    required this.onOpenDocument,
    this.db,
    this.baseDir,
    this.client,
    this.onListChanged,
    this.refreshListenable,
    this.thumbGenerator,
    this.onOpenGallery,
  });

  /// Canvas route hand-off (Doc 26 §4, wired in Wave 3.A).
  final void Function(CanvasDocumentModel doc) onOpenDocument;

  /// Optional [LocalDb] injection (tests). `null` ⇒ the dashboard opens —
  /// and owns — its own connection.
  final LocalDb? db;

  /// Optional `.slatesync` cache directory (tests). `null` ⇒ path_provider
  /// app-documents/SlateSync (Doc 26 §5.3).
  final String? baseDir;

  /// App-lifetime Doc 25 client; when provided, the app bar shows the
  /// "Connect" entry point to [PairingScreen] (Issue 03).
  final VectorSyncClient? client;

  /// Doc 02 §8.1 round-4 hook: invoked after create/rename/delete (once
  /// the row change is persisted and the grid refreshed) so the shell can
  /// push a fresh `CANVAS_LIST`. `null` ⇒ no-op (existing callers/tests).
  final VoidCallback? onListChanged;

  /// Doc 02 §9 round-5 hook: notified when an OUT-of-band store mutation
  /// may have changed the rows (bridge `hubChanged`: CANVAS_PUT applied,
  /// hub list merged, pulls done) or when the shell returns to this route.
  /// Each notification debounces into a single `_refresh()` after 100 ms so
  /// bursts coalesce. `null` ⇒ no-op (existing callers/tests compile
  /// untouched).
  final Listenable? refreshListenable;

  /// Doc 02 §10.6 thumbnail seam (additive, default `null`): forwarded to
  /// `saveDocument` on create/rename/upgrade and to the lazy gallery
  /// backfill. `null` ⇒ the frozen `saveDocThumbnail` renderer.
  final ThumbGenerator? thumbGenerator;

  /// Round-13 §03 additive hook: when provided, the app bar shows the image
  /// library entry point. `null` ⇒ no button, so existing callers and tests
  /// compile and render exactly as before.
  final VoidCallback? onOpenGallery;

  @override
  State<HomeCanvasDashboard> createState() => _HomeCanvasDashboardState();
}

class _HomeCanvasDashboardState extends State<HomeCanvasDashboard> {
  LocalDb? _db;
  bool _ownsDb = false;
  List<CanvasRecord> _records = const <CanvasRecord>[];
  String _query = '';
  Timer? _debounce;
  Timer? _refreshDebounce;
  Listenable? _attachedRefresh;

  /// Monotonic read token: only the NEWEST initiated `_refresh` may publish
  /// its rows, so a slow read started earlier can never overwrite newer
  /// titles with a stale snapshot (rename vs. backfill re-read race).
  int _refreshEpoch = 0;

  // Doc 02 §10.6 lazy thumbnail backfill — a tiny id queue drained by ONE
  // sequential async chain (microtask yields, no timers), so first paint is
  // never blocked and bursts of refreshes coalesce instead of racing.
  final Set<String> _thumbQueue = <String>{};
  bool _thumbDraining = false;

  @override
  void initState() {
    super.initState();
    _attachRefreshListenable();
    _init();
  }

  @override
  void didUpdateWidget(covariant HomeCanvasDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.refreshListenable, widget.refreshListenable)) {
      _detachRefreshListenable();
      _attachRefreshListenable();
    }
  }

  void _attachRefreshListenable() {
    _attachedRefresh = widget.refreshListenable;
    _attachedRefresh?.addListener(_onRefreshRequested);
  }

  void _detachRefreshListenable() {
    _attachedRefresh?.removeListener(_onRefreshRequested);
    _attachedRefresh = null;
  }

  /// Doc 02 §9: coalesce bursty hub notifications into ONE re-read.
  void _onRefreshRequested() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) {
        return;
      }
      unawaited(_refresh());
    });
  }

  Future<void> _init() async {
    final LocalDb? injected = widget.db;
    if (injected != null) {
      _db = injected;
    } else {
      _db = await LocalDb.open();
      _ownsDb = true;
    }
    await _refresh();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _refreshDebounce?.cancel();
    _detachRefreshListenable();
    if (_ownsDb) {
      unawaited(_db?.close());
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    final LocalDb? db = _db;
    if (db == null) {
      return;
    }
    final int epoch = ++_refreshEpoch;
    final List<CanvasRecord> rows;
    try {
      rows = await db.list(query: _query);
    } catch (_) {
      return; // database closed mid-flight (widget/test teardown)
    }
    if (!mounted || epoch != _refreshEpoch) {
      return; // superseded by a newer read — it owns the published state
    }
    setState(() {
      _records = rows;
    });
    _queueThumbBackfill(rows);
  }

  // ----- Doc 02 §10.6 thumbnail backfill -----------------------------------

  /// Queue every listed row whose `thumb_path` is missing (or whose file
  /// vanished) for the sequential backfill drain. Additive: never throws,
  /// never blocks the list render that just happened.
  void _queueThumbBackfill(List<CanvasRecord> rows) {
    if (_db == null) {
      return;
    }
    for (final CanvasRecord row in rows) {
      if (row.thumbPath.isEmpty || !File(row.thumbPath).existsSync()) {
        _thumbQueue.add(row.id);
      }
    }
    if (_thumbQueue.isNotEmpty && !_thumbDraining) {
      unawaited(_drainThumbQueue());
    }
  }

  /// Drain queued ids one at a time: `loadDocument` → `ensureThumbnail`
  /// (fake-injectable via [HomeCanvasDashboard.thumbGenerator]) → row
  /// update. Sequential with microtask yields between items — cooperative
  /// and timer-free, so it never starves frames or leaks pending timers
  /// into widget tests. Failures (missing/corrupt archive, headless
  /// rasterizer) keep the placeholder and retry on a later refresh.
  Future<void> _drainThumbQueue() async {
    if (_thumbDraining) {
      return;
    }
    _thumbDraining = true;
    try {
      while (mounted && _thumbQueue.isNotEmpty) {
        final String id = _thumbQueue.first;
        await Future<void>.microtask(() {}); // yield — let the frame land
        try {
          final LocalDb? db = _db;
          final CanvasRecord? row = db == null ? null : await db.get(id);
          if (row == null ||
              (row.thumbPath.isNotEmpty &&
                  File(row.thumbPath).existsSync())) {
            continue; // deleted meanwhile — or filled by another writer
          }
          final CanvasDocumentModel doc = await loadDocument(
            id,
            baseDir: widget.baseDir,
          );
          final String thumbPath = await ensureThumbnail(
            doc,
            baseDir: widget.baseDir,
            generator: widget.thumbGenerator,
          );
          // Single-column patch: never clobber a title/preset that changed
          // while this (potentially slow) render was in flight.
          await db!.setThumbPath(id, thumbPath);
          if (mounted) {
            // Patch against the CURRENT in-memory list (never the drain's
            // earlier read), and only thumb_path — a fresh title published
            // meanwhile survives, and no out-of-band row re-read escapes
            // this drain (home only re-reads on explicit triggers).
            setState(() {
              _records = <CanvasRecord>[
                for (final CanvasRecord r in _records)
                  r.id == id
                      ? CanvasRecord(
                          id: r.id,
                          title: r.title,
                          preset: r.preset,
                          background: r.background,
                          thumbPath: thumbPath,
                          filePath: r.filePath,
                          updatedAt: r.updatedAt,
                        )
                      : r,
              ];
            });
          }
        } catch (_) {
          // Best-effort: leave the neutral placeholder in place.
        } finally {
          _thumbQueue.remove(id);
        }
      }
    } finally {
      _thumbDraining = false;
      if (mounted && _thumbQueue.isNotEmpty) {
        unawaited(_drainThumbQueue()); // refreshed mid-drain — pick it up
      }
    }
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _query = value;
      });
      unawaited(_refresh());
    });
  }

  // ----- New canvas --------------------------------------------------------

  Future<void> _newCanvas() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) =>
          NewCanvasModal(onCreate: _createDocument),
    );
  }

  // ----- Pairing (Issue 03) ------------------------------------------------

  void _openPairing() {
    final VectorSyncClient? client = widget.client;
    if (client == null) {
      return;
    }
    // This context sits inside the `MaterialApp` home route, below its
    // Navigator, so `Navigator.of(context)` is valid here.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => PairingScreen(client: client),
      ),
    );
  }

  Future<void> _createDocument(
    CanvasDocumentModel doc, {
    Map<String, List<int>>? assets,
  }) async {
    final LocalDb? db = _db;
    if (db == null) {
      throw StateError('LocalDb is not ready yet');
    }
    // Doc 02 §10.6: saveDocument writes the archive AND the thumbnail PNG;
    // the row stores the canonical thumb path (refreshed by every re-save).
    final String path = await saveDocument(
      doc,
      baseDir: widget.baseDir,
      assets: assets,
      thumbGenerator: widget.thumbGenerator,
    );
    final String thumbPath = await thumbFilePath(
      doc.canvasId,
      baseDir: widget.baseDir,
    );
    await db.insertCanvas(
      CanvasRecord(
        id: doc.canvasId,
        title: doc.title,
        preset: doc.artboard.preset,
        background: doc.artboard.backgroundStyle,
        thumbPath: thumbPath,
        filePath: path,
        updatedAt: doc.updatedAt,
      ),
    );
    await _refresh();
    widget.onListChanged?.call(); // Doc 02 §8.1 — push CANVAS_LIST
  }

  // ----- Open / rename / delete / upgrade ---------------------------------

  Future<void> _open(CanvasRecord record) async {
    try {
      final CanvasDocumentModel doc = await loadDocument(
        record.id,
        baseDir: widget.baseDir,
      );
      if (!mounted) {
        return;
      }
      widget.onOpenDocument(doc);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open canvas: $e')),
      );
    }
  }

  Future<void> _onMenuSelected(CanvasRecord record, String value) async {
    switch (value) {
      case 'rename':
        await _renamePrompt(record);
      case 'delete':
        await _delete(record);
      case 'upgrade':
        await _upgradePrompt(record);
    }
  }

  Future<void> _renamePrompt(CanvasRecord record) async {
    final String? newTitle = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _RenameDialog(initialTitle: record.title),
    );
    final LocalDb? db = _db;
    if (newTitle == null || db == null || !mounted) {
      return;
    }
    final int now = unixNowSeconds();
    // Doc 02 §10.6: rename re-saves ⇒ thumbnail refreshes at the canonical
    // path, which the row records.
    final String thumbPath = await thumbFilePath(
      record.id,
      baseDir: widget.baseDir,
    );
    try {
      await db.update(
        CanvasRecord(
          id: record.id,
          title: newTitle,
          preset: record.preset,
          background: record.background,
          thumbPath: thumbPath,
          filePath: record.filePath,
          updatedAt: now,
        ),
      );
      try {
        final CanvasDocumentModel doc = await loadDocument(
          record.id,
          baseDir: widget.baseDir,
        );
        doc.title = newTitle;
        doc.updatedAt = now;
        await saveDocument(
          doc,
          baseDir: widget.baseDir,
          thumbGenerator: widget.thumbGenerator,
        );
      } catch (_) {
        // No cached document yet — the row rename still stands.
      }
    } finally {
      if (mounted) {
        await _refresh();
      }
    }
    widget.onListChanged?.call(); // Doc 02 §8.1 — push CANVAS_LIST
  }

  Future<void> _delete(CanvasRecord record) async {
    final LocalDb? db = _db;
    if (db == null) {
      return;
    }
    await db.delete(record.id);
    try {
      final String path = record.filePath.isNotEmpty
          ? record.filePath
          : await slatesyncFilePath(record.id, baseDir: widget.baseDir);
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cache cleanup; the row is already gone.
    }
    if (mounted) {
      await _refresh();
    }
    widget.onListChanged?.call(); // Doc 02 §8.1 — push CANVAS_LIST
  }

  Future<void> _upgradePrompt(CanvasRecord record) async {
    final CanvasDocumentModel doc;
    try {
      doc = await loadDocument(record.id, baseDir: widget.baseDir);
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open canvas: $e')),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final ArtboardManager manager = ArtboardManager(
      preset: doc.artboard.preset,
    );
    final Map<String, double> cb = doc.contentBounds;
    manager.noteContent(
      Rect.fromLTRB(cb['min_x']!, cb['min_y']!, cb['max_x']!, cb['max_y']!),
    );
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => UpgradeDialog(
        manager: manager,
        onSaved: (Artboard newArtboard) {
          doc.artboard = newArtboard;
          doc.updatedAt = unixNowSeconds();
          unawaited(_persistUpgrade(doc, record));
        },
      ),
    );
    if (mounted) {
      await _refresh();
    }
  }

  Future<void> _persistUpgrade(
    CanvasDocumentModel doc,
    CanvasRecord old,
  ) async {
    try {
      // Doc 02 §10.6: the upgrade re-save refreshes the thumbnail at the
      // canonical path; the row records it (was [CanvasRecord.thumbPath]).
      final String path = await saveDocument(
        doc,
        baseDir: widget.baseDir,
        thumbGenerator: widget.thumbGenerator,
      );
      final String thumbPath = await thumbFilePath(
        doc.canvasId,
        baseDir: widget.baseDir,
      );
      await _db?.update(
        CanvasRecord(
          id: doc.canvasId,
          title: doc.title,
          preset: doc.artboard.preset,
          background: doc.artboard.backgroundStyle,
          thumbPath: thumbPath,
          filePath: path,
          updatedAt: doc.updatedAt,
        ),
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save canvas size: $e')),
        );
      }
    }
  }

  // ----- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('home_dashboard'),
      backgroundColor: StudioTheme.bg,
      appBar: AppBar(
        backgroundColor: StudioTheme.surface,
        title: const Text('SlateSync', key: Key('dashboard_title')),
        actions: <Widget>[
          if (widget.client != null)
            IconButton(
              key: const Key('home-connect'),
              tooltip: 'Connect to SlateSync PC',
              onPressed: _openPairing,
              icon: const Icon(Icons.link),
            ),
          // Round-13 §03 — the image library lives on the PC, but it is a
          // first-class place to start a canvas from, so its entry point sits
          // with the other top-level actions rather than behind a menu.
          if (widget.onOpenGallery != null)
            IconButton(
              key: const Key('home-open-gallery'),
              tooltip: 'Image library',
              onPressed: widget.onOpenGallery,
              icon: const Icon(Icons.photo_library_outlined),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              key: const Key('canvas_search'),
              onChanged: _onQueryChanged,
              style: const TextStyle(color: StudioTheme.text),
              decoration: InputDecoration(
                hintText: 'Search canvases',
                hintStyle: const TextStyle(color: StudioTheme.subText),
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: StudioTheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _records.isEmpty ? const _EmptyGallery() : _buildGrid(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('new_canvas_fab'),
        onPressed: _newCanvas,
        backgroundColor: StudioTheme.accent,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      key: const Key('canvas_grid'),
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: _records.length,
      itemBuilder: (BuildContext context, int index) {
        final CanvasRecord record = _records[index];
        return _CanvasGridCard(
          record: record,
          nowSeconds: unixNowSeconds(),
          onTap: () => _open(record),
          onMenu: (String value) => _onMenuSelected(record, value),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Gallery widgets (Doc 26 §5.4 card layout contract)
// ---------------------------------------------------------------------------

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.dashboard_customize_outlined,
            size: 56,
            color: StudioTheme.text.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          const Text(
            kEmptyGalleryMessage,
            key: Key('empty_gallery'),
            style: TextStyle(
              color: StudioTheme.text,
              fontSize: StudioTheme.bodySize,
            ),
          ),
        ],
      ),
    );
  }
}

/// One gallery card (Doc 02 §10.6 rework): thumbnail image (fade-in over a
/// neutral placeholder) with the preset badge chip OVERLAID on it, plus
/// title (ellipsis) and relative updated time below.
class _CanvasGridCard extends StatelessWidget {
  const _CanvasGridCard({
    required this.record,
    required this.nowSeconds,
    required this.onTap,
    required this.onMenu,
  });

  final CanvasRecord record;
  final int nowSeconds;
  final VoidCallback onTap;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final Color tint = presetTint(record.preset);
    return Card(
      key: Key('canvas_card_${record.id}'),
      color: StudioTheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
        side: BorderSide(color: tint.withValues(alpha: 0.35)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: _thumbnailArea()),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Text(
                record.title,
                key: Key('card_title_${record.id}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: StudioTheme.text,
                  fontSize: StudioTheme.bodySize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  Flexible(
                    child: Text(
                      relativeTime(nowSeconds, record.updatedAt),
                      key: Key('card_time_${record.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        color: StudioTheme.text.withValues(alpha: 0.6),
                        fontSize: StudioTheme.captionSize,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: Key('card_menu_${record.id}'),
                    padding: EdgeInsets.zero,
                    onSelected: onMenu,
                    itemBuilder: (BuildContext context) =>
                        const <PopupMenuItem<String>>[
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('Rename'),
                          ),
                          PopupMenuItem<String>(
                            value: 'upgrade',
                            child: Text('Canvas size'),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('Delete'),
                          ),
                        ],
                    icon: Icon(
                      Icons.more_vert,
                      size: 18,
                      color: StudioTheme.text.withValues(alpha: 0.6),
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

  /// Doc 02 §10.6 gallery thumbnail: neutral placeholder UNDERNEATH (visible
  /// while the file decodes/loads or when no thumb exists yet), the fade-in
  /// [Image.file] on top, and the preset badge chip overlaid top-left.
  Widget _thumbnailArea() {
    final String path = record.thumbPath;
    // Round-12 issue 08: the PNG is rewritten on every save, but `Image.file`
    // caches by PATH, so the old decode was served forever. `refreshThumbnail`
    // evicts the stale FileImage and returns a version token that is folded
    // into the widget key, forcing the reload.
    final String version = refreshThumbnail(path);
    final bool hasThumb = version != '0';
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _placeholder(),
        if (hasThumb)
          Positioned.fill(
            child: Image.file(
              File(path),
              key: thumbnailKey(record.id, version),
              fit: BoxFit.cover,
              frameBuilder: (
                BuildContext context,
                Widget child,
                int? frame,
                bool wasSyncLoaded,
              ) {
                if (wasSyncLoaded) {
                  return child;
                }
                return AnimatedOpacity(
                  opacity: frame == null ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: child,
                );
              },
              errorBuilder: (
                BuildContext context,
                Object error,
                StackTrace? stackTrace,
              ) =>
                  const SizedBox.shrink(), // placeholder below stays visible
            ),
          ),
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            key: Key('preset_chip_${record.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: presetBadgeColor(record.preset),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              record.preset, // A5 / A4 / LETTER / INFINITE — overlay label
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: StudioTheme.captionSize,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Neutral (preset-agnostic gray) placeholder shown while the thumbnail
  /// loads or when it has not been generated yet.
  Widget _placeholder() => Container(
        key: Key('card_placeholder_${record.id}'),
        color: const Color(0xFFE4E7EC),
        alignment: Alignment.center,
        child: Icon(
          record.preset == 'INFINITE' ? Icons.all_inclusive : Icons.crop_portrait,
          size: 32,
          color: const Color(0xFF9AA3B2),
        ),
      );
}

// ---------------------------------------------------------------------------
// New Canvas modal (Doc 26 §5.5)
// ---------------------------------------------------------------------------

/// Rename prompt — owns its [TextEditingController] so disposal happens
/// with the route (after the pop transition), never mid-animation.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename canvas'),
      content: TextField(
        key: const Key('rename_field'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Title'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('rename_confirm'),
          onPressed: () {
            final String v = _controller.text.trim();
            Navigator.of(context).pop(v.isEmpty ? null : v);
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// Receives the seeded document, plus any asset bytes it references so the
/// archive can embed them (a book's cover is chosen before the document exists,
/// so its bytes cannot be re-read from disk yet).
typedef NewCanvasCreate = Future<void> Function(
  CanvasDocumentModel doc, {
  Map<String, List<int>>? assets,
});

/// Preset cards (A5/A4/Letter/Book/Infinite) + three background mini previews;
/// Create builds the seed document and hands it to [onCreate].
class NewCanvasModal extends StatefulWidget {
  const NewCanvasModal({
    super.key,
    required this.onCreate,
    this.coverPicker,
  });

  /// Save + insert + refresh (dashboard) — awaited before the modal closes.
  final NewCanvasCreate onCreate;

  /// Injectable cover picker (tests); `null` ⇒ the real gallery picker.
  final ImageSourcePickFn? coverPicker;

  @override
  State<NewCanvasModal> createState() => _NewCanvasModalState();
}

class _NewCanvasModalState extends State<NewCanvasModal> {
  static const List<String> _presets = <String>[
    'A5',
    'A4',
    'LETTER',
    kBookPreset,
    'INFINITE',
  ];
  static const List<String> _backgrounds = kBackgroundStyles;

  String _preset = 'A4';
  String _background = kBackgroundBlank;
  double _spacing = kDefaultBackgroundSpacing;
  String _pageSize = kDefaultBookPageSize;

  /// Chosen cover, held as bytes until the document exists to attach it to.
  PickedImage? _cover;

  final TextEditingController _title = TextEditingController(text: 'Untitled');
  bool _busy = false;
  String? _error;

  bool get _isBook => _preset == kBookPreset;

  /// `assets/cover.<ext>` — the ref the cover element points at, matching the
  /// `assets/*` convention `saveDocument` embeds.
  String? get _coverRef {
    final PickedImage? cover = _cover;
    if (cover == null) {
      return null;
    }
    final String name = cover.filename.toLowerCase();
    final int dot = name.lastIndexOf('.');
    final String ext = dot > 0 ? name.substring(dot + 1) : 'png';
    return 'assets/cover.$ext';
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final ImageSourcePickFn pick =
        widget.coverPicker ?? defaultPickImageFromSource;
    final PickedImage? picked = await pick(ImageSource.gallery);
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _cover = picked);
  }

  Future<void> _create() async {
    final String title = _title.text.trim();
    final CanvasDocumentModel doc = buildNewCanvasDocument(
      title: title.isEmpty ? 'Untitled' : title,
      preset: _preset,
      background: _background,
      backgroundSpacing: _spacing,
      pageSize: _isBook ? _pageSize : null,
      coverAssetRef: _isBook ? _coverRef : null,
    );
    final Map<String, List<int>>? assets = _coverRef == null
        ? null
        : <String, List<int>>{_coverRef!: _cover!.bytes};
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(doc, assets: assets);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save canvas: $e';
        });
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New canvas'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                key: const Key('new_title_field'),
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Size',
                style: TextStyle(
                  color: StudioTheme.text,
                  fontSize: StudioTheme.captionSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String preset in _presets) _presetCard(preset),
                ],
              ),
              if (_isBook) ...<Widget>[
                const SizedBox(height: 16),
                const Text(
                  'Page size',
                  style: TextStyle(
                    color: StudioTheme.text,
                    fontSize: StudioTheme.captionSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String size in kBookPageSizes)
                      _pageSizeChip(size),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const Key('new_book_cover'),
                      onPressed: _busy ? null : _pickCover,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: Text(
                        _cover == null ? 'Add cover image' : 'Change cover',
                      ),
                    ),
                    if (_cover != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _cover!.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: StudioTheme.subText,
                            fontSize: StudioTheme.captionSize,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('new_book_cover_clear'),
                        tooltip: 'Remove cover',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _busy
                            ? null
                            : () => setState(() => _cover = null),
                      ),
                    ],
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'The cover is the gallery thumbnail; without one the '
                    'first page is shown.',
                    style: TextStyle(
                      color: StudioTheme.subText,
                      fontSize: StudioTheme.captionSize,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                _isBook ? 'Page background' : 'Background',
                style: const TextStyle(
                  color: StudioTheme.text,
                  fontSize: StudioTheme.captionSize,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String bg in _backgrounds) _backgroundCard(bg),
                ],
              ),
              if (_background != kBackgroundBlank) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  _background == kBackgroundRuled
                      ? 'Rule spacing'
                      : 'Square size',
                  style: const TextStyle(
                    color: StudioTheme.text,
                    fontSize: StudioTheme.captionSize,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final double preset in kBackgroundSpacingPresets)
                      _spacingChip(preset),
                  ],
                ),
              ],
              if (_error != null)
                Padding(
                  key: const Key('new_canvas_error'),
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: StudioTheme.danger),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('create_canvas'),
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Widget _presetCard(String preset) {
    final bool selected = preset == _preset;
    final Color tint = presetTint(preset);
    return InkWell(
      key: Key('new_preset_$preset'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => setState(() => _preset = preset),
      child: Container(
        width: 76,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected ? tint.withValues(alpha: 0.18) : StudioTheme.surface,
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(
            color: selected ? tint : StudioTheme.text.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              presetLabel(preset),
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
              presetDimsLabel(preset),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: StudioTheme.text.withValues(alpha: 0.6),
                fontSize: StudioTheme.captionSize,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backgroundCard(String background) {
    final bool selected = background == _background;
    return InkWell(
      key: Key('new_background_$background'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => setState(() => _background = background),
      child: Container(
        width: 92,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(
            color: selected
                ? StudioTheme.accent
                : StudioTheme.text.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: <Widget>[
            SizedBox(
              width: 78,
              height: 56,
              child: CustomPaint(
                painter: BackgroundPreviewPainter(
                  background,
                  spacing: _spacing,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              backgroundLabel(background),
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected
                    ? StudioTheme.accent
                    : StudioTheme.text.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageSizeChip(String size) {
    final bool selected = size == _pageSize;
    final ({double w, double h})? dims = bookPageDims(size);
    return InkWell(
      key: Key('new_book_page_size_$size'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => setState(() => _pageSize = size),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? StudioTheme.accent.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(
            color: selected
                ? StudioTheme.accent
                : StudioTheme.text.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              presetLabel(size),
              style: TextStyle(
                fontSize: StudioTheme.bodySize,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected
                    ? StudioTheme.accent
                    : StudioTheme.text.withValues(alpha: 0.8),
              ),
            ),
            if (dims != null)
              Text(
                '${dims.w.round()} × ${dims.h.round()}',
                style: const TextStyle(
                  fontSize: 10,
                  color: StudioTheme.subText,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _spacingChip(double preset) {
    final bool selected = preset == _spacing;
    return InkWell(
      key: Key('new_spacing_${preset.toInt()}'),
      borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
      onTap: () => setState(() => _spacing = preset),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? StudioTheme.accent.withValues(alpha: 0.18) : null,
          borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
          border: Border.all(
            color: selected
                ? StudioTheme.accent
                : StudioTheme.text.withValues(alpha: 0.2),
            width: selected ? 2 : 1,
          ),
        ),
        child: Text(
          '${preset.toInt()} px',
          style: TextStyle(
            fontSize: StudioTheme.bodySize,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected
                ? StudioTheme.accent
                : StudioTheme.text.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canvas Upgrade dialog (Doc 26 §5.7, Doc 23 §4.4 rule)
// ---------------------------------------------------------------------------

/// Wraps an injected [ArtboardManager] (faked in tests): preset chips call
/// `tryUpgrade`; blocked ⇒ warning banner from `reasonKey` and the dialog
/// stays open; allowed ⇒ `onSaved(newArtboard)` then pop — the caller
/// re-saves the document.
class UpgradeDialog extends StatefulWidget {
  const UpgradeDialog({
    super.key,
    required this.manager,
    required this.onSaved,
  });

  /// Injected — faked in tests (Doc 26 §4).
  final ArtboardManager manager;

  /// Re-save document on allowed (Doc 26 §4).
  final void Function(Artboard newArtboard) onSaved;

  /// Human-readable mapping for the two frozen reason keys (Doc 23).
  static String reasonMessage(String? reasonKey) => switch (reasonKey) {
        ReasonKeys.clipsContent => 'New size would crop existing content',
        ReasonKeys.invalidTarget => 'Invalid target size',
        _ => 'Canvas size could not be changed',
      };

  @override
  State<UpgradeDialog> createState() => _UpgradeDialogState();
}

class _UpgradeDialogState extends State<UpgradeDialog> {
  static const List<(String, String)> _targets = <(String, String)>[
    ('A5', 'A5'),
    ('A4', 'A4'),
    ('LETTER', 'Letter'),
    ('INFINITE', 'Infinite'),
  ];

  String? _reasonKey;

  void _tryUpgrade(String target) {
    final UpgradeResult result = widget.manager.tryUpgrade(target);
    if (result.allowed) {
      widget.onSaved(widget.manager.current);
      Navigator.of(context).pop();
    } else {
      setState(() {
        _reasonKey = result.reasonKey;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Canvas size', key: Key('upgrade_title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Current size: ${presetLabel(widget.manager.current.preset)}',
            key: const Key('upgrade_current'),
            style: const TextStyle(
              color: StudioTheme.text,
              fontSize: StudioTheme.bodySize,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (String key, String label) in _targets)
                ActionChip(
                  key: Key('upgrade_target_$key'),
                  label: Text(label),
                  onPressed: () => _tryUpgrade(key),
                ),
            ],
          ),
          if (_reasonKey != null)
            Container(
              key: const Key('upgrade_warning'),
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: StudioTheme.danger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: StudioTheme.danger),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: StudioTheme.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      UpgradeDialog.reasonMessage(_reasonKey),
                      style: const TextStyle(color: StudioTheme.danger),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('upgrade_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
