"""Round-8 issue 02 — fill-vs-outline policy for mirrored SHAPE nodes.

Doc 08 §5(7) has always described the shape tessellators as feeding the
triangle batch *"fill vs outline decided by ``node.style``"*, but the renderer
unconditionally emitted a fill for RECT / CIRCLE / TRIANGLE. The tablet draws
those tools as outlines (``_drawShape`` uses a ``PaintingStyle.stroke`` paint
and never sets ``PaintingStyle.fill``), so the PC mirror showed solid shapes
that the user never drew.

The wire schema (``shared_specs/canvas_document_schema.json`` §NodeStyle) is
frozen and carries only ``color`` / ``stroke_width`` / ``opacity`` /
``blend_mode`` — there is no fill field, and none may be added. The fill
decision therefore has to be derived from the style the tablet already sends.

Frozen rule (this module is the single source of truth for it):

* ``stroke_width > 0`` ⇒ **outline only** — paint the stroked ring/edges at
  ``stroke_width`` and emit no interior triangles. This is what every mobile
  shape tool produces (``ToolConfig.width`` defaults to 2.5 and the panels
  never expose 0).
* ``stroke_width == 0`` ⇒ **solid fill** — the node asked for no outline, so
  the interior is painted in ``color``. This keeps the schema's documented
  "fill vs outline" capability reachable (a programmatic node may set 0) and
  preserves the previous behaviour for such nodes.

The ARROW tool is deliberately exempt: its shaft and head are *stroked*
geometry on the tablet (two ``drawLine`` calls), never a filled polygon, so
the PC builds the shaft as a width-scaled quad plus barb lines instead of the
viewport's filled triangles.
"""

from __future__ import annotations

#: Below this width a node is treated as "no outline" ⇒ solid fill.
MIN_STROKE_WIDTH = 1e-6


def shape_is_filled(stroke_width: float) -> bool:
    """``True`` when a SHAPE node should paint its interior.

    ``stroke_width == 0`` means the author asked for no outline, which is the
    only way the frozen schema can express a solid shape. Any positive width
    is an outline — the mobile default (2.5) and therefore every shape the
    tablet draws today.
    """
    return float(stroke_width) <= MIN_STROKE_WIDTH


def arrow_is_filled(stroke_width: float) -> bool:
    """ARROW never fills: the tablet strokes its shaft and both barbs.

    A zero-width arrow still draws a hairline shaft (``max(1.0, ...)``) rather
    than a solid wedge, matching ``_drawArrow``'s unconditional ``drawLine``.
    """
    del stroke_width  # geometry choice is stroke-only for this shape_type
    return False
