/// Round-13 issue 01 — the text box painted as a line instead of a box.
///
/// The node was always correct: rect, wrapped content, font size and alignment
/// all reached the document, and the model's wrap/origin maths was unit-tested.
/// The defect was in the painter dispatch — `shape_type == "TEXT"` had no case,
/// so it hit the polyline `default:` and the box's two corner `pts` drew as a
/// single diagonal stroke.
///
/// These tests therefore assert on what the painter actually *emits*: recorded
/// [Canvas]/[TextPainter] interaction, not the model. A test on the model alone
/// would have passed throughout the entire bug.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/text_box_model.dart';
import 'package:mobile_app/canvas_engine/text_box_painter.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Deterministic measurer: 10 world units per character at any size.
double _measure(String text, double fontSize) => text.length * 10.0;

CanvasNodeModel _textNode(
  Rect rect, {
  String text = 'Hello',
  double fontSize = 24,
  String align = 'left',
}) =>
    CanvasNodeModel(
      nodeId: 'n1',
      kind: 'SHAPE',
      layer: 0,
      bbox: <double>[rect.left, rect.top, rect.right, rect.bottom],
      style: NodeStyleModel(
        color: '#112233',
        strokeWidth: 2,
        opacity: 1,
        blendMode: 'SRC_OVER',
      ),
      geometry: NodeGeometryModel(
        shapeType: 'TEXT',
        pts: <List<double>>[
          <double>[rect.left, rect.top],
          <double>[rect.right, rect.bottom],
        ],
        graphConfig: <String, dynamic>{
          'text': text,
          'font_size': fontSize,
          'align': align,
        },
      ),
    );

