/**
 * RepoService: builds the repo-centric home-screen snapshot (git/gh
 * enrichment) for a set of projects.
 *
 * Extracted from {@link SessionManager} (SPEC-19, localizing SPEC-17 P3). The
 * git/branch/worktree reads and the `gh` open-PR lookup fan out concurrently,
 * but bounded (#66): a large install (many repos × worktrees) must not spawn
 * hundreds of git/gh child processes at once (FD/process-limit exhaustion, gh
 * network storm). Callers should treat this as an occasional (connect / spawn
 * / refresh) operation, not per-event.
 */

import type { ProjectDTO, RepoDTO, WorktreeDTO } from "./protocol.js";
import type { Session } from "./session.js";
import {
  isGitRepo,
  detectDefaultBranch,
  detectCurrentBranch,
  listWorktrees,
  diffStat,
  findOpenPr,
  uncommittedFileCount,
  commitsAhead,
  commitsBehind,
} from "./git.js";
import { mapLimit } from "./concurrency.js";

/**
 * Concurrency caps for the repo snapshot fan-out. These bound how many git/gh
 * child processes run at once so a large install (many repos/worktrees) can't
 * exhaust file-descriptor/process limits or storm GitHub with `gh` calls. The
 * git caps nest (projects × worktrees), so keep their product modest; the PR
 * lookups are flattened across all repos, so PR_CONCURRENCY is a true global
 * bound on concurrent `gh` invocations.
 */
const PROJECT_CONCURRENCY = 4;
const WORKTREE_CONCURRENCY = 6;
const PR_CONCURRENCY = 6;

/**
 * Repo-centric snapshot for the home screen: each project enriched with its
 * default/current branch and worktrees (diff stats, open PR, running
 * sessions). Shells out to git/gh per worktree — projects and worktrees are
 * processed in parallel (bounded) so the snapshot cost is roughly the slowest
 * single repo, not the sum of all of them. Callers should still treat this as
 * an occasional (connect / spawn / refresh) operation, not per-event.
 *
 * `includePrs` gates the open-PR lookup. The diff +/- numbers are pure local
 * git and instant; the PR lookup shells out to `gh` (network, seconds). Pass
 * `false` to get the fast git-only snapshot, then call {@link enrichPrs} on the
 * result to add PR info without redoing the git work — so the numbers never
 * wait on the network.
 */
export async function listRepos(
  projects: ProjectDTO[],
  sessions: Session[],
  includePrs: boolean,
): Promise<RepoDTO[]> {
  // Bounded fan-out across projects (SPEC-17 P3 × #66 concurrency cap).
  const repos = await mapLimit(projects, PROJECT_CONCURRENCY, (p) => repoSnapshot(p, sessions));
  return includePrs ? enrichPrs(repos) : repos;
}

/**
 * Git-only snapshot of one project (no `gh`/network). Per-worktree diff stats
 * are read in parallel but bounded ({@link WORKTREE_CONCURRENCY}).
 */
async function repoSnapshot(dto: ProjectDTO, sessions: Session[]): Promise<RepoDTO> {
  const repoPath = dto.path;
  const gitRepo = await isGitRepo(repoPath);
  // Branch detection + worktree enumeration are independent reads — run
  // them concurrently rather than in a serial chain.
  const [defaultBranch, currentBranch, entries] = gitRepo
    ? await Promise.all([
        detectDefaultBranch(repoPath),
        detectCurrentBranch(repoPath),
        listWorktrees(repoPath),
      ])
    : [null, null, [] as Awaited<ReturnType<typeof listWorktrees>>];

  // Group this project's STARTED sessions by the worktree path they run
  // in. Pending drafts (no worktree yet) are surfaced separately by the UI.
  const sessionsByPath = new Map<string, string[]>();
  for (const s of sessions) {
    if (s.projectId !== dto.id || s.pending) continue;
    const key = s.worktreePath ?? repoPath;
    const list = sessionsByPath.get(key) ?? [];
    list.push(s.id);
    sessionsByPath.set(key, list);
  }

  const worktrees: WorktreeDTO[] = await mapLimit(entries, WORKTREE_CONCURRENCY, async (e) => {
    // Run the per-worktree git probes sequentially so they add no extra
    // parallel fan-out on top of WORKTREE_CONCURRENCY: at most one of these
    // helpers runs at a time per worktree (diffStat's own internal parallelism
    // is unchanged), keeping concurrent git subprocesses within budget.
    const stat = await diffStat(e.path, defaultBranch);
    const uncommittedFiles = await uncommittedFileCount(e.path);
    const aheadCount = await commitsAhead(e.path, defaultBranch);
    const behindCount = await commitsBehind(e.path);
    return {
      id: e.path,
      path: e.path,
      branch: e.branch,
      isPrimary: e.isPrimary,
      insertions: stat.insertions,
      deletions: stat.deletions,
      filesChanged: stat.filesChanged,
      uncommittedFiles,
      aheadCount,
      behindCount,
      committedAt: e.committedAt,
      pr: null,
      sessionIds: sessionsByPath.get(e.path) ?? [],
    };
  });

  return {
    id: dto.id,
    name: dto.name,
    path: repoPath,
    pinned: dto.pinned,
    lastActivityAt: dto.lastActivityAt,
    isGitRepo: gitRepo,
    defaultBranch,
    currentBranch,
    worktrees,
  };
}

/**
 * Add open-PR info (via `gh`, network) to a git-only snapshot from
 * {@link listRepos}. Returns new objects — the input is not mutated — so the
 * caller can keep the fast snapshot around while this one is in flight. The
 * `gh` lookups are flattened across all repos and run through a single bounded
 * pool ({@link PR_CONCURRENCY}), so a many-worktree install can't launch
 * hundreds of concurrent `gh` processes / network calls.
 */
export async function enrichPrs(repos: RepoDTO[]): Promise<RepoDTO[]> {
  // Clone up front so the input snapshot is never mutated.
  const out = repos.map((repo) => ({
    ...repo,
    worktrees: repo.worktrees.map((w) => ({ ...w })),
  }));
  // Flatten the eligible (secondary, branched) worktrees so concurrency is
  // bounded globally rather than per-repo.
  const tasks: Array<{ ri: number; wi: number; repoPath: string; branch: string }> = [];
  out.forEach((repo, ri) =>
    repo.worktrees.forEach((w, wi) => {
      if (w.branch && !w.isPrimary) tasks.push({ ri, wi, repoPath: repo.path, branch: w.branch });
    }),
  );
  const prs = await mapLimit(tasks, PR_CONCURRENCY, (t) => findOpenPr(t.repoPath, t.branch));
  tasks.forEach((t, i) => {
    out[t.ri].worktrees[t.wi].pr = prs[i];
  });
  return out;
}
