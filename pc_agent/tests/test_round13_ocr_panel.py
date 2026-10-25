"""Round-13 issue 02 — the OCR jobs panel.

Focused on the state machine rather than pixels: what the panel shows for a
given sequence of bus events, whether cancel is offered only when it means
something, and whether pruning keeps a long session bounded. Tk itself is
stubbed, because the point is the logic, not the widget tree.
"""

from __future__ import annotations

import pytest

from pc_agent.core.events import (
    OCR_JOB_FINISHED,
    OCR_JOB_PROGRESS,
    OCR_JOB_STARTED,
    EventBus,
)
from pc_agent.gui import ocr_jobs_panel as panel_mod
from pc_agent.gui.ocr_jobs_panel import (
    KEEP_FINISHED_SECONDS,
    MAX_FINISHED_ROWS,
    OcrJobRow,
    OcrJobsPanel,
)


class _FakeWidget:
    def __init__(self, *args, **kwargs):
        self.options: dict = dict(kwargs)
        self.packed = False
        self._ocr_label = None
        self._ocr_bar = None
        self._ocr_button = None

    def pack(self, **kwargs):
        self.packed = True
        return self

    def pack_forget(self):
        self.packed = False
        return self

    def configure(self, **kwargs):
        self.options.update(kwargs)
        return self

    def set(self, value):
        self.options["value"] = value
        return self

    def after(self, _ms, callback):
        # Run synchronously so assertions do not need a Tk event loop.
        callback()

    def title(self, *_a):
        return self

    def geometry(self, *_a):
        return self

    def minsize(self, *_a):
        return self

    def protocol(self, *_a):
        return self

    def transient(self, *_a):
        return self

    def deiconify(self):
        return self

    def lift(self):
        return self

    def focus_force(self):
        return self

    def destroy(self):
        self.options["destroyed"] = True
        return self


@pytest.fixture()
def tk(monkeypatch):
    """Stub customtkinter so the panel builds without a display."""
    for name in (
        "CTkToplevel",
        "CTkLabel",
        "CTkFrame",
        "CTkButton",
        "CTkProgressBar",
        "CTkScrollableFrame",
    ):
        monkeypatch.setattr(panel_mod.ctk, name, _FakeWidget, raising=False)
    # Window ownership belongs to dialog_utils (it has its own tests); the panel
    # only needs a widget to hand its children. Stubbing here keeps this file
    # about the job state machine.
    monkeypatch.setattr(
        panel_mod.dialog_utils,
        "make_toplevel",
        lambda _parent, _title: _FakeWidget(),
    )
    monkeypatch.setattr(
        panel_mod.dialog_utils,
        "show_toplevel",
        lambda dialog, _parent, modal=True: dialog.deiconify(),
    )
    return _FakeWidget


def _panel(tk, *, cancel=None):
    bus = EventBus()
    panel = OcrJobsPanel(object(), bus, cancel=cancel)
    return bus, panel


class TestJobRow:
    def test_a_queued_job_reads_sensibly(self):
        row = OcrJobRow(job_id="j", scope="canvas")
        assert "whole canvas" in row.summary()
        assert "Queued" in row.summary()

    def test_a_region_job_is_called_a_selection(self):
        assert "selection" in OcrJobRow(job_id="j", scope="region").summary()

    def test_progress_shows_the_percent(self):
        row = OcrJobRow(job_id="j", stage="RECOGNISING", percent=40)
        summary = row.summary()
        assert "Reading text" in summary
        assert "40%" in summary

    def test_a_finished_ok_job_names_the_provider(self):
        row = OcrJobRow(
            job_id="j",
            ok=True,
            provider="DmlExecutionProvider",
            finished_at=1.0,
            stage="DONE",
        )
        assert "done" in row.summary()
        assert "DmlExecutionProvider" in row.summary()

    def test_a_failed_job_shows_the_reason(self):
        row = OcrJobRow(job_id="j", ok=False, reason="engine missing", finished_at=1.0)
        assert "engine missing" in row.summary()

    def test_an_unknown_stage_is_still_readable(self):
        row = OcrJobRow(job_id="j", stage="SOMETHING_NEW")
        assert "Something_New" in row.summary()

    def test_is_finished_tracks_finished_at(self):
        assert OcrJobRow(job_id="j").is_finished is False
        assert OcrJobRow(job_id="j", finished_at=0.0).is_finished is True


