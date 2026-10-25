"""Round-13 §03 — the PC image library.

Covers the four things that actually decide whether the feature works:

* the index's **durability** (round-trip, atomic write, corrupt-file recovery);
* **newest-first ordering**, because the grid's whole value is "the thing I just
  pasted is at the top";
* the **add / save / replace / copy** semantics, where replace is destructive and
  must therefore never be a default;
* the ``CF_DIB`` **header layout** — bottom-up rows, 32 bpp, correct size fields —
  because writing PNG bytes under ``CF_DIB`` is exactly the bug that made "copy to
  clipboard" useless.

Drag-and-drop is tested through its *degradation*: ``tkinterdnd2`` is not
installed, and the window must keep paste and the file picker working without it.
Everything that needs a display is skipped when Tk is unavailable.
"""

from __future__ import annotations

import base64
import io
import json
import struct
import time
from pathlib import Path

import pytest
from PIL import Image

from pc_agent.core.events import RPC_MESSAGE, EventBus
from pc_agent.gallery import clipboard_image as clip
from pc_agent.gallery.events import GALLERY_CHANGED, REASON_ADDED, REASON_SAVED
from pc_agent.gallery.gallery_index import (
    SOURCE_CANVAS,
    SOURCE_DROP,
    SOURCE_PASTE,
    GalleryIndex,
    coerce_row,
    normalise_source,
    sort_rows,
)
from pc_agent.gallery.library_store import (
    MODE_COPY,
    MODE_REPLACE,
    LibraryStore,
    extension_for,
    inspect_image,
)
from pc_agent.network.gallery_sync import (
    CHUNK_RAW,
    MAX_PENDING_TRANSFERS,
    TRANSFER_TTL_S,
    GallerySync,
)

# --------------------------------------------------------------------------- helpers


def png_bytes(width: int = 8, height: int = 6, colour=(200, 30, 40)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), colour).save(buffer, format="PNG")
    return buffer.getvalue()


def jpeg_bytes(width: int = 5, height: int = 4) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (10, 200, 30)).save(buffer, format="JPEG")
    return buffer.getvalue()


def envelope(action: str, payload: dict, *, envelope_type: str = "GALLERY") -> dict:
    return {
        "id": "00000000-0000-4000-8000-000000000000",
        "type": envelope_type,
        "action": action,
        "canvas_id": "",
        "payload": payload,
        "timestamp": int(time.time()),
    }


class PushSpy:
    def __init__(self) -> None:
        self.envelopes: list[dict] = []

    def __call__(self, envelope: dict) -> None:
        self.envelopes.append(envelope)

    def actions(self) -> list[str]:
        return [env["action"] for env in self.envelopes]


@pytest.fixture()
def store(tmp_path: Path) -> LibraryStore:
    return LibraryStore(tmp_path / "gallery")


@pytest.fixture()
def sync(store: LibraryStore):
    bus = EventBus()
    push = PushSpy()
    gallery_sync = GallerySync(bus, store, push=push)
    yield gallery_sync, bus, push
    gallery_sync.shutdown()


# ------------------------------------------------------------------ index storage


def test_index_starts_empty_when_absent(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path / "missing")
    assert index.list() == []
    assert index.count() == 0
    assert index.get("nope") is None


def test_index_round_trip_preserves_every_row_key(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path)
    row = {
        "image_id": "img-1",
        "title": "Screenshot",
        "width": 640,
        "height": 480,
        "source": SOURCE_PASTE,
        "created_at": 1_700_000_000,
        "updated_at": 1_700_000_010,
        "mime": "image/png",
        "filename": "shot.png",
    }
    index.put(row)
    reopened = GalleryIndex(tmp_path)
    stored = reopened.get("img-1")
    assert stored is not None
    assert {key: stored[key] for key in row} == row


def test_index_write_is_atomic_and_leaves_no_tmp_file(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path)
    index.put({"image_id": "a", "width": 2, "height": 2, "updated_at": 5})
    assert (tmp_path / "index.json").is_file()
    assert not (tmp_path / "index.json.tmp").exists()


def test_corrupt_index_reads_as_empty_rather_than_raising(tmp_path: Path) -> None:
    (tmp_path / "index.json").write_text("{not json at all", encoding="utf-8")
    index = GalleryIndex(tmp_path)
    assert index.list() == []
    # ... and the library is still usable afterwards.
    index.put({"image_id": "fresh", "width": 3, "height": 3, "updated_at": 7})
    assert [row["image_id"] for row in index.list()] == ["fresh"]


def test_index_with_wrong_outer_type_reads_as_empty(tmp_path: Path) -> None:
    (tmp_path / "index.json").write_text(json.dumps({"rows": []}), encoding="utf-8")
    assert GalleryIndex(tmp_path).list() == []


def test_index_drops_rows_that_cannot_identify_an_image(tmp_path: Path) -> None:
    (tmp_path / "index.json").write_text(
        json.dumps([{"title": "no id"}, "garbage", {"image_id": ""}, 42]),
        encoding="utf-8",
    )
    assert GalleryIndex(tmp_path).list() == []


def test_index_repairs_stringly_typed_numbers(tmp_path: Path) -> None:
    (tmp_path / "index.json").write_text(
        json.dumps(
            [
                {
                    "image_id": "x",
                    "width": "640",
                    "height": "480",
                    "created_at": "17",
                    "updated_at": "18",
                }
            ]
        ),
        encoding="utf-8",
    )
    row = GalleryIndex(tmp_path).get("x")
    assert row is not None
    assert (row["width"], row["height"]) == (640, 480)
    assert (row["created_at"], row["updated_at"]) == (17, 18)


