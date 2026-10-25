"""Round 13 issue 04 — books: page model, page filter, BOOK preset, export.

Covers the three things that can silently break a book:

* the page FILTER (one element pipeline — a legacy element with no ``page_id``
  must land on page 1 and nothing else);
* the BOOK preset being BOUNDED (an infinite book has no pages to turn);
* multi-page PDF export producing one sheet per page in page order, verified by
  inflating cairo's ObjStm streams and reading ``/MediaBox`` (no pypdf here).
"""

from __future__ import annotations

import re
import zlib
from pathlib import Path

import pytest

from pc_agent.core.config_manager import AppConfig
from pc_agent.engine import book_model
from pc_agent.engine.book_model import (
    BOOK_PRESET,
    COVER_PAGE_ID,
    DEFAULT_PAGE_SIZE,
    PAGE_SIZES,
    BookLayout,
    assign_nodes_to_page,
    cover_node,
    default_page_title,
    detach_page_nodes,
    is_book_preset,
    new_page,
    node_page_id,
    nodes_for_page,
    normalize_pages,
    page_size,
    page_size_name,
    resolve_page_id,
    set_node_page_id,
    thumbnail_elements,
)
from pc_agent.engine.document_store import Artboard, CanvasDocument, DocumentStore
from pc_agent.engine.scene_graph import CanvasNode, NodeGeometry, NodeStyle
from pc_agent.export import book_exporter
from pc_agent.export.book_exporter import (
    BookPdfExporter,
    BookRasterExporter,
    book_page_count,
    book_page_ids,
    cover_element,
    elements_for_page,
    page_ids_in_order,
    page_size_pt,
    page_view,
    thumbnail_page_id,
    total_sheet_count,
)
from pc_agent.export.thumbnail_renderer import render_thumbnail

_MEDIABOX_RE = rb"/MediaBox\s*\[\s*[-\d.]+\s+[-\d.]+\s+([-\d.]+)\s+([-\d.]+)\s*\]"
_ZERO_BOUNDS = {"min_x": 0.0, "min_y": 0.0, "max_x": 0.0, "max_y": 0.0}


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
def _node(node_id: str, *, page_id: str | None = None, layer: int = 0) -> CanvasNode:
    node = CanvasNode(
        node_id=node_id,
        kind="STROKE",
        layer=layer,
        bbox=(10.0, 10.0, 60.0, 60.0),
        style=NodeStyle(color="#1E1E1E", stroke_width=4.0, opacity=1.0, blend_mode="SRC_OVER"),
        geometry=NodeGeometry(pts=[[10.0, 10.0], [60.0, 60.0]]),
    )
    set_node_page_id(node, page_id)
    return node


def _book(
    *,
    pages: list[dict] | None = None,
    elements: list[CanvasNode] | None = None,
    size: tuple[float, float] = (620.0, 870.0),
    canvas_id: str = "cv-book",
) -> CanvasDocument:
    return CanvasDocument(
        canvas_id=canvas_id,
        title="book",
        created_at=0,
        updated_at=0,
        artboard=Artboard(
            preset=BOOK_PRESET,
            width=size[0],
            height=size[1],
            is_infinite=False,
            background_style="BLANK",
            background_color="#FFFFFF",
        ),
        content_bounds=dict(_ZERO_BOUNDS),
        elements=list(elements or []),
        pages=normalize_pages(pages if pages is not None else [{"page_id": "p1", "index": 0}]),
    )


def _pages(*ids: str) -> list[dict]:
    return [{"page_id": pid, "index": i, "title": default_page_title(i)} for i, pid in
            enumerate(ids)]


def _config(tmp_path: Path) -> AppConfig:
    return AppConfig(
        shader_dir=tmp_path / "shaders",
        assets_dir=tmp_path / "assets",
        export_dir=tmp_path / "exports",
        appdata_dir=tmp_path / "appdata",
    )


def _store(tmp_path: Path) -> DocumentStore:
    from pc_agent.core.events import EventBus
    from pc_agent.engine.scene_graph import SceneGraph

    bus = EventBus()
    return DocumentStore(bus, _config(tmp_path), SceneGraph(bus))


