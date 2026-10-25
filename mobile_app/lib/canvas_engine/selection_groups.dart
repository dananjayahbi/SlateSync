/// Round-9 issue 05 — temporary lock groups for the selector tool.
///
/// The user's rule: *"we can select one or more objects and click its lock
/// icon. So the selected objects will be in a temporary group and locked until
/// we select that group (the group will act as a single object until unlocked)
/// and click its unlock button again."*
///
/// A per-node `locked` flag cannot express this. `NodeStyle` is frozen at
/// `color` / `stroke_width` / `opacity` / `blend_mode` (Doc 03) and there is no
/// node flag to add, but the real problem is semantic: the requirement is a
/// *group* that behaves as one object, so the document needs a group relation,
/// not a flag. [CanvasDocumentModel.groups] is that relation
/// (`group_id → member ids`).
///
/// Everything here is pure list/map maths over ids so both the page and the
/// spec tests can exercise it without a widget tree:
///
/// * [expandSelection] turns "the user tapped this node" into "these nodes are
///   selected" by pulling in every locked group the hit belongs to.
/// * [lockSelection] / [unlockSelection] move ids in and out of `doc.groups`.
/// * [groupOutline] collects the member nodes of every group represented in a
///   selection, so the selector can draw the group as ONE object with a single
///   lock badge instead of a badge per member.
library;

import 'package:mobile_app/core/models/canvas_models.dart';

/// Ids of every node locked inside a group, in document order.
Set<String> lockedNodeIds(CanvasDocumentModel doc) => <String>{
      for (final List<String> members in doc.groups.values) ...members,
    };

/// True when [nodeId] belongs to a locked group.
bool isLocked(CanvasDocumentModel doc, String nodeId) =>
    doc.groupOf(nodeId) != null;

/// Expands [ids] so a locked group is always selected as a whole.
///
/// Selecting one member of a locked group must select the entire group —
/// otherwise a "single object" could be moved one piece at a time.
Set<String> expandSelection(CanvasDocumentModel doc, Iterable<String> ids) {
  final Set<String> out = <String>{};
  for (final String id in ids) {
    out.add(id);
    final String? groupId = doc.groupOf(id);
    if (groupId == null) {
      continue;
    }
    final List<String>? members = doc.groups[groupId];
    if (members != null) {
      out.addAll(members);
    }
  }
  return out;
}

/// Groups (id → members) represented by [selection], largest first.
///
/// The selector shows one lock badge per group, so it needs the group ids —
/// not the member ids — for the current selection.
Map<String, List<String>> groupsInSelection(
  CanvasDocumentModel doc,
  Iterable<String> selection,
) {
  final Set<String> chosen = selection.toSet();
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final MapEntry<String, List<String>> e in doc.groups.entries) {
    if (e.value.any(chosen.contains)) {
      out[e.key] = List<String>.of(e.value);
    }
  }
  return out;
}

/// `true` when every member of the selection is already inside one group.
bool selectionIsFullyLocked(
  CanvasDocumentModel doc,
  Iterable<String> selection,
) {
  final List<String> ids = selection.toList(growable: false);
  if (ids.isEmpty) {
    return false;
  }
  final String? first = doc.groupOf(ids.first);
  if (first == null) {
    return false;
  }
  for (final String id in ids) {
    if (doc.groupOf(id) != first) {
      return false;
    }
  }
  return true;
}

/// Locks [selection] into one NEW group and returns its id.
///
/// Nodes already locked in another group are folded into the new group (their
/// old group is dropped when it empties), so repeated lock/unlock can never
/// leave a node claimed by two groups — an invariant every renderer relies on
/// because it changes the meaning of "selected as one object".
///
/// Returns `null` when the selection is empty or already a single group.
String? lockSelection(CanvasDocumentModel doc, Iterable<String> selection) {
  final List<String> ids = <String>[];
  for (final String id in selection) {
    if (id.isNotEmpty && !ids.contains(id)) {
      ids.add(id);
    }
  }
  if (ids.isEmpty || selectionIsFullyLocked(doc, ids)) {
    return null;
  }
  // Detach the members from any group they used to belong to.
  for (final String id in ids) {
    final String? previous = doc.groupOf(id);
    if (previous == null) {
      continue;
    }
    final List<String>? members = doc.groups[previous];
    if (members == null) {
      continue;
    }
    members.remove(id);
    if (members.isEmpty) {
      doc.groups.remove(previous);
    }
  }
  final String groupId = 'grp-${_nextGroupSerial(doc)}';
  doc.groups[groupId] = ids;
  return groupId;
}

/// Removes [groupId] from the lock map. Returns the freed member ids.
List<String> unlockGroup(CanvasDocumentModel doc, String groupId) {
  final List<String>? members = doc.groups.remove(groupId);
  return members == null ? const <String>[] : List<String>.of(members);
}

/// Drops a node from whatever group holds it, removing now-empty groups.
///
/// Called from every delete path: a group that referenced a removed node would
/// otherwise expand a later selection to include a node that no longer exists.
void forgetNode(CanvasDocumentModel doc, String nodeId) {
  final List<String> empty = <String>[];
  for (final MapEntry<String, List<String>> e in doc.groups.entries) {
    e.value.remove(nodeId);
    if (e.value.isEmpty) {
      empty.add(e.key);
    }
  }
  for (final String id in empty) {
    doc.groups.remove(id);
  }
}

/// Members of every group in [selection] that are present in [elements].
///
/// Used by the rotation guard: a group counts as rotatable only when ALL of its
/// members are rotatable, exactly like `canScaleSelection` does for resizing.
List<CanvasNodeModel> groupMembers(
  CanvasDocumentModel doc,
  Iterable<String> selection,
) {
  final Map<String, List<String>> groups =
      groupsInSelection(doc, selection);
  final Set<String> wanted = <String>{
    for (final List<String> members in groups.values) ...members,
  };
  if (wanted.isEmpty) {
    return <CanvasNodeModel>[];
  }
  return <CanvasNodeModel>[
    for (final CanvasNodeModel n in doc.elements)
      if (wanted.contains(n.nodeId)) n,
  ];
}

int _nextGroupSerial(CanvasDocumentModel doc) {
  int serial = 1;
  while (doc.groups.containsKey('grp-$serial')) {
    serial++;
  }
  return serial;
}
