"""Round 12 — issue 07: unexpected failures must leave evidence behind.

The agent "crashed and closed" on a background-style canvas switch with no
traceback. Part of the fix is defensive GL state handling (see
``test_round12_background_switch.py``); the other part is that this class of
failure must never again be undiagnosable.

A native fault in the GL path is NOT catchable in Python, so the only thing that
can record it is ``faulthandler``, armed before the viewport exists. These tests
pin the logging contract.
"""

from __future__ import annotations

import sys
import threading
from pathlib import Path

import pytest

from pc_agent.core import crash_log


@pytest.fixture(autouse=True)
def _clean() -> None:
    """Never leak global hooks between tests."""
    crash_log.reset_for_tests()
    original_sys = sys.excepthook
    original_thread = threading.excepthook
    try:
        yield
    finally:
        crash_log.reset_for_tests()
        sys.excepthook = original_sys
        threading.excepthook = original_thread


def test_install_creates_the_log_and_returns_its_path(tmp_path: Path) -> None:
    path = crash_log.install(tmp_path)
    assert path == tmp_path / crash_log.CRASH_LOG_NAME
    assert path.exists()
    assert "session start" in path.read_text(encoding="utf-8")


def test_install_is_idempotent(tmp_path: Path) -> None:
    first = crash_log.install(tmp_path)
    text = first.read_text(encoding="utf-8")
    second = crash_log.install(tmp_path)
    assert first == second
    assert second.read_text(encoding="utf-8") == text, "no duplicate session banner"


def test_install_creates_missing_directories(tmp_path: Path) -> None:
    nested = tmp_path / "a" / "b" / "c"
    path = crash_log.install(nested)
    assert path.exists()


def test_an_uncaught_exception_is_recorded(tmp_path: Path) -> None:
    path = crash_log.install(tmp_path)
    try:
        raise ValueError("background switch exploded")
    except ValueError:
        exc_type, exc, tb = sys.exc_info()
        sys.excepthook(exc_type, exc, tb)  # type: ignore[arg-type]

    text = path.read_text(encoding="utf-8")
    assert "uncaught" in text
    assert "background switch exploded" in text
    assert "ValueError" in text
    assert "Traceback" in text


def test_keyboard_interrupt_is_not_treated_as_a_crash(tmp_path: Path) -> None:
    path = crash_log.install(tmp_path)
    try:
        raise KeyboardInterrupt
    except KeyboardInterrupt:
        exc_type, exc, tb = sys.exc_info()
        sys.excepthook(exc_type, exc, tb)  # type: ignore[arg-type]

    text = path.read_text(encoding="utf-8")
    assert "KeyboardInterrupt" not in text, "Ctrl+C on the console is not a crash"


def test_a_thread_failure_is_recorded(tmp_path: Path) -> None:
    path = crash_log.install(tmp_path)
    outcome: list[BaseException] = []

    def boom() -> None:
        raise RuntimeError("export worker died")

    def runner() -> None:
        try:
            boom()
        except RuntimeError as exc:
            outcome.append(exc)
            args = threading.ExceptHookArgs(
                (type(exc), exc, exc.__traceback__, threading.current_thread())
            )
            threading.excepthook(args)

    thread = threading.Thread(target=runner, name="worker-test")
    thread.start()
    thread.join()

    text = path.read_text(encoding="utf-8")
    assert "uncaught thread" in text
    assert "export worker died" in text
    assert "worker-test" in text


def test_system_exit_in_a_thread_is_ignored(tmp_path: Path) -> None:
    path = crash_log.install(tmp_path)
    args = threading.ExceptHookArgs(
        (SystemExit, SystemExit(0), None, threading.current_thread())
    )
    threading.excepthook(args)
    assert "SystemExit" not in path.read_text(encoding="utf-8")


def test_the_previous_excepthook_still_runs(tmp_path: Path) -> None:
    """Installation must chain, not swallow, the existing hook."""
    crash_log.install(tmp_path)
    seen: list[str] = []

    def previous(exc_type, exc, tb):  # noqa: ANN001, ANN202
        seen.append(getattr(exc_type, "__name__", "?"))

    # install() captured the hook that was current THEN; re-install to chain ours.
    crash_log.reset_for_tests()
    sys.excepthook = previous
    crash_log.install(tmp_path)
    try:
        raise LookupError("chained")
    except LookupError:
        exc_type, exc, tb = sys.exc_info()
        sys.excepthook(exc_type, exc, tb)  # type: ignore[arg-type]
    assert seen == ["LookupError"]


def test_a_huge_traceback_is_truncated(tmp_path: Path) -> None:
    """The cap must hold, or one bad crash could fill the disk."""
    path = crash_log.install(tmp_path)

    class _Tb:
        """Stands in for a traceback object: forces a very wide formatted text."""

    fake_tb = _Tb()
    original = crash_log.traceback.format_exception

    def wide(exc_type, exc, tb):  # noqa: ANN001, ANN202
        return ["y" * crash_log.MAX_TRACEBACK_CHARS for _ in range(4)]

    crash_log.traceback.format_exception = wide
    try:
        text = crash_log._format(RuntimeError, RuntimeError("wide"), fake_tb)
    finally:
        crash_log.traceback.format_exception = original

    assert text.endswith("... (truncated)\n")
    assert len(text) <= crash_log.MAX_TRACEBACK_CHARS + len("\n... (truncated)\n")
    crash_log._append(path, "uncaught", text)
    assert "(truncated)" in path.read_text(encoding="utf-8")


def test_the_log_is_rotated_when_it_grows_too_large(tmp_path: Path) -> None:
    path = tmp_path / crash_log.CRASH_LOG_NAME
    path.write_text("x" * (crash_log.MAX_BYTES + 10), encoding="utf-8")
    crash_log.install(tmp_path)
    text = path.read_text(encoding="utf-8")
    assert "rotated at" in text
    assert len(text) < crash_log.MAX_BYTES


def test_log_render_failure_records_the_origin(tmp_path: Path) -> None:
    crash_log.install(tmp_path)
    try:
        raise OSError("draw failed")
    except OSError as exc:
        crash_log.log_render_failure(exc, "PrimitiveRenderer.render", tmp_path)

    text = (tmp_path / crash_log.CRASH_LOG_NAME).read_text(encoding="utf-8")
    assert "render failure in PrimitiveRenderer.render" in text
    assert "draw failed" in text


def test_log_render_failure_without_a_dir_is_a_no_op() -> None:
    crash_log.log_render_failure(RuntimeError("x"), "somewhere", None)  # must not raise


def test_install_never_raises_on_an_unwritable_dir() -> None:
    """A diagnostics failure must not stop the agent from starting."""
    # A path that cannot be created as a directory on Windows.
    bad = Path("NUL") / "nested"
    path = crash_log.install(bad)  # must not raise
    assert path.name == crash_log.CRASH_LOG_NAME
