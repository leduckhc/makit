import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Axis;

import '../selected_worktree.dart';
import 'pane_zoom.dart';

/// The edge of a target [Split] a dragged [Split] is dropped onto.
///
/// [left]/[right] re-dock side-by-side (a horizontal splitter); [top]/[bottom]
/// stack the splits (a vertical splitter).
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

/// The lower and upper bounds a [Splitter.ratio] is clamped to, so a child is
/// never dragged fully closed.
const double kMinPaneRatio = 0.1;

/// See [kMinPaneRatio].
const double kMaxPaneRatio = 0.9;

/// A node in the recursive workspace tree: either a [Split] (a leaf region that
/// hosts a strip of [Tab]s) or a [Splitter] (two children divided along an
/// [Axis]).
///
/// Trees are immutable; the top-level functions in this file
/// ([divideSplit], [removeSplit], [setRatio], [moveSplit]) return new trees
/// rather than mutating in place, preserving the identity of untouched nodes.
@immutable
sealed class SplitNode {
  const SplitNode();

  /// Stable identity for this node.
  String get id;

  /// A JSON map for persistence. Tagged by kind (`k`) so [fromJson] can
  /// dispatch to the right subtype: `'split'` → [Split], `'splitter'` →
  /// [Splitter].
  Map<String, Object?> toJson();

  /// Rebuilds a node (recursively, for splitters) from a [toJson] map. Throws a
  /// [FormatException] on an unknown or missing kind tag.
  static SplitNode fromJson(Map<String, Object?> j) => switch (j['k']) {
    'split' => Split.fromJson(j),
    'splitter' => Splitter.fromJson(j),
    final o => throw FormatException('unknown split node kind: $o'),
  };
}

/// One session view inside a [Split]. [sessionId] is the session it hosts, or
/// null for the empty placeholder tab.
final class Tab {
  /// Creates a tab.
  const Tab({required this.id, this.sessionId, this.worktree});

  /// Rebuilds a tab from its [toJson] map. A persisted [worktree] hint is only
  /// meaningful — and only ever present — on an empty (sessionless) tab.
  factory Tab.fromJson(Map<String, Object?> json) {
    final sessionId = json['sessionId'] as String?;
    final rawWorktree = json['worktree'];
    return Tab(
      id: json['id'] as String,
      sessionId: sessionId,
      worktree: (sessionId == null && rawWorktree is Map<String, Object?>)
          ? SelectedWorktree.fromJson(rawWorktree)
          : null,
    );
  }

  /// Stable identity for this tab.
  final String id;

  /// The session this tab hosts, or null for the empty placeholder tab.
  final String? sessionId;

  /// Only meaningful when [sessionId] is null: an optional worktree used to
  /// pre-fill the New session dialog's Worktree field. Never an inline picker.
  final SelectedWorktree? worktree;

  /// JSON for persistence. The [worktree] hint is serialized only for an empty
  /// (sessionless) tab, since it is meaningless once a session is bound.
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionId': sessionId,
    if (sessionId == null && worktree != null) 'worktree': worktree!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Tab &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.worktree == worktree;

  @override
  int get hashCode => Object.hash(id, sessionId, worktree);
}

/// A leaf region: a strip of tabs plus which one is active. A live [Split]
/// always has at least one tab; [removeTab] returns null rather than yielding an
/// empty strip.
final class Split extends SplitNode {
  /// Creates a split. [activeTabId] must reference a tab in [tabs].
  const Split({
    required this.id,
    required this.tabs,
    required this.activeTabId,
    this.zoom = PaneZoom.none,
  });

  /// Rebuilds a split (and its tabs) from its [toJson] map.
  ///
  /// A layout persisted before SPEC-pane-zoom carries no `zoom` key, and loads
  /// at [PaneZoom.none]. A corrupt or hand-edited value is clamped, because a
  /// stored scale is untrusted input like any other.
  factory Split.fromJson(Map<String, Object?> json) => Split(
    id: json['id'] as String,
    activeTabId: json['activeTabId'] as String,
    zoom: switch (json['zoom']) {
      final num z => PaneZoom.clamp(z.toDouble()),
      _ => PaneZoom.none,
    },
    tabs: [
      for (final t in json['tabs'] as List)
        Tab.fromJson(t as Map<String, Object?>),
    ],
  );

  @override
  final String id;

  /// The tab strip. Never empty for a live split.
  final List<Tab> tabs;

  /// The id of the active tab; always references a tab in [tabs].
  final String activeTabId;