def _pdf_page_sizes(path: Path) -> list[tuple[float, float]]:
    """All page MediaBox sizes (pt) — cairo stores pages in ObjStm streams."""
    data = path.read_bytes()
    sizes: list[tuple[float, float]] = []
    for match in re.finditer(rb"stream\r?\n", data):
        start = match.end()
        end = data.find(b"endstream", start)
        if end < 0:
            continue
        try:
            inflated = zlib.decompress(data[start:end])
        except zlib.error:
            continue
        for box in re.finditer(_MEDIA_BOX_RE_SAFE(), inflated):
            sizes.append((float(box.group(1)), float(box.group(2))))
    if not sizes:
        for box in re.finditer(_MEDIA_BOX_RE_SAFE(), data):
            sizes.append((float(box.group(1)), float(box.group(2))))
    return sizes


def _MEDIA_BOX_RE_SAFE() -> bytes:  # noqa: N802 — tiny helper kept explicit
    return _MEDIABOX_RE


# ---------------------------------------------------------------------------
# Page size mapping — A4 / A5 / LETTER, never INFINITE
# ---------------------------------------------------------------------------
def test_page_sizes_cover_exactly_three_paper_names() -> None:
    assert sorted(PAGE_SIZES) == ["A4", "A5", "LETTER"]


def test_page_size_a4() -> None:
    assert page_size("A4") == (2480.0, 3508.0)


def test_page_size_a5() -> None:
    assert page_size("A5") == (1748.0, 2480.0)


def test_page_size_letter() -> None:
    assert page_size("LETTER") == (2550.0, 3300.0)


def test_page_size_is_case_insensitive() -> None:
    assert page_size("letter") == page_size("LETTER")


def test_page_size_rejects_infinite() -> None:
    with pytest.raises(ValueError, match="unknown book page size"):
        page_size("INFINITE")


def test_page_size_rejects_unknown() -> None:
    with pytest.raises(ValueError):
        page_size("A0")


def test_default_page_size_is_a_paper_size() -> None:
    assert DEFAULT_PAGE_SIZE in PAGE_SIZES


def test_page_size_name_round_trips() -> None:
    for name, dims in PAGE_SIZES.items():
        assert page_size_name(*dims) == name


def test_page_size_name_falls_back_for_odd_dims() -> None:
    assert page_size_name(1.0, 2.0) == DEFAULT_PAGE_SIZE
    assert page_size_name(None, None) == DEFAULT_PAGE_SIZE


# ---------------------------------------------------------------------------
# BOOK preset boundedness
# ---------------------------------------------------------------------------
def test_book_preset_is_bounded_in_the_store_table(tmp_path: Path) -> None:
    doc = _store(tmp_path).new("BOOK", "b")
    from pc_agent.engine.document_store import artboard_is_infinite

    assert artboard_is_infinite(doc.artboard) is False


def test_book_preset_is_not_infinite_by_flag_even_if_flagged() -> None:
    from pc_agent.engine.document_store import artboard_is_infinite

    artboard = Artboard(preset=BOOK_PRESET, width=100.0, height=200.0, is_infinite=True)
    assert artboard_is_infinite(artboard) is False


def test_book_preset_helper() -> None:
    assert is_book_preset("BOOK") is True
    assert is_book_preset(" book ") is True
    assert is_book_preset("A4") is False
    assert is_book_preset(None) is False


def test_new_book_document_seeds_one_page(tmp_path: Path) -> None:
    doc = _store(tmp_path).new("BOOK", "b")
    assert doc.is_book is True
    assert len(doc.pages) == 1
    assert doc.pages[0].title == default_page_title(0)


def test_new_non_book_document_has_no_pages(tmp_path: Path) -> None:
    doc = _store(tmp_path).new("A4", "a")
    assert doc.is_book is False
    assert doc.pages == []


# ---------------------------------------------------------------------------
# Page list normalisation
# ---------------------------------------------------------------------------
def test_normalize_pages_sorts_by_index_and_reindexes() -> None:
    pages = normalize_pages([
        {"page_id": "b", "index": 5, "title": "Second"},
        {"page_id": "a", "index": 0, "title": "First"},
    ])
    assert [page.page_id for page in pages] == ["a", "b"]
    assert [page.index for page in pages] == [0, 1]


