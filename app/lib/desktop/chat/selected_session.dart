import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../store/store.dart';
import 'panes/pane_tree_controller.dart';
import 'selected_worktree.dart';

export 'selected_worktree.dart';

/// The session currently shown in the desktop chat pane, or `null` when none
/// is selected (empty state). Desktop is a two-pane master/detail layout, so —
/// unlike the mobile push-navigation flow — the "current session" is app state,
/// not a route.
final selectedSessionProvider = StateProvider<String?>((ref) => null);

/// Convenience for widgets/tests that only need to change the selection.
@visibleForTesting
void selectSession(WidgetRef ref, String? sessionId) =>
    ref.read(selectedSessionProvider.notifier).state = sessionId;

/// The worktree currently shown in the pane area, or null (empty placeholder).
/// A read-only mirror of the pane controller's current tree, kept for the
/// sidebar highlight; every writer routes through [PaneTreeController] so the
/// highlight can never desync from the view.
final selectedWorktreeProvider = Provider<SelectedWorktree?>(
  (ref) => ref.watch(paneTreeControllerProvider).current?.worktree,
);

/// Close the pane hosting [leafId] without touching its session: the session
/// keeps running and stays in the sidebar, only the pane is removed. When it
/// was the last pane in the tree the view drops to the empty placeholder and
/// the sidebar highlight is reset so it matches the empty pane area.
void closePane(WidgetRef ref, String leafId) {
  final controller = ref.read(paneTreeControllerProvider.notifier);
  controller.setActive(leafId);
  controller.closeActive();
  if (controller.current == null) {
    ref.read(selectedSessionProvider.notifier).state = null;
  }
}

/// Select a session: switch the pane view to that session's worktree tree
/// (seeding it if absent) and bind the session into that tree's active leaf
/// (decision 4). [selectedSessionProvider] stays in sync for the sidebar
/// highlight and mobile.
void selectSessionExclusive(WidgetRef ref, String id) {
  ref.read(selectedSessionProvider.notifier).state = id;
  final controller = ref.read(paneTreeControllerProvider.notifier);
  final session = ref.read(sessionsProvider).byId(id);
  final path = session?.worktreePath;
  if (session != null && path != null) {
    controller.bindActiveSession(
      id,
      SelectedWorktree(
        projectId: session.projectId,
        path: path,
        branch: session.branch,
      ),
    );
    return;
  }
  if (session != null) {
    // A still-pending draft has no real worktree on disk yet: bind it into its
    // own virtual, session-scoped tree so the pane shows the harness picker.
    // The real worktree materializes — and the pane switches to the transcript
    // — on the first message.
    controller.bindActiveSession(id, draftWorktreeFor(session.projectId, id));
    return;
  }
  // The session is not in the store yet: bind it into the current tree when one
  // is selected, otherwise leave the highlight set with no pane binding (mobile
  // has no pane tree).
  final current = controller.current;
  if (current != null) controller.bindActiveSession(id, current.worktree);
}

/// Open a freshly spawned pending draft ([sessionId]) in its own virtual pane
/// tree and select it (the sidebar + button). Unlike [selectSessionExclusive]
/// this does not read the session from the store, so it works immediately after
/// `spawnSession` returns — before the server's sessions.snapshot arrives.
void openDraftSession(WidgetRef ref, String projectId, String sessionId) {
  ref.read(selectedSessionProvider.notifier).state = sessionId;
  ref
      .read(paneTreeControllerProvider.notifier)
      .bindActiveSession(sessionId, draftWorktreeFor(projectId, sessionId));
}

/// Select a sessionless worktree: swap the pane view to that worktree's tree
/// (seeding a single empty starter pane the first time). The session highlight
/// is cleared; [selectedWorktreeProvider] follows the controller automatically.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  ref.read(selectedSessionProvider.notifier).state = null;
  ref.read(paneTreeControllerProvider.notifier).selectWorktree(worktree);
}
