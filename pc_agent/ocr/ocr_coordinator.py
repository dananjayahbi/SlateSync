"""Round-12 issue 09 — the OCR job lifecycle.

Mirrors :class:`ExportCoordinator` deliberately: the export path already solved
threading, throttled progress, cooperative cancellation and the frozen envelope
shape, so copying that structure keeps one mental model for "long PC job driven
by the tablet".

Flow::

    START_OCR  ──► QUEUED ──► RASTERISING ──► RECOGNISING ──► DONE
                        └──► ERROR (bad scope, infinite canvas, engine missing)

Differences from export worth knowing:

* the raster is **temporary** — it exists only to feed the model, never kept;
* a **region** scan is masked to the user's free-drawn polygon, so ink outside
  the loop cannot leak into the result;
* **whole-canvas** scans are refused on infinite canvases, because "the entire
  canvas" is not a bounded area there.
"""

from __future__ import annotations

import logging
import math
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import TYPE_CHECKING, Any, Callable, Sequence
from uuid import uuid4

from pc_agent.core.events import (
    OCR_JOB_FINISHED,
    OCR_JOB_PROGRESS,
    OCR_JOB_STARTED,
    RPC_MESSAGE,
    EventBus,
)
from pc_agent.ocr.ocr_engine import (
    OcrEngineError,
    OcrEngineUnavailable,
    OcrResult,
    get_engine,
)
from pc_agent.ocr.region_mask import crop_to_polygon, is_usable_polygon

if TYPE_CHECKING:  # compile-time only — no GL/export import needed to import this
    from pc_agent.core.config_manager import AppConfig
    from pc_agent.engine.document_store import CanvasDocument
    from pc_agent.export.tiled_raster_exporter import TiledRasterExporter

logger = logging.getLogger(__name__)

#: Progress is throttled to the same 10 Hz ceiling the export job uses.
PROGRESS_MIN_INTERVAL_S = 0.1

#: Rasterisation DPI for a scan. 300 is the exporter's floor and is already
#: beyond what the recogniser resizes to internally, so higher only costs time.
SCAN_DPI = 300

#: Default world-unit growth applied around a free-drawn selection.
DEFAULT_PADDING = 6.0

STAGES = ("QUEUED", "RASTERISING", "RECOGNISING", "DONE", "ERROR")

SCOPE_REGION = "region"
SCOPE_CANVAS = "canvas"


class OcrJobError(RuntimeError):
    """A request that cannot be attempted; surfaced to the tablet as `error`."""


class OcrCancelled(Exception):
    """Raised internally when the tablet cancels an in-flight job."""


class _Push:
    """Small helper so a missing pusher in tests cannot raise mid-job."""

    def __init__(self, push: Callable[[dict], None] | None) -> None:
        self._push = push or (lambda _payload: None)

    def __call__(self, payload: dict) -> None:
        try:
            self._push(payload)
        except Exception:  # pragma: no cover - transport failure must not kill the job
            logger.warning("OCR: pushing an envelope failed", exc_info=True)


