/// Round-12 issues 05 / 09 — the new tools as wired into the canvas page.
///
/// The models are covered by their own tests; what matters here is that
/// dragging with a tool actually commits the *right* node shape, because a
/// silently wrong `shape_type` or a missing `graph_config` would only show up
/// as "my polygon does not appear on the PC".
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/polygon_geometry.dart';
import 'package:mobile_app/canvas_engine/text_box_model.dart';
import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/canvas/canvas_studio_page.dart';
import 'package:mobile_app/features/canvas/text_box_editor.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart';
import 'package:mobile_app/network/vector_sync_client.dart';

class _FakeSyncClient extends VectorSyncClient {
  _FakeSyncClient();

  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  final StreamController<SyncEvent> _ctrl =
      StreamController<SyncEvent>.broadcast();

  @override
  bool get isConnected => true;

  @override
  Stream<SyncEvent> get events => _ctrl.stream;

  @override
  Future<void> sendRpc(Map<String, dynamic> envelope) async {
    for (final String field in const <String>[
      'type',
      'action',
      'canvas_id',
      'payload',
    ]) {
      if (!envelope.containsKey(field)) {
        throw FormatException('missing envelope field: $field');
      }
    }
    sent.add(Map<String, dynamic>.from(envelope));
  }

  void emit(Map<String, dynamic> message) {
    _ctrl.add(SyncEvent(kind: SyncEventKind.rpcReceived, msg: message));
  }

  List<Map<String, dynamic>> ofAction(String action) => sent
      .where((Map<String, dynamic> e) => e['action'] == action)
      .toList(growable: false);

  @override
  Future<void> dispose() async {
    await _ctrl.close();
    await super.dispose();
  }
}

CanvasDocumentModel _doc({String preset = 'A4'}) => buildNewCanvasDocument(
      title: 'Round 12',
      preset: preset,
      background: 'BLANK',
      canvasId: '11111111-1111-4111-8111-111111111111',
      now: 1000,
    );

Future<void> _pumpStudio(
  WidgetTester tester,
  _FakeSyncClient client, {
  String preset = 'A4',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasStudioPage(document: _doc(preset: preset), client: client),
    ),
  );
  await tester.pump();
}

/// Selects [tool] through the dock's rail.
Future<void> _pickTool(WidgetTester tester, StudioTool tool) async {
  final Finder button = find.byKey(ValueKey<String>('tool-${tool.name}'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 50));
}

