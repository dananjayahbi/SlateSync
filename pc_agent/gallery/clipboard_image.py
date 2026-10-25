"""Windows clipboard image I/O for the PC gallery (Doc 02 §13.1).

**Why this module exists at all.** An image on the Windows clipboard is
``CF_DIB`` — a ``BITMAPINFOHEADER`` followed by raw, bottom-up device-independent
pixels — and *not* encoded PNG bytes. Writing PNG bytes under a DIB format id
produces an entry Windows will accept but no application can paste: Paint,
Word, Slack and every browser ask for ``CF_DIB`` and decode the header. That is
the single reason "copy to clipboard" did not work before, so the encoder lives
here rather than inline in the window.

Two implementation choices:

* **ctypes only** — ``user32``/``kernel32`` through :mod:`ctypes` needs no new
  dependency and works in the frozen PyInstaller build. ``pywin32`` is tried as a
  fallback when it happens to be installed, but is never required.
* **alpha is forced opaque.** Many applications treat a 32-bpp ``CF_DIB`` as
  premultiplied and render a zero alpha channel as fully transparent, so a
  pasted screenshot would arrive blank. The image's own alpha is dropped on the
  DIB path; keeping it would be worse than losing it.

The pure encoding functions (:func:`dib_header`, :func:`dib_pixels`,
:func:`dib_from_image`, :func:`dib_to_image`) are separated from the clipboard
calls so the header layout can be tested without touching the real clipboard —
tests that grab the system clipboard interfere with the developer's own machine.
"""

from __future__ import annotations

import ctypes
import io
import logging
import struct
import sys
from typing import Any

from PIL import Image

logger = logging.getLogger("slatesync.gallery.clipboard")

#: ``CF_DIB`` — the format every Windows application understands.
CF_DIB = 8
#: ``CF_DIBV5`` — contains colour-space info; read as a fallback when present.
CF_DIBV5 = 17

#: ``BITMAPINFOHEADER`` (``biSize``) — the smallest header every consumer reads.
BITMAPINFOHEADER_SIZE = 40
#: ``BI_RGB``: uncompressed, which is what ``CF_DIB`` publishers must use for
#: 32-bpp data (``BI_BITFIELDS`` would add three masks and break simple readers).
BI_RGB = 0
#: Horizontal/vertical resolution in pixels per metre for 96 DPI. Cosmetic, but a
#: zero makes some viewers report a nonsense print size.
PELS_PER_METRE = 3780

GMEM_MOVEABLE = 0x0002


class ClipboardError(RuntimeError):
    """Any clipboard operation that could not complete (never fatal)."""