class OcrCoordinator:
    """Owns OCR jobs: submit, progress, result, cancel."""

    def __init__(
        self,
        bus: EventBus | None,
        config: AppConfig,
        raster: TiledRasterExporter | None,
        push: Callable[[dict], None] | None = None,
        engine_factory: Callable[[], Any] | None = None,
    ) -> None:
        self._bus = bus
        self._config = config
        self._raster = raster
        self._push = _Push(push)
        self._engine_factory = engine_factory or get_engine
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ocr-job")
        self._jobs: dict[str, dict] = {}
        self._throttle: dict[str, dict] = {}
        self._lock = threading.RLock()
        self._loader: Callable[[dict], CanvasDocument] | None = None
        if bus is not None:
            bus.on(RPC_MESSAGE, self._on_rpc)

    # ------------------------------------------------------------------ wiring

    def attach_document_loader(self, loader: Callable[[dict], CanvasDocument]) -> None:
        """Inject the doc resolver (same contract as the export coordinator)."""
        self._loader = loader

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=True)

    # ------------------------------------------------------------- RPC ingest

    def _on_rpc(self, msg: Any = None, **_extra: Any) -> None:
        """Handle `START_OCR` / `CANCEL_OCR` off the bus.

        The signature is `(self, msg=None, **_extra)` **on purpose**: the bus
        dispatches with `handler(**payload)` and the WebSocket server emits
        `bus.emit(RPC_MESSAGE, msg=envelope)`. Every other subscriber is
        declared the same way. A parameter named anything else simply never
        receives the envelope, and because `EventBus.emit` swallows handler
        exceptions the failure is completely silent — which is exactly how
        OCR shipped with every request dropped on the floor.
        """
        if not isinstance(msg, dict):
            return
        if msg.get("type") != "OCR_JOB":
            return
        action = msg.get("action")
        payload = msg.get("payload") or {}
        if not isinstance(payload, dict):
            return
        canvas_id = str(msg.get("canvas_id") or payload.get("canvas_id") or "")

        if action == "CANCEL_OCR":
            job_id = str(payload.get("job_id") or "")
            if job_id:
                self.cancel(job_id)
            return
        if action != "START_OCR":
            return

        # The tablet may propose its own job_id so it can correlate a cancel
        # before the first progress arrives; otherwise mint one.
        job_id = str(payload.get("job_id") or "").strip() or str(uuid4())
        request = dict(payload)
        request["canvas_id"] = canvas_id or payload.get("canvas_id")
        try:
            self.submit(job_id=job_id, request=request)
        except OcrJobError as exc:
            # A rejected request MUST still answer the tablet. Letting the
            # exception escape would hand it to `EventBus.emit`, which logs and
            # swallows it — and the tablet would wait out its whole timeout for
            # a job that was never queued.
            logger.info("OCR request %s rejected: %s", job_id, exc)
            self._fail(job_id, canvas_id, str(exc))
        except RuntimeError as exc:
            # Executor already shut down (app closing mid-request).
            logger.warning("OCR request %s not scheduled: %s", job_id, exc)
            self._fail(job_id, canvas_id, "The PC is shutting down.")

    # ------------------------------------------------------------------ §API

    def submit(self, *, job_id: str, request: dict) -> str:
        """Validate, register and schedule a job. Raises :class:`OcrJobError`."""
        scope = str(request.get("scope") or "").strip().lower()
        if scope not in (SCOPE_REGION, SCOPE_CANVAS):
            raise OcrJobError(f"unknown OCR scope {scope!r}")
        if scope == SCOPE_REGION and not is_usable_polygon(request.get("path")):
            raise OcrJobError(
                "Select an area to scan: draw a closed outline with at least three points"
            )

        with self._lock:
            self._jobs[job_id] = {
                "status": "queued",
                "stage": "QUEUED",
                "percent": 0.0,
                "cancel_flag": False,
                "canvas_id": str(request.get("canvas_id") or ""),
            }
            self._throttle[job_id] = {
                "last_ts": float("-inf"),
                "last_stage": "QUEUED",
                "last_percent": -1.0,
            }

        self._emit_progress(job_id, 0.0, "QUEUED")
        self._emit_event(
            OCR_JOB_STARTED,
            job_id=job_id,
            scope=scope,
            canvas_id=str(request.get("canvas_id") or ""),
        )
        try:
            self._executor.submit(self._run_job, job_id, request)
        except RuntimeError:
            with self._lock:
                self._jobs.pop(job_id, None)
                self._throttle.pop(job_id, None)
            raise
        return job_id

    def cancel(self, job_id: str) -> bool:
        """Ask a job to stop. Returns False when the id is unknown."""
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is None:
                return False
            entry["cancel_flag"] = True
            if entry["status"] == "queued":
                entry["status"] = "cancelled"
            return True

    def is_running(self, job_id: str) -> bool:
        with self._lock:
            entry = self._jobs.get(job_id)
            return entry is not None and entry["status"] in ("queued", "running")

    # -------------------------------------------------------------- job runner

    def _run_job(self, job_id: str, request: dict) -> None:
        canvas_id = str(request.get("canvas_id") or "")
        try:
            # Checked first: a job cancelled while queued must not spend time
            # resolving a document or rasterising anything.
            self._check_cancelled(job_id)
            doc = self._resolve_document(request)
            extent = self._resolve_extent(request, doc)

            self._stage(job_id, "RASTERISING", 10.0)
            raster_path = self._rasterise(job_id, doc, extent)
            try:
                self._stage(job_id, "RECOGNISING", 55.0)
                result = self._recognise(job_id, request, raster_path, extent)
            finally:
                try:
                    raster_path.unlink(missing_ok=True)
                except OSError:  # pragma: no cover - temp cleanup is best effort
                    logger.debug("OCR: could not remove %s", raster_path)

            self._stage(job_id, "DONE", 100.0)
            self._emit_result(job_id, canvas_id, result=result, origin=extent[:2])
        except OcrCancelled:
            self._fail(job_id, canvas_id, "Cancelled")
        except (OcrEngineUnavailable, OcrEngineError) as exc:
            logger.warning("OCR job %s: engine problem: %s", job_id, exc)
            self._fail(job_id, canvas_id, str(exc))
        except OcrJobError as exc:
            self._fail(job_id, canvas_id, str(exc))
        except Exception as exc:  # pragma: no cover - last-resort guard
            logger.exception("OCR job %s failed", job_id)
            self._fail(job_id, canvas_id, str(exc) or type(exc).__name__)
        finally:
            with self._lock:
                self._jobs.pop(job_id, None)
                self._throttle.pop(job_id, None)

    def _resolve_document(self, request: dict) -> CanvasDocument:
        if self._loader is None:
            raise OcrJobError("OCR is not wired to a canvas yet")
        try:
            doc = self._loader(request)
        except Exception as exc:
            raise OcrJobError(f"Could not open the canvas for scanning: {exc}") from exc
        if doc is None:
            raise OcrJobError("Could not open the canvas for scanning")
        return doc

    def _resolve_extent(
        self, request: dict, doc: CanvasDocument
    ) -> tuple[float, float, float, float]:
        """World region to rasterise, refusing unbounded requests."""
        scope = str(request.get("scope") or "").strip().lower()
        if scope == SCOPE_REGION:
            from pc_agent.ocr.region_mask import polygon_bounds

            bounds = polygon_bounds(request.get("path"))
            if bounds is None:
                raise OcrJobError(
                    "Select an area to scan: draw a closed outline with at least three points"
                )
            return bounds

        if getattr(doc.artboard, "is_infinite", False):
            # "The whole canvas" has no bounded area on an infinite canvas; the
            # tablet hides the button, and this is the server-side backstop.
            raise OcrJobError(
                "An infinite canvas cannot be scanned in full — select an area instead"
            )
        from pc_agent.export.tiled_raster_exporter import resolve_extent

        try:
            return resolve_extent(doc)
        except ValueError as exc:
            raise OcrJobError("This canvas is empty — there is nothing to scan") from exc

    def _rasterise(
        self,
        job_id: str,
        doc: CanvasDocument,
        extent: tuple[float, float, float, float],
    ) -> Path:
        if self._raster is None:
            raise OcrJobError("The canvas renderer is unavailable")
        # The exporter renders strips synchronously and only calls `progress`
        # between them, so a cancel requested before the first strip would
        # otherwise be invisible until the whole raster finished.
        self._check_cancelled(job_id)
        handle = tempfile.NamedTemporaryFile(
            prefix=f"slatesync-ocr-{job_id[:8]}-", suffix=".png", delete=False
        )
        path = Path(handle.name)
        handle.close()

        def on_progress(frac: float) -> None:
            self._check_cancelled(job_id)
            # 10→50 % of the job is rasterisation.
            value = 10.0 + min(max(float(frac or 0.0), 0.0), 1.0) * 40.0
            self._emit_progress(job_id, value, "RASTERISING")

        try:
            self._raster.export(doc, SCAN_DPI, path, progress=on_progress, extent=extent)
        except Exception as exc:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
            raise OcrJobError(f"Could not render the area to scan: {exc}") from exc
        self._check_cancelled(job_id)
        return path

    def _recognise(
        self,
        job_id: str,
        request: dict,
        raster_path: Path,
        extent: tuple[float, float, float, float],
    ) -> OcrResult:
        from PIL import Image

        self._check_cancelled(job_id)
        engine = self._engine_factory()
        with Image.open(raster_path) as page:
            page.load()
            image = page.convert("RGB")

        offset = (0.0, 0.0)
        if str(request.get("scope") or "").lower() == SCOPE_REGION:
            padding = request.get("padding")
            grow = DEFAULT_PADDING
            if isinstance(padding, (int, float)) and math.isfinite(float(padding)):
                grow = max(0.0, float(padding))
            # The polygon is in world units; the raster is at SCAN_DPI, where
            # 1 world unit == 1 px (the exporter's own 300 DPI reference).
            crop = crop_to_polygon(
                image,
                request.get("path"),
                scale=1.0,
                grow=grow,
            )
            if crop is None:
                raise OcrJobError(
                    "The selected area is too small to scan — draw a larger outline"
                )
            image = crop.image
            offset = crop.offset

        self._check_cancelled(job_id)
        result = engine.recognize(image, offset=offset)
        logger.info(
            "OCR job %s: %d line(s), provider=%s, %d ms",
            job_id,
            len(result.lines),
            result.provider,
            result.elapsed_ms,
        )
        return result

    # -------------------------------------------------------------- envelopes

    def _check_cancelled(self, job_id: str) -> None:
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is None or entry["cancel_flag"] or entry["status"] == "cancelled":
                raise OcrCancelled(job_id)

    def _stage(self, job_id: str, stage: str, percent: float) -> None:
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is not None:
                entry["status"] = "running"
                entry["stage"] = stage
        self._emit_progress(job_id, percent, stage)

    def _emit_progress(self, job_id: str, percent: float, stage: str) -> None:
        """Throttled, monotonic progress — stage changes always flush."""
        with self._lock:
            entry = self._jobs.get(job_id)
            state = self._throttle.get(job_id)
            if entry is None or state is None:
                return
            value = float(percent)
            if not math.isfinite(value):
                value = 0.0
            value = min(max(value, 0.0), 100.0)
            value = max(value, float(entry["percent"]))
            entry["percent"] = value
            now = time.monotonic()
            stage_changed = stage != state["last_stage"]
            due = (now - state["last_ts"]) >= PROGRESS_MIN_INTERVAL_S
            terminal = value >= 100.0
            fresh = value != state["last_percent"]
            if not stage_changed and not (fresh and (due or terminal)):
                return
            state["last_ts"] = now
            state["last_stage"] = stage
            state["last_percent"] = value
            canvas_id = entry["canvas_id"]

        self._push(
            self._envelope(
                "OCR_PROGRESS",
                canvas_id,
                {"job_id": job_id, "stage": stage, "percent": int(round(value))},
            )
        )
        self._emit_event(
            OCR_JOB_PROGRESS,
            job_id=job_id,
            stage=stage,
            percent=value,
            canvas_id=canvas_id,
        )

    def _fail(self, job_id: str, canvas_id: str, reason: str) -> None:
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is not None:
                entry["stage"] = "ERROR"
        self._push(
            self._envelope(
                "OCR_PROGRESS",
                canvas_id,
                {"job_id": job_id, "stage": "ERROR", "percent": 100},
            )
        )
        self._push(
            self._envelope(
                "OCR_RESULT",
                canvas_id,
                {"job_id": job_id, "text": "", "error": reason or "OCR failed"},
            )
        )
        self._emit_event(
            OCR_JOB_FINISHED,
            job_id=job_id,
            ok=False,
            reason=reason or "OCR failed",
            canvas_id=canvas_id,
        )

    def _emit_result(
        self,
        job_id: str,
        canvas_id: str,
        *,
        result: OcrResult,
        origin: Sequence[float],
    ) -> None:
        payload: dict[str, Any] = result.to_wire()
        payload["job_id"] = job_id
        payload["origin"] = [round(float(origin[0]), 2), round(float(origin[1]), 2)]
        self._push(self._envelope("OCR_RESULT", canvas_id, payload))
        self._emit_event(
            OCR_JOB_FINISHED,
            job_id=job_id,
            ok=True,
            reason="",
            canvas_id=canvas_id,
            lines=len(result.lines),
            provider=result.provider,
            elapsed_ms=result.elapsed_ms,
        )

    def _emit_event(self, event: str, **payload: Any) -> None:
        """Bus notify for the PC panel; a missing/failing bus is not fatal."""
        if self._bus is None:
            return
        try:
            self._bus.emit(event, **payload)
        except Exception:  # pragma: no cover - the panel must never break a job
            logger.debug("OCR: bus emit %s failed", event, exc_info=True)

    @staticmethod
    def _envelope(action: str, canvas_id: str, payload: dict) -> dict:
        return {
            "id": str(uuid4()),
            "type": "OCR_JOB",
            "action": action,
            "canvas_id": canvas_id,
            "payload": payload,
            "timestamp": int(time.time()),
        }
