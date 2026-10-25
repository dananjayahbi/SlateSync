"""PC image library (Doc 02 §13.1) — ``<appdata>/gallery``.

The library is a **shared, two-way collection**, not a file list: an image
captured on the PC (paste, drop) must be openable on the tablet, and a canvas
rendered on the tablet must come back to the PC in a form that can be pasted
into a ticket.

Module split, one concern each:

* :mod:`pc_agent.gallery.gallery_index` — the JSON row index (atomic, tolerant);
* :mod:`pc_agent.gallery.library_store` — the bytes + the add/save semantics;
* :mod:`pc_agent.gallery.clipboard_image` — the Windows ``CF_DIB`` encoder;
* :mod:`pc_agent.gallery.events` — the local bus event the window listens to.
"""

from __future__ import annotations

from pc_agent.gallery.clipboard_image import (
    CF_DIB,
    copy_image_to_clipboard,
    dib_from_image,
    dib_header,
)
from pc_agent.gallery.events import GALLERY_CHANGED
from pc_agent.gallery.gallery_index import (
    SOURCE_CANVAS,
    SOURCE_DROP,
    SOURCE_PASTE,
    SOURCES,
    GalleryIndex,
    default_gallery_dir,
    sort_rows,
)
from pc_agent.gallery.library_store import LibraryStore, extension_for

__all__ = [
    "CF_DIB",
    "GALLERY_CHANGED",
    "SOURCE_CANVAS",
    "SOURCE_DROP",
    "SOURCE_PASTE",
    "SOURCES",
    "GalleryIndex",
    "LibraryStore",
    "copy_image_to_clipboard",
    "default_gallery_dir",
    "dib_from_image",
    "dib_header",
    "extension_for",
    "sort_rows",
]