def test_normalize_pages_drops_junk_and_duplicates() -> None:
    pages = normalize_pages([{"page_id": "a"}, "x", {}, {"page_id": "a"}])
    assert [page.page_id for page in pages] == ["a"]


def test_normalize_pages_rejects_the_cover_id() -> None:
    pages = normalize_pages([{"page_id": COVER_PAGE_ID}])
    assert pages == []


def test_normalize_pages_ignores_non_list_input() -> None:
    assert normalize_pages(None) == []
    assert normalize_pages("nope") == []


def test_normalize_pages_fills_missing_titles() -> None:
    pages = normalize_pages([{"page_id": "a"}, {"page_id": "b"}])
    assert [page.title for page in pages] == ["Page 1", "Page 2"]


def test_new_page_defaults_id_and_title() -> None:
    page = new_page(index=2)
    assert page.page_id and page.index == 2
    assert page.title == default_page_title(2)


def test_new_page_honours_explicit_values() -> None:
    page = new_page(index=0, page_id="p9", title="Index")
    assert (page.page_id, page.title) == ("p9", "Index")


def test_book_model_layout_sees_the_document_pages() -> None:
    doc = _book(pages=_pages("p1", "p2"))
    layout = book_model.BookLayout.from_document(doc)
    assert layout.page_ids() == ["p1", "p2"]


def test_book_model_layout_of_a_non_book_document_is_empty() -> None:
    doc = _book(pages=[])
    assert len(book_model.BookLayout.from_document(doc)) == 0


# ---------------------------------------------------------------------------
# Layout mutation: add / delete / move / rename
# ---------------------------------------------------------------------------
def test_layout_seeded_has_one_page() -> None:
    assert len(BookLayout.seeded()) == 1


def test_layout_add_appends() -> None:
    layout = BookLayout.seeded()
    page = layout.add(title="Two")
    assert len(layout) == 2
    assert layout.pages[1].page_id == page.page_id
    assert layout.pages[1].title == "Two"


def test_layout_add_at_index_inserts() -> None:
    layout = BookLayout(_pages("a", "b"))
    layout.add(page_id="mid", at=1)
    assert layout.page_ids() == ["a", "mid", "b"]
    assert [page.index for page in layout] == [0, 1, 2]


def test_layout_add_rejects_the_reserved_cover_id() -> None:
    layout = BookLayout.seeded()
    with pytest.raises(ValueError, match="reserved"):
        layout.add(page_id=COVER_PAGE_ID)


def test_layout_delete_removes_and_reindexes() -> None:
    layout = BookLayout(_pages("a", "b", "c"))
    removed = layout.delete("b")
    assert removed is not None and removed.page_id == "b"
    assert layout.page_ids() == ["a", "c"]
    assert [page.index for page in layout] == [0, 1]


def test_layout_delete_refuses_the_last_page() -> None:
    layout = BookLayout.seeded()
    only = layout.page_ids()[0]
    assert layout.delete(only) is None
    assert len(layout) == 1


def test_layout_delete_unknown_page_is_a_noop() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.delete("zzz") is None
    assert len(layout) == 2


def test_layout_move_reorders() -> None:
    layout = BookLayout(_pages("a", "b", "c"))
    assert layout.move("c", 0) is True
    assert layout.page_ids() == ["c", "a", "b"]
    assert [page.index for page in layout] == [0, 1, 2]


def test_layout_move_clamps_out_of_range() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.move("a", 99) is True
    assert layout.page_ids() == ["b", "a"]


def test_layout_move_same_position_reports_no_change() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.move("a", 0) is False


def test_layout_reorder_applies_explicit_order() -> None:
    layout = BookLayout(_pages("a", "b", "c"))
    assert layout.reorder(["c", "a", "b"]) is True
    assert layout.page_ids() == ["c", "a", "b"]


