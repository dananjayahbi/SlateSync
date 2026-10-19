/// Issue 03 round 5 (Doc 02 §9): `HomeCanvasDashboard.refreshListenable`
/// — an OPTIONAL `Listenable` (default `null`, existing constructions
/// untouched) that turns each notification into a debounced 100 ms
/// `_refresh()` so bursty hub updates (bridge `hubChanged`) coalesce into
/// one row re-read, plus detach-on-dispose safety.
///
/// Harness mirrors `home_dashboard_test.dart`: injected `LocalDb` +
/// `baseDir`, `sqflite_common_ffi`, real-event-loop `flushReal` windows.
/// All scratch state lives under `test/.home_refresh_tmp/` (never `/tmp`)
/// and is removed in `tearDown`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/core/storage/local_db.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final Directory root = Directory('test/.home_refresh_tmp');
  int counter = 0;
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

  CanvasRecord record(String id, String title, int updatedAt) => CanvasRecord(
    id: id,
    title: title,
    preset: 'A4',
    background: 'BLANK',
    thumbPath: '',
    filePath: '$cacheDir/$id.slatesync',
    updatedAt: updatedAt,
  );

  /// Real event-loop windows interleaved with frame pumps (ffi/file futures
  /// parked from the fake zone only progress inside `runAsync`).
  Future<void> flushReal(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'refreshListenable notifications debounce (100 ms) into a row re-read',
    (WidgetTester tester) async {
      final LocalDb db =
          (await tester.runAsync(() => openDb('refresh.db')))!;
      await tester.runAsync(
        () async {
          await db.insertCanvas(record('r1', 'Seeded Row', 1000));
        },
      );

      final ValueNotifier<int> hub = ValueNotifier<int>(0);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeCanvasDashboard(
            onOpenDocument: (_) {},
            db: db,
            baseDir: cacheDir,
            refreshListenable: hub,
          ),
        ),
      );
      await flushReal(tester);
      expect(find.text('Seeded Row'), findsOneWidget);

      // A hub/peer write lands out-of-band (silent store mutation, §9.1):
      // the dashboard must NOT re-read until notified.
      await tester.runAsync(
        () => db.insertCanvas(record('r2', 'Hub Arrival', 2000)),
      );
      await flushReal(tester);
      expect(
        find.text('Hub Arrival'),
        findsNothing,
        reason: 'rows only change via an explicit refresh trigger',
      );

      // Notify → 100 ms debounce: still absent at +50 ms…
      hub.value += 1;
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.text('Hub Arrival'),
        findsNothing,
        reason: 'refresh must be debounced (100 ms), not immediate',
      );
      // …present once the debounce elapses and the query lands.
      await flushReal(tester, rounds: 4);
      expect(find.text('Hub Arrival'), findsOneWidget);

      // A burst of notifications restarts the debounce each time — one
      // coalesced re-read shows the final row set, correctly, once.
      await tester.runAsync(
        () => db.insertCanvas(record('r3', 'Burst Row', 3000)),
      );
      hub.value += 1;
      await tester.pump(const Duration(milliseconds: 40));
      hub.value += 1;
      await tester.pump(const Duration(milliseconds: 40));
      hub.value += 1;
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        find.text('Burst Row'),
        findsNothing,
        reason: 'each notification restarts the 100 ms coalescing window',
      );
      await flushReal(tester, rounds: 4);
      expect(find.text('Burst Row'), findsOneWidget);
      expect(find.text('Hub Arrival'), findsOneWidget);
      expect(find.text('Seeded Row'), findsOneWidget);

      // Unmount removes the listener — later notifications are harmless.
      await tester.pumpWidget(const SizedBox.shrink());
      hub.value += 1;
      await tester.pump();
      hub.dispose();
    },
  );

  testWidgets(
    'default refreshListenable (null) keeps existing constructions working',
    (WidgetTester tester) async {
      final LocalDb db =
          (await tester.runAsync(() => openDb('plain.db')))!;
      await tester.runAsync(
        () => db.insertCanvas(record('p1', 'Plain Row', 1000)),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: HomeCanvasDashboard(
            onOpenDocument: (_) {},
            db: db,
            baseDir: cacheDir,
          ),
        ),
      );
      await flushReal(tester);
      expect(find.text('Plain Row'), findsOneWidget);
      expect(
        tester.widget<HomeCanvasDashboard>(find.byType(HomeCanvasDashboard))
            .refreshListenable,
        isNull,
      );
    },
  );
}
