import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/legacy.dart';

import 'pane_node.dart';
// Aliased so the controller's own `setRatio`/`moveLeaf` methods can still
// reach the pure tree functions of the same name.
import 'pane_node.dart' as tree;

/// The split-pane tree plus which leaf is currently active. Immutable; the
/// [PaneTreeController] swaps in new instances.
@immutable
class PaneTreeState {
  /// Creates a tree state.
  const PaneTreeState({required this.root, required this.activeLeafId});

  /// The root of the pane tree.
  final PaneNode root;

  /// The id of the leaf splits and closes act on.
  final String activeLeafId;

  @override
  bool operator ==(Object other) =>
      other is PaneTreeState &&
      other.root == root &&
      other.activeLeafId == activeLeafId;

  @override
  int get hashCode => Object.hash(root, activeLeafId);
}

/// Holds and mutates the desktop split-pane tree. Splits and closes target the
/// [PaneTreeState.activeLeafId]; a new pane inherits the active pane's session
/// so it is immediately usable.
class PaneTreeController extends StateNotifier<PaneTreeState> {
  /// Seeds a single leaf (session null → falls back to the global selection,
  /// so first launch matches the pre-split single-pane behaviour).
  PaneTreeController() : super(_seed());

  static PaneTreeState _seed() {
    final id = nextPaneId();
    return PaneTreeState(
      root: PaneLeaf(id: id),
      activeLeafId: id,
    );
  }

  PaneLeaf? _activeLeaf(PaneNode node) {
    switch (node) {
      case PaneLeaf():
        return node.id == state.activeLeafId ? node : null;
      case PaneSplit():
        return _activeLeaf(node.first) ?? _activeLeaf(node.second);
    }
  }

  /// The session id explicitly stored on the active leaf (null when it is a
  /// fresh pane still tracking the global selection). Callers resolve the
  /// fallback themselves since the controller cannot read providers.
  String? get activeLeafSessionId => _activeLeaf(state.root)?.sessionId;

  PaneNode _pinLeaf(PaneNode node, String id, String? sessionId) {
    switch (node) {
      case PaneLeaf():
        return node.id == id
            ? PaneLeaf(id: node.id, sessionId: sessionId)
            : node;
      case PaneSplit():
        return PaneSplit(
          id: node.id,
          axis: node.axis,
          first: _pinLeaf(node.first, id, sessionId),
          second: _pinLeaf(node.second, id, sessionId),
          ratio: node.ratio,
        );
    }
  }

  /// Splits the active pane along [axis]. The current pane is pinned to
  /// [pinnedSessionId] (its resolved session) so it keeps showing that session,
  /// and a fresh empty pane is added and activated — splitting opens a new
  /// session rather than duplicating the existing one.
  void splitActive(Axis axis, {String? pinnedSessionId}) {
    final activeId = state.activeLeafId;
    final pinned = pinnedSessionId ?? _activeLeaf(state.root)?.sessionId;
    final pinnedRoot = _pinLeaf(state.root, activeId, pinned);
    // A null session on the new leaf means "track the global selection", which
    // the following new-session flow (or a sidebar pick) fills in.
    final newLeaf = PaneLeaf(id: nextPaneId());
    state = PaneTreeState(
      root: splitLeaf(pinnedRoot, activeId, axis, newLeaf),
      activeLeafId: newLeaf.id,
    );
  }

  /// Closes the active pane, collapsing its parent split into the sibling. The
  /// sibling subtree's left-most leaf becomes active (falling back to the whole
  /// tree's first leaf), so focus stays near the closed pane. No-op when only
  /// one pane remains.
  void closeActive() {
    final target = state.activeLeafId;
    final sibling = _siblingFirstLeafId(state.root, target);
    final next = closeLeaf(state.root, target);
    if (identical(next, state.root) || next == state.root) return;
    final focus = (sibling != null && containsLeaf(next, sibling))
        ? sibling
        : firstLeafId(next);
    state = PaneTreeState(root: next, activeLeafId: focus);
  }

