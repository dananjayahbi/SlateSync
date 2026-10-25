/// Round-9 issue 06 — the table tool's initial-configuration popup.
///
/// The user asked for the config to appear *when the tool is selected* — before
/// anything is drawn — and to let them mark a header column. Rows/columns can
/// still be added afterwards from the on-canvas handles the selector shows, so
/// this dialog only needs the starting shape.
library;

import 'package:flutter/material.dart';

import 'package:mobile_app/canvas_engine/table_geometry.dart';
import 'package:mobile_app/core/theme/studio_theme.dart';

/// Result of [showTableConfigPopup].
class TableConfig {
  const TableConfig({
    required this.rows,
    required this.cols,
    required this.headerRow,
    required this.headerCol,
  });

  final int rows;
  final int cols;
  final bool headerRow;
  final bool headerCol;

  TableGridSizeHint get hint => TableGridSizeHint(rows: rows, cols: cols);
}

/// Modal "new table" dialog. Returns `null` when dismissed.
Future<TableConfig?> showTableConfigPopup(BuildContext context) =>
    showDialog<TableConfig>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext ctx) => const _TableConfigDialog(),
    );

class _TableConfigDialog extends StatefulWidget {
  const _TableConfigDialog();

  @override
  State<_TableConfigDialog> createState() => _TableConfigDialogState();
}

class _TableConfigDialogState extends State<_TableConfigDialog> {
  int _rows = kDefaultTableRows;
  int _cols = kDefaultTableCols;
  bool _headerRow = true;
  bool _headerCol = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('table-config-dialog'),
      backgroundColor: StudioTheme.surface,
      title: const Text(
        'New table',
        style: TextStyle(color: StudioTheme.text, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _stepper(
            label: 'Rows',
            value: _rows,
            keyName: 'table-rows',
            min: kMinTableRows,
            max: kMaxTableRows,
            onChanged: (int v) => setState(() => _rows = v),
          ),
          const SizedBox(height: 8),
          _stepper(
            label: 'Columns',
            value: _cols,
            keyName: 'table-cols',
            min: kMinTableCols,
            max: kMaxTableCols,
            onChanged: (int v) => setState(() => _cols = v),
          ),
          const SizedBox(height: 4),
          _toggle(
            label: 'Header row',
            keyName: 'table-header-row',
            value: _headerRow,
            enabled: _rows >= 2,
            onChanged: (bool v) => setState(() => _headerRow = v),
          ),
          _toggle(
            label: 'Header column',
            keyName: 'table-header-col',
            value: _headerCol,
            enabled: _cols >= 2,
            onChanged: (bool v) => setState(() => _headerCol = v),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('table-config-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('table-config-confirm'),
          onPressed: () => Navigator.of(context).pop(
            TableConfig(
              rows: _rows,
              cols: _cols,
              headerRow: _headerRow && _rows >= 2,
              headerCol: _headerCol && _cols >= 2,
            ),
          ),
          child: const Text(
            'Add table',
            style: TextStyle(color: StudioTheme.accent),
          ),
        ),
      ],
    );
  }

  Widget _stepper({
    required String label,
    required int value,
    required String keyName,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: StudioTheme.text,
            fontSize: StudioTheme.bodySize,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              key: ValueKey<String>('$keyName-dec'),
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_circle_outline, size: 20),
            ),
            SizedBox(
              width: 32,
              child: Text(
                '$value',
                key: ValueKey<String>('$keyName-value'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: StudioTheme.text),
              ),
            ),
            IconButton(
              key: ValueKey<String>('$keyName-inc'),
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_circle_outline, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  Widget _toggle({
    required String label,
    required String keyName,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      key: ValueKey<String>(keyName),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: TextStyle(
          color: enabled ? StudioTheme.text : StudioTheme.text.withValues(alpha: 0.4),
          fontSize: StudioTheme.bodySize,
        ),
      ),
      value: value && enabled,
      onChanged: enabled ? onChanged : null,
    );
  }
}
