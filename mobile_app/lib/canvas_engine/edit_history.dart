/// Round-9 issue 03 — undo/redo for the canvas document.
///
/// The engine is a tile cache and the page mutates `doc.elements` directly,
/// so the only state an undo has to restore is the element list (plus the
/// round-9 lock groups, which are document-level bookkeeping). This module
/// snapshots exactly that and keeps two bounded stacks.
///
/// **Snapshots, not commands.** Every canvas mutation in the page already
/// funnels through a handful of helpers (`_commitStroke`, `_commitElement`,
/// `_deleteNode`, `_replaceWithFragments`, `_applyTransform`, …) and several
/// of them emit MULTIPLE RPCs for one user gesture (a transform is a
/// `DELETE_NODE` + `ADD_*` pair). A command log would have to model that
/// pairing in two places; a snapshot taken *before* a user gesture and
/// compared *after* it cannot drift out of sync with the mutation set.
///
/// Deliberately free of Flutter imports: the page owns the buttons, this
/// module owns the stacks, so it is unit-testable without a widget tree.
library;

import 'package:mobile_app/core/models/canvas_models.dart';

/// One restorable document state: every element serialised plus the groups.
class CanvasSnapshot {
  const CanvasSnapshot(this.elements, this.groups);

  /// Element JSON in document order (deep copies — a node's `pts`, `bbox` and
  /// `style` are mutable, so a shallow list copy would follow later edits).
  final List<Map<String, dynamic>> elements;

  /// `group_id → member ids` at snapshot time.
  final Map<String, List<String>> groups;

  int get nodeCount => elements.length;

  /// Rebuilds the node list from the snapshot (fresh objects every call, so a
  /// restored list can be mutated without corrupting the stack).
  List<CanvasNodeModel> buildNodes() => elements
      .map((Map<String, dynamic> json) => CanvasNodeModel.fromJson(json))
      .toList();

  /// Copies the groups map so a restored document cannot alias the stack.
  Map<String, List<String>> buildGroups() => <String, List<String>>{
        for (final MapEntry<String, List<String>> e in groups.entries)
          e.key: List<String>.of(e.value),
      };
}

/// Captures the current state of [doc].
CanvasSnapshot snapshotOf(CanvasDocumentModel doc) => CanvasSnapshot(
      doc.elements
          .map((CanvasNodeModel n) => n.toJson())
          .toList(growable: false),
      <String, List<String>>{
        for (final MapEntry<String, List<String>> e in doc.groups.entries)
          e.key: List<String>.of(e.value),
      },
    );

/// Bounded undo/redo stacks over [CanvasSnapshot].
///
/// Usage is always the same pair: [record] the state *before* a gesture, then
/// [commit] it once the gesture actually changed something. A gesture that
/// turns out to be a no-op (a tap that drew nothing) is discarded, so the
/// buttons never step through invisible edits.
class EditHistory {
  EditHistory({this.limit = 60});

  /// Maximum number of undo steps retained. Older states are dropped from the
  /// bottom — undo is a convenience, not an audit log, and an unbounded stack
  /// would keep whole canvases alive on a tablet.
  final int limit;

  final List<CanvasSnapshot> _undo = <CanvasSnapshot>[];
  final List<CanvasSnapshot> _redo = <CanvasSnapshot>[];
  CanvasSnapshot? _pending;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Diagnostic counters for the top-bar buttons and tests.
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;

  /// Remembers [state] as the "before" of a gesture in progress.
  void record(CanvasSnapshot state) => _pending = state;

  /// Finishes the gesture: pushes [after] onto the undo stack unless it equals
  /// the recorded "before" (nothing happened).
  ///
  /// Returns `true` when a step was actually pushed, so callers can skip a
  /// rebuild. Any redo history is invalidated — a new edit always abandons the
  /// branch the user had rewound.
  bool commit(CanvasSnapshot after) {
    final CanvasSnapshot? before = _pending;
    _pending = null;
    if (before == null || _sameState(before, after)) {
      return false;
    }
    _undo.add(before);
    if (_undo.length > limit) {
      _undo.removeRange(0, _undo.length - limit);
    }
    _redo.clear();
    return true;
  }

  /// Drops a pending record (a gesture that was cancelled).
  void discard() => _pending = null;

  /// Pops the previous state; [current] is pushed onto the redo stack.
  /// Returns `null` when there is nothing to undo.
  CanvasSnapshot? undo(CanvasSnapshot current) {
    if (_undo.isEmpty) {
      return null;
    }
    final CanvasSnapshot state = _undo.removeLast();
    _redo.add(current);
    if (_redo.length > limit) {
      _redo.removeRange(0, _redo.length - limit);
    }
    return state;
  }

  /// Pops the next state; [current] is pushed back onto the undo stack.
  CanvasSnapshot? redo(CanvasSnapshot current) {
    if (_redo.isEmpty) {
      return null;
    }
    final CanvasSnapshot state = _redo.removeLast();
    _undo.add(current);
    if (_undo.length > limit) {
      _undo.removeRange(0, _undo.length - limit);
    }
    return state;
  }

  /// Forgets everything (used when a different canvas is opened).
  void clear() {
    _undo.clear();
    _redo.clear();
    _pending = null;
  }

  /// Structural equality of two snapshots — the "did anything change?" test.
  ///
  /// Compares the serialised elements field by field rather than by identity:
  /// `toJson()` allocates a fresh map every call, so `==` would always be
  /// false. Group order is not significant, so groups are compared as sets.
  static bool _sameState(CanvasSnapshot a, CanvasSnapshot b) {
    if (a.elements.length != b.elements.length) {
      return false;
    }
    for (int i = 0; i < a.elements.length; i++) {
      if (!_sameJson(a.elements[i], b.elements[i])) {
        return false;
      }
    }
    if (a.groups.length != b.groups.length) {
      return false;
    }
    for (final MapEntry<String, List<String>> e in a.groups.entries) {
      final List<String>? other = b.groups[e.key];
      if (other == null || other.length != e.value.length) {
        return false;
      }
      for (int i = 0; i < e.value.length; i++) {
        if (e.value[i] != other[i]) {
          return false;
        }
      }
    }
    return true;
  }

  static bool _sameJson(Object? a, Object? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) {
        return false;
      }
      for (final Object? key in a.keys) {
        if (!b.containsKey(key) || !_sameJson(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) {
        return false;
      }
      for (int i = 0; i < a.length; i++) {
        if (!_sameJson(a[i], b[i])) {
          return false;
        }
      }
      return true;
    }
    if (a is num && b is num) {
      return (a.toDouble() - b.toDouble()).abs() < 1e-9;
    }
    return a == b;
  }
}
