"""Round 13 issue 04 — multi-page PDF (and per-page raster) export of a book.

A book is an ordinary document plus ``pages``, so exporting one is *not* a new
renderer: every page is drawn by the same code that draws a single-page canvas.
This module only decides **how many sheets there are and in what order**, then
hands each page's elements to the vector exporter's own drawing helpers.

The vector surface is shared because that is the one thing a per-page call
cannot do — :class:`VectorPdfExporter` owns exactly one ``PDFSurface`` per call,
so composing it per page would produce N files and no PDF library is available
to concatenate them. The drawing, tiling, background and boundary code is reused
verbatim from ``vector_pdf_exporter``; only the loop-over-pages is new.

For raster output the situation is the reverse: ``TiledRasterExporter`` already
writes one file per call, so each page is exported through it with a
single-page view of the document, which is genuine reuse rather than
reimplementation.
"""

from __future__ import annotations

import math
from dataclasses import replace
from pathlib import Path
from typing import Callable, Iterable, Sequence
from uuid import uuid4

import cairo

from pc_agent.core.config_manager import AppConfig
from pc_agent.engine.book_model import (
    BOOK_PRESET,
    COVER_PAGE_ID,
    BookLayout,
    nodes_for_page,
)
from pc_agent.engine.document_store import CanvasDocument, artboard_is_infinite
from pc_agent.engine.scene_graph import CanvasNode
from pc_agent.export.tiled_raster_exporter import TiledRasterExporter
from pc_agent.export.vector_pdf_exporter import (
    PAGE_PT_LIMIT,
    UNIT_TO_PT,
    VectorPdfExporter,
    _draw_background,
    _draw_node,
    _page_extent,
    _Throttle,
    _tile_pages,
)


def book_layout(doc: CanvasDocument) -> BookLayout:
    """Page layout of ``doc``; a page-less book falls back to "one page"."""
    return BookLayout.from_document(doc)


def book_page_ids(doc: CanvasDocument) -> list[str | None]:
    """Page ids of ``doc`` in export order.

    A book whose ``pages`` list is missing (or empty) still exports: it becomes a
    single page addressed by ``None``, which is what every page-less element
    means anyway. Returning ``None`` there keeps the exporter's ordering honest
    instead of inventing an id the document does not have.
    """
    layout = book_layout(doc)
    ids = layout.page_ids()
    if ids:
        return list(ids)
    return [None]


def book_page_count(doc: CanvasDocument) -> int:
    """Number of sheets a book export produces (≥ 1)."""
    return len(book_page_ids(doc))


def elements_for_page(doc: CanvasDocument, page_id: str | None) -> list[CanvasNode]:
    """The elements of one page, in layer order.

    Goes through the single page filter, so an element with no ``page_id`` lands
    on page 1 and the cover never appears on any sheet.
    """
    layout = book_layout(doc)
    page_nodes = nodes_for_page(doc.elements, page_id, layout)
    return sorted(page_nodes, key=lambda node: node.layer)


def page_view(doc: CanvasDocument, page_id: str | None) -> CanvasDocument:
    """A shallow copy of ``doc`` holding only one page's elements.

    Used to hand a single page to an exporter that only knows about documents.
    The copy shares node objects (no deep copy) because nothing here mutates
    them, and the artboard is untouched so every page keeps the book's size.
    """
    return replace(doc, elements=elements_for_page(doc, page_id))


def _part_path(out_path: Path) -> Path:
    """``.part`` temp sibling of ``out_path`` (never left behind on failure)."""
    return out_path.parent / f".{out_path.stem}.{uuid4().hex}.part"


def _validate_book(doc: CanvasDocument) -> tuple[float, float, float, float]:
    """World extent of one book page; ``ValueError`` for a degenerate book."""
    if artboard_is_infinite(doc.artboard):
        raise ValueError("a book page cannot be infinite")
    if str(doc.artboard.preset or "").upper() != BOOK_PRESET:
        # Allowed on purpose: exporting a normal canvas happens to be exactly a
        # one-page book, and refusing would make callers branch needlessly.
        pass
    return _page_extent(doc)


def page_size_pt(doc: CanvasDocument) -> tuple[float, float]:
    """Size of one exported book page in points (same policy as Doc 14)."""
    extent = _validate_book(doc)
    return (
        (extent[2] - extent[0]) * UNIT_TO_PT,
        (extent[3] - extent[1]) * UNIT_TO_PT,
    )


def _page_tiles(doc: CanvasDocument) -> list[tuple[int, int, float, float]]:
    """Tiles of ONE book page, so a huge page size still fits a PDF sheet."""
    w_pt, h_pt = page_size_pt(doc)
    return _tile_pages(w_pt, h_pt)


def total_sheet_count(doc: CanvasDocument) -> int:
    """PDF sheets across the whole book (pages × tiles per page)."""
    return book_page_count(doc) * len(_page_tiles(doc))


def cover_element(doc: CanvasDocument) -> CanvasNode | None:
    """The cover element of ``doc``, when it has one."""
    for node in doc.elements:
        if getattr(node, "page_id", None) == COVER_PAGE_ID:
            return node
    return None


