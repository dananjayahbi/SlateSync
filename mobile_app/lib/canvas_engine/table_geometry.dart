/// Round-9 issue 06 — the table tool's geometry and config.
///
/// A table is stored as a single `SHAPE` node with
/// `shape_type: "TABLE"` and its grid in `graph_config` (`rows`, `cols`,
/// `header_row`, `header_col`) — the same "config object on a shape" shape the
/// graph tools already use, which means the frozen Doc 03 schema needs no new
/// node type and every existing renderer path (mobile painter, PC viewport,
/// three exporters) gains tables by reading one extra `shape_type`.
///
/// `graph_config` is preserved verbatim on the wire, so the nested keys are
/// snake_case. `rows` / `cols` are TOTAL cell counts (header band included),
/// matching the PC `table_geometry` implementation exactly — the two sides
/// must agree or the mirror's gridlines would drift from the tablet's.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset, Rect;

/// Guard rails, identical to the PC `vector_geometry` clamps.
const int kMinTableRows = 1;
const int kMaxTableRows = 200;
const int kMinTableCols = 1;
const int kMaxTableCols = 40;

/// Default new-table shape (3×3 with a header row, like a spreadsheet).
const int kDefaultTableRows = 3;
const int kDefaultTableCols = 3;

/// Size of one default cell in world units (the drag sets the real size).
const double kDefaultTableCellSize = 140.0;

/// Grid description of a table node.
class TableGrid {
  const TableGrid({
    required this.box,
    required this.rows,
    required this.cols,
    required this.headerRow,
    required this.headerCol,
  });

  final Rect box;
  final int rows;
  final int cols;
  final bool headerRow;
  final bool headerCol;

  /// Row boundaries, top → bottom (`rows + 1` values).
  List<double> get rowEdges => <double>[
        for (int i = 0; i <= rows; i++) box.top + box.height * i / rows,
      ];

  /// Column boundaries, left → right (`cols + 1` values).
  List<double> get colEdges => <double>[
        for (int i = 0; i <= cols; i++) box.left + box.width * i / cols,
      ];

  /// Every grid segment, borders included.
  List<(Offset, Offset)> get lines {
    final List<(Offset, Offset)> out = <(Offset, Offset)>[];
    for (final double y in rowEdges) {
      out.add((Offset(box.left, y), Offset(box.right, y)));
    }
    for (final double x in colEdges) {
      out.add((Offset(x, box.top), Offset(x, box.bottom)));
    }
    return out;
  }

  /// Filled header bands. The corner cell belongs to the row band only, so the
  /// two bands never double-paint.
  List<Rect> get headerRects {
    final List<double> re = rowEdges;
    final List<double> ce = colEdges;
    final List<Rect> out = <Rect>[];
    if (headerRow) {
      out.add(Rect.fromLTRB(box.left, re[0], box.right, re[1]));
    }
    if (headerCol) {
      final double top = headerRow ? re[1] : re[0];
      out.add(Rect.fromLTRB(ce[0], top, ce[1], box.bottom));
    }
    return out;
  }

  /// Cell rect at ([row], [col]), clamped into the grid.
  Rect cellRect(int row, int col) {
    final List<double> re = rowEdges;
    final List<double> ce = colEdges;
    final int r = row.clamp(0, rows - 1);
    final int c = col.clamp(0, cols - 1);
    return Rect.fromLTRB(ce[c], re[r], ce[c + 1], re[r + 1]);
  }

  /// The row band the add-row handle hangs off (the last row).
  Rect get lastRowBand => cellRect(rows - 1, 0);

  /// The column band the add-column handle hangs off (the last column).
  Rect get lastColBand => cellRect(0, cols - 1);
}

/// Builds the `graph_config` map for a TABLE node.
Map<String, dynamic> buildTableConfig({
  required int rows,
  required int cols,
  bool headerRow = true,
  bool headerCol = false,
}) =>
    <String, dynamic>{
      'rows': rows.clamp(kMinTableRows, kMaxTableRows).toInt(),
      'cols': cols.clamp(kMinTableCols, kMaxTableCols).toInt(),
      'header_row': headerRow,
      'header_col': headerCol,
    };

/// Reads the grid back out of a node's `graph_config`, tolerant of a corrupt or
/// missing map (falls back to a 3×3 header table).
TableGrid tableGridOf(Rect box, Map<String, dynamic>? config) {
  final Map<String, dynamic> cfg = config ?? const <String, dynamic>{};
  final int rows = _intIn(cfg['rows'], kDefaultTableRows, kMinTableRows, kMaxTableRows);
  final int cols = _intIn(cfg['cols'], kDefaultTableCols, kMinTableCols, kMaxTableCols);
  final bool headerRow = cfg['header_row'] != false && rows >= 2;
  final bool headerCol = cfg['header_col'] == true && cols >= 2;
  return TableGrid(
    box: box,
    rows: rows,
    cols: cols,
    headerRow: headerRow,
    headerCol: headerCol,
  );
}

/// Copies [config] with one extra row / column.
///
/// Rebuilds the map rather than mutating it: `graph_config` maps are shared
/// with the node that was handed to the engine and the RPC payload, so an
/// in-place edit would silently rewrite the node the mirror already has.
Map<String, dynamic> withExtraRow(Map<String, dynamic>? config) {
  final Map<String, dynamic> cfg =
      Map<String, dynamic>.from(config ?? const <String, dynamic>{});
  final int rows = _intIn(cfg['rows'], kDefaultTableRows, kMinTableRows, kMaxTableRows);
  cfg['rows'] = math.min(kMaxTableRows, rows + 1);
  return cfg;
}

/// Copies [config] with one extra column.
Map<String, dynamic> withExtraColumn(Map<String, dynamic>? config) {
  final Map<String, dynamic> cfg =
      Map<String, dynamic>.from(config ?? const <String, dynamic>{});
  final int cols = _intIn(cfg['cols'], kDefaultTableCols, kMinTableCols, kMaxTableCols);
  cfg['cols'] = math.min(kMaxTableCols, cols + 1);
  return cfg;
}

/// The rect a new table occupies when dragged from [start] to [end], with a
/// minimum size so a stray tap still produces a usable grid.
Rect planTableRect(Offset start, Offset end, TableGridSizeHint hint) {
  final Rect raw = Rect.fromPoints(start, end);
  final double minW = hint.cols * kDefaultTableCellSize * 0.5;
  final double minH = hint.rows * kDefaultTableCellSize * 0.5;
  return Rect.fromLTWH(
    raw.left,
    raw.top,
    math.max(raw.width, minW),
    math.max(raw.height, minH),
  );
}

/// Row/column counts chosen in the config popup before the table is drawn.
class TableGridSizeHint {
  const TableGridSizeHint({required this.rows, required this.cols});
  final int rows;
  final int cols;
}

int _intIn(Object? value, int fallback, int low, int high) {
  if (value is num) {
    return value.toInt().clamp(low, high).toInt();
  }
  if (value is String) {
    final int? parsed = int.tryParse(value.trim());
    if (parsed != null) {
      return parsed.clamp(low, high).toInt();
    }
  }
  return fallback;
}
