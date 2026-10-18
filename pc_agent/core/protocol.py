"""Wire-protocol mirror of Doc 02 (source of truth: ``shared_specs/*.json``).

Constants and semantics are copied from ``docs/micro/02_vector_stream_protocol_spec.md``
and ``_micro_doc_template.md`` §3 — never re-derived here (Doc 04 §1).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Final

FRAME_LIVE_POINT, FRAME_LIVE_END, FRAME_CAMERA, FRAME_LASER = 0x01, 0x02, 0x03, 0x04
TOOL_PEN, TOOL_HIGHLIGHTER, TOOL_ERASER, TOOL_SHAPE_PREVIEW = 0x01, 0x02, 0x03, 0x04

#: 16 bytes little-endian: type@0, tool@1, seq u16 LE @2-3, f32 @4/8/12.
FRAME_STRUCT: Final = struct.Struct("<BBHfff")

RPC_TYPES: Final = frozenset(
    {
        "CANVAS_LIFECYCLE",
        "ELEMENT_COMMIT",
        "ARTBOARD_RESIZE",
        "ASSET_UPLOAD",
        "EXPORT_JOB",
    }
)

RPC_ACTIONS: Final = frozenset(
    {
        "OPEN_CANVAS",
        "ADD_STROKE",
        "ADD_GRAPH",
        "ADD_SHAPE",
        "ADD_IMAGE",
        "DELETE_NODE",
        "UPGRADE_SIZE",
        "START_EXPORT",
        "CANCEL_EXPORT",
        "EXPORT_PROGRESS",
        "EXPORT_FINISHED",
        "ASSET_START",
        "ASSET_CHUNK",
        "ASSET_DONE",
    }
)


@dataclass(frozen=True)
class LiveFrame:
    frame_type: int
    tool_id: int
    seq: int
    f1: float
    f2: float
    f3: float


def pack_live_frame(frame: LiveFrame) -> bytes:
    """Serialize to exactly 16 bytes (``<BBHfff``) per Doc 02 §4.1."""
    return FRAME_STRUCT.pack(
        frame.frame_type, frame.tool_id, frame.seq, frame.f1, frame.f2, frame.f3
    )


def unpack_live_frame(data: bytes | memoryview) -> LiveFrame:
    """Parse a 16-byte wire frame; raises ``ValueError`` on wrong size."""
    if len(data) != FRAME_STRUCT.size:
        raise ValueError(f"live frame must be {FRAME_STRUCT.size} bytes, got {len(data)}")
    frame_type, tool_id, seq, f1, f2, f3 = FRAME_STRUCT.unpack(data)
    return LiveFrame(frame_type, tool_id, seq, f1, f2, f3)


def is_newer_seq(seq: int, last: int | None) -> bool:
    """Mod-2^16 freshness window (template §3): None → True; else 0 < delta < 0x8000."""
    if last is None:
        return True
    delta = (seq - last) & 0xFFFF
    return 0 < delta < 0x8000