def test_index_clamps_zero_sizes_to_one(tmp_path: Path) -> None:
    row = coerce_row({"image_id": "z", "width": 0, "height": -4})
    assert row is not None
    assert (row["width"], row["height"]) == (1, 1)


def test_index_remove_reports_whether_anything_went(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path)
    index.put({"image_id": "a", "width": 1, "height": 1, "updated_at": 1})
    assert index.remove("a") is True
    assert index.remove("a") is False


def test_index_replace_all_rewrites_the_file(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path)
    index.put({"image_id": "old", "width": 1, "height": 1, "updated_at": 1})
    index.replace_all(
        [{"image_id": "new", "width": 2, "height": 2, "updated_at": 2}, {"bogus": True}]
    )
    assert [row["image_id"] for row in index.list()] == ["new"]


def test_row_shape_matches_the_wire_payload_keys(tmp_path: Path) -> None:
    index = GalleryIndex(tmp_path)
    index.put({"image_id": "w", "width": 4, "height": 5, "updated_at": 2})
    row = index.get("w")
    assert row is not None
    assert set(row) == {
        "image_id",
        "title",
        "width",
        "height",
        "source",
        "created_at",
        "updated_at",
        "mime",
        "filename",
    }


def test_unknown_source_is_coerced_to_paste() -> None:
    assert normalise_source("canvas") == SOURCE_CANVAS
    assert normalise_source("  DROP ") == SOURCE_DROP
    assert normalise_source("SOMETHING_ELSE") == SOURCE_PASTE
    assert normalise_source(None) == SOURCE_PASTE


# ---------------------------------------------------------------------- ordering


def test_rows_are_newest_first() -> None:
    rows = [
        {"image_id": "old", "updated_at": 100},
        {"image_id": "new", "updated_at": 300},
        {"image_id": "mid", "updated_at": 200},
    ]
    assert [row["image_id"] for row in sort_rows(rows)] == ["new", "mid", "old"]


def test_ordering_is_stable_for_equal_timestamps() -> None:
    rows = [
        {"image_id": "b", "updated_at": 100},
        {"image_id": "a", "updated_at": 100},
    ]
    assert [row["image_id"] for row in sort_rows(rows)] == ["a", "b"]
    assert [row["image_id"] for row in sort_rows(list(reversed(rows)))] == ["a", "b"]


def test_store_list_is_newest_first(store: LibraryStore) -> None:
    first = store.add(png_bytes(), title="first")
    time.sleep(0.01)
    second = store.add(png_bytes(), title="second")
    assert [row["image_id"] for row in store.list()][:2] == [
        second["image_id"],
        first["image_id"],
    ]


def test_re_adding_an_image_moves_it_to_the_front(store: LibraryStore) -> None:
    older = store.add(png_bytes(), title="older")
    newer = store.add(png_bytes(), title="newer")
    time.sleep(0.01)
    store.add(png_bytes(), title="older", image_id=older["image_id"])
    assert store.list()[0]["image_id"] == older["image_id"]
    assert len(store.list()) == 2
    assert newer["image_id"] in {row["image_id"] for row in store.list()}


# -------------------------------------------------------------- add / save semantics


def test_add_measures_the_real_pixel_size(store: LibraryStore) -> None:
    row = store.add(png_bytes(width=37, height=19), title="shot")
    assert (row["width"], row["height"]) == (37, 19)


def test_add_ignores_a_lying_declared_size(store: LibraryStore) -> None:
    """The bytes win: an artboard built from a declared size would clip."""
    row = store.add(png_bytes(width=12, height=9), title="shot", image_id="liar")
    assert (row["width"], row["height"]) == (12, 9)


def test_add_derives_the_extension_from_the_bytes(store: LibraryStore) -> None:
    row = store.add(jpeg_bytes(), filename="actually_a_png.png")
    assert row["mime"] == "image/jpeg"
    stored = store.path_for(row)
    assert stored.suffix == ".jpg"
    assert stored.is_file()


def test_add_falls_back_to_the_id_extension_for_unknown_mime() -> None:
    assert extension_for(None) == "png"
    assert extension_for("application/octet-stream", "photo.JPEG") == "jpg"
    assert extension_for("image/webp") == "webp"


def test_add_rejects_bytes_that_are_not_an_image(store: LibraryStore) -> None:
    with pytest.raises(ValueError):
        store.add(b"definitely not an image")


def test_inspect_image_reports_mime_and_size() -> None:
    mime, ext, width, height = inspect_image(png_bytes(11, 7))
    assert (mime, ext, width, height) == ("image/png", "png", 11, 7)


def test_add_uses_the_filename_stem_as_the_default_title(store: LibraryStore) -> None:
    row = store.add(png_bytes(), filename="bug-report.png")
    assert row["title"] == "bug-report"


def test_add_falls_back_to_a_short_id_title(store: LibraryStore) -> None:
    row = store.add(png_bytes(), image_id="abcdefgh-1234")
    assert row["title"] == "abcdefgh"


def test_add_strips_directories_out_of_the_display_name(store: LibraryStore) -> None:
    row = store.add(png_bytes(), filename="../../evil/shot.png")
    assert row["filename"] == "shot.png"