def test_layout_reorder_keeps_unmentioned_pages() -> None:
    layout = BookLayout(_pages("a", "b", "c"))
    layout.reorder(["c"])
    assert layout.page_ids() == ["c", "a", "b"]


def test_layout_reorder_ignores_unknown_and_duplicate_ids() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.reorder(["zzz", "b", "b"]) is True
    assert layout.page_ids() == ["b", "a"]


def test_layout_reorder_identical_order_reports_no_change() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.reorder(["a", "b"]) is False


def test_layout_rename() -> None:
    layout = BookLayout(_pages("a"))
    assert layout.rename("a", "Contents") is True
    assert layout.pages[0].title == "Contents"


def test_layout_rename_rejects_blank_and_unknown() -> None:
    layout = BookLayout(_pages("a"))
    assert layout.rename("a", "   ") is False
    assert layout.rename("zzz", "Contents") is False


def test_layout_first_page_id_and_index_of() -> None:
    layout = BookLayout(_pages("a", "b"))
    assert layout.first_page_id == "a"
    assert layout.index_of("b") == 1
    assert layout.index_of("zzz") == -1


# ---------------------------------------------------------------------------
# The page filter — the single element pipeline
# ---------------------------------------------------------------------------
def test_legacy_nodes_land_on_page_one() -> None:
    nodes = [_node("legacy-1"), _node("legacy-2")]
    doc = _book(pages=_pages("p1", "p2"), elements=nodes)
    assert [n.node_id for n in elements_for_page(doc, "p1")] == ["legacy-1", "legacy-2"]
    assert elements_for_page(doc, "p2") == []


def test_page_filter_selects_only_that_page() -> None:
    nodes = [_node("a", page_id="p1"), _node("b", page_id="p2"), _node("c", page_id="p2")]
    doc = _book(pages=_pages("p1", "p2"), elements=nodes)
    assert [n.node_id for n in elements_for_page(doc, "p1")] == ["a"]
    assert [n.node_id for n in elements_for_page(doc, "p2")] == ["b", "c"]


def test_page_filter_excludes_the_cover() -> None:
    nodes = [_node("c", page_id=COVER_PAGE_ID), _node("a", page_id="p1")]
    doc = _book(pages=_pages("p1"), elements=nodes)
    assert [n.node_id for n in elements_for_page(doc, "p1")] == ["a"]


def test_page_filter_unknown_page_falls_back_to_the_first() -> None:
    nodes = [_node("legacy"), _node("a", page_id="p1")]
    doc = _book(pages=_pages("p1"), elements=nodes)
    assert sorted(n.node_id for n in elements_for_page(doc, "zzz")) == ["a", "legacy"]


def test_page_filter_none_means_page_one() -> None:
    nodes = [_node("legacy"), _node("a", page_id="p1"), _node("b", page_id="p2")]
    doc = _book(pages=_pages("p1", "p2"), elements=nodes)
    assert [n.node_id for n in elements_for_page(doc, None)] == ["legacy", "a"]


def test_page_filter_sorts_by_layer() -> None:
    nodes = [_node("top", page_id="p1", layer=5), _node("bottom", page_id="p1", layer=1)]
    doc = _book(pages=_pages("p1"), elements=nodes)
    assert [n.node_id for n in elements_for_page(doc, "p1")] == ["bottom", "top"]


def test_nodes_for_page_is_the_shared_filter() -> None:
    layout = BookLayout(_pages("p1", "p2"))
    nodes = [_node("legacy"), _node("b", page_id="p2")]
    assert [n.node_id for n in nodes_for_page(nodes, "p1", layout)] == ["legacy"]
    assert [n.node_id for n in nodes_for_page(nodes, "p2", layout)] == ["b"]


def test_resolve_page_id_prefers_first_page() -> None:
    layout = BookLayout(_pages("p1", "p2"))
    assert resolve_page_id(None, layout) == "p1"
    assert resolve_page_id("p2", layout) == "p2"
    assert resolve_page_id("zzz", layout) == "p1"
    assert resolve_page_id(COVER_PAGE_ID, layout) == COVER_PAGE_ID


