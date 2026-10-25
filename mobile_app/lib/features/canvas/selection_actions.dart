/// Round-9 issue 05/06 — the selector's per-object action chrome.
///
/// The user was explicit about placement: *"all these explained selector tools
/// per things like rotate, locking, column, row things will be at the relevant
/// object. Be smart where we should display them. For example, rows icons
/// should be at the bottom of the table."*
///
/// So this is three separate widgets rather than one toolbar:
///
/// * [SelectionActionBar] — floats just ABOVE the selection box: lock / unlock,
///   rotate (shapes only, and only when every selected object is rotatable) and
///   delete.
/// * [TableGrowHandles] — the add-row handle sits BELOW the table's bottom
///   edge and the add-column handle sits to its RIGHT, exactly where a
///   spreadsheet puts them.
///
/// Both are positioned in SCREEN space by the caller (which owns the camera),
/// so they stay finger-sized at any zoom.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/core/theme/studio_theme.dart';

/// Actions the selector offers for the current selection.
class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    super.key,
    required this.anchor,
    required this.locked,
    required this.canLock,
    required this.canRotate,
    required this.canFill,
    required this.filled,
    required this.onLock,
    required this.onUnlock,
    required this.onRotate,
    required this.onFill,
    required this.onDelete,
  });

  /// Screen-space offset of the selection box's TOP-LEFT corner.
  final Offset anchor;

  /// `true` when the selection is entirely inside one locked group.
  final bool locked;

  /// `false` when a locked group should be grown instead of locked.
  final bool canLock;

  /// `true` when every selected object is a rotatable shape (never a stroke).
  final bool canRotate;

  final bool canFill;
  final bool filled;

  final VoidCallback onLock;
  final VoidCallback onUnlock;
  final VoidCallback onRotate;
  final VoidCallback onFill;
  final VoidCallback onDelete;

  static const double _size = 34;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final List<Widget> buttons = <Widget>[
      if (locked)
        _button(
          keyName: 'selection-unlock',
          icon: Icons.lock_open,
          tooltip: 'Unlock group',
          onPressed: onUnlock,
          tint: StudioTheme.accent,
        )
      else if (canLock)
        _button(
          keyName: 'selection-lock',
          icon: Icons.lock_outline,
          tooltip: 'Lock as a group',
          onPressed: onLock,
        ),
      if (canRotate)
        _button(
          keyName: 'selection-rotate',
          icon: Icons.rotate_right,
          tooltip: 'Rotate 15°',
          onPressed: onRotate,
        ),
      if (canFill)
        _button(
          keyName: 'selection-fill',
          icon: filled ? Icons.format_color_reset : Icons.format_color_fill,
          tooltip: filled ? 'Clear fill' : 'Fill',
          onPressed: onFill,
        ),
      _button(
        keyName: 'selection-delete',
        icon: Icons.delete_outline,
        tooltip: 'Delete selection',
        onPressed: onDelete,
        tint: StudioTheme.danger,
      ),
    ];
    return Positioned(
      left: anchor.dx,
      top: anchor.dy - (_size + 10),
      child: Material(
        key: const ValueKey<String>('selection-action-bar'),
        color: StudioTheme.surface,
        elevation: 6,
        borderRadius: BorderRadius.circular(StudioTheme.radiusSmall),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < buttons.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: _gap),
                buttons[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String keyName,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? tint,
  }) {
    return IconButton(
      key: ValueKey<String>(keyName),
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: _size, height: _size),
      icon: Icon(icon, color: tint ?? StudioTheme.text),
    );
  }
}

/// Add-row (below the table) and add-column (right of the table) handles.
class TableGrowHandles extends StatelessWidget {
  const TableGrowHandles({
    super.key,
    required this.rowAnchor,
    required this.colAnchor,
    required this.onAddRow,
    required this.onAddColumn,
  });

  /// Screen-space CENTRE of the table's bottom edge.
  final Offset rowAnchor;

  /// Screen-space CENTRE of the table's right edge.
  final Offset colAnchor;

  final VoidCallback onAddRow;
  final VoidCallback onAddColumn;

  static const double _size = 26;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned(
          left: rowAnchor.dx - _size / 2,
          top: rowAnchor.dy + 4,
          child: _chip(
            keyName: 'table-add-row',
            icon: Icons.add,
            tooltip: 'Add row',
            onPressed: onAddRow,
          ),
        ),
        Positioned(
          left: colAnchor.dx + 4,
          top: colAnchor.dy - _size / 2,
          child: _chip(
            keyName: 'table-add-column',
            icon: Icons.add,
            tooltip: 'Add column',
            onPressed: onAddColumn,
          ),
        ),
      ],
    );
  }

  Widget _chip({
    required String keyName,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: StudioTheme.accent,
      shape: const CircleBorder(),
      elevation: 4,
      child: IconButton(
        key: ValueKey<String>(keyName),
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: _size, height: _size),
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }
}

/// A small lock badge drawn on a locked group (the member outline is drawn as
/// one box by [CanvasSelectionOverlay]).
class LockBadge extends StatelessWidget {
  const LockBadge({super.key, required this.anchor});

  /// Screen-space offset of the group box's TOP-LEFT corner.
  final Offset anchor;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: anchor.dx - 10,
      top: anchor.dy - 10,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey<String>('group-lock-badge'),
          width: 20,
          height: 20,
          decoration: const BoxDecoration(
            color: StudioTheme.accent,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.lock, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}
