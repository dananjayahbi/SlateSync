"""Export Stream Coordinator (Doc 15 §4–§5).

Job registry + ``ThreadPoolExecutor(2)`` running the frozen Docs 13/14
exporters, an ``RPC_MESSAGE`` subscriber for ``EXPORT_JOB`` start/cancel,
rate-limited (≤10 Hz) progress envelopes over the injected ``push`` mirrored
as ``EXPORT_STARTED/PROGRESS/FINISHED`` bus events, and a streamed
``ASSET_UPLOAD`` chunk pusher (≤262144 raw bytes per chunk).

The sibling exporters are intentionally *not* imported at runtime (parallel
Wave 2.A execution): they are type-checking-only imports and both are accepted
by duck typing as anything exposing ``.export(doc, dpi, out_path, progress=None)``
(respectively ``.export(doc, out_path, progress=None)``).
"""

from __future__ import annotations

import base64
import logging
import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import TYPE_CHECKING, Callable
from uuid import uuid4

from pc_agent.core.config_manager import AppConfig
from pc_agent.core.events import (
    EXPORT_FINISHED,
    EXPORT_PROGRESS,
    EXPORT_STARTED,
    RPC_MESSAGE,
    EventBus,
)

if TYPE_CHECKING:  # compile-time only — never imported at runtime (Doc 15 §7)
    from pc_agent.engine.document_store import CanvasDocument

    # Relative (local) imports: stable ruff isort classification whether or not
    # the sibling exporter modules exist yet during this parallel wave.
    from .tiled_raster_exporter import TiledRasterExporter
    from .vector_pdf_exporter import VectorPdfExporter

logger = logging.getLogger(__name__)

CHUNK_RAW: int = 262144  # template §3: raw bytes per asset chunk (before base64)
STAGES = ("QUEUED", "EXPORTING", "TRANSFERRING", "DONE", "ERROR")
PROGRESS_MIN_INTERVAL_S = 0.1  # ≤10 Hz (template §3 "rate" row)

_RASTER_FORMATS = frozenset({"PNG", "JPG"})
_PUSH_TARGETS = frozenset({"TABLET", "BOTH"})
_EXTENSIONS = {"PNG": "png", "JPG": "jpg", "PDF": "pdf"}


class ExportCancelled(Exception):
    """Raised from the progress callback to abort Docs 13/14 exports (Doc 15 §4)."""