  /// The left-most leaf id of [targetId]'s sibling subtree, or null when
  /// [targetId] has no parent split (it is the root leaf).
  String? _siblingFirstLeafId(PaneNode node, String targetId) {
    switch (node) {
      case PaneLeaf():
        return null;
      case PaneSplit():
        final first = node.first;
        final second = node.second;
        if (first is PaneLeaf && first.id == targetId) {
          return firstLeafId(second);
        }
        if (second is PaneLeaf && second.id == targetId) {
          return firstLeafId(first);
        }
        return _siblingFirstLeafId(first, targetId) ??
            _siblingFirstLeafId(second, targetId);
    }
  }

  /// Marks the leaf [leafId] active (visible focus ring).
  void setActive(String leafId) {
    if (leafId == state.activeLeafId || !containsLeaf(state.root, leafId)) {
      return;
    }
    state = PaneTreeState(root: state.root, activeLeafId: leafId);
  }

  /// Binds [sessionId] to the active pane so a sidebar pick lands in the
  /// focused pane rather than a single global slot.
  void bindActiveSession(String sessionId) {
    state = PaneTreeState(
      root: _pinLeaf(state.root, state.activeLeafId, sessionId),
      activeLeafId: state.activeLeafId,
    );
  }

  /// Clears the active pane's bound session (e.g. when a sessionless worktree
  /// is selected), so it falls back to the global selection / worktree draft.
  void clearActiveSession() {
    state = PaneTreeState(
      root: _pinLeaf(state.root, state.activeLeafId, null),
      activeLeafId: state.activeLeafId,
    );
  }

  /// Updates the ratio of split [splitId] (clamped in [setRatio]).
  void setRatio(String splitId, double ratio) {
    state = PaneTreeState(
      root: tree.setRatio(state.root, splitId, ratio),
      activeLeafId: state.activeLeafId,
    );
  }

  /// Adds [delta] to split [splitId]'s current ratio, reading the live state so
  /// rapid divider drags accumulate correctly.
  void adjustRatio(String splitId, double delta) {
    final current = _ratioOf(state.root, splitId);
    if (current == null) return;
    setRatio(splitId, current + delta);
  }

  double? _ratioOf(PaneNode node, String splitId) {
    switch (node) {
      case PaneLeaf():
        return null;
      case PaneSplit():
        if (node.id == splitId) return node.ratio;
        return _ratioOf(node.first, splitId) ?? _ratioOf(node.second, splitId);
    }
  }

  /// Unbinds [sessionId] from every pane pinned to it (e.g. after the session
  /// is quit), so those panes drop back to their empty/fallback state instead
  /// of pointing at a dead session id.
  void unbindSession(String sessionId) {
    state = PaneTreeState(
      root: _clearSession(state.root, sessionId),
      activeLeafId: state.activeLeafId,
    );
  }

  PaneNode _clearSession(PaneNode node, String sessionId) {
    switch (node) {
      case PaneLeaf():
        return node.sessionId == sessionId ? PaneLeaf(id: node.id) : node;
      case PaneSplit():
        return PaneSplit(
          id: node.id,
          axis: node.axis,
          first: _clearSession(node.first, sessionId),
          second: _clearSession(node.second, sessionId),
          ratio: node.ratio,
        );
    }
  }

  /// Re-docks the [source] leaf onto [edge] of the [target] leaf; the moved
  /// pane stays active.
  void moveLeaf(String source, String target, DropEdge edge) {
    final next = tree.moveLeaf(state.root, source, target, edge);
    if (next == state.root) return;
    state = PaneTreeState(
      root: next,
      activeLeafId: containsLeaf(next, source) ? source : firstLeafId(next),
    );
  }
}

/// The active split-pane tree for the desktop chat surface.
final paneTreeControllerProvider =
    StateNotifierProvider<PaneTreeController, PaneTreeState>(
      (ref) => PaneTreeController(),
    );
