"""Round-12 issue 09 — region mask and engine plumbing tests.

These cover the parts that are pure logic (no model download): polygon
validation, crop geometry, the white-paper masking rule, and the engine's
lazy/release behaviour. The actual accuracy of the model is not something a
unit test should assert on.
"""

from __future__ import annotations

import math

from PIL import Image

from pc_agent.ocr.region_mask import (
    DEFAULT_GROW,
    crop_to_polygon,
    is_usable_polygon,
    polygon_bounds,
)


def _page(width: int = 200, height: int = 120) -> Image.Image:
    """White page with a black block on the left and a red block on the right."""
    img = Image.new("RGB", (width, height), (255, 255, 255))
    for x in range(10, 40):
        for y in range(10, 40):
            img.putpixel((x, y), (0, 0, 0))
    for x in range(150, 180):
        for y in range(60, 90):
            img.putpixel((x, y), (255, 0, 0))
    return img


class TestPolygonValidation:
    def test_too_few_points_is_not_usable(self):
        assert is_usable_polygon([(0, 0), (10, 10)]) is False

    def test_none_and_empty_are_not_usable(self):
        assert is_usable_polygon(None) is False
        assert is_usable_polygon([]) is False

    def test_a_real_triangle_is_usable(self):
        assert is_usable_polygon([(0, 0), (50, 0), (25, 40)]) is True

    def test_collinear_points_have_no_area(self):
        # Zero height: nothing could be enclosed.
        assert is_usable_polygon([(0, 5), (10, 5), (20, 5)]) is False

    def test_non_finite_points_are_dropped(self):
        pts = [(0, 0), (float("nan"), 5), (40, 0), (20, float("inf")), (20, 30)]
        assert polygon_bounds(pts) == (0.0, 0.0, 40.0, 30.0)

    def test_malformed_entries_are_dropped(self):
        pts = [(0, 0), "nope", (40, 0), (None, 3), (20, 30)]
        assert polygon_bounds(pts) == (0.0, 0.0, 40.0, 30.0)

    def test_bounds_of_a_square(self):
        assert polygon_bounds([(5, 6), (25, 6), (25, 40), (5, 40)]) == (5.0, 6.0, 25.0, 40.0)


