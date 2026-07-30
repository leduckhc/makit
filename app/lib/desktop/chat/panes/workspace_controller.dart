import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'split_node.dart';
// Aliased so the controller's own `setRatio`/`moveSplit` methods can still
// reach the pure tree functions of the same name.
import 'split_node.dart' as tree;
import '../groups/groups_controller.dart';
import '../selected_worktree.dart';

/// SharedPreferences key holding the whole workspace (the split/tab tree plus
/// the active split) as a single JSON object.
const String kWorkspacePrefsKey = 'desktop_workspace';

/// Sentinel "append" index for tab inserts: `_insertTab`/`reorderTab` clamp to
/// the tab count, so any out-of-range value lands the tab last.
const int _kAppendIndex = 1 << 30;

/// The single, worktree-agnostic workspace: the recursive split/tab [root] plus
/// which [Split] is active. Immutable; the [WorkspaceController] swaps in new
/// instances.
@immutable
class WorkspaceState {
  /// Creates a workspace state. [activeSplitId] must reference a [Split] in
  /// [root].
  const WorkspaceState({required this.root, required this.activeSplitId});

  /// Rebuilds a workspace from its [toJson] map.
  factory WorkspaceState.fromJson(Map<String, Object?> json) => WorkspaceState(
    root: SplitNode.fromJson(json['root'] as Map<String, Object?>),
    activeSplitId: json['activeSplitId'] as String,
  );

  /// The root of the split/tab tree.
  final SplitNode root;

  /// The id of the [Split] that split/tab-open actions act on. Always
  /// references a live [Split].
  final String activeSplitId;

  /// JSON for persistence.
  Map<String, Object?> toJson() => {
    'root': root.toJson(),
    'activeSplitId': activeSplitId,
  };

  @override
  bool operator ==(Object other) =>
      other is WorkspaceState &&
      other.root == root &&
      other.activeSplitId == activeSplitId;

  @override
  int get hashCode => Object.hash(root, activeSplitId);
}

/// Notified with the whole workspace after every mutation, so an owner can
/// persist it. **Must not throw and must not be awaited** — a failed write may
/// never crash the app or surface as an unhandled async error (SPEC-30 Lane 2).
typedef WorkspaceCommit = void Function(WorkspaceState next);

/// Holds and mutates **one** split/tab tree.
///
/// Since SPEC-30 there are many trees — one per group — so this controller no
/// longer owns persistence: it reports every mutation through a
/// [WorkspaceCommit] sink and the groups layer decides what is written. All
/// tree operations below are unchanged; only the plumbing moved.
class WorkspaceController extends StateNotifier<WorkspaceState> {
  /// Creates a controller seeded from [initial], reporting mutations to
  /// [_onCommit]. A null sink makes the controller ephemeral.
  WorkspaceController(this._onCommit, WorkspaceState initial) : super(initial);

  /// A non-persisting controller seeded with the starter workspace.
  WorkspaceController.ephemeral() : this(null, seedWorkspace());

  final WorkspaceCommit? _onCommit;

  /// The starter workspace, exposed so the groups layer can seed a new group's
  /// tree with the same shape a fresh workspace has.
  static WorkspaceState seedWorkspace() => _seed();

  /// Decodes a persisted workspace blob, falling back to the starter workspace
  /// for absent/corrupt/unusable JSON. Exposed for the SPEC-30 migration, which
  /// must read the legacy single-workspace key.
  static WorkspaceState decodeWorkspace(String? raw) => _decode(raw);

  /// The starter workspace: a single [Split] holding one empty (sessionless)
  /// starter [Tab], active (decision 7).
  static WorkspaceState _seed() {
    final tab = Tab(id: nextNodeId(SplitNodeKind.tab));
    final split = Split(
      id: nextNodeId(SplitNodeKind.split),
      tabs: [tab],
      activeTabId: tab.id,
    );
    return WorkspaceState(root: split, activeSplitId: split.id);
  }