def thumbnail_page_id(doc: CanvasDocument) -> str | None:
    """Page the gallery thumbnail should show: cover wins, else page 1.

    Returned as an id so the caller can filter; ``COVER_PAGE_ID`` means "draw
    only the cover element".
    """
    if cover_element(doc) is not None:
        return COVER_PAGE_ID
    ids = book_page_ids(doc)
    return ids[0] if ids else None


class BookPdfExporter:
    """Doc-14-compatible exporter that writes one PDF sheet per book page."""

    def __init__(self, config: AppConfig) -> None:
        self._config = config

    def export(
        self,
        doc: CanvasDocument,
        out_path: Path,
        progress: Callable[[float], None] | None = None,
    ) -> Path:
        """Write ``doc`` to ``out_path``; one sheet per page, in page order.

        Raises ``ValueError("empty canvas")`` for a degenerate book and
        ``ValueError("a book page cannot be infinite")`` for an unbounded one —
        a fold needs paper, so an infinite book is a contradiction rather than a
        special case.
        """
        out_path = Path(out_path)
        extent = _validate_book(doc)
        w_u = extent[2] - extent[0]
        h_u = extent[3] - extent[1]
        tiles = _page_tiles(doc)
        nx = max(1, math.ceil(page_size_pt(doc)[0] / PAGE_PT_LIMIT))
        ny = max(1, math.ceil(page_size_pt(doc)[1] / PAGE_PT_LIMIT))
        tile_w_u = w_u / nx
        tile_h_u = h_u / ny
        tile_w_pt = tile_w_u * UNIT_TO_PT

        out_path.parent.mkdir(parents=True, exist_ok=True)
        part = _part_path(out_path)
        page_ids = book_page_ids(doc)
        pages: Sequence[tuple[str | None, list[CanvasNode]]] = [
            (page_id, elements_for_page(doc, page_id)) for page_id in page_ids
        ]
        sheets = max(1, len(pages) * len(tiles))
        assets_root = self._config.assets_dir / doc.canvas_id
        throttle = _Throttle(progress)
        artboard = doc.artboard
        board_w = float(artboard.width or 0.0)
        board_h = float(artboard.height or 0.0)

        surface = cairo.PDFSurface(str(part), tile_w_pt, tile_h_u * UNIT_TO_PT)
        ctx = cairo.Context(surface)
        sheet = 0
        try:
            for page_id, page_nodes in pages:
                for _idx, _count, off_x, off_y in tiles:
                    ox = extent[0] + off_x
                    oy = extent[1] + off_y
                    ctx.save()
                    ctx.identity_matrix()
                    ctx.scale(UNIT_TO_PT, UNIT_TO_PT)
                    _draw_background(ctx, artboard, tile_w_u, tile_h_u)
                    ctx.translate(-ox, -oy)
                    # A page is drawn whole: it was already filtered by page, so
                    # there is nothing outside this sheet to cull.
                    for node in page_nodes:
                        _draw_node(ctx, node, assets_root)
                    ctx.set_source_rgba(0.25, 0.25, 0.3, 1.0)
                    ctx.set_line_width(1.5)
                    ctx.rectangle(0.0, 0.0, board_w, board_h)
                    ctx.stroke()
                    ctx.restore()
                    ctx.show_page()
                    sheet += 1
                    throttle.maybe(sheet / sheets)
            throttle.finish()
            surface.finish()
            part.replace(out_path)
            return out_path
        finally:
            surface.finish()
            try:
                part.unlink(missing_ok=True)
            except OSError:
                pass

    def export_page_pdf(self, doc: CanvasDocument, page_id: str | None, out_path: Path) -> Path:
        """One page through the ordinary single-page vector exporter.

        Kept public because it is the cheapest way for a caller (or a test) to
        prove the book exporter agrees with the non-book one: the same page must
        come out byte-comparable whichever route is used.
        """
        single = page_view(doc, page_id)
        return VectorPdfExporter(self._config).export(single, out_path)


class BookRasterExporter:
    """Per-page PNG export that delegates each page to the tiled rasteriser."""

    def __init__(self, config: AppConfig) -> None:
        self._config = config

    def export_pages(
        self,
        doc: CanvasDocument,
        out_dir: Path,
        dpi: int = 300,
        progress: Callable[[float], None] | None = None,
    ) -> list[Path]:
        """Write ``<out_dir>/<canvas_id>-page-N.png`` for every page, in order."""
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        page_ids = book_page_ids(doc)
        exporter = TiledRasterExporter(self._config)
        written: list[Path] = []
        for index, page_id in enumerate(page_ids):
            single = page_view(doc, page_id)
            target = out_dir / f"{doc.canvas_id}-page-{index + 1}.png"
            exporter.export(single, dpi, target)
            written.append(target)
            if progress is not None:
                progress(min(1.0, (index + 1) / max(1, len(page_ids))))
        return written


def page_ids_in_order(elements: Iterable[CanvasNode]) -> list[str | None]:
    """Distinct page ids present on ``elements``, page-less first.

    A book's ``pages`` array is authoritative for order, but a caller holding
    only a bare element list (an archive fragment, a sync payload) can still
    recover which pages exist — page-less elements mean page 1, so they sort
    first.
    """
    seen: list[str | None] = []
    for node in elements:
        owner = getattr(node, "page_id", None)
        key = owner if isinstance(owner, str) and owner else None
        if key == COVER_PAGE_ID:
            continue
        if key not in seen:
            seen.append(key)
    return seen
