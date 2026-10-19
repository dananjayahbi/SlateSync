/// Issue 02 regression: "Can't open a canvas — SnackBar: Could not open
/// canvas: Null check operator used on a null value."
///
/// Drives the REAL shell (`SlateSyncApp` from `lib/main.dart`, no injected
/// `LocalDb`/`baseDir` seams): create a canvas through the New Canvas modal,
/// tap its gallery card, and expect navigation to [CanvasStudioPage] with the
/// loaded document.
///
/// All scratch state lives under `test/.open_canvas_regression_tmp/` inside
/// the package (never `/tmp`) and is removed in `tearDownAll`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const MethodChannel pathChannel =
      MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmpRoot;
  late String dbFilePath;

  setUpAll(() {
    tmpRoot = Directory(
      'test/.open_canvas_regression_tmp/${DateTime.now().microsecondsSinceEpoch}',
    );
    tmpRoot.createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (MethodCall call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getTemporaryDirectory':
          return tmpRoot.path;
      }
      return null;
    });
  });

  setUp(() async {
    // The real shell opens `slatesync.db` through the default databases path;
    // wipe it so leftovers from earlier runs cannot skew the gallery.
    final String base = await getDatabasesPath();
    dbFilePath = '$base${Platform.pathSeparator}slatesync.db';
    await deleteDatabase(dbFilePath);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    final String base = await getDatabasesPath();
    try {
      await deleteDatabase('$base${Platform.pathSeparator}slatesync.db');
    } catch (_) {
      // best effort
    }
    try {
      if (tmpRoot.existsSync()) {
        tmpRoot.deleteSync(recursive: true);
      }
    } catch (_) {
      // best effort
    }
  });

  /// Real event-loop windows interleaved with frame pumps — `testWidgets`
  /// runs on a fake clock, so sqflite/file futures (ffi isolate ports) parked
  /// from the fake zone only progress while `runAsync` gives them real time.
  Future<void> flushReal(WidgetTester tester, {int rounds = 6}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// First error surfaced by the dashboard `_open()` catch, if any.
  String? openError(WidgetTester tester) {
    for (final Text t in tester.widgetList<Text>(find.byType(Text))) {
      final String data = t.data ?? t.textSpan?.toPlainText() ?? '';
      if (data.startsWith('Could not open canvas')) {
        return data;
      }
    }
    return null;
  }

  testWidgets(
    'real shell: create canvas then tap card opens CanvasStudioPage',
    (WidgetTester tester) async {
      await tester.pumpWidget(const SlateSyncApp());
      await flushReal(tester);

      // Empty gallery → New Canvas modal.
      expect(find.byKey(const Key('empty_gallery')), findsOneWidget);
      await tester.tap(find.byKey(const Key('new_canvas_fab')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('new_title_field')),
        'Regression Canvas',
      );

      // Create. The very first ffi `LocalDb.open()` (isolate spawn + schema)
      // may still be in flight, so retry the create until the modal pops —
      // each attempt yields real-time windows for `_init` to finish. The
      // error path (`LocalDb is not ready yet`) performs no writes, so the
      // retry cannot duplicate rows.
      for (int i = 0; i < 40; i++) {
        // warnIfMissed: false — mid-retry the button may legitimately be
        // disabled (`_busy`) while an earlier attempt is still in flight.
        await tester.tap(
          find.byKey(const Key('create_canvas')),
          warnIfMissed: false,
        );
        await flushReal(tester, rounds: 3);
        if (find.byType(AlertDialog).evaluate().isEmpty) {
          break;
        }
      }
      await flushReal(tester, rounds: 6); // grid refresh (db.list)
      await tester.pump();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const Key('canvas_grid')), findsOneWidget);
      expect(find.text('Regression Canvas'), findsOneWidget);

      // Open the canvas — this is the reported failure path.
      await tester.tap(find.text('Regression Canvas'));
      await flushReal(tester); // loadDocument + push + first studio frame

      // Diagnosis hook: fail with the EXACT caught message (Issue 02 report
      // shows `Null check operator used on a null value`; debug builds may
      // show the underlying Navigator.of assertion first).
      expect(
        openError(tester),
        isNull,
        reason: 'Opening a canvas must not surface an error SnackBar',
      );

      await tester.pumpAndSettle();
      expect(find.byType(CanvasStudioPage), findsOneWidget);

      // Unmount so the studio autosave timer and client subscription are
      // cancelled before the test ends.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
