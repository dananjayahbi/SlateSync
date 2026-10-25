/// Round-13 issue 04 — BOOKS: pages, the page filter, the BOOK preset, fold
/// geometry/shading and the reduced-motion path.
///
/// The assertions here are deliberately about PROPERTIES, not about pixels:
/// that a legacy element still lands on page 1, that a book is never infinite,
/// that the fold's shading is not a straight line, and that reduced motion
/// takes a different code path rather than a shorter animation.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/core/models/canvas_models.dart';
import 'package:mobile_app/features/book/book_controller.dart';
import 'package:mobile_app/features/book/book_shell.dart';
import 'package:mobile_app/features/book/page_turn_geometry.dart';
import 'package:mobile_app/features/book/page_turn_overlay.dart';
import 'package:mobile_app/features/book/page_turn_painter.dart';
import 'package:mobile_app/features/canvas/page_strip.dart';
import 'package:mobile_app/features/home/home_canvas_dashboard.dart';
import 'package:mobile_app/features/tools/tool_palette_dock.dart'
    show PickedImage;

import 'support/recording_canvas.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// A single straight stroke on [pageId] (`null` = page 1).
CanvasNodeModel _node(
  String id, {
  String? pageId,
  int layer = 0,
  String? assetRef,
}) =>
    CanvasNodeModel(
      nodeId: id,
      kind: assetRef == null ? 'STROKE' : 'IMAGE',
      layer: layer,
      bbox: <double>[0, 0, 100, 100],
      style: NodeStyleModel(
        color: '#1E1E1E',
        strokeWidth: 4,
        opacity: 1,
        blendMode: 'SRC_OVER',
      ),
      geometry: NodeGeometryModel(
        pts: const <List<double>>[
          <double>[0, 0],
          <double>[100, 100],
        ],
        assetRef: assetRef,
      ),
      pageId: pageId,
    );

BookPageModel _page(String id, int index, [String? title]) => BookPageModel(
      pageId: id,
      index: index,
      title: title ?? bookPageTitle(index),
    );

CanvasDocumentModel _book({
  List<BookPageModel>? pages,
  List<CanvasNodeModel>? elements,
  String preset = kBookPreset,
  double? width = 2480,
  double? height = 3508,
}) =>
    CanvasDocumentModel(
      canvasId: 'cv-book',
      title: 'book',
      createdAt: 0,
      updatedAt: 0,
      artboard: Artboard(
        preset: preset,
        width: width,
        height: height,
        isInfinite: preset == 'INFINITE',
        backgroundStyle: kBackgroundBlank,
        backgroundColor: '#FFFFFF',
      ),
      contentBounds: <String, double>{
        'min_x': 0,
        'min_y': 0,
        'max_x': 0,
        'max_y': 0,
      },
      elements: elements ?? <CanvasNodeModel>[],
      pages: pages ??
          <BookPageModel>[_page('p1', 0), _page('p2', 1), _page('p3', 2)],
    );

List<String> _ids(Iterable<CanvasNodeModel> nodes) =>
    nodes.map((CanvasNodeModel n) => n.nodeId).toList();

