/// Paints a `shape_type == "TEXT"` node with real glyphs.
///
/// Why this module exists: the text tool committed correct nodes — the rect,
/// the wrapped content, the font size and the alignment all arrived on the
/// canvas — but [TiledCanvasPainter] had no `TEXT` case in its shape dispatch,
/// so every text box fell through to the generic polyline branch. A box with
/// two corner points `pts` drawn as a polyline is a single diagonal line, which
/// is exactly what the tool looked like: "it's just a single line instead of a
/// box". The fix is not in the model (that was already right and tested) but
/// here, plus one `case` in the dispatch.
///
/// Conventions deliberately mirrored from the PC renderer
/// (`pc_agent/viewport/text_renderer.py`) so the tablet and the mirror agree:
///
/// * the text is laid out inside `bbox` inset by [kTextPadding] on all sides;
/// * lines come from [TextBoxModel.wrapLines], the Dart twin of the PC
///   `wrap_lines`, so both wrap at the same character;
/// * the block is clipped to the box, so a long line cannot bleed over a
///   neighbouring shape;
/// * a text box paints **no outline of its own** — only glyphs (and the fill
///   that [paintNodeFill] already lays down, which the PC also does).
library;

import 'package:flutter/widgets.dart';

import 'package:mobile_app/canvas_engine/text_box_model.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// World-space rect of a node's `bbox`, normalised so `left <= right`.
///
/// A drag can produce an inverted rect (the user drew right-to-left or
/// bottom-to-top); `Rect.fromLTRB` would then have a negative width and the
/// clip and layout both collapse.
Rect textBoxRectOf(CanvasNodeModel n) {
  final List<double> bbox = n.bbox;
  if (bbox.length < 4) {
    return Rect.zero;
  }
  final double x0 = bbox[0];
  final double y0 = bbox[1];
  final double x1 = bbox[2];
  final double y1 = bbox[3];
  if (!x0.isFinite || !y0.isFinite || !x1.isFinite || !y1.isFinite) {
    return Rect.zero;
  }
  return Rect.fromLTRB(
    x0 < x1 ? x0 : x1,
    y0 < y1 ? y0 : y1,
    x0 < x1 ? x1 : x0,
    y0 < y1 ? y1 : y0,
  );
}

/// A [TextMeasurer] backed by [TextPainter].
///
/// The model takes the measurer as a callback so its wrap rule is testable with
/// a stub; on a real canvas the real glyph metrics have to be used, otherwise
/// the tablet wraps at a different word than the PC mirror does.
TextMeasurer textPainterMeasurer() {
  return (String text, double fontSize) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final double width = tp.width;
    tp.dispose();
    return width;
  };
}

/// Lays a text box out into positioned lines.
///
/// Pure: no [Canvas] touched, so the placement maths is unit-testable without a
/// render target. Returns an empty list when the box paints no ink.
List<({String line, Offset origin})> layoutTextBox(
  TextBoxModel box, {
  TextMeasurer? measure,
}) {
  final TextBoxModel model = box.normalised();
  if (model.isEmpty) {
    return const <({String line, Offset origin})>[];
  }
  final TextMeasurer measurer = measure ?? textPainterMeasurer();
  final List<String> lines = model.wrapLines(measurer);
  if (lines.isEmpty) {
    return const <({String line, Offset origin})>[];
  }
  final List<Offset> origins = model.lineOrigins(lines, measurer);
  return <({String line, Offset origin})>[
    for (int i = 0; i < lines.length; i++)
      (line: lines[i], origin: origins[i]),
  ];
}

/// The text style a box's glyphs are painted with.
///
/// Extracted and public so the colour/size wiring is assertable: the node's own
/// style colour must reach the glyphs (the PC paints with the node colour too,
/// not a hardcoded black), and the size must be the clamped font size.
TextStyle textBoxTextStyle({required Color color, required double fontSize}) =>
    TextStyle(color: color, fontSize: clampFontSize(fontSize));

/// Draws a TEXT node's glyphs. `false` when nothing was painted.
///
/// [color] is the node's own stroke colour (the PC paints the box with the
/// style colour, not a hardcoded black), and [opacity] folds in `style.opacity`.
bool paintTextBox(
  Canvas canvas,
  CanvasNodeModel n, {
  required Color color,
  TextMeasurer? measure,
}) {
  final Rect rect = textBoxRectOf(n);
  if (rect.width <= 0 || rect.height <= 0) {
    return false;
  }
  final TextBoxModel box =
      TextBoxModel.fromGraphConfig(n.geometry.graphConfig, rect);
  final List<({String line, Offset origin})> lines =
      layoutTextBox(box, measure: measure);
  if (lines.isEmpty) {
    return false;
  }
  final double fontSize = clampFontSize(box.fontSize);
  final TextStyle style = textBoxTextStyle(color: color, fontSize: fontSize);
  canvas.save();
  try {
    canvas.clipRect(rect);
    for (final ({String line, Offset origin}) entry in lines) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: entry.line, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      tp.paint(canvas, entry.origin);
      tp.dispose();
    }
  } finally {
    canvas.restore();
  }
  return true;
}