class TestPanelStateMachine:
    def test_it_starts_with_no_jobs(self, tk):
        _, panel = _panel(tk)
        assert panel._rows == {}

    def test_started_adds_a_row(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas", canvas_id="c")
        assert "j-1" in panel._rows
        assert panel._rows["j-1"].scope == "canvas"

    def test_newest_job_is_first(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_STARTED, job_id="j-2", scope="region")
        assert panel._order[0] == "j-2"

    def test_progress_updates_the_existing_row(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_PROGRESS, job_id="j-1", stage="RECOGNISING", percent=55)
        row = panel._rows["j-1"]
        assert row.stage == "RECOGNISING"
        assert row.percent == 55

    def test_progress_is_monotonic(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_PROGRESS, job_id="j-1", stage="RECOGNISING", percent=60)
        # A stale, out-of-order update must not make the bar jump backwards.
        bus.emit(OCR_JOB_PROGRESS, job_id="j-1", stage="RASTERISING", percent=20)
        assert panel._rows["j-1"].percent == 60

    def test_progress_is_clamped(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_PROGRESS, job_id="j-1", stage="RECOGNISING", percent=140)
        assert panel._rows["j-1"].percent == 100.0

    def test_progress_for_an_unknown_job_is_adopted(self, tk):
        """A panel opened mid-job must not silently drop its updates."""
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_PROGRESS, job_id="late", stage="RECOGNISING", percent=30)
        assert panel._rows["late"].percent == 30

    def test_a_non_numeric_percent_is_ignored(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_PROGRESS, job_id="j-1", stage="RECOGNISING", percent="lots")
        assert panel._rows["j-1"].percent == 0.0

    def test_finished_ok_marks_done(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_FINISHED, job_id="j-1", ok=True, provider="DmlExecutionProvider")
        row = panel._rows["j-1"]
        assert row.is_finished is True
        assert row.ok is True
        assert row.percent == 100.0

    def test_finished_failure_keeps_the_error_stage(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_FINISHED, job_id="j-1", ok=False, reason="cancelled")
        row = panel._rows["j-1"]
        assert row.stage == "ERROR"
        assert row.reason == "cancelled"

    def test_a_start_with_no_job_id_is_ignored(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, scope="canvas")
        assert panel._rows == {}

    def test_two_jobs_both_tracked(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="a", scope="canvas")
        bus.emit(OCR_JOB_STARTED, job_id="b", scope="region")
        bus.emit(OCR_JOB_PROGRESS, job_id="a", stage="RECOGNISING", percent=50)
        bus.emit(OCR_JOB_PROGRESS, job_id="b", stage="RASTERISING", percent=20)
        assert panel._rows["a"].percent == 50
        assert panel._rows["b"].percent == 20


class TestCancelWiring:
    def test_cancel_calls_the_injected_callable(self, tk):
        seen: list[str] = []
        bus, panel = _panel(tk, cancel=seen.append)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        panel._request_cancel("j-1")
        assert seen == ["j-1"]

    def test_cancel_with_no_callable_is_harmless(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        panel._request_cancel("j-1")  # must not raise

    def test_a_raising_cancel_does_not_escape_into_tk(self, tk):
        def boom(_job_id):
            raise RuntimeError("nope")

        bus, panel = _panel(tk, cancel=boom)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        panel._request_cancel("j-1")  # must not raise

    def test_the_cancel_button_is_disabled_once_finished(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        bus.emit(OCR_JOB_FINISHED, job_id="j-1", ok=True)
        frame = panel._widgets["j-1"]
        assert frame._ocr_button.options.get("state") == "disabled"


class TestPruning:
    def test_old_finished_rows_are_dropped(self, tk, monkeypatch):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="old", scope="canvas")
        bus.emit(OCR_JOB_FINISHED, job_id="old", ok=True)
        panel._rows["old"].finished_at = 0.0
        monkeypatch.setattr(
            panel_mod.time, "monotonic", lambda: KEEP_FINISHED_SECONDS + 10
        )
        panel._prune()
        assert "old" not in panel._rows

    def test_a_recent_finished_row_is_kept(self, tk):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="new", scope="canvas")
        bus.emit(OCR_JOB_FINISHED, job_id="new", ok=True)
        panel._prune()
        assert "new" in panel._rows

    def test_the_finished_list_is_capped(self, tk):
        bus, panel = _panel(tk)
        for index in range(MAX_FINISHED_ROWS + 5):
            bus.emit(OCR_JOB_STARTED, job_id=f"j-{index}", scope="canvas")
            bus.emit(OCR_JOB_FINISHED, job_id=f"j-{index}", ok=True)
        panel._prune()
        finished = [j for j in panel._order if panel._rows[j].is_finished]
        assert len(finished) <= MAX_FINISHED_ROWS

    def test_running_jobs_are_never_pruned(self, tk, monkeypatch):
        bus, panel = _panel(tk)
        bus.emit(OCR_JOB_STARTED, job_id="live", scope="canvas")
        monkeypatch.setattr(
            panel_mod.time, "monotonic", lambda: KEEP_FINISHED_SECONDS + 10
        )
        panel._prune()
        assert "live" in panel._rows


class TestLifecycle:
    def test_close_unsubscribes_so_later_events_are_ignored(self, tk):
        bus, panel = _panel(tk)
        panel.close()
        bus.emit(OCR_JOB_STARTED, job_id="j-1", scope="canvas")
        assert panel._rows == {}

    def test_close_is_idempotent(self, tk):
        _, panel = _panel(tk)
        panel.close()
        panel.close()

    def test_close_invokes_its_callback_once(self, tk):
        calls: list[int] = []
        bus = EventBus()
        panel = OcrJobsPanel(object(), bus, on_close=lambda: calls.append(1))
        panel.close()
        panel.close()
        assert calls == [1]

    def test_exists_flips_after_close(self, tk):
        _, panel = _panel(tk)
        assert panel.exists() is True
        panel.close()
        assert panel.exists() is False

    def test_show_after_close_is_harmless(self, tk):
        _, panel = _panel(tk)
        panel.close()
        panel.show()  # must not raise

    def test_auto_show_does_not_raise(self, tk):
        OcrJobsPanel(object(), EventBus(), auto_show=True)