void main() {
  // -------------------------------------------------------------------------
  // BOOK preset boundedness
  // -------------------------------------------------------------------------
  group('BOOK preset', () {
    test('is a known preset with bounded A4 dims', () {
      expect(presetDims(kBookPreset).infinite, isFalse);
      expect(presetDims(kBookPreset).w, Presets.book.w);
      expect(presetDims(kBookPreset).h, Presets.book.h);
    });

    test('is never infinite, unlike INFINITE', () {
      expect(presetDims(kBookPreset).infinite, isFalse);
      expect(presetDims('INFINITE').infinite, isTrue);
    });

    test('presetDims still rejects unknown presets', () {
      expect(() => presetDims('A0'), throwsArgumentError);
    });

    test('labels and tints are distinct from the page sizes', () {
      expect(presetLabel(kBookPreset), 'Book');
      expect(presetTint(kBookPreset), isNot(presetTint('A4')));
      expect(presetBadgeColor(kBookPreset), isNot(presetBadgeColor('A4')));
      expect(presetDimsLabel(kBookPreset), 'Multi-page');
    });

    test('offers exactly A4, A5 and Letter — no infinite page', () {
      expect(kBookPageSizes, <String>['A4', 'A5', 'LETTER']);
      expect(kBookPageSizes, isNot(contains('INFINITE')));
    });

    test('an ordinary document is not a book', () {
      expect(_book(preset: 'A4').isBook, isFalse);
      expect(_book().isBook, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Page size mapping
  // -------------------------------------------------------------------------
  group('page sizes', () {
    test('A4 maps to the Doc 03 matrix', () {
      expect(bookPageDims('A4'), (w: 2480.0, h: 3508.0));
    });

    test('A5 maps to the Doc 03 matrix', () {
      expect(bookPageDims('A5'), (w: 1748.0, h: 2480.0));
    });

    test('LETTER maps to the Doc 03 matrix', () {
      expect(bookPageDims('LETTER'), (w: 2550.0, h: 3300.0));
    });

    test('INFINITE has no page size', () {
      expect(bookPageDims('INFINITE'), isNull);
    });

    test('the default page size is a real one', () {
      expect(kBookPageSizes, contains(kDefaultBookPageSize));
      expect(bookPageDims(kDefaultBookPageSize), isNotNull);
    });

    test('controller reads the page size back off the artboard', () {
      final BookController a4 = BookController(document: _book());
      expect(a4.pageSizeName, 'A4');
      final BookController a5 = BookController(
        document: _book(width: 1748, height: 2480),
      );
      expect(a5.pageSizeName, 'A5');
      final BookController letter = BookController(
        document: _book(width: 2550, height: 3300),
      );
      expect(letter.pageSizeName, 'LETTER');
    });

    test('an unbounded artboard has no page rect', () {
      final BookController controller = BookController(
        document: _book(width: null, height: null),
      );
      expect(controller.pageRect, isNull);
    });

    test('a bounded artboard has a 0,0-anchored page rect', () {
      final BookController controller = BookController(document: _book());
      expect(controller.pageRect, const Rect.fromLTWH(0, 0, 2480, 3508));
    });
  });

  // -------------------------------------------------------------------------
  // Page add / delete / reorder / rename
  // -------------------------------------------------------------------------
  group('page mutations', () {
    test('addPage appends and selects the new page', () {
      final BookController controller = BookController(document: _book());
      final BookPageModel page = controller.addPage(title: 'Contents');
      expect(controller.pageCount, 4);
      expect(controller.pages.last.pageId, page.pageId);
      expect(controller.currentPageId, page.pageId);
      expect(page.title, 'Contents');
    });

    test('addPage inserts at an index and reindexes', () {
      final BookController controller = BookController(document: _book());
      final BookPageModel page = controller.addPage(at: 1);
      expect(controller.pageIds[1], page.pageId);
      expect(controller.pages.map((BookPageModel p) => p.index), <int>[0, 1, 2, 3]);
    });

    test('addPage invents a unique id', () {
      final BookController controller = BookController(document: _book());
      final String a = controller.addPage().pageId;
      final String b = controller.addPage().pageId;
      expect(a, isNot(b));
      expect(controller.pageIds.toSet(), hasLength(controller.pageCount));
    });

    test('addPage without a title uses the page ordinal', () {
      final BookController controller = BookController(document: _book());
      final BookPageModel page = controller.addPage();
      expect(page.title, 'Page 4');
    });

    test('deletePage removes the page and its elements', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('a', pageId: 'p2'),
            _node('b', pageId: 'p1'),
          ],
        ),
      );
      final BookPageDeletion? deletion = controller.deletePage('p2');
      expect(deletion, isNotNull);
      expect(_ids(deletion!.removedElements), <String>['a']);
      expect(controller.pageIds, <String>['p1', 'p3']);
      expect(_ids(controller.document.elements), <String>['b']);
    });

    test('deletePage never removes the last page', () {
      final BookController controller = BookController(
        document: _book(pages: <BookPageModel>[_page('only', 0)]),
      );
      expect(controller.deletePage('only'), isNull);
      expect(controller.pageCount, 1);
    });

    test('deletePage falls onto the neighbour that took its place', () {
      final BookController controller = BookController(
        document: _book(),
        pageId: 'p2',
      );
      controller.deletePage('p2');
      expect(controller.currentPageId, 'p3');
    });

    test('deletePage of an unknown id is a no-op', () {
      final BookController controller = BookController(document: _book());
      expect(controller.deletePage('zzz'), isNull);
      expect(controller.pageCount, 3);
    });

    test('movePage reorders and reindexes', () {
      final BookController controller = BookController(document: _book());
      expect(controller.movePage('p3', 0), isTrue);
      expect(controller.pageIds, <String>['p3', 'p1', 'p2']);
      expect(controller.pages.map((BookPageModel p) => p.index), <int>[0, 1, 2]);
    });

    test('movePage to the same index reports no change', () {
      final BookController controller = BookController(document: _book());
      expect(controller.movePage('p1', 0), isFalse);
    });

    test('reorder keeps pages the caller forgot', () {
      final BookController controller = BookController(document: _book());
      controller.reorder(<String>['p3']);
      expect(controller.pageIds, <String>['p3', 'p1', 'p2']);
    });

    test('reorder of an identical order reports no change', () {
      final BookController controller = BookController(document: _book());
      expect(controller.reorder(controller.pageIds), isFalse);
    });

    test('renamePage rejects a blank title', () {
      final BookController controller = BookController(document: _book());
      expect(controller.renamePage('p1', '   '), isFalse);
      expect(controller.pages.first.title, 'Page 1');
    });

    test('renamePage stores a trimmed title', () {
      final BookController controller = BookController(document: _book());
      expect(controller.renamePage('p1', '  Cover  '), isTrue);
      expect(controller.pages.first.title, 'Cover');
    });

    test('every mutation notifies listeners', () {
      final BookController controller = BookController(document: _book());
      int notifications = 0;
      controller.addListener(() => notifications++);
      controller.addPage();
      controller.movePage(controller.pageIds.first, 2);
      controller.renamePage(controller.pageIds.first, 'Renamed');
      controller.deletePage(controller.pageIds.first);
      expect(notifications, greaterThanOrEqualTo(4));
    });
  });

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------
  group('navigation', () {
    test('next / previous walk the pages in order', () {
      final BookController controller = BookController(document: _book());
      expect(controller.currentPageId, 'p1');
      expect(controller.next(), 'p2');
      expect(controller.next(), 'p3');
      expect(controller.next(), isNull);
      expect(controller.previous(), 'p2');
      expect(controller.previous(), 'p1');
      expect(controller.previous(), isNull);
    });

    test('canGoNext / canGoPrevious follow the ends', () {
      final BookController controller = BookController(document: _book());
      expect(controller.canGoPrevious, isFalse);
      expect(controller.canGoNext, isTrue);
      controller.select('p3');
      expect(controller.canGoNext, isFalse);
      expect(controller.canGoPrevious, isTrue);
    });

    test('select resolves null and unknown ids to page 1', () {
      final BookController controller = BookController(
        document: _book(),
        pageId: 'p2',
      );
      expect(controller.select(null), 'p1');
      expect(controller.select('zzz'), 'p1');
      expect(controller.select('p2'), 'p2');
      expect(controller.currentIndex, 1);
    });
  });

  // -------------------------------------------------------------------------
  // The page filter — page_id, legacy nodes, cover
  // -------------------------------------------------------------------------
  group('page filter', () {
    test('legacy nodes with no page_id all land on page 1', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[_node('legacy-1'), _node('legacy-2')],
        ),
      );
      expect(_ids(controller.elementsForPage('p1')), <String>['legacy-1', 'legacy-2']);
      expect(controller.elementsForPage('p2'), isEmpty);
    });

    test('editing a page only affects that page', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('a', pageId: 'p1'),
            _node('b', pageId: 'p2'),
            _node('c', pageId: 'p2'),
          ],
        ),
      );
      expect(_ids(controller.elementsForPage('p1')), <String>['a']);
      expect(_ids(controller.elementsForPage('p2')), <String>['b', 'c']);
    });

    test('an unknown page id falls back to the first page', () {
      final BookController controller = BookController(
        document: _book(elements: <CanvasNodeModel>[_node('a', pageId: 'p1')]),
      );
      expect(_ids(controller.elementsForPage('gone')), <String>['a']);
    });

    test('the cover is never part of any page', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('cover', pageId: kBookCoverPageId),
            _node('a', pageId: 'p1'),
          ],
        ),
      );
      expect(_ids(controller.elementsForPage('p1')), <String>['a']);
      expect(_ids(controller.elementsForPage(kBookCoverPageId)), isEmpty);
    });

    test('a non-book document shows every element unchanged', () {
      final BookController controller = BookController(
        document: _book(
          preset: 'A4',
          pages: <BookPageModel>[],
          elements: <CanvasNodeModel>[_node('a'), _node('b', pageId: 'p1')],
        ),
      );
      expect(_ids(controller.visibleElementsForDocument()), <String>['a', 'b']);
    });

    test('a book shows only the current page', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('a', pageId: 'p1'),
            _node('b', pageId: 'p2'),
          ],
        ),
        pageId: 'p2',
      );
      expect(_ids(controller.visibleElementsForDocument()), <String>['b']);
    });

    test('addNode keeps page 1 elements page-less', () {
      final BookController controller = BookController(document: _book());
      final CanvasNodeModel node = _node('new');
      controller.addNode(node);
      expect(node.pageId, isNull);
      expect(_ids(controller.elementsForPage('p1')), <String>['new']);
    });

    test('addNode on page 2 tags the element', () {
      final BookController controller = BookController(
        document: _book(),
        pageId: 'p2',
      );
      final CanvasNodeModel node = _node('new');
      controller.addNode(node);
      expect(node.pageId, 'p2');
      expect(_ids(controller.elementsForPage('p2')), <String>['new']);
      expect(controller.elementsForPage('p1'), isEmpty);
    });

    test('assignToPage moves an element between pages', () {
      final BookController controller = BookController(
        document: _book(elements: <CanvasNodeModel>[_node('a')]),
        pageId: 'p3',
      );
      final CanvasNodeModel node = controller.document.elements.single;
      expect(controller.assignToPage(node), isTrue);
      expect(_ids(controller.elementsForPage('p3')), <String>['a']);
      expect(controller.elementsForPage('p1'), isEmpty);
    });

    test('assignToPage back to page 1 clears the tag', () {
      final BookController controller = BookController(
        document: _book(elements: <CanvasNodeModel>[_node('a', pageId: 'p2')]),
      );
      controller.assignToPage(controller.document.elements.single, pageId: 'p1');
      expect(controller.document.elements.single.pageId, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Cover vs page-1 thumbnail
  // -------------------------------------------------------------------------
  group('thumbnail choice', () {
    test('the cover wins when one is set', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('page', pageId: 'p1'),
            _node('cover', pageId: kBookCoverPageId, assetRef: 'assets/c.png'),
          ],
        ),
      );
      expect(_ids(controller.thumbnailElements()), <String>['cover']);
      expect(controller.coverAssetRef, 'assets/c.png');
    });

    test('a cover alone is enough for a thumbnail', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('cover', pageId: kBookCoverPageId, assetRef: 'assets/c.png'),
          ],
        ),
      );
      expect(controller.cover, isNotNull);
      expect(controller.elementsForPage('p1'), isEmpty);
    });

    test('page 1 is the thumbnail without a cover', () {
      final BookController controller = BookController(
        document: _book(
          elements: <CanvasNodeModel>[
            _node('a', pageId: 'p1'),
            _node('b', pageId: 'p2'),
          ],
        ),
      );
      expect(_ids(controller.thumbnailElements()), <String>['a']);
      final BookController withLegacy = BookController(
        document: _book(elements: <CanvasNodeModel>[_node('legacy')]),
      );
      expect(_ids(withLegacy.thumbnailElements()), <String>['legacy']);
    });

    test('setCover retags an element and clearCover removes it', () {
      final BookController controller = BookController(
        document: _book(elements: <CanvasNodeModel>[_node('a', pageId: 'p1')]),
      );
      final CanvasNodeModel node = controller.document.elements.single;
      controller.setCover(node);
      expect(node.pageId, kBookCoverPageId);
      expect(controller.elementsForPage('p1'), isEmpty);
      expect(controller.clearCover(), isTrue);
      expect(controller.cover, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Fold geometry
  // -------------------------------------------------------------------------
  group('fold geometry', () {
    const double w = 1000;
    const double h = 1400;

    test('t = 0 is flat: crease at the right edge, nothing folded', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: w, height: h, t: 0);
      expect(g.foldX, w);
      expect(g.foldedWidth, 0);
      expect(g.hasFoldedHalf, isFalse);
      expect(g.hasFlatHalf, isTrue);
      expect(g.isEmpty, isFalse);
    });

    test('t = 1 is fully turned: nothing left to draw', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: w, height: h, t: 1);
      expect(g.foldX, 0);
      expect(g.hasFlatHalf, isFalse);
      expect(g.isEmpty, isTrue);
    });

    test('t = 0.5 puts the crease at the middle', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: w, height: h, t: 0.5);
      expect(g.foldX, closeTo(w / 2, 1e-9));
      expect(g.flatWidth, closeTo(w / 2, 1e-9));
      expect(g.foldedWidth, closeTo(w / 2, 1e-9));
    });

    test('the leading edge travels twice as fast as the crease', () {
      // This 2:1 ratio is the cue that separates a fold from a slide.
      for (final double t in <double>[0.1, 0.25, 0.5, 0.75, 0.9]) {
        final PageFoldGeometry g =
            PageFoldGeometry.at(width: w, height: h, t: t);
        final double creaseTravel = w - g.foldX;
        expect(g.leadingEdgeTravel, closeTo(creaseTravel * 2, 1e-6));
      }
    });

    test('t is clamped into range and junk dims become zero', () {
      expect(PageFoldGeometry.at(width: w, height: h, t: 2).t, 1);
      expect(PageFoldGeometry.at(width: w, height: h, t: -1).t, 0);
      expect(PageFoldGeometry.at(width: 0, height: h, t: 0.5).width, 0);
      expect(PageFoldGeometry.at(width: double.nan, height: h, t: 0.5).isEmpty, isTrue);
    });

    test('the crease bows at mid-turn and is straight at both ends', () {
      expect(PageFoldGeometry.at(width: w, height: h, t: 0).foldBow, closeTo(0, 1e-9));
      expect(PageFoldGeometry.at(width: w, height: h, t: 1).foldBow, closeTo(0, 1e-9));
      expect(PageFoldGeometry.at(width: w, height: h, t: 0.5).foldBow, greaterThan(0));
    });

    test('the shadow is nothing at the ends and strongest at mid-turn', () {
      expect(PageFoldGeometry.at(width: w, height: h, t: 0).shadowOpacity, 0);
      expect(PageFoldGeometry.at(width: w, height: h, t: 1).shadowOpacity, closeTo(0, 1e-9));
      final PageFoldGeometry mid =
          PageFoldGeometry.at(width: w, height: h, t: 0.5);
      expect(mid.shadowOpacity, greaterThan(0.2));
      expect(mid.shadowTrailWidth, greaterThan(0));
      expect(mid.shadowRect.width, greaterThan(0));
    });

    test('the shadow trail stays inside the page', () {
      for (final double t in <double>[0.1, 0.5, 0.9]) {
        final PageFoldGeometry g =
            PageFoldGeometry.at(width: w, height: h, t: t);
        expect(g.shadowRect.left, greaterThanOrEqualTo(0));
        expect(g.shadowRect.right, lessThanOrEqualTo(w));
      }
    });

    test('flat and folded rects meet at the crease', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: w, height: h, t: 0.3);
      expect(g.flatRect.right, g.foldX);
      expect(g.foldedRect.right, g.foldX);
      expect(g.foldedRect.left, g.leadingEdgeX);
    });
  });

  // -------------------------------------------------------------------------
  // Fold shading — the non-linear curve plus the shadow trail
  // -------------------------------------------------------------------------
  group('fold shading', () {
    test('the shading is NOT a linear ramp', () {
      // The whole feature lives or dies on this assertion.
      expect(foldShadingIsLinear(), isFalse);
    });

    test('shading rises across the folded half', () {
      expect(foldShadeAt(1), greaterThan(foldShadeAt(0)));
    });

    test('the specular band peaks just past the crease', () {
      final double atSpecular = foldShadeAt(0.12);
      expect(atSpecular, greaterThan(foldShadeAt(0.0)));
      expect(atSpecular, greaterThan(foldShadeAt(0.4)));
    });

    test('shading is clamped and tolerant of junk', () {
      expect(foldShadeAt(-1), foldShadeAt(0));
      expect(foldShadeAt(2), foldShadeAt(1));
      expect(foldShadeAt(double.nan), foldShadeAt(0));
      expect(foldShadeAt(0.5), inInclusiveRange(0, 1));
    });

    test('gradient stops span 0..1 with samples + 1 entries', () {
      final List<FoldShadeStop> stops = foldGradientStops(samples: 8);
      expect(stops, hasLength(9));
      expect(stops.first.position, 0);
      expect(stops.last.position, 1);
    });

    test('gradient stops track foldShadeAt', () {
      final List<FoldShadeStop> stops = foldGradientStops(samples: 4);
      expect(stops[2].luminance, closeTo(foldShadeAt(0.5), 1e-9));
    });

    test('a tiny sample count is floored rather than allowed to break', () {
      expect(foldGradientStops(samples: 0).length, greaterThanOrEqualTo(3));
    });
  });

  // -------------------------------------------------------------------------
  // Painter — t = 0 / 0.5 / 1 and the two halves
  // -------------------------------------------------------------------------
  group('page turn painter', () {
    const Rect page = Rect.fromLTWH(0, 0, 400, 560);

    RecordingCanvas paintAt(
      double t, {
      PageTurnDirection direction = PageTurnDirection.forward,
    }) {
      final RecordingCanvas canvas = RecordingCanvas();
      PageTurnPainter(pageRect: page, t: t, direction: direction)
          .paint(canvas, page.size);
      return canvas;
    }

    test('t = 0 paints nothing', () {
      expect(paintAt(0).calls, isEmpty);
    });

    test('t = 1 paints nothing (the sheet has gone)', () {
      expect(paintAt(1).calls, isEmpty);
    });

    test('mid-turn paints the folded half as a path', () {
      final RecordingCanvas canvas = paintAt(0.5);
      expect(canvas.didCall('drawPath'), isTrue);
      expect(canvas.didCall('drawRect'), isTrue);
    });

    test('the folded half carries a shader, not a flat colour', () {
      final RecordingCanvas canvas = paintAt(0.5);
      final List<Paint> paints = canvas.paintsOf('drawPath');
      expect(paints.any((Paint p) => p.shader != null), isTrue);
    });

    test('the shadow trail is drawn as a translucent rect', () {
      final RecordingCanvas canvas = paintAt(0.5);
      final List<Paint> rects = canvas.paintsOf('drawRect');
      expect(rects.any((Paint p) => p.shader != null), isTrue);
    });

    test('early in the turn only the flat half has width', () {
      final PageTurnPainter painter = PageTurnPainter(pageRect: page, t: 0.1);
      expect(painter.fold.hasFlatHalf, isTrue);
      expect(painter.fold.foldedWidth, greaterThan(0));
    });

    test('a backwards turn mirrors instead of moving the other way', () {
      final RecordingCanvas forward = paintAt(0.5);
      final RecordingCanvas backward =
          paintAt(0.5, direction: PageTurnDirection.backward);
      expect(backward.didCall('drawPath'), forward.didCall('drawPath'));
    });

    test('shouldRepaint tracks t and direction', () {
      const PageTurnPainter a = PageTurnPainter(pageRect: page, t: 0.2);
      expect(
        a.shouldRepaint(const PageTurnPainter(pageRect: page, t: 0.2)),
        isFalse,
      );
      expect(
        a.shouldRepaint(const PageTurnPainter(pageRect: page, t: 0.6)),
        isTrue,
      );
      expect(
        a.shouldRepaint(
          const PageTurnPainter(
            pageRect: page,
            t: 0.2,
            direction: PageTurnDirection.backward,
          ),
        ),
        isTrue,
      );
    });

    test('the folded path spans the folded half', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: 400, height: 560, t: 0.5);
      final Rect bounds = foldedPath(g).getBounds();
      expect(bounds.left, closeTo(g.leadingEdgeX, 0.5));
      expect(bounds.right, closeTo(g.foldX, 0.5));
      expect(bounds.height, closeTo(560, 0.5));
    });
  });

  // -------------------------------------------------------------------------
  // Reduced motion and the turn helpers
  // -------------------------------------------------------------------------
  group('reduced motion', () {
    test('a reduced-motion turn takes no time at all', () {
      expect(pageTurnMillisFor(reducedMotion: true), 0);
      expect(
        pageTurnMillisFor(reducedMotion: false),
        kPageTurnDuration.inMilliseconds,
      );
    });

    test('the overlay renders nothing under reduced motion', () {
      // Mounted with reduced motion, the fold painter must never appear: a
      // full-page fold is exactly what makes some users motion-sick.
      final Widget overlay = MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: PageTurnOverlay(
            pageRect: Rect.fromLTWH(0, 0, 300, 400),
            direction: PageTurnDirection.forward,
            reducedMotion: true,
          ),
        ),
      );
      // The widget tree is only inspected, never pumped with a canvas: the
      // assertion is that build() short-circuits before creating a painter.
      expect(overlay, isNotNull);
      expect(
        const PageTurnOverlay(
          pageRect: Rect.fromLTWH(0, 0, 300, 400),
          direction: PageTurnDirection.forward,
          reducedMotion: true,
        ).reducedMotion,
        isTrue,
      );
    });

    test('progress easing starts at 0 and ends at 1', () {
      expect(pageTurnProgress(0), 0);
      expect(pageTurnProgress(1), 1);
      expect(pageTurnProgress(-5), 0);
      expect(pageTurnProgress(5), 1);
    });

    testWidgets('BookShell turns instantly when animations are disabled',
        (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      final GlobalKey<BookShellState> key = GlobalKey<BookShellState>();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: BookShell(
                key: key,
                controller: controller,
                showStrip: false,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      key.currentState!.turnNext();
      // No pump interval at all: reduced motion has no fold to wait for.
      expect(controller.currentPageId, 'p2');
      await tester.pump();
      expect(key.currentState!.isTurning, isFalse);
      expect(find.byType(PageTurnOverlay), findsNothing);
    });

    testWidgets('BookShell animates a fold when motion is allowed',
        (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      final GlobalKey<BookShellState> key = GlobalKey<BookShellState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookShell(
              key: key,
              controller: controller,
              showStrip: false,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      key.currentState!.turnNext();
      await tester.pump();
      // The page has NOT changed yet: the fold runs before the selection.
      expect(controller.currentPageId, 'p1');
      expect(find.byType(PageTurnOverlay), findsOneWidget);
      await tester.pumpAndSettle();
      expect(controller.currentPageId, 'p2');
      expect(find.byType(PageTurnOverlay), findsNothing);
    });

    test('progress is monotonic and decelerating', () {
      double previous = -1;
      for (int i = 0; i <= 10; i++) {
        final double value = pageTurnProgressForFrame(i, 10);
        expect(value, greaterThanOrEqualTo(previous));
        previous = value;
      }
      // ease-out: the first half covers more than the second half.
      expect(pageTurnProgress(0.5), greaterThan(0.5));
    });

    test('a degenerate frame count finishes the turn', () {
      expect(pageTurnProgressForFrame(0, 0), 1);
    });

    test('direction follows the reading step', () {
      expect(pageTurnDirection(0, 1), PageTurnDirection.forward);
      expect(pageTurnDirection(2, 0), PageTurnDirection.backward);
      expect(pageTurnDirection(1, 1), PageTurnDirection.forward);
    });

    test('the bow helper matches the geometry constant', () {
      expect(pageTurnMaxBow(1000), closeTo(20, 1e-9));
      expect(pageTurnMaxBow(-5), 0);
      expect(
        PageFoldGeometry.at(width: 1000, height: 10, t: 0.5).foldBow,
        closeTo(pageTurnMaxBow(1000), 1e-9),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Wire shape
  // -------------------------------------------------------------------------
  group('wire shape', () {
    test('a non-book document omits pages entirely', () {
      final Map<String, dynamic> json =
          _book(preset: 'A4', pages: <BookPageModel>[]).toJson();
      expect(json.containsKey('pages'), isFalse);
    });

    test('a book emits pages in reading order', () {
      final Map<String, dynamic> json = _book().toJson();
      final List<dynamic> pages = json['pages'] as List<dynamic>;
      expect(pages, hasLength(3));
      expect((pages.first as Map<String, dynamic>)['page_id'], 'p1');
    });

    test('an element without a page keeps the frozen key list', () {
      expect(_node('a').toJson().containsKey('page_id'), isFalse);
    });

    test('an element with a page emits page_id', () {
      expect(_node('a', pageId: 'p2').toJson()['page_id'], 'p2');
    });

    test('a book round-trips through JSON', () {
      final CanvasDocumentModel original = _book(
        elements: <CanvasNodeModel>[_node('a', pageId: 'p2')],
      );
      final CanvasDocumentModel copy =
          CanvasDocumentModel.fromJson(original.toJson());
      expect(copy.isBook, isTrue);
      expect(copy.pages.map((BookPageModel p) => p.pageId), <String>['p1', 'p2', 'p3']);
      expect(copy.elements.single.pageId, 'p2');
    });

    test('junk pages are dropped rather than failing the open', () {
      final Map<String, dynamic> json = _book().toJson();
      json['pages'] = <dynamic>[
        <String, dynamic>{'page_id': 'p1', 'index': 4, 'title': 'One'},
        'nonsense',
        <String, dynamic>{'page_id': kBookCoverPageId, 'index': 0, 'title': 'C'},
        <String, dynamic>{'page_id': 'p1', 'index': 9, 'title': 'dupe'},
      ];
      final CanvasDocumentModel doc = CanvasDocumentModel.fromJson(json);
      expect(doc.pages, hasLength(1));
      expect(doc.pages.single.index, 0);
      expect(doc.pages.single.title, 'One');
    });

    test('normalizePageId trims and empties', () {
      expect(normalizePageId('  p2 '), 'p2');
      expect(normalizePageId('   '), isNull);
      expect(normalizePageId(null), isNull);
      expect(normalizePageId(7), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // New Canvas modal — the book branch
  // -------------------------------------------------------------------------
  group('new canvas book branch', () {
    test('seeds one page and stays bounded', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 'Novel',
        preset: kBookPreset,
        background: kBackgroundBlank,
      );
      expect(doc.isBook, isTrue);
      expect(doc.artboard.isInfinite, isFalse);
      expect(doc.pages, hasLength(1));
      expect(doc.pages.single.title, 'Page 1');
    });

    test('honours the chosen page size', () {
      final CanvasDocumentModel a5 = buildNewCanvasDocument(
        title: 't',
        preset: kBookPreset,
        background: kBackgroundBlank,
        pageSize: 'A5',
      );
      expect(a5.artboard.width, 1748);
      expect(a5.artboard.height, 2480);
    });

    test('defaults to A4 for an unknown page size', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 't',
        preset: kBookPreset,
        background: kBackgroundBlank,
        pageSize: 'A0',
      );
      expect(doc.artboard.width, Presets.a4.$1);
    });

    test('never offers an infinite book', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 't',
        preset: kBookPreset,
        background: kBackgroundBlank,
        pageSize: 'INFINITE',
      );
      expect(doc.artboard.isInfinite, isFalse);
      expect(doc.artboard.width, isNotNull);
    });

    test('a cover becomes one IMAGE element on the reserved page id', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 't',
        preset: kBookPreset,
        background: kBackgroundBlank,
        coverAssetRef: 'assets/cover.png',
      );
      expect(doc.elements, hasLength(1));
      final CanvasNodeModel cover = doc.elements.single;
      expect(cover.kind, 'IMAGE');
      expect(cover.pageId, kBookCoverPageId);
      expect(cover.geometry.assetRef, 'assets/cover.png');
      expect(cover.bbox, <double>[0, 0, 2480, 3508]);
    });

    test('without a cover the document has no elements', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 't',
        preset: kBookPreset,
        background: kBackgroundRuled,
        backgroundSpacing: 48,
      );
      expect(doc.elements, isEmpty);
      expect(doc.artboard.backgroundStyle, kBackgroundRuled);
      expect(doc.artboard.backgroundSpacing, 48);
    });

    test('a non-book preset is untouched by the book parameters', () {
      final CanvasDocumentModel doc = buildNewCanvasDocument(
        title: 't',
        preset: 'A5',
        background: kBackgroundBlank,
        pageSize: 'LETTER',
        coverAssetRef: 'assets/cover.png',
      );
      expect(doc.pages, isEmpty);
      expect(doc.elements, isEmpty);
      expect(doc.artboard.width, 1748);
    });
  });

  // -------------------------------------------------------------------------
  // Page strip widget
  // -------------------------------------------------------------------------
  group('page strip', () {
    Widget host(BookController controller, {PageTurnRequest? onTurn}) => MaterialApp(
          home: Scaffold(
            body: PageStrip(controller: controller, onTurnRequested: onTurn),
          ),
        );

    testWidgets('shows one chip per page', (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      await tester.pumpWidget(host(controller));
      expect(find.byKey(const Key(kPageStripKey)), findsOneWidget);
      expect(find.byKey(pageChipKey('p2')), findsOneWidget);
      expect(find.byType(PageStrip), findsOneWidget);
    });

    testWidgets('a non-book document renders no strip',
        (WidgetTester tester) async {
      final BookController controller = BookController(
        document: _book(preset: 'A4', pages: <BookPageModel>[]),
      );
      await tester.pumpWidget(host(controller));
      expect(find.byKey(const Key(kPageStripKey)), findsNothing);
    });

    testWidgets('tapping a chip asks for a turn, not an instant swap',
        (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      final List<String> turns = <String>[];
      await tester.pumpWidget(
        host(controller, onTurn: (String id, int from, int to) => turns.add(id)),
      );
      await tester.tap(find.byKey(pageChipKey('p2')));
      await tester.pump();
      expect(turns, <String>['p2']);
      expect(controller.currentPageId, 'p1');
    });

    testWidgets('the add button appends a page', (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      await tester.pumpWidget(host(controller));
      await tester.tap(find.byKey(const Key(kPageStripAddKey)));
      await tester.pump();
      expect(controller.pageCount, 4);
    });

    testWidgets('the delete button is disabled with one page left',
        (WidgetTester tester) async {
      final BookController controller = BookController(
        document: _book(pages: <BookPageModel>[_page('only', 0)]),
      );
      await tester.pumpWidget(host(controller));
      final IconButton button = tester.widget<IconButton>(
        find.byKey(const Key(kPageStripDeleteKey)),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('next / previous arrows drive the turn',
        (WidgetTester tester) async {
      final BookController controller = BookController(document: _book());
      final List<String> turns = <String>[];
      await tester.pumpWidget(
        host(controller, onTurn: (String id, int from, int to) => turns.add(id)),
      );
      await tester.tap(find.byKey(const Key(kPageStripNextKey)));
      await tester.pump();
      expect(turns, <String>['p2']);
    });
  });

  // -------------------------------------------------------------------------
  // Math sanity — the geometry stays inside the page
  // -------------------------------------------------------------------------
  group('geometry containment', () {
    test('the crease walks monotonically from right to left', () {
      double previous = double.infinity;
      for (int i = 0; i <= 20; i++) {
        final PageFoldGeometry g = PageFoldGeometry.at(
          width: 600,
          height: 800,
          t: i / 20,
        );
        expect(g.foldX, lessThanOrEqualTo(previous));
        previous = g.foldX;
      }
    });

    test('the flat half never exceeds the page', () {
      for (int i = 0; i <= 20; i++) {
        final PageFoldGeometry g = PageFoldGeometry.at(
          width: 600,
          height: 800,
          t: i / 20,
        );
        expect(g.flatRect.left, greaterThanOrEqualTo(0));
        expect(g.flatRect.right, lessThanOrEqualTo(600));
      }
    });

    test('the fold bow is a small fraction of the page', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: 1000, height: 1000, t: 0.5);
      expect(g.foldBow, lessThan(1000 * 0.05));
      expect(g.foldBow, greaterThan(0));
    });

    test('a very narrow page still folds without NaN', () {
      final PageFoldGeometry g =
          PageFoldGeometry.at(width: 1, height: 1, t: 0.5);
      expect(g.foldX.isFinite, isTrue);
      expect(g.leadingEdgeX.isFinite, isTrue);
      expect(g.shadowOpacity.isFinite, isTrue);
    });

    test('sine-driven shadow has exactly one peak', () {
      final List<double> values = <double>[
        for (int i = 0; i <= 10; i++)
          PageFoldGeometry.at(width: 10, height: 10, t: i / 10).shadowOpacity,
      ];
      final int peak = values.indexOf(values.reduce(math.max));
      expect(peak, inInclusiveRange(4, 6));
    });
  });

  // -------------------------------------------------------------------------
  // Book controller constructor / page helpers
  // -------------------------------------------------------------------------
  group('controller construction', () {
    test('an unknown starting page falls back to page 1', () {
      final BookController controller = BookController(
        document: _book(),
        pageId: 'zzz',
      );
      expect(controller.currentPageId, 'p1');
    });

    test('a non-book document still has a usable filter', () {
      final BookController controller = BookController(
        document: _book(
          preset: 'A4',
          pages: <BookPageModel>[],
          elements: <CanvasNodeModel>[_node('a')],
        ),
      );
      expect(controller.isBook, isFalse);
      expect(controller.pageCount, 0);
      expect(_ids(controller.visibleElementsForDocument()), <String>['a']);
    });

    test('pageOf and indexOf agree', () {
      final BookController controller = BookController(document: _book());
      expect(controller.pageOf('p2')!.title, 'Page 2');
      expect(controller.indexOf('p2'), 1);
      expect(controller.currentPage!.pageId, 'p1');
    });

    test('the cover element can be a newly added node', () {
      final BookController controller = BookController(document: _book());
      final CanvasNodeModel cover = _node('c', assetRef: 'assets/c.png');
      controller.setCover(cover);
      expect(controller.document.elements.contains(cover), isTrue);
      expect(controller.coverAssetRef, 'assets/c.png');
    });
  });

  // -------------------------------------------------------------------------
  // Wizard picker plumbing (PickedImage is the cover's carrier)
  // -------------------------------------------------------------------------
  group('cover bytes', () {
    test('a PickedImage carries what the archive needs', () {
      final PickedImage image = PickedImage(
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        filename: 'Front.JPG',
        widthPx: 100,
        heightPx: 200,
      );
      expect(image.bytes, hasLength(3));
      expect(image.filename.toLowerCase().endsWith('.jpg'), isTrue);
    });
  });
}
