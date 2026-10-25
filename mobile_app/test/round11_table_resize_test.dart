/// Round 11 — issue 03: a table must lose a row or a column after placement.
///
/// Round 9 added *grow* handles; the user then asked for the opposite ("we need
/// a way to delete columns and rows after draw the table as well"). Two rules
/// make removal safe, and both live in `table_geometry.dart`:
///
/// * the grid may never go below one cell (`withFewerRow` / `withFewerColumn`
///   return `null` so the caller can disable the handle instead of emitting an
///   invalid grid);
/// * dropping to a single row/column also drops the header flag — a header band
///   over the only row would hide the data.
library;

import 'package:flutter/widgets.dart' show Rect;
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/canvas_engine/table_geometry.dart';

void main() {
  group('withFewerRow', () {
    test('removes exactly one row and keeps the column count', () {
      final Map<String, dynamic> start =
          buildTableConfig(rows: 4, cols: 3, headerRow: true);
      final Map<String, dynamic>? next = withFewerRow(start);
      expect(next, isNotNull);
      expect(next!['rows'], 3);
      expect(next['cols'], 3);
    });

    test('refuses to drop below one row', () {
      final Map<String, dynamic> one =
          buildTableConfig(rows: 1, cols: 3, headerRow: false);
      expect(withFewerRow(one), isNull);
    });

    test('clears the header when only one row remains', () {
      final Map<String, dynamic> two =
          buildTableConfig(rows: 2, cols: 3, headerRow: true);
      final Map<String, dynamic>? next = withFewerRow(two);
      expect(next, isNotNull);
      expect(next!['rows'], 1);
      expect(next['header_row'], isFalse);
    });

    test('keeps the header while two or more rows remain', () {
      final Map<String, dynamic> three =
          buildTableConfig(rows: 3, cols: 3, headerRow: true);
      expect(withFewerRow(three)!['header_row'], isTrue);
    });

    test('does not mutate the map it was handed', () {
      final Map<String, dynamic> start =
          buildTableConfig(rows: 4, cols: 3, headerRow: true);
      final Map<String, dynamic> copy = Map<String, dynamic>.from(start);
      withFewerRow(start);
      expect(start, copy);
    });
  });

  group('withFewerColumn', () {
    test('removes exactly one column and keeps the row count', () {
      final Map<String, dynamic>? next =
          withFewerColumn(buildTableConfig(rows: 3, cols: 5));
      expect(next, isNotNull);
      expect(next!['cols'], 4);
      expect(next['rows'], 3);
    });

    test('refuses to drop below one column', () {
      expect(withFewerColumn(buildTableConfig(rows: 3, cols: 1)), isNull);
    });

    test('clears the header column when only one column remains', () {
      final Map<String, dynamic> two = buildTableConfig(
        rows: 3,
        cols: 2,
        headerRow: false,
        headerCol: true,
      );
      final Map<String, dynamic>? next = withFewerColumn(two);
      expect(next, isNotNull);
      expect(next!['cols'], 1);
      expect(next['header_col'], isFalse);
    });
  });

  group('round trip', () {
    test('grow then shrink returns the original grid', () {
      final Map<String, dynamic> start = buildTableConfig(rows: 3, cols: 4);
      final Map<String, dynamic> grown = withExtraColumn(withExtraRow(start));
      final Map<String, dynamic> back =
          withFewerColumn(withFewerRow(grown))!;
      expect(back['rows'], start['rows']);
      expect(back['cols'], start['cols']);
    });

    test('the max clamps still hold', () {
      expect(kMinTableRows, 1);
      expect(kMinTableCols, 1);
      expect(
        withExtraRow(buildTableConfig(rows: kMaxTableRows, cols: 3))['rows'],
        kMaxTableRows,
      );
      expect(
        withExtraColumn(buildTableConfig(rows: 3, cols: kMaxTableCols))['cols'],
        kMaxTableCols,
      );
    });

    test('a shrunk config still renders the remaining grid', () {
      final Map<String, dynamic> shrunk =
          withFewerColumn(withFewerRow(buildTableConfig(rows: 4, cols: 4)))!;
      final TableGrid grid =
          tableGridOf(const Rect.fromLTWH(0, 0, 400, 400), shrunk);
      expect(grid.rows, 3);
      expect(grid.cols, 3);
      expect(grid.rowEdges.length, 4); // rows + 1 boundaries
      expect(grid.colEdges.length, 4);
    });
  });
}