  static WorkspaceState _decode(String? raw) {
    if (raw == null || raw.isEmpty) return _seed();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return _seed();
    }
    if (decoded is! Map) return _seed();
    try {
      final state = WorkspaceState.fromJson({
        for (final e in decoded.entries) '${e.key}': e.value,
      });
      // Advance the id counters past the restored tree so ids minted this
      // session can't collide with persisted `split-0`/`tab-0`/… nodes.
      seedNodeIdsFrom(state.root);
      // Guard the invariant: a blob from an older/other build can point
      // activeSplitId at a split that no longer exists, which would freeze
      // every mutation. Recover by focusing the first split.
      if (!containsSplit(state.root, state.activeSplitId)) {
        return WorkspaceState(
          root: state.root,
          activeSplitId: firstSplitId(state.root),
        );
      }
      return state;
    } on Object {
      // Any structural mismatch (missing keys, wrong types, unknown node kind)
      // → starter workspace rather than a crash, so a bad blob never bricks the
      // workspace.
      return _seed();
    }
  }

  // -- Splits ---------------------------------------------------------------

  /// Splits the active [Split] along [axis]. The new [Split] is seeded with one
  /// empty starter [Tab] and becomes active; the original keeps its tabs.
  ///
  /// [worktree] seeds that starter tab's hint (SPEC-30 decision 17) so a split
  /// lands on the in-pane starter for the branch you were already in. The
  /// caller supplies it: resolving a bound tab's worktree needs the session
  /// list, which this controller deliberately knows nothing about.
  void divideActive(Axis axis, {SelectedWorktree? worktree}) {
    final tab = Tab(id: nextNodeId(SplitNodeKind.tab), worktree: worktree);
    final newSplit = Split(
      id: nextNodeId(SplitNodeKind.split),
      tabs: [tab],
      activeTabId: tab.id,
    );
    final root = tree.divideSplit(
      state.root,
      state.activeSplitId,
      axis,
      newSplit,
    );
    if (identical(root, state.root)) return;
    _commit(WorkspaceState(root: root, activeSplitId: newSplit.id));
  }

  /// Removes the active [Split], collapsing its parent [Splitter] into the
  /// surviving sibling and focusing that sibling's left-most split. No-op when
  /// the active split is the only one.
  void closeActiveSplit() {
    final target = state.activeSplitId;
    final next = tree.removeSplit(state.root, target);
    if (identical(next, state.root)) return; // sole split → no-op
    _commit(
      WorkspaceState(
        root: next,
        activeSplitId: _focusAfterRemoval(target, next),
      ),
    );
  }

  /// Focuses the [Split] with [id]. No-op when it is already active or absent.
  void setActiveSplit(String id) {
    if (id == state.activeSplitId || !tree.containsSplit(state.root, id)) {
      return;
    }
    _commit(WorkspaceState(root: state.root, activeSplitId: id));
  }

  /// Sets [Splitter] [splitterId]'s ratio (clamped in [setRatio]).
  void setRatio(String splitterId, double ratio) {
    final root = tree.setRatio(state.root, splitterId, ratio);
    if (identical(root, state.root)) return;
    _commit(WorkspaceState(root: root, activeSplitId: state.activeSplitId));
  }

  /// Adds [delta] to [Splitter] [splitterId]'s current ratio, reading the live
  /// state so rapid divider drags accumulate correctly.
  void adjustRatio(String splitterId, double delta) {
    final current = _ratioOf(state.root, splitterId);
    if (current == null) return;
    setRatio(splitterId, current + delta);
  }

  /// Re-docks the [source] split onto [edge] of the [target] split; the moved
  /// split stays active.
  void moveSplit(String source, String target, DropEdge edge) {
    final next = tree.moveSplit(state.root, source, target, edge);
    if (identical(next, state.root)) return;
    final active = tree.containsSplit(next, source)
        ? source
        : tree.firstSplitId(next);
    _commit(WorkspaceState(root: next, activeSplitId: active));
  }

  // -- Tabs -----------------------------------------------------------------

  /// Appends [tab] to [Split] [splitId] and activates it. When [tab] hosts a
  /// session already open elsewhere (decision 5), its existing tab is revealed
  /// instead of being duplicated. No-op when [splitId] is absent.
  void openTab(String splitId, Tab tab) {
    final sessionId = tab.sessionId;
    if (sessionId != null) {
      final existing = tree.findTab(state.root, sessionId);
      if (existing != null) {
        _focus(existing.$1, existing.$2);
        return;
      }
    }
    if (!tree.containsSplit(state.root, splitId)) return;
    final root = tree.mapSplits(
      state.root,
      (s) => s.id == splitId ? tree.addTab(s, tab) : s,
    );
    _commit(WorkspaceState(root: root, activeSplitId: splitId));
  }

  /// Removes [Tab] [tabId] from [Split] [splitId]. When it was the split's last
  /// tab the split collapses (parent [Splitter] folds into the sibling), unless
  /// it is the only split, which instead resets to one empty starter [Tab].
  /// No-op when [splitId] or [tabId] is absent.
  void closeTab(String splitId, String tabId) {
    final split = _splitById(splitId);
    if (split == null) return;
    final removed = tree.removeTab(split, tabId);
    if (identical(removed, split)) return; // tabId absent → no-op
    if (removed != null) {
      final root = tree.mapSplits(
        state.root,
        (s) => s.id == splitId ? removed : s,
      );
      _commit(WorkspaceState(root: root, activeSplitId: state.activeSplitId));
      return;
    }
    _collapseOrReset(splitId);
  }

  /// Switches the active tab of [Split] [splitId] to [tabId]. No-op when either
  /// is absent or [tabId] is already active.
  void setActiveTab(String splitId, String tabId) {
    final split = _splitById(splitId);
    if (split == null) return;
    final updated = tree.activateTab(split, tabId);
    if (identical(updated, split)) return;
    final root = tree.mapSplits(
      state.root,
      (s) => s.id == splitId ? updated : s,
    );
    _commit(WorkspaceState(root: root, activeSplitId: state.activeSplitId));
  }

  /// Moves [Tab] [tabId] from [fromSplitId] to [toSplitId] at [index],
  /// activating it in the target. A same-split move reorders. When the move
  /// empties the source split it collapses (or, were it the only split, resets
  /// to a starter [Tab]). No-op when a split or the tab is absent.
  void moveTab(String fromSplitId, String tabId, String toSplitId, int index) {
    if (fromSplitId == toSplitId) {
      final split = _splitById(fromSplitId);
      if (split == null) return;
      final reordered = tree.reorderTab(split, tabId, index);
      if (identical(reordered, split)) return;
      final root = tree.mapSplits(
        state.root,
        (s) => s.id == fromSplitId ? reordered : s,
      );
      _commit(WorkspaceState(root: root, activeSplitId: state.activeSplitId));
      return;
    }

    final from = _splitById(fromSplitId);
    final to = _splitById(toSplitId);
    if (from == null || to == null) return;
    final moving = _tabOf(from, tabId);
    if (moving == null) return;

    final target = _insertTab(to, moving, index);
    final source = tree.removeTab(from, tabId); // Split? (null when emptied)

    if (source != null) {
      final root = tree.mapSplits(state.root, (s) {
        if (s.id == toSplitId) return target;
        if (s.id == fromSplitId) return source;
        return s;
      });
      _commit(WorkspaceState(root: root, activeSplitId: toSplitId));
      return;
    }

    // Source emptied: update the target first, then collapse the source out of
    // the resulting tree (or reset it if it was somehow the sole split).
    final withTarget = tree.mapSplits(
      state.root,
      (s) => s.id == toSplitId ? target : s,
    );
    final collapsed = tree.removeSplit(withTarget, fromSplitId);
    if (identical(collapsed, withTarget)) {
      _resetSole(fromSplitId);
      return;
    }
    _commit(WorkspaceState(root: collapsed, activeSplitId: toSplitId));
  }

  /// Detaches [Tab] [tabId] from [fromSplitId] into a brand-new [Split] docked
  /// on [edge] of [targetSplitId] (VSCode-style: drag a tab onto a pane edge to
  /// split). The new split becomes active. When the move empties the source it
  /// collapses. No-op when a split or the tab is absent, or when detaching the
  /// sole tab of a split onto an edge of that same split (nothing would change).
  void moveTabToEdge(
    String fromSplitId,
    String tabId,
    String targetSplitId,
    DropEdge edge,
  ) {
    final from = _splitById(fromSplitId);
    if (from == null) return;
    final moving = _tabOf(from, tabId);
    if (moving == null) return;
    if (fromSplitId == targetSplitId && from.tabs.length == 1) return;

    final newSplit = Split(
      id: nextNodeId(SplitNodeKind.split),
      tabs: [moving],
      activeTabId: moving.id,
    );

    // Detach from the source first: reduced split when tabs remain, else the
    // emptied source is collapsed out of the tree (target always survives —
    // the same-split sole-tab case is guarded above).
    final source = tree.removeTab(from, tabId); // Split? (null when emptied)
    final base = source != null
        ? tree.mapSplits(state.root, (s) => s.id == fromSplitId ? source : s)
        : tree.removeSplit(state.root, fromSplitId);

    final root = _dockNewSplit(base, targetSplitId, newSplit, edge);
    if (identical(root, base)) return; // target vanished → no-op
    _commit(WorkspaceState(root: root, activeSplitId: newSplit.id));
  }

  /// Docks [newSplit] on [edge] of [targetSplitId] within [base], returning the
  /// new tree (or [base] unchanged when the target is absent). Shared by the
  /// tab- and session-to-edge drops.
  SplitNode _dockNewSplit(
    SplitNode base,
    String targetSplitId,
    Split newSplit,
    DropEdge edge,
  ) {
    final axis = switch (edge) {
      DropEdge.left || DropEdge.right => Axis.horizontal,
      DropEdge.top || DropEdge.bottom => Axis.vertical,
    };
    final newAfter = edge == DropEdge.right || edge == DropEdge.bottom;
    return tree.divideSplit(
      base,
      targetSplitId,
      axis,
      newSplit,
      newAfter: newAfter,
    );
  }

  /// Drops [sessionId] into [splitId] (e.g. dragged from the sidebar): moves
  /// its existing tab there (dedupe, decision 5), just activates it when it is
  /// already in [splitId], or opens a fresh tab when it lives nowhere yet —
  /// appended and activated. No-op when [splitId] is absent.
  void openSessionInSplit(String splitId, String sessionId) {
    if (!tree.containsSplit(state.root, splitId)) return;
    final existing = tree.findTab(state.root, sessionId);
    if (existing == null) {
      openTab(
        splitId,
        Tab(id: nextNodeId(SplitNodeKind.tab), sessionId: sessionId),
      );
      return;
    }
    if (existing.$1 == splitId) {
      _focus(splitId, existing.$2);
      return;
    }
    moveTab(existing.$1, existing.$2, splitId, _kAppendIndex);
  }

  /// Drops [sessionId] into a brand-new [Split] docked on [edge] of
  /// [targetSplitId]: moves its existing tab (dedupe) or opens a fresh tab in
  /// the new split. No-op when [targetSplitId] is absent.
  void openSessionAtEdge(
    String targetSplitId,
    String sessionId,
    DropEdge edge,
  ) {
    if (!tree.containsSplit(state.root, targetSplitId)) return;
    final existing = tree.findTab(state.root, sessionId);
    if (existing != null) {
      moveTabToEdge(existing.$1, existing.$2, targetSplitId, edge);
      return;
    }
    final tab = Tab(id: nextNodeId(SplitNodeKind.tab), sessionId: sessionId);
    final newSplit = Split(
      id: nextNodeId(SplitNodeKind.split),
      tabs: [tab],
      activeTabId: tab.id,
    );
    final root = _dockNewSplit(state.root, targetSplitId, newSplit, edge);
    if (identical(root, state.root)) return;
    _commit(WorkspaceState(root: root, activeSplitId: newSplit.id));
  }

  // -- Session-oriented ops -------------------------------------------------

  /// SPEC-28 decision 6. Reveals [sessionId]: if a tab already hosts it, focus
  /// that split + tab; otherwise open a new [Tab] for it in the active split.
  /// The session's worktree is its own metadata — never stored on the tab.
  void revealSession(String sessionId) {
    final existing = tree.findTab(state.root, sessionId);
    if (existing != null) {
      _focus(existing.$1, existing.$2);
      return;
    }
    // Bind into the active split's EMPTY active tab when there is one (the
    // starter placeholder seeded by divide/reset) instead of appending next to
    // it — revealing a session should fill the placeholder, not leave a
    // dangling "New" tab.
    final active = _splitById(state.activeSplitId);
    final activeTab = active?.tabs
        .where((t) => t.id == active.activeTabId)
        .firstOrNull;
    if (active != null && activeTab != null && activeTab.sessionId == null) {
      final bound = Tab(id: activeTab.id, sessionId: sessionId);
      final root = tree.mapSplits(
        state.root,
        (s) => s.id != active.id
            ? s
            : Split(
                id: s.id,
                tabs: [
                  for (final t in s.tabs) t.id == activeTab.id ? bound : t,
                ],
                activeTabId: activeTab.id,
              ),
      );
      _commit(WorkspaceState(root: root, activeSplitId: active.id));
      return;
    }
    openTab(
      state.activeSplitId,
      Tab(id: nextNodeId(SplitNodeKind.tab), sessionId: sessionId),
    );
  }

  /// Sidebar worktree selection: reuse the active split's EMPTY placeholder tab
  /// by rebinding its [worktree] hint (instead of stacking another "New" tab on
  /// every click); otherwise open a fresh hinted tab. Mirrors [revealSession]'s
  /// placeholder-fill so the two sidebar paths stay consistent.
  void revealWorktree(SelectedWorktree worktree) {
    final active = _splitById(state.activeSplitId);
    final activeTab = active?.tabs
        .where((t) => t.id == active.activeTabId)
        .firstOrNull;
    if (active != null && activeTab != null && activeTab.sessionId == null) {
      final bound = Tab(id: activeTab.id, worktree: worktree);
      final root = tree.mapSplits(
        state.root,
        (s) => s.id != active.id
            ? s
            : Split(
                id: s.id,
                tabs: [
                  for (final t in s.tabs) t.id == activeTab.id ? bound : t,
                ],
                activeTabId: activeTab.id,
              ),
      );
      _commit(WorkspaceState(root: root, activeSplitId: active.id));
      return;
    }
    openTab(
      state.activeSplitId,
      Tab(id: nextNodeId(SplitNodeKind.tab), worktree: worktree),
    );
  }

  /// Removes the tab hosting [sessionId] from wherever it lives (e.g. after the
  /// session is quit), collapsing/resetting per [closeTab]. No-op when no tab
  /// hosts it.
  void unbindSession(String sessionId) {
    final located = tree.findTab(state.root, sessionId);
    if (located == null) return;
    closeTab(located.$1, located.$2);
  }

  /// Whether any tab in the workspace still hosts [sessionId] (SPEC-29). Used
  /// after closing a tab to decide whether the session is now orphaned (no
  /// remaining view) and should be archived.
  bool isSessionBound(String sessionId) =>
      tree.findTab(state.root, sessionId) != null;

  // -- Internals ------------------------------------------------------------

  /// Focuses tab [tabId] in split [splitId], making that split active.
  void _focus(String splitId, String tabId) {
    final split = _splitById(splitId);
    if (split == null) return;
    final updated = tree.activateTab(split, tabId);
    final root = identical(updated, split)
        ? state.root
        : tree.mapSplits(state.root, (s) => s.id == splitId ? updated : s);
    _commit(WorkspaceState(root: root, activeSplitId: splitId));
  }

  /// Collapses split [splitId] out of the tree, or — when it is the sole split
  /// — resets it to a single empty starter [Tab] (it can never fully close).
  void _collapseOrReset(String splitId) {
    final next = tree.removeSplit(state.root, splitId);
    if (identical(next, state.root)) {
      _resetSole(splitId);
      return;
    }
    _commit(
      WorkspaceState(
        root: next,
        activeSplitId: _focusAfterRemoval(splitId, next),
      ),
    );
  }

  /// Resets the sole split [splitId] to a single fresh empty starter [Tab].
  void _resetSole(String splitId) {
    final tab = Tab(id: nextNodeId(SplitNodeKind.tab));
    final fresh = Split(id: splitId, tabs: [tab], activeTabId: tab.id);
    _commit(WorkspaceState(root: fresh, activeSplitId: splitId));
  }

  /// The split to focus after [removedSplitId] is collapsed out of [next]:
  /// the current active split when it survives and was not the one removed;
  /// otherwise the removed split's surviving sibling (or the first split).
  String _focusAfterRemoval(String removedSplitId, SplitNode next) {
    if (removedSplitId != state.activeSplitId &&
        tree.containsSplit(next, state.activeSplitId)) {
      return state.activeSplitId;
    }
    final sibling = _siblingFirstSplitId(state.root, removedSplitId);
    return (sibling != null && tree.containsSplit(next, sibling))
        ? sibling
        : tree.firstSplitId(next);
  }

  Split? _splitById(String id) =>
      tree.firstSplitWhere(state.root, (s) => s.id == id ? s : null);

  Tab? _tabOf(Split split, String tabId) {
    for (final t in split.tabs) {
      if (t.id == tabId) return t;
    }
    return null;
  }

  Split _insertTab(Split split, Tab tab, int index) {
    final tabs = [...split.tabs];
    tabs.insert(index.clamp(0, tabs.length), tab);
    return Split(id: split.id, tabs: tabs, activeTabId: tab.id);
  }

  /// The left-most split id of [targetId]'s sibling subtree, or null when
  /// [targetId] has no parent [Splitter] (it is the root split).
  String? _siblingFirstSplitId(SplitNode node, String targetId) {
    switch (node) {
      case Split():
        return null;
      case Splitter():
        final first = node.first;
        final second = node.second;
        if (first is Split && first.id == targetId) {
          return tree.firstSplitId(second);
        }
        if (second is Split && second.id == targetId) {
          return tree.firstSplitId(first);
        }
        return _siblingFirstSplitId(first, targetId) ??
            _siblingFirstSplitId(second, targetId);
    }
  }

  double? _ratioOf(SplitNode node, String splitterId) {
    switch (node) {
      case Split():
        return null;
      case Splitter():
        if (node.id == splitterId) return node.ratio;
        return _ratioOf(node.first, splitterId) ??
            _ratioOf(node.second, splitterId);
    }
  }

  void _commit(WorkspaceState next) {
    state = next;
    // Best-effort: a sink that throws must not take the app down with it — the
    // in-memory tree is already correct and the next mutation retries. But it is
    // reported rather than swallowed, so a persistence failure is diagnosable
    // instead of silently costing the user their layout.
    try {
      _onCommit?.call(next);
    } catch (e, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stack,
          library: 'makit',
          context: ErrorDescription('committing a workspace mutation'),
        ),
      );
    }
  }
}

/// The **active group's** split/tab tree (SPEC-30). Derived, not owned: it is
/// rebuilt whenever the active group changes, seeded with that group's stored
/// tree, and every mutation is reported straight back to the groups layer, which
/// owns persistence. Switching groups therefore costs one controller rebuild and
/// loses nothing, because the trees live in the groups.
///
/// Tests that want a bare tree can still override this with
/// `WorkspaceController.ephemeral()`.
final workspaceControllerProvider =
    StateNotifierProvider<WorkspaceController, WorkspaceState>((ref) {
      final groups = ref.watch(groupsControllerProvider.notifier);
      // Only the identity of the active group should rebuild this controller —
      // not every tree mutation it makes, which would be a rebuild loop.
      final activeId = ref.watch<String>(
        groupsControllerProvider.select<String>((s) => s.active.id),
      );
      final tree =
          groups.groupById(activeId)?.tree ??
          WorkspaceController.seedWorkspace();
      return WorkspaceController(
        (next) => groups.commitTree(activeId, next),
        tree,
      );
    });
