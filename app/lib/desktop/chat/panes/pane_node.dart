import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Axis;

/// The edge of a target pane a dragged pane is dropped onto.
///
/// [left]/[right] re-dock side-by-side (a horizontal split); [top]/[bottom]
/// stack the panes (a vertical split).
enum DropEdge {
  /// Dock the source to the left of the target.
  left,

  /// Dock the source to the right of the target.
  right,

  /// Dock the source above the target.
  top,

  /// Dock the source below the target.
  bottom,
}

/// A node in the recursive split-pane tree: either a [PaneLeaf] (a single chat
/// pane) or a [PaneSplit] (two children divided along an [Axis]).
///
/// Trees are immutable; the top-level functions in this file
/// ([splitLeaf], [closeLeaf], [setRatio], [moveLeaf]) return new trees rather
/// than mutating in place.
@immutable
sealed class PaneNode {
  const PaneNode();

  /// Stable identity for this node.
  String get id;
}

/// A single chat pane. [sessionId] is the session it hosts, or null to fall
/// back to the globally selected session (preserving single-pane behaviour).
final class PaneLeaf extends PaneNode {
  /// Creates a leaf pane.
  const PaneLeaf({required this.id, this.sessionId});

  @override
  final String id;

  /// The session this pane hosts, or null to defer to the global selection.
  final String? sessionId;

  @override
  bool operator ==(Object other) =>
      other is PaneLeaf && other.id == id && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(id, sessionId);
}

/// Two child nodes divided along [axis]. [ratio] is the [first] child's
/// fraction of the available space, clamped to `0.1`–`0.9`.
final class PaneSplit extends PaneNode {
  /// Creates a split node.
  const PaneSplit({
    required this.id,
    required this.axis,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  });

  @override
  final String id;

  /// [Axis.horizontal] lays the children out side-by-side (a vertical
  /// divider); [Axis.vertical] stacks them (a horizontal divider).
  final Axis axis;

  /// The leading child (left or top).
  final PaneNode first;

  /// The trailing child (right or bottom).
  final PaneNode second;

  /// [first]'s fraction of the space, in `0.1`–`0.9`.
  final double ratio;

  /// Returns a copy with the given fields replaced.
  PaneSplit copyWith({PaneNode? first, PaneNode? second, double? ratio}) =>
      PaneSplit(
        id: id,
        axis: axis,
        first: first ?? this.first,
        second: second ?? this.second,
        ratio: ratio ?? this.ratio,
      );

  @override
  bool operator ==(Object other) =>
      other is PaneSplit &&
      other.id == id &&
      other.axis == axis &&
      other.first == first &&
      other.second == second &&
      other.ratio == ratio;

  @override
  int get hashCode => Object.hash(id, axis, first, second, ratio);
}

/// The lower and upper bounds a split [PaneSplit.ratio] is clamped to, so a
/// child is never dragged fully closed.
const double kMinPaneRatio = 0.1;

/// See [kMinPaneRatio].
const double kMaxPaneRatio = 0.9;

int _paneIdCounter = 0;

/// Returns a process-unique pane id. Purely incremental so the model stays
/// deterministic; the pure tree functions take explicit ids for tests.
String nextPaneId() => 'pane-${_paneIdCounter++}';

/// Replaces the leaf [targetLeafId] with a [PaneSplit] of the original leaf and
/// [newLeaf]. [newAfter] controls order: true → new leaf second (right/bottom).
/// Returns [root] unchanged when the target is not found.
PaneNode splitLeaf(
  PaneNode root,
  String targetLeafId,
  Axis axis,
  PaneLeaf newLeaf, {
  bool newAfter = true,
  String? splitId,
}) {
  switch (root) {
    case PaneLeaf():
      if (root.id != targetLeafId) return root;
      return PaneSplit(
        id: splitId ?? nextPaneId(),
        axis: axis,
        first: newAfter ? root : newLeaf,
        second: newAfter ? newLeaf : root,
      );
    case PaneSplit():
      return root.copyWith(
        first: splitLeaf(
          root.first,
          targetLeafId,
          axis,
          newLeaf,
          newAfter: newAfter,
          splitId: splitId,
        ),
        second: splitLeaf(
          root.second,
          targetLeafId,
          axis,
          newLeaf,
          newAfter: newAfter,
          splitId: splitId,
        ),
      );
  }
}

