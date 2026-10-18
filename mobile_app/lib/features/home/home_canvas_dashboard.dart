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
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart'; // Doc 23
import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/network/vector_sync_client.dart' show uuidV4; // Doc 25

// ---------------------------------------------------------------------------
// Pure helpers (Doc 26 §5.8 — unit-testable)
// ---------------------------------------------------------------------------

/// Empty-gallery copy (Doc 26 §5.4), shared by widget and test.
const String kEmptyGalleryMessage = 'No canvases yet — tap + to start';

/// Card/menu chip labels: `A5 / A4 / Letter / Infinite` (Doc 26 §5.4).
String presetLabel(String preset) => switch (preset) {
      'LETTER' => 'Letter',
      'INFINITE' => 'Infinite',
      _ => preset,
    };

/// Gradient-placeholder tint per preset (Doc 26 §5.4 card contract).
Color presetTint(String preset) => switch (preset) {
      'A5' => const Color(0xFF4F8EF7),
      'A4' => const Color(0xFF7C5CFC),
      'LETTER' => const Color(0xFF4FBF8D),
      'INFINITE' => const Color(0xFFF2A93B),
      _ => StudioTheme.accent,
    };

/// Preset dimension table (template §3, 300-DPI world units). INFINITE ⇒
/// null dims + `infinite: true`. Unknown preset ⇒ [ArgumentError].
({double? w, double? h, bool infinite}) presetDims(String preset) =>
    switch (preset) {
      'A5' => (w: Presets.a5.w, h: Presets.a5.h, infinite: false),
      'A4' => (w: Presets.a4.$1, h: Presets.a4.$2, infinite: false),
      'LETTER' => (w: Presets.letter.$1, h: Presets.letter.$2, infinite: false),
      'INFINITE' => (w: null, h: null, infinite: true),
      _ => throw ArgumentError.value(
          preset,
          'preset',
          'Unknown artboard preset (expected A5, A4, LETTER or INFINITE)',
        ),
    };

/// Human dims label: `1748 × 2480` … `Unbounded` for INFINITE.
String presetDimsLabel(String preset) {
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
CanvasDocumentModel buildNewCanvasDocument({
  required String title,
  required String preset,
  required String background,
  String? canvasId,
  int? now,
}) {
  final ({double? w, double? h, bool infinite}) dims = presetDims(preset);
  final int ts = now ?? unixNowSeconds();
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
      backgroundStyle: background,
      backgroundColor: '#FFFFFF',
    ),
    contentBounds: <String, double>{
      'min_x': 0,
      'min_y': 0,
      'max_x': 0,
      'max_y': 0,
    },
    elements: <CanvasNodeModel>[],
  );
}

// ---------------------------------------------------------------------------
// Mini background previews (Doc 26 §5.5)
// ---------------------------------------------------------------------------

/// Mini painter for the four background templates:
/// `BLANK / RULED / DOT_GRID / ISO_GRID` (template §3).
class BackgroundPreviewPainter extends CustomPainter {
  BackgroundPreviewPainter(this.style);

  final String style;

  static const Color _line = Color(0xFF8E8E8E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (style == 'BLANK') {
      return;
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final Paint line = Paint()
      ..color = _line
      ..strokeWidth = 1;
    switch (style) {
      case 'RULED':
        final double step = size.height / 6;
        for (double y = step; y < size.height; y += step) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
      case 'DOT_GRID':
        final Paint dot = Paint()..color = _line;
        const double step = 9;
        for (double x = step / 2; x < size.width; x += step) {
          for (double y = step / 2; y < size.height; y += step) {
            canvas.drawCircle(Offset(x, y), 1.2, dot);
          }
        }
      case 'ISO_GRID':
        final double cx = size.width / 2;
        final double cy = size.height / 2;
        final double diag = size.width + size.height;
        for (final double angle in <double>[
          -math.pi / 6,
          math.pi / 6,
          math.pi / 2,
        ]) {
          final double ux = math.cos(angle);
          final double uy = math.sin(angle);
          final double px = -uy;
          final double py = ux;
          for (double k = -diag; k <= diag; k += 10) {
            final double ox = cx + px * k;
            final double oy = cy + py * k;
            canvas.drawLine(
              Offset(ox - ux * diag, oy - uy * diag),
              Offset(ox + ux * diag, oy + uy * diag),
              line,
            );
          }
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BackgroundPreviewPainter old) => old.style != style;
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
  });

  /// Canvas route hand-off (Doc 26 §4, wired in Wave 3.A).
  final void Function(CanvasDocumentModel doc) onOpenDocument;

  /// Optional [LocalDb] injection (tests). `null` ⇒ the dashboard opens —
  /// and owns — its own connection.
  final LocalDb? db;

  /// Optional `.slatesync` cache directory (tests). `null` ⇒ path_provider
  /// app-documents/SlateSync (Doc 26 §5.3).
  final String? baseDir;

  @override
  State<HomeCanvasDashboard> createState() => _HomeCanvasDashboardState();
}

class _HomeCanvasDashboardState extends State<HomeCanvasDashboard> {
  LocalDb? _db;
  bool _ownsDb = false;
  List<CanvasRecord> _records = const <CanvasRecord>[];
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _init();
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
    final List<CanvasRecord> rows;
    try {
      rows = await db.list(query: _query);
    } catch (_) {
      return; // database closed mid-flight (widget/test teardown)
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _records = rows;
    });
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

