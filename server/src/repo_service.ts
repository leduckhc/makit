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
import {
  isGitRepo,
  detectDefaultBranch,
  listLocalBranches,
  listRemoteBranchNames,
  detectCurrentBranch,
  listWorktrees,
  diffStat,
  fetchOpenPr,
  uncommittedFileCount,
  commitsAhead,
  commitsBehind,
} from "./git.js";
import { mapLimit } from "./concurrency.js";
import {
  loadTargets,
  putTarget,
  pruneTargets,
  worktreeTargetsFile,
  type TargetMap,
} from "./worktree-target-store.js";
import { resolveThroughChain } from "./target_candidates.js";

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
/**
 * The single owner of "what branch does this worktree land in?".
 *
 * Precedence, and why:
 *  1. **Primary or detached -> null.** The primary checkout *is* where branches
 *     land; a detached worktree has no branch to land. Neither has a target, and
 *     `diffStat` reads a null target as "count the working tree", which is the
 *     honest answer for both.
 *  2. **An open PR's `baseRefName`.** Once a PR exists the forge is
 *     authoritative -- and this is precisely how makit inherits GitHub's
 *     automatic PR retargeting (when a parent PR merges and its branch is
 *     deleted, GitHub repoints the children at the merged PR's own base) without
 *     reimplementing any of it.
 *  3. **The persisted user choice** (`worktree-target-store`): the answer given
 *     at creation time or via `worktree.setTarget`.
 *  4. **The repo default.** Deliberately last, and deliberately the fallback:
 *     it reproduces the pre-feature behaviour exactly, so upgrading an existing
 *     install moves nobody's numbers until they choose a target.
 *
 * A winner equal to the worktree's own branch is discarded and resolution
 * continues. That is reachable in practice: `renameBranch` keeps the worktree
 * path (and therefore its stored target) while changing the branch name, so a
 * rename onto the target's name would otherwise leave the worktree silently
 * self-targeting -- which `diffStat` would report as working-tree-only with no
 * indication anything was wrong.
 *
 * Pure, so the precedence rules are testable without a repo or a network.
 */
/**
 * Persist the base of any **live** pull request that disagrees with what we have
 * stored, and return the effective map.
 *
 * This is what makes the "PR wins while it is open, the stored choice applies
 * otherwise" rule survive its own transitions. Three cases it fixes:
 *
 *  * a PR opened by hand against a different base (`gh pr create --base …`) — the
 *    stored value catches up rather than lying in wait,
 *  * the PR closing or reopening — the fallback is now where it actually pointed,
 *  * GitHub auto-retargeting a stacked PR and then auto-closing it, which would
 *    otherwise drop us back onto a target that no longer matches.
 *
 * Announced via `retargetedFrom` only when it OVERRODE a value we already had:
 * agreement is not news, and a first-time adoption of the base the user chose
 * anyway would just be noise.
 *
 * Synchronous: `lastKnown` is the previous broadcast's PR, already in memory. It
 * is null on the very first snapshot after a restart, so adoption happens one
 * poll later -- the documented latency window, not a lost update.
 */
function adoptLivePrTargets(
  repoPath: string,
  entries: readonly { path: string; branch: string | null }[],
  persisted: TargetMap,
  lastKnown: LastKnownPr,
): TargetMap {
  let out: TargetMap | null = null;
  const file = worktreeTargetsFile();
  for (const e of entries) {
    if (!e.branch) continue;
    const pr = lastKnown(repoPath, e.branch);
    if (!pr || pr.state?.toUpperCase() !== "OPEN") continue;
    const base = pr.baseRefName;
    // A PR cannot land in its own head branch; treat that as bad data rather than
    // persisting a self-target we would then have to discard on every read.
    if (!base || base === e.branch) continue;
    const current = persisted[e.path]?.target;
    if (current === base) continue;
    out ??= { ...persisted };
    out[e.path] = current ? { target: base, retargetedFrom: current } : { target: base };
    putTarget(file, e.path, base, current ? { retargetedFrom: current } : {});
  }
  return out ?? persisted;
}

