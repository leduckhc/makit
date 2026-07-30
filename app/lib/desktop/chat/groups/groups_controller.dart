/// SPEC-30 — the groups layer: which groups exist, which one is active, which
/// boards were recently closed, and the one persisted payload for all of it.
///
/// This is a **pure state container**. It takes the data it needs as arguments
/// (a session's location, the set of live session ids) instead of reading
/// providers or the store, so every rule it enforces is testable without a
/// widget tree — and so the rules live in one place rather than being
/// re-implemented at each call site.
///
/// It also owns persistence for the split/tab trees: since SPEC-30 there are
/// many trees (one per group), [WorkspaceController] reports mutations through a
/// [WorkspaceCommit] sink and this controller writes them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../panes/split_node.dart';
import '../panes/workspace_controller.dart';
import 'group.dart';

/// SharedPreferences key holding every group, the active group, and the
/// recently-closed boards as one versioned JSON object.
const String kGroupsPrefsKey = 'desktop_groups';

/// Payload version. Bump when the shape changes; an unknown version falls back
/// to a fresh state rather than guessing (the SPEC-28 blob had no version,
/// which is exactly why migrating it needed a special case).
const int kGroupsPayloadVersion = 1;

/// How many closed boards are remembered (SPEC-30 decision 8).
const int kRecentlyClosedLimit = 10;

/// Where a session runs — the pair that decides whether it belongs to a
/// worktree group's scope. Passed in rather than looked up, keeping this layer
/// free of the session store.
@immutable
class SessionLocation {
  /// Creates a location.
  const SessionLocation({required this.projectId, this.worktreePath});

  /// The project the session belongs to.
  final String projectId;

  /// The worktree the session runs in, or null when it has none yet.
  final String? worktreePath;
}

/// A board the user closed, plus the tab slot it occupied so reopening restores
/// its position and not just its contents.
@immutable
class ClosedBoard {
  /// Creates a closed-board record.
  const ClosedBoard({required this.group, required this.slot});

  /// Rebuilds a record, or null when the group inside it is unusable.
  static ClosedBoard? fromJson(Map<String, Object?> json) {
    final raw = json['group'];
    if (raw is! Map<String, Object?>) return null;
    final group = Group.fromJson(raw);
    if (group == null) return null;
    return ClosedBoard(
      group: group,
      slot: (json['slot'] as num?)?.toInt() ?? 0,
    );
  }

  /// The board itself, membership and arrangement intact.
  final Group group;

  /// The index it sat at in the group bar.
  final int slot;

  /// JSON for persistence.
  Map<String, Object?> toJson() => {'group': group.toJson(), 'slot': slot};

  @override
  bool operator ==(Object other) =>
      other is ClosedBoard && other.group == group && other.slot == slot;

  @override
  int get hashCode => Object.hash(group, slot);
}

/// Every group, the active one, and the recently-closed boards.
@immutable
class GroupsState {
  /// Creates a state. [activeGroupId] must reference a group in [groups], and
  /// [groups] must never be empty — there is always a canvas. Asserted here so
  /// a violation surfaces where it is diagnosable rather than as a `.first` on
  /// an empty list somewhere in a widget build. `closeGroup` refuses to close
  /// the last group and every decoder falls back to [fresh], so the invariant
  /// holds by construction.
  const GroupsState({
    required this.groups,
    required this.activeGroupId,
    this.recentlyClosed = const [],
  }) : assert(groups.length > 0, 'a workspace always has at least one group');

  /// The fresh-launch state: one empty board. SPEC-30 decision 19 prefers the
  /// most recently active session's worktree group, but sessions are not known
  /// until the first snapshot arrives — [GroupsController.seedFromSessions]
  /// upgrades this the moment they are.
  factory GroupsState.fresh() {
    final board = Group.board(
      id: newGroupId(),
      label: 'Board 1',
      tree: WorkspaceController.seedWorkspace(),
    );
    return GroupsState(groups: [board], activeGroupId: board.id);
  }

  /// The groups, in group-bar order.
  final List<Group> groups;

  /// The group whose tree is on the canvas.
  final String activeGroupId;

  /// Closed boards, oldest first, capped at [kRecentlyClosedLimit].
  final List<ClosedBoard> recentlyClosed;

