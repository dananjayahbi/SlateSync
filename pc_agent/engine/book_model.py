"""Round 13 issue 04 — multi-page books on top of the ordinary canvas document.

A book is **not** a second document type. It is a normal ``CanvasDocument``
(elements, style, geometry, exporters all unchanged) plus:

* ``artboard.preset == "BOOK"`` — bounded, like A4. A book never becomes an
  infinite canvas, so every bounded code path (page rect, export extent,
  thumbnail view) keeps working untouched;
* an ordered ``pages`` array of ``{page_id, index, title}``;
* an optional ``page_id`` on each element. Absent/null means the *first* page,
  which is exactly what an element in a pre-round-13 document means, so those
  documents keep loading with no migration at all.

The single element pipeline is the point: "which page am I on" is a FILTER over
one element list, never a second storage path. Every consumer (renderer,
exporter, thumbnail, page strip) asks :func:`nodes_for_page` instead of
branching on "is this a book".

Two deliberate choices worth recording:

* ``COVER_PAGE_ID`` is a reserved *page id value*, not a new field. The cover is
  an ordinary IMAGE element carrying that value, so it rides the existing
  archive asset embedding (``saveDocument`` walks ``geometry.asset_ref``) and
  is skipped by every page filter. A separate ``cover_asset_ref`` document key
  would have needed new plumbing in three frozen save paths and would still
  have had to explain why the bytes were never archived.
* ``PAGE_SIZES`` has A4/A5/LETTER and nothing else. Infinite books are
  deliberately unrepresentable — :func:`page_size` raises rather than silently
  falling back to an unbounded page.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

#: Artboard preset key for a book (bounded; registered in the preset table).
BOOK_PRESET = "BOOK"

#: Reserved ``page_id`` carrying the cover image. Never a real page: no page in
#: a book may use this id, so the cover is filtered out of every page view.
COVER_PAGE_ID = "__cover__"

#: Selectable book page sizes (300-DPI world units, Doc 03 preset matrix).
#: Deliberately no INFINITE entry — the brief forbids an infinite book.
PAGE_SIZES: dict[str, tuple[float, float]] = {
    "A4": (2480.0, 3508.0),
    "A5": (1748.0, 2480.0),
    "LETTER": (2550.0, 3300.0),
}

#: Page size used when a caller does not choose one.
DEFAULT_PAGE_SIZE = "A4"


def is_book_preset(preset: object) -> bool:
    """True when ``preset`` names the bounded book artboard."""
    return str(preset or "").strip().upper() == BOOK_PRESET


def page_size(name: object) -> tuple[float, float]:
    """World-unit page size for a book page size name.

    Raises ``ValueError`` for anything outside A4/A5/LETTER — including
    ``INFINITE``, which is exactly the option a book must never offer.
    """
    key = str(name or "").strip().upper()
    try:
        return PAGE_SIZES[key]
    except KeyError as exc:
        raise ValueError(
            f"unknown book page size {name!r}; expected one of {sorted(PAGE_SIZES)}"
        ) from exc


def page_size_name(width: object, height: object) -> str:
    """Best-effort reverse lookup of a page size name for dims (book defaults)."""
    try:
        w = round(float(width))  # type: ignore[arg-type]
        h = round(float(height))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_PAGE_SIZE
    for name, (size_w, size_h) in PAGE_SIZES.items():
        if round(size_w) == w and round(size_h) == h:
            return name
    return DEFAULT_PAGE_SIZE


def default_page_title(index: int) -> str:
    """``Page 1``-style title for the page at ``index`` (0-based)."""
    return f"Page {max(0, int(index)) + 1}"


@dataclass
class BookPage:
    """One page entry of a book document (``pages[]`` element on the wire)."""

    page_id: str
    index: int = 0
    title: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "page_id": self.page_id,
            "index": int(self.index),
            "title": self.title,
        }


def new_page(
    *,
    index: int = 0,
    page_id: str | None = None,
    title: str | None = None,
) -> BookPage:
    """Fresh page; a missing id becomes a uuid4 and a missing title a default."""
    return BookPage(
        page_id=str(page_id) if page_id else str(uuid.uuid4()),
        index=max(0, int(index)),
        title=title if title is not None else default_page_title(index),
    )


def normalize_pages(value: object) -> list[BookPage]:
    """Tolerant ``pages`` reader: order by ``index``, drop junk, reindex densely.

    A hand-edited or future document must never fail to open, so entries that
    are not objects (or carry no usable id) are skipped rather than raising.
    Duplicate ids keep their first occurrence: two pages sharing an id would
    make every element on them indistinguishable.
    """
    if isinstance(value, BookLayout):
        return value.pages
    if not isinstance(value, (list, tuple)):
        return []
    entries: list[tuple[int, int, BookPage]] = []
    seen: set[str] = set()
    for order, raw in enumerate(value):
        page: BookPage | None = None
        if isinstance(raw, BookPage):
            page = raw
        elif isinstance(raw, dict):
            page_id = raw.get("page_id")
            if not isinstance(page_id, str) or not page_id.strip():
                continue
            try:
                index = int(raw.get("index", order))
            except (TypeError, ValueError):
                index = order
            title = raw.get("title")
            page = BookPage(
                page_id=page_id.strip(),
                index=max(0, index),
                title=str(title) if isinstance(title, str) else default_page_title(index),
            )
        if page is None or not page.page_id or page.page_id in seen:
            continue
        if page.page_id == COVER_PAGE_ID:
            # Reserved: a real page holding it would swallow the cover filter.
            continue
        seen.add(page.page_id)
        entries.append((page.index, order, page))
    entries.sort(key=lambda item: (item[0], item[1]))
    pages = [page for _index, _order, page in entries]
    for index, page in enumerate(pages):
        page.index = index
        if not page.title:
            page.title = default_page_title(index)
    return pages


def pages_to_json(pages: Iterable[BookPage]) -> list[dict[str, Any]]:
    """Wire form of ``pages`` — densely reindexed, so a hand edit cannot leak."""
    normalized = normalize_pages(list(pages))
    return [page.to_json() for page in normalized]


class BookLayout:
    """Ordered page list of one book, with the mutations the page strip needs.

    Holds the same list object the document holds, so ``document.pages`` and
    the layout can never drift. ``title``/``index`` invariants (dense 0..n-1
    indexes, no empty titles, no cover id) are maintained after every mutation
    by :meth:`_reindex`.
    """

    def __init__(self, pages: Sequence[BookPage] | None = None) -> None:
        self._pages: list[BookPage] = normalize_pages(list(pages or []))

    @classmethod
    def from_document(cls, doc: object) -> BookLayout:
        """Layout of ``doc.pages`` (a non-book document yields an empty book)."""
        return cls(list(getattr(doc, "pages", None) or []))

    @classmethod
    def seeded(cls) -> BookLayout:
        """A new book: one page, so every book always has somewhere to draw."""
        return cls([new_page(index=0)])

    # -- reading -----------------------------------------------------------
    @property
    def pages(self) -> list[BookPage]:
        return self._pages

    def __len__(self) -> int:
        return len(self._pages)

    def __iter__(self):
        return iter(self._pages)

    def page_ids(self) -> list[str]:
        return [page.page_id for page in self._pages]

    @property
    def first_page_id(self) -> str | None:
        return self._pages[0].page_id if self._pages else None

    def page(self, page_id: object) -> BookPage | None:
        for page in self._pages:
            if page.page_id == page_id:
                return page
        return None

    def index_of(self, page_id: object) -> int:
        """Position of ``page_id`` in reading order, ``-1`` when absent."""
        for index, page in enumerate(self._pages):
            if page.page_id == page_id:
                return index
        return -1

    def to_json(self) -> list[dict[str, Any]]:
        return pages_to_json(self._pages)

    # -- mutating ----------------------------------------------------------
    def add(
        self,
        *,
        title: str | None = None,
        page_id: str | None = None,
        at: int | None = None,
    ) -> BookPage:
        """Insert a page (end by default) and return it."""
        position = len(self._pages) if at is None else max(0, min(int(at), len(self._pages)))
        page = new_page(index=position, page_id=page_id, title=title)
        if page.page_id == COVER_PAGE_ID:
            raise ValueError(f"{COVER_PAGE_ID!r} is reserved for the book cover")
        self._pages.insert(position, page)
        self._reindex()
        return self.page(page.page_id) or page

    def delete(self, page_id: object) -> BookPage | None:
        """Remove one page; the last remaining page is never deleted.

        Returns the removed page, or ``None`` when nothing was removed. The
        caller decides what happens to that page's elements — the layout owns
        pages only.
        """
        index = self.index_of(page_id)
        if index < 0 or len(self._pages) <= 1:
            return None
        removed = self._pages.pop(index)
        self._reindex()
        return removed

    def move(self, page_id: object, to_index: int) -> bool:
        """Reorder one page to ``to_index`` (clamped); False when not found."""
        index = self.index_of(page_id)
        if index < 0:
            return False
        target = max(0, min(int(to_index), len(self._pages) - 1))
        if target == index:
            return False
        page = self._pages.pop(index)
        self._pages.insert(target, page)
        self._reindex()
        return True

    def reorder(self, order: Sequence[object]) -> bool:
        """Apply an explicit page-id order; unknown/duplicate ids are ignored.

        A partial order keeps the unmentioned pages after the named ones in
        their previous relative order, so a stale client cannot lose a page.
        """
        wanted = [str(pid) for pid in order]
        by_id = {page.page_id: page for page in self._pages}
        ordered: list[BookPage] = []
        used: set[str] = set()
        for page_id in wanted:
            page = by_id.get(page_id)
            if page is not None and page_id not in used:
                ordered.append(page)
                used.add(page_id)
        ordered.extend(page for page in self._pages if page.page_id not in used)
        if [page.page_id for page in ordered] == self.page_ids():
            return False
        self._pages = ordered
        self._reindex()
        return True

    def rename(self, page_id: object, title: str) -> bool:
        page = self.page(page_id)
        if page is None:
            return False
        cleaned = str(title or "").strip()
        if not cleaned:
            return False
        if page.title == cleaned:
            return False
        page.title = cleaned
        return True

    def _reindex(self) -> None:
        for index, page in enumerate(self._pages):
            page.index = index
            if not page.title:
                page.title = default_page_title(index)


# ---------------------------------------------------------------------------
# Element ⇄ page addressing
# ---------------------------------------------------------------------------
def node_page_id(node: object) -> str | None:
    """``page_id`` of an element, or ``None`` for "belongs to page 1".

    ``CanvasNode`` (Doc 09) is frozen and owns no such field, so the value is
    carried as a plain attribute set by the store's parser and by
    :func:`set_node_page_id`. Reading it through a helper keeps that one
    detail out of every consumer.
    """
    value = getattr(node, "page_id", None)
    if isinstance(value, str):
        cleaned = value.strip()
        return cleaned or None
    return None


def set_node_page_id(node: object, page_id: object) -> None:
    """Attach (or clear) an element's page. ``None``/empty means page 1."""
    cleaned = page_id.strip() if isinstance(page_id, str) else None
    setattr(node, "page_id", cleaned or None)


