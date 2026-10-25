"""Round-13 — one bus event for the PC image library.

The gallery window must refresh when the library changes, whoever changed it: a
paste in the window, a drag-and-drop, a ``GALLERY_ADD`` from the tablet, or a
canvas saved back with ``GALLERY_SAVE``. Emitting one event from the sync layer
means the window has exactly one refresh path and never has to poll the disk.

The name is defined here rather than in ``core/events.py`` so the round-13
gallery work stays self-contained; the bus keys handlers by string, so a
listener cannot tell the difference.
"""

from __future__ import annotations

#: Frozen payload: ``{reason: str, image_id: str | None}``.
#: ``reason`` is one of :data:`REASON_ADDED`, :data:`REASON_SAVED`,
#: :data:`REASON_REMOVED`. Handlers must tolerate unknown keys (``**extra``).
GALLERY_CHANGED = "GALLERY_CHANGED"

REASON_ADDED = "added"
REASON_SAVED = "saved"
REASON_REMOVED = "removed"
