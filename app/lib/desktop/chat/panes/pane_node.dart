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
PaneNode setRatio(PaneNode root, String splitId, double ratio) {
  switch (root) {
    case PaneLeaf():
      return root;
    case PaneSplit():
      final clamped = ratio.clamp(kMinPaneRatio, kMaxPaneRatio);
      if (root.id == splitId) return root.copyWith(ratio: clamped);
      return root.copyWith(
        first: setRatio(root.first, splitId, ratio),
        second: setRatio(root.second, splitId, ratio),
      );
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
  final source = _findLeaf(root, sourceLeafId);
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

/// The id of the left-most (first-descended) leaf.
String firstLeafId(PaneNode root) => switch (root) {
  PaneLeaf() => root.id,
  PaneSplit() => firstLeafId(root.first),
};

/// Whether a leaf with [leafId] exists anywhere in [root].
bool containsLeaf(PaneNode root, String leafId) =>
    _findLeaf(root, leafId) != null;

PaneLeaf? _findLeaf(PaneNode root, String leafId) {
  switch (root) {
    case PaneLeaf():
      return root.id == leafId ? root : null;
    case PaneSplit():
      return _findLeaf(root.first, leafId) ?? _findLeaf(root.second, leafId);
  }
}