def resolve_page_id(page_id: object, pages: Sequence[BookPage] | BookLayout) -> str | None:
    """Effective page id: ``None`` resolves to the book's first page."""
    layout = pages if isinstance(pages, BookLayout) else BookLayout(pages)
    wanted = page_id.strip() if isinstance(page_id, str) else None
    if wanted and layout.page(wanted) is not None:
        return wanted
    if wanted == COVER_PAGE_ID:
        return COVER_PAGE_ID
    return layout.first_page_id


def nodes_for_page(
    elements: Iterable[object],
    page_id: object,
    pages: Sequence[BookPage] | BookLayout,
) -> list:
    """The elements shown on one page — the single page filter.

    Rules (must match the Dart ``BookController``):
    * an element with no ``page_id`` belongs to the FIRST page;
    * the cover element belongs to no page at all;
    * an unknown ``page_id`` falls back to the first page, so a document whose
      pages were deleted still renders its content somewhere.
    """
    layout = pages if isinstance(pages, BookLayout) else BookLayout(pages)
    target = resolve_page_id(page_id, layout)
    first = layout.first_page_id
    out: list = []
    for node in elements:
        owner = node_page_id(node)
        if owner == COVER_PAGE_ID:
            continue
        if owner is None:
            if target == first:
                out.append(node)
            continue
        if owner == target:
            out.append(node)
    return out