/// Removes leaf [targetLeafId] and collapses its parent split into the
/// surviving sibling. Returns the sole leaf unchanged when it is the only pane,
/// and [root] unchanged when the target is not found (never yields an empty
/// tree).
PaneNode closeLeaf(PaneNode root, String targetLeafId) {
  switch (root) {
    case PaneLeaf():
      return root;
    case PaneSplit():
      if (root.first is PaneLeaf &&
          (root.first as PaneLeaf).id == targetLeafId) {
        return root.second;
      }
      if (root.second is PaneLeaf &&
          (root.second as PaneLeaf).id == targetLeafId) {
        return root.first;
      }
      return root.copyWith(
        first: closeLeaf(root.first, targetLeafId),
        second: closeLeaf(root.second, targetLeafId),
      );
  }
}

/// Sets split [splitId]'s ratio, clamped to [kMinPaneRatio]–[kMaxPaneRatio].
/// Returns [root] unchanged (same identity) when [splitId] is not found, and
/// only rebuilds the ancestor chain of the matched split — the sibling subtree
/// keeps its identity.
PaneNode setRatio(PaneNode root, String splitId, double ratio) {
  switch (root) {
    case PaneLeaf():
      return root;
    case PaneSplit():
      if (root.id == splitId) {
        return root.copyWith(ratio: ratio.clamp(kMinPaneRatio, kMaxPaneRatio));
      }
      final newFirst = setRatio(root.first, splitId, ratio);
      if (!identical(newFirst, root.first)) {
        return root.copyWith(first: newFirst);
      }
      final newSecond = setRatio(root.second, splitId, ratio);
      if (!identical(newSecond, root.second)) {
        return root.copyWith(second: newSecond);
      }
      return root;
  }
}

/// Moves leaf [sourceLeafId] onto [edge] of leaf [targetLeafId]: the source is
/// removed and the target is split so the source docks on that edge. No-op when
/// source and target are the same leaf.
PaneNode moveLeaf(
  PaneNode root,
  String sourceLeafId,
  String targetLeafId,
  DropEdge edge, {
  String? splitId,
}) {
  if (sourceLeafId == targetLeafId) return root;
  final source = firstLeafWhere(root, (l) => l.id == sourceLeafId ? l : null);
  if (source == null || !containsLeaf(root, targetLeafId)) return root;

  final pruned = closeLeaf(root, sourceLeafId);
  final axis = switch (edge) {
    DropEdge.left || DropEdge.right => Axis.horizontal,
    DropEdge.top || DropEdge.bottom => Axis.vertical,
  };
  final newAfter = edge == DropEdge.right || edge == DropEdge.bottom;
  return splitLeaf(
    pruned,
    targetLeafId,
    axis,
    source,
    newAfter: newAfter,
    splitId: splitId,
  );
}

// ---------------------------------------------------------------------------
// Leaf combinators — the two primitives every leaf-based walk is built on.
// ---------------------------------------------------------------------------

/// Rebuilds [root], replacing every [PaneLeaf] with [transform] applied to it.
/// Splits are preserved unchanged (same id/axis/ratio); a pure structural map
/// used to pin/clear sessions across the tree.
PaneNode mapLeaves(PaneNode root, PaneLeaf Function(PaneLeaf) transform) =>
    switch (root) {
      PaneLeaf() => transform(root),
      PaneSplit() => root.copyWith(
        first: mapLeaves(root.first, transform),
        second: mapLeaves(root.second, transform),
      ),
    };

/// Returns [select] applied to the first leaf (left-most, depth-first) for
/// which it returns a non-null value, or null when no leaf matches.
T? firstLeafWhere<T>(PaneNode root, T? Function(PaneLeaf) select) =>
    switch (root) {
      PaneLeaf() => select(root),
      PaneSplit() =>
        firstLeafWhere(root.first, select) ??
            firstLeafWhere(root.second, select),
    };

/// The id of the left-most (first-descended) leaf.
String firstLeafId(PaneNode root) => firstLeafWhere(root, (l) => l.id)!;

/// Whether a leaf with [leafId] exists anywhere in [root].
bool containsLeaf(PaneNode root, String leafId) =>
    firstLeafWhere(root, (l) => l.id == leafId ? true : null) ?? false;
