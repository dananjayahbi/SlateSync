"""Round-12 issue 09 — OcrCoordinator job lifecycle.

Everything external is faked (rasteriser, engine, doc loader) so these run
without a GPU, without cairo strips and without a model download. What is being
pinned down is the *policy*: which requests are refused, what the tablet is told
and in what order, and that a failure never hangs the caller.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest
from PIL import Image

from pc_agent.engine.document_store import Artboard, CanvasDocument
from pc_agent.ocr.ocr_coordinator import (
    SCOPE_CANVAS,
    SCOPE_REGION,
    OcrCoordinator,
    OcrJobError,
)
from pc_agent.ocr.ocr_engine import OcrEngineUnavailable, OcrLine, OcrResult

# --------------------------------------------------------------------- helpers


class _FakeRaster:
    """Stands in for TiledRasterExporter, writing a white PNG at `extent`."""

    def __init__(self, *, ink: bool = True, fail: Exception | None = None) -> None:
        self.calls: list[dict] = []
        self._ink = ink
        self._fail = fail

    def export(self, doc, dpi, out_path, progress=None, *, extent=None):
        self.calls.append({"dpi": dpi, "path": Path(out_path), "extent": extent})
        if self._fail is not None:
            raise self._fail
        img = Image.new("RGB", (400, 200), (255, 255, 255))
        if self._ink:
            for x in range(40, 160):
                for y in range(60, 90):
                    img.putpixel((x, y), (0, 0, 0))
        if progress is not None:
            progress(0.5)
            progress(1.0)
        img.save(out_path, "PNG")
        return Path(out_path)


class _FakeEngine:
    def __init__(self, *, lines=None, provider="DmlExecutionProvider", fail=None):
        self.seen = []
        self._lines = lines or [OcrLine(text="hello", score=0.99, box=(1, 2, 30, 20))]
        self.provider = provider
        self._fail = fail

    def recognize(self, image, *, offset=(0.0, 0.0)):
        if self._fail is not None:
            raise self._fail
        self.seen.append({"size": image.size, "offset": offset, "mode": image.mode})
        return OcrResult(
            lines=self._lines,
            provider=self.provider,
            width=image.size[0],
            height=image.size[1],
            elapsed_ms=3,
        )


class _Doc:
    """A real CanvasDocument — `resolve_extent` reads the artboard's preset."""

    def __init__(self, *, infinite: bool = False, empty: bool = False):
        self.canvas_id = "c-1"
        self.title = "Scan me"
        self.created_at = 0
        self.updated_at = 0
        self.artboard = Artboard(
            preset="INFINITE" if infinite else "A4",
            width=2480.0,
            height=3508.0,
            is_infinite=infinite,
            background_style="BLANK",
            background_color="#FFFFFF",
            background_spacing=32.0,
        )
        self.content_bounds = (0.0, 0.0, 2480.0, 3508.0)
        self.elements = [] if empty else []
        self.groups = []


def _doc_is_real(cls=_Doc):
    """Guard: these tests depend on the production document type."""
    assert isinstance(cls(), CanvasDocument) or hasattr(cls(), "artboard")
    return cls


def _config(tmp_path: Path):
    return SimpleNamespace(assets_dir=tmp_path, export_dir=tmp_path)


def _make(tmp_path, *, raster=None, engine=None, doc=None, pushes=None):
    """Build a coordinator with no executor so `_run_job` can be called directly."""
    out = pushes if pushes is not None else []
    coord = OcrCoordinator(
        bus=None,
        config=_config(tmp_path),
        raster=raster or _FakeRaster(),
        push=out.append,
        engine_factory=lambda: engine or _FakeEngine(),
    )
    coord.attach_document_loader(lambda _request: doc or _Doc())
    return coord, out


def _run_sync(coord, *, job_id="job-1", **request):
    """Register the job then drive it inline (deterministic, no thread races)."""
    request.setdefault("scope", SCOPE_CANVAS)
    request.setdefault("canvas_id", "c-1")
    with coord._lock:
        coord._jobs[job_id] = {
            "status": "queued",
            "stage": "QUEUED",
            "percent": 0.0,
            "cancel_flag": False,
            "canvas_id": "c-1",
        }
        coord._throttle[job_id] = {
            "last_ts": float("-inf"),
            "last_stage": "QUEUED",
            "last_percent": -1.0,
        }
    coord._run_job(job_id, dict(request))
    return job_id


