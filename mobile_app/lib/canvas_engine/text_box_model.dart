/// Round-12 issue 05 — the text box model (`shape_type: "TEXT"`).
///
/// `NodeStyle` is frozen (Doc 03) and `geometry.pts` is numeric-only, so the
/// text cannot ride on either. It travels in `graph_config` instead —
/// `{"text": ..., "font_size": ..., "align": ...}` — exactly the way `TABLE`
/// stores its grid, which is what keeps the schema change to a single enum
/// member (`TEXT`).
///
/// Two things this file deliberately does NOT do:
///
/// * it never touches a `Canvas` or a `TextPainter` itself. Wrapping takes a
///   [`TextMeasurer`] callback, so the wrap rule can be unit-tested without a
///   real font stack, and so the PC mirror
///   (`pc_agent/viewport/text_renderer.py`) can be checked against identical
///   numbers. A wrap that only one side can compute is a wrap that drifts.
/// * it does not own the node. A text box is *derived from* a `SHAPE` node and
///   written back as `graph_config`, so there is no second source of truth for
///   the rect or the style.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, Rect, Size, TextAlign;

/// Default font size in world units — matches the PC `DEFAULT_FONT_SIZE`.
const double kDefaultTextFontSize = 24.0;

/// Guard rails, identical to the PC clamps. A 1 pt box is unreadable and a
/// 10 000 pt box overflows every surface, so both ends are clamped rather than
/// trusted — a `graph_config` can arrive from a hand-edited document.
const double kMinTextFontSize = 6.0;
const double kMaxTextFontSize = 400.0;

/// Line box height as a multiple of the font size (PC `LINE_HEIGHT_FACTOR`).
const double kTextLineHeightFactor = 1.25;

/// Inset of the text from its own rect, in world units.
const double kTextPadding = 4.0;

/// Smallest rect a text box may occupy, so a stray tap still leaves room for
/// one glyph and the selector still has something to grab.
const double kMinTextBoxSize = 48.0;

/// The alignment spellings the wire accepts, in UI cycle order.
const List<String> kTextAlignments = <String>['left', 'center', 'right'];

/// Measures the width of [text] at [fontSize] in world units.
///
/// Supplied by the caller because only the caller knows its font: the canvas
/// passes a `TextPainter`, a test passes a deterministic stub. Wrapping through
/// an injected measurer is the whole reason this model is testable headlessly.
typedef TextMeasurer = double Function(String text, double fontSize);

/// A `TextPainter`-shaped measurer backed by nothing but an average glyph
/// width — the fallback for tests and for a code path with no font available.
///
/// It is deliberately crude (0.5 em per character, the usual rough average for
/// a proportional sans face) and must NOT be used to lay out anything the user
/// will see rendered by a real font; use it only where "approximately fits" is
/// enough, such as deciding whether a blank box needs growing.
TextMeasurer approximateTextMeasurer() =>
    (String text, double fontSize) => text.length * fontSize * 0.5;

/// A text box: its content, typography, and world-space rect.
///
/// Immutable on purpose. The canvas page re-creates one of these per edit and
/// rewrites `graph_config`, which keeps the node the single source of truth and
/// makes undo a matter of swapping the map back.
class TextBoxModel {
  const TextBoxModel({
    required this.rect,
    this.text = '',
    this.fontSize = kDefaultTextFontSize,
    this.align = 'left',
  });

  /// World-space rect the text is laid out in (normalised by the constructor).
  final Rect rect;
  final String text;
  final double fontSize;

  /// One of [kTextAlignments]; see [normalisedAlign].
  final String align;

  /// [align] mapped onto its wire spelling, unknown values falling back to
  /// `left` — never throws, because a corrupt document must still open.
  String get normalisedAlign =>
      kTextAlignments.contains(align) ? align : 'left';

