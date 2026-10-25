/// Round-12 issue 09 — OCR tool UI tests.
///
/// The interesting behaviour is not the widgets themselves but the policy they
/// encode: when the whole-canvas scan must be unavailable, that a failed scan
/// says why, and that "no text found" is not dressed up as success.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/features/ocr/ocr_client.dart';
import 'package:mobile_app/features/ocr/ocr_panel.dart';
import 'package:mobile_app/features/ocr/ocr_selection_painter.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

OcrPanel _panel({
  bool canvasIsInfinite = false,
  bool running = false,
  String stage = 'QUEUED',
  double percent = 0,
  bool hasSelection = false,
  String? errorText,
  String? resultSummary,
  VoidCallback? onScanSelection,
  VoidCallback? onScanCanvas,
  VoidCallback? onCancel,
}) =>
    OcrPanel(
      canvasIsInfinite: canvasIsInfinite,
      running: running,
      stage: stage,
      percent: percent,
      hasSelection: hasSelection,
      errorText: errorText,
      resultSummary: resultSummary,
      onScanSelection: onScanSelection ?? () {},
      onScanCanvas: onScanCanvas ?? () {},
      onCancel: onCancel ?? () {},
    );

void main() {
  group('OcrSelectionPath', () {
    test('it starts empty and unusable', () {
      final OcrSelectionPath path = OcrSelectionPath();
      expect(path.isEmpty, isTrue);
      expect(path.isUsable, isFalse);
      expect(path.bounds, isNull);
    });

    test('fewer than three points can never enclose an area', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0)
        ..add(const Offset(0, 0))
        ..add(const Offset(100, 0));
      expect(path.isUsable, isFalse);
    });

    test('three spread points are usable and give bounds', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0)
        ..add(const Offset(10, 20))
        ..add(const Offset(110, 20))
        ..add(const Offset(60, 90));
      expect(path.isUsable, isTrue);
      expect(path.bounds, const Rect.fromLTRB(10, 20, 110, 90));
    });

    test('samples closer than the spacing are dropped', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 5);
      expect(path.add(const Offset(0, 0)), isTrue);
      expect(path.add(const Offset(1, 1)), isFalse);
      expect(path.add(const Offset(6, 0)), isTrue);
      expect(path.points.length, 2);
    });

    test('every sample is kept when spacing is zero', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0);
      for (int i = 0; i < 10; i++) {
        path.add(Offset(i.toDouble(), 0));
      }
      expect(path.points.length, 10);
    });

    test('non-finite points are rejected', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0);
      expect(path.add(const Offset(double.nan, 0)), isFalse);
      expect(path.add(const Offset(0, double.infinity)), isFalse);
      expect(path.add(const Offset(double.negativeInfinity, 5)), isFalse);
      expect(path.points, isEmpty);
    });

    test('a degenerate outline has no bounds', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0)
        ..add(const Offset(5, 5))
        ..add(const Offset(5, 5))
        ..add(const Offset(5, 6));
      expect(path.bounds, isNull, reason: 'zero width encloses nothing');
      expect(path.isUsable, isFalse);
    });

    test('clear empties it', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0)
        ..add(const Offset(0, 0))
        ..add(const Offset(10, 0))
        ..add(const Offset(10, 10));
      path.clear();
      expect(path.isEmpty, isTrue);
      expect(path.toWire(), isEmpty);
    });

    test('toWire produces x/y pairs', () {
      final OcrSelectionPath path = OcrSelectionPath(minSpacing: 0)
        ..add(const Offset(1.5, 2.5))
        ..add(const Offset(3, 4));
      expect(
        path.toWire(),
        <List<double>>[
          <double>[1.5, 2.5],
          <double>[3, 4],
        ],
      );
    });
  });

  group('OcrSelectionPainter', () {
    test('it repaints when the points change', () {
      final OcrSelectionPainter a = OcrSelectionPainter(
        viewMatrix: Matrix4.identity(),
        points: const <Offset>[Offset(0, 0), Offset(5, 0), Offset(5, 5)],
      );
      final OcrSelectionPainter b = OcrSelectionPainter(
        viewMatrix: Matrix4.identity(),
        points: const <Offset>[Offset(0, 0), Offset(9, 0), Offset(9, 9)],
      );
      expect(a.shouldRepaint(b), isTrue);
    });

    test('it does not repaint for identical points', () {
      const List<Offset> pts = <Offset>[Offset(0, 0), Offset(5, 0), Offset(5, 5)];
      final OcrSelectionPainter a = OcrSelectionPainter(
        viewMatrix: Matrix4.identity(),
        points: pts,
      );
      final OcrSelectionPainter b = OcrSelectionPainter(
        viewMatrix: Matrix4.identity(),
        points: pts,
      );
      expect(a.shouldRepaint(b), isFalse);
    });

    test('an empty outline is a no-op and does not throw', () {
      final OcrSelectionPainter painter = OcrSelectionPainter(
        viewMatrix: Matrix4.identity(),
        points: const <Offset>[],
      );
      // Painting an empty path must not raise.
      expect(
        () => painter.paint(Canvas(ui.PictureRecorder()), const Size(100, 100)),
        returnsNormally,
      );
    });
  });

  group('OcrPanel', () {
    testWidgets('it offers both scan actions when idle and bounded',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel()));
      expect(find.byKey(OcrPanel.scanSelectionKey), findsOneWidget);
      expect(find.byKey(OcrPanel.scanCanvasKey), findsOneWidget);
    });

    testWidgets('scan-selection is disabled until an outline exists',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(hasSelection: false)));
      final FilledButton button = tester.widget<FilledButton>(
        find.byKey(OcrPanel.scanSelectionKey),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('scan-selection is enabled once an outline exists',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(hasSelection: true)));
      final FilledButton button = tester.widget<FilledButton>(
        find.byKey(OcrPanel.scanSelectionKey),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('whole-canvas scan is DISABLED on an infinite canvas',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(canvasIsInfinite: true)));
      final OutlinedButton button = tester.widget<OutlinedButton>(
        find.byKey(OcrPanel.scanCanvasKey),
      );
      expect(button.onPressed, isNull,
          reason: 'an infinite canvas has no bounded area to scan');
      expect(find.byKey(const ValueKey<String>('ocr-infinite-note')),
          findsOneWidget);
    });

    testWidgets('whole-canvas scan is enabled on a bounded canvas',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(canvasIsInfinite: false)));
      final OutlinedButton button = tester.widget<OutlinedButton>(
        find.byKey(OcrPanel.scanCanvasKey),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('the actions disappear while a job runs',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(running: true)));
      expect(find.byKey(OcrPanel.scanSelectionKey), findsNothing);
      expect(find.byKey(const ValueKey<String>('ocr-progress')),
          findsOneWidget);
    });

    testWidgets('progress shows a human stage label and a cancel button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_panel(running: true, stage: 'RECOGNISING', percent: 60)),
      );
      expect(find.textContaining('Reading the text'), findsOneWidget);
      expect(find.textContaining('60%'), findsOneWidget);
      expect(find.byKey(OcrPanel.cancelKey), findsOneWidget);
    });

    testWidgets('an unknown stage still reads sensibly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_panel(running: true, stage: 'SOMETHING_NEW', percent: 10)),
      );
      expect(find.textContaining('Scanning'), findsOneWidget);
    });

    testWidgets('a zero percent shows an indeterminate bar, not a stuck zero',
        (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(running: true, percent: 0)));
      final LinearProgressIndicator bar =
          tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);
    });

    testWidgets('an error is shown and is not mistaken for success',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_panel(errorText: 'engine missing')),
      );
      expect(find.byKey(const ValueKey<String>('ocr-error')), findsOneWidget);
      expect(find.text('engine missing'), findsOneWidget);
    });

    testWidgets('a result summary is shown', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(_panel(resultSummary: 'Added 3 lines (GPU in 2.1s)')),
      );
      expect(find.byKey(const ValueKey<String>('ocr-result-summary')),
          findsOneWidget);
    });

    testWidgets('an empty error string shows nothing', (WidgetTester tester) async {
      await tester.pumpWidget(_host(_panel(errorText: '')));
      expect(find.byKey(const ValueKey<String>('ocr-error')), findsNothing);
    });

    testWidgets('cancel invokes its callback', (WidgetTester tester) async {
      bool cancelled = false;
      await tester.pumpWidget(
        _host(_panel(running: true, onCancel: () => cancelled = true)),
      );
      await tester.tap(find.byKey(OcrPanel.cancelKey));
      expect(cancelled, isTrue);
    });

    testWidgets('scan-selection invokes its callback', (WidgetTester tester) async {
      bool scanned = false;
      await tester.pumpWidget(
        _host(_panel(
          hasSelection: true,
          onScanSelection: () => scanned = true,
        )),
      );
      await tester.tap(find.byKey(OcrPanel.scanSelectionKey));
      expect(scanned, isTrue);
    });
  });

  group('describeOcrOutcome', () {
    test('it names the GPU when DirectML did the work', () {
      const OcrOutcome outcome = OcrOutcome(
        text: 'a\nb',
        provider: 'DmlExecutionProvider',
        lines: <OcrLine>[
          OcrLine(text: 'a', score: 1, box: <double>[0, 0, 1, 1]),
          OcrLine(text: 'b', score: 1, box: <double>[0, 2, 1, 3]),
        ],
        elapsedMs: 2100,
      );
      final String described = describeOcrOutcome(outcome);
      expect(described, contains('2 lines'));
      expect(described, contains('GPU'));
      expect(described, contains('2.1s'));
    });

    test('it says "CPU" when the GPU was not used', () {
      const OcrOutcome outcome = OcrOutcome(
        text: 'a',
        provider: 'CPUExecutionProvider',
        lines: <OcrLine>[OcrLine(text: 'a', score: 1, box: <double>[0, 0, 1, 1])],
      );
      expect(describeOcrOutcome(outcome), contains('CPU'));
    });

    test('one line is singular', () {
      const OcrOutcome outcome = OcrOutcome(
        text: 'a',
        lines: <OcrLine>[OcrLine(text: 'a', score: 1, box: <double>[0, 0, 1, 1])],
      );
      expect(describeOcrOutcome(outcome), contains('1 line'));
      expect(describeOcrOutcome(outcome), isNot(contains('1 lines')));
    });

    test('no text is reported honestly, not as success', () {
      const OcrOutcome outcome = OcrOutcome(text: '   ');
      final String described = describeOcrOutcome(outcome);
      expect(described, contains('No text found'));
    });
  });
}
