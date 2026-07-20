import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Axis;
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pane_node.dart';
// Aliased so the controller's own `setRatio`/`moveLeaf` methods can still
// reach the pure tree functions of the same name.
import 'pane_node.dart' as tree;
import '../selected_worktree.dart';

/// SharedPreferences key holding the whole pane workspace (every worktree's
/// tree plus the current selection) as a single JSON object.
const String kPaneWorkspacePrefsKey = 'desktop_pane_workspace';

/// The split-pane tree of a single worktree plus which leaf is active.
/// Immutable; the [PaneTreeController] swaps in new instances.
@immutable
class PaneTreeState {
  /// Creates a tree state bound to [worktree].
  const PaneTreeState({
    required this.root,
    required this.activeLeafId,
    required this.worktree,
  });

  /// Rebuilds a tree from its [toJson] map.
  factory PaneTreeState.fromJson(Map<String, Object?> json) => PaneTreeState(
    root: PaneNode.fromJson(json['root'] as Map<String, Object?>),
    activeLeafId: json['activeLeafId'] as String,
    worktree: SelectedWorktree.fromJson(
      json['worktree'] as Map<String, Object?>,
    ),
  );

  /// The root of the pane tree.
  final PaneNode root;

  /// The id of the leaf splits and closes act on.
  final String activeLeafId;

  /// The worktree this whole tree belongs to; a null-session leaf starts a
  /// session in it.
  final SelectedWorktree worktree;

  /// JSON for persistence.
  Map<String, Object?> toJson() => {
    'root': root.toJson(),
    'activeLeafId': activeLeafId,
    'worktree': worktree.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is PaneTreeState &&
      other.root == root &&
      other.activeLeafId == activeLeafId &&
      other.worktree == worktree;

  @override
  int get hashCode => Object.hash(root, activeLeafId, worktree);
}

/// The desktop pane workspace: one [PaneTreeState] per worktree (keyed by the
/// worktree's stable [SelectedWorktree.path]) plus which worktree is currently
/// shown. Immutable.
@immutable
class PaneWorkspaceState {
  /// Creates a workspace.
  const PaneWorkspaceState({required this.trees, this.currentKey});

  /// An empty workspace (fresh launch / cleared selection).
  const PaneWorkspaceState.empty() : this(trees: const {});

  /// Rebuilds a workspace from its [toJson] map. Missing/absent fields yield an
  /// empty workspace.
  factory PaneWorkspaceState.fromJson(Map<String, Object?> json) {
    final rawTrees = json['trees'];
    final trees = <String, PaneTreeState>{
      if (rawTrees is Map)
        for (final entry in rawTrees.entries)
          '${entry.key}': PaneTreeState.fromJson(
            entry.value as Map<String, Object?>,
          ),
    };
    final currentKey = json['currentKey'] as String?;
    // A dangling currentKey (no matching tree) collapses to the empty state.
    return PaneWorkspaceState(
      trees: trees,
      currentKey: trees.containsKey(currentKey) ? currentKey : null,
    );
  }

  /// Every worktree's tree, keyed by [SelectedWorktree.path].
  final Map<String, PaneTreeState> trees;

  /// The key of the worktree currently shown, or null for the empty
  /// placeholder.
  final String? currentKey;

  /// The tree currently shown, or null when nothing is selected.
  PaneTreeState? get current => currentKey == null ? null : trees[currentKey];

  /// JSON for persistence.
  Map<String, Object?> toJson() => {
    'trees': {for (final e in trees.entries) e.key: e.value.toJson()},
    'currentKey': currentKey,
  };

  @override
  bool operator ==(Object other) =>
      other is PaneWorkspaceState &&
      other.currentKey == currentKey &&
      mapEquals(other.trees, trees);

  @override
  int get hashCode => Object.hash(
    currentKey,
    Object.hashAllUnordered([
      for (final e in trees.entries) Object.hash(e.key, e.value),
    ]),
  );
}

/// Holds and mutates the desktop pane workspace. Each worktree owns its own
/// split-pane tree; selecting a worktree swaps the whole view. Mirrors the
/// [PreferencesController]/[KeymapController] pattern: nullable prefs make the
/// controller ephemeral (provider default + tests); every mutation writes the
/// whole workspace back through as one JSON blob.
class PaneTreeController extends StateNotifier<PaneWorkspaceState> {
  /// Creates a controller over [prefs], seeded from [initial]. When [prefs] is
  /// null the controller is ephemeral (mutations update state but are not
  /// persisted).
  PaneTreeController(this._prefs, PaneWorkspaceState initial) : super(initial);

  /// A non-persisting controller with an empty workspace.
  PaneTreeController.ephemeral() : this(null, const PaneWorkspaceState.empty());

  /// Builds a controller from the persisted workspace. Corrupt or absent JSON
  /// yields an empty workspace.
  static PaneTreeController load(SharedPreferences prefs) => PaneTreeController(
    prefs,
    _decode(prefs.getString(kPaneWorkspacePrefsKey)),
  );

