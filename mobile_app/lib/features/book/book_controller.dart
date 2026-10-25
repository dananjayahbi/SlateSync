/// Round-13 issue 04 — the book controller: pages, selection and the page
/// FILTER over one element list.
///
/// A book is a normal [CanvasDocumentModel] with `artboard.preset == 'BOOK'`
/// plus an ordered `pages` list. The whole point of this class is that page
/// membership is a *filter*, not a second storage path:
///
/// * every element keeps living in `document.elements`;
/// * an element's page is `CanvasNodeModel.pageId`;
/// * `pageId == null` means the FIRST page — which is also what an element of
///   a pre-round-13 document means, so nothing needs migrating;
/// * the reserved [kBookCoverPageId] belongs to no page, so the cover can never
///   appear on top of page 1.
///
/// The controller owns the ordering invariants (dense 0..n-1 indexes, one page
/// minimum, no empty titles) and notifies listeners after every mutation, so
/// the page strip and the canvas stay in step without either owning the truth.
/// These rules mirror `pc_agent/engine/book_model.py` exactly — two
/// implementations of one filter would be the fork the plan forbids.
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05

/// Result of deleting a page: what was removed, and where the reader landed.
class BookPageDeletion {
  const BookPageDeletion({
    required this.page,
    required this.removedElements,
    required this.nextPageId,
  });

  final BookPageModel page;

  /// The elements that lived on the deleted page. Returned rather than
  /// silently dropped so a caller can push them onto its undo stack.
  final List<CanvasNodeModel> removedElements;

  /// The page that is now current (the neighbour the reader fell onto).
  final String? nextPageId;
}

/// Pages + selection + page filtering for one book document.
class BookController extends ChangeNotifier {
  BookController({required this.document, String? pageId}) {
    _reindex();
    _currentPageId = _resolveSelection(pageId);
  }

  /// The document this controller drives (never replaced).
  final CanvasDocumentModel document;

  String? _currentPageId;


  /// True when the document is a book at all. A non-book document has no
  /// pages, and every element therefore belongs to "page 1" — the filter still
  /// behaves, which is what keeps the canvas page free of `isBook` branches.
  bool get isBook => document.isBook;

  List<BookPageModel> get pages => document.pages;

  int get pageCount => pages.length;

  String? get currentPageId => _currentPageId;

  /// 0-based position of the current page (`0` for a paged document with none).
  int get currentIndex {
    final int index = indexOf(_currentPageId);
    return index < 0 ? 0 : index;
  }

  BookPageModel? get currentPage => pageOf(_currentPageId);

  /// Ids in reading order.
  List<String> get pageIds => <String>[
        for (final BookPageModel page in pages) page.pageId,
      ];

  bool get canGoPrevious => currentIndex > 0;

  bool get canGoNext => currentIndex < pageCount - 1;

  /// The book's first page, which is also the owner of page-less elements.
  String? get firstPageId => pages.isEmpty ? null : pages.first.pageId;

  // -------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------

