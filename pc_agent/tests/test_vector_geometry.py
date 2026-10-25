"""Round-9 issues 04/05/06 — vector geometry for fill, paths and tables.

The viewport and all three exporters consume these helpers, so a bug here shows
up in four renderers at once. These tests pin the contract (closure tolerance,
triangulation of concave loops, table grid clamps) rather than any single
caller's behaviour.
"""

from __future__ import annotations

import math

import pytest

from pc_agent.viewport.vector_geometry import (
    MAX_TABLE_COLS,
    MAX_TABLE_ROWS,
    ellipse_polygon,
    outline_segments,
    point_in_polygon,
    points_of,
    polyline_is_closed,
    rect_polygon,
    signed_area,
    table_geometry,
    triangulate,
)


def _square(size: float = 100.0) -> list[tuple[float, float]]:
    return [(0.0, 0.0), (size, 0.0), (size, size), (0.0, size)]


# ---------------------------------------------------------------------------
# points_of / rect / ellipse
# ---------------------------------------------------------------------------


def test_points_of_drops_malformed_entries() -> None:
    assert points_of([[1, 2], [3], "nope", [4, 5], None]) == [(1.0, 2.0), (4.0, 5.0)]
    assert points_of(None) == []
    assert points_of("text") == []


def test_rect_polygon_normalises_an_inverted_bbox() -> None:
    assert rect_polygon((100.0, 80.0, 0.0, 0.0)) == [
        (0.0, 0.0),
        (100.0, 0.0),
        (100.0, 80.0),
        (0.0, 80.0),
    ]


def test_rect_polygon_rejects_a_degenerate_bbox() -> None:
    assert rect_polygon((10.0, 10.0, 10.0, 40.0)) == []
    assert rect_polygon(None) == []


def test_ellipse_polygon_inscribes_the_bbox() -> None:
    polygon = ellipse_polygon((0.0, 0.0, 100.0, 50.0), segments=8)
    assert len(polygon) == 8
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    assert math.isclose(max(xs), 100.0, abs_tol=1e-9)
    assert math.isclose(max(ys), 50.0, abs_tol=1e-9)
    assert all(point_in_polygon((50.0, 25.0), polygon) for _ in [0])


def test_ellipse_polygon_rejects_a_zero_extent_bbox() -> None:
    assert ellipse_polygon((0.0, 0.0, 0.0, 50.0)) == []


# ---------------------------------------------------------------------------
# closure detection
# ---------------------------------------------------------------------------


def test_a_loop_that_returns_to_its_start_is_closed() -> None:
    loop = [(0.0, 0.0), (200.0, 0.0), (200.0, 200.0), (0.0, 200.0), (3.0, 3.0)]
    assert polyline_is_closed(loop)


def test_an_open_arc_is_not_closed() -> None:
    arc = [(0.0, 0.0), (100.0, 0.0), (200.0, 100.0)]
    assert not polyline_is_closed(arc)


def test_closure_tolerance_scales_with_the_path_size() -> None:
    # A 12-unit gap closes on a small loop (the absolute floor) but not on a
    # page-sized one, where the gap would be visually obvious.
    small = [(0.0, 0.0), (40.0, 0.0), (40.0, 40.0), (12.0, 0.0)]
    assert polyline_is_closed(small)
    big = [
        (0.0, 0.0),
        (2400.0, 0.0),
        (2400.0, 3400.0),
        (0.0, 3400.0),
        (400.0, 400.0),
    ]
    assert not polyline_is_closed(big)


def test_a_two_point_path_is_never_a_region() -> None:
    assert not polyline_is_closed([(0.0, 0.0), (10.0, 10.0)])


# ---------------------------------------------------------------------------
# point-in-polygon / area
# ---------------------------------------------------------------------------


def test_point_in_polygon_handles_concave_loops() -> None:
    # A "C" shape: the notch is outside the polygon.
    c_shape = [
        (0.0, 0.0),
        (100.0, 0.0),
        (100.0, 20.0),
        (20.0, 20.0),
        (20.0, 80.0),
        (100.0, 80.0),
        (100.0, 100.0),
        (0.0, 100.0),
    ]
    assert point_in_polygon((10.0, 50.0), c_shape)
    assert not point_in_polygon((60.0, 50.0), c_shape)