  /// This pane's text zoom (SPEC-pane-zoom D2). [PaneZoom.none] when untouched.
  ///
  /// Zoom belongs to the pane, not to the tab, so every tab in the strip reads
  /// at the same scale. It rides the split tree, so it survives a restart and
  /// dies with the pane.
  final double zoom;

  /// This split at [zoom], clamped to the ladder's ends.
  Split withZoom(double zoom) => Split(
    id: id,
    tabs: tabs,
    activeTabId: activeTabId,
    zoom: PaneZoom.clamp(zoom),
  );

  @override
  Map<String, Object?> toJson() => {
    'k': 'split',
    'id': id,
    'activeTabId': activeTabId,
    // Omitted at 100%, like Tab's worktree hint, to keep a persisted layout
    // small and unchanged for the majority of panes.
    if (zoom != PaneZoom.none) 'zoom': zoom,
    'tabs': [for (final t in tabs) t.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is Split &&
      other.id == id &&
      other.activeTabId == activeTabId &&
      other.zoom == zoom &&
      listEquals(other.tabs, tabs);

  @override
  int get hashCode => Object.hash(id, activeTabId, zoom, Object.hashAll(tabs));
}

/// An internal divider node. [ratio] is the [first] child's fraction of the
/// available space, clamped to [kMinPaneRatio]–[kMaxPaneRatio] by [setRatio].
final class Splitter extends SplitNode {
  /// Creates a splitter node.
  const Splitter({
    required this.id,
    required this.axis,
    required this.first,
    required this.second,
    this.ratio = 0.5,
  });

  /// Rebuilds a splitter (and its children) from its [toJson] map.
  factory Splitter.fromJson(Map<String, Object?> json) => Splitter(
    id: json['id'] as String,
    axis: json['axis'] == 'h' ? Axis.horizontal : Axis.vertical,
    ratio: (json['ratio'] as num).toDouble(),
    first: SplitNode.fromJson(json['first'] as Map<String, Object?>),
    second: SplitNode.fromJson(json['second'] as Map<String, Object?>),
  );

  @override
  final String id;

  /// [Axis.horizontal] lays the children out side-by-side (a vertical
  /// divider); [Axis.vertical] stacks them (a horizontal divider).
  final Axis axis;

  /// The leading child (left or top).
  final SplitNode first;

  /// The trailing child (right or bottom).
  final SplitNode second;

  /// [first]'s fraction of the space, in [kMinPaneRatio]–[kMaxPaneRatio].
  final double ratio;

  /// Returns a copy with the given fields replaced.
  Splitter copyWith({SplitNode? first, SplitNode? second, double? ratio}) =>
      Splitter(
        id: id,
        axis: axis,
        first: first ?? this.first,
        second: second ?? this.second,
        ratio: ratio ?? this.ratio,
      );

  @override
  Map<String, Object?> toJson() => {
    'k': 'splitter',
    'id': id,
    'axis': axis == Axis.horizontal ? 'h' : 'v',
    'ratio': ratio,
    'first': first.toJson(),
    'second': second.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Splitter &&
      other.id == id &&
      other.axis == axis &&
      other.first == first &&
      other.second == second &&
      other.ratio == ratio;

  @override
  int get hashCode => Object.hash(id, axis, first, second, ratio);
}

/// The kind of id [nextNodeId] mints: a leaf [Split], a divider [Splitter], or
/// a [Tab].
enum SplitNodeKind {
  /// A [Split] leaf id (`split-N`).
  split,

  /// A [Splitter] divider id (`splitter-N`).
  splitter,

  /// A [Tab] id (`tab-N`).
  tab,
}

int _splitCounter = 0;
int _splitterCounter = 0;
int _tabCounter = 0;

/// Returns a process-unique id for [kind]: `split-N` / `splitter-N` / `tab-N`.
/// Purely incremental (one counter per kind) so the model stays deterministic;
/// the pure tree functions take explicit ids for tests. Reset with
/// [resetNodeIds].
String nextNodeId(SplitNodeKind kind) => switch (kind) {
  SplitNodeKind.split => 'split-${_splitCounter++}',
  SplitNodeKind.splitter => 'splitter-${_splitterCounter++}',
  SplitNodeKind.tab => 'tab-${_tabCounter++}',
};

/// Resets every [nextNodeId] counter to zero. For tests only, so id-dependent
/// assertions are deterministic.
@visibleForTesting
void resetNodeIds() {
  _splitCounter = 0;
  _splitterCounter = 0;
  _tabCounter = 0;
}

/// Advances the [nextNodeId] counters past the highest `kind-N` id already
/// present in [root], so ids minted after a persisted tree is restored can
/// never collide with existing nodes (the counters otherwise restart at 0 each
/// launch while the restored tree already holds `split-0`/`tab-0`/…). Ids that
/// don't match the `kind-N` shape are ignored.
void seedNodeIdsFrom(SplitNode root) {
  int bumpedPast(int current, String id, String prefix) {
    if (!id.startsWith(prefix)) return current;
    final n = int.tryParse(id.substring(prefix.length));
    return (n != null && n + 1 > current) ? n + 1 : current;
  }

  void walk(SplitNode node) {
    switch (node) {
      case Split():
        _splitCounter = bumpedPast(_splitCounter, node.id, 'split-');
        for (final t in node.tabs) {
          _tabCounter = bumpedPast(_tabCounter, t.id, 'tab-');
        }
      case Splitter():
        _splitterCounter = bumpedPast(_splitterCounter, node.id, 'splitter-');
        walk(node.first);
        walk(node.second);
    }
  }

  walk(root);
}

// ---------------------------------------------------------------------------
// Pure tree functions — immutable, identity-preserving on untouched nodes.
// ---------------------------------------------------------------------------

/// Replaces the split [targetSplitId] with a [Splitter] of the original split
/// and [newSplit]. [newAfter] controls order: true → new split second
/// (right/bottom). Returns [root] unchanged when the target is not found.
SplitNode divideSplit(
  SplitNode root,
  String targetSplitId,
  Axis axis,
  Split newSplit, {
  bool newAfter = true,
  String? splitterId,
}) {
  switch (root) {
    case Split():
      if (root.id != targetSplitId) return root;
      return Splitter(
        id: splitterId ?? nextNodeId(SplitNodeKind.splitter),
        axis: axis,
        first: newAfter ? root : newSplit,
        second: newAfter ? newSplit : root,
      );
    case Splitter():
      final newFirst = divideSplit(
        root.first,
        targetSplitId,
        axis,
        newSplit,
        newAfter: newAfter,
        splitterId: splitterId,
      );
      if (!identical(newFirst, root.first)) {
        return root.copyWith(first: newFirst);
      }
      final newSecond = divideSplit(
        root.second,
        targetSplitId,
        axis,
        newSplit,
        newAfter: newAfter,
        splitterId: splitterId,
      );
      if (!identical(newSecond, root.second)) {
        return root.copyWith(second: newSecond);
      }
      return root;
  }
}

/// Removes split [targetSplitId] and collapses its parent [Splitter] into the
/// surviving sibling. Returns [root] unchanged (same identity) when the target
/// is the sole root split (the caller resets it to a starter tab) or is not
/// found — never yields an empty tree.
SplitNode removeSplit(SplitNode root, String targetSplitId) {
  switch (root) {
    case Split():
      return root;
    case Splitter():
      final first = root.first;
      final second = root.second;
      if (first is Split && first.id == targetSplitId) return second;
      if (second is Split && second.id == targetSplitId) return first;
      final newFirst = removeSplit(first, targetSplitId);
      if (!identical(newFirst, first)) return root.copyWith(first: newFirst);
      final newSecond = removeSplit(second, targetSplitId);
      if (!identical(newSecond, second)) {
        return root.copyWith(second: newSecond);
      }
      return root;
  }
}

/// Sets splitter [splitterId]'s ratio, clamped to [kMinPaneRatio]–
/// [kMaxPaneRatio]. Returns [root] unchanged (same identity) when [splitterId]
/// is not found, and only rebuilds the ancestor chain of the matched splitter —
/// the sibling subtree keeps its identity.
SplitNode setRatio(SplitNode root, String splitterId, double ratio) {
  switch (root) {
    case Split():
      return root;
    case Splitter():
      if (root.id == splitterId) {
        return root.copyWith(ratio: ratio.clamp(kMinPaneRatio, kMaxPaneRatio));
      }
      final newFirst = setRatio(root.first, splitterId, ratio);
      if (!identical(newFirst, root.first)) {
        return root.copyWith(first: newFirst);
      }
      final newSecond = setRatio(root.second, splitterId, ratio);
      if (!identical(newSecond, root.second)) {
        return root.copyWith(second: newSecond);
      }
      return root;
  }
}

/// Moves split [sourceSplitId] onto [edge] of split [targetSplitId]: the source
/// is removed and the target is divided so the source docks on that edge. No-op
/// (same identity) when source and target are the same split, or when either is
/// not found.
SplitNode moveSplit(
  SplitNode root,
  String sourceSplitId,
  String targetSplitId,
  DropEdge edge, {
  String? splitterId,
}) {
  if (sourceSplitId == targetSplitId) return root;
  final source = firstSplitWhere(root, (s) => s.id == sourceSplitId ? s : null);
  if (source == null || !containsSplit(root, targetSplitId)) return root;

  final pruned = removeSplit(root, sourceSplitId);
  final axis = switch (edge) {
    DropEdge.left || DropEdge.right => Axis.horizontal,
    DropEdge.top || DropEdge.bottom => Axis.vertical,
  };
  final newAfter = edge == DropEdge.right || edge == DropEdge.bottom;
  return divideSplit(
    pruned,
    targetSplitId,
    axis,
    source,
    newAfter: newAfter,
    splitterId: splitterId,
  );
}

// ---------------------------------------------------------------------------
// Split combinators — the primitives every split-based walk is built on.
// ---------------------------------------------------------------------------

/// Rebuilds [root], replacing every [Split] with [transform] applied to it.
/// Splitters keep their identity when neither child changed (so untouched
/// subtrees are not needlessly copied, matching the other tree functions).
SplitNode mapSplits(SplitNode root, Split Function(Split) transform) {
  switch (root) {
    case Split():
      return transform(root);
    case Splitter():
      final first = mapSplits(root.first, transform);
      final second = mapSplits(root.second, transform);
      if (identical(first, root.first) && identical(second, root.second)) {
        return root;
      }
      return root.copyWith(first: first, second: second);
  }
}

/// Returns [select] applied to the first split (left-most, depth-first) for
/// which it returns a non-null value, or null when no split matches.
T? firstSplitWhere<T>(SplitNode root, T? Function(Split) select) =>
    switch (root) {
      Split() => select(root),
      Splitter() =>
        firstSplitWhere(root.first, select) ??
            firstSplitWhere(root.second, select),
    };

/// The id of the left-most (first-descended) split.
String firstSplitId(SplitNode root) => firstSplitWhere(root, (s) => s.id)!;

/// Whether a split with [splitId] exists anywhere in [root].
bool containsSplit(SplitNode root, String splitId) =>
    firstSplitWhere(root, (s) => s.id == splitId ? true : null) ?? false;

/// Locates the session [sessionId] anywhere in [root], returning
/// `(splitId, tabId)` of the tab hosting it, or null when no tab does.
(String splitId, String tabId)? findTab(SplitNode root, String sessionId) =>
    firstSplitWhere(root, (s) {
      for (final t in s.tabs) {
        if (t.sessionId == sessionId) return (s.id, t.id);
      }
      return null;
    });

// ---------------------------------------------------------------------------
// Tab helpers — pure operations on a single Split.
// ---------------------------------------------------------------------------

/// Appends [tab] to [split] and makes it the active tab.
Split addTab(Split split, Tab tab) =>
    Split(id: split.id, tabs: [...split.tabs, tab], activeTabId: tab.id);

/// Removes tab [tabId] from [split]. Returns null when it was the last tab (the
/// caller collapses or resets the split), or [split] unchanged (same identity)
/// when [tabId] is not present. When the removed tab was active, a neighbour
/// becomes active.
Split? removeTab(Split split, String tabId) {
  final index = split.tabs.indexWhere((t) => t.id == tabId);
  if (index < 0) return split;
  if (split.tabs.length == 1) return null;
  final tabs = [...split.tabs]..removeAt(index);
  final activeTabId = split.activeTabId == tabId
      ? tabs[index < tabs.length ? index : tabs.length - 1].id
      : split.activeTabId;
  return Split(id: split.id, tabs: tabs, activeTabId: activeTabId);
}

/// Makes tab [tabId] active in [split]. Returns [split] unchanged (same
/// identity) when [tabId] is not present or already active.
Split activateTab(Split split, String tabId) {
  if (split.activeTabId == tabId || !split.tabs.any((t) => t.id == tabId)) {
    return split;
  }
  return Split(id: split.id, tabs: split.tabs, activeTabId: tabId);
}

/// Moves tab [tabId] to [newIndex] within [split], preserving the active tab.
/// Returns [split] unchanged (same identity) when [tabId] is not present.
Split reorderTab(Split split, String tabId, int newIndex) {
  final index = split.tabs.indexWhere((t) => t.id == tabId);
  if (index < 0) return split;
  final tabs = [...split.tabs];
  final tab = tabs.removeAt(index);
  tabs.insert(newIndex.clamp(0, tabs.length), tab);
  return Split(id: split.id, tabs: tabs, activeTabId: split.activeTabId);
}