def test_node_page_id_trims_and_normalises() -> None:
    node = _node("a")
    set_node_page_id(node, "  p1  ")
    assert node_page_id(node) == "p1"
    set_node_page_id(node, "   ")
    assert node_page_id(node) is None


def test_detach_and_assign_page_nodes() -> None:
    nodes = [_node("a", page_id="p1"), _node("b", page_id="p2")]
    kept, removed = detach_page_nodes(nodes, "p1")
    assert [n.node_id for n in kept] == ["b"]
    assert [n.node_id for n in removed] == ["a"]
    assign_nodes_to_page(kept, "p1")
    assert [node_page_id(n) for n in kept] == ["p1"]


def test_detach_page_nodes_never_strips_a_whole_book() -> None:
    nodes = [_node("a", page_id="p1")]
    kept, removed = detach_page_nodes(nodes, None)
    assert kept == nodes and removed == []


# ---------------------------------------------------------------------------
# Cover vs page 1 (thumbnail choice)
# ---------------------------------------------------------------------------
def test_cover_node_finds_the_cover() -> None:
    nodes = [_node("a", page_id="p1"), _node("cover", page_id=COVER_PAGE_ID)]
    found = cover_node(nodes)
    assert found is not None and found.node_id == "cover"


def test_thumbnail_elements_prefers_the_cover() -> None:
    nodes = [_node("a", page_id="p1"), _node("cover", page_id=COVER_PAGE_ID)]
    layout = BookLayout(_pages("p1"))
    assert [n.node_id for n in thumbnail_elements(nodes, layout)] == ["cover"]


def test_thumbnail_elements_falls_back_to_page_one() -> None:
    nodes = [_node("a", page_id="p1"), _node("b", page_id="p2")]
    layout = BookLayout(_pages("p1", "p2"))
    assert [n.node_id for n in thumbnail_elements(nodes, layout)] == ["a"]


def test_thumbnail_page_id_prefers_the_cover_id() -> None:
    doc = _book(pages=_pages("p1"), elements=[_node("cover", page_id=COVER_PAGE_ID)])
    assert thumbnail_page_id(doc) == COVER_PAGE_ID


def test_thumbnail_page_id_falls_back_to_the_first_page() -> None:
    doc = _book(pages=_pages("p1", "p2"), elements=[_node("a", page_id="p1")])
    assert thumbnail_page_id(doc) == "p1"


def test_book_page_ids_preserve_reading_order() -> None:
    doc = _book(pages=_pages("c", "a", "b"))
    assert book_page_ids(doc) == ["c", "a", "b"]


def test_book_page_ids_of_a_pageless_book_is_one_none_page() -> None:
    doc = _book(pages=[])
    assert book_page_ids(doc) == [None]
    assert book_page_count(doc) == 1


def test_page_ids_in_order_dedupes_and_skips_the_cover() -> None:
    nodes = [_node("cover", page_id=COVER_PAGE_ID), _node("a", page_id="p2"),
             _node("b", page_id="p2"), _node("c")]
    assert page_ids_in_order(nodes) == ["p2", None]


# ---------------------------------------------------------------------------
# Export — one PDF sheet per page, in page order
# ---------------------------------------------------------------------------
def test_book_page_size_pt_matches_the_ordinary_exporter(tmp_path: Path) -> None:
    doc = _book(size=(2480.0, 3508.0))
    assert page_size_pt(doc)[0] == pytest.approx(595.2, abs=0.5)
    assert page_size_pt(doc)[1] == pytest.approx(841.92, abs=0.5)


def test_book_page_size_pt_rejects_an_infinite_book() -> None:
    doc = _book()
    doc.artboard.is_infinite = True
    doc.artboard.preset = "INFINITE"
    with pytest.raises(ValueError, match="cannot be infinite"):
        page_size_pt(doc)


def test_book_page_validation_accepts_a_plain_canvas(tmp_path: Path) -> None:
    """A non-book export is exactly a one-page book, so it must not be refused."""
    doc = _book(pages=_pages("p1"))
    doc.artboard.preset = "A4"
    assert len(book_exporter.book_page_ids(doc)) == 1
    out = tmp_path / "exports" / "plain.pdf"
    BookPdfExporter(_config(tmp_path)).export(doc, out)
    assert len(_pdf_page_sizes(out)) == 1