class ExportCoordinator:
    """Doc 15 §4 frozen interface: ``__init__`` / ``submit`` / ``cancel``."""

    def __init__(self, bus: EventBus, config: AppConfig,
                 raster: TiledRasterExporter, vector: VectorPdfExporter,
                 push: Callable[[dict], None]) -> None:
        self._bus = bus
        self._config = config
        self._raster = raster
        self._vector = vector
        self._push = push
        self._executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="export-job")
        self._jobs: dict[str, dict] = {}  # {status, percent, stage, out_path, cancel_flag}
        self._throttle: dict[str, dict] = {}  # per-job ≤10 Hz progress state
        self._lock = threading.RLock()  # guards _jobs/_throttle + decide-and-push atomicity
        self._loader: Callable[[dict], CanvasDocument] | None = None
        bus.on(RPC_MESSAGE, self._on_rpc)

    # ------------------------------------------------------------------ §4 API

    def submit(self, job: dict) -> str:
        """Register a job, emit ``START_EXPORT`` and schedule ``_run_job`` (Doc 15 §5.3)."""
        payload, canvas_id = self._normalize_job(job)
        job_id = str(uuid4())
        with self._lock:
            self._jobs[job_id] = {
                "status": "queued",
                "percent": 0.0,
                "stage": "QUEUED",
                "out_path": None,
                "cancel_flag": False,
            }
            self._throttle[job_id] = {
                "last_ts": float("-inf"),
                "last_stage": "QUEUED",
                "last_percent": -1.0,
            }
        self._push(self._envelope("START_EXPORT", canvas_id, job_id, 0.0, "QUEUED"))
        self._bus.emit(EXPORT_STARTED, job_id=job_id)
        try:
            self._executor.submit(self._run_job, job_id, payload)
        except RuntimeError:  # executor already shut down — do not leak the entry
            with self._lock:
                self._jobs.pop(job_id, None)
                self._throttle.pop(job_id, None)
            raise
        return job_id

    def cancel(self, job_id: str) -> None:
        """Set the cooperative cancel flag; queued jobs flip straight to cancelled."""
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is None:
                return
            entry["cancel_flag"] = True
            if entry["status"] == "queued":
                entry["status"] = "cancelled"

    def attach_document_loader(self, loader: Callable[[dict], CanvasDocument]) -> None:
        """``payload → CanvasDocument``; wired to DocumentStore (Doc 10) in main.py."""
        self._loader = loader

    # ------------------------------------------------------------- §4 internals

    @staticmethod
    def _normalize_job(job: dict) -> tuple[dict, str]:
        """Accept either a full ``EXPORT_JOB`` envelope (Doc 16 GUI) or a bare payload."""
        if job.get("type") == "EXPORT_JOB" and isinstance(job.get("payload"), dict):
            canvas_id = str(job.get("canvas_id") or job["payload"].get("canvas_id") or "")
            payload = dict(job["payload"])
        else:
            payload = dict(job)
            canvas_id = str(payload.get("canvas_id") or "")
        payload["canvas_id"] = canvas_id
        return payload, canvas_id

    def _on_rpc(self, msg: dict) -> None:  # Doc 15 §4 — RPC_MESSAGE subscriber
        if not isinstance(msg, dict) or msg.get("type") != "EXPORT_JOB":
            return
        action = msg.get("action")
        if action == "START_EXPORT":
            payload = dict(msg.get("payload") or {})
            payload.setdefault("canvas_id", msg.get("canvas_id") or "")
            self.submit(payload)
        elif action == "CANCEL_EXPORT":
            payload = msg.get("payload") or {}
            job_id = payload.get("job_id")
            if job_id:
                self.cancel(str(job_id))

    def _envelope(self, action: str, canvas_id: str, job_id: str,
                  percent: float, stage: str) -> dict:
        """Doc 02 §4.2 envelope: ``{id, type, action, canvas_id, payload, timestamp}``."""
        return {
            "id": str(uuid4()),
            "type": "EXPORT_JOB",
            "action": action,
            "canvas_id": canvas_id,
            "payload": {"job_id": job_id, "percent": percent, "stage": stage},
            "timestamp": int(time.time()),
        }

    @staticmethod
    def _asset_envelope(action: str, canvas_id: str, payload: dict) -> dict:
        """Same envelope shape with ``type: "ASSET_UPLOAD"`` (Doc 02 Step 10)."""
        return {
            "id": str(uuid4()),
            "type": "ASSET_UPLOAD",
            "action": action,
            "canvas_id": canvas_id,
            "payload": payload,
            "timestamp": int(time.time()),
        }

    def _out_path(self, job_id: str, payload: dict) -> Path:
        fmt = str(payload.get("format", "PNG")).upper()
        ext = _EXTENSIONS.get(fmt, "bin")
        out_dir = Path(self._config.export_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        return out_dir / f"{job_id}.{ext}"

    # -------------------------------------------------------------- job runner

    def _run_job(self, job_id: str, payload: dict) -> None:
        with self._lock:
            entry = self._jobs.get(job_id)
        if entry is None:
            return
        canvas_id = str(payload.get("canvas_id") or "")
        path: Path | None = None
        try:
            out_path = self._out_path(job_id, payload)
            with self._lock:
                if entry["cancel_flag"] or entry["status"] == "cancelled":
                    raise ExportCancelled(job_id)
                entry["status"] = "running"
                entry["stage"] = "EXPORTING"
                entry["out_path"] = str(out_path)

            def on_progress(frac: float) -> None:
                self._report(job_id, canvas_id, frac)  # may raise ExportCancelled

            doc = self._loader(payload) if self._loader is not None else payload
            fmt = str(payload.get("format", "PNG")).upper()
            if fmt == "PDF":
                result = self._vector.export(doc, out_path, progress=on_progress)
            elif fmt in _RASTER_FORMATS:
                dpi = int(payload.get("dpi") or 600)
                result = self._raster.export(doc, dpi, out_path, progress=on_progress)
            else:
                raise ValueError(f"unsupported export format: {fmt!r}")
            path = Path(result) if result is not None else out_path

            with self._lock:
                if entry["cancel_flag"]:
                    raise ExportCancelled(job_id)
                entry["out_path"] = str(path)
            self._report(job_id, canvas_id, 1.0)  # always flush terminal progress

            if str(payload.get("target", "PC")).upper() in _PUSH_TARGETS:
                if not path.is_file():
                    raise FileNotFoundError(f"export produced no file: {path}")
                with self._lock:
                    if entry["cancel_flag"]:
                        raise ExportCancelled(job_id)
                    entry["stage"] = "TRANSFERRING"
                    entry["percent"] = 100.0
                self._report(job_id, canvas_id, 1.0)  # stage-change flush
                self._push_asset(canvas_id, path, job_id)

            with self._lock:
                entry["status"] = "done"
                entry["stage"] = "DONE"
                entry["percent"] = 100.0
            self._finish(job_id, canvas_id, entry, ok=True, path=path)
        except ExportCancelled:
            with self._lock:
                entry["status"] = "cancelled"
                entry["stage"] = "ERROR"
            self._finish(job_id, canvas_id, entry, ok=False, path=path, reason="cancelled")
        except Exception as exc:
            logger.exception("Export job %s failed", job_id)
            with self._lock:
                entry["status"] = "failed"
                entry["stage"] = "ERROR"
            self._finish(job_id, canvas_id, entry, ok=False, path=path,
                         reason=str(exc) or type(exc).__name__)
        finally:
            with self._lock:
                self._jobs.pop(job_id, None)
                self._throttle.pop(job_id, None)

    def _report(self, job_id: str, canvas_id: str, frac: float) -> None:
        """Progress callback handed to Docs 13/14: ≤10 Hz, monotonic, cancel-aware.

        Holds the registry lock across the cancel check *and* the push so that
        once ``cancel()`` returns no further ``EXPORT_PROGRESS`` can be emitted.
        Stage changes and the terminal ``100.0`` always flush.
        """
        with self._lock:
            entry = self._jobs.get(job_id)
            if entry is None:
                return
            if entry["cancel_flag"] or entry["status"] == "cancelled":
                raise ExportCancelled(job_id)
            value = float(frac)
            if not math.isfinite(value):
                value = 0.0
            percent = min(max(value, 0.0), 1.0) * 100.0
            percent = max(percent, float(entry["percent"]))  # strictly non-decreasing
            entry["percent"] = percent
            stage = entry["stage"]
            state = self._throttle.get(job_id)
            if state is None:
                return
            now = time.monotonic()
            stage_changed = stage != state["last_stage"]
            due = (now - state["last_ts"]) >= PROGRESS_MIN_INTERVAL_S
            terminal = percent >= 100.0
            fresh = percent != state["last_percent"]
            if not stage_changed and not (fresh and (due or terminal)):
                return
            state["last_ts"] = now
            state["last_stage"] = stage
            state["last_percent"] = percent
            self._push(self._envelope("EXPORT_PROGRESS", canvas_id, job_id, percent, stage))
            self._bus.emit(EXPORT_PROGRESS, job_id=job_id, percent=percent)

    def _finish(self, job_id: str, canvas_id: str, entry: dict, *,
                ok: bool, path: Path | None, reason: str | None = None) -> None:
        with self._lock:
            percent = float(entry["percent"])
            stage = entry["stage"]
            final_path = path if path is not None else entry.get("out_path")
        final_path = str(final_path) if final_path else None
        envelope = self._envelope("EXPORT_FINISHED", canvas_id, job_id, percent, stage)
        envelope["payload"]["ok"] = bool(ok)
        envelope["payload"]["path"] = final_path
        if not ok:
            envelope["payload"]["reason"] = reason or ""
        self._push(envelope)
        self._bus.emit(EXPORT_FINISHED, job_id=job_id, percent=percent,
                       path=final_path, ok=bool(ok))

    # ------------------------------------------------------------ chunk pusher

    def _push_asset(self, canvas_id: str, path: Path, job_id: str) -> None:
        """Stream ``path`` back to the tablet as ``ASSET_START/CHUNK/DONE`` (≤262144 B)."""
        path = Path(path)
        transfer_id = str(uuid4())
        size_bytes = path.stat().st_size
        total_chunks = (size_bytes + CHUNK_RAW - 1) // CHUNK_RAW
        self._push(self._asset_envelope("ASSET_START", canvas_id, {
            "transfer_id": transfer_id,
            "filename": path.name,
            "total_chunks": total_chunks,
            "size_bytes": size_bytes,
        }))
        index = 0
        with path.open("rb") as handle:
            while True:
                data = handle.read(CHUNK_RAW)
                if not data:
                    break
                with self._lock:  # cooperative cancel checked between chunks
                    entry = self._jobs.get(job_id)
                    if entry is not None and entry["cancel_flag"]:
                        raise ExportCancelled(job_id)
                self._push(self._asset_envelope("ASSET_CHUNK", canvas_id, {
                    "transfer_id": transfer_id,
                    "index": index,
                    "data_b64": base64.b64encode(data).decode("ascii"),
                }))
                index += 1
        self._push(self._asset_envelope("ASSET_DONE", canvas_id, {"transfer_id": transfer_id}))