/// Drags on the canvas from a to b in screen coordinates.
Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 4,
}) async {
  final TestGesture gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 16));
  for (int i = 1; i <= steps; i++) {
    final Offset point = Offset.lerp(from, to, i / steps)!;
    await gesture.moveTo(point);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the polygon tool commits a PATH shape with the right vertex count',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.polygon);
    await _drag(tester, const Offset(300, 250), const Offset(480, 400));

    final List<Map<String, dynamic>> adds = client.ofAction('ADD_SHAPE');
    expect(adds, hasLength(1), reason: 'one polygon per drag');
    final Map<String, dynamic> geometry =
        adds.single['payload']['geometry'] as Map<String, dynamic>;
    expect(geometry['shape_type'], 'PATH');
    // A hexagon by default, plus the 6 vertices in `pts`.
    expect((geometry['pts'] as List<dynamic>).length, 6);
    await _dispose(tester, client);
  });

  testWidgets('a polygon is never emitted as a RECT', (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.polygon);
    await _drag(tester, const Offset(300, 250), const Offset(480, 400));
    final Map<String, dynamic> geometry = client.ofAction('ADD_SHAPE').single['payload']['geometry']
        as Map<String, dynamic>;
    expect(geometry['shape_type'], isNot('RECT'),
        reason: 'a rounded/rect polygon would fill on the PC as a rectangle');
    await _dispose(tester, client);
  });

  testWidgets('the text tool commits a TEXT shape carrying graph_config',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.text);
    await _drag(tester, const Offset(320, 300), const Offset(520, 380));

    final List<Map<String, dynamic>> adds = client.ofAction('ADD_SHAPE');
    expect(adds, hasLength(1));
    final Map<String, dynamic> geometry =
        adds.single['payload']['geometry'] as Map<String, dynamic>;
    expect(geometry['shape_type'], 'TEXT');
    final Map<String, dynamic>? config =
        geometry['graph_config'] as Map<String, dynamic>?;
    expect(config, isNotNull, reason: 'the text has nowhere else to live');
    expect(config!.containsKey('text'), isTrue);
    expect(config.containsKey('font_size'), isTrue);
    await _dispose(tester, client);
  });

  testWidgets('committing a text box opens the keyboard editor',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.text);
    await _drag(tester, const Offset(320, 300), const Offset(520, 380));
    expect(find.byKey(const ValueKey<String>('text-box-editor')),
        findsOneWidget);
    await _dispose(tester, client);
  });

  testWidgets('typing and confirming rewrites the node config',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.text);
    await _drag(tester, const Offset(320, 300), const Offset(520, 380));

    await tester.enterText(
      find.byKey(const ValueKey<String>('text-box-field')),
      'Buy milk',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('text-box-save')));
    await tester.pumpAndSettle();

    final List<Map<String, dynamic>> adds = client.ofAction('ADD_SHAPE');
    final Map<String, dynamic> last =
        adds.last['payload']['geometry']['graph_config']
            as Map<String, dynamic>;
    expect(last['text'], 'Buy milk');
    await _dispose(tester, client);
  });

  testWidgets('cancelling the editor keeps the original empty text',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.text);
    await _drag(tester, const Offset(320, 300), const Offset(520, 380));
    final int before = client.ofAction('ADD_SHAPE').length;

    await tester.enterText(
      find.byKey(const ValueKey<String>('text-box-field')),
      'discard me',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('text-box-cancel')));
    await tester.pumpAndSettle();

    expect(client.ofAction('ADD_SHAPE').length, before,
        reason: 'a cancelled edit must not send a second commit');
    await _dispose(tester, client);
  });

  testWidgets('the OCR tool draws an outline instead of committing ink',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);
    await _pickTool(tester, StudioTool.ocr);
    await _drag(tester, const Offset(300, 250), const Offset(480, 400));

    expect(client.ofAction('ADD_SHAPE'), isEmpty,
        reason: 'circling text is a selection, not a drawing');
    expect(client.ofAction('ADD_STROKE'), isEmpty);
    expect(client.ofAction('START_OCR'), isEmpty,
        reason: 'the scan is started explicitly, not on pen-lift');
    await _dispose(tester, client);
  });

  testWidgets('the focus toggle hides the dock and can bring it back',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    expect(find.byKey(const ValueKey<String>('tool-pen')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('focus-enter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tool-pen')), findsNothing,
        reason: 'focus mode hides the tool rail');
    expect(find.byKey(const ValueKey<String>('focus-exit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('focus-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tool-pen')), findsOneWidget);
    await _dispose(tester, client);
  });

  group('OCR property panel', () {
    /// Selects OCR and opens its property panel the way a user does: a
    /// 500 ms press-and-hold on the rail button.
    Future<void> openOcrPanel(WidgetTester tester) async {
      final Finder button = find.byKey(const ValueKey<String>('tool-ocr'));
      await tester.ensureVisible(button);
      await tester.pump();
      final TestGesture hold =
          await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await hold.up();
      await tester.pump();
    }

    testWidgets('an infinite canvas disables the whole-canvas scan',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client, preset: 'INFINITE');
      await openOcrPanel(tester);

      expect(find.byKey(const ValueKey<String>('property-overlay-panel')),
          findsOneWidget);
      final Finder scanCanvas =
          find.byKey(const ValueKey<String>('ocr-scan-canvas'));
      expect(scanCanvas, findsOneWidget);
      expect(tester.widget<OutlinedButton>(scanCanvas).onPressed, isNull,
          reason: 'an infinite canvas has no bounded area to scan');
      expect(find.byKey(const ValueKey<String>('ocr-infinite-note')),
          findsOneWidget);
      await _dispose(tester, client);
    });

    testWidgets('a bounded canvas allows the whole-canvas scan',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await openOcrPanel(tester);

      final Finder scanCanvas =
          find.byKey(const ValueKey<String>('ocr-scan-canvas'));
      expect(scanCanvas, findsOneWidget);
      expect(tester.widget<OutlinedButton>(scanCanvas).onPressed, isNotNull);
      await _dispose(tester, client);
    });

    testWidgets('scan-selection stays disabled until an outline exists',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await openOcrPanel(tester);
      final Finder scanSelection =
          find.byKey(const ValueKey<String>('ocr-scan-selection'));
      expect(tester.widget<FilledButton>(scanSelection).onPressed, isNull,
          reason: 'nothing has been circled yet');
      await _dispose(tester, client);
    });

    testWidgets('circling an area enables scan-selection and sends START_OCR',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await _pickTool(tester, StudioTool.ocr);
      await _drag(tester, const Offset(320, 300), const Offset(520, 400));
      await tester.pumpAndSettle();
      await openOcrPanel(tester);
      await tester.pumpAndSettle();

      final Finder scanSelection =
          find.byKey(const ValueKey<String>('ocr-scan-selection'));
      expect(find.byKey(const ValueKey<String>('property-overlay-panel')),
          findsOneWidget,
          reason: 'the OCR property panel must be open');
      expect(tester.widget<FilledButton>(scanSelection).onPressed, isNotNull,
          reason: 'a free-drawn loop was made, so a region scan is possible');
      await tester.tap(scanSelection);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final List<Map<String, dynamic>> starts = client.ofAction('START_OCR');
      expect(starts, hasLength(1));
      final Map<String, dynamic> payload =
          starts.single['payload'] as Map<String, dynamic>;
      expect(payload['scope'], 'region');
      expect((payload['path'] as List<dynamic>).length,
          greaterThanOrEqualTo(3));
      await _dispose(tester, client);
    });

    testWidgets('scanning the canvas sends scope=canvas with no path',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await openOcrPanel(tester);

      await tester.tap(find.byKey(const ValueKey<String>('ocr-scan-canvas')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final List<Map<String, dynamic>> starts = client.ofAction('START_OCR');
      expect(starts, hasLength(1));
      final Map<String, dynamic> payload =
          starts.single['payload'] as Map<String, dynamic>;
      expect(payload['scope'], 'canvas');
      expect(payload.containsKey('path'), isFalse);
      await _dispose(tester, client);
    });

    testWidgets('a returned result becomes an editable TEXT node',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await openOcrPanel(tester);
      await tester.tap(find.byKey(const ValueKey<String>('ocr-scan-canvas')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final String jobId = client.ofAction('START_OCR').single['payload']
          ['job_id'] as String;
      client.emit(<String, dynamic>{
        'type': 'OCR_JOB',
        'action': 'OCR_RESULT',
        'canvas_id': '11111111-1111-4111-8111-111111111111',
        'payload': <String, dynamic>{
          'job_id': jobId,
          'text': 'scanned notes',
          'provider': 'DmlExecutionProvider',
          'lines': <Map<String, dynamic>>[
            <String, dynamic>{
              'text': 'scanned notes',
              'score': 0.99,
              'box': <double>[0, 0, 100, 20],
            },
          ],
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final List<Map<String, dynamic>> adds = client.ofAction('ADD_SHAPE');
      expect(adds, hasLength(1),
          reason: 'the recognised text lands on the canvas');
      final Map<String, dynamic> geometry =
          adds.single['payload']['geometry'] as Map<String, dynamic>;
      expect(geometry['shape_type'], 'TEXT');
      final Map<String, dynamic> config =
          geometry['graph_config'] as Map<String, dynamic>;
      expect(config['text'], 'scanned notes');
      await _dispose(tester, client);
    });

    testWidgets('a failed scan shows why and adds nothing',
        (WidgetTester tester) async {
      final _FakeSyncClient client = _FakeSyncClient();
      await _pumpStudio(tester, client);
      await openOcrPanel(tester);
      await tester.tap(find.byKey(const ValueKey<String>('ocr-scan-canvas')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final String jobId = client.ofAction('START_OCR').single['payload']
          ['job_id'] as String;
      client.emit(<String, dynamic>{
        'type': 'OCR_JOB',
        'action': 'OCR_RESULT',
        'canvas_id': '11111111-1111-4111-8111-111111111111',
        'payload': <String, dynamic>{
          'job_id': jobId,
          'text': '',
          'error': 'OCR engine missing',
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(client.ofAction('ADD_SHAPE'), isEmpty);
      expect(find.byKey(const ValueKey<String>('ocr-error')), findsOneWidget);
      expect(find.text('OCR engine missing'), findsOneWidget);
      await _dispose(tester, client);
    });
  });

  testWidgets('the focus toggle hides the dock and can bring it back',
      (WidgetTester tester) async {
    final _FakeSyncClient client = _FakeSyncClient();
    await _pumpStudio(tester, client);

    expect(find.byKey(const ValueKey<String>('tool-pen')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('focus-enter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tool-pen')), findsNothing,
        reason: 'focus mode hides the tool rail');
    expect(find.byKey(const ValueKey<String>('focus-exit')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('focus-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('tool-pen')), findsOneWidget);
    await _dispose(tester, client);
  });

  group('polygon geometry helpers used by the commit path', () {
    test('a square box yields six evenly spread vertices', () {
      final List<Offset> pts = regularPolygonInBox(
        const Rect.fromLTWH(0, 0, 100, 100),
        sides: 6,
      );
      expect(pts, hasLength(6));
    });

    test('the vertices stay inside the drag box', () {
      const Rect box = Rect.fromLTWH(10, 20, 80, 60);
      for (final Offset p in regularPolygonInBox(box, sides: 6)) {
        expect(p.dx, greaterThanOrEqualTo(box.left - 0.01));
        expect(p.dx, lessThanOrEqualTo(box.right + 0.01));
        expect(p.dy, greaterThanOrEqualTo(box.top - 0.01));
        expect(p.dy, lessThanOrEqualTo(box.bottom + 0.01));
      }
    });

    test('the wire form is x/y pairs', () {
      final List<List<double>> wire =
          polygonPts(regularPolygonInBox(const Rect.fromLTWH(0, 0, 10, 10)));
      expect(wire, isNotEmpty);
      for (final List<double> point in wire) {
        expect(point, hasLength(2));
      }
    });
  });

  group('text box round trip through graph_config', () {
    test('a committed config reads back with the same text', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(0, 0, 200, 80),
        text: 'Scan result line 1\nline 2',
        fontSize: 20,
        align: 'center',
      );
      final TextBoxModel back = TextBoxModel.fromGraphConfig(
        box.toGraphConfig(),
        box.rect,
      );
      expect(back.text, box.text);
      expect(back.fontSize, box.fontSize);
      expect(back.align, box.align);
    });

    test('an empty text box is still valid to commit', () {
      const TextBoxModel box = TextBoxModel(rect: Rect.fromLTWH(0, 0, 120, 40));
      final Map<String, dynamic> wire = box.toGraphConfig();
      expect(wire['text'], '');
      expect(wire['font_size'], isA<double>());
    });

    test('the editor result maps onto the model without dropping fields', () {
      const TextBoxEdit edit = TextBoxEdit(
        text: 'hello',
        fontSize: 32,
        align: 'right',
      );
      const TextBoxModel base = TextBoxModel(
        rect: Rect.fromLTWH(5, 5, 100, 50),
      );
      final TextBoxModel after = base.copyWith(
        text: edit.text,
        fontSize: edit.fontSize,
        align: edit.align,
      );
      expect(after.text, 'hello');
      expect(after.fontSize, 32);
      expect(after.align, 'right');
      expect(after.rect, base.rect, reason: 'the box keeps its geometry');
    });

    test('the committed node JSON is serialisable end to end', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(0, 0, 200, 80),
        text: 'round trip',
      );
      final Map<String, dynamic> node = <String, dynamic>{
        'node_id': 'n-1',
        'kind': 'SHAPE',
        'layer': 1,
        'bbox': <double>[0, 0, 200, 80],
        'geometry': <String, dynamic>{
          'pts': <List<double>>[
            <double>[0, 0],
            <double>[200, 80],
          ],
          'shape_type': 'TEXT',
          'graph_config': box.toGraphConfig(),
        },
      };
      final String encoded = jsonEncode(node);
      final Map<String, dynamic> decoded =
          jsonDecode(encoded) as Map<String, dynamic>;
      final TextBoxModel back = TextBoxModel.fromGraphConfig(
        Map<String, dynamic>.from(
          decoded['geometry']['graph_config'] as Map,
        ),
        box.rect,
      );
      expect(back.text, 'round trip');
    });
  });
}

Future<void> _dispose(WidgetTester tester, _FakeSyncClient client) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await client.dispose();
}