  static PaneWorkspaceState _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const PaneWorkspaceState.empty();
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const PaneWorkspaceState.empty();
    }
    if (decoded is! Map) return const PaneWorkspaceState.empty();
    try {
      return PaneWorkspaceState.fromJson({
        for (final e in decoded.entries) '${e.key}': e.value,
      });
    } on Object {
      // Any structural mismatch (missing keys, wrong types) → empty workspace
      // rather than a crash, so a bad blob never bricks the pane area.
      return const PaneWorkspaceState.empty();
    }
  }

  final SharedPreferences? _prefs;

  static PaneTreeState _seed(SelectedWorktree worktree) {
    final id = nextPaneId();
    return PaneTreeState(
      root: PaneLeaf(id: id),
      activeLeafId: id,
      worktree: worktree,
    );
  }

  /// The tree currently shown, or null when nothing is selected.
  PaneTreeState? get current => state.current;

  PaneLeaf? _activeLeaf(PaneTreeState treeState) => firstLeafWhere(
    treeState.root,
    (l) => l.id == treeState.activeLeafId ? l : null,
  );

  /// The session id explicitly stored on the current tree's active leaf, or
  /// null (no current tree, or an empty starter leaf).
  String? get activeLeafSessionId {
    final cur = current;
    return cur == null ? null : _activeLeaf(cur)?.sessionId;
  }

  PaneNode _pinLeaf(PaneNode node, String id, {String? sessionId}) => mapLeaves(
    node,
    (l) => l.id == id ? PaneLeaf(id: l.id, sessionId: sessionId) : l,
  );

  /// Replaces the current tree with [update]'s result and persists. No-op when
  /// nothing is selected.
  void _updateCurrent(PaneTreeState Function(PaneTreeState) update) {
    final key = state.currentKey;
    final cur = state.current;
    if (key == null || cur == null) return;
    _commit(
      PaneWorkspaceState(
        trees: {...state.trees, key: update(cur)},
        currentKey: key,
      ),
    );
  }

  void _commit(PaneWorkspaceState next) {
    state = next;
    _persist();
  }

  /// Selects [worktree], swapping the whole view to its tree and seeding a
  /// single empty starter pane the first time it is chosen.
  void selectWorktree(SelectedWorktree worktree) {
    final trees = state.trees.containsKey(worktree.path)
        ? state.trees
        : {...state.trees, worktree.path: _seed(worktree)};
    _commit(PaneWorkspaceState(trees: trees, currentKey: worktree.path));
  }

  /// Switches to [worktree]'s tree (seeding it if absent) and binds [sessionId]
  /// to that tree's active leaf (decision 4: a session's selection follows its
  /// own worktree).
  void bindActiveSession(String sessionId, SelectedWorktree worktree) {
    final tree = state.trees[worktree.path] ?? _seed(worktree);
    final bound = PaneTreeState(
      root: _pinLeaf(tree.root, tree.activeLeafId, sessionId: sessionId),
      activeLeafId: tree.activeLeafId,
      worktree: tree.worktree,
    );
    _commit(
      PaneWorkspaceState(
        trees: {...state.trees, worktree.path: bound},
        currentKey: worktree.path,
      ),
    );
  }

  /// Clears the current selection, showing the empty placeholder. Trees are
  /// retained so re-selecting a worktree restores its layout.
  void clearSelection() {
    if (state.currentKey == null) return;
    _commit(PaneWorkspaceState(trees: state.trees, currentKey: null));
  }

  /// The session ids that currently own a virtual draft tree (keyed
  /// `draft:<sessionId>`). Used to reconcile drafts against the live session
  /// list once it arrives (materialize or prune).
  Iterable<String> draftTreeSessionIds() => state.trees.keys
      .where((k) => k.startsWith(kDraftWorktreePrefix))
      .map((k) => k.substring(kDraftWorktreePrefix.length))
      .toList(growable: false);

  /// Migrate a still-pending draft's virtual tree (`draft:<sessionId>`) onto the
  /// real [worktree] once it materializes on disk, preserving the tree's pane
  /// layout + active leaf so the pane the user is already looking at keeps its
  /// splits and stops reporting the stale "New worktree" title. No-op when the
  /// session has no draft tree. If a tree already exists at the real path (rare
  /// — the same worktree reached another way), that one wins and the draft is
  /// just dropped.
  void materializeDraft(String sessionId, SelectedWorktree worktree) {
    final draftKey = '$kDraftWorktreePrefix$sessionId';
    final draftTree = state.trees[draftKey];
    if (draftTree == null) return;
    final trees = {...state.trees}..remove(draftKey);
    trees[worktree.path] ??= PaneTreeState(
      root: draftTree.root,
      activeLeafId: draftTree.activeLeafId,
      worktree: worktree,
    );
    _commit(
      PaneWorkspaceState(
        trees: trees,
        currentKey: state.currentKey == draftKey
            ? worktree.path
            : state.currentKey,
      ),
    );
  }

  /// Drop a draft's virtual tree whose pending session no longer exists (e.g. a
  /// draft abandoned before its first message, or a persisted draft tree whose
  /// session is gone after a restart) so stale `draft:` keys can't accumulate
  /// in the persisted workspace. No-op when no such tree exists.
  void dropDraftTree(String sessionId) {
    final draftKey = '$kDraftWorktreePrefix$sessionId';
    if (!state.trees.containsKey(draftKey)) return;
    final trees = {...state.trees}..remove(draftKey);
    _commit(
      PaneWorkspaceState(
        trees: trees,
        currentKey: state.currentKey == draftKey ? null : state.currentKey,
      ),
    );
  }

  /// Splits the current tree's active pane along [axis]. The current pane keeps
  /// its own session; the fresh leaf is empty (a null-session leaf renders the
  /// tree's worktree harness picker) and becomes active.
  void splitActive(Axis axis) {
    _updateCurrent((cur) {
      final newLeaf = PaneLeaf(id: nextPaneId());
      return PaneTreeState(
        root: splitLeaf(cur.root, cur.activeLeafId, axis, newLeaf),
        activeLeafId: newLeaf.id,
        worktree: cur.worktree,
      );
    });
  }

  /// Closes the current tree's active pane, collapsing its parent split into
  /// the sibling and focusing the sibling's left-most leaf. When the active
  /// pane is the only one left, the whole tree is removed and the view drops to
  /// the empty placeholder (`current == null`).
  void closeActive() {
    final cur = state.current;
    if (cur == null) return;
    final target = cur.activeLeafId;
    final sibling = _siblingFirstLeafId(cur.root, target);
    final next = closeLeaf(cur.root, target);
    if (identical(next, cur.root) || next == cur.root) {
      // The active leaf is the only pane (closeLeaf can't remove the root
      // leaf): closing it removes this worktree's tree entirely so the pane
      // area shows the empty "Select or start a session" placeholder.
      final key = state.currentKey;
      if (key == null) return;
      final trees = Map<String, PaneTreeState>.from(state.trees)..remove(key);
      _commit(PaneWorkspaceState(trees: trees, currentKey: null));
      return;
    }
    final focus = (sibling != null && containsLeaf(next, sibling))
        ? sibling
        : firstLeafId(next);
    _updateCurrent(
      (c) =>
          PaneTreeState(root: next, activeLeafId: focus, worktree: c.worktree),
    );
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

  /// Marks the leaf [leafId] active in the current tree (visible focus ring).
  void setActive(String leafId) {
    final cur = state.current;
    if (cur == null ||
        leafId == cur.activeLeafId ||
        !containsLeaf(cur.root, leafId)) {
      return;
    }
    _updateCurrent(
      (c) => PaneTreeState(
        root: c.root,
        activeLeafId: leafId,
        worktree: c.worktree,
      ),
    );
  }

  /// Updates the ratio of split [splitId] in the current tree (clamped in
  /// [setRatio]).
  void setRatio(String splitId, double ratio) {
    _updateCurrent(
      (c) => PaneTreeState(
        root: tree.setRatio(c.root, splitId, ratio),
        activeLeafId: c.activeLeafId,
        worktree: c.worktree,
      ),
    );
  }

  /// Adds [delta] to split [splitId]'s current ratio, reading the live state so
  /// rapid divider drags accumulate correctly.
  void adjustRatio(String splitId, double delta) {
    final cur = state.current;
    if (cur == null) return;
    final current = _ratioOf(cur.root, splitId);
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

  /// Unbinds [sessionId] from every pane pinned to it **in every tree** (e.g.
  /// after the session is quit), so a dead session never lingers in any
  /// worktree's layout.
  void unbindSession(String sessionId) {
    final trees = {
      for (final e in state.trees.entries)
        e.key: PaneTreeState(
          root: _clearSession(e.value.root, sessionId),
          activeLeafId: e.value.activeLeafId,
          worktree: e.value.worktree,
        ),
    };
    _commit(PaneWorkspaceState(trees: trees, currentKey: state.currentKey));
  }

  PaneNode _clearSession(PaneNode node, String sessionId) =>
      mapLeaves(node, (l) => l.sessionId == sessionId ? PaneLeaf(id: l.id) : l);

  /// Re-docks the [source] leaf onto [edge] of the [target] leaf in the current
  /// tree; the moved pane stays active.
  void moveLeaf(String source, String target, DropEdge edge) {
    final cur = state.current;
    if (cur == null) return;
    final next = tree.moveLeaf(cur.root, source, target, edge);
    if (next == cur.root) return;
    _updateCurrent(
      (c) => PaneTreeState(
        root: next,
        activeLeafId: containsLeaf(next, source) ? source : firstLeafId(next),
        worktree: c.worktree,
      ),
    );
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (state.trees.isEmpty && state.currentKey == null) {
      await prefs.remove(kPaneWorkspacePrefsKey);
    } else {
      await prefs.setString(kPaneWorkspacePrefsKey, jsonEncode(state.toJson()));
    }
  }
}

/// The desktop pane workspace. Defaults to a non-persisting controller with an
/// empty workspace; `runDesktopApp` overrides it with a
/// [SharedPreferences]-backed one, and tests may override it too.
final paneTreeControllerProvider =
    StateNotifierProvider<PaneTreeController, PaneWorkspaceState>(
      (ref) => PaneTreeController.ephemeral(),
    );
