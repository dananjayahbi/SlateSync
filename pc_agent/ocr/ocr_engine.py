"""PP-OCRv6 recognition, GPU-backed through ONNX Runtime DirectML.

Design constraints this module exists to satisfy:

* **Lazy** — importing the app must never load a model. A machine with no GPU,
  or with `onnxruntime` missing entirely, still starts and still mirrors
  canvases; only an actual OCR request fails, and it fails loudly.
* **GPU, but provably** — ONNX Runtime silently demotes an unavailable provider
  to CPU. A silent demotion would look like "it works, just slow", so the active
  provider list is read back and recorded rather than trusted.
* **Releasable** — VRAM is only held while the engine is live, so a 6 GB card is
  not permanently occupied by an idle app.

See `docs/round12_plan.md` §09 for the measurements behind the model choice
(PP-OCRv6 `small` / `en` beat `medium` on handwriting *and* on speed).
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Optional

logger = logging.getLogger(__name__)

#: How long an unused engine is kept warm before its VRAM is handed back.
IDLE_RELEASE_SECONDS = 180.0

#: Confidence below which a recognised line is treated as noise. The engine's
#: own default is 0.5; handwriting sits higher than that when it is real ink.
MIN_SCORE = 0.5


class OcrEngineError(RuntimeError):
    """A recognition run failed for a reason the user can act on."""


class OcrEngineUnavailable(OcrEngineError):
    """The OCR stack is not installed / usable on this machine."""


@dataclass(frozen=True)
class OcrLine:
    """One recognised line of text with its box in the raster's pixel space."""

    text: str
    score: float
    #: `(x0, y0, x1, y1)` — axis-aligned bounds of the rotated quad, in pixels.
    box: tuple[float, float, float, float]

    def to_wire(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "score": round(float(self.score), 4),
            "box": [round(float(v), 2) for v in self.box],
        }


@dataclass
class OcrResult:
    """Everything the tablet needs to build a text box from a scan."""

    lines: list[OcrLine] = field(default_factory=list)
    #: Provider ONNX Runtime actually used — `DmlExecutionProvider` when the GPU
    #: was engaged; never assumed.
    provider: str = "unknown"
    #: Raster size the boxes refer to, so the tablet can scale back to world units.
    width: int = 0
    height: int = 0
    elapsed_ms: int = 0

    @property
    def text(self) -> str:
        """Lines joined for a plain text box (reading order, top to bottom)."""
        return "\n".join(line.text for line in self.lines)

    @property
    def is_empty(self) -> bool:
        return not any(line.text.strip() for line in self.lines)

    def to_wire(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "provider": self.provider,
            "width": self.width,
            "height": self.height,
            "elapsed_ms": self.elapsed_ms,
            "lines": [line.to_wire() for line in self.lines],
        }


def _build_params(use_gpu: bool) -> dict[str, Any]:
    """RapidOCR params. Built lazily because the enums come from `rapidocr`.

    Kept separate so tests can assert the shape without importing the model.
    """
    from rapidocr import LangDet, LangRec, ModelType, OCRVersion

    params: dict[str, Any] = {
        "Global.log_level": "error",
        # PP-OCRv6 small/en: measured best on handwriting AND fastest.
        "Det.ocr_version": OCRVersion.PPOCRV6,
        "Rec.ocr_version": OCRVersion.PPOCRV6,
        "Det.model_type": ModelType.SMALL,
        "Rec.model_type": ModelType.SMALL,
        "Det.lang_type": LangDet.EN,
        "Rec.lang_type": LangRec.EN,
        "Global.text_score": MIN_SCORE,
    }
    if use_gpu:
        params["EngineConfig.onnxruntime.use_dml"] = True
    return params


