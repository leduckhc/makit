import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'panes/pane_tree_controller.dart';

/// The session currently shown in the desktop chat pane, or `null` when none
/// is selected (empty state). Desktop is a two-pane master/detail layout, so —
/// unlike the mobile push-navigation flow — the "current session" is app state,
/// not a route.
final selectedSessionProvider = StateProvider<String?>((ref) => null);

/// Convenience for widgets/tests that only need to change the selection.
@visibleForTesting
void selectSession(WidgetRef ref, String? sessionId) =>
    ref.read(selectedSessionProvider.notifier).state = sessionId;

/// A sessionless worktree the user picked in the sidebar. Puts the pane in
/// "start a session here" mode (harness cards); the session is spawned in this
/// existing worktree on the first message. Mutually exclusive with
/// [selectedSessionProvider].
@immutable
class SelectedWorktree {
  const SelectedWorktree({
    required this.projectId,
    required this.path,
    required this.branch,
  });

  final String projectId;
  final String path;
  final String? branch;

  @override
  bool operator ==(Object other) =>
      other is SelectedWorktree &&
      other.projectId == projectId &&
      other.path == path &&
      other.branch == branch;

  @override
  int get hashCode => Object.hash(projectId, path, branch);
}

/// The sessionless worktree currently shown in the pane, or null.
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

/// Select a sessionless worktree, clearing any selected session. The active
/// pane's bound session is cleared too so it falls back to the worktree draft.
void selectWorktree(WidgetRef ref, SelectedWorktree worktree) {
  ref.read(selectedSessionProvider.notifier).state = null;
  ref.read(selectedWorktreeProvider.notifier).state = worktree;
  ref.read(paneTreeControllerProvider.notifier).clearActiveSession();
}