/**
 * Repoint any worktree whose persisted target no longer exists, and return the
 * effective map. Pure with respect to its inputs; writes to the store only when a
 * repair was needed.
 *
 * Uses {@link resolveThroughChain} so a stack that landed bottom-up outside makit
 * still collapses to where it actually landed rather than jumping straight to the
 * repo default.
 */
/**
 * Pure decision core of {@link repairVanishedTargets}: given the live branch set
 * and the record of what-lands-where, decide the new target for each of THIS
 * repo's worktrees whose persisted target has vanished. Returns the writes to
 * persist (empty when nothing is broken), so the I/O stays in the caller and
 * this stays unit-testable without a repo.
 *
 * Two invariants it enforces, both once-live bugs:
 *  * **Repo isolation** — `persisted` is the GLOBAL store; only paths in `here`
 *    (this repo's worktrees) are considered, so another repo's target is never
 *    tested against this repo's branches and rewritten to this repo's default.
 *  * **Remote bases are live** — a target that exists on `origin` has NOT
 *    vanished, even if it was never checked out locally. An open PR's base
 *    (which `adoptLivePrTargets` may have just persisted) commonly lives only on
 *    the remote, and rewriting it to the default would undo that adoption.
 */
export function repointVanishedTargets(args: {
  here: ReadonlySet<string>;
  persisted: TargetMap;
  live: ReadonlySet<string>;
  branchTarget: Readonly<Record<string, string>>;
  defaultBranch: string | null;
}): Array<{ path: string; target: string; retargetedFrom: string }> {
  const { here, persisted, live, branchTarget, defaultBranch } = args;
  const out: Array<{ path: string; target: string; retargetedFrom: string }> = [];
  for (const [path, entry] of Object.entries(persisted)) {
    if (!entry.target || !here.has(path)) continue;
    if (live.has(entry.target)) continue;
    const resolved = resolveThroughChain(entry.target, { live, branchTarget, defaultBranch });
    // Nothing to fall back to (no default, or it is gone too). Leave the broken
    // target in place: `diffStat` reports `targetResolved: false` and the UI says
    // so, which beats inventing a destination.
    if (!resolved || resolved === entry.target) continue;
    out.push({ path, target: resolved, retargetedFrom: entry.target });
  }
  return out;
}

async function repairVanishedTargets(
  repoPath: string,
  entries: readonly { path: string; branch: string | null }[],
  persisted: TargetMap,
  defaultBranch: string | null,
): Promise<TargetMap> {
  // Only this repo's worktrees carry targets we may touch; `persisted` is global.
  const here = new Set(entries.map((e) => e.path));
  const hasStale = Object.entries(persisted).some(([path, e]) => e.target && here.has(path));
  if (!hasStale) return persisted;
  // Liveness is local refs ∪ `origin`: a PR base often lives only on the remote,
  // so a local-only check would wrongly classify it as vanished.
  const [locals, remotes] = await Promise.all([
    listLocalBranches(repoPath),
    listRemoteBranchNames(repoPath),
  ]);
  const live = new Set<string>([...locals, ...remotes]);
  if (live.size === 0) return persisted;

  // branch -> where it lands, so a multi-link chain can be walked.
  const branchTarget: Record<string, string> = {};
  for (const e of entries) {
    const entry = e.branch ? persisted[e.path] : undefined;
    if (e.branch && entry) branchTarget[e.branch] = entry.target;
  }

  const writes = repointVanishedTargets({ here, persisted, live, branchTarget, defaultBranch });
  if (writes.length === 0) return persisted;
  const out: TargetMap = { ...persisted };
  const file = worktreeTargetsFile();
  for (const w of writes) {
    out[w.path] = { target: w.target, retargetedFrom: w.retargetedFrom };
    putTarget(file, w.path, w.target, { retargetedFrom: w.retargetedFrom });
  }
  return out;
}