class OcrEngine:
    """Owns the RapidOCR instance and the GPU session behind it.

    Thread-safe: :meth:`recognize` serialises on one lock, because a single
    RapidOCR instance is not reentrant and running two scans at once would
    interleave their buffers rather than go faster.
    """

    def __init__(self, *, prefer_gpu: bool = True) -> None:
        self._lock = threading.Lock()
        self._prefer_gpu = prefer_gpu
        self._engine: Any = None
        self._provider: str = "not-loaded"
        self._last_used: float = 0.0

    # -- lifecycle ---------------------------------------------------------

    @property
    def provider(self) -> str:
        return self._provider

    @property
    def is_loaded(self) -> bool:
        return self._engine is not None

    def _load(self) -> Any:
        """Create the engine if needed. Raises :class:`OcrEngineUnavailable`."""
        if self._engine is not None:
            return self._engine

        try:
            import onnxruntime  # noqa: F401  (proves the runtime is present)
            from rapidocr import RapidOCR
        except Exception as exc:  # pragma: no cover - environment dependent
            raise OcrEngineUnavailable(
                "OCR is not available: the onnxruntime/rapidocr packages are "
                f"missing ({exc}). Reinstall the SlateSync agent."
            ) from exc

        attempts = [True, False] if self._prefer_gpu else [False]
        last_error: Optional[Exception] = None
        for use_gpu in attempts:
            try:
                engine = RapidOCR(params=_build_params(use_gpu))
            except Exception as exc:  # pragma: no cover - environment dependent
                last_error = exc
                logger.warning("OCR init failed (gpu=%s): %s", use_gpu, exc)
                continue

            provider = self._active_provider(engine, use_gpu)
            if use_gpu and provider != "DmlExecutionProvider":
                # Requested the GPU and did not get it: rather than silently
                # run 10x slower, report it and let the CPU attempt stand in.
                logger.warning(
                    "OCR GPU provider unavailable (got %s); continuing on CPU",
                    provider,
                )
            self._engine = engine
            self._provider = provider
            self._last_used = time.monotonic()
            logger.info("OCR engine ready on %s", provider)
            return engine

        raise OcrEngineUnavailable(
            f"OCR engine could not start: {last_error}"
        ) from last_error

    @staticmethod
    def _active_provider(engine: Any, use_gpu: bool) -> str:
        """Read back the provider ONNX Runtime *actually* bound.

        RapidOCR nests its sessions behind det/cls/rec objects that differ
        between versions, so probe generically and fall back to the requested
        provider name when nothing is introspectable.
        """
        wanted = "DmlExecutionProvider" if use_gpu else "CPUExecutionProvider"
        try:
            for attr in ("session", "_session", "ort_session"):
                sess = getattr(engine, attr, None)
                if sess is not None and hasattr(sess, "get_providers"):
                    provs = sess.get_providers()
                    if provs:
                        return provs[0]
        except Exception:  # pragma: no cover - defensive
            pass
        return wanted

    def release(self) -> None:
        """Drop the model and hand VRAM back to the system."""
        with self._lock:
            self._engine = None
            self._provider = "released"

    def release_if_idle(self, *, now: Optional[float] = None) -> bool:
        """Release the engine when it has not been used for a while."""
        if self._engine is None:
            return False
        now = time.monotonic() if now is None else now
        if now - self._last_used < IDLE_RELEASE_SECONDS:
            return False
        logger.info("OCR engine idle — releasing GPU memory")
        self.release()
        return True

    # -- recognition -------------------------------------------------------

    def recognize(
        self,
        image: Any,
        *,
        offset: tuple[float, float] = (0.0, 0.0),
    ) -> OcrResult:
        """Recognise text in a PIL image (or numpy array).

        [offset] is added to every box so callers that cropped a region can get
        boxes back in the *original* raster's coordinates.
        """
        from PIL import Image

        started = time.monotonic()
        with self._lock:
            engine = self._load()
            self._last_used = time.monotonic()
            if not isinstance(image, Image.Image):
                image = Image.fromarray(image)
            if image.mode not in ("RGB", "L"):
                image = image.convert("RGB")

            try:
                raw = engine(image)
            except Exception as exc:
                raise OcrEngineError(f"OCR failed: {exc}") from exc

            width, height = image.size
            lines = self._to_lines(raw, offset)
            provider = self._provider
            self._last_used = time.monotonic()

        return OcrResult(
            lines=lines,
            provider=provider,
            width=width,
            height=height,
            elapsed_ms=int((time.monotonic() - started) * 1000),
        )

    @staticmethod
    def _to_lines(raw: Any, offset: tuple[float, float]) -> list[OcrLine]:
        """Normalise RapidOCR's result into :class:`OcrLine`s, in reading order."""
        if raw is None:
            return []
        txts = getattr(raw, "txts", None)
        if not txts:
            return []
        scores = getattr(raw, "scores", None) or [1.0] * len(txts)
        boxes = getattr(raw, "boxes", None)

        dx, dy = offset
        lines: list[OcrLine] = []
        for index, text in enumerate(txts):
            text = (text or "").strip()
            if not text:
                continue
            try:
                score = float(scores[index])
            except (IndexError, TypeError, ValueError):
                score = 1.0
            if score < MIN_SCORE:
                continue
            box = _quad_to_box(boxes, index) if boxes is not None else None
            if box is None:
                # No geometry: stack lines so callers still get a sane layout.
                box = (0.0, float(index) * 24.0, 0.0, float(index) * 24.0 + 20.0)
            lines.append(
                OcrLine(
                    text=text,
                    score=score,
                    box=(box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy),
                )
            )

        # Reading order: top to bottom, then left to right for shared rows.
        lines.sort(key=lambda ln: (round(ln.box[1] / 12.0), ln.box[0]))
        return lines


def _quad_to_box(boxes: Any, index: int) -> Optional[tuple[float, float, float, float]]:
    """Bounding box of a rotated quad, tolerating int/float/nested shapes."""
    try:
        quad = boxes[index]
    except (IndexError, TypeError):
        return None
    try:
        xs = [float(point[0]) for point in quad]
        ys = [float(point[1]) for point in quad]
    except (TypeError, ValueError, IndexError):
        return None
    if not xs or not ys:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


_ENGINE: Optional[OcrEngine] = None
_ENGINE_LOCK = threading.Lock()


def get_engine() -> OcrEngine:
    """Process-wide engine (lazy; created on first call)."""
    global _ENGINE
    with _ENGINE_LOCK:
        if _ENGINE is None:
            _ENGINE = OcrEngine()
        return _ENGINE


def reset_engine_for_tests() -> None:
    """Drop the singleton — tests only."""
    global _ENGINE
    with _ENGINE_LOCK:
        if _ENGINE is not None:
            _ENGINE.release()
        _ENGINE = None