def test_signed_area_is_positive_for_counter_clockwise() -> None:
    assert signed_area(_square()) > 0
    assert signed_area(list(reversed(_square()))) < 0


# ---------------------------------------------------------------------------
# triangulation
# ---------------------------------------------------------------------------


def test_triangulate_emits_two_triangles_for_a_quad() -> None:
    flat = triangulate(_square())
    assert len(flat) == 12  # 2 triangles × 3 verts × 2 ordinates


def test_triangulate_covers_a_concave_polygon_with_the_right_area() -> None:
    """The triangle area must equal the polygon area for ear clipping.

    A fan would OVER-count here (it walks outside the outline), which is the
    artefact the fill tool must never produce.
    """

    def tri_area(flat: list[float]) -> float:
        total = 0.0
        for i in range(0, len(flat), 6):
            ax, ay, bx, by, cx, cy = flat[i : i + 6]
            total += abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2.0
        return total

    c_shape = [
        (0.0, 0.0),
        (100.0, 0.0),
        (100.0, 20.0),
        (20.0, 20.0),
        (20.0, 80.0),
        (100.0, 80.0),
        (100.0, 100.0),
        (0.0, 100.0),
    ]
    flat = triangulate(c_shape)
    assert math.isclose(tri_area(flat), abs(signed_area(c_shape)), rel_tol=1e-9)


def test_triangulate_of_a_degenerate_polygon_is_empty() -> None:
    assert triangulate([(0.0, 0.0), (1.0, 1.0)]) == []


def test_outline_segments_close_the_loop() -> None:
    segments = outline_segments(_square())
    assert len(segments) == 4
    assert segments[-1][2:] == (0.0, 0.0)  # last edge returns to the start


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------


def test_table_geometry_builds_edges_bands_and_lines() -> None:
    geo = table_geometry(
        (0.0, 0.0, 300.0, 200.0),
        {"rows": 4, "cols": 3, "header_row": True, "header_col": True},
    )
    assert geo.is_valid
    assert geo.rows == 4
    assert geo.cols == 3
    assert geo.row_edges == pytest.approx([0.0, 50.0, 100.0, 150.0, 200.0])
    assert geo.col_edges == pytest.approx([0.0, 100.0, 200.0, 300.0])
    assert len(geo.lines) == 5 + 4
    assert len(geo.header_rects) == 2
    # The corner cell belongs to the row band only.
    assert geo.header_rects[0] == (0.0, 0.0, 300.0, 50.0)
    assert geo.header_rects[1][1] == pytest.approx(50.0)


def test_table_geometry_without_header_flags_has_no_bands() -> None:
    geo = table_geometry(
        (0.0, 0.0, 100.0, 100.0),
        {"rows": 2, "cols": 2, "header_row": False, "header_col": False},
    )
    assert geo.header_rects == []


def test_a_single_row_cannot_be_a_header_band() -> None:
    geo = table_geometry((0.0, 0.0, 100.0, 100.0), {"rows": 1, "cols": 1,
                                                   "header_row": True})
    assert geo.header_row is False
    assert geo.header_rects == []


def test_table_geometry_clamps_hostile_config() -> None:
    geo = table_geometry((0.0, 0.0, 100.0, 100.0), {"rows": 10**9, "cols": -4})
    assert geo.rows == MAX_TABLE_ROWS
    assert geo.cols == 1
    geo_high_cols = table_geometry((0.0, 0.0, 100.0, 100.0), {"cols": 10**9})
    assert geo_high_cols.cols == MAX_TABLE_COLS


def test_table_geometry_defaults_when_config_is_missing() -> None:
    geo = table_geometry((0.0, 0.0, 100.0, 100.0), None)
    assert (geo.rows, geo.cols) == (3, 3)


def test_table_geometry_is_invalid_for_a_degenerate_bbox() -> None:
    geo = table_geometry((10.0, 10.0, 10.0, 10.0), {"rows": 3, "cols": 3})
    assert not geo.is_valid
    assert geo.lines == []
