import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

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

/// The sessionless worktree currently shown in the active pane, or null. Used
/// for the sidebar highlight; each pane also binds its own worktree (see
/// [PaneLeaf.worktree]) so splits never rely on this single global slot.
final selectedWorktreeProvider = StateProvider<SelectedWorktree?>(
  (ref) => null,
);

/// Select a session, clearing any selected sessionless worktree. Also binds
/// the session to the active split pane so a sidebar pick lands in the focused
/// pane; the global providers stay in sync for the sidebar highlight and
/// empty-state / auto-select logic.
void selectSessionExclusive(WidgetRef ref, String id) {
  ref.read(selectedWorktreeProvider.notifier).state = null;
  ref.read(selectedSessionProvider.notifier).state = id;
  ref.read(paneTreeControllerProvider.notifier).bindActiveSession(id);
}

/// Select a sessionless worktree, clearing any selected session. Binds the
/// worktree to the active split pane (so it persists through splits and never
/// relies on the global fallback), and keeps the global provider in sync for
/// the sidebar highlight.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  ref.read(selectedSessionProvider.notifier).state = null;
  ref.read(selectedWorktreeProvider.notifier).state = worktree;
  ref.read(paneTreeControllerProvider.notifier).bindActiveWorktree(worktree);
}