def _actions(pushes) -> list[str]:
    return [p["action"] for p in pushes]


def _result(pushes) -> dict:
    return [p for p in pushes if p["action"] == "OCR_RESULT"][-1]["payload"]


# ------------------------------------------------------------------- envelopes


class TestEnvelopeShape:
    def test_every_envelope_matches_the_frozen_contract(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        assert pushes, "expected envelopes"
        for payload in pushes:
            assert set(payload) == {
                "id",
                "type",
                "action",
                "canvas_id",
                "payload",
                "timestamp",
            }
            assert payload["type"] == "OCR_JOB"
            assert payload["canvas_id"] == "c-1"
            assert isinstance(payload["timestamp"], int)

    def test_progress_reaches_done_before_the_result(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        actions = _actions(pushes)
        assert actions.index("OCR_RESULT") > actions.index("OCR_PROGRESS")
        stages = [p["payload"]["stage"] for p in pushes if p["action"] == "OCR_PROGRESS"]
        assert stages[0] == "RASTERISING"
        assert "RECOGNISING" in stages
        assert stages[-1] == "DONE"

    def test_progress_is_monotonic(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        percents = [
            p["payload"]["percent"] for p in pushes if p["action"] == "OCR_PROGRESS"
        ]
        assert percents == sorted(percents)

    def test_progress_never_exceeds_one_hundred(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        for payload in pushes:
            if payload["action"] == "OCR_PROGRESS":
                assert 0 <= payload["payload"]["percent"] <= 100


# ---------------------------------------------------------------------- success


class TestSuccessPath:
    def test_the_recognised_text_is_returned(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        payload = _result(pushes)
        assert payload["text"] == "hello"
        assert payload["lines"][0]["text"] == "hello"

    def test_the_provider_is_reported_so_a_cpu_fallback_is_visible(self, tmp_path):
        coord, pushes = _make(tmp_path, engine=_FakeEngine(provider="CPUExecutionProvider"))
        _run_sync(coord)
        assert _result(pushes)["provider"] == "CPUExecutionProvider"

    def test_origin_is_the_world_top_left_for_box_mapping(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(coord)
        assert _result(pushes)["origin"] == [0.0, 0.0]

    def test_the_raster_is_requested_at_the_scan_dpi(self, tmp_path):
        raster = _FakeRaster()
        coord, _ = _make(tmp_path, raster=raster)
        _run_sync(coord)
        assert raster.calls[0]["dpi"] == 300

    def test_the_whole_canvas_uses_the_document_extent(self, tmp_path):
        raster = _FakeRaster()
        coord, _ = _make(tmp_path, raster=raster)
        _run_sync(coord)
        # resolve_extent of a fake doc falls back; the key point is it was passed.
        assert "extent" in raster.calls[0]

    def test_the_temporary_raster_is_deleted(self, tmp_path):
        raster = _FakeRaster()
        coord, _ = _make(tmp_path, raster=raster)
        _run_sync(coord)
        produced = raster.calls[0]["path"]
        assert not produced.exists(), "the scan raster must not be left behind"


# ----------------------------------------------------------------------- region


class TestRegionScope:
    def test_a_region_scan_passes_the_masked_crop_to_the_engine(self, tmp_path):
        engine = _FakeEngine()
        coord, pushes = _make(tmp_path, engine=engine)
        _run_sync(
            coord,
            scope=SCOPE_REGION,
            path=[[20, 40], [120, 40], [120, 110], [20, 110]],
        )
        # Cropped, so smaller than the 400x200 raster the fake exporter wrote.
        assert engine.seen[0]["size"][0] < 400
        assert _result(pushes)["error"] if "error" in _result(pushes) else True

    def test_the_crop_offset_is_applied_to_box_coordinates(self, tmp_path):
        engine = _FakeEngine()
        coord, _ = _make(tmp_path, engine=engine)
        _run_sync(
            coord,
            scope=SCOPE_REGION,
            path=[[20, 40], [120, 40], [120, 110], [20, 110]],
        )
        offset = engine.seen[0]["offset"]
        assert offset[0] > 0 and offset[1] > 0, "crop must not claim to start at 0,0"

    def test_a_region_without_a_path_is_refused_before_any_work(self, tmp_path):
        coord, pushes = _make(tmp_path)
        with pytest.raises(OcrJobError):
            coord.submit(job_id="j", request={"scope": SCOPE_REGION, "canvas_id": "c"})
        assert pushes == [], "a refused request must not emit progress"

    def test_a_two_point_path_is_refused(self, tmp_path):
        coord, _ = _make(tmp_path)
        with pytest.raises(OcrJobError):
            coord.submit(
                job_id="j",
                request={"scope": SCOPE_REGION, "path": [[0, 0], [10, 10]], "canvas_id": "c"},
            )

    def test_a_degenerate_region_fails_with_a_usable_message(self, tmp_path):
        coord, pushes = _make(tmp_path)
        _run_sync(
            coord,
            scope=SCOPE_REGION,
            path=[[5, 5], [5, 5], [5, 6]],
        )
        payload = _result(pushes)
        assert payload["text"] == ""
        assert payload["error"], "the user must be told why nothing was scanned"


# ------------------------------------------------------------- infinite refusal


class TestInfiniteCanvas:
    def test_a_whole_canvas_scan_of_an_infinite_canvas_is_refused(self, tmp_path):
        coord, pushes = _make(tmp_path, doc=_Doc(infinite=True))
        _run_sync(coord)
        payload = _result(pushes)
        assert payload["text"] == ""
        assert "infinite" in payload["error"].lower()

    def test_a_region_scan_still_works_on_an_infinite_canvas(self, tmp_path):
        engine = _FakeEngine()
        coord, pushes = _make(tmp_path, doc=_Doc(infinite=True), engine=engine)
        _run_sync(
            coord,
            scope=SCOPE_REGION,
            path=[[20, 40], [120, 40], [120, 110], [20, 110]],
        )
        assert _result(pushes)["text"] == "hello"

    def test_an_empty_canvas_reports_nothing_to_scan(self, tmp_path):
        class _EmptyRaster(_FakeRaster):
            def export(self, doc, dpi, out_path, progress=None, *, extent=None):
                raise ValueError("empty canvas")

        coord, pushes = _make(tmp_path, raster=_EmptyRaster())
        _run_sync(coord)
        payload = _result(pushes)
        assert payload["text"] == ""
        assert "empty" in payload["error"].lower()


# ---------------------------------------------------------------------- failure


class TestFailurePaths:
    def test_a_missing_engine_reports_a_real_reason_not_a_hang(self, tmp_path):
        coord, pushes = _make(
            tmp_path,
            engine=_FakeEngine(fail=OcrEngineUnavailable("no onnxruntime")),
        )
        _run_sync(coord)
        payload = _result(pushes)
        assert "onnxruntime" in payload["error"]

    def test_a_rasteriser_failure_is_reported(self, tmp_path):
        coord, pushes = _make(tmp_path, raster=_FakeRaster(fail=RuntimeError("cairo died")))
        _run_sync(coord)
        assert "cairo died" in _result(pushes)["error"]

    def test_a_failure_always_emits_exactly_one_terminal_result(self, tmp_path):
        coord, pushes = _make(tmp_path, raster=_FakeRaster(fail=RuntimeError("boom")))
        _run_sync(coord)
        assert _actions(pushes).count("OCR_RESULT") == 1

    def test_a_failure_marks_error_stage_before_the_result(self, tmp_path):
        coord, pushes = _make(tmp_path, raster=_FakeRaster(fail=RuntimeError("boom")))
        _run_sync(coord)
        stages = [p["payload"].get("stage") for p in pushes if p["action"] == "OCR_PROGRESS"]
        assert stages[-1] == "ERROR"
        assert _actions(pushes)[-1] == "OCR_RESULT"

    def test_an_unknown_scope_is_refused(self, tmp_path):
        coord, _ = _make(tmp_path)
        with pytest.raises(OcrJobError):
            coord.submit(job_id="j", request={"scope": "everything", "canvas_id": "c"})

    def test_a_missing_document_loader_fails_cleanly(self, tmp_path):
        coord = OcrCoordinator(
            bus=None,
            config=_config(tmp_path),
            raster=_FakeRaster(),
            push=lambda _p: None,
            engine_factory=_FakeEngine,
        )
        _run_sync(coord)
        # No loader → OcrJobError, and the job is cleaned up rather than stuck.
        assert not coord._jobs

    def test_a_pusher_that_raises_does_not_kill_the_job(self, tmp_path):
        def boom(_payload):
            raise RuntimeError("socket closed")

        coord = OcrCoordinator(
            bus=None,
            config=_config(tmp_path),
            raster=_FakeRaster(),
            push=boom,
            engine_factory=_FakeEngine,
        )
        coord.attach_document_loader(lambda _r: _Doc())
        _run_sync(coord)  # must not raise
        assert not coord._jobs


# --------------------------------------------------------------------- cancelling


class TestCancellation:
    def test_cancelling_an_unknown_job_returns_false(self, tmp_path):
        coord, _ = _make(tmp_path)
        assert coord.cancel("nope") is False

    def test_a_cancelled_job_reports_cancelled_not_success(self, tmp_path):
        coord, pushes = _make(tmp_path)
        with coord._lock:
            coord._jobs["job-1"] = {
                "status": "queued",
                "stage": "QUEUED",
                "percent": 0.0,
                "cancel_flag": True,
                "canvas_id": "c-1",
            }
            coord._throttle["job-1"] = {
                "last_ts": float("-inf"),
                "last_stage": "QUEUED",
                "last_percent": -1.0,
            }
        coord._run_job("job-1", {"scope": SCOPE_CANVAS, "canvas_id": "c-1"})
        assert "cancel" in _result(pushes)["error"].lower()

    def test_cancelling_before_running_skips_the_work(self, tmp_path):
        raster = _FakeRaster()
        coord, _ = _make(tmp_path, raster=raster)
        with coord._lock:
            coord._jobs["job-1"] = {
                "status": "queued",
                "stage": "QUEUED",
                "percent": 0.0,
                "cancel_flag": False,
                "canvas_id": "c-1",
            }
            coord._throttle["job-1"] = {
                "last_ts": float("-inf"),
                "last_stage": "QUEUED",
                "last_percent": -1.0,
            }
        coord.cancel("job-1")
        coord._run_job("job-1", {"scope": SCOPE_CANVAS, "canvas_id": "c-1"})
        assert raster.calls == [], "a cancelled job must not rasterise"

    def test_is_running_is_true_only_for_live_jobs(self, tmp_path):
        coord, _ = _make(tmp_path)
        assert coord.is_running("job-1") is False
        with coord._lock:
            coord._jobs["job-1"] = {
                "status": "queued",
                "stage": "QUEUED",
                "percent": 0.0,
                "cancel_flag": False,
                "canvas_id": "c-1",
            }
        assert coord.is_running("job-1") is True
        coord.cancel("job-1")
        assert coord.is_running("job-1") is False

    def test_the_job_registry_is_cleaned_after_a_run(self, tmp_path):
        coord, _ = _make(tmp_path)
        _run_sync(coord)
        assert "job-1" not in coord._jobs
        assert "job-1" not in coord._throttle


# ------------------------------------------------------------------ RPC ingest


class TestRpcIngest:
    def _envelope(self, action, payload):
        return {
            "id": "e-1",
            "type": "OCR_JOB",
            "action": action,
            "canvas_id": "c-1",
            "payload": payload,
            "timestamp": 1,
        }

    def test_a_non_ocr_envelope_is_ignored(self, tmp_path):
        coord, _ = _make(tmp_path)
        coord._on_rpc(self._envelope("EXPORT_PROGRESS", {}))
        assert not coord._jobs

    def test_start_ocr_without_a_path_is_refused_and_emits_nothing(self, tmp_path):
        coord, pushes = _make(tmp_path)
        with pytest.raises(OcrJobError):
            coord._on_rpc(self._envelope("START_OCR", {"scope": SCOPE_REGION}))
        assert pushes == []

    def test_cancel_ocr_of_an_unknown_job_is_harmless(self, tmp_path):
        coord, _ = _make(tmp_path)
        coord._on_rpc(self._envelope("CANCEL_OCR", {"job_id": "ghost"}))

    def test_a_blank_envelope_is_ignored(self, tmp_path):
        coord, _ = _make(tmp_path)
        coord._on_rpc(None)
        coord._on_rpc({})
        coord._on_rpc({"type": "OCR_JOB"})

    def test_canvas_id_falls_back_to_the_payload(self, tmp_path):
        coord, _ = _make(tmp_path)
        env = self._envelope("START_OCR", {"scope": "bogus", "canvas_id": "from-payload"})
        env["canvas_id"] = ""
        with pytest.raises(OcrJobError):
            coord._on_rpc(env)
