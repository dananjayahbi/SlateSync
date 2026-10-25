/// Doc 26 §6 acceptance suite: LocalDb CRUD + search ordering
/// (`sqflite_common_ffi`), `.slatesync` save→load roundtrip (unicode +
/// assets via `archive`), New Canvas modal row creation, Open hand-off,
/// rename/delete, UpgradeDialog allowed/blocked flows with fake/injected
/// `ArtboardManager`, empty state, preset dims and `relativeTime`.
///
/// All scratch state lives under `test/.home_dashboard_tmp/` inside the
/// package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/canvas_engine/artboard_manager.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';

// ---------------------------------------------------------------------------
// Fakes (Doc 26 §6: injected ArtboardManager)
// ---------------------------------------------------------------------------

class _FakeAllowedManager extends ArtboardManager {
  _FakeAllowedManager() : super(preset: 'A5');

  @override
  UpgradeResult tryUpgrade(String targetPreset) =>
      const UpgradeResult(true, null);
}

class _FakeBlockedManager extends ArtboardManager {
  _FakeBlockedManager(this.reason) : super(preset: 'A5');

  final String reason;

  @override
  UpgradeResult tryUpgrade(String targetPreset) => UpgradeResult(false, reason);
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.home_dashboard_tmp');
  late Directory tmp;
  late String cacheDir;
  final List<LocalDb> openDbs = <LocalDb>[];

  setUp(() {
    tmp = Directory('${root.path}/${DateTime.now().microsecondsSinceEpoch}_$counter');
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

  CanvasRecord record(
    String id,
    String title,
    int updatedAt, {
    String preset = 'A4',
    String background = 'BLANK',
  }) =>
      CanvasRecord(
        id: id,
        title: title,
        preset: preset,
        background: background,
        thumbPath: '',
        filePath: '$cacheDir/$id.slatesync',
        updatedAt: updatedAt,
      );

  /// Real event-loop windows interleaved with frame pumps — `testWidgets`
  /// runs on a fake clock, so sqflite/file futures parked from the fake zone
  /// only progress while `runAsync` gives them real time.
  Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Real-IO aware settle for multi-step chains (save/insert/refresh/pop).
  /// Round count covers the Doc 02 §10.6 save path, which now also
  /// rasterizes a PNG thumbnail before the chain can land.
  Future<void> settleIo(WidgetTester tester, {int rounds = 28}) async {
    await flushReal(tester, rounds: rounds);
    await tester.pump(const Duration(milliseconds: 500));
    await flushReal(tester, rounds: 2);
  }

  /// Poll [condition] with real-event-loop windows between frame pumps
  /// (up to [maxRounds]) — for chains whose length varies with the PNG
  /// rasterization step (Doc 02 §10.6) and machine load. Returns whether
  /// the condition held on the last check.
  Future<bool> settleUntil(
    WidgetTester tester,
    Future<bool> Function() condition, {
    int maxRounds = 50,
  }) async {
    bool ok = await condition();
    for (int i = 0; i < maxRounds && !ok; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      ok = await condition();
    }
    return ok;
  }

  Future<LocalDb> openDbInTester(WidgetTester tester, String name) async {
    final LocalDb? db = await tester.runAsync(() => openDb(name));
    return db!;
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    required LocalDb db,
    void Function(CanvasDocumentModel doc)? onOpen,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeCanvasDashboard(
          onOpenDocument: onOpen ?? (_) {},
          db: db,
          baseDir: cacheDir,
        ),
      ),
    );
    // Let initState's first `db.list` complete and rebuild with rows.
    await flushReal(tester);
  }

