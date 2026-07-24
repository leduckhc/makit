import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
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

/// Reveal [id] (SPEC-28 decision 6): focus the tab already hosting the session
/// anywhere in the tree, or open a new tab for it in the active split. The
/// session's worktree is its own metadata — never stored on the bound tab.
/// [selectedSessionProvider] follows automatically (it mirrors the active tab).
void selectSessionExclusive(WidgetRef ref, String id) {
  ref.read(workspaceControllerProvider.notifier).revealSession(id);
}

/// Close the active split's active tab without touching its session (the
/// keyboard "Close tab" and the tab-strip ✕). Closing the last tab collapses
/// the split, or resets the sole split to an empty starter tab.
void closeActiveTab(WidgetRef ref) {
  final state = ref.read(workspaceControllerProvider);
  final tab = activeTab(state);
  if (tab == null) return;
  ref.read(workspaceControllerProvider.notifier).closeTab(state.activeSplitId, tab.id);
}

/// Close the whole active split (the keyboard "Close split"). No-op when it is
/// the only split.
void closeActiveSplit(WidgetRef ref) {
  ref.read(workspaceControllerProvider.notifier).closeActiveSplit();
}

/// Reveal a freshly spawned pending draft ([sessionId]) as a tab and focus it
/// (the sidebar + button). Unlike [selectSessionExclusive] this is the same
/// reveal path, kept as a named call site so the sidebar reads intently.
void openDraftSession(WidgetRef ref, String sessionId) {
  ref.read(workspaceControllerProvider.notifier).revealSession(sessionId);
}

/// Select a sessionless worktree from the sidebar: open a starter tab hinted
/// with [worktree] in the active split (SPEC-28 — no layout swap). The New
/// session dialog opened from that tab pre-fills with the worktree.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  final state = ref.read(workspaceControllerProvider);
  ref
      .read(workspaceControllerProvider.notifier)
      .openTab(state.activeSplitId, Tab(id: nextNodeId(SplitNodeKind.tab), worktree: worktree));
}