def test_add_keeps_the_original_bytes_for_png(store: LibraryStore) -> None:
    original = png_bytes(9, 5)
    row = store.add(original, filename="kept.png")
    assert store.path_for(row).read_bytes() == original


def test_add_writes_no_tmp_residue(store: LibraryStore) -> None:
    store.add(png_bytes(), image_id="clean")
    leftovers = [path.name for path in store.directory.iterdir() if path.suffix == ".tmp"]
    assert leftovers == []


def test_save_canvas_copy_mints_a_new_id(store: LibraryStore) -> None:
    original = store.add(png_bytes(), title="original")
    saved = store.save_canvas(
        png_bytes(20, 20), mode=MODE_COPY, image_id=original["image_id"], title="render"
    )
    assert saved["image_id"] != original["image_id"]
    assert saved["source"] == SOURCE_CANVAS
    assert len(store.list()) == 2


def test_save_canvas_replace_keeps_the_id_and_bumps_updated_at(store: LibraryStore) -> None:
    original = store.add(png_bytes(4, 4), title="annotated")
    time.sleep(1.05)  # unix seconds: the bump has to be observable
    saved = store.save_canvas(
        png_bytes(40, 30), mode=MODE_REPLACE, image_id=original["image_id"], title="annotated"
    )
    assert saved["image_id"] == original["image_id"]
    assert saved["created_at"] == original["created_at"]
    assert saved["updated_at"] > original["updated_at"]
    # The new render replaced the bytes, including its measured pixel size.
    assert (saved["width"], saved["height"]) == (40, 30)
    assert len(store.list()) == 1


def test_save_canvas_with_an_unknown_mode_is_a_copy(store: LibraryStore) -> None:
    original = store.add(png_bytes(), title="original")
    saved = store.save_canvas(png_bytes(), mode="SIDEWAYS", image_id=original["image_id"])
    assert saved["image_id"] != original["image_id"]


def test_save_canvas_replace_without_an_id_cannot_destroy_anything(
    store: LibraryStore,
) -> None:
    store.add(png_bytes(), title="keep me")
    saved = store.save_canvas(png_bytes(), mode=MODE_REPLACE, image_id=None)
    assert saved["image_id"]
    assert len(store.list()) == 2


def test_add_with_a_replacement_extension_removes_the_stale_file(
    store: LibraryStore,
) -> None:
    store.add(png_bytes(6, 6), image_id="swap")
    stale = store.directory / "swap.png"
    assert stale.is_file()
    store.add(jpeg_bytes(6, 6), image_id="swap")
    assert not stale.exists()
    assert (store.directory / "swap.jpg").is_file()


def test_import_file_adds_a_dropped_file(store: LibraryStore, tmp_path: Path) -> None:
    dropped = tmp_path / "dropped.png"
    dropped.write_bytes(png_bytes(14, 12))
    row = store.import_file(dropped)
    assert row["source"] == SOURCE_DROP
    assert (row["width"], row["height"]) == (14, 12)


def test_list_hides_rows_whose_file_vanished(store: LibraryStore) -> None:
    row = store.add(png_bytes(), title="ghost")
    store.path_for(row).unlink()
    assert store.list() == []
    assert store.get(row["image_id"]) is None


def test_remove_deletes_bytes_and_row(store: LibraryStore) -> None:
    row = store.add(png_bytes(), title="bye")
    path = store.path_for(row)
    assert store.remove(row["image_id"]) is True
    assert not path.exists()
    assert store.get(row["image_id"]) is None


def test_save_as_copies_to_the_requested_destination(
    store: LibraryStore, tmp_path: Path
) -> None:
    row = store.add(png_bytes(3, 3), filename="copy-me.png")
    target = tmp_path / "out" / "copy-me.png"
    assert store.save_as(row["image_id"], target) == target
    assert target.read_bytes() == store.path_for(row).read_bytes()