  Future<void> pumpUpgrade(WidgetTester tester, UpgradeDialog dialog) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: ElevatedButton(
              key: const Key('open_upgrade'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (BuildContext context) => dialog,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_upgrade')));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------------
  // LocalDb CRUD + search (sqflite_common_ffi)
  // -------------------------------------------------------------------------

  group('LocalDb CRUD & search (ffi)', () {
    test('insert → list ordered updated_at DESC; get/update/delete', () async {
      final LocalDb db = await openDb('crud');
      await db.insertCanvas(record('a', 'Alpha', 100));
      await db.insertCanvas(record('b', 'Beta', 300));
      await db.insertCanvas(record('c', 'Gamma', 200));

      expect(
        (await db.list()).map((CanvasRecord r) => r.id),
        <String>['b', 'c', 'a'],
      );
      expect((await db.get('c'))?.title, 'Gamma');

      await db.update(
        record('c', 'Gamma v2', 400, preset: 'LETTER', background: 'SQUARE_GRID'),
      );
      final CanvasRecord? updated = await db.get('c');
      expect(updated, isNotNull);
      expect(updated!.title, 'Gamma v2');
      expect(updated.updatedAt, 400);
      expect(updated.preset, 'LETTER');
      expect(updated.background, 'SQUARE_GRID');

      // conflictAlgorithm: replace on same primary key
      await db.insertCanvas(record('a', 'Alpha 2', 500));
      expect((await db.get('a'))?.title, 'Alpha 2');
      expect((await db.list()).first.id, 'a');

      await db.delete('a');
      expect(await db.get('a'), isNull);
      expect((await db.list()), hasLength(2));
    });

    test('search is case-insensitive; empty query returns all', () async {
      final LocalDb db = await openDb('search');
      await db.insertCanvas(record('c1', 'Control Systems LECTURE 04', 2000));
      await db.insertCanvas(record('c2', 'Thermodynamics notes', 3000));
      await db.insertCanvas(record('c3', 'lecture recap', 1000));

      final List<CanvasRecord> lower = await db.list(query: 'lecture');
      expect(
        lower.map((CanvasRecord r) => r.id),
        <String>['c1', 'c3'], // ordered updated_at DESC
      );
      final List<CanvasRecord> upper = await db.list(query: 'LECTURE');
      expect(
        upper.map((CanvasRecord r) => r.id),
        <String>['c1', 'c3'],
      );

      expect(
        (await db.list()).map((CanvasRecord r) => r.id),
        <String>['c2', 'c1', 'c3'],
      );
      expect(await db.list(query: '   '), hasLength(3));
      expect(await db.list(query: 'nothing-matches'), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // .slatesync container roundtrip
  // -------------------------------------------------------------------------

  group('.slatesync save → load roundtrip (archive)', () {
    test('unicode title + assets survive; real ZIP with document.json', () async {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Ünicode — 研究ノート ✨',
        preset: 'A5',
        background: 'RULED',
        canvasId: 'rt-canvas',
        now: 1760760000,
      );
      doc.elements.add(
        CanvasNodeModel(
          nodeId: 'node-1',
          kind: 'IMAGE',
          layer: 0,
          bbox: const <double>[10.0, 20.0, 300.0, 200.0],
          style: NodeStyleModel(
            color: '#FFFFFF',
            strokeWidth: 2.5,
            opacity: 1.0,
            blendMode: 'SRC_OVER',
          ),
          geometry: NodeGeometryModel(
            pts: const <List<double>>[],
            assetRef: 'assets/写真.png',
          ),
        ),
      );
      doc.contentBounds = <String, double>{
        'min_x': 10.0,
        'min_y': 20.0,
        'max_x': 300.0,
        'max_y': 200.0,
      };
      final List<int> assetBytes = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];

      final String path = await saveDocument(
        doc,
        baseDir: cacheDir,
        assets: <String, List<int>>{'assets/写真.png': assetBytes},
      );
      expect(File(path).existsSync(), isTrue);
      expect(path, '$cacheDir/rt-canvas.slatesync');

      // Real ZIP: document.json at root + assets/* (template §3).
      final Archive zip =
          ZipDecoder().decodeBytes(File(path).readAsBytesSync(), verify: true);
      expect(
        zip.files.map((ArchiveFile f) => f.name),
        containsAll(<String>['document.json', 'assets/写真.png']),
      );

      final ArchiveFile docFile =
          zip.files.firstWhere((ArchiveFile f) => f.name == 'document.json');
      final Map<String, dynamic> raw =
          jsonDecode(utf8.decode(docFile.content)) as Map<String, dynamic>;
      expect(
        raw.keys,
        containsAll(<String>[
          'canvas_id',
          'title',
          'created_at',
          'updated_at',
          'artboard',
          'content_bounds',
          'elements',
        ]),
      );
      expect(raw['title'], 'Ünicode — 研究ノート ✨');

      final CanvasDocumentModel loaded = await loadDocument(
        'rt-canvas',
        baseDir: cacheDir,
      );
      expect(loaded.toJson(), equals(doc.toJson()));

      // Assets extracted (basename-only) for the next save to re-embed.
      final File extracted = File('$cacheDir/assets/rt-canvas/写真.png');
      expect(extracted.existsSync(), isTrue);
      expect(extracted.readAsBytesSync(), equals(assetBytes));

      final String path2 = await saveDocument(loaded, baseDir: cacheDir);
      final Archive zip2 =
          ZipDecoder().decodeBytes(File(path2).readAsBytesSync(), verify: true);
      final ArchiveFile asset2 =
          zip2.files.firstWhere((ArchiveFile f) => f.name == 'assets/写真.png');
      expect(asset2.content, equals(assetBytes));
    });

    test('loadDocument on a missing archive throws', () async {
      expect(
        () => loadDocument('nope', baseDir: cacheDir),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // New document seed + preset dims + relativeTime
  // -------------------------------------------------------------------------

  group('New Canvas document seed (template §3 presets)', () {
    test('A5/A4/LETTER dims and INFINITE null dims', () {
      final CanvasDocumentModel a5 = buildNewCanvasDocument(
        title: 't',
        preset: 'A5',
        background: 'BLANK',
        canvasId: 'c-a5',
        now: 100,
      );
      expect(a5.artboard.width, 1748.0);
      expect(a5.artboard.height, 2480.0);
      expect(a5.artboard.isInfinite, isFalse);

      final CanvasDocumentModel a4 = buildNewCanvasDocument(
        title: 't',
        preset: 'A4',
        background: 'SQUARE_GRID',
        canvasId: 'c-a4',
        now: 100,
      );
      expect(a4.artboard.width, 2480.0);
      expect(a4.artboard.height, 3508.0);
      expect(a4.artboard.isInfinite, isFalse);

      final CanvasDocumentModel letter = buildNewCanvasDocument(
        title: 't',
        preset: 'LETTER',
        background: 'RULED',
        canvasId: 'c-ltr',
        now: 100,
      );
      expect(letter.artboard.width, 2550.0);
      expect(letter.artboard.height, 3300.0);
      expect(letter.artboard.isInfinite, isFalse);

      final CanvasDocumentModel infinite = buildNewCanvasDocument(
        title: 't',
        preset: 'INFINITE',
        background: 'BLANK',
        canvasId: 'c-inf',
        now: 100,
      );
      expect(infinite.artboard.width, isNull);
      expect(infinite.artboard.height, isNull);
      expect(infinite.artboard.isInfinite, isTrue);
      expect(infinite.artboard.preset, 'INFINITE');
    });

    test('seed defaults: zeros bounds, empty elements, #FFFFFF, uuid id', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Untitled',
        preset: 'A4',
        background: 'BLANK',
        now: 42,
      );
      expect(doc.contentBounds, <String, double>{
        'min_x': 0,
        'min_y': 0,
        'max_x': 0,
        'max_y': 0,
      });
      expect(doc.elements, isEmpty);
      expect(doc.artboard.backgroundColor, '#FFFFFF');
      expect(doc.createdAt, 42);
      expect(doc.updatedAt, 42);
      expect(
        doc.canvasId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );

      expect(
        () => buildNewCanvasDocument(
          title: 't',
          preset: 'BANANA',
          background: 'BLANK',
        ),
        throwsArgumentError,
      );
      expect(presetDimsLabel('INFINITE'), 'Unbounded');
      expect(presetDimsLabel('A5'), '1748 × 2480');
    });
  });

  group('relativeTime helper', () {
    final int now = 1000000;

    test('<60 s → just now', () {
      expect(relativeTime(now, now), 'just now');
      expect(relativeTime(now, now - 59), 'just now');
      expect(relativeTime(now, now + 120), 'just now'); // clock skew
    });

    test('minute / hour / day boundaries', () {
      expect(relativeTime(now, now - 60), '1 min ago');
      expect(relativeTime(now, now - 3599), '59 min ago');
      expect(relativeTime(now, now - 3600), '1 h ago');
      expect(relativeTime(now, now - 86399), '23 h ago');
      expect(relativeTime(now, now - 86400), '1 d ago');
      expect(relativeTime(now, now - 6 * 86400), '6 d ago');
    });

    test('≥7 days → yyyy-MM-dd', () {
      final int old = now - 7 * 86400;
      final String value = relativeTime(now, old);
      expect(value, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      final DateTime d = DateTime.fromMillisecondsSinceEpoch(old * 1000);
      final String mm = d.month.toString().padLeft(2, '0');
      final String dd = d.day.toString().padLeft(2, '0');
      expect(value, '${d.year}-$mm-$dd');
    });
  });

  // -------------------------------------------------------------------------
  // Dashboard widget tests
  // -------------------------------------------------------------------------

  group('HomeCanvasDashboard (widget)', () {
    testWidgets('empty state when zero rows; card appears after insert',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'empty');
      await pumpDashboard(tester, db: db);

      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);
      expect(find.text(kEmptyGalleryMessage), findsOneWidget);

      await tester.runAsync(
        () => db.insertCanvas(record('n1', 'Fresh Canvas', unixNowSeconds())),
      );
      // Remount so initState re-queries the table with the new row.
      await tester.pumpWidget(const SizedBox());
      await pumpDashboard(tester, db: db);

      expect(find.byKey(const Key('empty_gallery')), findsNothing);
      expect(find.byKey(const Key('canvas_card_n1')), findsOneWidget);
    });

    testWidgets('card contract: title, preset chip, relative time',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'card');
      final int now = unixNowSeconds();
      await tester.runAsync(
        () => db.insertCanvas(
          record('lec', 'Control Systems LECTURE 04', now - 7200),
        ),
      );
      await pumpDashboard(tester, db: db);

      final Finder card = find.byKey(const Key('canvas_card_lec'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const Key('card_title_lec')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Control Systems LECTURE 04')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const Key('preset_chip_lec')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('A4')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const Key('card_time_lec')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('2 h ago')),
        findsOneWidget,
      );
    });

    testWidgets('debounced search filters the grid',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'search_widget');
      final int now = unixNowSeconds();
      await tester.runAsync(
        () async {
          await db.insertCanvas(
            record('s1', 'Control Systems LECTURE 04', now, preset: 'A4'),
          );
          await db.insertCanvas(
            record('s2', 'Heat transfer notes', now - 100, preset: 'A5'),
          );
        },
      );
      await pumpDashboard(tester, db: db);
      expect(find.byKey(const Key('canvas_card_s1')), findsOneWidget);
      expect(find.byKey(const Key('canvas_card_s2')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('canvas_search')),
        'lecture',
      );
      await tester.pump(const Duration(milliseconds: 300)); // debounce fires
      await flushReal(tester);
      expect(find.byKey(const Key('canvas_card_s1')), findsOneWidget);
      expect(find.byKey(const Key('canvas_card_s2')), findsNothing);

      await tester.enterText(find.byKey(const Key('canvas_search')), 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await flushReal(tester);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);
    });

    testWidgets('New Canvas modal: A4 + SQUARE_GRID creates row + file',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'new_canvas');
      await pumpDashboard(tester, db: db);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);

      await tester.tap(find.byKey(const Key('new_canvas_fab')));
      await tester.pumpAndSettle();

      // Preset cards + four mini background preview painters.
      expect(find.byKey(const Key('new_preset_A5')), findsOneWidget);
      expect(find.byKey(const Key('new_preset_A4')), findsOneWidget);
      expect(find.byKey(const Key('new_preset_LETTER')), findsOneWidget);
      expect(find.byKey(const Key('new_preset_INFINITE')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is CustomPaint && w.painter is BackgroundPreviewPainter,
        ),
        findsNWidgets(3),
      );

      await tester.enterText(
        find.byKey(const Key('new_title_field')),
        'Control Systems',
      );
      await tester.tap(find.byKey(const Key('new_preset_A4')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('new_background_SQUARE_GRID')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('create_canvas')));
      // The create chain now includes the Doc 02 §10.6 PNG rasterization —
      // poll for the modal to close (it pops only after save+insert land)
      // instead of assuming one fixed real-time window suffices.
      final bool modalClosed = await settleUntil(
        tester,
        () async => find.byKey(const Key('new_title_field')).evaluate().isEmpty,
      );
      await tester.pump(); // run the pop transition frames
      expect(
        find.byKey(const Key('new_title_field')),
        findsNothing,
        reason: 'modal must close once the create chain completes '
            '(modalClosed=$modalClosed)',
      );

      final List<CanvasRecord>? rows =
          await tester.runAsync(() => db.list());
      expect(rows, hasLength(1));
      expect(rows!.single.title, 'Control Systems');
      expect(rows.single.preset, 'A4');
      expect(rows.single.background, 'SQUARE_GRID');
      expect(File(rows.single.filePath).existsSync(), isTrue);
      expect(
        File('$cacheDir/${rows.single.id}.slatesync').existsSync(),
        isTrue,
      );
      expect(
        find.byKey(Key('canvas_card_${rows.single.id}')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('empty_gallery')), findsNothing);
    });

    testWidgets('card tap loads the archive and hands off via onOpenDocument',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'open_flow');
      final CanvasDocumentModel seed = buildNewCanvasDocument(
        title: 'Ünicode — 研究ノート',
        preset: 'LETTER',
        background: 'SQUARE_GRID',
        canvasId: 'open-1',
        now: unixNowSeconds(),
      );
      final String? path = await tester.runAsync(
        () => saveDocument(seed, baseDir: cacheDir),
      );
      await tester.runAsync(
        () => db.insertCanvas(
          CanvasRecord(
            id: 'open-1',
            title: seed.title,
            preset: seed.artboard.preset,
            background: seed.artboard.backgroundStyle,
            thumbPath: '',
            filePath: path!,
            updatedAt: seed.updatedAt,
          ),
        ),
      );

      CanvasDocumentModel? handed;
      await pumpDashboard(
        tester,
        db: db,
        onOpen: (CanvasDocumentModel doc) => handed = doc,
      );
      expect(find.byKey(const Key('canvas_card_open-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('canvas_card_open-1')));
      await settleIo(tester);

      expect(handed, isNotNull);
      expect(handed!.canvasId, 'open-1');
      expect(handed!.title, 'Ünicode — 研究ノート');
      expect(handed!.artboard.preset, 'LETTER');
      expect(handed!.toJson(), equals(seed.toJson()));
    });

    testWidgets('rename updates the row and the cached document',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'rename');
      final CanvasDocumentModel seed = buildNewCanvasDocument(
        title: 'Old name',
        preset: 'A4',
        background: 'BLANK',
        canvasId: 'rn-1',
        now: unixNowSeconds(),
      );
      final String? path = await tester.runAsync(
        () => saveDocument(seed, baseDir: cacheDir),
      );
      await tester.runAsync(
        () => db.insertCanvas(
          CanvasRecord(
            id: 'rn-1',
            title: seed.title,
            preset: seed.artboard.preset,
            background: seed.artboard.backgroundStyle,
            thumbPath: '',
            filePath: path!,
            updatedAt: seed.updatedAt,
          ),
        ),
      );
      await pumpDashboard(tester, db: db);

      await tester.tap(find.byKey(const Key('card_menu_rn-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rename_field')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('rename_field')),
        'Renamed lecture',
      );
      await tester.tap(find.byKey(const Key('rename_confirm')));
      // Row update + archive re-save (zip + Doc 02 §10.6 PNG) are real IO —
      // poll until the re-saved archive carries the new title.
      final bool archiveRenamed = await settleUntil(
        tester,
        () async {
          // Errors are swallowed INSIDE the real-zone callback so a
          // half-written zip never surfaces as a framework zone error.
          final String? title = await tester.runAsync<String?>(() async {
            try {
              final CanvasDocumentModel d = await loadDocument(
                'rn-1',
                baseDir: cacheDir,
              );
              return d.title;
            } catch (_) {
              return null; // not (fully) written yet
            }
          });
          return title == 'Renamed lecture';
        },
      );
      expect(archiveRenamed, isTrue, reason: 'rename re-save must land');
      await tester.pump();

      final CanvasRecord? row =
          await tester.runAsync<CanvasRecord?>(() => db.get('rn-1'));
      expect(row, isNotNull);
      expect(row!.title, 'Renamed lecture');

      final CanvasDocumentModel? reloaded = await tester.runAsync(
        () => loadDocument('rn-1', baseDir: cacheDir),
      );
      expect(reloaded!.title, 'Renamed lecture');

      // The post-rename `_refresh` only runs after the §10.6 thumbnail
      // render inside the re-save chain finishes — poll for the repaint
      // instead of assuming one fixed real-time window.
      final bool cardRepainted = await settleUntil(
        tester,
        () async =>
            find.descendant(
              of: find.byKey(const Key('canvas_card_rn-1')),
              matching: find.text('Renamed lecture'),
            ).evaluate().length ==
            1,
      );
      expect(cardRepainted, isTrue, reason: 'post-rename refresh must '
          'repaint the card with the new title');
      expect(
        find.descendant(
          of: find.byKey(const Key('canvas_card_rn-1')),
          matching: find.text('Renamed lecture'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('delete removes the row and the cached file',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'delete');
      final CanvasDocumentModel seed = buildNewCanvasDocument(
        title: 'Doomed',
        preset: 'A5',
        background: 'RULED',
        canvasId: 'del-1',
        now: unixNowSeconds(),
      );
      final String? path = await tester.runAsync(
        () => saveDocument(seed, baseDir: cacheDir),
      );
      await tester.runAsync(
        () => db.insertCanvas(
          CanvasRecord(
            id: 'del-1',
            title: seed.title,
            preset: seed.artboard.preset,
            background: seed.artboard.backgroundStyle,
            thumbPath: '',
            filePath: path!,
            updatedAt: seed.updatedAt,
          ),
        ),
      );
      await pumpDashboard(tester, db: db);
      expect(find.byKey(const Key('canvas_card_del-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('card_menu_del-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await settleIo(tester);

      expect(await tester.runAsync(() => db.get('del-1')), isNull);
      expect(File('$cacheDir/del-1.slatesync').existsSync(), isFalse);
      expect(find.byKey(const Key('canvas_card_del-1')), findsNothing);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);
    });

    // Doc 02 §8.1 (Issue 04, round 4): the optional onListChanged hook —
    // wired by the shell to CanvasSyncBridge.publishList — fires after
    // create/rename/delete. Additive: default-null keeps existing callers
    // untouched.
    testWidgets(
        'onListChanged fires after create, rename and delete (Doc 02 §8.1)',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'list_changed');
      int calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeCanvasDashboard(
            onOpenDocument: (_) {},
            db: db,
            baseDir: cacheDir,
            onListChanged: () => calls += 1,
          ),
        ),
      );
      await flushReal(tester);
      expect(calls, 0); // not fired by init/refresh alone

      // Flush until the callback fires: the create/rename/delete chains do
      // real sqflite/file IO plus the §10.6 PNG rasterization, and the
      // suite runs test files in parallel, so a fixed pump budget can be
      // starved under load.
      Future<void> settleUntil(int expected) async {
        for (int i = 0; i < 60 && calls < expected; i++) {
          await flushReal(tester, rounds: 3);
          await tester.pump();
        }
      }

      // Create → one push.
      await tester.tap(find.byKey(const Key('new_canvas_fab')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('new_title_field')),
        'Push Hook',
      );
      await tester.tap(find.byKey(const Key('create_canvas')));
      await settleUntil(1);
      expect(calls, 1);

      final List<CanvasRecord>? rows = await tester.runAsync(() => db.list());
      expect(rows, hasLength(1));
      final String id = rows!.single.id;

      // Rename → second push.
      await tester.tap(find.byKey(Key('card_menu_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rename_field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('rename_field')),
        'Push Hook v2',
      );
      await tester.tap(find.byKey(const Key('rename_confirm')));
      await settleUntil(2);
      expect(calls, 2);

      // Delete → third push.
      await tester.tap(find.byKey(Key('card_menu_$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await settleUntil(3);
      expect(calls, 3);
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------
  // UpgradeDialog flows
  // -------------------------------------------------------------------------

  group('UpgradeDialog (injected ArtboardManager)', () {
    testWidgets('allowed: onSaved called, dialog pops (fake manager)',
        (WidgetTester tester) async {
      final _FakeAllowedManager manager = _FakeAllowedManager();
      Artboard? saved;
      await pumpUpgrade(
        tester,
        UpgradeDialog(
          manager: manager,
          onSaved: (Artboard artboard) => saved = artboard,
        ),
      );
      expect(find.byKey(const Key('upgrade_target_A4')), findsOneWidget);
      expect(find.text('Current size: A5'), findsOneWidget);

      await tester.tap(find.byKey(const Key('upgrade_target_A4')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved, same(manager.current));
      expect(find.byType(UpgradeDialog), findsNothing);
    });

    testWidgets("blocked 'clips_content': banner, stays open, no onSaved",
        (WidgetTester tester) async {
      final _FakeBlockedManager manager =
          _FakeBlockedManager(ReasonKeys.clipsContent);
      bool called = false;
      await pumpUpgrade(
        tester,
        UpgradeDialog(
          manager: manager,
          onSaved: (Artboard artboard) => called = true,
        ),
      );

      await tester.tap(find.byKey(const Key('upgrade_target_A4')));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(find.byKey(const Key('upgrade_warning')), findsOneWidget);
      expect(
        find.text('New size would crop existing content'),
        findsOneWidget,
      );
      expect(find.byType(UpgradeDialog), findsOneWidget);

      // Still blocked for any target with the fake.
      await tester.tap(find.byKey(const Key('upgrade_target_INFINITE')));
      await tester.pumpAndSettle();
      expect(called, isFalse);
      expect(find.byType(UpgradeDialog), findsOneWidget);
    });

    testWidgets("blocked 'invalid_target': distinct human message",
        (WidgetTester tester) async {
      final _FakeBlockedManager manager =
          _FakeBlockedManager(ReasonKeys.invalidTarget);
      await pumpUpgrade(
        tester,
        UpgradeDialog(manager: manager, onSaved: (Artboard a) {}),
      );

      await tester.tap(find.byKey(const Key('upgrade_target_A5')));
      await tester.pumpAndSettle();

      expect(find.text('Invalid target size'), findsOneWidget);
      // Distinct from the other frozen reason message.
      expect(
        find.text('New size would crop existing content'),
        findsNothing,
      );
      expect(find.byType(UpgradeDialog), findsOneWidget);
    });

    testWidgets('real manager: negative bounds block A4, INFINITE allowed',
        (WidgetTester tester) async {
      final ArtboardManager manager = ArtboardManager(preset: 'A5');
      manager.noteContent(const Rect.fromLTRB(-10, 0, 500, 500));
      Artboard? saved;
      await pumpUpgrade(
        tester,
        UpgradeDialog(
          manager: manager,
          onSaved: (Artboard artboard) => saved = artboard,
        ),
      );

      await tester.tap(find.byKey(const Key('upgrade_target_A4')));
      await tester.pumpAndSettle();
      expect(find.text('New size would crop existing content'), findsOneWidget);
      expect(saved, isNull);

      await tester.tap(find.byKey(const Key('upgrade_target_INFINITE')));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.isInfinite, isTrue);
      expect(saved!.preset, 'INFINITE');
      expect(find.byType(UpgradeDialog), findsNothing);
    });
  });
}

/// Monotonic scratch-dir suffix (avoids collisions with leftover dirs).
int counter = 0;