  /// [align] as Flutter's enum, for the painter.
  TextAlign get textAlign => switch (normalisedAlign) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };

  /// Whether this box would paint anything.
  bool get isEmpty => text.trim().isEmpty;

  /// Line box height in world units.
  double get lineHeight => fontSize * kTextLineHeightFactor;

  /// The box with every field sanitised (non-finite rect/size rejected).
  ///
  /// Total rather than throwing: a `graph_config` arrives from the wire and a
  /// renderer that raises on a corrupt node takes the canvas down with it.
  TextBoxModel normalised() {
    final Rect safeRect = _normaliseRect(rect);
    return TextBoxModel(
      rect: safeRect,
      text: normaliseText(text),
      fontSize: clampFontSize(fontSize),
      align: normalisedAlign,
    );
  }

  /// Copies with individual fields replaced, then normalised.
  TextBoxModel copyWith({Rect? rect, String? text, double? fontSize, String? align}) =>
      TextBoxModel(
        rect: rect ?? this.rect,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        align: align ?? this.align,
      ).normalised();

  /// `graph_config` for the node that carries this box.
  ///
  /// Snake_case keys, matching every other wire map (and `TABLE`'s `rows` /
  /// `header_row`). The text is stored verbatim — normalising here would make a
  /// save/reload change the document, and the round-trip is meant to be exact.
  Map<String, dynamic> toGraphConfig() => <String, dynamic>{
        'text': text,
        'font_size': clampFontSize(fontSize),
        'align': normalisedAlign,
      };

  /// Reads a box out of `graph_config` + the node's bbox.
  ///
  /// Every field is optional with a defined fallback, so a `TABLE`'s config (or
  /// a `null`) yields an empty default box rather than an exception.
  factory TextBoxModel.fromGraphConfig(
    Map<String, dynamic>? config,
    Rect rect,
  ) {
    final Map<String, dynamic> cfg = config ?? const <String, dynamic>{};
    return TextBoxModel(
      rect: rect,
      text: normaliseText(cfg['text']),
      fontSize: clampFontSize(cfg['font_size']),
      align: normaliseAlign(cfg['align']),
    ).normalised();
  }

  /// Wraps [text] into lines that fit [rect]'s width (minus [kTextPadding]).
  ///
  /// Returns an empty list for empty text. Explicit `\n` always breaks a line
  /// and blank lines are preserved, because a user pressing Enter twice expects
  /// a blank line rather than a collapsed one.
  List<String> wrapLines(TextMeasurer measure, {double padding = kTextPadding}) {
    return wrapTextLines(
      text,
      maxWidth: rect.width - 2 * _clampedPadding(padding, rect.width),
      measure: measure,
      fontSize: clampFontSize(fontSize),
    );
  }

  /// Top-left world point of each wrapped line, honouring [normalisedAlign].
  List<Offset> lineOrigins(List<String> lines, TextMeasurer measure,
      {double padding = kTextPadding}) {
    final double inset = _clampedPadding(padding, rect.width);
    final double size = clampFontSize(fontSize);
    final double height = size * kTextLineHeightFactor;
    final List<Offset> out = <Offset>[];
    for (int i = 0; i < lines.length; i++) {
      final double width = math.max(0.0, measure(lines[i], size));
      out.add(
        Offset(
          textOriginX(
            left: rect.left,
            right: rect.right,
            lineWidth: width,
            align: normalisedAlign,
            padding: inset,
          ),
          rect.top + inset + i * height,
        ),
      );
    }
    return out;
  }

  /// Size the box needs to show all its text without wrapping, used to grow the
  /// rect when the user types past its edge.
  ///
  /// Height is line-count based (not glyph-metric based) to match the
  /// `lineHeight` the painters use, so the grown rect and the drawn text agree.
  Size measuredSize(TextMeasurer measure, {double padding = kTextPadding}) {
    final List<String> lines = wrapLines(measure, padding: padding);
    final double size = clampFontSize(fontSize);
    double widest = 0;
    for (final String line in lines) {
      widest = math.max(widest, measure(line, size));
    }
    final int count = math.max(1, lines.length);
    final double inset = _clampedPadding(padding, rect.width);
    return Size(
      widest + 2 * inset,
      count * size * kTextLineHeightFactor + 2 * inset,
    );
  }
}

/// Greedy word wrap — the Dart twin of the PC `wrap_lines`.
///
/// Runs of spaces collapse to one (the wrap is word based) and a word wider
/// than the whole line is hard-split at the longest prefix that fits, with at
/// least one character per chunk so a single glyph wider than the box cannot
/// loop forever.
///
/// An unusable [maxWidth] (zero, negative, non-finite) means "cannot measure",
/// so paragraphs come back unbroken rather than one character per line.
List<String> wrapTextLines(
  String text, {
  required double maxWidth,
  required TextMeasurer measure,
  double fontSize = kDefaultTextFontSize,
}) {
  final String usable = normaliseText(text);
  if (usable.trim().isEmpty) {
    // A whitespace-only box paints no ink, so it must wrap to nothing rather
    // than to a single blank line the renderers would then draw.
    return const <String>[];
  }
  final List<String> paragraphs = usable.split('\n');
  final double width = maxWidth;
  if (!width.isFinite || width <= 0) {
    return paragraphs;
  }
  final double size = clampFontSize(fontSize);
  final List<String> lines = <String>[];
  for (final String paragraph in paragraphs) {
    if (measure(paragraph, size) <= width) {
      lines.add(paragraph);
      continue;
    }
    final List<String> words =
        paragraph.trim().split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      lines.add('');
      continue;
    }
    String line = '';
    for (final String word in words) {
      final String candidate = line.isEmpty ? word : '$line $word';
      if (measure(candidate, size) <= width) {
        line = candidate;
        continue;
      }
      if (line.isNotEmpty) {
        lines.add(line);
        line = '';
      }
      if (measure(word, size) <= width) {
        line = word;
        continue;
      }
      final List<String> chunks = _splitLongWord(word, width, size, measure);
      lines.addAll(chunks.sublist(0, chunks.length - 1));
      line = chunks.isEmpty ? '' : chunks.last;
    }
    lines.add(line);
  }
  return lines;
}

