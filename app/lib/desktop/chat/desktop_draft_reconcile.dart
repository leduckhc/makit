import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'panes/pane_tree_controller.dart';
import 'selected_worktree.dart';

/// Keeps the pane workspace's virtual draft trees (`draft:<sessionId>`, opened
/// by the sidebar + button) in sync with the live session list:
///
/// - once a draft materializes on disk (its session gains a `worktreePath`),
///   its tree is migrated onto the real worktree path so the pane keeps its
///   layout and the title strip shows the real branch instead of "New
///   worktree";
/// - if a draft's session disappears (abandoned before its first message, or a
///   persisted draft tree whose session is gone after a restart), its stale
///   `draft:` tree is pruned so the persisted workspace can't grow unbounded.
///
/// Watched (kept alive) by the desktop app shell, mirroring
/// [desktopAutoSelectSessionProvider].
final desktopDraftReconcileProvider = Provider<void>((ref) {
  void reconcile(SessionsState sessions) {
    // Skip the empty startup snapshot: the shell activates this provider before
    // the connection delivers the first sessions.snapshot, so an empty list
    // here is "not loaded yet", not "no sessions". Pruning against it would
    // permanently drop restored draft trees whose sessions haven't arrived.
    // The listen below re-runs once the authoritative (non-empty) snapshot
    // lands. Mirrors desktopAutoSelectSessionProvider's empty-list guard.
    if (sessions.sessions.isEmpty) return;
    final controller = ref.read(paneTreeControllerProvider.notifier);
    for (final sid in controller.draftTreeSessionIds()) {
      final session = sessions.byId(sid);
      final path = session?.worktreePath;
      if (session == null) {
        controller.dropDraftTree(sid);
      } else if (path != null) {
        controller.materializeDraft(
          sid,
          SelectedWorktree(
            projectId: session.projectId,
            path: path,
            branch: session.branch,
          ),
        );
      }
    }
  }

  ref.listen(sessionsProvider, (_, next) => reconcile(next));
  // Reconcile once against the current snapshot for drafts restored from prefs.
  Future.microtask(() => reconcile(ref.read(sessionsProvider)));
});