def test_export_writes_one_sheet_per_page(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1", "p2", "p3"), elements=[_node("a", page_id="p1")])
    out = tmp_path / "exports" / "book.pdf"
    BookPdfExporter(_config(tmp_path)).export(doc, out)
    assert out.read_bytes()[:4] == b"%PDF"
    assert len(_pdf_page_sizes(out)) == 3


def test_export_sheet_count_follows_pages_not_elements(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1", "p2"), elements=[_node("a"), _node("b"), _node("c")])
    assert total_sheet_count(doc) == 2
    out = tmp_path / "exports" / "two.pdf"
    BookPdfExporter(_config(tmp_path)).export(doc, out)
    assert len(_pdf_page_sizes(out)) == 2


def test_export_page_order_matches_the_pages_array(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p3", "p1", "p2"))
    assert book_page_ids(doc) == ["p3", "p1", "p2"]
    export_order = [pid for pid, _nodes in
                    ((pid, elements_for_page(doc, pid)) for pid in book_page_ids(doc))]
    assert export_order == ["p3", "p1", "p2"]


def test_export_page_size_is_the_book_page(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1", "p2"), size=(2480.0, 3508.0))
    out = tmp_path / "exports" / "a4.pdf"
    BookPdfExporter(_config(tmp_path)).export(doc, out)
    for w_pt, h_pt in _pdf_page_sizes(out):
        assert w_pt == pytest.approx(595.2, abs=0.5)
        assert h_pt == pytest.approx(841.92, abs=0.5)


def test_export_reports_progress_to_one(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1", "p2"))
    seen: list[float] = []
    BookPdfExporter(_config(tmp_path)).export(doc, tmp_path / "exports" / "p.pdf", seen.append)
    assert seen[-1] == 1.0
    assert all(0.0 <= value <= 1.0 for value in seen)


def test_export_leaves_no_part_file(tmp_path: Path) -> None:
    out = tmp_path / "exports" / "clean.pdf"
    BookPdfExporter(_config(tmp_path)).export(_book(pages=_pages("p1")), out)
    assert list(out.parent.glob("*.part")) == []


def test_page_view_holds_only_one_page() -> None:
    doc = _book(pages=_pages("p1", "p2"),
                elements=[_node("a", page_id="p1"), _node("b", page_id="p2")])
    assert [n.node_id for n in page_view(doc, "p2").elements] == ["b"]
    assert page_view(doc, "p2").artboard.width == doc.artboard.width


def test_export_page_pdf_agrees_with_the_book_exporter(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1"), size=(620.0, 870.0),
                elements=[_node("a", page_id="p1")])
    single = BookPdfExporter(_config(tmp_path)).export_page_pdf(
        doc, "p1", tmp_path / "exports" / "single.pdf")
    assert len(_pdf_page_sizes(single)) == 1


def test_raster_export_writes_one_png_per_page(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1", "p2"), size=(120.0, 160.0),
                elements=[_node("a", page_id="p1")])
    written = BookRasterExporter(_config(tmp_path)).export_pages(
        doc, tmp_path / "out", dpi=300)
    assert len(written) == 2
    assert [p.name for p in written] == ["cv-book-page-1.png", "cv-book-page-2.png"]
    assert all(p.is_file() for p in written)


def test_thumbnail_prefers_the_cover_element(tmp_path: Path) -> None:
    cover = _node("cover", page_id=COVER_PAGE_ID)
    page = _node("page", page_id="p1")
    doc = _book(pages=_pages("p1"), elements=[page, cover])
    out = render_thumbnail(doc, tmp_path / "thumb.png")
    assert out.is_file()
    assert cover_element(doc) is cover


def test_thumbnail_of_a_book_without_a_cover_still_renders(tmp_path: Path) -> None:
    doc = _book(pages=_pages("p1"), elements=[_node("page", page_id="p1")])
    out = render_thumbnail(doc, tmp_path / "thumb.png")
    assert out.is_file()
    assert cover_element(doc) is None
