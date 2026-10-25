/// Round-12 issue 05 — polygon and text box models.
///
/// Pure geometry and pure wrapping, so nothing here needs a canvas: the
/// measurer is injected, exactly as the production code expects a
/// `TextPainter` to be. What the tests pin is the part that must match the PC
/// mirror (`pc_agent/viewport/text_renderer.py`), because a wrap rule that only
/// one side can compute is a wrap rule that drifts the moment text is mirrored.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/canvas_engine/polygon_geometry.dart';
import 'package:mobile_app/canvas_engine/text_box_model.dart';

/// Deterministic measurer: 0.6 em per character.
///
/// A real font is not available in a unit test, and worse, would make the
/// expected line breaks depend on the platform's font stack. A fixed advance
/// keeps every expectation exact and readable.
double stubMeasure(String text, double fontSize) => text.length * fontSize * 0.6;

void main() {
  group('regular polygon vertices', () {
    test('a hexagon has six vertices in the order top-first', () {
      final List<Offset> pts =
          regularPolygonAt(const Offset(100, 100), 50, sides: 6);
      expect(pts, hasLength(6));
      // Top vertex is straight up from the centre.
      expect(pts.first.dx, closeTo(100, 1e-9));
      expect(pts.first.dy, closeTo(50, 1e-9));
    });

    test('every vertex sits exactly on the radius', () {
      const Offset centre = Offset(-12.5, 41.25);
      const double radius = 37.5;
      for (final int sides in <int>[3, 4, 5, 6, 8, 12]) {
        for (final Offset p in regularPolygonAt(centre, radius, sides: sides)) {
          expect((p - centre).distance, closeTo(radius, 1e-9),
              reason: 'sides=$sides');
        }
      }
    });

    test('vertex count follows the requested side count', () {
      for (final int sides in <int>[3, 5, 7, 9, 12]) {
        expect(regularPolygonAt(Offset.zero, 10, sides: sides), hasLength(sides));
      }
    });

    test('side counts are clamped to the guard rails', () {
      expect(clampPolygonSides(1), kMinPolygonSides);
      expect(clampPolygonSides(0), kMinPolygonSides);
      expect(clampPolygonSides(6), 6);
      expect(clampPolygonSides(10000), kMaxPolygonSides);
      expect(regularPolygonAt(Offset.zero, 10, sides: 2), hasLength(kMinPolygonSides));
      expect(
          regularPolygonAt(Offset.zero, 10, sides: 9999), hasLength(kMaxPolygonSides));
    });

    test('a square inscribed in a box touches all four extremes', () {
      final Rect box = Rect.fromLTWH(10, 20, 200, 120);
      final List<Offset> pts = regularPolygonInBox(box, sides: 4);
      final Rect bounds = polygonBounds(pts);
      // A 45°-rotated square's bbox is its circumscribed box, so the extremes
      // must match the drag the user made.
      expect(bounds.left, closeTo(box.left, 1e-9));
      expect(bounds.top, closeTo(box.top, 1e-9));
      expect(bounds.right, closeTo(box.right, 1e-9));
      expect(bounds.bottom, closeTo(box.bottom, 1e-9));
    });

    test('an inscribed polygon never leaves its drag box', () {
      final Rect box = Rect.fromLTWH(-40, -30, 180, 90);
      for (final int sides in <int>[3, 4, 6, 9, 20]) {
        final Rect bounds = polygonBounds(regularPolygonInBox(box, sides: sides));
        expect(bounds.left, greaterThanOrEqualTo(box.left - 1e-9));
        expect(bounds.top, greaterThanOrEqualTo(box.top - 1e-9));
        expect(bounds.right, lessThanOrEqualTo(box.right + 1e-9));
        expect(bounds.bottom, lessThanOrEqualTo(box.bottom + 1e-9));
      }
    });

    test('a drag in any direction produces the same polygon', () {
      const Offset a = Offset(10, 20);
      const Offset b = Offset(210, 140);
      final List<Offset> forward = polygonFromDrag(a, b);
      final List<Offset> backward = polygonFromDrag(b, a);
      expect(forward, hasLength(backward.length));
      for (int i = 0; i < forward.length; i++) {
        expect(forward[i].dx, closeTo(backward[i].dx, 1e-9));
        expect(forward[i].dy, closeTo(backward[i].dy, 1e-9));
      }
    });

    test('a degenerate drag yields no vertices', () {
      // A pure tap: no interior to inscribe anything into.
      expect(polygonFromDrag(const Offset(5, 5), const Offset(5, 5)), isEmpty);
      expect(polygonFromDrag(const Offset(5, 5), const Offset(5, 90)), isEmpty);
      expect(polygonFromDrag(const Offset(5, 5), const Offset(90, 5)), isEmpty);
    });

    test('non-finite input is rejected rather than propagated', () {
      expect(regularPolygonAt(const Offset(double.nan, 0), 10), isEmpty);
      expect(regularPolygonAt(const Offset(0, 0), double.infinity), isEmpty);
      expect(regularPolygonAt(const Offset(0, 0), -5), isEmpty);
      expect(regularPolygonAt(const Offset(0, 0), double.nan), isEmpty);
      // A non-finite rotation is treated as "no rotation", not as NaN vertices.
      final List<Offset> rotated =
          regularPolygonAt(const Offset(0, 0), 10, rotation: double.nan);
      expect(rotated, hasLength(kDefaultPolygonSides));
      for (final Offset p in rotated) {
        expect(p.dx.isFinite && p.dy.isFinite, isTrue);
      }
    });

    test('rotation moves the first vertex by exactly that angle', () {
      const Offset centre = Offset(0, 0);
      final List<Offset> base = regularPolygonAt(centre, 10);
      final List<Offset> turned =
          regularPolygonAt(centre, 10, rotation: math.pi / 2);
      expect(turned.first.dx, closeTo(-base.first.dy, 1e-9));
      expect(turned.first.dy, closeTo(base.first.dx, 1e-9));
    });

    test('the default side count is a hexagon', () {
      expect(regularPolygonAt(Offset.zero, 5), hasLength(kDefaultPolygonSides));
      expect(kDefaultPolygonSides, 6);
    });
  });

  group('polygon pts round-trip', () {
    test('world points serialise to [[x, y], ...]', () {
      final List<List<double>> pts = polygonPts(
          const <Offset>[Offset(1, 2), Offset(3, 4), Offset(5, 6)]);
      expect(pts, <List<double>>[
        <double>[1, 2],
        <double>[3, 4],
        <double>[5, 6],
      ]);
    });

    test('malformed pairs are dropped, not fatal', () {
      final List<Offset> parsed = polygonFromPts(<List<double>>[
        <double>[1, 2],
        <double>[3],
        <double>[double.nan, 4],
        <double>[5, 6],
      ]);
      expect(parsed, <Offset>[const Offset(1, 2), const Offset(5, 6)]);
      expect(polygonFromPts(null), isEmpty);
    });

    test('a serialise → parse cycle preserves the polygon', () {
      final List<Offset> original = regularPolygonInBox(
          Rect.fromLTWH(0, 0, 120, 80),
          sides: 5);
      final List<Offset> parsed = polygonFromPts(polygonPts(original));
      expect(parsed, hasLength(original.length));
      for (int i = 0; i < parsed.length; i++) {
        expect(parsed[i].dx, closeTo(original[i].dx, 1e-9));
        expect(parsed[i].dy, closeTo(original[i].dy, 1e-9));
      }
    });
  });

  group('point in polygon', () {
    final List<Offset> square = <Offset>[
      const Offset(0, 0),
      const Offset(100, 0),
      const Offset(100, 100),
      const Offset(0, 100),
    ];

    test('an interior point is inside', () {
      expect(pointInPolygon(const Offset(50, 50), square), isTrue);
    });

    test('an exterior point is outside', () {
      expect(pointInPolygon(const Offset(150, 50), square), isFalse);
      expect(pointInPolygon(const Offset(-1, 50), square), isFalse);
      expect(pointInPolygon(const Offset(50, 99.9), square), isTrue);
      // Beyond the edge tolerance band, so genuinely outside.
      expect(pointInPolygon(const Offset(50, 101), square), isFalse);
    });

    test('a point on an edge or vertex counts as a hit', () {
      expect(pointInPolygon(const Offset(0, 50), square), isTrue);
      expect(pointInPolygon(const Offset(50, 0), square), isTrue);
      expect(pointInPolygon(const Offset(100, 100), square), isTrue);
      // Just inside the tolerance band of the top edge.
      expect(pointInPolygon(const Offset(50, -0.5), square), isTrue);
      // Clearly outside it.
      expect(pointInPolygon(const Offset(50, -3), square), isFalse);
    });

    test('a concave polygon is tested by ray casting, not by its bbox', () {
      // A "C" missing its right-hand middle: the notch is outside the shape but
      // inside its bounding box, which is exactly where a bbox test lies.
      final List<Offset> concave = <Offset>[
        const Offset(0, 0),
        const Offset(30, 0),
        const Offset(30, 30),
        const Offset(10, 30),
        const Offset(10, 70),
        const Offset(30, 70),
        const Offset(30, 100),
        const Offset(0, 100),
      ];
      expect(pointInPolygon(const Offset(5, 50), concave), isTrue);
      expect(pointInPolygon(const Offset(20, 50), concave), isFalse);
    });

    test('degenerate polygons and non-finite points are not hits', () {
      expect(pointInPolygon(const Offset(0, 0), const <Offset>[]), isFalse);
      expect(
          pointInPolygon(const Offset(0, 0),
              const <Offset>[Offset(0, 0), Offset(1, 1)]),
          isFalse);
      expect(pointInPolygon(const Offset(double.nan, 0), square), isFalse);
    });
  });

  group('centroid, bounds and usability', () {
    test('the centroid of a square is its centre', () {
      final List<Offset> square = regularPolygonInBox(
          Rect.fromLTWH(10, 10, 100, 100),
          sides: 4);
      final Offset centre = polygonCentroid(square);
      expect(centre.dx, closeTo(60, 1e-9));
      expect(centre.dy, closeTo(60, 1e-9));
    });

    test('an irregular polygon uses the area centroid, not the vertex average',
        () {
      // Extra vertices clustered on one side. The vertex average drifts right;
      // the area centroid stays at the geometric centre of the rectangle.
      final List<Offset> lopsided = <Offset>[
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 50),
        const Offset(100, 100),
        const Offset(50, 100),
        const Offset(0, 100),
      ];
      final Offset centre = polygonCentroid(lopsided);
      expect(centre.dx, closeTo(50, 1e-6));
      expect(centre.dy, closeTo(50, 1e-6));
    });

    test('a degenerate polygon falls back to the vertex average', () {
      final Offset centre = polygonCentroid(
          const <Offset>[Offset(0, 0), Offset(10, 0), Offset(20, 0)]);
      expect(centre.dx, closeTo(10, 1e-9));
      expect(centre.dy, closeTo(0, 1e-9));
      expect(polygonCentroid(const <Offset>[]), Offset.zero);
    });

    test('bounds normalise a polygon with any vertex order', () {
      final Rect bounds = polygonBounds(const <Offset>[
        Offset(30, 40),
        Offset(-10, 90),
        Offset(50, 0),
      ]);
      expect(bounds, const Rect.fromLTRB(-10, 0, 50, 90));
      expect(polygonBounds(const <Offset>[]), Rect.zero);
    });

    test('usability requires three vertices and a non-zero area', () {
      final List<Offset> triangle =
          regularPolygonAt(const Offset(0, 0), 20, sides: 3);
      expect(polygonIsUsable(triangle), isTrue);
      expect(polygonIsUsable(const <Offset>[]), isFalse);
      expect(
          polygonIsUsable(
              const <Offset>[Offset(0, 0), Offset(10, 0), Offset(20, 0)]),
          isFalse);
    });

    test('signed area is positive for a clockwise ring in y-down space', () {
      final List<Offset> clockwise = <Offset>[
        const Offset(0, 0),
        const Offset(10, 0),
        const Offset(10, 10),
        const Offset(0, 10),
      ];
      expect(polygonSignedArea(clockwise), closeTo(100, 1e-9));
      expect(polygonSignedArea(clockwise.reversed.toList()), closeTo(-100, 1e-9));
    });
  });

  group('text wrapping', () {
    test('an empty string wraps to no lines', () {
      expect(wrapTextLines('', maxWidth: 100, measure: stubMeasure), isEmpty);
      expect(wrapTextLines('   ', maxWidth: 100, measure: stubMeasure), isEmpty);
    });

    test('a short single line is returned unchanged', () {
      expect(
        wrapTextLines('Hello', maxWidth: 200, measure: stubMeasure),
        <String>['Hello'],
      );
    });

    test('a longer paragraph breaks on word boundaries', () {
      // 0.6 em/char at 10 pt = 6 units/char; 60 units fits 10 characters.
      final List<String> lines =
          wrapTextLines('aaa bbb ccc ddd', maxWidth: 60, measure: stubMeasure, fontSize: 10);
      expect(lines, <String>['aaa bbb', 'ccc ddd']);
    });

    test('multiple paragraphs are all wrapped', () {
      final List<String> lines = wrapTextLines(
        'aaa bbb ccc\nddd eee fff',
        maxWidth: 60,
        measure: stubMeasure,
        fontSize: 10,
      );
      expect(lines, <String>['aaa bbb', 'ccc', 'ddd eee', 'fff']);
    });

    test('a blank line inside the text is preserved', () {
      expect(
        wrapTextLines('one\n\ntwo', maxWidth: 200, measure: stubMeasure),
        <String>['one', '', 'two'],
      );
    });

    test('a word wider than the line is hard-split', () {
      final List<String> lines = wrapTextLines(
        'abcdefghij',
        maxWidth: 30,
        measure: stubMeasure,
        fontSize: 10,
      );
      // 5 characters fit per line at 6 units each.
      expect(lines, <String>['abcde', 'fghij']);
      for (final String line in lines) {
        expect(stubMeasure(line, 10), lessThanOrEqualTo(30));
      }
    });

    test('a word that fits on its own line is not split', () {
      final List<String> lines = wrapTextLines(
        'ab abcdef',
        maxWidth: 40,
        measure: stubMeasure,
        fontSize: 10,
      );
      expect(lines, <String>['ab', 'abcdef']);
    });

    test('a very narrow rect still produces single-character chunks', () {
      final List<String> lines = wrapTextLines(
        'abcd',
        maxWidth: 1,
        measure: stubMeasure,
        fontSize: 10,
      );
      expect(lines, <String>['a', 'b', 'c', 'd']);
    });

    test('a non-positive or non-finite width leaves paragraphs unbroken', () {
      for (final double width in <double>[0, -5, double.nan, double.infinity]) {
        expect(
          wrapTextLines('aaa bbb\nccc', maxWidth: width, measure: stubMeasure),
          <String>['aaa bbb', 'ccc'],
          reason: 'width=$width',
        );
      }
    });

    test('CRLF input does not become a double line break', () {
      expect(
        wrapTextLines('one\r\ntwo', maxWidth: 200, measure: stubMeasure),
        <String>['one', 'two'],
      );
    });
  });

  group('text box graph_config round-trip', () {
    test('every field survives a round trip', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(10, 20, 300, 120),
        text: 'Hello\nthere',
        fontSize: 32,
        align: 'right',
      );
      final TextBoxModel back = TextBoxModel.fromGraphConfig(
        box.toGraphConfig(),
        box.rect,
      );
      expect(back.text, 'Hello\nthere');
      expect(back.fontSize, 32);
      expect(back.align, 'right');
      expect(back.rect, box.rect);
    });

    test('the config uses snake_case wire keys', () {
      const TextBoxModel box =
          TextBoxModel(rect: Rect.fromLTWH(0, 0, 10, 10), text: 'x');
      expect(box.toGraphConfig().keys.toSet(),
          <String>{'text', 'font_size', 'align'});
    });

    test('a missing config falls back to an empty default box', () {
      final TextBoxModel box =
          TextBoxModel.fromGraphConfig(null, const Rect.fromLTWH(0, 0, 50, 50));
      expect(box.text, '');
      expect(box.fontSize, kDefaultTextFontSize);
      expect(box.align, 'left');
      expect(box.isEmpty, isTrue);
    });

    test('garbage fields fall back individually', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{
          'text': 42,
          'font_size': 'huge',
          'align': 'justify',
        },
        const Rect.fromLTWH(0, 0, 50, 50),
      );
      expect(box.text, '');
      expect(box.fontSize, kDefaultTextFontSize);
      expect(box.align, 'left');
    });

    test('a numeric string font size is accepted', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'text': 'x', 'font_size': '18.5'},
        const Rect.fromLTWH(0, 0, 50, 50),
      );
      expect(box.fontSize, 18.5);
    });

    test('a table config degrades to an empty text box', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'rows': 3, 'cols': 4},
        const Rect.fromLTWH(0, 0, 50, 50),
      );
      expect(box.isEmpty, isTrue);
      expect(box.align, 'left');
    });

    test('a non-finite rect is replaced rather than propagated', () {
      final TextBoxModel box = TextBoxModel.fromGraphConfig(
        <String, dynamic>{'text': 'x'},
        const Rect.fromLTWH(double.nan, 0, double.infinity, 10),
      );
      expect(box.rect.isFinite, isTrue);
      expect(box.wrapLines(stubMeasure), <String>['x']);
    });
  });

  group('font size clamping', () {
    test('sizes below the minimum clamp up', () {
      expect(clampFontSize(0), kMinTextFontSize);
      expect(clampFontSize(-100), kMinTextFontSize);
      expect(clampFontSize('2'), kMinTextFontSize);
    });

    test('sizes above the maximum clamp down', () {
      expect(clampFontSize(10000), kMaxTextFontSize);
      expect(clampFontSize('9999'), kMaxTextFontSize);
    });

    test('a size inside the range is kept exactly', () {
      expect(clampFontSize(24), 24);
      expect(clampFontSize(24.5), 24.5);
      expect(clampFontSize('31.25'), 31.25);
    });

    test('non-finite and unusable values fall back to the default', () {
      expect(clampFontSize(double.nan), kDefaultTextFontSize);
      expect(clampFontSize(double.infinity), kDefaultTextFontSize);
      expect(clampFontSize(double.negativeInfinity), kDefaultTextFontSize);
      expect(clampFontSize(null), kDefaultTextFontSize);
      expect(clampFontSize('abc'), kDefaultTextFontSize);
      expect(clampFontSize(<int>[1]), kDefaultTextFontSize);
    });

    test('the default and the rails agree with the PC constants', () {
      expect(kDefaultTextFontSize, 24.0);
      expect(kMinTextFontSize, 6.0);
      expect(kMaxTextFontSize, 400.0);
      expect(kTextLineHeightFactor, 1.25);
    });
  });

  group('alignment handling', () {
    const double left = 0;
    const double right = 200;
    const double lineWidth = 40;

    test('left align offsets by the padding only', () {
      expect(
          textOriginX(
              left: left,
              right: right,
              lineWidth: lineWidth,
              align: 'left'),
          kTextPadding);
    });

    test('centre align is symmetric about the box centre', () {
      expect(
          textOriginX(
              left: left,
              right: right,
              lineWidth: lineWidth,
              align: 'center'),
          80);
    });

    test('right align keeps the padding on the right', () {
      expect(
          textOriginX(
              left: left,
              right: right,
              lineWidth: lineWidth,
              align: 'right'),
          right - kTextPadding - lineWidth);
    });

    test('an unknown alignment behaves as left', () {
      expect(
          textOriginX(
              left: left,
              right: right,
              lineWidth: lineWidth,
              align: 'justify'),
          kTextPadding);
      expect(normaliseAlign('CENTER'), 'center');
      expect(normaliseAlign('  Right '), 'right');
      expect(normaliseAlign(null), 'left');
      expect(normaliseAlign(7), 'left');
    });

    test('a box narrower than the padding does not invert its edges', () {
      final double x = textOriginX(
        left: 10,
        right: 14,
        lineWidth: 40,
        align: 'center',
      );
      expect(x, 12 - 20);
    });

    test('line origins stack by lineHeight from the padded top', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(0, 100, 200, 400),
        text: 'a\nb\nc',
        fontSize: 20,
        align: 'left',
      );
      final List<String> lines = box.wrapLines(stubMeasure);
      final List<Offset> origins = box.lineOrigins(lines, stubMeasure);
      expect(origins, hasLength(3));
      expect(origins[0].dy, closeTo(100 + kTextPadding, 1e-9));
      expect(origins[1].dy,
          closeTo(100 + kTextPadding + 20 * kTextLineHeightFactor, 1e-9));
      expect(origins[2].dy,
          closeTo(100 + kTextPadding + 2 * 20 * kTextLineHeightFactor, 1e-9));
      for (final Offset o in origins) {
        expect(o.dx, closeTo(kTextPadding, 1e-9));
      }
    });

    test('centre alignment re-centres every line individually', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(0, 0, 200, 200),
        text: 'aa\nbbbb',
        fontSize: 10,
        align: 'center',
      );
      final List<Offset> origins =
          box.lineOrigins(box.wrapLines(stubMeasure), stubMeasure);
      final double shortWidth = stubMeasure('aa', 10);
      final double longWidth = stubMeasure('bbbb', 10);
      expect(origins[0].dx, closeTo(100 - shortWidth / 2, 1e-9));
      expect(origins[1].dx, closeTo(100 - longWidth / 2, 1e-9));
    });
  });

  group('text box helpers', () {
    test('the text align enum follows the wire spelling', () {
      const TextBoxModel centre =
          TextBoxModel(rect: Rect.fromLTWH(0, 0, 10, 10), align: 'center');
      const TextBoxModel right =
          TextBoxModel(rect: Rect.fromLTWH(0, 0, 10, 10), align: 'right');
      const TextBoxModel bogus =
          TextBoxModel(rect: Rect.fromLTWH(0, 0, 10, 10), align: 'justify');
      expect(centre.textAlign, TextAlign.center);
      expect(right.textAlign, TextAlign.right);
      expect(bogus.textAlign, TextAlign.left);
      expect(bogus.normalisedAlign, 'left');
    });

    test('measuredSize grows with the text and never goes below the padding',
        () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(0, 0, 400, 400),
        text: 'aaaa\nbb',
        fontSize: 10,
        align: 'left',
      );
      final Size size = box.measuredSize(stubMeasure);
      expect(size.width, closeTo(stubMeasure('aaaa', 10) + 2 * kTextPadding, 1e-9));
      expect(size.height,
          closeTo(2 * 10 * kTextLineHeightFactor + 2 * kTextPadding, 1e-9));
    });

    test('planTextBoxRect enforces a minimum size on a tap', () {
      final Rect rect = planTextBoxRect(const Offset(10, 10), const Offset(10, 10));
      expect(rect.left, 10);
      expect(rect.top, 10);
      expect(rect.width, kMinTextBoxSize);
      expect(rect.height, kMinTextBoxSize);
    });

    test('planTextBoxRect keeps a real drag intact', () {
      final Rect rect = planTextBoxRect(const Offset(0, 0), const Offset(300, 200));
      expect(rect, const Rect.fromLTWH(0, 0, 300, 200));
      // A drag in the opposite direction normalises.
      expect(planTextBoxRect(const Offset(300, 200), const Offset(0, 0)),
          const Rect.fromLTWH(0, 0, 300, 200));
    });

    test('copyWith renormalises the changed fields', () {
      const TextBoxModel box =
          TextBoxModel(rect: Rect.fromLTWH(0, 0, 100, 100), text: 'x');
      final TextBoxModel grown = box.copyWith(fontSize: 1e6, align: 'nope');
      expect(grown.fontSize, kMaxTextFontSize);
      expect(grown.align, 'left');
      expect(grown.text, 'x');
    });

    test('normalised rejects a non-finite rect and keeps the text', () {
      const TextBoxModel box = TextBoxModel(
        rect: Rect.fromLTWH(double.nan, double.infinity, 10, 10),
        text: 'kept',
        fontSize: double.nan,
      );
      final TextBoxModel safe = box.normalised();
      expect(safe.rect.isFinite, isTrue);
      expect(safe.text, 'kept');
      expect(safe.fontSize, kDefaultTextFontSize);
    });

    test('normaliseText handles CRLF and non-strings', () {
      expect(normaliseText('a\r\nb\rc'), 'a\nb\nc');
      expect(normaliseText(null), '');
      expect(normaliseText(42), '');
    });

    test('the approximate measurer scales with length and size', () {
      final TextMeasurer measure = approximateTextMeasurer();
      expect(measure('abcd', 10), 20);
      expect(measure('', 10), 0);
    });
  });
}
