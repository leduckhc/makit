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
import 'desktop_group_reconcile.dart' show closeGroupsForDeletedWorktrees;
import 'starter_picks.dart';

/// Prefix of every starter-scoped draft key. The key is
/// `starter:<projectId>:<worktreePath>` — must match `WorktreeStarter._draftKey`.
///
/// The project id is in the key because the prune has to be guarded **per repo**
/// (see below), and a worktree path alone cannot say which repo owns it: a linked
/// worktree usually lives nowhere near its repo's directory.
const String kStarterKeyPrefix = 'starter:';

/// The `(projectId, worktreePath)` a starter key names, or null when [key] is
/// not a starter key (a live session's draft is keyed by session id).
({String projectId, String path})? parseStarterKey(String key) {
  if (!key.startsWith(kStarterKeyPrefix)) return null;
  final rest = key.substring(kStarterKeyPrefix.length);
  final colon = rest.indexOf(':');
  if (colon <= 0 || colon == rest.length - 1) return null;
  // First colon only: a project id has none, a POSIX path may.
  return (projectId: rest.substring(0, colon), path: rest.substring(colon + 1));
}

/// Drop the starter draft, picks and staged images of every worktree [repos] no
/// longer lists.
///
/// Guarded **per repo**, exactly like [closeGroupsForDeletedWorktrees]: a repo
/// missing from the snapshot is unknown (not gone), and a repo reporting no
/// worktrees is either mid-refresh or not a git repo at all — `repo_service.ts`
/// hands back `worktrees: []` whenever `isGitRepo` is false. An earlier version
/// bailed out of the whole pass when *any* repo looked unpopulated, which meant a
/// single non-git project silently disabled pruning for everything.
///
/// Live-session keys are untouched — they are not `starter:` keys.
void pruneStarterDrafts(Ref ref, ReposState repos) {
  if (repos.repos.isEmpty) return;

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
    final parsed = parseStarterKey(key);
    if (parsed == null) continue;
    final repo = repos.byId(parsed.projectId);
    if (repo == null) continue; // not loaded yet — say nothing
    if (repo.worktrees.isEmpty) continue; // mid-refresh, or not a git repo
    if (repo.worktrees.any((w) => w.path == parsed.path)) continue;
    drafts.set(key, '');
    picks.clear(key);
    attachments.clear(key);
  }
}