def dib_header(
    width: int,
    height: int,
    *,
    bpp: int = 32,
    size_image: int | None = None,
) -> bytes:
    """Build the 40-byte ``BITMAPINFOHEADER`` for a bottom-up 32-bpp DIB.

    ``biHeight`` is deliberately POSITIVE: positive means "rows are stored bottom
    to top", which is the convention ``CF_DIB`` consumers assume. A negative
    height (top-down) is legal for BMP files but is mishandled by several
    clipboard readers, so the pixel encoder flips the rows instead.
    """
    if width < 1 or height < 1:
        raise ValueError(f"DIB needs a positive size, got {width}x{height}")
    if bpp not in (24, 32):
        raise ValueError(f"unsupported DIB depth {bpp!r}; expected 24 or 32")
    row_bytes = ((width * bpp + 31) // 32) * 4  # rows are DWORD-aligned
    pixel_bytes = row_bytes * height if size_image is None else int(size_image)
    return struct.pack(
        "<IiiHHIIiiII",
        BITMAPINFOHEADER_SIZE,
        int(width),
        int(height),  # positive ⇒ bottom-up (see docstring)
        1,  # biPlanes — always 1
        bpp,
        BI_RGB,
        pixel_bytes,
        PELS_PER_METRE,
        PELS_PER_METRE,
        0,  # biClrUsed — no palette at this depth
        0,  # biClrImportant — all colours significant
    )


def header_fields(header: bytes) -> dict[str, int]:
    """Decode a ``BITMAPINFOHEADER`` into named fields (tests + diagnostics)."""
    if len(header) < BITMAPINFOHEADER_SIZE:
        raise ValueError(f"header must be {BITMAPINFOHEADER_SIZE} bytes, got {len(header)}")
    (
        bi_size,
        width,
        height,
        planes,
        bpp,
        compression,
        size_image,
        x_ppm,
        y_ppm,
        clr_used,
        clr_important,
    ) = struct.unpack_from("<IiiHHIIiiII", header, 0)
    return {
        "biSize": bi_size,
        "biWidth": width,
        "biHeight": height,
        "biPlanes": planes,
        "biBitCount": bpp,
        "biCompression": compression,
        "biSizeImage": size_image,
        "biXPelsPerMeter": x_ppm,
        "biYPelsPerMeter": y_ppm,
        "biClrUsed": clr_used,
        "biClrImportant": clr_important,
    }


def dib_pixels(image: Image.Image, *, bpp: int = 32) -> bytes:
    """Pixel payload: BGRA (or BGR), bottom-up, alpha forced opaque.

    The channel order comes from PIL's ``raw`` encoder (``"BGRA"``) rather than a
    ``merge()``: PIL has no BGRA image mode, so merging channels cannot express a
    byte order — only the raw encoder can.
    """
    rgba = image.convert("RGBA")
    width, height = rgba.size
    rgb = rgba.convert("RGB")  # the image's own alpha is dropped (module docstring)
    opaque = Image.merge("RGBA", (*rgb.split(), Image.new("L", (width, height), 255)))
    flipped = opaque.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
    if bpp == 24:
        # 24-bpp DIB pixels are BGR too, so "RGB" here would swap the channels and
        # every pasted 24-bpp image would come out blue-tinted.
        return flipped.tobytes("raw", "BGR")
    return flipped.tobytes("raw", "BGRA")


def dib_from_image(image: Image.Image, *, bpp: int = 32) -> bytes:
    """Complete ``CF_DIB`` blob (header + pixels) for ``image``."""
    if image.size[0] < 1 or image.size[1] < 1:
        raise ValueError("cannot copy an empty image to the clipboard")
    pixels = dib_pixels(image, bpp=bpp)
    return dib_header(image.size[0], image.size[1], bpp=bpp, size_image=len(pixels)) + pixels


def dib_to_image(raw: bytes) -> Image.Image:
    """Decode a ``CF_DIB`` blob back into a PIL image.

    The blob lacks the ``BITMAPFILEHEADER`` PIL's BMP reader expects, so a
    synthetic file header is prepended — far more robust than reimplementing the
    BMP row/palette/compression rules for the dozen layouts a clipboard may hold.
    """
    if len(raw) < BITMAPINFOHEADER_SIZE:
        raise ValueError("clipboard data is too short to be a DIB")
    fields = header_fields(raw)
    bi_size = fields["biSize"]
    if bi_size < BITMAPINFOHEADER_SIZE:
        raise ValueError(f"unsupported DIB header size {bi_size}")
    bpp = fields["biBitCount"]
    palette_entries = fields["biClrUsed"] or (2**bpp if bpp <= 8 else 0)
    pixel_offset = 14 + bi_size + palette_entries * 4
    file_header = b"BM" + struct.pack("<IHHI", 14 + len(raw), 0, 0, pixel_offset)
    with Image.open(io.BytesIO(file_header + raw)) as image:
        image.load()
        return image.copy()


# ---------------------------------------------------------------------------
# Win32 clipboard plumbing (guarded: a clipboard failure must never crash)
# ---------------------------------------------------------------------------


def _windll() -> tuple[Any, Any] | None:
    """``(user32, kernel32)``, or ``None`` off Windows / with no ctypes windll."""
    if sys.platform != "win32":  # pragma: no cover - exercised on Windows only
        return None
    try:
        windll: Any = ctypes.windll  # type: ignore[attr-defined]
        user32 = windll.user32
        kernel32 = windll.kernel32
    except Exception:  # pragma: no cover - defensive
        logger.debug("windll unavailable", exc_info=True)
        return None
    # Explicit prototypes: the default c_int return would truncate 64-bit
    # handles to 32 bits and silently corrupt every GlobalAlloc/GetClipboardData.
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalAlloc.argtypes = (ctypes.c_uint, ctypes.c_size_t)
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = (ctypes.c_void_p,)
    kernel32.GlobalUnlock.argtypes = (ctypes.c_void_p,)
    kernel32.GlobalUnlock.restype = ctypes.c_int
    kernel32.GlobalFree.argtypes = (ctypes.c_void_p,)
    kernel32.GlobalFree.restype = ctypes.c_void_p
    kernel32.GlobalSize.argtypes = (ctypes.c_void_p,)
    kernel32.GlobalSize.restype = ctypes.c_size_t
    user32.OpenClipboard.argtypes = (ctypes.c_void_p,)
    user32.OpenClipboard.restype = ctypes.c_int
    user32.EmptyClipboard.restype = ctypes.c_int
    user32.CloseClipboard.restype = ctypes.c_int
    user32.SetClipboardData.argtypes = (ctypes.c_uint, ctypes.c_void_p)
    user32.SetClipboardData.restype = ctypes.c_void_p
    user32.GetClipboardData.argtypes = (ctypes.c_uint,)
    user32.GetClipboardData.restype = ctypes.c_void_p
    return user32, kernel32


def _copy_via_ctypes(blob: bytes, user32: Any, kernel32: Any) -> None:
    """Publish ``blob`` as ``CF_DIB``; raises :class:`ClipboardError`."""
    if not user32.OpenClipboard(None):
        raise ClipboardError("another application is holding the clipboard")
    try:
        if not user32.EmptyClipboard():
            raise ClipboardError("could not empty the clipboard")
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(blob))
        if not handle:
            raise ClipboardError("could not allocate clipboard memory")
        pointer = kernel32.GlobalLock(handle)
        if not pointer:
            kernel32.GlobalFree(handle)
            raise ClipboardError("could not lock clipboard memory")
        try:
            ctypes.memmove(pointer, blob, len(blob))
        finally:
            kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(CF_DIB, handle):
            # Ownership never transferred, so this handle is still ours to free.
            kernel32.GlobalFree(handle)
            raise ClipboardError("could not set the clipboard data")
        # On success the clipboard owns the handle: freeing it would blank the
        # data every other application is about to read.
    finally:
        user32.CloseClipboard()


