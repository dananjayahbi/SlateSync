/// Round-13 issue 04 — the book page strip.
///
/// A horizontal reel of page chips under the canvas: tap to select, long-press
/// to rename, drag to reorder, `+` to append, and a delete control for the
/// current page. Back/forward arrows flank it and drive the same page turn the
/// keyboard and the fold animation use — the strip never changes page content
/// itself, it only asks [BookController] to, so the canvas keeps one source of
/// truth.
///
/// Deliberately dumb about the canvas: it needs the controller and nothing else,
/// which is what lets the studio page mount it without touching its own state
/// machine.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/models/canvas_models.dart'; // Doc 05
import 'package:mobile_app/core/theme/studio_theme.dart'; // Doc 05
import 'package:mobile_app/features/book/book_controller.dart';

/// Height reserved for the strip, so the canvas can inset by it exactly.
const double kPageStripHeight = 76;

/// Keys used by the strip (stable for widget tests).
const String kPageStripKey = 'book_page_strip';
const String kPageStripAddKey = 'book_page_add';
const String kPageStripDeleteKey = 'book_page_delete';
const String kPageStripNextKey = 'book_page_next';
const String kPageStripPreviousKey = 'book_page_previous';

/// Key for one page chip.
Key pageChipKey(String pageId) => Key('book_page_chip_$pageId');

/// Fires when the reader asks to move to another page.
///
/// Separate from the controller call so the caller can run the fold animation
/// BEFORE the page content changes; [BookController.select] alone would swap
/// content instantly and make the fold pointless.
typedef PageTurnRequest = void Function(
  String pageId,
  int fromIndex,
  int toIndex,
);

/// Bottom strip: page chips plus turn/add/delete controls.
class PageStrip extends StatelessWidget {
  const PageStrip({
    super.key,
    required this.controller,
    this.onTurnRequested,
    this.onAddRequested,
    this.onDeleteRequested,
    this.onReorder,
    this.onRenameRequested,
    this.height = kPageStripHeight,
  });

  final BookController controller;

  /// Navigates with a page turn; when absent, pages change instantly.
  final PageTurnRequest? onTurnRequested;

  /// Called instead of [BookController.addPage] when provided (undo hooks).
  final VoidCallback? onAddRequested;

  /// Called instead of [BookController.deletePage] when provided.
  final void Function(String pageId)? onDeleteRequested;

  /// Called with the new id order after a drag reorder.
  final void Function(List<String> order)? onReorder;

  /// Called with (pageId, currentTitle) when the reader long-presses a chip.
  final void Function(String pageId, String title)? onRenameRequested;

  final double height;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        if (!controller.isBook) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          key: const Key(kPageStripKey),
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: StudioTheme.surface,
              border: Border(
                top: BorderSide(
                  color: StudioTheme.text.withValues(alpha: 0.12),
                ),
              ),
            ),
            child: Row(
              children: <Widget>[
                _turnButton(
                  key: const Key(kPageStripPreviousKey),
                  icon: Icons.chevron_left,
                  tooltip: 'Previous page',
                  enabled: controller.canGoPrevious,
                  onPressed: () => _turnTo(controller.currentIndex - 1),
                ),
                Expanded(child: _reel(context)),
                _turnButton(
                  key: const Key(kPageStripNextKey),
                  icon: Icons.chevron_right,
                  tooltip: 'Next page',
                  enabled: controller.canGoNext,
                  onPressed: () => _turnTo(controller.currentIndex + 1),
                ),
                IconButton(
                  key: const Key(kPageStripAddKey),
                  icon: const Icon(Icons.add),
                  tooltip: 'Add page',
                  onPressed: () => _add(context),
                ),
                IconButton(
                  key: const Key(kPageStripDeleteKey),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: controller.pageCount <= 1
                      ? 'A book keeps at least one page'
                      : 'Delete page',
                  onPressed: controller.pageCount <= 1
                      ? null
                      : () => _delete(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _reel(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: controller.pageCount,
      itemBuilder: (BuildContext context, int index) {
        final BookPageModel page = controller.pages[index];
        return _chip(context, page, index);
      },
    );
  }

  Widget _chip(BuildContext context, BookPageModel page, int index) {
    final bool selected = index == controller.currentIndex;
    final Color tint = selected ? StudioTheme.accent : StudioTheme.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
      child: DragTarget<int>(
        onWillAcceptWithDetails: (DragTargetDetails<int> details) =>
            details.data != index,
        onAcceptWithDetails: (DragTargetDetails<int> details) =>
            _move(details.data, index),
        builder: (
          BuildContext context,
          List<int?> candidates,
          List<dynamic> rejected,
        ) {
          final Widget chip = InkWell(
            key: pageChipKey(page.pageId),
            borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
            onTap: () => _turnTo(index),
            onLongPress: onRenameRequested == null
                ? null
                : () => onRenameRequested!(page.pageId, page.title),
            child: Container(
              constraints: const BoxConstraints(minWidth: 74),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? StudioTheme.accent.withValues(alpha: 0.16)
                    : StudioTheme.bg,
                borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
                border: Border.all(
                  color: selected
                      ? StudioTheme.accent
                      : StudioTheme.text.withValues(alpha: 0.18),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    page.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tint,
                      fontSize: StudioTheme.bodySize,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    'Page ${index + 1}',
                    style: TextStyle(
                      color: StudioTheme.subText,
                      fontSize: StudioTheme.captionSize,
                    ),
                  ),
                ],
              ),
            ),
          );
          if (candidates.isNotEmpty) {
            // Highlight the drop target rather than previewing the move: the
            // strip is short and a preview would reflow the whole reel.
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: StudioTheme.accent.withValues(alpha: 0.45),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: chip,
            );
          }
          return LongPressDraggable<int>(
            data: index,
            feedback: Material(
              color: Colors.transparent,
              child: Opacity(opacity: 0.9, child: chip),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: chip),
            child: chip,
          );
        },
      ),
    );
  }

  Widget _turnButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
    );
  }

  void _turnTo(int index) {
    if (index < 0 || index >= controller.pageCount) {
      return;
    }
    final int from = controller.currentIndex;
    if (index == from) {
      return;
    }
    final String pageId = controller.pages[index].pageId;
    final PageTurnRequest? request = onTurnRequested;
    if (request != null) {
      request(pageId, from, index);
      return;
    }
    controller.select(pageId);
  }

  void _add(BuildContext context) {
    final VoidCallback? hook = onAddRequested;
    if (hook != null) {
      hook();
      return;
    }
    controller.addPage();
  }

  void _delete(BuildContext context) {
    final String? current = controller.currentPageId;
    if (current == null) {
      return;
    }
    final void Function(String pageId)? hook = onDeleteRequested;
    if (hook != null) {
      hook(current);
      return;
    }
    controller.deletePage(current);
  }

  void _move(int from, int to) {
    final String pageId = controller.pages[from].pageId;
    if (!controller.movePage(pageId, to)) {
      return;
    }
    onReorder?.call(controller.pageIds);
  }
}
