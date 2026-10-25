"""Round 12 — issue 10: PC popups must open ABOVE the studio window.

Report: "in the PC agent, when we open its popups, it initially displays them
behind the main window."

Cause: a ``CTkToplevel`` created with only a parent path is NOT owned by that
parent as far as the window manager is concerned. Ownership is expressed by
``transient()``, and stacking is only guaranteed once the dialog is raised and
given focus. Several dialogs were created bare; nothing called ``grab_set``.

``pc_agent/gui/dialog_utils.py`` is now the single place that presents a popup,
so a new dialog cannot reintroduce the defect. These tests use fake Tk objects to
pin the CONTRACT (own → modal → raise) without needing a display.
"""

from __future__ import annotations

from typing import Any

import pytest

from pc_agent.gui import dialog_utils


class _FakeWidget:
    """Records the window-manager calls a dialog must receive."""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.after_jobs: list[tuple[int, Any]] = []

    # -- ownership / stacking ------------------------------------------------
    def transient(self, parent: Any) -> None:
        self.calls.append("transient")

    def grab_set(self) -> None:
        self.calls.append("grab_set")

    def grab_release(self) -> None:
        self.calls.append("grab_release")

    def lift(self) -> None:
        self.calls.append("lift")

    def focus_force(self) -> None:
        self.calls.append("focus_force")

    def deiconify(self) -> None:
        self.calls.append("deiconify")

    def withdraw(self) -> None:
        self.calls.append("withdraw")

    def after(self, ms: int, callback: Any = None) -> str:
        self.after_jobs.append((ms, callback))
        return f"after#{len(self.after_jobs)}"

    # -- geometry ------------------------------------------------------------
    def update_idletasks(self) -> None:
        return None

    def geometry(self, spec: str) -> None:
        self.calls.append(f"geometry:{spec}")

    def winfo_width(self) -> int:
        return 800

    def winfo_height(self) -> int:
        return 600

    def winfo_rootx(self) -> int:
        return 100

    def winfo_rooty(self) -> int:
        return 50

    def winfo_reqwidth(self) -> int:
        return 400

    def winfo_reqheight(self) -> int:
        return 300

    def winfo_class(self) -> str:
        return "Toplevel"

    def run_scheduled(self) -> None:
        """Fire the deferred raise, as Tk would on the next idle turn."""
        for _ms, callback in self.after_jobs:
            if callable(callback):
                callback()


@pytest.fixture()
def parent() -> _FakeWidget:
    return _FakeWidget()