def test_save_as_refuses_an_unknown_image(store: LibraryStore, tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        store.save_as("nope", tmp_path / "x.png")


def test_row_for_wire_keeps_exactly_the_contract_keys(store: LibraryStore) -> None:
    row = store.add(png_bytes(), title="wire")
    wire = LibraryStore.row_for_wire(row)
    assert set(wire) == {
        "image_id",
        "title",
        "width",
        "height",
        "source",
        "created_at",
        "updated_at",
        "mime",
        "filename",
    }


# ------------------------------------------------------------------- CF_DIB layout


def test_dib_header_declares_a_40_byte_bottom_up_32bpp_header() -> None:
    fields = clip.header_fields(clip.dib_header(4, 3))
    assert fields == {
        "biSize": 40,
        "biWidth": 4,
        "biHeight": 3,  # POSITIVE ⇒ bottom-up: what CF_DIB consumers expect
        "biPlanes": 1,
        "biBitCount": 32,
        "biCompression": 0,  # BI_RGB
        "biSizeImage": 4 * 4 * 3,
        "biXPelsPerMeter": clip.PELS_PER_METRE,
        "biYPelsPerMeter": clip.PELS_PER_METRE,
        "biClrUsed": 0,
        "biClrImportant": 0,
    }


def test_dib_header_scales_the_image_size_with_the_height() -> None:
    assert clip.header_fields(clip.dib_header(10, 1))["biSizeImage"] == 40
    assert clip.header_fields(clip.dib_header(10, 5))["biSizeImage"] == 200


def test_dib_header_pads_24bpp_rows_to_a_dword_boundary() -> None:
    # 3 px * 3 bytes = 9 → 12 padded; 2 rows → 24 bytes.
    fields = clip.header_fields(clip.dib_header(3, 2, bpp=24))
    assert fields["biBitCount"] == 24
    assert fields["biSizeImage"] == 24


def test_dib_header_rejects_empty_or_unsupported_sizes() -> None:
    with pytest.raises(ValueError):
        clip.dib_header(0, 5)
    with pytest.raises(ValueError):
        clip.dib_header(5, -1)
    with pytest.raises(ValueError):
        clip.dib_header(5, 5, bpp=8)


def test_dib_rows_are_stored_bottom_up() -> None:
    """The last pixel row on screen is the FIRST row in the blob."""
    image = Image.new("RGB", (1, 2), (0, 0, 0))
    image.putpixel((0, 0), (255, 0, 0))  # top row red
    image.putpixel((0, 1), (0, 0, 255))  # bottom row blue
    blob = clip.dib_from_image(image)
    pixels = blob[clip.BITMAPINFOHEADER_SIZE:]
    assert len(pixels) == 8  # 1 px * 4 bytes * 2 rows
    assert tuple(pixels[0:3]) == (255, 0, 0)  # BGR of the BLUE pixel first
    assert tuple(pixels[4:7]) == (0, 0, 255)  # ... then the RED one


def test_dib_pixels_are_bgra_with_an_opaque_alpha() -> None:
    image = Image.new("RGBA", (1, 1), (10, 20, 30, 0))  # transparent source
    pixels = clip.dib_pixels(image)
    assert tuple(pixels) == (30, 20, 10, 255)  # BGRA, alpha forced opaque


def test_dib_blob_is_header_plus_exactly_the_declared_pixels() -> None:
    blob = clip.dib_from_image(Image.new("RGB", (7, 3)))
    header = clip.header_fields(blob[: clip.BITMAPINFOHEADER_SIZE])
    assert len(blob) == clip.BITMAPINFOHEADER_SIZE + header["biSizeImage"]
    assert len(blob) == clip.BITMAPINFOHEADER_SIZE + 7 * 4 * 3


def test_dib_round_trips_through_the_decoder() -> None:
    image = Image.new("RGB", (5, 4), (12, 34, 56))
    restored = clip.dib_to_image(clip.dib_from_image(image))
    assert restored.size == (5, 4)
    assert restored.convert("RGB").getpixel((0, 0)) == (12, 34, 56)


def test_dib_decoder_rejects_a_truncated_blob() -> None:
    with pytest.raises(ValueError):
        clip.dib_to_image(b"\x00" * 10)


def test_cf_dib_is_format_eight() -> None:
    assert clip.CF_DIB == 8


def test_clipboard_error_is_a_runtime_error() -> None:
    assert issubclass(clip.ClipboardError, RuntimeError)


def test_copy_of_an_empty_image_is_reported_not_raised_as_value_error() -> None:
    with pytest.raises(clip.ClipboardError):
        clip.copy_image_to_clipboard(Image.new("RGB", (0, 0)))


# --------------------------------------------------------------- RPC / sync layer


def test_list_request_answers_with_every_row(sync) -> None:
    gallery_sync, bus, push = sync
    gallery_sync._store.add(png_bytes(), title="a")  # noqa: SLF001 - test seam
    gallery_sync._store.add(png_bytes(), title="b")  # noqa: SLF001
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_LIST_REQUEST", {}))
    assert push.actions() == ["GALLERY_LIST"]
    images = push.envelopes[-1]["payload"]["images"]
    assert len(images) == 2
    assert [image["title"] for image in images] == ["b", "a"]  # newest first


def test_list_payload_carries_the_full_row_contract(sync) -> None:
    gallery_sync, _bus, _push = sync
    gallery_sync._store.add(png_bytes(10, 8), title="contract")  # noqa: SLF001
    payload = gallery_sync.list_payload()
    assert set(payload) == {"images"}
    image = payload["images"][0]
    assert set(image) == {
        "image_id",
        "title",
        "width",
        "height",
        "source",
        "created_at",
        "updated_at",
        "mime",
        "filename",
    }
    assert (image["width"], image["height"]) == (10, 8)


def test_unknown_gallery_action_is_ignored(sync) -> None:
    _gallery_sync, bus, push = sync
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_NONSENSE", {}))
    assert push.envelopes == []


def test_non_gallery_envelopes_are_left_alone(sync) -> None:
    _gallery_sync, bus, push = sync
    bus.emit(RPC_MESSAGE, msg=envelope("OPEN_CANVAS", {}, envelope_type="CANVAS_LIFECYCLE"))
    assert push.envelopes == []


def test_inline_bytes_b64_is_accepted_for_a_small_add(sync) -> None:
    gallery_sync, bus, _push = sync
    payload = {
        "image_id": "inline-1",
        "title": "inline",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "inline.png",
        "mime": "image/png",
        "bytes_b64": base64.b64encode(png_bytes(8, 6)).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    row = gallery_sync._store.get("inline-1")  # noqa: SLF001
    assert row is not None and (row["width"], row["height"]) == (8, 6)


def test_a_streamed_add_commits_only_on_asset_done(sync) -> None:
    gallery_sync, bus, push = sync
    data = png_bytes(16, 12)
    payload = {
        "image_id": "streamed",
        "title": "streamed",
        "width": 16,
        "height": 12,
        "source": SOURCE_PASTE,
        "filename": "streamed.png",
        "mime": "image/png",
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    assert gallery_sync._store.get("streamed") is None  # noqa: SLF001

    start = {
        "transfer_id": "streamed",
        "filename": "streamed.png",
        "total_chunks": 1,
        "size_bytes": len(data),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("ASSET_START", start, envelope_type="ASSET_UPLOAD"))
    assert gallery_sync._store.get("streamed") is None  # noqa: SLF001

    chunk = {
        "transfer_id": "streamed",
        "index": 0,
        "data_b64": base64.b64encode(data).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("ASSET_CHUNK", chunk, envelope_type="ASSET_UPLOAD"))
    bus.emit(
        RPC_MESSAGE,
        msg=envelope("ASSET_DONE", {"transfer_id": "streamed"}, envelope_type="ASSET_UPLOAD"),
    )
    row = gallery_sync._store.get("streamed")  # noqa: SLF001
    assert row is not None
    assert row["source"] == SOURCE_PASTE
    assert push.actions()[-1] == "GALLERY_LIST"


def test_an_undeclared_transfer_is_not_claimed_for_the_library(sync) -> None:
    """The open canvas's ASSET_* uploads must reach DocumentStore untouched."""
    gallery_sync, bus, _push = sync
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_START",
            {"transfer_id": "canvas-image", "filename": "x.png", "total_chunks": 1,
             "size_bytes": 10},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {"transfer_id": "canvas-image", "index": 0,
             "data_b64": base64.b64encode(png_bytes()).decode()},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_DONE", {"transfer_id": "canvas-image"}, envelope_type="ASSET_UPLOAD"
        ),
    )
    assert gallery_sync._store.list() == []  # noqa: SLF001


def test_gallery_save_copy_produces_two_library_items(sync) -> None:
    gallery_sync, bus, _push = sync
    existing = gallery_sync._store.add(png_bytes(), title="original")  # noqa: SLF001
    payload = {
        "image_id": existing["image_id"],
        "title": "annotated",
        "width": 8,
        "height": 6,
        "filename": "annotated.png",
        "mime": "image/png",
        "mode": MODE_COPY,
        "bytes_b64": base64.b64encode(png_bytes(8, 6)).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_SAVE", payload))
    rows = gallery_sync._store.list()  # noqa: SLF001
    assert len(rows) == 2
    assert rows[0]["source"] == SOURCE_CANVAS


def test_gallery_save_replace_overwrites_the_same_library_item(sync) -> None:
    gallery_sync, bus, _push = sync
    existing = gallery_sync._store.add(png_bytes(4, 4), title="annotated")  # noqa: SLF001
    payload = {
        "image_id": existing["image_id"],
        "title": "annotated",
        "width": 30,
        "height": 20,
        "filename": "annotated.png",
        "mime": "image/png",
        "mode": MODE_REPLACE,
        "bytes_b64": base64.b64encode(png_bytes(30, 20)).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_SAVE", payload))
    rows = gallery_sync._store.list()  # noqa: SLF001
    assert len(rows) == 1
    assert rows[0]["image_id"] == existing["image_id"]
    assert (rows[0]["width"], rows[0]["height"]) == (30, 20)


def test_gallery_changed_is_emitted_for_a_committed_upload(sync) -> None:
    gallery_sync, bus, _push = sync
    seen: list[dict] = []
    bus.on(GALLERY_CHANGED, lambda **payload: seen.append(payload))
    payload = {
        "image_id": "evented",
        "title": "evented",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "evented.png",
        "mime": "image/png",
        "bytes_b64": base64.b64encode(png_bytes()).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    assert seen and seen[-1]["reason"] == REASON_ADDED
    assert seen[-1]["image_id"] == "evented"


def test_a_local_gallery_changed_pushes_the_list(sync) -> None:
    """A paste in the PC window must reach the tablet through one code path."""
    _gallery_sync, bus, push = sync
    bus.emit(GALLERY_CHANGED, reason=REASON_ADDED, image_id="local")
    assert push.actions() == ["GALLERY_LIST"]


def test_a_save_emits_the_saved_reason(sync) -> None:
    gallery_sync, bus, _push = sync
    seen: list[dict] = []
    bus.on(GALLERY_CHANGED, lambda **payload: seen.append(payload))
    payload = {
        "image_id": "saved",
        "title": "saved",
        "width": 8,
        "height": 6,
        "filename": "saved.png",
        "mime": "image/png",
        "mode": MODE_REPLACE,
        "bytes_b64": base64.b64encode(png_bytes()).decode(),
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_SAVE", payload))
    assert seen[-1]["reason"] == REASON_SAVED


def test_a_bad_chunk_discards_the_upload(sync) -> None:
    gallery_sync, bus, _push = sync
    payload = {
        "image_id": "broken",
        "title": "broken",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "broken.png",
        "mime": "image/png",
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    assert "broken" in gallery_sync.pending_transfers
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {"transfer_id": "broken", "index": 0, "data_b64": "!!!not base64!!!"},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    assert "broken" not in gallery_sync.pending_transfers


def test_a_chunk_over_the_cap_discards_the_upload(sync) -> None:
    gallery_sync, bus, _push = sync
    payload = {
        "image_id": "huge",
        "title": "huge",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "huge.png",
        "mime": "image/png",
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    oversized = base64.b64encode(b"\x00" * (CHUNK_RAW + 1)).decode()
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {"transfer_id": "huge", "index": 0, "data_b64": oversized},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    assert "huge" not in gallery_sync.pending_transfers


def test_an_aborted_transfer_is_never_applied(sync) -> None:
    gallery_sync, bus, _push = sync
    payload = {
        "image_id": "aborted",
        "title": "aborted",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "aborted.png",
        "mime": "image/png",
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_DONE",
            {"transfer_id": "aborted", "ok": False},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    assert gallery_sync._store.list() == []  # noqa: SLF001


def test_a_short_transfer_never_commits(sync) -> None:
    gallery_sync, bus, _push = sync
    payload = {
        "image_id": "short",
        "title": "short",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "short.png",
        "mime": "image/png",
    }
    data = png_bytes()
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_START",
            {"transfer_id": "short", "filename": "short.png", "total_chunks": 2,
             "size_bytes": len(data)},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {"transfer_id": "short", "index": 0, "data_b64": base64.b64encode(data).decode()},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope("ASSET_DONE", {"transfer_id": "short"}, envelope_type="ASSET_UPLOAD"),
    )
    assert gallery_sync._store.list() == []  # noqa: SLF001


def test_a_size_mismatch_never_commits(sync) -> None:
    gallery_sync, bus, _push = sync
    data = png_bytes()
    payload = {
        "image_id": "mismatch",
        "title": "mismatch",
        "width": 8,
        "height": 6,
        "source": SOURCE_PASTE,
        "filename": "mismatch.png",
        "mime": "image/png",
    }
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_ADD", payload))
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_START",
            {"transfer_id": "mismatch", "filename": "mismatch.png", "total_chunks": 1,
             "size_bytes": len(data) + 99},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "ASSET_CHUNK",
            {"transfer_id": "mismatch", "index": 0,
             "data_b64": base64.b64encode(data).decode()},
            envelope_type="ASSET_UPLOAD",
        ),
    )
    bus.emit(
        RPC_MESSAGE,
        msg=envelope("ASSET_DONE", {"transfer_id": "mismatch"}, envelope_type="ASSET_UPLOAD"),
    )
    assert gallery_sync._store.list() == []  # noqa: SLF001


def test_pending_transfers_are_bounded(sync) -> None:
    gallery_sync, bus, _push = sync
    for index in range(MAX_PENDING_TRANSFERS + 3):
        bus.emit(
            RPC_MESSAGE,
            msg=envelope(
                "GALLERY_ADD",
                {
                    "image_id": f"pending-{index}",
                    "title": "pending",
                    "width": 4,
                    "height": 4,
                    "source": SOURCE_PASTE,
                    "filename": "pending.png",
                    "mime": "image/png",
                },
            ),
        )
    assert len(gallery_sync.pending_transfers) <= MAX_PENDING_TRANSFERS


def test_an_expired_transfer_is_forgotten(sync, monkeypatch: pytest.MonkeyPatch) -> None:
    gallery_sync, bus, _push = sync
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "GALLERY_ADD",
            {
                "image_id": "stale",
                "title": "stale",
                "width": 4,
                "height": 4,
                "source": SOURCE_PASTE,
                "filename": "stale.png",
                "mime": "image/png",
            },
        ),
    )
    assert "stale" in gallery_sync.pending_transfers
    later = time.monotonic() + TRANSFER_TTL_S + 1
    monkeypatch.setattr(time, "monotonic", lambda: later)
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "GALLERY_ADD",
            {
                "image_id": "another",
                "title": "another",
                "width": 4,
                "height": 4,
                "source": SOURCE_PASTE,
                "filename": "another.png",
                "mime": "image/png",
            },
        ),
    )
    assert "stale" not in gallery_sync.pending_transfers


def test_detach_stops_all_handling(sync) -> None:
    gallery_sync, bus, push = sync
    gallery_sync.detach()
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_LIST_REQUEST", {}))
    bus.emit(GALLERY_CHANGED, reason=REASON_ADDED, image_id="x")
    assert push.envelopes == []


def test_gallery_envelope_shape_matches_doc02(sync) -> None:
    gallery_sync, bus, push = sync
    bus.emit(RPC_MESSAGE, msg=envelope("GALLERY_LIST_REQUEST", {}))
    sent = push.envelopes[-1]
    assert set(sent) == {"id", "type", "action", "canvas_id", "payload", "timestamp"}
    assert sent["type"] == "GALLERY"
    assert sent["action"] == "GALLERY_LIST"
    assert isinstance(sent["timestamp"], int)


# ------------------------------------------------------- window / degradation


def _tk_root():
    import customtkinter as ctk

    try:
        root = ctk.CTk()
    except Exception as exc:  # pragma: no cover - headless CI
        pytest.skip(f"Tk unavailable: {exc}")
    root.withdraw()
    return root


def test_dnd_absence_degrades_instead_of_breaking() -> None:
    """``tkinterdnd2`` is not a dependency: the module must import without it."""
    from pc_agent.gui import gallery_window

    assert isinstance(gallery_window.HAS_DND, bool)
    # Whatever the environment, the import succeeded — that is the contract.
    assert gallery_window.GalleryWindow is not None


def test_grid_columns_always_offers_at_least_one_column() -> None:
    from pc_agent.gui.gallery_window import grid_columns

    assert grid_columns(0) == 1
    assert grid_columns(120) == 1
    assert grid_columns(2000) >= 5


def test_drop_paths_handle_braced_names_with_spaces() -> None:
    from pc_agent.gui.gallery_window import parse_drop_paths

    assert parse_drop_paths("{C:/My Images/shot 1.png}") == ["C:/My Images/shot 1.png"]
    assert parse_drop_paths("C:/a.png D:/b.png") == ["C:/a.png", "D:/b.png"]
    assert parse_drop_paths("") == []


def test_only_image_suffixes_are_accepted_from_a_drop() -> None:
    from pc_agent.gui.gallery_window import is_image_path

    assert is_image_path("C:/a/b.PNG") is True
    assert is_image_path("C:/a/b.jpeg") is True
    assert is_image_path("C:/a/b.txt") is False


def test_dimensions_caption_tolerates_bad_values() -> None:
    from pc_agent.gui.gallery_window import format_dimensions

    assert format_dimensions(1920, 1080) == "1920 × 1080"
    assert format_dimensions(None, 4) == "—"
    assert format_dimensions(0, 0) == "—"


def test_suggested_save_name_never_escapes_the_dialog() -> None:
    from pc_agent.gui.gallery_window import suggested_save_name

    assert suggested_save_name({"filename": "../../etc/passwd.png"}) == "passwd.png"
    assert suggested_save_name({"image_id": "abc"}) == "abc.png"


def test_window_reports_items_newest_first(store: LibraryStore, tmp_path: Path) -> None:
    from pc_agent.gui.gallery_window import GalleryWindow

    store.add(png_bytes(), title="one")
    time.sleep(0.01)
    second = store.add(png_bytes(), title="two")
    root = _tk_root()
    bus = EventBus()
    window = GalleryWindow(
        root, bus, store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        root.update_idletasks()
        assert window.order[0] == second["image_id"]
        assert window.card_count == 2
    finally:
        window.close()
        root.destroy()


def test_closing_the_window_does_not_destroy_the_root(
    store: LibraryStore,
) -> None:
    """The whole point of a separate, non-modal window: the app survives it."""
    from pc_agent.gui.gallery_window import GalleryWindow

    store.add(png_bytes(), title="one")
    root = _tk_root()
    closed: list[bool] = []
    window = GalleryWindow(
        root,
        EventBus(),
        store,
        on_close=lambda: closed.append(True),
        thumbnail_loader=lambda _path, _size: None,
    )
    try:
        window.close()
        assert closed == [True]
        assert window.exists() is False
        # The root is still alive and answering, so the agent keeps running.
        assert root.winfo_exists()
    finally:
        root.destroy()


def test_the_window_never_grabs_input(store: LibraryStore) -> None:
    """A grab would freeze the studio window while the library is open."""
    from pc_agent.gui.gallery_window import GalleryWindow

    root = _tk_root()
    window = GalleryWindow(
        root, EventBus(), store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        assert root.grab_current() is None
    finally:
        window.close()
        root.destroy()


def test_paste_without_an_image_reports_and_adds_nothing(
    store: LibraryStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from pc_agent.gui import gallery_window

    monkeypatch.setattr(gallery_window, "image_from_clipboard", lambda: None)
    root = _tk_root()
    window = gallery_window.GalleryWindow(
        root, EventBus(), store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        assert window.paste_from_clipboard() is None
        assert store.list() == []
    finally:
        window.close()
        root.destroy()


def test_paste_stores_the_clipboard_image(
    store: LibraryStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from pc_agent.gui import gallery_window

    monkeypatch.setattr(
        gallery_window, "image_from_clipboard", lambda: Image.new("RGB", (11, 7), (1, 2, 3))
    )
    root = _tk_root()
    window = gallery_window.GalleryWindow(
        root, EventBus(), store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        row = window.paste_from_clipboard()
        assert row is not None
        assert (row["width"], row["height"]) == (11, 7)
        assert row["source"] == SOURCE_PASTE
    finally:
        window.close()
        root.destroy()


def test_copy_failure_is_reported_not_raised(
    store: LibraryStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from pc_agent.gui import gallery_window

    def boom(_image) -> None:
        raise gallery_window.ClipboardError("clipboard busy")

    monkeypatch.setattr(gallery_window, "copy_image_to_clipboard", boom)
    row = store.add(png_bytes(), title="copy me")
    root = _tk_root()
    window = gallery_window.GalleryWindow(
        root, EventBus(), store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        assert window.copy_to_clipboard(row["image_id"]) is False
    finally:
        window.close()
        root.destroy()


def test_copy_success_uses_the_dib_encoder(
    store: LibraryStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from pc_agent.gui import gallery_window

    seen: list[tuple[int, int]] = []

    def fake_copy(image) -> None:
        seen.append(image.size)

    monkeypatch.setattr(gallery_window, "copy_image_to_clipboard", fake_copy)
    row = store.add(png_bytes(9, 9), title="copy me")
    root = _tk_root()
    window = gallery_window.GalleryWindow(
        root, EventBus(), store, thumbnail_loader=lambda _path, _size: None
    )
    try:
        assert window.copy_to_clipboard(row["image_id"]) is True
        assert seen == [(9, 9)]
    finally:
        window.close()
        root.destroy()


def test_gallery_changed_reloads_the_open_window(
    store: LibraryStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    from pc_agent.gui.gallery_window import GalleryWindow

    bus = EventBus()
    root = _tk_root()
    window = GalleryWindow(root, bus, store, thumbnail_loader=lambda _path, _size: None)
    try:
        assert window.order == []
        store.add(png_bytes(), title="arrived")
        bus.emit(GALLERY_CHANGED, reason=REASON_ADDED, image_id="arrived")
        root.update()  # drain the after(0) hop _on_changed uses
        assert len(window.order) == 1
    finally:
        window.close()
        root.destroy()


# ------------------------------------------------------------- contract lockstep


def test_contract_lockstep_gallery_type_and_actions() -> None:
    root = Path(__file__).resolve().parents[2]
    schema = json.loads((root / "shared_specs" / "ws_rpc_schema.json").read_text("utf-8"))
    from pc_agent.core.protocol import RPC_ACTIONS, RPC_TYPES

    assert "GALLERY" in schema["envelope"]["type"]["enum"]
    assert "GALLERY" in RPC_TYPES
    assert set(schema["type_actions"]["GALLERY"]) == {
        "GALLERY_LIST_REQUEST",
        "GALLERY_LIST",
        "GALLERY_ADD",
        "GALLERY_SAVE",
    }
    for action in ("GALLERY_LIST_REQUEST", "GALLERY_LIST", "GALLERY_ADD", "GALLERY_SAVE"):
        assert action in RPC_ACTIONS
        assert action in schema["envelope"]["action"]["enum"]


def test_contract_lockstep_counts_are_28_and_7() -> None:
    root = Path(__file__).resolve().parents[2]
    schema = json.loads((root / "shared_specs" / "ws_rpc_schema.json").read_text("utf-8"))
    from pc_agent.core.protocol import RPC_ACTIONS, RPC_TYPES

    assert len(schema["envelope"]["action"]["enum"]) == 28
    assert len(schema["envelope"]["type"]["enum"]) == 7
    assert len(RPC_ACTIONS) == 28
    assert len(RPC_TYPES) == 7


def test_gallery_payload_schemas_exist_for_all_four_actions() -> None:
    root = Path(__file__).resolve().parents[2]
    schema = json.loads((root / "shared_specs" / "ws_rpc_schema.json").read_text("utf-8"))
    schemas = schema["payload_schemas"]
    for action in ("GALLERY_LIST_REQUEST", "GALLERY_LIST", "GALLERY_ADD", "GALLERY_SAVE"):
        assert action in schemas
    assert schemas["GALLERY_LIST"]["required"] == ["images"]
    assert schemas["GALLERY_LIST_REQUEST"]["properties"] == {}


def test_gallery_list_row_schema_matches_the_store_row() -> None:
    root = Path(__file__).resolve().parents[2]
    schema = json.loads((root / "shared_specs" / "ws_rpc_schema.json").read_text("utf-8"))
    item = schema["payload_schemas"]["GALLERY_LIST"]["properties"]["images"]["items"]
    assert set(item["required"]) == {
        "image_id",
        "title",
        "width",
        "height",
        "source",
        "created_at",
        "updated_at",
        "mime",
        "filename",
    }
    assert item["properties"]["source"]["enum"] == ["PASTE", "DROP", "CANVAS"]


def test_a_declared_transfer_is_claimed_before_its_bytes(sync) -> None:
    """Ordering is the contract: DocumentStore claims ASSET_* too."""
    gallery_sync, bus, _push = sync
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "GALLERY_ADD",
            {
                "image_id": "claim-me",
                "title": "claim",
                "width": 4,
                "height": 4,
                "source": SOURCE_PASTE,
                "filename": "claim.png",
                "mime": "image/png",
            },
        ),
    )
    assert gallery_sync.knows("claim-me") is True
    assert gallery_sync.knows("unknown-transfer") is False


def test_meta_records_which_mode_a_save_declared(sync) -> None:
    gallery_sync, bus, _push = sync
    bus.emit(
        RPC_MESSAGE,
        msg=envelope(
            "GALLERY_SAVE",
            {
                "image_id": "mode-probe",
                "title": "probe",
                "width": 4,
                "height": 4,
                "filename": "probe.png",
                "mime": "image/png",
                "mode": MODE_REPLACE,
            },
        ),
    )
    assert gallery_sync.meta_for("mode-probe")["mode"] == MODE_REPLACE


def test_dib_header_size_field_is_derived_from_the_bpp() -> None:
    assert clip.header_fields(clip.dib_header(2, 2, bpp=32))["biSizeImage"] == 16
    assert clip.header_fields(clip.dib_header(2, 2, bpp=24))["biSizeImage"] == 16


def test_dib_pixels_24bpp_drops_the_alpha_channel() -> None:
    image = Image.new("RGBA", (1, 1), (10, 20, 30, 0))
    assert clip.dib_pixels(image, bpp=24) == bytes((30, 20, 10))


def test_unknown_mime_still_yields_a_png_labelled_row(store: LibraryStore) -> None:
    """A stored row must never claim a format the file does not hold."""
    row = store.add(png_bytes(), filename="weird.bin")
    assert row["mime"] == "image/png"
    assert store.path_for(row).suffix == ".png"


def test_struct_layout_of_the_header_is_little_endian() -> None:
    header = clip.dib_header(258, 300)
    assert struct.unpack_from("<I", header, 0)[0] == 40
    assert struct.unpack_from("<i", header, 4)[0] == 258
    assert struct.unpack_from("<i", header, 8)[0] == 300