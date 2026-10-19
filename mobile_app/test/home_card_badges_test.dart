/// Issue 07 round-6 (Doc 02 §10.6) — gallery card visuals:
/// thumbnail `Image.file` (fade-in over a NEUTRAL placeholder) with the
/// preset badge chip OVERLAID (`A5 / A4 / LETTER / INFINITE`, distinct
/// colors readable on the light theme), unicode-safe titles, and the
/// placeholder staying visible while a slow backfill thumbnail is still
/// loading.
///
/// Harness mirrors `home_dashboard_test.dart`: injected `LocalDb` +
/// `baseDir`, `sqflite_common_ffi`, real-event-loop `flushReal` windows.
/// All scratch state lives under `test/.home_card_badges_tmp/` inside the
/// package (never `/tmp`) and is removed in `tearDown`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';

/// Valid 1×1 PNG (verified) — stands in for a generated thumbnail.
const String kOnePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

const List<String> kPresets = <String>['A5', 'A4', 'LETTER', 'INFINITE'];

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.home_card_badges_tmp');
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
    String thumbPath = '',
  }) =>
      CanvasRecord(
        id: id,
        title: title,
        preset: preset,
        background: 'BLANK',
        thumbPath: thumbPath,
        filePath: '$cacheDir/$id.slatesync',
        updatedAt: updatedAt,
      );

  Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Poll [condition] with real-event-loop windows between frame pumps
  /// (up to [maxRounds]); returns the final condition result.
  Future<bool> waitUntil(
    WidgetTester tester,
    Future<bool> Function() condition, {
    int maxRounds = 40,
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

  /// Write a 1×1 PNG at the canonical thumb path for [id]; returns it.
  Future<String> writeThumb(String id) async {
    final String path = await thumbFilePath(id, baseDir: cacheDir);
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(kOnePixelPngBase64), flush: true);
    return path;
  }

  // -------------------------------------------------------------------------
  // Card contract: thumbnail Image + overlaid badge, per preset
  // -------------------------------------------------------------------------

  for (final String preset in kPresets) {
    testWidgets(
        'gallery card shows thumbnail Image + overlaid "$preset" badge',
        (WidgetTester tester) async {
      final LocalDb db = await openDbInTester(tester, 'badge_$preset');
      final String id = 'badge-$preset';
      final String thumb =
          (await tester.runAsync<String>(() => writeThumb(id)))!;
      await tester.runAsync(
        () => db.insertCanvas(
          record(id, 'Card $preset', unixNowSeconds(), preset: preset, thumbPath: thumb),
        ),
      );
      await pumpDashboard(tester, db: db);

      final Finder card = find.byKey(Key('canvas_card_$id'));
      expect(card, findsOneWidget);
      // Thumbnail image widget, fade-in wrapper, neutral placeholder kept.
      expect(
        find.descendant(of: card, matching: find.byKey(Key('card_thumb_$id'))),
        findsOneWidget,
      );
      expect(find.descendant(of: card, matching: find.byType(Image)),
          findsOneWidget);
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(Key('card_placeholder_$id')),
        ),
        findsOneWidget,
        reason: 'neutral placeholder stays mounted beneath the image',
      );
      // Badge: raw preset key overlaid on the thumbnail.
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(Key('preset_chip_$id')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text(preset)),
        findsOneWidget,
        reason: 'badge label must be the raw preset key ($preset)',
      );
      // Title + relative time contracts intact.
      expect(
        find.descendant(of: card, matching: find.byKey(Key('card_title_$id'))),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.byKey(Key('card_time_$id'))),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('badge colors are distinct per preset and white-readable (≥4.5:1)',
      () {
    double linear(double channel) {
      final double c = channel / 255;
      return c <= 0.04045
          ? c / 12.92
          : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    double luminance(Color color) => 0.2126 * linear(color.r * 255) +
        0.7152 * linear(color.g * 255) +
        0.0722 * linear(color.b * 255);

    // Pairwise-distinct hues.
    final Set<int> seen = <int>{};
    for (final String preset in kPresets) {
      final Color color = presetBadgeColor(preset);
      expect(seen.add(color.toARGB32()), isTrue,
          reason: 'badge colors must be distinct ($preset)');
      // White label contrast ≥ 4.5:1 (WCAG AA for normal text).
      final double ratio = 1.05 / (luminance(color) + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5),
          reason: 'white on $preset badge must be readable');
    }
  });

  // -------------------------------------------------------------------------
  // Placeholder while loading + unicode safety
  // -------------------------------------------------------------------------

  testWidgets(
      'neutral placeholder shows until the backfilled thumbnail lands, '
      'then the Image fades in', (WidgetTester tester) async {
    final LocalDb db = await openDbInTester(tester, 'slow_load');
    // Legacy row: archive on disk, no thumbnail, empty thumb_path.
    await tester.runAsync(
      () async {
        final CanvasDocumentModel doc = buildNewCanvasDocument(
          title: 'Slow',
          preset: 'A4',
          background: 'BLANK',
          canvasId: 'slow-1',
          now: unixNowSeconds(),
        );
        await saveDocument(
          doc,
          baseDir: cacheDir,
          thumbGenerator: (CanvasDocumentModel d, String outPath) async =>
              outPath,
        );
        await db.insertCanvas(record('slow-1', 'Slow', unixNowSeconds()));
      },
    );

    final Completer<void> gate = Completer<void>();
    int calls = 0;
    Future<String> slow(CanvasDocumentModel doc, String outPath) async {
      calls += 1;
      await gate.future; // hold the "load" open — placeholder must show
      final File file = File(outPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(base64Decode(kOnePixelPngBase64), flush: true);
      return outPath;
    }

    await pumpDashboard(tester, db: db, thumbGenerator: slow);
    await pumpDashboard(tester, db: db, thumbGenerator: slow);
    await waitUntil(tester, () async => calls == 1);

    final Finder card = find.byKey(const Key('canvas_card_slow-1'));
    expect(calls, 1, reason: 'backfill reached the generator');
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('card_placeholder_slow-1')),
      ),
      findsOneWidget,
      reason: 'neutral placeholder shows while the thumbnail loads',
    );
    expect(
      find.byType(Image),
      findsNothing,
      reason: 'no Image yet — row thumb_path is still empty',
    );

    gate.complete();
    // Poll (real windows + pumps) until the backfill patch lands and the
    // card rebuilds with the image — fixed windows can be starved when the
    // full suite runs files in parallel.
    final bool imageLanded = await waitUntil(
      tester,
      () async => find.byType(Image).evaluate().isNotEmpty,
    );
    expect(imageLanded, isTrue,
        reason: 'backfill must publish the thumb path to the card');

    expect(calls, 1, reason: 'exactly one generation');
    expect(
      find.descendant(of: card, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'thumbnail Image appears once the backfill lands',
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('card_placeholder_slow-1')),
      ),
      findsOneWidget,
      reason: 'placeholder remains mounted beneath the fading image',
    );

    // Fade-in contract: the AnimatedOpacity wrapper (frameBuilder) exists
    // and eventually settles at full opacity once frames decode; the
    // placeholder stays underneath the whole time.
    final Finder fadeFinder = find.descendant(
      of: card,
      matching: find.byType(AnimatedOpacity),
    );
    expect(fadeFinder, findsOneWidget);
    final bool fadedIn = await waitUntil(
      tester,
      () async => tester.widget<AnimatedOpacity>(fadeFinder).opacity == 1.0,
    );
    expect(fadedIn, isTrue, reason: 'fade-in must reach full opacity');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unicode titles render safely on the thumbnail card',
      (WidgetTester tester) async {
    final LocalDb db = await openDbInTester(tester, 'unicode');
    final String thumb =
        (await tester.runAsync<String>(() => writeThumb('uni-1')))!;
    await tester.runAsync(
      () => db.insertCanvas(
        record(
          'uni-1',
          'Ünicode — 研究ノート ✨',
          unixNowSeconds(),
          preset: 'LETTER',
          thumbPath: thumb,
        ),
      ),
    );
    await pumpDashboard(tester, db: db);

    final Finder card = find.byKey(const Key('canvas_card_uni-1'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byKey(const Key('card_title_uni-1'))),
      findsOneWidget,
    );
    expect(find.text('Ünicode — 研究ノート ✨'), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('LETTER')),
        findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
