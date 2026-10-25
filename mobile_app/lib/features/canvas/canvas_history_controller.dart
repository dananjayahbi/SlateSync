/// Round-9 issue 03 — undo/redo for the canvas page.
///
/// [EditHistory] owns the stacks; this controller is the thin Flutter-facing
/// layer the page talks to. It exists so the page's commit helpers do not each
/// have to remember the "record before, commit after" dance: they call
/// [begin] once at the start of a user gesture and [end] once it finishes, and
/// [canUndo] / [canRedo] drive the top-bar buttons through [ValueNotifier].
///
/// A gesture that turns out to be a no-op is dropped by [EditHistory.commit],
/// so a stray tap never adds an undo step the user cannot see.
library;

import 'package:flutter/foundation.dart';

import 'package:mobile_app/canvas_engine/edit_history.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

class CanvasHistoryController {
  CanvasHistoryController({this.limit = 60})
      : _history = EditHistory(limit: limit);

  final int limit;
  final EditHistory _history;

  /// Bumped whenever the stacks change, so the buttons can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  @visibleForTesting
  int get undoDepth => _history.undoDepth;
  @visibleForTesting
  int get redoDepth => _history.redoDepth;

  /// Snapshots [doc] as the "before" state of a gesture about to start.
  void begin(CanvasDocumentModel doc) => _history.record(snapshotOf(doc));

  /// Closes the gesture. Returns `true` when a step was actually pushed.
  bool end(CanvasDocumentModel doc) {
    final bool pushed = _history.commit(snapshotOf(doc));
    if (pushed) {
      revision.value++;
    }
    return pushed;
  }

  /// Abandons a gesture that was cancelled before it mutated anything.
  void cancel() => _history.discard();

  /// Restores the previous state into [doc].
  ///
  /// Returns `true` when [doc] changed, so the caller knows to reindex the
  /// engine and repaint. The restored nodes are FRESH objects (built from the
  /// snapshot) because the engine's R-tree holds references and a reused list
  /// would alias the stack.
  bool undo(CanvasDocumentModel doc) {
    final CanvasSnapshot? state = _history.undo(snapshotOf(doc));
    if (state == null) {
      return false;
    }
    _restore(doc, state);
    revision.value++;
    return true;
  }

  /// Reapplies the state an [undo] rewound.
  bool redo(CanvasDocumentModel doc) {
    final CanvasSnapshot? state = _history.redo(snapshotOf(doc));
    if (state == null) {
      return false;
    }
    _restore(doc, state);
    revision.value++;
    return true;
  }

  /// Forgets the stacks (a different canvas was opened).
  void clear() {
    _history.clear();
    revision.value++;
  }

  void dispose() => revision.dispose();

  static void _restore(CanvasDocumentModel doc, CanvasSnapshot state) {
    doc.elements
      ..clear()
      ..addAll(state.buildNodes());
    doc.groups = state.buildGroups();
  }
}