  Future<void> _createDocument(CanvasDocumentModel doc) async {
    final LocalDb? db = _db;
    if (db == null) {
      throw StateError('LocalDb is not ready yet');
    }
    final String path = await saveDocument(doc, baseDir: widget.baseDir);
    await db.insertCanvas(
      CanvasRecord(
        id: doc.canvasId,
        title: doc.title,
        preset: doc.artboard.preset,
        background: doc.artboard.backgroundStyle,
        thumbPath: '',
        filePath: path,
        updatedAt: doc.updatedAt,
      ),
    );
    await _refresh();
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
    try {
      await db.update(
        CanvasRecord(
          id: record.id,
          title: newTitle,
          preset: record.preset,
          background: record.background,
          thumbPath: record.thumbPath,
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
        await saveDocument(doc, baseDir: widget.baseDir);
      } catch (_) {
        // No cached document yet — the row rename still stands.
      }
    } finally {
      if (mounted) {
        await _refresh();
      }
    }
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
      final String path = await saveDocument(doc, baseDir: widget.baseDir);
      await _db?.update(
        CanvasRecord(
          id: doc.canvasId,
          title: doc.title,
          preset: doc.artboard.preset,
          background: doc.artboard.backgroundStyle,
          thumbPath: old.thumbPath,
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
                hintStyle: TextStyle(
                  color: StudioTheme.text.withValues(alpha: 0.5),
                ),
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

/// One thumbnail card: [title (ellipsis), preset chip, relative time] —
/// three visual children inside a single [Card] (Doc 26 §5.4, tested).
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
            Expanded(child: _thumbnail(tint)),
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
                  Container(
                    key: Key('preset_chip_${record.id}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: tint),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      presetLabel(record.preset),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tint,
                        fontSize: StudioTheme.captionSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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

  Widget _thumbnail(Color tint) {
    final String path = record.thumbPath;
    if (path.isNotEmpty && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.cover, width: double.infinity);
    }
    // Gradient placeholder tinted by preset (Doc 26 §5.4).
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            tint.withValues(alpha: 0.25),
            tint.withValues(alpha: 0.75),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        record.preset == 'INFINITE' ? Icons.all_inclusive : Icons.crop_portrait,
        size: 36,
        color: Colors.white.withValues(alpha: 0.85),
      ),
    );
  }
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

/// Preset cards (A5/A4/Letter/Infinite) + four background mini previews;
/// Create builds the seed document and hands it to [onCreate].
class NewCanvasModal extends StatefulWidget {
  const NewCanvasModal({super.key, required this.onCreate});

  /// Save + insert + refresh (dashboard) — awaited before the modal closes.
  final Future<void> Function(CanvasDocumentModel doc) onCreate;

  @override
  State<NewCanvasModal> createState() => _NewCanvasModalState();
}

class _NewCanvasModalState extends State<NewCanvasModal> {
  static const List<String> _presets = <String>[
    'A5',
    'A4',
    'LETTER',
    'INFINITE',
  ];
  static const List<String> _backgrounds = <String>[
    'BLANK',
    'RULED',
    'DOT_GRID',
    'ISO_GRID',
  ];

  String _preset = 'A4';
  String _background = 'BLANK';
  final TextEditingController _title = TextEditingController(text: 'Untitled');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final String title = _title.text.trim();
    final CanvasDocumentModel doc = buildNewCanvasDocument(
      title: title.isEmpty ? 'Untitled' : title,
      preset: _preset,
      background: _background,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(doc);
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
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String preset in _presets) _presetCard(preset),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Background',
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
                  for (final String bg in _backgrounds) _backgroundCard(bg),
                ],
              ),
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
        width: 96,
        padding: const EdgeInsets.all(8),
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
              style: const TextStyle(
                color: StudioTheme.text,
                fontSize: StudioTheme.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              presetDimsLabel(preset),
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
              child: CustomPaint(painter: BackgroundPreviewPainter(background)),
            ),
            const SizedBox(height: 4),
            Text(
              background,
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
