/// Round-8 issue 07 — selector transforms (move / resize) as pure geometry.
///
/// The canvas had no way to manipulate what was already drawn: once a shape
/// was committed it could only be erased. The selector tool fixes that, and
/// every transform it performs reduces to the two operations here — translate
/// and scale — applied to a node's points, bbox and (for text-free shapes,
/// trivially) its style width.
///
/// Deliberately pure: no widgets, no engine, no RPC. The canvas page owns the
/// drag/drag-handle UI and the mutation fan-out; this module owns only "what
/// do the numbers become", so it is exhaustively unit-testable.
///
/// **Free-hand strokes are move-only.** A pen stroke's point list is the
/// drawn path; scaling it would thin or fatten the line inconsistently with
/// the recorded `stroke_width` and destroy the hand-drawn feel. The UI blocks
/// the resize handles for such a selection (see [canScaleSelection]) but still
/// allows move and delete.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// Kinds that may be resized by the selector.
///
/// Strokes are excluded on purpose — see the library doc. SHAPE / IMAGE /
/// GRAPH_AXES are all bbox-driven, so scaling their geometry is well defined.
const Set<String> kScalableKinds = <String>{
  'SHAPE',
  'IMAGE',
  'GRAPH_AXES',
  'LINE',
};

/// A selection may be scaled only when every member kind is scalable.
///
/// The user's rule: "we can't resize a free drawed line with the pen tool …
/// But we can still move or delete if we select at least one free drawed
/// line."
bool canScaleSelection(Iterable<String> kinds) {
  bool any = false;
  for (final String kind in kinds) {
    any = true;
    if (!kScalableKinds.contains(kind)) {
      return false;
    }
  }
  return any;
}

/// Union of every bbox, or `Rect.zero` for an empty selection.
Rect selectionBounds(Iterable<List<double>> bboxes) {
  Rect? out;
  for (final List<double> b in bboxes) {
    if (b.length < 4) {
      continue;
    }
    final Rect r = Rect.fromLTRB(
      math.min(b[0], b[2]),
      math.min(b[1], b[3]),
      math.max(b[0], b[2]),
      math.max(b[1], b[3]),
    );
    out = out == null ? r : out.expandToInclude(r);
  }
  return out ?? Rect.zero;
}

/// True when [rect] intersects the marquee [selection] (touching counts).
bool intersectsMarquee(Rect rect, Rect selection) =>
    rect.overlaps(selection) ||
    selection.contains(rect.center) ||
    rect.contains(selection.center);

/// Translates a point list by [delta].
List<List<double>> translatePoints(List<List<double>> pts, Offset delta) {
  if (delta == Offset.zero) {
    return pts;
  }
  return pts
      .map(
        (List<double> p) => p.length >= 2
            ? <double>[p[0] + delta.dx, p[1] + delta.dy]
            : List<double>.of(p),
      )
      .toList(growable: false);
}

/// Translates a bbox by [delta].
List<double> translateBbox(List<double> bbox, Offset delta) {
  if (bbox.length < 4 || delta == Offset.zero) {
    return bbox;
  }
  return <double>[
    bbox[0] + delta.dx,
    bbox[1] + delta.dy,
    bbox[2] + delta.dx,
    bbox[3] + delta.dy,
  ];
}

/// Scales [pts] from [from] into [to] per axis.
///
/// Both rects describe the SAME content bounds before and after the resize
/// drag, so the mapping is a per-axis affine transform. A zero-width or
/// zero-height source axis cannot be scaled; that axis is translated instead
/// (degenerate content stays degenerate rather than collapsing to NaN).
List<List<double>> scalePoints(
  List<List<double>> pts,
  Rect from,
  Rect to,
) {
  final Offset delta = to.topLeft - from.topLeft;
  if (from.width.abs() < 1e-9 && from.height.abs() < 1e-9) {
    return translatePoints(pts, delta);
  }
  final double sx = from.width.abs() < 1e-9 ? 1.0 : to.width / from.width;
  final double sy = from.height.abs() < 1e-9 ? 1.0 : to.height / from.height;
  return pts
      .map(
        (List<double> p) => p.length >= 2
            ? <double>[
                to.left + (p[0] - from.left) * sx,
                to.top + (p[1] - from.top) * sy,
              ]
            : List<double>.of(p),
      )
      .toList(growable: false);
}

/// Scales [bbox] from [from] into [to] (bbox is axis-aligned, so this is just
/// the target rect in bbox order).
List<double> scaleBbox(List<double> bbox, Rect from, Rect to) {
  if (bbox.length < 4) {
    return bbox;
  }
  return <double>[to.left, to.top, to.right, to.bottom];
}

/// Normalises a drag rect so handles can be dragged past each other without
/// inverting the selection.
Rect normalizedRect(Rect r) => Rect.fromLTRB(
      math.min(r.left, r.right),
      math.min(r.top, r.bottom),
      math.max(r.left, r.right),
      math.max(r.top, r.bottom),
    );

/// The eight resize handles of a selection, keyed by where they sit.
enum ResizeHandle { topLeft, topCenter, topRight, centerLeft, centerRight, bottomLeft, bottomCenter, bottomRight }

/// Handle position within [bounds].
Offset handlePosition(ResizeHandle handle, Rect bounds) => switch (handle) {
      ResizeHandle.topLeft => bounds.topLeft,
      ResizeHandle.topCenter => Offset(bounds.center.dx, bounds.top),
      ResizeHandle.topRight => bounds.topRight,
      ResizeHandle.centerLeft => Offset(bounds.left, bounds.center.dy),
      ResizeHandle.centerRight => Offset(bounds.right, bounds.center.dy),
      ResizeHandle.bottomLeft => bounds.bottomLeft,
      ResizeHandle.bottomCenter => Offset(bounds.center.dx, bounds.bottom),
      ResizeHandle.bottomRight => bounds.bottomRight,
    };

/// The rect produced by dragging [handle] to [to], with the opposite
/// edge/corner pinned.
Rect resizeRect(Rect bounds, ResizeHandle handle, Offset to) {
  double left = bounds.left;
  double top = bounds.top;
  double right = bounds.right;
  double bottom = bounds.bottom;
  switch (handle) {
    case ResizeHandle.topLeft:
      left = to.dx;
      top = to.dy;
    case ResizeHandle.topCenter:
      top = to.dy;
    case ResizeHandle.topRight:
      right = to.dx;
      top = to.dy;
    case ResizeHandle.centerLeft:
      left = to.dx;
    case ResizeHandle.centerRight:
      right = to.dx;
    case ResizeHandle.bottomLeft:
      left = to.dx;
      bottom = to.dy;
    case ResizeHandle.bottomCenter:
      bottom = to.dy;
    case ResizeHandle.bottomRight:
      right = to.dx;
      bottom = to.dy;
  }
  return normalizedRect(Rect.fromLTRB(left, top, right, bottom));
}
