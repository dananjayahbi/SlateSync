/// Round-13 issue 04 — the book shell.
///
/// Glue only: it owns the page-turn animation state that a *canvas* must not
/// own, hosts the fold overlay above the child, and the page strip below it.
/// The canvas itself is handed in as [child] and is never rebuilt from scratch
/// per turn — only its page FILTER changes — so the tile cache, live strokes and
/// selector survive a turn untouched.
///
/// Two behaviours are load-bearing here:
///
/// * **Reduced motion.** When `MediaQuery.disableAnimations` is set the turn is
///   instantaneous — the page changes on the same frame and no fold is mounted.
///   A full-page fold is precisely the animation that triggers motion sickness,
///   so honouring the platform flag is not optional.
/// * **Turn before content.** The reader's target page is captured first, then
///   the fold runs, then the controller is told to select it. Selecting first
///   would show the new page under a fold of the old one.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/features/book/book_controller.dart';
import 'package:mobile_app/features/book/page_turn_overlay.dart';
import 'package:mobile_app/features/book/page_turn_painter.dart';
import 'package:mobile_app/features/canvas/page_strip.dart';

/// Wraps a book canvas with the page-turn overlay and the page strip.
class BookShell extends StatefulWidget {
  const BookShell({
    super.key,
    required this.controller,
    required this.child,
    this.showStrip = true,
    this.duration = kPageTurnDuration,
    this.paperColor = const Color(0xFFFFFFFF),
  });

  final BookController controller;

  /// The canvas. Kept as a child so a turn does not rebuild its state.
  final Widget child;

  final bool showStrip;
  final Duration duration;
  final Color paperColor;

  @override
  State<BookShell> createState() => BookShellState();
}

/// Public so a studio page can drive a turn from a keyboard shortcut without
/// reaching into the animation controller.
class BookShellState extends State<BookShell> {
  /// Page to land on once the running fold finishes; `null` when idle.
  String? _pendingPageId;
  PageTurnDirection _direction = PageTurnDirection.forward;
  Rect _pageRect = Rect.zero;
  bool _turning = false;

  /// True while a fold is on screen.
  bool get isTurning => _turning && !_reducedMotion(context);

  bool _reducedMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPageChanged);
  }

  @override
  void didUpdateWidget(BookShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPageChanged);
      widget.controller.addListener(_onPageChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onPageChanged);
    super.dispose();
  }

  void _onPageChanged() {
    // External selection (keyboard, tests, sync) lands without a fold, so the
    // overlay must not be left mid-turn.
    if (_pendingPageId != null && _pendingPageId == widget.controller.currentPageId) {
      _pendingPageId = null;
      if (mounted) {
        setState(() => _turning = false);
      }
    }
  }

  /// Turn to [pageId], animating a fold unless reduced motion is on.
  ///
  /// Returns the page id actually selected (or `null` if the target was not a
  /// page of this book).
  String? turnTo(String? pageId) {
    final int target = widget.controller.indexOf(pageId);
    if (target < 0) {
      return null;
    }
    final int from = widget.controller.currentIndex;
    if (target == from) {
      return widget.controller.currentPageId;
    }
    _direction = pageTurnDirection(from, target);
    if (_reducedMotion(context)) {
      return widget.controller.select(pageId);
    }
    _pendingPageId = pageId;
    setState(() => _turning = true);
    return widget.controller.currentPageId;
  }

  /// Step one page forward with a fold.
  String? turnNext() {
    final int next = widget.controller.currentIndex + 1;
    if (next >= widget.controller.pageCount) {
      return null;
    }
    return turnTo(widget.controller.pages[next].pageId);
  }

  /// Step one page back with a fold.
  String? turnPrevious() {
    final int previous = widget.controller.currentIndex - 1;
    if (previous < 0) {
      return null;
    }
    return turnTo(widget.controller.pages[previous].pageId);
  }

  void _onTurnCompleted() {
    final String? target = _pendingPageId;
    _pendingPageId = null;
    if (target != null) {
      widget.controller.select(target);
    }
    if (mounted) {
      setState(() => _turning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = _reducedMotion(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget body = widget.showStrip
            ? Column(
                children: <Widget>[
                  Expanded(child: widget.child),
                  PageStrip(
                    controller: widget.controller,
                    onTurnRequested: (String pageId, int from, int to) =>
                        turnTo(pageId),
                  ),
                ],
              )
            : widget.child;
        return Stack(
          children: <Widget>[
            body,
            if (_turning && !reduced)
              Positioned.fill(
                child: PageTurnOverlay(
                  pageRect: _pageRectFor(constraints),
                  direction: _direction,
                  reducedMotion: reduced,
                  duration: widget.duration,
                  paperColor: widget.paperColor,
                  onTurnCompleted: _onTurnCompleted,
                ),
              ),
          ],
        );
      },
    );
  }

  /// The fold covers the free area above the strip, which is where the page is
  /// drawn; the strip is chrome, not paper.
  Rect _pageRectFor(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
      return _pageRect;
    }
    final double stripHeight = widget.showStrip ? kPageStripHeight : 0;
    _pageRect = Rect.fromLTWH(
      0,
      0,
      constraints.maxWidth,
      (constraints.maxHeight - stripHeight).clamp(0.0, constraints.maxHeight),
    );
    return _pageRect;
  }
}