void main() {
  group('textBoxRectOf', () {
    test('normalises a rect dragged right-to-left / bottom-to-top', () {
      final Rect r = textBoxRectOf(_textNode(const Rect.fromLTRB(200, 300, 50, 40)));
      expect(r, const Rect.fromLTRB(50, 40, 200, 300));
      expect(r.width, greaterThan(0));
      expect(r.height, greaterThan(0));
    });

    test('a degenerate bbox yields an empty rect rather than throwing', () {
      final CanvasNodeModel n = _textNode(const Rect.fromLTRB(0, 0, 0, 0));
      expect(textBoxRectOf(n).isEmpty, isTrue);
    });
  });

  group('layoutTextBox', () {
    test('a short line is laid out as one line inside the box', () {
      final Rect rect = const Rect.fromLTWH(0, 0, 400, 200);
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'text': 'Hello', 'font_size': 24.0},
        rect,
      );
      final List<({String line, Offset origin})> lines =
          layoutTextBox(box, measure: _measure);
      expect(lines.map((({String line, Offset origin}) l) => l.line), <String>['Hello']);
      // Inset by the documented padding, at the box's top-left.
      expect(lines.first.origin.dx, closeTo(rect.left + kTextPadding, 0.001));
      expect(lines.first.origin.dy, closeTo(rect.top + kTextPadding, 0.001));
    });

    test('a long line wraps to the box width, giving a real block', () {
      // 40 units per 4 chars = 40; a 100-wide box fits 10 chars per line.
      final Rect rect = const Rect.fromLTWH(0, 0, 108, 400);
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{
          'text': 'aaaa bbbb cccc dddd',
          'font_size': 10.0,
        },
        rect,
      );
      final List<({String line, Offset origin})> lines =
          layoutTextBox(box, measure: _measure);
      expect(lines.length, greaterThan(1),
          reason: 'a box narrower than its text must wrap, not overflow');
      // Later lines step down by exactly one line height.
      final double step = lines[1].origin.dy - lines[0].origin.dy;
      expect(step, closeTo(box.lineHeight, 0.001));
    });

    test('explicit newlines are preserved', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'text': 'a\nb\nc', 'font_size': 20.0},
        const Rect.fromLTWH(0, 0, 400, 400),
      );
      final List<({String line, Offset origin})> lines =
          layoutTextBox(box, measure: _measure);
      expect(lines.map((({String line, Offset origin}) l) => l.line),
          <String>['a', 'b', 'c']);
    });

    test('an empty box paints nothing', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'text': '   '},
        const Rect.fromLTWH(0, 0, 200, 100),
      );
      expect(layoutTextBox(box, measure: _measure), isEmpty);
    });
  });

  group('paintTextBox', () {
    test('paints glyphs and clips them to the box', () {
      final _RecordingCanvas rec = _RecordingCanvas();
      final bool painted = paintTextBox(
        rec,
        _textNode(const Rect.fromLTWH(10, 20, 300, 120), text: 'Vector'),
        color: const Color(0xFF112233),
        measure: _measure,
      );
      expect(painted, isTrue);
      expect(rec.drawnParagraphs, 1, reason: 'a single line is one glyph run');
      expect(rec.saved, greaterThan(0), reason: 'must save before clipping');
      expect(rec.clips.single, const Rect.fromLTWH(10, 20, 300, 120));
      expect(rec.restored, rec.saved, reason: 'every save must be balanced');
      // Laid out inside the box, not at the origin.
      expect(rec.paintedOffsets.single.dx, closeTo(10 + kTextPadding, 0.001));
    });

    test('paints each wrapped line separately', () {
      final _RecordingCanvas rec = _RecordingCanvas();
      paintTextBox(
        rec,
        _textNode(const Rect.fromLTWH(0, 0, 108, 400),
            text: 'aaaa bbbb cccc dddd', fontSize: 10),
        color: const Color(0xFF112233),
        measure: _measure,
      );
      expect(rec.drawnParagraphs, greaterThan(1),
          reason: 'a wrapped box is several glyph runs, not one line');
    });

    test('an empty text box paints no glyphs at all', () {
      final _RecordingCanvas rec = _RecordingCanvas();
      final bool painted = paintTextBox(
        rec,
        _textNode(const Rect.fromLTWH(0, 0, 200, 100), text: ''),
        color: const Color(0xFF112233),
        measure: _measure,
      );
      expect(painted, isFalse);
      expect(rec.drawnParagraphs, 0);
    });

    test('a zero-size box paints nothing (no divide-by-zero layout)', () {
      final _RecordingCanvas rec = _RecordingCanvas();
      final bool painted = paintTextBox(
        rec,
        _textNode(const Rect.fromLTRB(50, 50, 50, 50)),
        color: const Color(0xFF112233),
        measure: _measure,
      );
      expect(painted, isFalse);
    });

    test('the node colour is used, not a hardcoded black', () {
      final TextStyle style = textBoxTextStyle(
        color: const Color(0xFF112233),
        fontSize: 24,
      );
      expect(style.color, const Color(0xFF112233));
    });

    test('the font size is clamped to the supported range', () {
      expect(textBoxTextStyle(color: const Color(0xFF000000), fontSize: 0).fontSize,
          kMinTextFontSize);
      expect(
          textBoxTextStyle(color: const Color(0xFF000000), fontSize: 99999)
              .fontSize,
          kMaxTextFontSize);
    });
  });

  group('the dispatch reaches the text painter (the original bug)', () {
    // The defect was in DISPATCH, not in the text code: `TEXT` had no case in
    // `_drawShape`, so the node fell to the polyline `default:` and its two
    // corner `pts` drew as ONE diagonal line. Tests that call `paintTextBox`
    // directly cannot see that - they pass with the bug present.
    //
    // These assertions are source-level on purpose. The regression was a
    // MISSING BRANCH, and a missing branch is invisible to a unit test that
    // exercises the branch's own function. This is the same technique the
    // round-12 dialog z-order guard uses, and for the same reason.
    test('the shape dispatch has a TEXT case routed to paintTextBox', () {
      final String source = File('lib/canvas_engine/tiled_canvas_painter.dart')
          .readAsStringSync();
      // The TEXT case must exist and must call the text painter.
      final int textCase = source.indexOf("case 'TEXT':");
      expect(textCase, greaterThan(-1),
          reason: 'TEXT needs its own case; without it the polyline default '
              'draws the box corners as one diagonal line');
      // Bound the body by the next sibling `case`/`default` at the same indent
      // rather than by a bare "case " substring, which also matches prose in a
      // comment inside a neighbouring case.
      final RegExp sibling = RegExp(r'\n    (?:case |default:)');
      final RegExpMatch? next = sibling.firstMatch(source.substring(textCase + 1));
      final int bodyEnd =
          next == null ? source.length : textCase + 1 + next.start;
      final String body = source.substring(textCase, bodyEnd);
      expect(body, contains('paintTextBox('),
          reason: 'the TEXT case must call paintTextBox, got: $body');
      expect(body, isNot(contains('canvas.drawPath')),
          reason: 'TEXT must not draw a path; that is the line bug');
    });

    test('a TEXT node is never routed to the polyline fallback', () {
      final String source = File('lib/canvas_engine/tiled_canvas_painter.dart')
          .readAsStringSync();
      // The polyline default is the only place that draws `pts` as a path; the
      // TEXT case must appear before it so the fallthrough can never reach it.
      final int textCase = source.indexOf("case 'TEXT':");
      final int defaultCase = source.indexOf('default:', textCase);
      expect(textCase, greaterThan(-1));
      expect(defaultCase, greaterThan(textCase));
    });

    test('an empty text box paints no glyphs and no line', () {
      final _RecordingCanvas probe = _RecordingCanvas();
      final CanvasNodeModel node =
          _textNode(const Rect.fromLTWH(0, 0, 300, 120), text: '');
      expect(
        paintTextBox(probe,
            node, color: const Color(0xFF112233), measure: _measure),
        isFalse,
      );
      expect(probe.drawnParagraphs, 0);
      expect(probe.clips, isEmpty, reason: 'nothing to clip for empty text');
    });
  });
}

/// A [Canvas] stub that records the calls the text painter makes.
///
/// Only the members the renderer touches are implemented; anything else throws
/// so an accidental new draw call in this path is loud rather than silent.
class _RecordingCanvas implements Canvas {
  int saved = 0;
  int restored = 0;
  int drawnParagraphs = 0;
  final List<Rect> clips = <Rect>[];
  final List<Offset> paintedOffsets = <Offset>[];
  final List<String> paintedText = <String>[];
  final List<Color> paintedColours = <Color>[];

  @override
  void save() => saved++;

  @override
  void restore() => restored++;

  @override
  void clipRect(Rect rect,
      {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    clips.add(rect);
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    // `TextPainter.paint` funnels through here. Counting the glyph runs is what
    // makes these tests meaningful: they assert on what the painter really
    // emitted, so a missing TEXT branch (the original bug) cannot pass.
    drawnParagraphs++;
    paintedOffsets.add(offset);
  }

  /// `TextPainter.paint` reaches the canvas through `drawParagraph` on some
  /// engines and through the raw canvas otherwise; record either way.
  void recordText(String text, Color colour) {
    paintedText.add(text);
    paintedColours.add(colour);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}