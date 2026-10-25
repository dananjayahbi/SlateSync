"""Round-13 issue 02 — OCR must actually receive its RPCs.

The round-12 bug is worth stating plainly because it is the most dangerous kind:
`EventBus.emit` dispatches with `handler(**payload)`, and the WebSocket server
emits `bus.emit(RPC_MESSAGE, msg=envelope)`. The OCR coordinator was declared
`_on_rpc(self, message=None, **kwargs)` and read `kwargs.get("envelope")`, so it
matched neither keyword, returned early, and **every** OCR request was silently
discarded. `EventBus` deliberately swallows handler exceptions, so nothing was
logged. The tablet waited out its timeout and the Cancel button did nothing.

The tests below therefore drive a REAL `EventBus` with the exact keyword the
server uses. Anything that constructs an envelope by hand and passes it
positionally would have missed this entirely — which is precisely what the
round-12 tests did.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from pc_agent.core.events import RPC_MESSAGE, EventBus
from pc_agent.engine.document_store import Artboard
from pc_agent.ocr import ocr_coordinator
from pc_agent.ocr.ocr_coordinator import SCOPE_CANVAS, SCOPE_REGION, OcrCoordinator
from pc_agent.ocr.ocr_engine import OcrLine, OcrResult


class _FakeRaster:
    def __init__(self, *, ink: bool = True) -> None:
        self.calls: list[dict] = []
        self._ink = ink

    def export(self, doc, dpi, out_path, progress=None, *, extent=None):
        from PIL import Image

        self.calls.append({"dpi": dpi, "extent": extent})
        img = Image.new("RGB", (200, 100), (255, 255, 255))
        if self._ink:
            for x in range(10, 40):
                for y in range(10, 30):
                    img.putpixel((x, y), (0, 0, 0))
        if progress is not None:
            progress(1.0)
        img.save(out_path, "PNG")
        return Path(out_path)


class _FakeEngine:
    def __init__(self, *, provider: str = "DmlExecutionProvider") -> None:
        self.provider = provider
        self.calls = 0

    def recognize(self, image, *, offset=(0.0, 0.0)):
        self.calls += 1
        return OcrResult(
            lines=[OcrLine(text="hello", score=1.0, box=(0, 0, 5, 5))],
            provider=self.provider,
            width=image.size[0],
            height=image.size[1],
            elapsed_ms=1,
        )


class _Doc:
    """A real CanvasDocument — `resolve_extent` reads width/height off the board."""

    def __init__(self, *, infinite: bool = False) -> None:
        self.canvas_id = "c-1"
        self.title = "t"
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
        self.elements = []
        self.groups = []


def _config(tmp_path: Path):
    return SimpleNamespace(assets_dir=tmp_path, export_dir=tmp_path)


def _envelope(action: str, payload: dict, canvas_id: str = "c-1") -> dict:
    return {
        "id": "e-1",
        "type": "OCR_JOB",
        "action": action,
        "canvas_id": canvas_id,
        "payload": payload,
        "timestamp": 1,
    }


def _build(tmp_path, *, pushes=None, engine=None):
    out = pushes if pushes is not None else []
    bus = EventBus()
    coord = OcrCoordinator(
        bus,
        _config(tmp_path),
        _FakeRaster(),
        push=out.append,
        engine_factory=lambda: engine or _FakeEngine(),
    )
    coord.attach_document_loader(lambda _request: _Doc())
    return bus, coord, out


def _drain(coord, timeout: float = 5.0) -> None:
    """Wait for the single-worker executor to go idle."""
    coord._executor.shutdown(wait=True)
    coord._executor = ocr_coordinator.ThreadPoolExecutor(max_workers=1)


def _actions(pushes) -> list[str]:
    return [p["action"] for p in pushes]


def _results(pushes) -> list[dict]:
    return [p for p in pushes if p["action"] == "OCR_RESULT"]


class TestBusDispatch:
    """The exact convention the WebSocket server uses."""

    def test_start_ocr_arrives_via_the_msg_keyword(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        engine = _FakeEngine()
        coord._engine_factory = lambda: engine

        # This is byte-for-byte how ws_stream_server emits an envelope.
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)

        assert engine.calls == 1, "the job never reached the engine"
        assert _actions(pushes), "the PC answered nothing"
        assert _results(pushes)[-1]["payload"]["text"] == "hello"

    def test_the_same_envelope_without_the_msg_keyword_is_the_control(self, tmp_path):
        """Guard the guard: prove the assertion above is meaningful.

        If the coordinator were still reading `message`/`envelope`, the emit
        above would produce no envelopes at all. This pins that a *wrong*
        keyword produces silence, so the test above cannot pass vacuously.
        """
        bus, coord, pushes = _build(tmp_path)
        bus.emit(RPC_MESSAGE, message=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)
        assert pushes == [], "a mis-keyworded dispatch must do nothing at all"

    def test_cancel_ocr_arrives_via_the_msg_keyword(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        engine = _FakeEngine()
        coord._engine_factory = lambda: engine
        # Occupy the single worker so the job stays QUEUED and the cancel below
        # is deterministic rather than racing the worker's first instruction.
        coord._executor.submit(lambda: __import__("time").sleep(0.15))
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("START_OCR", {"job_id": "j-1", "scope": SCOPE_CANVAS}),
        )
        bus.emit(RPC_MESSAGE, msg=_envelope("CANCEL_OCR", {"job_id": "j-1"}))
        _drain(coord)

        assert engine.calls == 0, "cancel never reached the job"
        assert "cancel" in _results(pushes)[-1]["payload"]["error"].lower()
        assert coord.is_running("j-1") is False

    def test_cancel_after_the_job_started_still_terminates_it(self, tmp_path):
        """Cancellation is cooperative, so the honest assertion is the outcome.

        A job that is already running keeps `is_running` true until the worker
        notices the flag — asserting otherwise would be testing a lie.
        """
        bus, coord, pushes = _build(tmp_path)
        coord.submit(job_id="j-2", request={"scope": SCOPE_CANVAS, "canvas_id": "c-1"})
        bus.emit(RPC_MESSAGE, msg=_envelope("CANCEL_OCR", {"job_id": "j-2"}))
        _drain(coord)
        # Either it finished normally or it reported cancellation, but it MUST
        # have answered and MUST be gone.
        assert len(_results(pushes)) == 1
        assert coord.is_running("j-2") is False

    def test_a_non_ocr_type_is_ignored(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        env = _envelope("START_OCR", {"scope": SCOPE_CANVAS})
        env["type"] = "EXPORT_JOB"
        bus.emit(RPC_MESSAGE, msg=env)
        _drain(coord)
        assert pushes == []

    def test_a_missing_payload_does_not_crash(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        env = _envelope("START_OCR", {})
        del env["payload"]
        bus.emit(RPC_MESSAGE, msg=env)
        _drain(coord)
        # No scope → rejected, and the tablet is told why.
        assert "error" in _results(pushes)[-1]["payload"]


class TestRejectionAlwaysAnswers:
    """A refused request must never leave the tablet waiting."""

    def test_bad_scope_answers_with_an_error(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": "everything"}))
        _drain(coord)
        results = _results(pushes)
        assert len(results) == 1
        assert results[0]["payload"]["text"] == ""
        assert "scope" in results[0]["payload"]["error"]

    def test_a_region_without_a_path_answers_with_an_error(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_REGION}))
        _drain(coord)
        payload = _results(pushes)[-1]["payload"]
        assert payload["text"] == ""
        assert payload["error"]

    def test_a_rejected_job_still_reports_the_job_id(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope("START_OCR", {"job_id": "my-job", "scope": "bogus"}),
        )
        _drain(coord)
        # Without this the tablet cannot match the reply to its request.
        assert _results(pushes)[-1]["payload"]["job_id"] == "my-job"

    def test_an_unusable_region_polygon_answers(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope(
                "START_OCR",
                {"scope": SCOPE_REGION, "path": [[0, 0], [1, 1]]},
            ),
        )
        _drain(coord)
        assert _results(pushes)[-1]["payload"]["error"]


class TestCancelSemantics:
    def test_cancel_of_an_unknown_job_is_harmless(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(RPC_MESSAGE, msg=_envelope("CANCEL_OCR", {"job_id": "ghost"}))
        assert pushes == []

    def test_cancelling_a_queued_job_prevents_the_engine_running(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        engine = _FakeEngine()
        coord._engine_factory = lambda: engine
        # Fill the single worker so the new job stays queued behind it.
        coord._executor.submit(lambda: __import__("time").sleep(0.2))
        bus.emit(
            RPC_MESSAGE,
            msg=_envelope(
                "START_OCR",
                {"job_id": "j-2", "scope": SCOPE_CANVAS},
            ),
        )
        bus.emit(RPC_MESSAGE, msg=_envelope("CANCEL_OCR", {"job_id": "j-2"}))
        _drain(coord)

        assert engine.calls == 0, "a cancelled job must not spend GPU time"
        results = _results(pushes)
        assert results, "the tablet must still be told it was cancelled"
        assert "cancel" in results[-1]["payload"]["error"].lower()

    def test_every_path_ends_with_exactly_one_result(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)
        assert _actions(pushes).count("OCR_RESULT") == 1

    def test_a_cancelled_job_reports_error_not_success(self, tmp_path):
        bus, coord, pushes = _build(tmp_path)
        coord.submit(job_id="j-3", request={"scope": SCOPE_CANVAS, "canvas_id": "c-1"})
        coord.cancel("j-3")
        coord._run_job("j-3", {"scope": SCOPE_CANVAS, "canvas_id": "c-1"})
        assert _results(pushes)[-1]["payload"]["text"] == ""
        assert "cancel" in _results(pushes)[-1]["payload"]["error"].lower()


class TestGpuIsReported:
    def test_the_provider_reaches_the_tablet(self, tmp_path):
        bus, coord, pushes = _build(tmp_path, engine=_FakeEngine())
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)
        assert _results(pushes)[-1]["payload"]["provider"] == "DmlExecutionProvider"

    def test_a_cpu_fallback_is_visible_not_hidden(self, tmp_path):
        """A silent CPU fallback is the failure mode this field exists for."""
        bus, coord, pushes = _build(
            tmp_path, engine=_FakeEngine(provider="CPUExecutionProvider")
        )
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)
        assert _results(pushes)[-1]["payload"]["provider"] == "CPUExecutionProvider"


class TestBusEventEmission:
    """The PC panel is driven by bus events, so they must actually fire."""

    def test_job_lifecycle_events_are_emitted(self, tmp_path):
        from pc_agent.core.events import OCR_JOB_FINISHED, OCR_JOB_STARTED

        seen: list[tuple[str, dict]] = []
        bus = EventBus()
        bus.on(OCR_JOB_STARTED, lambda **kw: seen.append(("started", kw)))
        bus.on(OCR_JOB_FINISHED, lambda **kw: seen.append(("finished", kw)))
        coord = OcrCoordinator(
            bus,
            _config(tmp_path),
            _FakeRaster(),
            push=lambda _p: None,
            engine_factory=_FakeEngine,
        )
        coord.attach_document_loader(lambda _r: _Doc())
        bus.emit(RPC_MESSAGE, msg=_envelope("START_OCR", {"scope": SCOPE_CANVAS}))
        _drain(coord)

        kinds = [kind for kind, _ in seen]
        assert "started" in kinds
        assert "finished" in kinds
        started = dict(seen)["started"]
        assert started["job_id"]
        assert started["scope"] == SCOPE_CANVAS
