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

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/composer_attachments.dart';
import '../../store/store.dart';
import '../../ui/composer/composer_draft.dart';
import 'desktop_group_reconcile.dart' show closeGroupsForDeletedWorktrees;
import 'starter_picks.dart';

/// Prefix of every starter-scoped draft key.
///
/// The key is `starter:` followed by a JSON `[projectId, worktreePath]` pair —
/// build it with [starterDraftKey] and read it back with [parseStarterKey], never
/// by hand.
///
/// The project id is in the key because the prune has to be guarded **per repo**
/// (see below), and a worktree path alone cannot say which repo owns it: a linked
/// worktree usually lives nowhere near its repo's directory.
///
/// Two components in one string need an encoding, and this one is
/// **self-describing** rather than delimiter-based, because both earlier attempts
/// assumed a character could not occur in a component and were wrong:
///
/// - `:` — legal in a POSIX path *and* in an id (`project-store.ts` persists any
///   string), so with projects `a` and `a:b`, `a:b`'s key read back as project `a`
///   with a path `a` does not list. The prune then deleted a **live draft**.
/// - `\u0000` — impossible in a path, but not in an id, so the same collision
///   survived in a narrower form.
///
/// A lossy key here costs the user typed text and staged images, so the codec is
/// total for every input (including empty components) and is proven so by the
/// round-trip group in `starter_prune_test.dart`. Keys are in-memory only, so
/// their length and prettiness do not matter.
const String kStarterKeyPrefix = 'starter:';

/// The draft/picks/attachments key for a starter pane on [worktreePath] in
/// [projectId].
String starterDraftKey(String projectId, String worktreePath) =>
    '$kStarterKeyPrefix${jsonEncode([projectId, worktreePath])}';

/// The `(projectId, worktreePath)` a starter key names, or null when [key] is not
/// a key [starterDraftKey] produced — a live session's draft (keyed by session
/// id), or anything malformed. Never throws.
({String projectId, String path})? parseStarterKey(String key) {
  if (!key.startsWith(kStarterKeyPrefix)) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(key.substring(kStarterKeyPrefix.length));
  } on FormatException {
    return null;
  }
  if (decoded is! List || decoded.length != 2) return null;
  final projectId = decoded[0];
  final path = decoded[1];
  if (projectId is! String || path is! String) return null;
  return (projectId: projectId, path: path);
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
