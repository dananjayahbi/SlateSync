"""Tests for the Doc 02 wire-protocol mirror (Doc 04 §6)."""

import struct

from pc_agent.core.protocol import (
    FRAME_CAMERA,
    FRAME_LASER,
    FRAME_LIVE_END,
    FRAME_LIVE_POINT,
    FRAME_STRUCT,
    RPC_ACTIONS,
    RPC_TYPES,
    TOOL_ERASER,
    TOOL_HIGHLIGHTER,
    TOOL_PEN,
    TOOL_SHAPE_PREVIEW,
    LiveFrame,
    is_newer_seq,
    pack_live_frame,
    unpack_live_frame,
)


def test_frame_and_tool_constants() -> None:
    assert (FRAME_LIVE_POINT, FRAME_LIVE_END, FRAME_CAMERA, FRAME_LASER) == (0x01, 0x02, 0x03, 0x04)
    assert (TOOL_PEN, TOOL_HIGHLIGHTER, TOOL_ERASER, TOOL_SHAPE_PREVIEW) == (0x01, 0x02, 0x03, 0x04)


def test_frame_struct_is_16_bytes_little_endian() -> None:
    assert FRAME_STRUCT.size == 16


def test_pack_unpack_roundtrip() -> None:
    frame = LiveFrame(FRAME_LIVE_POINT, TOOL_PEN, 65535, 1.5, -2.25, 3.75)
    raw = pack_live_frame(frame)
    assert len(raw) == 16
    assert unpack_live_frame(raw) == frame
    assert unpack_live_frame(memoryview(raw)) == frame


def test_golden_byte_layout() -> None:
    frame = LiveFrame(FRAME_CAMERA, TOOL_SHAPE_PREVIEW, 0x0201, 1.0, 2.0, 3.0)
    raw = pack_live_frame(frame)
    assert len(raw) == 16
    assert raw[0] == 0x03  # frame_type @ byte 0
    assert raw[1] == 0x04  # tool_id @ byte 1
    assert raw[2] == 0x01 and raw[3] == 0x02  # u16 seq little-endian @ bytes 2-3
    assert struct.unpack_from("<f", raw, 4)[0] == 1.0  # f32 @ 4
    assert struct.unpack_from("<f", raw, 8)[0] == 2.0  # f32 @ 8
    assert struct.unpack_from("<f", raw, 12)[0] == 3.0  # f32 @ 12
    assert raw == bytes([0x03, 0x04, 0x01, 0x02]) + struct.pack("<fff", 1.0, 2.0, 3.0)


def test_unpack_rejects_wrong_size() -> None:
    try:
        unpack_live_frame(b"\x00" * 15)
    except ValueError:
        pass
    else:
        raise AssertionError("unpack_live_frame must reject non-16-byte input")


def test_is_newer_seq_mod_2_16_window() -> None:
    assert is_newer_seq(0, None) is True  # no prior frame
    assert is_newer_seq(0, 65535) is True  # wrap 65535 -> 0
    assert is_newer_seq(5, 65535) is True  # delta 6 across the wrap
    assert is_newer_seq(5, 5) is False  # duplicate
    assert is_newer_seq(99, 100) is False  # going backwards
    assert is_newer_seq(32767, 0) is True  # just inside the window
    assert is_newer_seq(32768, 0) is False  # half-window boundary excluded
    assert is_newer_seq(0, 32768) is False  # symmetric half-window: also excluded
    assert is_newer_seq(40000, 10000) is True


def test_rpc_actions_mirror_doc02_exactly() -> None:
    expected = {
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
        "CANVAS_LIST_REQUEST",
        "CANVAS_LIST",
        "CANVAS_OPEN_REQUEST",
        # Doc 02 §9.1 — Hub Sync & Multi-Device Extension (19 actions).
        "CANVAS_PUT",
        "CANVAS_PULL",
        # Doc 02 §10.1 — Round-6 clear (20 actions).
        "CLEAR_CANVAS",
    }
    assert RPC_ACTIONS == frozenset(expected)
    assert len(RPC_ACTIONS) == 20


def test_rpc_types_mirror_doc02_exactly() -> None:
    expected = {
        "CANVAS_LIFECYCLE",
        "ELEMENT_COMMIT",
        "ARTBOARD_RESIZE",
        "ASSET_UPLOAD",
        "EXPORT_JOB",
    }
    assert RPC_TYPES == frozenset(expected)
    assert len(RPC_TYPES) == 5