  /// The active group. Falls back to the first group when the id is stale, so
  /// there is always a canvas.
  Group get active => groups.firstWhere(
    (g) => g.id == activeGroupId,
    orElse: () => groups.first,
  );

  /// JSON for persistence, versioned.
  Map<String, Object?> toJson() => {
    'v': kGroupsPayloadVersion,
    'groups': [for (final g in groups) g.toJson()],
    'activeGroupId': activeGroupId,
    'recentlyClosed': [for (final c in recentlyClosed) c.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GroupsState &&
      listEquals(other.groups, groups) &&
      other.activeGroupId == activeGroupId &&
      listEquals(other.recentlyClosed, recentlyClosed);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(groups),
    activeGroupId,
    Object.hashAll(recentlyClosed),
  );
}

/// Monotonic group ids. Unlike node ids these never need to be replayed from a
/// restored tree, so a simple counter salted by time is enough to avoid
/// colliding with persisted ids after a restart.
int _groupSeq = 0;
String newGroupId() =>
    'group-${DateTime.now().microsecondsSinceEpoch}-${_groupSeq++}';

/// Owns the groups. See the library doc for why it takes data, not providers.
class GroupsController extends StateNotifier<GroupsState> {
  /// Creates a controller over [prefs], seeded from [initial]. A null [prefs]
  /// makes it ephemeral (mutations update state but are never written).
  GroupsController(this._prefs, GroupsState initial) : super(initial);

  /// A non-persisting controller, for the provider default and tests.
  GroupsController.ephemeral([GroupsState? initial])
    : this(null, initial ?? GroupsState.fresh());

  /// Builds a controller from persisted state, migrating the SPEC-28 single
  /// workspace when this is the first run with groups.
  static GroupsController load(SharedPreferences prefs) =>
      GroupsController(prefs, decode(prefs));

  final SharedPreferences? _prefs;

