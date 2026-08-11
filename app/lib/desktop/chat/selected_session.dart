import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../store/models.dart';
import '../../store/store.dart';
import 'groups/group.dart';
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
  closeTabAndSession(ref, state.activeSplitId, tab.id, tab.sessionId);
}

/// Close [tabId] in [splitId] and then dispose of its session **according to the
/// active group's kind** (SPEC-30 decision 7):
///
/// * **worktree group** → close it (SPEC-29). Membership is derived, so the
///   only way to take a session off that canvas is to end it.
/// * **board** → **unpin** it. The list is the user's to edit and the agent
///   keeps running; closing here would destroy work while tidying a view.
///
/// The choice lives here, in the one shared close path, rather than at each
/// affordance — so the tab ✕ and the `⌘⇧W` shortcut ([closeActiveTab]) cannot
/// drift apart. **No call site may special-case it.** A tab with no session (an
/// empty starter) just closes.
void closeTabAndSession(
  WidgetRef ref,
  String splitId,
  String tabId,
  String? sessionId,
) {
  final workspace = ref.read(workspaceControllerProvider.notifier);
  final group = ref.read(activeGroupProvider);
  // Close the tab first, always: it is the action the user took, and it is the
  // only thing that handles an empty tab or a session that is not a member.
  // `removeMember` then drops any remaining tabs for that session, which is a
  // second state update — but persistence is coalesced per microtask, so it
  // costs no extra write.
  workspace.closeTab(splitId, tabId);
  if (sessionId == null) return;
  if (group.kind == GroupKind.board) {
    // Unpin even if another tab still shows it: membership is the board's
    // contract, and the user just said "not on this board".
    ref
        .read(groupsControllerProvider.notifier)
        .removeMember(group.id, sessionId);
    return;
  }
  if (workspace.isSessionBound(sessionId)) return;
  // A never-started draft has no history worth preserving — closing it would
  // leave an empty, permanently-persisted entry in the Closed list. Just let
  // closeTab drop it.
  if (ref.read(sessionsProvider).byId(sessionId)?.pending ?? false) return;
  // Fire-and-forget: the sidebar reconciles from the fresh server snapshot, so
  // a failed close is non-fatal — the session simply stays/reappears there.
  unawaited(
    ref
        .read(storeControllerProvider.notifier)
        .closeSession(sessionId)
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
///
/// SPEC-51: with [previewGroupsPreference] on, a plain click mints the group as
/// the **preview** one — disposable, replaced by the next branch you click, so
/// browsing twenty worktrees costs one tab.
///
/// Promotion (decision 4) is **clicking the branch you are already previewing**:
/// the second click says "I'm staying here", and the group stops being
/// replaceable. Timing-free on purpose — an `onDoubleTap` on the sidebar row
/// would defer every single click to the double-tap timer (see `_selection` in
/// `desktop_sidebar.dart`), and a wall-clock double-click window in the widget
/// would make the gesture unreliable on a trackpad and untestable without a
/// fake clock. A fast double click satisfies this rule; so does a slow one.
///
/// [keep] forces promotion for callers that *are* an explicit keep gesture (the
/// group tab's "Keep this view"). Nothing else promotes: decision 4 rejects
/// heuristics like "you sent a message here".
void selectWorktree(
  WidgetRef ref,
  SelectedWorktree worktree, {
  bool keep = false,
}) {
  final groups = ref.read(groupsControllerProvider.notifier);
  final promote = keep || _isPreviewingOnScreen(ref, worktree);
  final id = groups.openWorktreeGroup(
    projectId: worktree.projectId,
    worktreePath: worktree.path,
    label: worktree.branch ?? worktree.path.split('/').last,
    preview: !promote && ref.read(previewGroupsEnabledProvider),
  );
  if (promote) groups.keepGroup(id);
  final active = ref.read(activeGroupProvider);
  if (ref.read(groupMembersProvider(active.id)).isEmpty) {
    ref.read(workspaceControllerProvider.notifier).revealWorktree(worktree);
  }
}

/// Whether [worktree]'s group is the preview group **and** the one on screen —
/// i.e. this click is the second one on the branch the user is already looking
/// at. Requiring *active* is what keeps it a deliberate repeat: clicking a
/// preview group that sits in the background is still navigation.
bool _isPreviewingOnScreen(WidgetRef ref, SelectedWorktree worktree) {
  final state = ref.read(groupsControllerProvider);
  final preview = state.previewGroup;
  return preview != null &&
      preview.id == state.activeGroupId &&
      preview.isScopedTo(
        projectId: worktree.projectId,
        worktreePath: worktree.path,
      );
}
