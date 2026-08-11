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

import type { ProjectDTO, PullRequestDTO, RepoDTO, WorktreeDTO } from "./protocol.js";
import type { Session } from "./session.js";
import type { GithubGateway } from "./github/gateway.js";
import type { RepoSettingsDTO } from "./protocol.js";

/**
 * Supplies one project's settings DTO. Injected rather than reached for: the
 * resolution chain lives in `repo_settings.ts` and the forge decision in the
 * router, and `listRepos` should not know about either.
 */
export type RepoSettingsLookup = (project: ProjectDTO) => RepoSettingsDTO | undefined;
import {
  isGitRepo,
  detectDefaultBranch,
  detectCurrentBranch,
  listWorktrees,
  diffStat,
  fetchOpenPr,
  uncommittedFileCount,
  commitsAhead,
  commitsBehind,
} from "./git.js";
import { mapLimit } from "./concurrency.js";

/**
 * Accessor for the previously-broadcast PR of a worktree, so a failed re-fetch
 * can retain the last-known pill instead of erasing it. Supplied by the caller,
 * which owns the last-broadcast snapshot. Returns null when nothing is known.
 */
export type LastKnownPr = (repoPath: string, branch: string) => PullRequestDTO | null;

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
  gateway: GithubGateway,
  lastKnown: LastKnownPr,
  settingsFor?: RepoSettingsLookup,
): Promise<RepoDTO[]> {
  // Bounded fan-out across projects (SPEC-17 P3 × #66 concurrency cap).
  const repos = await mapLimit(projects, PROJECT_CONCURRENCY, async (p) => {
    const repo = await repoSnapshot(p, sessions);
    const settings = settingsFor?.(p);
    return settings === undefined ? repo : { ...repo, settings };
  });
  return includePrs ? enrichPrs(repos, gateway, lastKnown) : repos;
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

  // Group this project's sessions by the worktree they are bound to. A draft
  // counts too: its worktree is resolved before the spawn, so it renders under
  // that worktree's row rather than in a separate UI bucket.
  //
  // Archived sessions (SPEC-29) are NOT counted. The caller hands us
  // `allSessions()`, which keeps them for fan-out and lookup, but they are hidden
  // from `listSessions()` and therefore from every client-side session list — so
  // their ids resolved to nothing in the consumers that map this field to session
  // rows, and SPEC-38's wrap-up brief counted them as work left behind.
  const sessionsByPath = new Map<string, string[]>();
  for (const s of sessions) {
    if (s.projectId !== dto.id || s.archived) continue;
    const key = s.boundWorktreePath ?? repoPath;
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
 * Add open-PR info (via the {@link GithubGateway}) to a git-only snapshot from
 * {@link listRepos}. Returns new objects — the input is not mutated — so the
 * caller can keep the fast snapshot around while this one is in flight. The
 * lookups are flattened across all repos and run through a single bounded pool
 * ({@link PR_CONCURRENCY}); the gateway has its own gate, but this cap is also
 * what keeps this fan-out's memory/FD footprint bounded.
 *
 * Crucially, a lookup that could not be completed ({@link PrLookup} `unknown`)
 * retains the last-known PR marked `stale` rather than clearing the pill — the
 * missing-pill bug (spec §1 defect 2, §6.5). Only a definite `none` drops it.
 */
export async function enrichPrs(
  repos: RepoDTO[],
  gateway: GithubGateway,
  lastKnown: LastKnownPr,
): Promise<RepoDTO[]> {
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
  const lookups = await mapLimit(tasks, PR_CONCURRENCY, (t) => fetchOpenPr(gateway, t.repoPath, t.branch));
  tasks.forEach((t, i) => {
    const lookup = lookups[i];
    const w = out[t.ri].worktrees[t.wi];
    switch (lookup.kind) {
      case "pr":
        // Fresh data: write it, and ensure no stale marker lingers.
        w.pr = { ...lookup.pr, stale: false };
        break;
      case "none":
        // Definitely no open PR: the pill *should* go.
        w.pr = null;
        break;
      case "unknown": {
        // Could not tell: retain the last-known pill, dimmed — never erase it on
        // a throttle/failure. Nothing to retain → null.
        const prior = lastKnown(t.repoPath, t.branch);
        w.pr = prior ? { ...prior, stale: true } : null;
        break;
      }
    }
  });
  return out;
}