class TestCropToPolygon:
    def test_a_polygon_around_the_black_block_keeps_only_that_ink(self):
        page = _page()
        crop = crop_to_polygon(page, [(5, 5), (45, 5), (45, 45), (5, 45)])
        assert crop is not None
        # The red block must be gone: it was outside the outline.
        colours = crop.image.getcolors(maxcolors=1 << 20) or []
        assert not any(
            count and r > 150 and g < 80 and b < 80 for count, (r, g, b) in colours
        )
        # And there must still be black ink.
        assert any(count and r < 60 and g < 60 and b < 60 for count, (r, g, b) in colours)

    def test_outside_the_selection_becomes_white_not_transparent(self):
        page = _page()
        crop = crop_to_polygon(page, [(5, 5), (45, 5), (45, 45), (5, 45)])
        assert crop is not None
        assert crop.image.mode == "RGB", "the recogniser expects paper, not alpha"
        # The corner furthest from the ink is pure white.
        assert crop.image.getpixel((crop.image.width - 2, crop.image.height - 2)) == (
            255,
            255,
            255,
        )

    def test_the_crop_is_bounded_by_the_polygon_not_the_whole_page(self):
        page = _page()
        crop = crop_to_polygon(page, [(5, 5), (45, 5), (45, 45), (5, 45)])
        assert crop is not None
        assert crop.image.width < page.width
        assert crop.image.height < page.height

    def test_offset_reports_where_the_crop_came_from(self):
        page = _page()
        crop = crop_to_polygon(page, [(60, 50), (100, 50), (100, 95), (60, 95)])
        assert crop is not None
        # Grown by the default radius on every side.
        grow = int(DEFAULT_GROW)
        assert crop.offset[0] <= 60
        assert crop.offset[1] <= 50
        assert crop.offset[0] >= 60 - grow - 1
        assert crop.offset[1] >= 50 - grow - 1

    def test_scale_maps_world_units_into_pixel_space(self):
        page = _page()
        # A polygon that is 20x20 in world units at scale 2 covers 40x40 px.
        at_one = crop_to_polygon(page, [(60, 50), (80, 50), (80, 70), (60, 70)], scale=1.0)
        at_two = crop_to_polygon(page, [(60, 50), (80, 50), (80, 70), (60, 70)], scale=2.0)
        assert at_one is not None and at_two is not None
        assert at_two.image.width > at_one.image.width

    def test_zero_scale_falls_back_to_one_instead_of_dividing_by_zero(self):
        page = _page()
        crop = crop_to_polygon(page, [(5, 5), (45, 5), (45, 45), (5, 45)], scale=0.0)
        assert crop is not None
        assert crop.image.width > 0

    def test_nan_scale_is_ignored(self):
        page = _page()
        crop = crop_to_polygon(page, [(5, 5), (45, 5), (45, 45), (5, 45)], scale=float("nan"))
        assert crop is not None
        assert crop.image.width > 0

    def test_a_degenerate_polygon_returns_none(self):
        assert crop_to_polygon(_page(), [(5, 5), (6, 6)]) is None

    def test_a_polygon_entirely_off_the_page_returns_none(self):
        # Bounds are valid but clamp to zero area against the image.
        assert crop_to_polygon(_page(), [(900, 900), (980, 900), (980, 980)]) is None

    def test_a_polygon_beyond_the_edge_is_clamped_not_crashed(self):
        page = _page()
        crop = crop_to_polygon(page, [(150, 60), (400, 60), (400, 200), (150, 200)])
        assert crop is not None
        assert crop.image.width <= page.width
        assert crop.image.height <= page.height

    def test_it_accepts_a_numpy_array(self):
        import numpy as np

        arr = np.full((80, 100, 3), 255, dtype=np.uint8)
        arr[20:50, 20:50] = 0
        crop = crop_to_polygon(arr, [(10, 10), (60, 10), (60, 60), (10, 60)])
        assert crop is not None
        assert crop.image.mode == "RGB"