# ---------------------------------------------------------------------------
# prepare_dialog: own it, make it modal, raise it
# ---------------------------------------------------------------------------
def test_prepare_dialog_makes_it_transient_first(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.prepare_dialog(dialog, parent)
    assert dialog.calls[0] == "transient", (
        "transient() is what tells the WM the dialog belongs to the parent — "
        "without it the popup can open behind the main window"
    )


def test_prepare_dialog_is_modal_by_default(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.prepare_dialog(dialog, parent)
    assert "grab_set" in dialog.calls


def test_prepare_dialog_can_be_non_modal(parent: _FakeWidget) -> None:
    """The QR dialog must NOT grab: the user needs the main window while scanning."""
    dialog = _FakeWidget()
    dialog_utils.prepare_dialog(dialog, parent, modal=False)
    assert "grab_set" not in dialog.calls


def test_prepare_dialog_raises_and_focuses(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.prepare_dialog(dialog, parent)
    assert "lift" in dialog.calls
    assert "focus_force" in dialog.calls


def test_the_raise_is_repeated_after_mapping(parent: _FakeWidget) -> None:
    """Windows can ignore a lift() issued before the window is mapped."""
    dialog = _FakeWidget()
    dialog_utils.prepare_dialog(dialog, parent)
    assert dialog.after_jobs, "a deferred raise must be scheduled"
    before = dialog.calls.count("lift")
    dialog.run_scheduled()
    assert dialog.calls.count("lift") > before


def test_present_dialog_centres_over_the_parent(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.present_dialog(dialog, parent)
    geometry = [c for c in dialog.calls if c.startswith("geometry:")]
    assert geometry, "the dialog should be placed over the parent"
    # 800x600 parent at (100,50) with a 400x300 dialog → x=300, y=150.
    assert geometry[0] == "geometry:+300+150"


def test_present_dialog_can_skip_centring(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.present_dialog(dialog, parent, center=False)
    assert not [c for c in dialog.calls if c.startswith("geometry:")]


def test_a_not_yet_laid_out_parent_is_not_centred(parent: _FakeWidget) -> None:
    """A 1x1 parent means Tk has not mapped it yet; centring would be nonsense."""
    parent.winfo_width = lambda: 1  # type: ignore[method-assign]
    parent.winfo_height = lambda: 1  # type: ignore[method-assign]
    dialog = _FakeWidget()
    dialog_utils.center_on_parent(dialog, parent)
    assert not [c for c in dialog.calls if c.startswith("geometry:")]


def test_a_broken_centre_does_not_raise(parent: _FakeWidget) -> None:
    def boom(*_a: Any, **_k: Any) -> None:
        raise RuntimeError("no display")

    parent.geometry = boom  # type: ignore[method-assign]
    dialog = _FakeWidget()
    dialog_utils.center_on_parent(dialog, parent)  # must not raise


# ---------------------------------------------------------------------------
# Ordering: ownership before modality before the raise
# ---------------------------------------------------------------------------
def test_calls_happen_in_a_sane_order(parent: _FakeWidget) -> None:
    dialog = _FakeWidget()
    dialog_utils.present_dialog(dialog, parent)
    ordered = [c for c in dialog.calls if c in ("transient", "grab_set", "lift")]
    assert ordered.index("transient") < ordered.index("grab_set")
    assert ordered.index("transient") < ordered.index("lift")


# ---------------------------------------------------------------------------
# Robustness: a dialog helper must never take the app down
# ---------------------------------------------------------------------------
def test_prepare_dialog_survives_a_widget_that_rejects_everything() -> None:
    class _Hostile:
        def transient(self, _p: Any) -> None:
            raise RuntimeError("nope")

        def grab_set(self) -> None:
            raise RuntimeError("nope")

        def lift(self) -> None:
            raise RuntimeError("nope")

        def focus_force(self) -> None:
            raise RuntimeError("nope")

        def after(self, _ms: int, _cb: Any = None) -> str:
            raise RuntimeError("nope")

    dialog_utils.prepare_dialog(_Hostile(), _FakeWidget())  # must not raise


def test_release_dialog_swallows_errors() -> None:
    class _Hostile:
        def grab_release(self) -> None:
            raise RuntimeError("nope")

    dialog_utils.release_dialog(_Hostile())  # must not raise


def test_messagebox_parent_returns_a_keyword_only_when_needed() -> None:
    parent = _FakeWidget()
    assert dialog_utils.messagebox_parent(parent) == {"parent": parent}
    assert dialog_utils.messagebox_parent(None) == {}


def test_every_toplevel_call_site_presents_the_dialog() -> None:
    """The regression guard: a new popup must not re-introduce the bug.

    Every GUI module that creates a ``CTkToplevel`` must also present it through
    ``dialog_utils`` — that is what applies transient/grab/raise. This is a
    source-level check because the real defect was a missing call, not a wrong
    one.
    """
    from pathlib import Path

    gui = Path(__file__).resolve().parents[1] / "gui"
    offenders: list[str] = []
    for path in sorted(gui.glob("*.py")):
        if path.name == "dialog_utils.py":
            continue  # the helper itself is allowed to construct one
        source = path.read_text(encoding="utf-8")
        if "CTkToplevel(" not in source:
            continue
        if "dialog_utils" not in source:
            offenders.append(path.name)
    assert not offenders, (
        "these modules create a Toplevel without presenting it via "
        f"dialog_utils (popups can open behind the main window): {offenders}"
    )