  /// The group with [id], or null.
  Group? groupById(String id) {
    for (final g in state.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  // -- Activation -----------------------------------------------------------

  /// Focuses [id]. No-op for an unknown id, so a stale reference can never
  /// leave the canvas pointing at nothing.
  void activate(String id) {
    if (id == state.activeGroupId || groupById(id) == null) return;
    _commit(_copy(activeGroupId: id));
  }

  /// Activates the group for `(projectId, worktreePath)`, minting it when no
  /// group holds that scope yet (SPEC-30 decision 15). Returns its id.
  String openWorktreeGroup({
    required String projectId,
    required String worktreePath,
    required String label,
  }) {
    for (final g in state.groups) {
      if (g.isScopedTo(projectId: projectId, worktreePath: worktreePath)) {
        activate(g.id);
        return g.id;
      }
    }
    final minted = Group.worktree(
      id: newGroupId(),
      projectId: projectId,
      worktreePath: worktreePath,
      label: label,
      tree: WorkspaceController.seedWorkspace(),
    );
    _commit(_copy(groups: [...state.groups, minted], activeGroupId: minted.id));
    return minted.id;
  }

  /// Creates an empty board and activates it. Returns its id.
  String newBoard({String? label}) {
    final boards = state.groups.where((g) => g.kind == GroupKind.board).length;
    final board = Group.board(
      id: newGroupId(),
      label: label ?? 'Board ${boards + 1}',
      tree: WorkspaceController.seedWorkspace(),
    );
    _commit(_copy(groups: [...state.groups, board], activeGroupId: board.id));
    return board.id;
  }

  // -- Closing (decision 7) -------------------------------------------------

  /// Closes [id]. A worktree group leaves **no residue** — its membership is
  /// derived, so clicking the branch rebuilds an identical group. A board's
  /// hand-made list has nothing to rebuild it from, so it is kept in
  /// [GroupsState.recentlyClosed]. Refuses to close the last group: there is
  /// always a canvas.
  void closeGroup(String id) {
    if (state.groups.length <= 1) return;
    final index = state.groups.indexWhere((g) => g.id == id);
    if (index < 0) return;
    final closing = state.groups[index];
    final groups = [...state.groups]..removeAt(index);
    final recentlyClosed = closing.kind == GroupKind.board
        ? _capped([
            ...state.recentlyClosed,
            ClosedBoard(group: closing, slot: index),
          ])
        : state.recentlyClosed;
    _commit(
      GroupsState(
        groups: groups,
        // Focus falls to the neighbour, mirroring how closing a split behaves.
        activeGroupId: state.activeGroupId == id
            ? groups[(index - 1).clamp(0, groups.length - 1)].id
            : state.activeGroupId,
        recentlyClosed: recentlyClosed,
      ),
    );
  }

  /// Reopens a closed board at its old slot, **filtering members that died
  /// while it was closed** (decision 8): a closed board is not live, so the
  /// unpin-on-vanish rule cannot reach it. A board left with no survivors still
  /// returns — it is a named thing the user made.
  void reopenBoard(String id, {required Set<String> liveSessionIds}) {
    final at = state.recentlyClosed.indexWhere((c) => c.group.id == id);
    if (at < 0) return;
    _restore(at, liveSessionIds);
  }

  /// Reopens the most recently closed board (the Undo affordance).
  void undoClose({required Set<String> liveSessionIds}) {
    if (state.recentlyClosed.isEmpty) return;
    _restore(state.recentlyClosed.length - 1, liveSessionIds);
  }

  void _restore(int at, Set<String> liveSessionIds) {
    final closed = state.recentlyClosed[at];
    final pruned = _pruneToLive(closed.group, liveSessionIds);
    final groups = [...state.groups]
      ..insert(closed.slot.clamp(0, state.groups.length), pruned);
    _commit(
      GroupsState(
        groups: groups,
        activeGroupId: pruned.id,
        recentlyClosed: [...state.recentlyClosed]..removeAt(at),
      ),
    );
  }

  // -- Membership (decisions 3, 4) ------------------------------------------

  /// Adds [sessionId] to [groupId] as the result of an **explicit** gesture
  /// (drag, quick-pin, picker tick — never navigation).
  ///
  /// On a board it is appended, at most once. On a worktree group an in-scope
  /// session is already a member (membership is derived, so there is nothing to
  /// store), and an **out-of-scope session converts the group into a board**
  /// holding what was on screen plus the newcomer — inserted right after the
  /// original, which is left untouched, and activated.
  void addMember(
    String groupId,
    String sessionId, {
    required SessionLocation location,
  }) {
    final index = state.groups.indexWhere((g) => g.id == groupId);
    if (index < 0) return;
    final group = state.groups[index];

    if (group.kind == GroupKind.board) {
      if (group.members.contains(sessionId)) return;
      _replace(index, group.copyWith(members: [...group.members, sessionId]));
      return;
    }
    if (group.isScopedTo(
      projectId: location.projectId,
      worktreePath: location.worktreePath,
    )) {
      return; // derived membership already covers it
    }

    final converted = Group.board(
      id: newGroupId(),
      label: '${group.label} +1',
      members: [..._boundSessionIds(group.tree), sessionId],
      tree: group.tree,
    );
    final groups = [...state.groups]..insert(index + 1, converted);
    _commit(_copy(groups: groups, activeGroupId: converted.id));
  }

  /// Removes [sessionId] from a board (the agent keeps running). No-op on a
  /// worktree group, whose membership is not the user's to edit.
  ///
  /// The session's **tab is dropped from the board's tree too**. Membership and
  /// tree must not be allowed to disagree: a tab bound to a non-member is a dead
  /// tile, which is exactly what decision 6 forbids — and it would only have
  /// surfaced later, when the user activated that board.
  void removeMember(String groupId, String sessionId) {
    final index = state.groups.indexWhere((g) => g.id == groupId);
    if (index < 0) return;
    final group = state.groups[index];
    if (group.kind != GroupKind.board) return;
    if (!group.members.contains(sessionId)) return;
    _replace(
      index,
      group.copyWith(
        members: group.members.where((m) => m != sessionId).toList(),
        tree: _dropTabs(group.tree, [sessionId]),
      ),
    );
  }

  // -- Trees + placement policy --------------------------------------------

  /// Stores [tree] as [groupId]'s arrangement. This is the sink
  /// [WorkspaceController] reports every tree mutation through.
  void commitTree(String groupId, WorkspaceState tree) {
    final index = state.groups.indexWhere((g) => g.id == groupId);
    if (index < 0) return;
    if (state.groups[index].tree == tree) return;
    _replace(index, state.groups[index].copyWith(tree: tree));
  }

  /// Pins [groupId] to [mode], or follows the threshold again when null
  /// (decision 9).
  void setLayoutOverride(String groupId, LayoutMode? mode) {
    final index = state.groups.indexWhere((g) => g.id == groupId);
    if (index < 0) return;
    _replace(index, state.groups[index].withLayout(mode));
  }

  /// Renames a **board** to [label] (trimmed). A worktree group's label is its
  /// branch and is not user-editable, so this is a no-op for one. An empty or
  /// unchanged label is ignored.
  void renameBoard(String groupId, String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;
    final index = state.groups.indexWhere((g) => g.id == groupId);
    if (index < 0) return;
    final group = state.groups[index];
    if (group.kind != GroupKind.board || group.label == trimmed) return;
    _replace(index, group.copyWith(label: trimmed));
  }

  /// Replaces a *pristine* fresh-launch state with the worktree group of the
  /// most recently active session (decision 19). Deliberately conservative: it
  /// only fires when the workspace is still the single untouched `Board 1`, so
  /// it can never disturb a layout the user has shaped.
  void seedFromSessions({
    required String projectId,
    required String worktreePath,
    required String label,
  }) {
    if (!_isPristine) return;
    final group = Group.worktree(
      id: newGroupId(),
      projectId: projectId,
      worktreePath: worktreePath,
      label: label,
      tree: WorkspaceController.seedWorkspace(),
    );
    _commit(GroupsState(groups: [group], activeGroupId: group.id));
  }

  bool get _isPristine {
    if (state.groups.length != 1 || state.recentlyClosed.isNotEmpty) {
      return false;
    }
    final only = state.groups.single;
    return only.kind == GroupKind.board &&
        only.members.isEmpty &&
        only.label == 'Board 1' &&
        _boundSessionIds(only.tree).isEmpty;
  }

  // -- Persistence ---------------------------------------------------------

  /// Decodes persisted state, migrating the SPEC-28 single workspace on first
  /// run and falling back to [GroupsState.fresh] for anything unusable.
  @visibleForTesting
  static GroupsState decode(SharedPreferences prefs) {
    final raw = prefs.getString(kGroupsPrefsKey);
    if (raw == null || raw.isEmpty) return _migrateLegacy(prefs);
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return GroupsState.fresh();
    }
    if (decoded is! Map) return GroupsState.fresh();
    if (decoded['v'] != kGroupsPayloadVersion) return GroupsState.fresh();

    final groups = <Group>[];
    final rawGroups = decoded['groups'];
    if (rawGroups is List) {
      for (final entry in rawGroups) {
        if (entry is! Map) continue;
        final group = Group.fromJson({
          for (final e in entry.entries) '${e.key}': e.value,
        });
        // A corrupt group is dropped, never fatal.
        if (group != null) groups.add(group);
      }
    }
    if (groups.isEmpty) return GroupsState.fresh();

    final closed = <ClosedBoard>[];
    final rawClosed = decoded['recentlyClosed'];
    if (rawClosed is List) {
      for (final entry in rawClosed) {
        if (entry is! Map) continue;
        final record = ClosedBoard.fromJson({
          for (final e in entry.entries) '${e.key}': e.value,
        });
        if (record != null) closed.add(record);
      }
    }

    // Advance the node-id counters past EVERY restored tree — including the ones
    // inside closed boards. Seeding only the live groups left the counter low,
    // so ids minted afterwards marched into the range a closed board was still
    // using, and reopening it produced duplicate ids inside one tree.
    for (final g in groups) {
      seedNodeIdsFrom(g.tree.root);
    }
    for (final record in closed) {
      seedNodeIdsFrom(record.group.tree.root);
    }

    final activeId = decoded['activeGroupId'];
    final active = groups.any((g) => g.id == activeId)
        ? activeId as String
        : groups.first.id;
    return GroupsState(
      groups: groups,
      activeGroupId: active,
      recentlyClosed: _capped(closed),
    );
  }

  /// First run with groups: fold the SPEC-28 single workspace into one board so
  /// nobody loses their layout. Empty tabs are carried over verbatim (decision
  /// 21) and bound tabs become the board's membership.
  static GroupsState _migrateLegacy(SharedPreferences prefs) {
    final legacyRaw = prefs.getString(kWorkspacePrefsKey);
    if (legacyRaw == null || legacyRaw.isEmpty) return GroupsState.fresh();
    final tree = WorkspaceController.decodeWorkspace(legacyRaw);
    final members = _boundSessionIds(tree);
    if (members.isEmpty && _isSeedShaped(tree)) return GroupsState.fresh();
    final board = Group.board(
      id: newGroupId(),
      label: 'Board 1',
      members: members,
      tree: tree,
    );
    return GroupsState(groups: [board], activeGroupId: board.id);
  }

  /// Whether [tree] is indistinguishable from a fresh starter workspace (one
  /// split, one empty tab) — in which case there is nothing worth migrating.
  static bool _isSeedShaped(WorkspaceState tree) {
    final root = tree.root;
    return root is Split &&
        root.tabs.length == 1 &&
        root.tabs.single.sessionId == null;
  }

  // -- Internals -----------------------------------------------------------

  GroupsState _copy({
    List<Group>? groups,
    String? activeGroupId,
    List<ClosedBoard>? recentlyClosed,
  }) => GroupsState(
    groups: groups ?? state.groups,
    activeGroupId: activeGroupId ?? state.activeGroupId,
    recentlyClosed: recentlyClosed ?? state.recentlyClosed,
  );

  void _replace(int index, Group group) {
    final groups = [...state.groups]..[index] = group;
    _commit(_copy(groups: groups));
  }

  /// Drops members (and their tabs) that are no longer live.
  static Group _pruneToLive(Group board, Set<String> live) {
    final members = board.members.where(live.contains).toList();
    if (members.length == board.members.length) return board;
    final dropped = board.members.where((m) => !live.contains(m));
    return board.copyWith(
      members: members,
      tree: _dropTabs(board.tree, dropped),
    );
  }

  static List<ClosedBoard> _capped(List<ClosedBoard> all) =>
      all.length <= kRecentlyClosedLimit
      ? all
      : all.sublist(all.length - kRecentlyClosedLimit);

  static List<String> _boundSessionIds(WorkspaceState tree) {
    final ids = <String>[];
    firstSplitWhere<bool>(tree.root, (split) {
      ids.addAll(split.tabs.map((t) => t.sessionId).nonNulls);
      return null;
    });
    return ids;
  }

  /// Removes every tab bound to a session in [doomed], collapsing emptied
  /// splits, by driving the class that already owns tree surgery. Reimplementing
  /// that here would be a second copy of the invariants.
  static WorkspaceState _dropTabs(
    WorkspaceState tree,
    Iterable<String> doomed,
  ) {
    final scratch = WorkspaceController(null, tree);
    for (final id in doomed) {
      scratch.unbindSession(id);
    }
    return scratch.state;
  }

  void _commit(GroupsState next) {
    state = next;
    _schedulePersist();
  }

  /// Coalesce writes to the end of the current microtask queue.
  ///
  /// Every tree mutation lands here — a divider drag emits one per frame — and
  /// each write serialises *all* groups, their trees and the closed-board list.
  /// Dragging a divider therefore produced a burst of full-state encodes. Only
  /// the last state in a burst matters, so schedule once and write once.
  void _schedulePersist() {
    if (_prefs == null || _persistScheduled) return;
    _persistScheduled = true;
    scheduleMicrotask(() {
      _persistScheduled = false;
      _persist();
    });
  }

  bool _persistScheduled = false;

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setString(kGroupsPrefsKey, jsonEncode(state.toJson()));
    } catch (e, stack) {
      // Best-effort, but not silent: a user losing their layout across restarts
      // is a real bug and an empty catch makes it undiagnosable.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: stack,
          library: 'makit',
          context: ErrorDescription('persisting desktop groups'),
        ),
      );
      // Best-effort, exactly as the workspace blob was: a failed write must not
      // crash the app; the in-memory state is intact and the next mutation
      // retries.
    }
  }
}

/// The groups layer. Defaults to a non-persisting controller; `runDesktopApp`
/// overrides it with a [SharedPreferences]-backed one, and tests may too.
final groupsControllerProvider =
    StateNotifierProvider<GroupsController, GroupsState>(
      (ref) => GroupsController.ephemeral(),
    );