export function resolveTargetBranch(args: {
  branch: string | null;
  isPrimary: boolean;
  prBaseRefName: string | null | undefined;
  /**
   * The pull request's state. Only a **live** PR is authoritative: a merged or
   * closed one is history, and letting its base keep winning would pin the
   * worktree to a destination that is already settled — so after it ends, the
   * user's own value takes over again. An unrecognised state is treated as not
   * authoritative, so a state this build predates cannot silently redirect where
   * work lands.
   */
  prState?: string | null;
  persisted: string | null | undefined;
  defaultBranch: string | null;
}): string | null {
  const { branch, isPrimary, prBaseRefName, prState, persisted, defaultBranch } = args;
  if (isPrimary || !branch) return null;
  const livePrBase = prState?.toUpperCase() === "OPEN" ? prBaseRefName : null;
  for (const candidate of [livePrBase, persisted, defaultBranch]) {
    if (candidate && candidate !== branch) return candidate;
  }
  return null;
}

/**
 * The set of currently-live worktree paths across every project in a snapshot,
 * or `null` when the snapshot cannot be trusted to prune against.
 *
 * A git repo always has at least its primary worktree, so a git repo reporting
 * ZERO worktrees means its enumeration failed (transient git error). Pruning the
 * global target store against a partial live set would delete valid targets, so
 * one such repo aborts the whole sweep rather than risk data loss.
 */
export function collectLivePathsForPrune(repos: readonly RepoDTO[]): Set<string> | null {
  const live = new Set<string>();
  for (const repo of repos) {
    if (repo.isGitRepo && repo.worktrees.length === 0) return null;
    for (const w of repo.worktrees) live.add(w.path);
  }
  return live;
}

export async function listRepos(
  projects: ProjectDTO[],
  sessions: Session[],
  includePrs: boolean,
  gateway: GithubGateway,
  lastKnown: LastKnownPr,
): Promise<RepoDTO[]> {
  // Bounded fan-out across projects (SPEC-17 P3 × #66 concurrency cap).
  // Read the persisted targets ONCE per snapshot rather than per worktree: it is
  // a single small JSON file, and re-reading it inside the fan-out would turn
  // one read into N.
  const persistedTargets = loadTargets(worktreeTargetsFile());
  const repos = await mapLimit(projects, PROJECT_CONCURRENCY, (p) =>
    repoSnapshot(p, sessions, lastKnown, persistedTargets),
  );
  // Sweep targets for worktrees that no longer exist. Paths are deterministic, so
  // a removed-and-recreated worktree reuses a path and a surviving entry would
  // hand the new worktree a dead target. `removeWorktree` clears its own entry,
  // but a worktree deleted OUTSIDE makit leaves one behind; this is the sweep
  // that collects those. `listProjects()` is the full project set, so the union
  // of their live worktrees is authoritative. Guarded against a transient git
  // failure (see {@link collectLivePathsForPrune}), and cheap: writes only when
  // something is actually stale.
  const live = collectLivePathsForPrune(repos);
  if (live) pruneTargets(worktreeTargetsFile(), [...live]);
  return includePrs ? enrichPrs(repos, gateway, lastKnown) : repos;
}

/**
 * Git-only snapshot of one project (no `gh`/network). Per-worktree diff stats
 * are read in parallel but bounded ({@link WORKTREE_CONCURRENCY}).
 */
