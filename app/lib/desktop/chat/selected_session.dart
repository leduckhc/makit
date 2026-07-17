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
  // The session has no worktree yet (a still-pending draft) or is not in the
  // store yet: bind it into the current tree when one is selected, otherwise
  // leave the highlight set with no pane binding (mobile has no pane tree).
  final current = controller.current;
  if (current != null) controller.bindActiveSession(id, current.worktree);
}

/// Select a sessionless worktree: swap the pane view to that worktree's tree
/// (seeding a single empty starter pane the first time). The session highlight
/// is cleared; [selectedWorktreeProvider] follows the controller automatically.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  ref.read(selectedSessionProvider.notifier).state = null;
  ref.read(paneTreeControllerProvider.notifier).selectWorktree(worktree);
}
