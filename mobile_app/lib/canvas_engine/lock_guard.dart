/// Round-10 issue 05 — a locked group must refuse EVERY tool.
///
/// Round 9 introduced lock groups and taught the selector to select a group as
/// one object, but only the *look* was enforced: `_applyTransform`,
/// `_rotateSelection`, `_eraseAt`, `_fillAt`, `_growTable` and the delete path
/// never asked whether the ids they were about to touch belonged to a group, so
/// a "locked" object could still be dragged, resized, rotated, erased, filled or
/// deleted. The user's rule is absolute: *"We should not be able to do anything
/// or use any tool against it until the selector tool unlocks it."*
///
/// The enforcement lives here — one predicate plus two filters, kept out of the
/// page so every entry point uses the same rule and the behaviour is testable
/// without a widget tree:
///
/// * [lockedGroupIds] — the ids that are currently protected.
/// * [isNodeLocked] — single-id predicate.
/// * [unlockedIds] — filter for a selection-driven gesture.
/// * [gestureRefusal] — the message to surface when a gesture was fully blocked.
///
/// Locking is intentionally *not* enforced against unlocking itself, nor against
/// deleting the group's own members from the document when the group is removed
/// first (see the page's `_deleteSelection`, which unlocks before deleting).
library;

import 'package:mobile_app/canvas_engine/selection_groups.dart';
import 'package:mobile_app/core/models/canvas_models.dart';

/// Ids protected by a lock group right now.
Set<String> lockedGroupIds(CanvasDocumentModel doc) => lockedNodeIds(doc);

/// True when [nodeId] is inside a locked group.
bool isNodeLocked(CanvasDocumentModel doc, String nodeId) =>
    isLocked(doc, nodeId);

/// True when ANY id in [ids] is locked.
///
/// A gesture is all-or-nothing: a selection that mixes a locked and an unlocked
/// object must not partially apply, or the group would be silently torn apart
/// while the object that *is* visible stays locked.
bool anyLocked(CanvasDocumentModel doc, Iterable<String> ids) {
  final Set<String> locked = lockedGroupIds(doc);
  if (locked.isEmpty) {
    return false;
  }
  for (final String id in ids) {
    if (locked.contains(id)) {
      return true;
    }
  }
  return false;
}

/// [ids] minus everything locked — the safe subset a gesture may mutate.
List<String> unlockedIds(CanvasDocumentModel doc, Iterable<String> ids) {
  final Set<String> locked = lockedGroupIds(doc);
  if (locked.isEmpty) {
    return List<String>.of(ids);
  }
  return <String>[
    for (final String id in ids)
      if (!locked.contains(id)) id,
  ];
}

/// Nodes a gesture may touch: [candidates] filtered to unlocked members.
List<CanvasNodeModel> unlockedNodes(
  CanvasDocumentModel doc,
  Iterable<CanvasNodeModel> candidates,
) {
  final Set<String> locked = lockedGroupIds(doc);
  if (locked.isEmpty) {
    return List<CanvasNodeModel>.of(candidates);
  }
  return <CanvasNodeModel>[
    for (final CanvasNodeModel n in candidates)
      if (!locked.contains(n.nodeId)) n,
  ];
}

/// User-facing message for a gesture that a lock blocked, or `null` when some
/// part of it was allowed (partial work still needs a hint to be honest about
/// what was skipped).
String? gestureRefusal({
  required CanvasDocumentModel doc,
  required Iterable<String> requested,
  required Iterable<String> applied,
}) {
  final int wanted = requested.length;
  final int done = applied.length;
  if (wanted == 0 || done == wanted) {
    return null;
  }
  if (done == 0) {
    return 'Locked — unlock the group with the selector tool first.';
  }
  return 'Skipped ${wanted - done} locked object(s).';
}