def cover_node(elements: Iterable[object]) -> object | None:
    """The cover IMAGE element, when the book has one."""
    for node in elements:
        if node_page_id(node) == COVER_PAGE_ID:
            return node
    return None


def thumbnail_elements(
    elements: Iterable[object],
    pages: Sequence[BookPage] | BookLayout,
) -> list:
    """Elements the gallery thumbnail shows: the cover, else page 1."""
    materialised = list(elements)
    cover = cover_node(materialised)
    if cover is not None:
        return [cover]
    return nodes_for_page(materialised, None, pages)


def detach_page_nodes(elements: Sequence[object], page_id: object) -> tuple[list, list]:
    """Split ``elements`` into (kept, removed) for a page delete.

    ``removed`` holds the elements that belong to ``page_id``. Elements with no
    ``page_id`` are kept: they belong to page 1, which is never removed unless
    it genuinely is ``page_id`` — and even then "no page_id" must keep meaning
    page 1, so the caller reassigns rather than deletes them.
    """
    target = page_id.strip() if isinstance(page_id, str) else None
    kept: list = []
    removed: list = []
    if not target or target == COVER_PAGE_ID:
        return list(elements), []
    for node in elements:
        if node_page_id(node) == target:
            removed.append(node)
        else:
            kept.append(node)
    return kept, removed


def assign_nodes_to_page(elements: Iterable[object], page_id: object) -> None:
    """Reassign many elements at once (page delete → survivor page)."""
    for node in elements:
        set_node_page_id(node, page_id)
