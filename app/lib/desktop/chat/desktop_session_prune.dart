import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'groups/placement.dart';
import 'panes/workspace_controller.dart';
import 'selected_worktree.dart';

/// Keeps the groups layer honest about what the server still has, on every
/// `sessions.snapshot` and every repo/worktree update:
///
/// * **Boards unpin vanished members** (SPEC-30 decision 6): a session absent
///   from the snapshot is removed from every board's member list, not merely
///   from its tabs. No dead tiles, no restore affordance.
/// * **The active worktree group's canvas follows its derived membership**
///   (decisions 5, 9, 20): a new in-scope session is placed automatically, an
///   out-of-scope tab is dropped, and an empty scope seeds the in-pane starter
///   — all without switching groups.
/// * **A board's tree** stays curated, but tabs whose session vanished are
///   still closed so no pane renders a dead session.
/// * **A deleted worktree closes its group** (decision 7 tail): when the active
///   group's scope no longer exists among the repo's worktrees, its group is
///   closed and focus falls to the neighbour, mirroring `_focusAfterRemoval`.
final desktopSessionPruneProvider = Provider<void>((ref) {
  void prune(SessionsState next) {
    // Before the first snapshot an empty list means "we don't know yet"
    // (offline, still connecting) — pruning then would wipe a restored layout.
    if (!ref.read(sessionsLoadedProvider)) return;
    final groupsCtrl = ref.read(groupsControllerProvider.notifier);

    // Decision 6: every board drops members the server no longer lists.
    for (final g in ref.read(groupsControllerProvider).groups) {
      if (g.kind != GroupKind.board) continue;
      for (final id in g.members) {
        if (next.byId(id) == null) groupsCtrl.removeMember(g.id, id);
      }
    }

    final workspace = ref.read(workspaceControllerProvider.notifier);
    final active = ref.read(activeGroupProvider);
    if (active.kind == GroupKind.worktree) {
      // The canvas follows derived membership: place newcomers, drop
      // out-of-scope tabs, seed the starter when the scope is empty.
      reconcileInto(
        workspace,
        ref.read(groupMembersProvider(active.id)),
        threshold: ref.read(autoSplitThresholdProvider),
        layoutOverride: active.layoutOverride,
        emptyHint: SelectedWorktree(
          projectId: active.projectId!,
          path: active.worktreePath!,
          branch: active.label,
        ),
      );
    } else {
      // A board's tree is the user's; only close tabs of vanished sessions.
      for (final id in boundSessionIds(ref.read(workspaceControllerProvider))) {
        if (next.byId(id) == null) workspace.unbindSession(id);
      }
    }
  }

  /// Decision 7 tail: a worktree removed from the sidebar takes its group with
  /// it. Detected reactively off the repo list so it needs no hook in the
  /// (UI-owned) delete flow; guarded by the repo being known, so a not-yet-
  /// loaded repo list can never close a group on startup.
  void reconcileWorktrees(ReposState repos) {
    final active = ref.read(activeGroupProvider);
    if (active.kind != GroupKind.worktree) return;
    final repo = repos.byId(active.projectId!);
    if (repo == null) return; // not loaded yet — say nothing
    if (repo.worktrees.any((w) => w.path == active.worktreePath)) return;
    ref.read(groupsControllerProvider.notifier).closeGroup(active.id);
  }

  ref.listen(sessionsProvider, (_, next) => prune(next));
  ref.listen(reposProvider, (_, next) => reconcileWorktrees(next));
  Future.microtask(() {
    prune(ref.read(sessionsProvider));
    reconcileWorktrees(ref.read(reposProvider));
  });
});
