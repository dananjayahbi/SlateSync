"""Round-13 issue 02 — a window that shows OCR work in progress.

Why this exists at all: an OCR job is the one operation where the PC is doing
something slow and the *tablet* is the only place it was visible. When a job
stalled, the PC looked idle and there was nothing to inspect. This window makes
the PC's queue observable — queued, running, stage and percent per job — and
gives it a Cancel button, so a stuck scan can be stopped from the machine that
is actually doing the work.

Design notes:

* **Bus-driven, never polled.** The coordinator emits
  ``OCR_JOB_STARTED`` / ``OCR_JOB_PROGRESS`` / ``OCR_JOB_FINISHED``. Tk widgets
  may only be touched from the Tk thread, so every callback hops through
  ``after(0, ...)`` — the same marshalling rule the rest of the GUI follows.
* **Non-modal on purpose.** It may sit beside the studio window; it must never
  grab input (a grab would freeze the agent while a scan runs).
* **Jobs are keyed by id, not appended blindly**, because progress arrives many
  times per job and a naive append would grow without bound.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field

import customtkinter as ctk

from pc_agent.core.events import (
    OCR_JOB_FINISHED,
    OCR_JOB_PROGRESS,
    OCR_JOB_STARTED,
    EventBus,
)
from pc_agent.gui import dialog_utils

logger = logging.getLogger(__name__)

_STAGE_LABELS = {
    "QUEUED": "Queued",
    "RASTERISING": "Rendering area",
    "RECOGNISING": "Reading text",
    "DONE": "Finishing",
    "ERROR": "Failed",
}

#: Finished jobs are kept briefly so an operator can see what just happened,
#: then dropped so a long session does not accumulate rows forever.
KEEP_FINISHED_SECONDS = 60.0
MAX_FINISHED_ROWS = 20


@dataclass
class OcrJobRow:
    """One job as displayed. Mutable because progress updates it in place."""

    job_id: str
    scope: str = ""
    canvas_id: str = ""
    stage: str = "QUEUED"
    percent: float = 0.0
    ok: bool | None = None
    reason: str = ""
    started_at: float = field(default_factory=time.monotonic)
    finished_at: float | None = None
    provider: str = ""

    @property
    def is_finished(self) -> bool:
        return self.finished_at is not None

    @property
    def stage_label(self) -> str:
        return _STAGE_LABELS.get(self.stage, self.stage.title() or "Queued")

    def summary(self) -> str:
        """One line: what this job is and how far along it is."""
        scope = "whole canvas" if self.scope == "canvas" else "selection"
        if self.is_finished:
            if self.ok is False:
                return f"{scope} — {self.reason or 'failed'}"
            if self.ok is True:
                extra = f" on {self.provider}" if self.provider else ""
                return f"{scope} — done{extra}"
        return f"{scope} — {self.stage_label} {self.percent:.0f}%"


class OcrJobsPanel:
    """Non-modal window listing OCR jobs with live progress and cancel."""

    def __init__(
        self,
        root: object,
        bus: EventBus,
        *,
        cancel: Callable[[str], object] | None = None,
        on_close: Callable[[], None] | None = None,
        auto_show: bool = False,
    ) -> None:
        self._bus = bus
        self._cancel = cancel
        self._on_close = on_close
        self._root = root
        self._rows: dict[str, OcrJobRow] = {}
        self._order: list[str] = []
        self._widgets: dict[str, ctk.CTkFrame] = {}
        self._closed = False

        # Created through dialog_utils so the panel is owned by the studio
        # window. A bare CTkToplevel opens behind it on Windows; the whole
        # point of this module is that popups are visible when they appear.
        self._window = dialog_utils.make_toplevel(root, "SlateSync OCR Jobs")
        self._window.geometry("520x420")
        self._window.minsize(420, 320)
        self._window.protocol("WM_DELETE_WINDOW", self.close)

        self._header = ctk.CTkLabel(
            self._window,
            text="No OCR jobs yet",
            anchor="w",
        )
        self._header.pack(fill="x", padx=12, pady=(12, 6))

        self._list = ctk.CTkScrollableFrame(self._window, label_text="Jobs")
        self._list.pack(fill="both", expand=True, padx=12, pady=(0, 12))

        self._empty = ctk.CTkLabel(
            self._list,
            text="Scans requested from a tablet appear here.",
            anchor="w",
        )
        self._empty.pack(fill="x", pady=8)

        bus.on(OCR_JOB_STARTED, self._on_started)
        bus.on(OCR_JOB_PROGRESS, self._on_progress)
        bus.on(OCR_JOB_FINISHED, self._on_finished)

        if auto_show:
            self.show()

    # ------------------------------------------------------------------ window

    @property
    def window(self) -> object:
        return self._window

    def exists(self) -> bool:
        return not self._closed

    def show(self) -> None:
        if self._closed:
            return
        try:
            # modal=False: the agent must stay usable while a scan runs, so this
            # must never take a grab.
            dialog_utils.show_toplevel(self._window, self._root, modal=False)
        except Exception:  # pragma: no cover - window may already be gone
            logger.debug("OCR panel: show failed", exc_info=True)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        for event, handler in (
            (OCR_JOB_STARTED, self._on_started),
            (OCR_JOB_PROGRESS, self._on_progress),
            (OCR_JOB_FINISHED, self._on_finished),
        ):
            try:
                self._bus.off(event, handler)
            except Exception:  # pragma: no cover - defensive
                logger.debug("OCR panel: unsubscribe failed", exc_info=True)
        try:
            self._window.destroy()
        except Exception:  # pragma: no cover - already destroyed
            pass
        if self._on_close is not None:
            self._on_close()

    # ------------------------------------------------------------------- bus

    def _on_started(self, **payload: object) -> None:
        job_id = str(payload.get("job_id") or "")
        if not job_id:
            return
        row = OcrJobRow(
            job_id=job_id,
            scope=str(payload.get("scope") or ""),
            canvas_id=str(payload.get("canvas_id") or ""),
        )
        self._rows[job_id] = row
        if job_id not in self._order:
            self._order.insert(0, job_id)  # newest first
        self._marshal(self._render)

    def _on_progress(self, **payload: object) -> None:
        job_id = str(payload.get("job_id") or "")
        row = self._rows.get(job_id)
        if row is None:
            # Progress for a job whose START we never saw (e.g. panel opened
            # mid-job): adopt it rather than dropping the update.
            row = OcrJobRow(job_id=job_id)
            self._rows[job_id] = row
            self._order.insert(0, job_id)
        stage = payload.get("stage")
        if isinstance(stage, str) and stage:
            row.stage = stage
        percent = payload.get("percent")
        if isinstance(percent, (int, float)):
            value = float(percent)
            # Monotonic: a stale/out-of-order update must not make the bar jump
            # backwards, which reads as a bug to the operator.
            row.percent = max(row.percent, min(max(value, 0.0), 100.0))
        self._marshal(self._render)

    def _on_finished(self, **payload: object) -> None:
        job_id = str(payload.get("job_id") or "")
        row = self._rows.get(job_id)
        if row is None:
            row = OcrJobRow(job_id=job_id)
            self._rows[job_id] = row
            self._order.insert(0, job_id)
        row.ok = bool(payload.get("ok")) if "ok" in payload else None
        reason = payload.get("reason")
        row.reason = str(reason) if reason else ""
        provider = payload.get("provider")
        if isinstance(provider, str):
            row.provider = provider
        row.finished_at = time.monotonic()
        if row.ok is not False:
            row.percent = 100.0
            row.stage = "DONE"
        else:
            row.stage = "ERROR"
        self._marshal(self._render)

    # ------------------------------------------------------------------- view

    def _marshal(self, action: Callable[[], None]) -> None:
        """Hop to the Tk thread. Bus events arrive from worker threads."""
        try:
            self._window.after(0, action)
        except Exception:  # pragma: no cover - window already destroyed
            logger.debug("OCR panel: marshal failed", exc_info=True)

    def _prune(self) -> None:
        now = time.monotonic()
        finished = [
            job_id
            for job_id in self._order
            if (row := self._rows.get(job_id)) is not None
            and row.is_finished
            and row.finished_at is not None
            and now - row.finished_at > KEEP_FINISHED_SECONDS
        ]
        for job_id in finished:
            self._order.remove(job_id)
            self._rows.pop(job_id, None)
        remaining = [j for j in self._order if self._rows.get(j) and self._rows[j].is_finished]
        for job_id in remaining[MAX_FINISHED_ROWS:]:
            self._order.remove(job_id)
            self._rows.pop(job_id, None)

    def _render(self) -> None:
        if self._closed:
            return
        try:
            self._prune()
            active = [j for j in self._order if not self._rows[j].is_finished]
            self._header.configure(
                text=(
                    f"{len(active)} running / {len(self._order)} shown"
                    if self._order
                    else "No OCR jobs yet"
                )
            )
            self._empty.pack_forget() if self._order else self._empty.pack(fill="x", pady=8)

            for job_id in self._order:
                widget = self._widgets.get(job_id)
                if widget is None:
                    widget = self._build_row(self._rows[job_id])
                    self._widgets[job_id] = widget
                self._update_row(self._rows[job_id], widget)
            # Re-stack so newest stays on top after adoptions.
            for job_id in reversed(self._order):
                widget = self._widgets.get(job_id)
                if widget is not None:
                    widget.pack(fill="x", pady=3)
        except Exception:  # pragma: no cover - a UI error must not kill the app
            logger.debug("OCR panel: render failed", exc_info=True)

    def _build_row(self, row: OcrJobRow) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self._list)
        label = ctk.CTkLabel(frame, text=row.summary(), anchor="w")
        label.pack(side="left", fill="x", expand=True, padx=(8, 4), pady=4)
        bar = ctk.CTkProgressBar(frame, height=6)
        bar.set(row.percent / 100.0)
        bar.pack(side="left", fill="x", expand=True, padx=4, pady=4)
        button = ctk.CTkButton(
            frame,
            text="Cancel",
            width=70,
            command=lambda job_id=row.job_id: self._request_cancel(job_id),
        )
        button.pack(side="right", padx=(4, 8), pady=4)
        frame._ocr_label = label  # type: ignore[attr-defined]
        frame._ocr_bar = bar  # type: ignore[attr-defined]
        frame._ocr_button = button  # type: ignore[attr-defined]
        return frame

    def _update_row(self, row: OcrJobRow, frame: ctk.CTkFrame) -> None:
        label = getattr(frame, "_ocr_label", None)
        bar = getattr(frame, "_ocr_bar", None)
        button = getattr(frame, "_ocr_button", None)
        if label is not None:
            label.configure(text=row.summary())
        if bar is not None:
            bar.set(row.percent / 100.0)
        if button is not None:
            # Cancelling a finished job is meaningless; disable rather than
            # leaving a button that does nothing.
            button.configure(state="disabled" if row.is_finished else "normal")

    def _request_cancel(self, job_id: str) -> None:
        if self._cancel is None:
            return
        try:
            self._cancel(job_id)
        except Exception:  # pragma: no cover - cancel must never raise into Tk
            logger.warning("OCR panel: cancel %s failed", job_id, exc_info=True)
