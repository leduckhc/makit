/// Pruning the starter pane's key spaces (SPEC-45 D10).
///
/// A starter's draft text, harness/model picks and staged images are held in
/// app-wide, non-`autoDispose` providers keyed `starter:<worktreePath>` — that
/// is what makes them survive the tab switch that recreates the pane. Nothing
/// dropped them, though: a worktree wrapped up or discarded left its draft (and,
/// worse, the megabytes of a staged screenshot) held for the life of the process.
///
/// A **closed tab is not** the trigger: reopening it is expected to find the
/// draft still there (D1). The trigger is the worktree itself disappearing from
/// the repo snapshot, which is the same evidence
/// `closeGroupsForDeletedWorktrees` acts on — and it is guarded the same way,
/// because an empty list means "not loaded yet", never "all gone".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/composer_attachments.dart';
import '../../store/store.dart';
import '../../ui/composer/composer_draft.dart';
import 'starter_picks.dart';

/// Prefix of every starter-scoped draft key. Must match `WorktreeStarter`.
const String kStarterKeyPrefix = 'starter:';

/// Drop the starter draft, picks and staged images of every worktree [repos] no
/// longer lists.
///
/// Says nothing (prunes nothing) when the snapshot cannot be trusted: an empty
/// repo list is "still connecting", and a repo with an empty worktree list is
/// mid-refresh. Live-session keys are untouched — they are not `starter:` keys.
void pruneStarterDrafts(Ref ref, ReposState repos) {
  if (repos.repos.isEmpty) return;
  // One unpopulated repo is enough to make the union unreliable, and a git repo
  // always has at least its primary worktree.
  if (repos.repos.any((r) => r.worktrees.isEmpty)) return;
  final live = {
    for (final repo in repos.repos)
      for (final wt in repo.worktrees) wt.path,
  };

  final drafts = ref.read(composerDraftsProvider.notifier);
  final picks = ref.read(starterPicksProvider.notifier);
  final attachments = ref.read(composerAttachmentsProvider.notifier);

  // Union of the three key spaces: a pane may have staged an image without
  // typing, or typed without staging.
  final keys = <String>{
    ...ref.read(composerDraftsProvider).keys,
    ...ref.read(starterPicksProvider).keys,
    ...ref.read(composerAttachmentsProvider).keys,
  };
  for (final key in keys) {
    if (!key.startsWith(kStarterKeyPrefix)) continue;
    final path = key.substring(kStarterKeyPrefix.length);
    if (live.contains(path)) continue;
    drafts.set(key, '');
    picks.clear(key);
    attachments.clear(key);
  }
}
