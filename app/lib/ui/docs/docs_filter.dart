/// SPEC-doc-preview — the pure filter + grouping behind the global Docs screen.
///
/// Pure functions and value types only: no widgets, no provider reads, so the
/// screen's visible-set logic is testable without a container (the same split
/// as `ports_filter.dart`). Grouping reads [ReposState] to resolve each doc's
/// owning worktree; a doc whose worktree is not active is dropped (D6 — a
/// removed worktree's files are gone, so the row could only be a dead link).
library;

import '../../store/docs.dart';
import '../../store/store.dart';

/// The filter chips the screen offers (mockup Card 2): All / Mockups / Specs /
/// Changed.
enum DocsFilter { all, mockups, specs, changed }

bool _matchesFilter(DocInfo d, DocsFilter filter) => switch (filter) {
  DocsFilter.all => true,
  DocsFilter.mockups => d.relPath.startsWith('mockups/'),
  DocsFilter.specs => d.relPath.startsWith('docs/'),
  DocsFilter.changed => d.changed == true,
};

/// Whether [d] matches a free-text [query], over title AND path.
///
/// The one definition: the Docs screen and the desktop popover both search, and
/// two copies of "contains, case-insensitive, title or relPath" would drift.
bool docMatchesQuery(DocInfo d, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return d.title.toLowerCase().contains(q) ||
      d.relPath.toLowerCase().contains(q);
}

/// Docs passing [filter] and (when non-empty) [query]. Search matches the title
/// OR the path, case-insensitively — titles AND paths, never doc bodies (P1
/// does not do full-text). A null snapshot yields no docs (the screen shows a
/// waiting/empty state, never a fabricated list).
List<DocInfo> filterDocs(
  DocsSnapshot? snapshot,
  DocsFilter filter, {
  String query = '',
}) {
  if (snapshot == null) return const [];
  return snapshot.docs
      .where((d) => _matchesFilter(d, filter) && docMatchesQuery(d, query))
      .toList();
}

/// Count for each filter, independent of the active one — so a chip can show
/// "Mockups 27" while "All" is selected (mockup Card 2 badges).
Map<DocsFilter, int> docsFilterCounts(DocsSnapshot? snapshot) => {
  for (final f in DocsFilter.values) f: filterDocs(snapshot, f).length,
};

/// One worktree's docs within a repo group.
class WorktreeDocGroup {
  const WorktreeDocGroup({
    required this.worktreePath,
    required this.branch,
    required this.docs,
  });

  final String worktreePath;
  final String branch;
  final List<DocInfo> docs;
}

/// One repo's worktrees (each with its docs), in first-seen order.
class RepoDocGroup {
  const RepoDocGroup({
    required this.repoId,
    required this.repoName,
    required this.worktrees,
  });

  final String repoId;
  final String repoName;
  final List<WorktreeDocGroup> worktrees;
}

/// The screen's grouped view: docs under repo → worktree, mtime-descending
/// within each worktree (D5).
class DocsGrouping {
  const DocsGrouping({required this.repos});
  final List<RepoDocGroup> repos;
  bool get isEmpty => repos.isEmpty;
}

/// Groups [docs] repo → worktree in first-seen order, mtime-descending inside
/// each worktree. A doc whose [DocInfo.worktreePath] matches no active worktree
/// is dropped entirely (D6): unlike a port, a removed worktree's file is gone.
DocsGrouping groupDocsByRepoWorktree(List<DocInfo> docs, ReposState repos) {
  final repoOrder = <String>[];
  final repoGroups = <String, RepoDocGroup>{};
  final worktreeGroups = <String, Map<String, WorktreeDocGroup>>{};

  for (final doc in docs) {
    final located = repos.locateWorktree(doc.worktreePath);
    if (located == null) continue; // D6: not an active worktree — drop.
    final repo = located.repo;
    final worktree = located.worktree;
    if (!repoGroups.containsKey(repo.id)) {
      repoOrder.add(repo.id);
      repoGroups[repo.id] = RepoDocGroup(
        repoId: repo.id,
        repoName: repo.name,
        worktrees: [],
      );
      worktreeGroups[repo.id] = {};
    }
    final wtGroups = worktreeGroups[repo.id]!;
    if (!wtGroups.containsKey(worktree.path)) {
      final group = WorktreeDocGroup(
        worktreePath: worktree.path,
        branch: worktree.branch ?? 'detached',
        docs: [],
      );
      wtGroups[worktree.path] = group;
      repoGroups[repo.id]!.worktrees.add(group);
    }
    wtGroups[worktree.path]!.docs.add(doc);
  }

  // mtime-descending inside each worktree (D5) — the doc you want is the one
  // you just made.
  for (final repo in repoGroups.values) {
    for (final wt in repo.worktrees) {
      wt.docs.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    }
  }

  return DocsGrouping(repos: [for (final id in repoOrder) repoGroups[id]!]);
}
