import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../store/models.dart';
import '../../store/store.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';
import 'selected_worktree.dart';

export 'selected_worktree.dart';

/// The active tab of [state] — the active split's active tab, or null when the
/// active split can't be located (should not happen for a live workspace).
Tab? activeTab(WorkspaceState state) {
  final split = firstSplitWhere(
    state.root,
    (s) => s.id == state.activeSplitId ? s : null,
  );
  if (split == null) return null;
  for (final t in split.tabs) {
    if (t.id == split.activeTabId) return t;
  }
  return null;
}

/// The session currently shown in the desktop chat workspace, or `null` when
/// the active tab is an empty placeholder (SPEC-28 decisions 4 & 6).
///
/// A **derived mirror** of the active split's active tab's `sessionId`: every
/// selection change routes through [WorkspaceController], so the sidebar
/// highlight can never desync from the visible tab. There is no direct writer.
final selectedSessionProvider = Provider<String?>(
  (ref) => activeTab(ref.watch(workspaceControllerProvider))?.sessionId,
);

/// The worktree of the active tab, for the sidebar grouping highlight, or null
/// when the active tab has neither a session nor a worktree hint. Derived from
/// the workspace so it tracks the visible tab (SPEC-28: worktree is per-session
/// metadata, never a layout owner).
final selectedWorktreeProvider = Provider<SelectedWorktree?>((ref) {
  final tab = activeTab(ref.watch(workspaceControllerProvider));
  if (tab == null) return null;
  final sessionId = tab.sessionId;
  if (sessionId == null) return tab.worktree;
  return _worktreeOfSession(ref.watch(sessionsProvider).byId(sessionId));
});

/// The real, on-disk worktree of [session], or null when it has none yet (a
/// still-pending draft with no `worktreePath`).
SelectedWorktree? _worktreeOfSession(Session? session) {
  final path = session?.worktreePath;
  if (session == null || path == null) return null;
  return SelectedWorktree(
    projectId: session.projectId,
    path: path,
    branch: session.branch,
  );
}

/// The active tab's real worktree for pre-filling the New-session dialog, or
/// null when the active tab has no session (or its session has no worktree on
/// disk yet). An empty tab's worktree hint pre-fills too.
SelectedWorktree? activeRealWorktree(WidgetRef ref) {
  final tab = activeTab(ref.read(workspaceControllerProvider));
  if (tab == null) return null;
  final sessionId = tab.sessionId;
  if (sessionId == null) return tab.worktree;
  return _worktreeOfSession(ref.read(sessionsProvider).byId(sessionId));
}

/// Navigate to [id] (SPEC-30 decision 15): **activate a group that already
/// contains it, then reveal its tab there** — navigation never mutates
/// membership, so it can never trigger decision 4's conversion. Resolution
/// order (a→d) lives in [groupHolding]; when it finds nothing (d) we mint the
/// session's own worktree group. A session with no worktree yet, or one the
/// store no longer knows, falls back to a plain reveal in the active group.
/// [selectedSessionProvider] follows automatically (it mirrors the active tab).
void selectSessionExclusive(WidgetRef ref, String id) {
  final session = ref.read(sessionsProvider).byId(id);
  final workspace = ref.read(workspaceControllerProvider.notifier);
  if (session == null) {
    workspace.revealSession(id);
    return;
  }
  final groups = ref.read(groupsControllerProvider.notifier);
  final held = groupHolding(
    ref.read(groupsControllerProvider),
    session,
    (groupId) => ref.read(groupMembersProvider(groupId)),
  );
  final worktreePath = session.worktreePath;
  if (held != null) {
    groups.activate(held);
  } else if (worktreePath != null) {
    // (d) mint its worktree group and activate it.
    groups.openWorktreeGroup(
      projectId: session.projectId,
      worktreePath: worktreePath,
      label: session.branch ?? worktreePath.split('/').last,
    );
  }
  // Reveal the session's tab in the now-active group. Never [addMember], so a
  // worktree group you were looking at is never converted by a click.
  ref.read(workspaceControllerProvider.notifier).revealSession(id);
}

/// Close the active split's active tab without touching its session (the
/// keyboard "Close tab" and the tab-strip ✕). Closing the last tab collapses
/// the split, or resets the sole split to an empty starter tab.
void closeActiveTab(WidgetRef ref) {
  final state = ref.read(workspaceControllerProvider);
  final tab = activeTab(state);
  if (tab == null) return;
  closeTabAndArchive(ref, state.activeSplitId, tab.id, tab.sessionId);
}

/// Close [tabId] in [splitId] and, when its session is no longer shown in any
/// other tab, archive it (SPEC-29). Archiving is soft + recoverable: the server
/// drops it from the active `sessions.snapshot` so the sidebar list updates,
/// while the transcript + resume handle are kept. Shared by the tab close (X)
/// button and the close-tab shortcut so both behave identically. A tab with no
/// session (empty starter) just closes.
void closeTabAndArchive(
  WidgetRef ref,
  String splitId,
  String tabId,
  String? sessionId,
) {
  final workspace = ref.read(workspaceControllerProvider.notifier);
  workspace.closeTab(splitId, tabId);
  if (sessionId == null || workspace.isSessionBound(sessionId)) return;
  // A never-started draft has no history worth preserving — archiving it would
  // leave an empty, permanently-persisted entry in the Archived list. Just let
  // closeTab drop it.
  if (ref.read(sessionsProvider).byId(sessionId)?.pending ?? false) return;
  // Fire-and-forget: the sidebar reconciles from the fresh server snapshot, so
  // a failed archive is non-fatal — the session simply stays/reappears there.
  unawaited(
    ref
        .read(storeControllerProvider.notifier)
        .archiveSession(sessionId)
        .catchError((_) {}),
  );
}

/// Close the whole active split (the keyboard "Close split"). No-op when it is
/// the only split.
void closeActiveSplit(WidgetRef ref) {
  ref.read(workspaceControllerProvider.notifier).closeActiveSplit();
}

/// Select a worktree from the sidebar (SPEC-30 decision 15): activate that
/// worktree's group, minting it when it does not exist yet. An empty scope
/// seeds the placeholder tab with [worktree] so the pane renders the in-pane
/// starter (decision 20) rather than the no-worktree placeholder.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  final groups = ref.read(groupsControllerProvider.notifier);
  groups.openWorktreeGroup(
    projectId: worktree.projectId,
    worktreePath: worktree.path,
    label: worktree.branch ?? worktree.path.split('/').last,
  );
  final active = ref.read(activeGroupProvider);
  if (ref.read(groupMembersProvider(active.id)).isEmpty) {
    ref.read(workspaceControllerProvider.notifier).revealWorktree(worktree);
  }
}
