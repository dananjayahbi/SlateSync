"""Round-8 issue 02 — fill-vs-outline policy (Doc 08 §5(7)).

The tablet strokes RECT / CIRCLE / TRIANGLE / ARROW; the PC mirror used to
fill them unconditionally. These tests pin the frozen rule the renderer now
follows and the arrow barb geometry the tablet actually draws.
"""

from __future__ import annotations

import math

import pytest

from pc_agent.viewport.primitive_renderer import arrow_outline_segments
from pc_agent.viewport.shape_fill import (
    MIN_STROKE_WIDTH,
    arrow_is_filled,
    shape_is_filled,
)

# --- shape_is_filled -------------------------------------------------------


def test_default_tool_width_is_an_outline() -> None:
    """ToolConfig.width defaults to 2.5 — every mobile shape is an outline."""
    assert shape_is_filled(2.5) is False


@pytest.mark.parametrize("width", [0.5, 1.0, 2.0, 2.5, 8.0, 20.0, 1e-3])
def test_positive_width_never_fills(width: float) -> None:
    assert shape_is_filled(width) is False


@pytest.mark.parametrize("width", [0.0, -0.0, -3.0])
def test_zero_or_negative_width_fills(width: float) -> None:
    """The frozen schema's only fill escape hatch: no outline requested."""
    assert shape_is_filled(width) is True


def test_threshold_is_documented_epsilon() -> None:
    assert MIN_STROKE_WIDTH == 1e-6
    assert shape_is_filled(MIN_STROKE_WIDTH) is True
    assert shape_is_filled(MIN_STROKE_WIDTH * 2) is False


def test_arrow_never_fills() -> None:
    for width in (0.0, 2.5, 10.0):
        assert arrow_is_filled(width) is False


# --- arrow_outline_segments ------------------------------------------------


def test_arrow_segments_are_shaft_plus_two_barbs() -> None:
    segments = arrow_outline_segments((0.0, 0.0), (100.0, 0.0), 2.5)
    assert len(segments) == 3
    assert segments[0] == (0.0, 0.0, 100.0, 0.0)  # shaft


def test_arrow_barbs_anchor_at_the_tip_not_beyond_it() -> None:
    """The viewport's filled arrow apexes PAST the end point; the tablet's
    barbs start at the tip and angle back, so the drawn head stays inside the
    node bbox."""
    segments = arrow_outline_segments((0.0, 0.0), (100.0, 0.0), 2.5)
    for ax, ay, bx, by in segments[1:]:
        assert (ax, ay) == (100.0, 0.0)  # both barbs start at the tip
        assert bx < 100.0  # and point back along the shaft
        assert abs(by) > 0.0  # splayed off-axis


def test_arrow_barb_length_is_max_12_or_4x_stroke_width() -> None:
    # 2.5 → 4·2.5 = 10 < 12 ⇒ stub length clamps to 12
    short = arrow_outline_segments((0.0, 0.0), (100.0, 0.0), 2.5)
    thin_len = math.hypot(short[1][2] - 100.0, short[1][3])
    assert thin_len == pytest.approx(12.0, abs=1e-6)
    # 10 → 4·10 = 40 > 12 ⇒ width-scaled
    long = arrow_outline_segments((0.0, 0.0), (100.0, 0.0), 10.0)
    thick_len = math.hypot(long[1][2] - 100.0, long[1][3])
    assert thick_len == pytest.approx(40.0, abs=1e-6)


def test_arrow_barbs_are_mirrored_about_the_shaft() -> None:
    """Both barbs anchor at the tip; for a vertical shaft they share the same
    y and mirror in x."""
    segments = arrow_outline_segments((0.0, 0.0), (0.0, 100.0), 5.0)
    left, right = segments[1], segments[2]
    assert left[0] == right[0] == 0.0  # both start at the tip x
    assert left[1] == right[1] == 100.0  # both start at the tip y
    assert left[3] == pytest.approx(right[3], abs=1e-6)  # same barb length back
    assert left[2] == pytest.approx(-right[2], abs=1e-6)  # symmetric in x


def test_degenerate_arrow_has_no_segments() -> None:
    assert arrow_outline_segments((5.0, 5.0), (5.0, 5.0), 2.5) == []
