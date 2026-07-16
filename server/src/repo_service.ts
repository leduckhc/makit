/**
 * RepoService: builds the repo-centric home-screen snapshot (git/gh
 * enrichment) for a set of projects.
 *
 * Extracted from {@link SessionManager} (SPEC-19, localizing SPEC-17 P3). The
 * git/branch/worktree reads and the `gh` open-PR lookup fan out concurrently;
 * callers should treat this as an occasional (connect / spawn / refresh)
 * operation, not per-event.
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
} from "./git.js";

/**
 * Repo-centric snapshot for the home screen: each project enriched with its
 * default/current branch and worktrees (diff stats, open PR, running
 * sessions). Shells out to git/gh per worktree, so callers should treat this
 * as an occasional (connect / spawn / refresh) operation, not per-event.
 *
 * `includePrs` gates the open-PR lookup. The diff +/- numbers are pure local
 * git and instant; the PR lookup shells out to `gh` (network, seconds). Pass
 * `false` to skip `gh` and emit the fast git-only snapshot, then call again
 * with `true` to enrich PRs — so the numbers never wait on the network.
 */
export async function listRepos(
  projects: ProjectDTO[],
  sessions: Session[],
  includePrs: boolean,
): Promise<RepoDTO[]> {
  // Independent read-only shells: fan out across projects (SPEC-17 P3).
  return Promise.all(projects.map((p) => listRepo(p, sessions, includePrs)));
}

/** Build the {@link RepoDTO} for one project, parallelizing per-worktree shells. */
async function listRepo(dto: ProjectDTO, sessions: Session[], includePrs: boolean): Promise<RepoDTO> {
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

  // Per-worktree diff stat + PR lookup are independent shells — fan out.
  const worktrees: WorktreeDTO[] = await Promise.all(
    entries.map(async (e): Promise<WorktreeDTO> => {
      const [stat, pr] = await Promise.all([
        diffStat(e.path, defaultBranch),
        includePrs && e.branch && !e.isPrimary
          ? findOpenPr(repoPath, e.branch)
          : Promise.resolve(null),
      ]);
      return {
        id: e.path,
        path: e.path,
        branch: e.branch,
        isPrimary: e.isPrimary,
        insertions: stat.insertions,
        deletions: stat.deletions,
        filesChanged: stat.filesChanged,
        committedAt: e.committedAt,
        pr,
        sessionIds: sessionsByPath.get(e.path) ?? [],
      };
    }),
  );

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
