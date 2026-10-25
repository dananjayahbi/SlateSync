"""Round-12 issue 07 — persist unexpected failures instead of letting them vanish.

The user's report was "the PC agent crashes and closes" when switching to a
canvas with a different background. Diagnosing it was hard for a structural
reason: a *native* fault in the GL path is not catchable in Python, so the
process simply exits — no traceback, no log line, nothing to hand back.

The Python-level render guards (``GLCanvasHost._tick`` / ``._render``) already
absorb ordinary exceptions. What was missing was a last-resort hook for the
exceptions that escape them and for interpreter-level failures:

* ``sys.excepthook`` — an uncaught exception on the main thread;
* ``threading.excepthook`` — an uncaught exception on a worker;
* ``faulthandler`` — a hard native crash, which writes the C-level stack.

Everything is appended to ``<appdata>/crash.log``, so a user can send the file
and the failure is diagnosable without reproducing it.

This module is deliberately dependency-free and safe to install before any
other subsystem: it must never be the reason startup fails.
"""

from __future__ import annotations

import faulthandler
import logging
import sys
import threading
import traceback
from datetime import UTC, datetime
from pathlib import Path
from typing import IO, Any

logger = logging.getLogger(__name__)

#: File name inside the app data directory.
CRASH_LOG_NAME = "crash.log"
#: Rotate (truncate) once the file grows past this size, so a crash loop cannot
#: fill the disk.
MAX_BYTES = 1_000_000
#: Cap on the traceback text written for a single failure.
MAX_TRACEBACK_CHARS = 32_000

_fault_file: IO[str] | None = None
_installed = False


def _rotate(path: Path) -> None:
    try:
        if path.exists() and path.stat().st_size > MAX_BYTES:
            path.write_text(
                f"# rotated at {datetime.now(UTC).isoformat()}\n",
                encoding="utf-8",
            )
    except OSError:  # pragma: no cover - defensive
        pass


def _append(path: Path, kind: str, text: str) -> None:
    """Append one entry; never raise (a crash handler must not crash)."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _rotate(path)
        stamp = datetime.now(UTC).isoformat(timespec="seconds")
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"\n=== {stamp} {kind} ===\n{text}\n")
    except Exception:  # pragma: no cover - defensive
        logger.exception("could not append to the crash log")


def _format(exc_type: type[BaseException], exc: BaseException, tb: Any) -> str:
    body = "".join(traceback.format_exception(exc_type, exc, tb))
    if len(body) > MAX_TRACEBACK_CHARS:
        body = body[:MAX_TRACEBACK_CHARS] + "\n... (truncated)\n"
    return body


def install(appdata_dir: Path | str) -> Path:
    """Install every last-resort handler; returns the log path.

    Idempotent: calling it twice does not stack hooks or reopen the file.
    """
    global _fault_file, _installed

    path = Path(appdata_dir) / CRASH_LOG_NAME
    if _installed:
        return path

    _append(path, "session start", f"python {sys.version}")

    previous_hook = sys.excepthook

    def _hook(
        exc_type: type[BaseException], exc: BaseException, tb: Any
    ) -> None:
        if not issubclass(exc_type, KeyboardInterrupt):
            _append(path, "uncaught", _format(exc_type, exc, tb))
        previous_hook(exc_type, exc, tb)

    sys.excepthook = _hook

    def _thread_hook(args: threading.ExceptHookArgs) -> None:
        if args.exc_type is SystemExit:
            return
        exc = args.exc_value or RuntimeError("unknown thread failure")
        _append(
            path,
            f"uncaught thread {getattr(args.thread, 'name', '?')}",
            _format(args.exc_type, exc, args.exc_traceback),
        )

    threading.excepthook = _thread_hook

    # A native fault (what actually killed the agent) leaves a C stack here.
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _fault_file = path.open("a", encoding="utf-8")
        faulthandler.enable(file=_fault_file, all_threads=True)
    except Exception:  # pragma: no cover - defensive
        logger.exception("faulthandler could not be enabled")

    _installed = True
    logger.info("crash logging enabled at %s", path)
    return path


def log_render_failure(exc: BaseException, where: str, appdata_dir: Path | None = None) -> None:
    """Record a swallowed render exception with its origin.

    The render guards already log via ``logger.exception``; this also persists
    the failure so a field report carries evidence even when the user cannot
    reach the log console.
    """
    if appdata_dir is None:
        return
    _append(
        Path(appdata_dir) / CRASH_LOG_NAME,
        f"render failure in {where}",
        _format(type(exc), exc, exc.__traceback__),
    )


def reset_for_tests() -> None:
    """Detach the hooks (tests only, so a suite does not leak global state)."""
    global _fault_file, _installed
    try:
        faulthandler.disable()
    except Exception:  # pragma: no cover - defensive
        pass
    if _fault_file is not None:
        try:
            _fault_file.close()
        except Exception:  # pragma: no cover - defensive
            pass
    _fault_file = None
    _installed = False
