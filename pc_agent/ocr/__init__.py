"""Round-12 issue 09 — OCR on the PC agent.

The tablet asks, the PC computes. This package owns three concerns:

* :mod:`ocr_engine`      — the recognition model (lazy, GPU-backed, releasable);
* :mod:`region_mask`     — turning a free-drawn polygon into a raster mask;
* :mod:`ocr_coordinator` — the job lifecycle (submit, progress, result, cancel).

Nothing here imports Flutter/GL code, so the whole package is importable and
testable without a window.
"""

from pc_agent.ocr.ocr_engine import (
    OcrEngine,
    OcrEngineError,
    OcrEngineUnavailable,
    OcrLine,
    OcrResult,
    get_engine,
    reset_engine_for_tests,
)

__all__ = [
    "OcrEngine",
    "OcrEngineError",
    "OcrEngineUnavailable",
    "OcrLine",
    "OcrResult",
    "get_engine",
    "reset_engine_for_tests",
]