List<String> _splitLongWord(
  String word,
  double maxWidth,
  double fontSize,
  TextMeasurer measure,
) {
  final List<String> chunks = <String>[];
  String current = '';
  for (final String char in word.split('')) {
    final String candidate = current + char;
    if (current.isNotEmpty && measure(candidate, fontSize) > maxWidth) {
      chunks.add(current);
      current = char;
    } else {
      current = candidate;
    }
  }
  if (current.isNotEmpty) {
    chunks.add(current);
  }
  return chunks;
}

/// Left edge of one line inside a box, honouring [align].
///
/// [padding] is clamped to the box half-width so a rect narrower than twice the
/// inset still centres on the box instead of inverting its edges.
double textOriginX({
  required double left,
  required double right,
  required double lineWidth,
  required String align,
  double padding = kTextPadding,
}) {
  final double width = right - left;
  final double inset = _clampedPadding(padding, width);
  return switch (align) {
    'center' => (left + right) / 2 - lineWidth / 2,
    'right' => right - inset - lineWidth,
    _ => left + inset,
  };
}

/// [fontSize] clamped into [kMinTextFontSize]..[kMaxTextFontSize].
///
/// Non-finite input is rejected explicitly (`NaN` compares false against every
/// bound, so `clamp` alone would let it through and poison every glyph
/// position).
double clampFontSize(Object? value) {
  final double size = switch (value) {
    final num number => number.toDouble(),
    final String token => double.tryParse(token.trim()) ?? kDefaultTextFontSize,
    _ => kDefaultTextFontSize,
  };
  if (!size.isFinite) {
    return kDefaultTextFontSize;
  }
  return size.clamp(kMinTextFontSize, kMaxTextFontSize).toDouble();
}

/// Normalises the alignment spelling, defaulting to `left`.
String normaliseAlign(Object? value) {
  if (value is! String) {
    return 'left';
  }
  final String token = value.trim().toLowerCase();
  return kTextAlignments.contains(token) ? token : 'left';
}

/// Normalises newlines to `\n` and drops non-string input to `''`.
///
/// Both sides split on `\n` only, so a stray `\r\n` from a paste would
/// otherwise become two line breaks and one side would draw a blank line the
/// other does not.
String normaliseText(Object? value) {
  if (value is! String) {
    return '';
  }
  return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}

/// The rect a new text box occupies for a drag from [start] to [end].
///
/// A tap (or a drag too small to hold a glyph) is grown to
/// [kMinTextBoxSize] rather than committed as a zero-width node, which the
/// selector could not resize and the wrappers would skip.
Rect planTextBoxRect(Offset start, Offset end, {double minSize = kMinTextBoxSize}) {
  final Rect raw = Rect.fromPoints(start, end);
  final double safeMin = minSize.isFinite && minSize > 0 ? minSize : kMinTextBoxSize;
  return Rect.fromLTWH(
    raw.left,
    raw.top,
    math.max(raw.width, safeMin),
    math.max(raw.height, safeMin),
  );
}

Rect _normaliseRect(Rect rect) {
  if (!rect.isFinite) {
    return Rect.fromLTWH(
      rect.left.isFinite ? rect.left : 0,
      rect.top.isFinite ? rect.top : 0,
      kMinTextBoxSize,
      kMinTextBoxSize,
    );
  }
  return Rect.fromLTRB(
    math.min(rect.left, rect.right),
    math.min(rect.top, rect.bottom),
    math.max(rect.left, rect.right),
    math.max(rect.top, rect.bottom),
  );
}

double _clampedPadding(double padding, double width) {
  if (!padding.isFinite || padding <= 0) {
    return 0;
  }
  final double half = math.max(0.0, width / 2);
  return math.min(padding, half);
}
