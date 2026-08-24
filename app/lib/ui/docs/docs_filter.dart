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

/// The filter chips the screen offers (D6): All / This repo / Markdown / Pages
/// / Changed. The kind chips read [DocInfo.kind], never a path — a chip must
/// never be dead in a valid repo. The set mirrors `PortsFilter`.
enum DocsFilter { all, thisRepo, markdown, pages, changed }

/// The set of worktree paths that belong to [repoId], or empty when unknown.
/// *This repo* keeps only docs owned by one of those worktrees (D3), the same
/// rule `filterPorts` applies for its own *This repo* chip.
Set<String> _worktreePathsOf(ReposState repos, String? repoId) {
  if (repoId == null) return const {};
  final repo = repos.byId(repoId);
  if (repo == null) return const {};
  return {for (final w in repo.worktrees) w.path};
}

bool _matchesFilter(DocInfo d, DocsFilter filter, Set<String> thisRepoPaths) =>
    switch (filter) {
      DocsFilter.all => true,
      DocsFilter.thisRepo => thisRepoPaths.contains(d.worktreePath),
      DocsFilter.markdown => d.kind == DocKind.md,
      DocsFilter.pages => d.kind == DocKind.html,
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
  DocsFilter filter,
  ReposState repos, {
  String? repoId,
  String query = '',
}) {
  if (snapshot == null) return const [];
  final thisRepoPaths = _worktreePathsOf(repos, repoId);
  return snapshot.docs
      .where(
        (d) =>
            _matchesFilter(d, filter, thisRepoPaths) &&
            docMatchesQuery(d, query),
      )
      .toList();
}

/// Count for each filter, independent of the active one — so a chip can show
/// "Markdown 27" while "All" is selected. The [repoId] feeds the *This repo*
/// count, which is zero (and its chip hidden) when the board is unscoped.
Map<DocsFilter, int> docsFilterCounts(
  DocsSnapshot? snapshot,
  ReposState repos, {
  String? repoId,
}) => {
  for (final f in DocsFilter.values)
    f: filterDocs(snapshot, f, repos, repoId: repoId).length,
};

/// The [limit] newest docs in [docs], newest first (D5). The board leads with
/// this so recency answers *which* doc, above the grouping that answers
/// *where*. Pure so the screen and its test share one definition.
List<DocInfo> recentDocs(List<DocInfo> docs, {int limit = 5}) {
  final sorted = [...docs]
    ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  return sorted.take(limit).toList();
}

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

/// The id of the repo that owns the newest doc across [grouping], or null when
/// the grouping is empty (D4). Unscoped with more than one repo, only this repo
/// stays expanded; the rest fold. Recency picks the open group, so no
/// `activeRepo` state has to be invented.
String? repoIdOwningNewestDoc(DocsGrouping grouping) {
  String? bestRepoId;
  var bestMtime = -1 << 62;
  for (final repo in grouping.repos) {
    for (final wt in repo.worktrees) {
      // Each worktree's docs are already mtime-descending, so the first is its
      // newest — one read per worktree, not a full scan.
      if (wt.docs.isEmpty) continue;
      final mtime = wt.docs.first.modifiedAt;
      if (mtime > bestMtime) {
        bestMtime = mtime;
        bestRepoId = repo.repoId;
      }
    }
  }
  return bestRepoId;
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
