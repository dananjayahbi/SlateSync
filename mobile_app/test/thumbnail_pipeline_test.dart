/// Issue 07 round-6 (Doc 02 §10.6) — save-time thumbnail pipeline:
/// `saveDocument` writes `<base>/thumbs/<canvas_id>.png` after the
/// `.slatesync` archive (real renderer ⇒ PNG magic bytes), the dashboard
/// create/rename/upgrade paths persist the canonical `thumb_path` in the
/// `canvases` row (`LocalDb.thumbPath`), create→open→back-save refreshes
/// the thumbnail, and the gallery's lazy backfill fills legacy missing
/// thumbs EXACTLY ONCE through the injected `thumbGenerator` seam.
///
/// All scratch state lives under `test/.thumbnail_pipeline_tmp/` inside the
/// package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/canvas_engine/thumbnail_renderer.dart'
    show renderDocThumbnail;
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';

/// PNG signature (Doc 02 §10.6 — thumbnails are real PNG files).
const List<int> kPngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.thumbnail_pipeline_tmp');
  int counter = 0;
  late Directory tmp;
  late String cacheDir;
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    tmp = Directory(
      '${root.path}/${DateTime.now().microsecondsSinceEpoch}_$counter',
    );
    counter += 1;
    tmp.createSync(recursive: true);
    cacheDir = '${tmp.path}/SlateSync';
    openDbs.clear();
  });

  tearDown(() async {
    for (final LocalDb db in openDbs) {
      try {
        await db.close();
      } catch (_) {
        // already closed
      }
    }
    openDbs.clear();
    try {
      if (tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort — never fail a test on cleanup
    }
  });

  tearDownAll(() {
    try {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort
    }
  });

  Future<LocalDb> openDb(String name) async {
    final LocalDb db = await LocalDb.open(
      pathOverride: '${tmp.path}/$name.db',
    );
    openDbs.add(db);
    return db;
  }

  Future<LocalDb> openDbInTester(WidgetTester tester, String name) async {
    final LocalDb? db = await tester.runAsync(() => openDb(name));
    return db!;
  }

  CanvasRecord record(
    String id,
    String title,
    int updatedAt, {
    String preset = 'A4',
    String background = 'BLANK',
    String thumbPath = '',
  }) =>
      CanvasRecord(
        id: id,
        title: title,
        preset: preset,
        background: background,
        thumbPath: thumbPath,
        filePath: '$cacheDir/$id.slatesync',
        updatedAt: updatedAt,
      );

  /// Real event-loop windows interleaved with frame pumps — `testWidgets`
  /// runs on a fake clock, so sqflite/file futures parked from the fake
  /// zone only progress while `runAsync` gives them real time.
  Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Real-IO aware settle for multi-step chains (save/insert/refresh).
  Future<void> settleIo(WidgetTester tester, {int rounds = 16}) async {
    await flushReal(tester, rounds: rounds);
    await tester.pump(const Duration(milliseconds: 500));
    await flushReal(tester, rounds: 2);
  }

  /// Pump real-event-loop windows until [condition] holds (safety cap — the
  /// assertion afterwards then fails with a clear message). Async variant:
  /// [condition] itself gets real windows (db reads) while polling.
  Future<void> waitUntil(
    WidgetTester tester,
    Future<bool> Function() condition, {
    int maxRounds = 40,
  }) async {
    for (int i = 0; i < maxRounds; i++) {
      if (await condition()) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    required LocalDb db,
    ThumbGenerator? thumbGenerator,
    Listenable? refreshListenable,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeCanvasDashboard(
          onOpenDocument: (_) {},
          db: db,
          baseDir: cacheDir,
          thumbGenerator: thumbGenerator,
          refreshListenable: refreshListenable,
        ),
      ),
    );
    await flushReal(tester);
  }

  // -------------------------------------------------------------------------
  // Save-time generation (Doc 02 §10.6)
  // -------------------------------------------------------------------------

  group('save-time thumbnail (Doc 02 §10.6)', () {
    test(
        'saveDocument writes archive + PNG (magic bytes) at the canonical '
        'thumbs path; LocalDb.thumbPath stores/returns it', () async {
      final LocalDb db = await openDb('save_png');
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Ünicode — 研究ノート ✨',
        preset: 'A5',
        background: 'RULED',
        canvasId: 'png-1',
        now: 1000,
      );

      final String zip = await saveDocument(doc, baseDir: cacheDir);
      expect(File(zip).existsSync(), isTrue);
      expect(zip, '$cacheDir/png-1.slatesync');

      // Doc 02 §10.6: canonical `<base>/thumbs/<canvas_id>.png`, real PNG.
      final String thumb = await thumbFilePath('png-1', baseDir: cacheDir);
      expect(thumb, '$cacheDir/thumbs/png-1.png');
      final File png = File(thumb);
      expect(png.existsSync(), isTrue, reason: 'save must write a thumbnail');
      final List<int> bytes = await png.readAsBytes();
      expect(bytes.length, greaterThan(8));
      expect(bytes.sublist(0, 8), kPngMagic, reason: 'PNG signature');

      // The row stores the path (dashboard create path), thumbPath API.
      await db.insertCanvas(
        CanvasRecord(
          id: 'png-1',
          title: doc.title,
          preset: doc.artboard.preset,
          background: doc.artboard.backgroundStyle,
          thumbPath: thumb,
          filePath: zip,
          updatedAt: doc.updatedAt,
        ),
      );
      expect(await db.thumbPath('png-1'), thumb);

      // Empty path (legacy row) and unknown ids ⇒ null.
      await db.insertCanvas(record('legacy', 'Legacy', 500));
      expect(await db.thumbPath('legacy'), isNull);
      expect(await db.thumbPath('no-such-id'), isNull);
    });

    test(
        'thumbGenerator seam: one generation per save; a re-save refreshes '
        'the file', () async {
      await openDb('seam');
      int calls = 0;
      Future<String> fake(CanvasDocumentModel doc, String outPath) async {
        calls += 1;
        final File file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsString('THUMB#$calls', flush: true);
        return outPath;
      }

      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Seam',
        preset: 'A4',
        background: 'BLANK',
        canvasId: 'seam-1',
        now: 1000,
      );
      await saveDocument(doc, baseDir: cacheDir, thumbGenerator: fake);
      expect(calls, 1);
      final String thumb = await thumbFilePath('seam-1', baseDir: cacheDir);
      expect(await File(thumb).readAsString(), 'THUMB#1');

      // Updated content ⇒ new thumb on the very next save.
      doc.updatedAt = 2000;
      doc.title = 'Seam v2';
      await saveDocument(doc, baseDir: cacheDir, thumbGenerator: fake);
      expect(calls, 2);
      expect(await File(thumb).readAsString(), 'THUMB#2');
      expect(
        await thumbFilePath('seam-1', baseDir: cacheDir),
        thumb,
        reason: 'canonical path is stable across saves',
      );
    });

    test('create → open → back-save refreshes the real PNG thumbnail',
        () async {      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Pipeline',
        preset: 'LETTER',
        background: 'BLANK',
        canvasId: 'pipe-1',
        now: 1000,
      );
      await saveDocument(doc, baseDir: cacheDir);
      final String thumb = await thumbFilePath('pipe-1', baseDir: cacheDir);
      final List<int> v1 = await File(thumb).readAsBytes();
      expect(v1.sublist(0, 8), kPngMagic);

      // Open (the dashboard/canvas `_open` path) …
      final CanvasDocumentModel opened = await loadDocument(
        'pipe-1',
        baseDir: cacheDir,
      );
      // … the user draws something, then backs out: canvas `_onBack` →
      // `_save` re-saves the document through the same save path.
      opened.elements.add(
        CanvasNodeModel(
          nodeId: 'stroke-1',
          kind: 'STROKE',
          layer: 0,
          bbox: const <double>[50, 50, 1700, 3200],
          style: NodeStyleModel(
            color: '#D64550',
            strokeWidth: 14,
            opacity: 1,
            blendMode: 'SRC_OVER',
          ),
          geometry: NodeGeometryModel(
            pts: const <List<double>>[
              <double>[100, 100],
              <double>[800, 1600],
              <double>[1600, 3000],
            ],
          ),
        ),
      );
      opened.updatedAt = 2000;
      await saveDocument(opened, baseDir: cacheDir);

      final List<int> v2 = await File(thumb).readAsBytes();
      expect(v2.sublist(0, 8), kPngMagic);
      expect(
        v2,
        isNot(equals(v1)),
        reason: 're-save with updated content must refresh the thumbnail',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Dashboard create path + lazy backfill (thumbGenerator seam)
  // -------------------------------------------------------------------------

  group('real renderer inside testWidgets (fake clock)', () {
    testWidgets('renderDocThumbnail completes inside tester.runAsync',
        (WidgetTester tester) async {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'RunAsync Render',
        preset: 'A4',
        background: 'BLANK',
        canvasId: 'rdr-1',
        now: 1000,
      );
      final List<int>? bytes = await tester.runAsync(
        () => renderDocThumbnail(doc),
      );
      expect(bytes, isNotNull);
      expect(bytes!.sublist(0, 8), kPngMagic);
    });

    testWidgets(
        'renderDocThumbnail started in the fake zone completes via '
        'flushReal windows (the saveDocument-in-widget scenario)',
        (WidgetTester tester) async {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Fake Zone Render',
        preset: 'LETTER',
        background: 'BLANK',
        canvasId: 'rdr-2',
        now: 1000,
      );
      List<int>? bytes;
      // Started exactly like a widget-initiated save: no runAsync wrapper —
      // progress must come from later real windows + pumps.
      final Future<List<int>> pending = renderDocThumbnail(doc);
      pending.then((List<int> value) => bytes = value);
      for (int i = 0; i < 60 && bytes == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(bytes, isNotNull,
          reason: 'fake-zone-started render must complete via real windows');
      expect(bytes!.sublist(0, 8), kPngMagic);
    });
  });

  group('dashboard create + lazy backfill', () {
    testWidgets(
        'create persists thumb_path on the row — generator runs exactly once',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'create_row');
      int calls = 0;
      Future<String> fake(CanvasDocumentModel doc, String outPath) async {
        calls += 1;
        final File file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsString('THUMB#$calls', flush: true);
        return outPath;
      }
      await pumpDashboard(tester, db: db, thumbGenerator: fake);

      await tester.tap(find.byKey(const Key('new_canvas_fab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(
        find.byKey(const Key('new_title_field')),
        'Seam Canvas',
      );
      await tester.tap(find.byKey(const Key('create_canvas')));
      await settleIo(tester);

      final Finder errFinder = find.byKey(const Key('new_canvas_error'));
      final String errText = errFinder.evaluate().isEmpty
          ? ''
          : (tester.widget<Text>(errFinder).data ?? '');
      final List<CanvasRecord>? rows = await tester.runAsync(() => db.list());
      expect(
        rows,
        hasLength(1),
        reason:
            'dialog_open=${find.byKey(const Key('new_title_field')).evaluate().isNotEmpty} err=$errText calls=$calls',
      );
      final CanvasRecord row = rows!.single;
      final String expected = '$cacheDir/thumbs/${row.id}.png';
      expect(
        row.thumbPath,
        expected,
        reason: 'create must persist the canonical thumb_path in the row',
      );
      expect(File(expected).existsSync(), isTrue);
      expect(
        await tester.runAsync(() => File(expected).readAsString()),
        'THUMB#1',
      );
      expect(calls, 1);
      expect(await tester.runAsync(() => db.thumbPath(row.id)), expected);

      // Later gallery refresh cycles see path + file present ⇒ no second
      // generation (backfill fills missing thumbs once, never repeatedly).
      await flushReal(tester, rounds: 6);
      await tester.pump(const Duration(milliseconds: 300));
      await flushReal(tester, rounds: 4);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'backfill fills legacy missing thumbs exactly once (fake call counts)',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'backfill_once');
      // Seed legacy rows: real archives on disk, NO thumbnail files, rows
      // with empty thumb_path (pre-round-6 layout).
      await tester.runAsync(
        () async {
          final CanvasDocumentModel d1 = buildNewCanvasDocument(
            title: 'Legacy One',
            preset: 'A5',
            background: 'BLANK',
            canvasId: 'bf-1',
            now: 1000,
          );
          final CanvasDocumentModel d2 = buildNewCanvasDocument(
            title: 'Legacy Two',
            preset: 'INFINITE',
            background: 'SQUARE_GRID',
            canvasId: 'bf-2',
            now: 900,
          );
          Future<String> noWrite(
            CanvasDocumentModel d,
            String outPath,
          ) async =>
              outPath;
          await saveDocument(
            d1,
            baseDir: cacheDir,
            thumbGenerator: noWrite,
          );
          await saveDocument(
            d2,
            baseDir: cacheDir,
            thumbGenerator: noWrite,
          );
          await db.insertCanvas(
            record('bf-1', 'Legacy One', 1000, preset: 'A5'),
          );
          await db.insertCanvas(
            record('bf-2', 'Legacy Two', 900, preset: 'INFINITE'),
          );
        },
      );
      expect(await tester.runAsync(() => db.thumbPath('bf-1')), isNull);

      int calls = 0;
      Future<String> fake(CanvasDocumentModel doc, String outPath) async {
        calls += 1;
        final File file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsString('THUMB#$calls', flush: true);
        return outPath;
      }
      final ValueNotifier<int> hub = ValueNotifier<int>(0);
      await pumpDashboard(
        tester,
        db: db,
        thumbGenerator: fake,
        refreshListenable: hub,
      );
      expect(find.text('Legacy One'), findsOneWidget);
      expect(find.text('Legacy Two'), findsOneWidget);

      final String thumb1 = '$cacheDir/thumbs/bf-1.png';
      final String thumb2 = '$cacheDir/thumbs/bf-2.png';
      // Wait for the ROWS to carry thumb_path (not just the files): the row
      // update lands a beat after the PNG is written.
      await waitUntil(tester, () async {
        final String? p1 =
            await tester.runAsync<String?>(() => db.thumbPath('bf-1'));
        final String? p2 =
            await tester.runAsync<String?>(() => db.thumbPath('bf-2'));
        return p1 == thumb1 && p2 == thumb2;
      });
      expect(
        File(thumb1).existsSync() && File(thumb2).existsSync(),
        isTrue,
        reason: 'backfill must generate both missing thumbnails',
      );
      expect(calls, 2, reason: 'exactly one generation per missing row');
      expect(await tester.runAsync(() => db.thumbPath('bf-1')), thumb1);
      expect(await tester.runAsync(() => db.thumbPath('bf-2')), thumb2);

      // A second gallery load (hub refresh) must NOT regenerate: both rows
      // now carry thumb_path with the file present.
      hub.value += 1;
      await tester.pump(const Duration(milliseconds: 120)); // 100 ms debounce
      await flushReal(tester, rounds: 6);
      await tester.pump(const Duration(milliseconds: 120));
      await flushReal(tester, rounds: 4);
      expect(calls, 2, reason: 'backfill fills each missing thumb exactly once');

      hub.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
