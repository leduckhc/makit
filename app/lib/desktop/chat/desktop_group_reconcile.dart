/// SPEC-tab-groups — keeping each group's stored tree in line with what the server says
/// exists. Extracted from `desktop_session_prune.dart` so a reader looking for
/// "what closes a group when its worktree is deleted" finds it by filename, and
/// so the session-vanish pruning next door stays one small idea.
///
/// These are plain functions rather than a second provider on purpose. They must
/// run in a fixed order relative to pruning — membership is unpinned *before*
/// the canvas is reconciled against it — and two providers listening to the same
/// `sessions.snapshot` would make that order implicit and fragile.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'groups/placement.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';
import 'selected_worktree.dart';

/// Brings the **active** group's canvas in line with its membership
/// (SPEC-tab-groups decisions 5, 9, 20).
///
/// * A worktree group is derived, so newcomers are placed, out-of-scope tabs are
///   dropped, and an empty scope seeds the in-pane starter — never switching
///   groups (decision 5) and never re-arranging existing panes (decision 9).
/// * A board's tree is the user's, so only tabs of vanished sessions are closed.
///
/// Only the active group is reconciled reactively: a background group's stored
/// tree is brought in line when it is activated, which is the first moment it
/// could be seen. Membership itself (derived) is always correct regardless.
void reconcileActiveCanvas(Ref ref, SessionsState sessions) {
  final workspace = ref.read(workspaceControllerProvider.notifier);
  // Read the groups state straight from its notifier, and resolve membership
  // with the pure [membersOf], rather than going through `activeGroupProvider` /
  // `groupMembersProvider`: this runs from listeners that can both fire in one
  // frame (a local pin plus a session snapshot), and Riverpod refuses to rebuild
  // a derived provider twice in the same one.
  final active = ref.read(groupsControllerProvider).active;
  final members = membersOf(
    kind: active.kind,
    projectId: active.projectId,
    worktreePath: active.worktreePath,
    members: active.members,
    sessions: sessions,
  );
  // A session the server has not located yet (a draft before its first
  // message) belongs to no scope, so it must not be mistaken for a foreign
  // tab and dropped from under the user.
  final unlocated = {
    for (final s in sessions.sessions)
      if (s.worktreePath == null) s.id,
  };

  if (active.kind == GroupKind.worktree) {
    reconcileInto(
      workspace,
      members,
      threshold: ref.read(autoSplitThresholdProvider),
      layoutOverride: active.layoutOverride,
      unlocated: unlocated,
      emptyHint: SelectedWorktree(
        projectId: active.projectId!,
        path: active.worktreePath!,
        branch: active.label,
      ),
    );
    return;
  }

  // A board's members got there by an explicit gesture (decision 14: pin,
  // drop, picker tick), so placing them *is* the user's intent — which is why
  // the canvas must reconcile against curated membership too, not merely close
  // vanished tabs. This is also what makes a reopened board come back showing
  // its survivors: its stored tree may never have been populated, so the
  // panes are (re)placed from the member list here.
  //
  // A board owns no scope, so there is no empty-hint starter and newcomers must
  // *appear* rather than seize the canvas: focus is captured and restored
  // around placement, since placeInto legitimately focuses what it just placed
  // (correct for the toggle, wrong for a background pin). Existing panes still
  // never move — that invariant lives in reconcileInto (decision 9).
  final before = ref.read(workspaceControllerProvider);
  final (keepSplit, keepTab) = _focusedPane(before);
  reconcileInto(
    workspace,
    members,
    threshold: ref.read(autoSplitThresholdProvider),
    layoutOverride: active.layoutOverride,
    unlocated: unlocated,
  );
  workspace.setActiveSplit(keepSplit);
  if (keepTab != null) workspace.setActiveTab(keepSplit, keepTab);
}

/// The `(activeSplitId, activeTabId)` pair identifying the focused pane, so a
/// board reconcile can restore it after placing background arrivals.
(String, String?) _focusedPane(WorkspaceState state) {
  final split = firstSplitWhere<Split>(
    state.root,
    (s) => s.id == state.activeSplitId ? s : null,
  );
  return (state.activeSplitId, split?.activeTabId);
}

/// Closes every worktree group whose scope no longer exists (SPEC-tab-groups decision 7
/// tail: "its worktree group disappears with its scope").
///
/// Detected reactively off the repo list, so it needs no hook in the UI-owned
/// delete flow. The decision is unconditional — every worktree group is checked,
/// not just the active one — while the *focus* rule is active-scoped and already
/// handled by [GroupsController.closeGroup] falling to the neighbour.
void closeGroupsForDeletedWorktrees(Ref ref, ReposState repos) {
  final groupsCtrl = ref.read(groupsControllerProvider.notifier);
  for (final g in ref.read(groupsControllerProvider).groups) {
    if (g.kind != GroupKind.worktree) continue;
    final repo = repos.byId(g.projectId!);
    if (repo == null) continue; // not loaded yet — say nothing
    // A repo mid-refresh can report an empty worktree list; closing on that
    // would delete groups the user still has. Only an otherwise-populated list
    // is evidence that this particular worktree is gone.
    if (repo.worktrees.isEmpty) continue;
    if (repo.worktrees.any((w) => w.path == g.worktreePath)) continue;
    groupsCtrl.closeGroup(g.id);
  }
}