  int indexOf(String? pageId) {
    if (pageId == null) {
      return -1;
    }
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].pageId == pageId) {
        return i;
      }
    }
    return -1;
  }

  BookPageModel? pageOf(String? pageId) {
    final int index = indexOf(pageId);
    return index < 0 ? null : pages[index];
  }

  /// Effective page id: `null` resolves to the first page; an unknown id falls
  /// back to the first page so a document whose pages vanished still renders
  /// its content somewhere rather than becoming blank.
  String? resolvePageId(String? pageId) {
    if (pageId != null && pageId == kBookCoverPageId) {
      return kBookCoverPageId;
    }
    if (pageId != null && indexOf(pageId) >= 0) {
      return pageId;
    }
    return firstPageId;
  }

  /// The elements shown on [pageId] — the single page filter.
  List<CanvasNodeModel> elementsForPage(String? pageId) {
    final String? target = resolvePageId(pageId ?? _currentPageId);
    final String? first = firstPageId;
    return <CanvasNodeModel>[
      for (final CanvasNodeModel node in document.elements)
        if (_onPage(node, target: target, first: first)) node,
    ];
  }

  /// Elements of the page currently being edited.
  List<CanvasNodeModel> get visibleElements =>
      elementsForPage(_currentPageId);

  /// Elements visible on this document right now.
  ///
  /// A non-book document shows everything, unchanged — callers ask for "the
  /// visible elements" instead of branching on whether it is a book.
  List<CanvasNodeModel> visibleElementsForDocument() => isBook
      ? visibleElements
      : List<CanvasNodeModel>.of(document.elements);

  bool _onPage(
    CanvasNodeModel node, {
    required String? target,
    required String? first,
  }) {
    final String? owner = normalizePageId(node.pageId);
    if (owner == kBookCoverPageId) {
      return false; // the cover is not a page
    }
    if (owner == null) {
      return target == first; // page-less means page 1
    }
    return owner == target;
  }

  // -------------------------------------------------------------------------
  // Cover
  // -------------------------------------------------------------------------

  /// The cover IMAGE element, when the book has one.
  CanvasNodeModel? get cover {
    for (final CanvasNodeModel node in document.elements) {
      if (normalizePageId(node.pageId) == kBookCoverPageId) {
        return node;
      }
    }
    return null;
  }

  String? get coverAssetRef => cover?.geometry.assetRef;

  /// Elements the gallery thumbnail should show: the cover, else page 1.
  List<CanvasNodeModel> thumbnailElements() {
    final CanvasNodeModel? coverNode = cover;
    if (coverNode != null) {
      return <CanvasNodeModel>[coverNode];
    }
    return elementsForPage(firstPageId);
  }

  // -------------------------------------------------------------------------
  // Selection
  // -------------------------------------------------------------------------

  /// Select [pageId]; unknown/null falls back to the first page. Returns the
  /// id actually selected.
  String? select(String? pageId) {
    final String? resolved = resolvePageId(pageId);
    if (resolved == _currentPageId) {
      return resolved;
    }
    _currentPageId = resolved;
    notifyListeners();
    return resolved;
  }

  /// Step one page forward; returns the new page id, or `null` at the end.
  String? next() {
    if (!canGoNext) {
      return null;
    }
    return select(pageIds[currentIndex + 1]);
  }

  /// Step one page back; returns the new page id, or `null` at the start.
  String? previous() {
    if (!canGoPrevious) {
      return null;
    }
    return select(pageIds[currentIndex - 1]);
  }

  // -------------------------------------------------------------------------
  // Mutations
  // -------------------------------------------------------------------------

  /// Append (or insert at [at]) a page; the new page becomes current.
  BookPageModel addPage({String? title, int? at}) {
    final int position = at == null ? pages.length : at.clamp(0, pages.length);
    final String trimmed = (title ?? '').trim();
    final BookPageModel page = BookPageModel(
      pageId: _newPageId(),
      index: position,
      title: trimmed.isEmpty ? bookPageTitle(position) : trimmed,
    );
    pages.insert(position, page);
    _reindex();
    _currentPageId = page.pageId;
    notifyListeners();
    return page;
  }

  /// Delete [pageId]. The last remaining page is never deleted — a book with
  /// nowhere to draw is not a state the strip or the exporter should see.
  BookPageDeletion? deletePage(String? pageId) {
    final int index = indexOf(pageId);
    if (index < 0 || pages.length <= 1) {
      return null;
    }
    final BookPageModel page = pages.removeAt(index);
    final List<CanvasNodeModel> removed = <CanvasNodeModel>[
      for (final CanvasNodeModel node in document.elements)
        if (normalizePageId(node.pageId) == page.pageId) node,
    ];
    document.elements.removeWhere(
      (CanvasNodeModel node) => normalizePageId(node.pageId) == page.pageId,
    );
    _reindex();
    // Fall onto the neighbour that took this page's place, or the new last one.
    final String? nextId =
        pages.isEmpty ? null : pages[index.clamp(0, pages.length - 1)].pageId;
    if (_currentPageId == page.pageId) {
      _currentPageId = resolvePageId(nextId);
    }
    notifyListeners();
    return BookPageDeletion(
      page: page,
      removedElements: removed,
      nextPageId: _currentPageId,
    );
  }

  /// Move [pageId] to [toIndex] (clamped). Returns true when the order changed.
  bool movePage(String? pageId, int toIndex) {
    final int index = indexOf(pageId);
    if (index < 0) {
      return false;
    }
    final int target = toIndex.clamp(0, pages.length - 1);
    if (target == index) {
      return false;
    }
    final BookPageModel page = pages.removeAt(index);
    pages.insert(target, page);
    _reindex();
    notifyListeners();
    return true;
  }

  /// Apply an explicit id order. Ids that name no page are ignored and pages
  /// the caller did not mention keep their relative order AFTER the named
  /// ones, so a stale client can never lose a page.
  bool reorder(List<String> order) {
    final Map<String, BookPageModel> byId = <String, BookPageModel>{
      for (final BookPageModel page in pages) page.pageId: page,
    };
    final List<BookPageModel> ordered = <BookPageModel>[];
    final Set<String> used = <String>{};
    for (final String pageId in order) {
      final BookPageModel? page = byId[pageId];
      if (page != null && used.add(pageId)) {
        ordered.add(page);
      }
    }
    for (final BookPageModel page in pages) {
      if (!used.contains(page.pageId)) {
        ordered.add(page);
      }
    }
    final List<String> previous = pageIds;
    final List<String> next = <String>[
      for (final BookPageModel page in ordered) page.pageId,
    ];
    if (listEquals(previous, next)) {
      return false;
    }
    pages
      ..clear()
      ..addAll(ordered);
    _reindex();
    notifyListeners();
    return true;
  }

  /// Rename one page; blank titles are rejected (the strip always shows a
  /// label, and an empty chip is untappable in practice).
  bool renamePage(String? pageId, String title) {
    final BookPageModel? page = pageOf(pageId);
    final String cleaned = title.trim();
    if (page == null || cleaned.isEmpty || page.title == cleaned) {
      return false;
    }
    page.title = cleaned;
    notifyListeners();
    return true;
  }

  /// Add [node] to the document on the CURRENT page.
  ///
  /// Page 1 elements keep `pageId == null` so a book's first page serialises
  /// exactly like a pre-round-13 document (and the wire stays as small as the
  /// data allows).
  void addNode(CanvasNodeModel node, {String? pageId}) {
    final String? target = resolvePageId(pageId ?? _currentPageId);
    node.pageId = target == firstPageId ? null : target;
    document.elements.add(node);
    notifyListeners();
  }

  /// Move an existing element onto the current page (or [pageId]).
  bool assignToPage(CanvasNodeModel node, {String? pageId}) {
    final String? target = resolvePageId(pageId ?? _currentPageId);
    final String? next = target == firstPageId ? null : target;
    if (node.pageId == next) {
      return false;
    }
    node.pageId = next;
    notifyListeners();
    return true;
  }

  /// Attach [node] as the cover (it is taken off whichever page held it).
  void setCover(CanvasNodeModel node) {
    node.pageId = kBookCoverPageId;
    if (!document.elements.contains(node)) {
      document.elements.add(node);
    }
    notifyListeners();
  }

  /// Detach the cover image from the document entirely.
  bool clearCover() {
    final int before = document.elements.length;
    document.elements.removeWhere(
      (CanvasNodeModel node) =>
          normalizePageId(node.pageId) == kBookCoverPageId,
    );
    if (document.elements.length == before) {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// Page size name of the artboard (`A4` / `A5` / `LETTER`; falls back to the
  /// default for dims that match nothing, e.g. a document resized by hand).
  String get pageSizeName {
    final double? w = document.artboard.width;
    final double? h = document.artboard.height;
    if (w == null || h == null) {
      return kDefaultBookPageSize;
    }
    for (final String name in kBookPageSizes) {
      final ({double w, double h})? size = bookPageDims(name);
      if (size == null) {
        continue;
      }
      if (size.w.round() == w.round() && size.h.round() == h.round()) {
        return name;
      }
    }
    return kDefaultBookPageSize;
  }

  /// World-unit page rect (`0,0 → w,h`); `null` for a book that somehow has
  /// null dims, so nothing invents an unbounded page.
  Rect? get pageRect {
    final double? w = document.artboard.width;
    final double? h = document.artboard.height;
    if (w == null || h == null || w <= 0 || h <= 0) {
      return null;
    }
    return Rect.fromLTWH(0, 0, w, h);
  }

  String _newPageId() {
    final Set<String> taken = pageIds.toSet();
    int suffix = 0;
    String candidate = 'page-${DateTime.now().microsecondsSinceEpoch}';
    while (taken.contains(candidate)) {
      suffix += 1;
      candidate = 'page-${DateTime.now().microsecondsSinceEpoch}-$suffix';
    }
    return candidate;
  }

  void _reindex() {
    for (int i = 0; i < pages.length; i++) {
      pages[i].index = i;
      if (pages[i].title.trim().isEmpty) {
        pages[i].title = bookPageTitle(i);
      }
    }
  }

  String? _resolveSelection(String? requested) {
    if (requested != null && indexOf(requested) >= 0) {
      return requested;
    }
    return firstPageId;
  }
}

/// World dims of a book page size; `null` for anything else (including
/// `INFINITE`, which a book must never offer).
({double w, double h})? bookPageDims(String name) => switch (name) {
      'A4' => (w: Presets.a4.$1, h: Presets.a4.$2),
      'A5' => (w: Presets.a5.w, h: Presets.a5.h),
      'LETTER' => (w: Presets.letter.$1, h: Presets.letter.$2),
      _ => null,
    };