class TestEngineLaziness:
    def test_importing_the_package_does_not_load_a_model(self):
        from pc_agent.ocr import ocr_engine

        ocr_engine.reset_engine_for_tests()
        engine = ocr_engine.get_engine()
        assert engine.is_loaded is False
        assert engine.provider == "not-loaded"

    def test_get_engine_returns_the_same_instance(self):
        from pc_agent.ocr import ocr_engine

        ocr_engine.reset_engine_for_tests()
        assert ocr_engine.get_engine() is ocr_engine.get_engine()
        ocr_engine.reset_engine_for_tests()

    def test_release_if_idle_does_nothing_when_not_loaded(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        assert OcrEngine().release_if_idle() is False

    def test_release_if_idle_keeps_a_recently_used_engine(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        engine = OcrEngine()
        engine._engine = object()  # pretend loaded
        engine._last_used = 1000.0
        assert engine.release_if_idle(now=1000.0 + 1.0) is False
        assert engine.is_loaded is True

    def test_release_if_idle_drops_an_old_engine(self):
        from pc_agent.ocr.ocr_engine import IDLE_RELEASE_SECONDS, OcrEngine

        engine = OcrEngine()
        engine._engine = object()
        engine._last_used = 0.0
        assert engine.release_if_idle(now=IDLE_RELEASE_SECONDS + 1.0) is True
        assert engine.is_loaded is False

    def test_release_is_safe_to_call_twice(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        engine = OcrEngine()
        engine.release()
        engine.release()
        assert engine.is_loaded is False


class TestResultShape:
    def test_text_joins_lines_and_empty_detects_nothing(self):
        from pc_agent.ocr.ocr_engine import OcrLine, OcrResult

        empty = OcrResult()
        assert empty.is_empty is True
        assert empty.text == ""

        result = OcrResult(
            lines=[
                OcrLine(text="hello", score=0.9, box=(0, 0, 10, 10)),
                OcrLine(text="world", score=0.8, box=(0, 12, 10, 22)),
            ]
        )
        assert result.is_empty is False
        assert result.text == "hello\nworld"

    def test_to_wire_is_json_safe(self):
        import json

        from pc_agent.ocr.ocr_engine import OcrLine, OcrResult

        result = OcrResult(
            lines=[OcrLine(text="a", score=0.123456, box=(0.4, 1.6, 9.2, 20.0))],
            provider="DmlExecutionProvider",
            width=10,
            height=20,
            elapsed_ms=5,
        )
        payload = result.to_wire()
        json.dumps(payload)  # must not raise
        assert payload["lines"][0]["score"] == 0.1235
        assert payload["lines"][0]["box"] == [0.4, 1.6, 9.2, 20.0]


class TestParams:
    def test_gpu_params_request_directml(self):
        from pc_agent.ocr.ocr_engine import _build_params

        params = _build_params(True)
        assert params["EngineConfig.onnxruntime.use_dml"] is True

    def test_cpu_params_do_not_request_directml(self):
        from pc_agent.ocr.ocr_engine import _build_params

        assert "EngineConfig.onnxruntime.use_dml" not in _build_params(False)

    def test_params_pin_the_measured_winning_model(self):
        from pc_agent.ocr.ocr_engine import _build_params

        params = _build_params(True)
        assert params["Det.model_type"].value == "small"
        assert params["Rec.model_type"].value == "small"
        assert params["Det.ocr_version"].value == "PP-OCRv6"
        assert params["Det.lang_type"].value == "en"


class TestLineNormalisation:
    def test_quads_become_axis_aligned_boxes(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["hi"]
            scores = [0.9]
            boxes = [[[10, 20], [40, 18], [41, 44], [9, 45]]]

        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert len(lines) == 1
        assert lines[0].box == (9.0, 18.0, 41.0, 45.0)

    def test_offset_is_added_to_boxes(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["hi"]
            scores = [0.9]
            boxes = [[[0, 0], [10, 0], [10, 10], [0, 10]]]

        lines = OcrEngine._to_lines(Raw(), (100.0, 200.0))
        assert lines[0].box == (100.0, 200.0, 110.0, 210.0)

    def test_low_confidence_lines_are_dropped(self):
        from pc_agent.ocr.ocr_engine import MIN_SCORE, OcrEngine

        class Raw:
            txts = ["noise", "real"]
            scores = [MIN_SCORE - 0.01, 0.9]
            boxes = [[[0, 0], [5, 0], [5, 5], [0, 5]]] * 2

        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert [ln.text for ln in lines] == ["real"]

    def test_blank_text_is_dropped(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["   ", "ok"]
            scores = [0.9, 0.9]
            boxes = [[[0, 0], [5, 0], [5, 5], [0, 5]]] * 2

        assert [ln.text for ln in OcrEngine._to_lines(Raw(), (0.0, 0.0))] == ["ok"]

    def test_none_result_is_empty(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        assert OcrEngine._to_lines(None, (0.0, 0.0)) == []

    def test_missing_boxes_do_not_crash_and_stack(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["one", "two"]
            scores = [0.9, 0.9]
            boxes = None

        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert len(lines) == 2
        assert lines[0].box[1] < lines[1].box[1]

    def test_reading_order_is_top_then_left(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["bottom", "right", "left"]
            scores = [0.9, 0.9, 0.9]
            boxes = [
                [[0, 100], [10, 100], [10, 110], [0, 110]],
                [[80, 10], [90, 10], [90, 20], [80, 20]],
                [[5, 10], [15, 10], [15, 20], [5, 20]],
            ]

        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert [ln.text for ln in lines] == ["left", "right", "bottom"]

    def test_mismatched_score_list_does_not_crash(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["a", "b"]
            scores = [0.9]
            boxes = [[[0, 0], [5, 0], [5, 5], [0, 5]]] * 2

        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert len(lines) == 2

    def test_nan_quad_does_not_crash(self):
        from pc_agent.ocr.ocr_engine import OcrEngine

        class Raw:
            txts = ["a"]
            scores = [0.9]
            boxes = [[[math.nan, 0], [5, 0], [5, 5], [0, 5]]]

        # Non-finite geometry falls through to the stacked fallback.
        lines = OcrEngine._to_lines(Raw(), (0.0, 0.0))
        assert len(lines) == 1

class TestSelfTestCli:
    """`--ocr-selftest` is the only honest answer to "is the GPU being used?".

    These stay hermetic: they patch the engine singleton rather than loading a
    real model, so the suite never depends on a GPU or a downloaded weight.
    """

    def test_it_reports_ok_and_the_provider(self, capsys, monkeypatch):
        from pc_agent import main as agent_main
        from pc_agent.ocr import ocr_engine

        class _Eng:
            def release(self):
                pass

            def recognize(self, _image, *, offset=(0.0, 0.0)):
                return ocr_engine.OcrResult(
                    lines=[
                        ocr_engine.OcrLine(
                            text="SlateSync OCR 24680", score=1.0, box=(0, 0, 10, 10)
                        )
                    ],
                    provider="DmlExecutionProvider",
                    width=720,
                    height=160,
                    elapsed_ms=12,
                )

        ocr_engine.reset_engine_for_tests()
        monkeypatch.setattr(ocr_engine, "_ENGINE", _Eng())
        assert agent_main.run_ocr_selftest() == 0
        out = capsys.readouterr().out
        assert "provider: DmlExecutionProvider" in out
        assert "OK" in out
        ocr_engine.reset_engine_for_tests()

    def test_a_cpu_fallback_warns_but_still_passes(self, capsys, monkeypatch):
        from pc_agent import main as agent_main
        from pc_agent.ocr import ocr_engine

        class _Eng:
            def release(self):
                pass

            def recognize(self, _image, *, offset=(0.0, 0.0)):
                return ocr_engine.OcrResult(
                    lines=[
                        ocr_engine.OcrLine(
                            text="SlateSync 24680", score=0.9, box=(0, 0, 9, 9)
                        )
                    ],
                    provider="CPUExecutionProvider",
                )

        ocr_engine.reset_engine_for_tests()
        monkeypatch.setattr(ocr_engine, "_ENGINE", _Eng())
        assert agent_main.run_ocr_selftest() == 0
        assert "WARNING" in capsys.readouterr().err
        ocr_engine.reset_engine_for_tests()

    def test_recognising_nothing_is_a_failure(self, monkeypatch):
        from pc_agent import main as agent_main
        from pc_agent.ocr import ocr_engine

        class _Eng:
            def release(self):
                pass

            def recognize(self, _image, *, offset=(0.0, 0.0)):
                return ocr_engine.OcrResult()

        ocr_engine.reset_engine_for_tests()
        monkeypatch.setattr(ocr_engine, "_ENGINE", _Eng())
        assert agent_main.run_ocr_selftest() == 1
        ocr_engine.reset_engine_for_tests()

    def test_unexpected_text_is_a_failure(self, monkeypatch):
        from pc_agent import main as agent_main
        from pc_agent.ocr import ocr_engine

        class _Eng:
            def release(self):
                pass

            def recognize(self, _image, *, offset=(0.0, 0.0)):
                return ocr_engine.OcrResult(
                    lines=[ocr_engine.OcrLine(text="???", score=0.9, box=(0, 0, 1, 1))],
                    provider="DmlExecutionProvider",
                )

        ocr_engine.reset_engine_for_tests()
        monkeypatch.setattr(ocr_engine, "_ENGINE", _Eng())
        assert agent_main.run_ocr_selftest() == 1
        ocr_engine.reset_engine_for_tests()

    def test_an_engine_failure_is_reported_not_raised(self, monkeypatch, capsys):
        from pc_agent import main as agent_main
        from pc_agent.ocr import ocr_engine

        class _Eng:
            def release(self):
                pass

            def recognize(self, _image, *, offset=(0.0, 0.0)):
                raise ocr_engine.OcrEngineUnavailable("no onnxruntime")

        ocr_engine.reset_engine_for_tests()
        monkeypatch.setattr(ocr_engine, "_ENGINE", _Eng())
        assert agent_main.run_ocr_selftest() == 1
        assert "no onnxruntime" in capsys.readouterr().err
        ocr_engine.reset_engine_for_tests()