def _copy_via_pywin32(blob: bytes) -> None:  # pragma: no cover - optional path
    """Fallback publisher for installs that happen to ship ``pywin32``."""
    import win32clipboard  # noqa: PLC0415 - optional dependency, imported lazily
    import win32con

    win32clipboard.OpenClipboard()
    try:
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardData(win32con.CF_DIB, blob)
    finally:
        win32clipboard.CloseClipboard()


def copy_image_to_clipboard(image: Image.Image) -> None:
    """Put ``image`` on the clipboard as ``CF_DIB``; raises :class:`ClipboardError`.

    Raises rather than logging so the window can tell the user *why* the copy did
    nothing; the caller is responsible for showing that message and carrying on.
    """
    try:
        blob = dib_from_image(image)
    except (ValueError, OSError) as exc:
        raise ClipboardError(f"could not encode the image: {exc}") from exc
    handles = _windll()
    if handles is None:
        # Off Windows (or with no ctypes) there is no clipboard to write; the
        # optional dependency is the only remaining route.
        try:
            _copy_via_pywin32(blob)
            return
        except Exception as exc:  # pragma: no cover - exercised on Windows only
            raise ClipboardError("the clipboard is unavailable on this platform") from exc
    user32, kernel32 = handles
    try:
        _copy_via_ctypes(blob, user32, kernel32)
        return
    except ClipboardError:
        raise
    except Exception as exc:  # pragma: no cover - defensive
        logger.debug("ctypes clipboard write failed", exc_info=True)
        last_error = exc
    try:  # pragma: no cover - optional path
        _copy_via_pywin32(blob)
    except Exception as exc:
        raise ClipboardError(f"could not write the clipboard: {last_error or exc}") from exc


def image_from_clipboard() -> Image.Image | None:
    """Read a ``CF_DIB``/``CF_DIBV5`` image from the clipboard.

    Returns ``None`` when the clipboard holds no bitmap (normal: the user may have
    copied text) or when Windows refuses access. Never raises, because paste is
    bound to a keystroke and a traceback there would be a crash, not a message.
    """
    handles = _windll()
    if handles is None:
        return _read_via_pywin32()  # pragma: no cover - optional path
    user32, kernel32 = handles
    if not user32.OpenClipboard(None):
        return None
    try:
        for fmt in (CF_DIB, CF_DIBV5):
            handle = user32.GetClipboardData(fmt)
            if not handle:
                continue
            pointer = kernel32.GlobalLock(handle)
            if not pointer:
                continue
            try:
                size = int(kernel32.GlobalSize(handle) or 0)
                if size <= 0:
                    continue
                raw = ctypes.string_at(pointer, size)
            finally:
                kernel32.GlobalUnlock(handle)
            try:
                return dib_to_image(raw)
            except (ValueError, OSError):
                logger.debug("clipboard DIB could not be decoded", exc_info=True)
                return None
        return None
    finally:
        user32.CloseClipboard()


def _read_via_pywin32() -> Image.Image | None:  # pragma: no cover - optional path
    try:
        import win32clipboard
        import win32con

        win32clipboard.OpenClipboard()
        try:
            if not win32clipboard.IsClipboardFormatAvailable(win32con.CF_DIB):
                return None
            raw = win32clipboard.GetClipboardData(win32con.CF_DIB)
        finally:
            win32clipboard.CloseClipboard()
        return dib_to_image(raw)
    except Exception:
        return None
