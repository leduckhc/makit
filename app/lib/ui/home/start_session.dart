import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import 'new_session_sheet.dart';
import 'repo_chips.dart';
import '../../app/routes.dart';

/// In-flight guard: a second entry while a flow is running returns silently.
///
/// The `+` awaits `fetchAgents` before its sheet appears, and an impatient second
/// tap in that window would open a second sheet — then fork a second worktree and
/// spawn twice. Library-level rather than per-widget because the sheet is modal:
/// only one flow can be in progress at a time anyway.
var _startingSession = false;

/// Clear the guard between tests. A test that ends with the sheet still open
/// leaves the flow suspended and the guard set, which would disable the flow for
/// every test after it.
@visibleForTesting
void resetStartSessionFlowGuard() => _startingSession = false;

/// Configure and start a session in [repo], then navigate to it.
///
/// One door for every new session: the sheet always opens, then the chosen
/// worktree is resolved — created for a new branch or a PR — before the session
/// spawns into it.
///
/// [worktree] pre-targets an existing worktree, which is what a worktree row's
/// `+` passes: the branch is already decided, so the sheet opens on it and the
/// user only picks the harness.
Future<void> startSessionFlow(
  BuildContext context,
  WidgetRef ref,
  RepoInfo repo, {
  Worktree? worktree,
}) async {
  if (_startingSession) return;
  _startingSession = true;
  try {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    final branches = branchOptionsForRepo(repo);
    final worktrees = sortWorktreesForDisplay(repo.worktrees);
    // A worktree created for this spawn is removed if the spawn then fails, so
    // a retry doesn't orphan it.
    String? createdWorktree;
    try {
      final agents = await store.fetchAgents();
      final selectable = agents.where((a) => a.available).toList();
      // Open PRs power the "From PR" worktree source; best-effort (an empty or
      // failed lookup just hides that option). Bounded so a slow `gh` can't
      // stall opening the sheet. Skipped entirely when the caller already named
      // a worktree — that flow can't reach the PR option.
      List<OpenPr> openPrs = const [];
      if (worktree == null) {
        try {
          openPrs = await store
              .listOpenPrs(repo.id)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => const <OpenPr>[],
              );
        } catch (_) {
          openPrs = const [];
        }
      }

      if (!context.mounted) return;
      final choice = await showModalBottomSheet<NewSessionChoice>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (ctx) => NewSessionSheet(
          agents: selectable,
          branches: branches,
          worktrees: worktrees,
          openPrs: openPrs,
          initialBranch:
              worktree?.branch ?? (branches.isEmpty ? null : branches.first),
          initialWorktreePath: worktree?.path,
        ),
      );
      if (choice == null) return;

      String? worktreePath;
      String? branch;
      switch (choice.source) {
        case WorktreeSource.existing:
          worktreePath = choice.worktreePath;
          for (final w in worktrees) {
            if (w.path == worktreePath) branch = w.branch;
          }
        case WorktreeSource.newBranch:
          final wt = await store.createWorktree(
            repo.id,
            baseBranch:
                choice.baseBranch ?? (branches.isEmpty ? null : branches.first),
          );
          worktreePath = wt.path;
          branch = wt.branch;
          createdWorktree = wt.path;
        case WorktreeSource.fromPr:
          if (choice.prNumber == null) return;
          final wt = await store.createWorktreeFromPr(
            repo.id,
            choice.prNumber!,
          );
          worktreePath = wt.path;
          branch = wt.branch;
          createdWorktree = wt.path;
      }

      final newId = await store.spawnSession(
        repo.id,
        agent: choice.agent,
        worktreePath: worktreePath,
        branch: branch,
        configOptions: choice.configOptions.isEmpty
            ? null
            : choice.configOptions,
      );
      createdWorktree = null; // spawned — the worktree now hosts a session.
      if (!context.mounted) return;
      context.go(routeForSession(newId));
    } catch (e) {
      if (createdWorktree != null) {
        await store.removeWorktree(repo.id, createdWorktree).catchError((_) {});
      }
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not start session: $e')),
        );
      }
    }
  } finally {
    _startingSession = false;
  }
}