async function repoSnapshot(
  dto: ProjectDTO,
  sessions: Session[],
  lastKnown: LastKnownPr,
  persistedTargets: TargetMap,
): Promise<RepoDTO> {
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
  // Closed sessions (SPEC-29) are NOT counted. The caller hands us
  // `allSessions()`, which keeps them for fan-out and lookup, but they are hidden
  // from `listSessions()` and therefore from every client-side session list — so
  // their ids resolved to nothing in the consumers that map this field to session
  // rows, and SPEC-38's wrap-up brief counted them as work left behind.
  const sessionsByPath = new Map<string, string[]>();
  for (const s of sessions) {
    if (s.projectId !== dto.id || s.closed) continue;
    const key = s.boundWorktreePath ?? repoPath;
    const list = sessionsByPath.get(key) ?? [];
    list.push(s.id);
    sessionsByPath.set(key, list);
  }

  // Rule 4: a target that has vanished without makit tidying it away.
  //
  // Someone ran `git branch -D`, or the forge auto-deleted the head branch when a
  // pull request merged -- either way there was no wrap-up, so nothing handed a
  // replacement down (rule 3). From here "merged" and "abandoned" are
  // indistinguishable, so we take the simple, predictable route: fall back to the
  // repo default, and RECORD what it used to be so the change is announced rather
  // than done behind the user's back.
  //
  // Repairing during a read is deliberate: this is the only place we notice, and
  // it costs one branch listing per repo (not per worktree). It writes only when
  // something actually changed, so a healthy repo never touches the file.
  // B7: adopt a LIVE pull request's base into the persisted value, so the two
  // backing stores converge instead of disagreeing at every lifecycle edge.
  // Without this, closing a PR falls back to whatever was persisted BEFORE it
  // existed -- a value that has not been true since the PR was opened -- and
  // GitHub's auto-retarget-then-auto-close sequence lands us on a target that no
  // longer matches reality.
  const adopted = gitRepo ? adoptLivePrTargets(repoPath, entries, persistedTargets, lastKnown) : persistedTargets;
  const repaired = gitRepo
    ? await repairVanishedTargets(repoPath, entries, adopted, defaultBranch)
    : adopted;

  const worktrees: WorktreeDTO[] = await mapLimit(entries, WORKTREE_CONCURRENCY, async (e) => {
    // Run the per-worktree git probes sequentially so they add no extra
    // parallel fan-out on top of WORKTREE_CONCURRENCY: at most one of these
    // helpers runs at a time per worktree (diffStat's own internal parallelism
    // is unchanged), keeping concurrent git subprocesses within budget.
    // Resolve the target FIRST, so the numbers and the label can never disagree.
    // `enrichPrs` runs later and only assigns `w.pr` -- it never recomputes the
    // diff -- so deferring this to that pass would leave the pill measuring
    // against the persisted value while the UI showed the PR's base, inside one
    // broadcast. `lastKnown` hands us the previous poll's PR synchronously,
    // which is what makes PR-first precedence possible in the git-only phase.
    const targetBranch = resolveTargetBranch({
      branch: e.branch,
      isPrimary: e.isPrimary,
      prBaseRefName: e.branch ? lastKnown(repoPath, e.branch)?.baseRefName : null,
      prState: e.branch ? lastKnown(repoPath, e.branch)?.state : null,
      persisted: repaired[e.path]?.target,
      defaultBranch,
    });
    const stat = await diffStat(e.path, targetBranch);
    const uncommittedFiles = await uncommittedFileCount(e.path);
    // NOTE: ahead/behind are UPSTREAM metrics, not target metrics.
    // `commitsAhead` prefers `@{upstream}..HEAD` and only falls back to the ref
    // passed here when the branch has no upstream; `commitsBehind` takes no ref
    // at all. Retargeting therefore moves the diff and NOT these counts -- which
    // is correct, because they answer "what would a push send / a pull fetch",
    // not "what would a PR contain". Do not present them as target-relative.
    const aheadCount = await commitsAhead(e.path, targetBranch);
    const behindCount = await commitsBehind(e.path);
    return {
      id: e.path,
      path: e.path,
      branch: e.branch,
      isPrimary: e.isPrimary,
      targetBranch,
      targetResolved: stat.targetResolved,
      // What this target replaced, when makit moved it automatically. Present
      // until the user picks a target explicitly, which is what makes it an
      // announcement rather than a toast that can be missed.
      retargetedFrom: repaired[e.path]?.retargetedFrom ?? null,
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
