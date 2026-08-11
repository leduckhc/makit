/**
 * git.ts — repo intelligence for the repo-centric home screen.
 *
 * Thin, promise-returning wrappers over the `git` and `gh` CLIs. Everything is
 * best-effort: a repo with no upstream, a missing `gh`, or a detached HEAD must
 * degrade gracefully (null / empty / zeroed stats) rather than throw, so the
 * home screen always renders. The one exception is {@link addWorktree}, whose
 * failure the caller needs to surface to the user.
 *
 * All paths are absolute. Commands run with the repo/worktree as `cwd`.
 */

import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { log } from "./log.js";
import { mapLimit } from "./concurrency.js";
import type { PrCheckBucket, PrCheckDTO, PrCheckRollup } from "./protocol.js";
// Type-only: the gateway imports value symbols (normalizeChecks, rollupChecks)
// from this file, so importing it as a value here would create a runtime cycle.
import type { GithubGateway, PrLookup } from "./github/gateway.js";

/**
 * Cap on concurrent per-worktree git reads within a single repo (e.g. the
 * HEAD-timestamp probe below). Bounds the child-process fan-out for a repo
 * with many worktrees; nests under the manager's project-level cap.
 */
const WORKTREE_READ_CONCURRENCY = 8;

/** Base directory under which managed worktrees are created. */
export function worktreeBaseDir(): string {
  return process.env.MAKIT_WORKTREE_DIR ?? join(homedir(), ".worktrees");
}

interface RunResult {
  code: number;
  stdout: string;
  stderr: string;
}

/**
 * Run a command, resolving with its exit code + captured output. Never
 * rejects (a spawn failure resolves with code 127 and the error on stderr) so
 * callers can branch on `code` without try/catch noise.
 */
export function run(cmd: string, args: string[], cwd?: string, timeoutMs?: number): Promise<RunResult> {
  return new Promise((resolvePromise) => {
    execFile(
      cmd,
      args,
      { cwd, maxBuffer: 32 * 1024 * 1024, timeout: timeoutMs },
      (err, stdout, stderr) => {
        if (err && typeof (err as { code?: unknown }).code === "number") {
          resolvePromise({ code: (err as { code: number }).code, stdout, stderr });
        } else if (err) {
          // Spawn failure (ENOENT etc.) or timeout — treat as "unavailable".
          resolvePromise({ code: 127, stdout: "", stderr: String((err as Error).message) });
        } else {
          resolvePromise({ code: 0, stdout, stderr });
        }
      },
    );
  });
}

/**
 * Hard cap for read-only git invocations. Local git is normally milliseconds;
 * the cap exists so one wedged repo (dead network mount, fsmonitor prompt,
 * lock contention) cannot hang the whole repos snapshot forever. Mutations
 * (worktree add/remove) are NOT capped — a large checkout may legitimately
 * take longer, and killing it halfway is worse than waiting.
 */
const GIT_READ_TIMEOUT_MS = 15_000;

const git = (args: string[], cwd: string) => run("git", args, cwd, GIT_READ_TIMEOUT_MS);

/** True when `path` is inside a git working tree. */
export async function isGitRepo(path: string): Promise<boolean> {
  const r = await git(["rev-parse", "--is-inside-work-tree"], path);
  return r.code === 0 && r.stdout.trim() === "true";
}

/**
 * The repo's default branch (e.g. `main`). Resolution order:
 *   1. `origin/HEAD` symbolic ref (what `git clone` sets) → strip `origin/`.
 *   2. First of `main` / `master` that exists locally.
 *   3. The current branch (last resort).
 * Returns null only for a repo with no branches at all.
 */
export async function detectDefaultBranch(repoPath: string): Promise<string | null> {
  const head = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repoPath);
  if (head.code === 0) {
    const ref = head.stdout.trim();
    if (ref.startsWith("origin/")) return ref.slice("origin/".length);
    if (ref) return ref;
  }
  for (const candidate of ["main", "master"]) {
    const exists = await git(["rev-parse", "--verify", "--quiet", `refs/heads/${candidate}`], repoPath);
    if (exists.code === 0) return candidate;
  }
  return detectCurrentBranch(repoPath);
}

/** The currently checked-out branch, or null when HEAD is detached. */
export async function detectCurrentBranch(repoPath: string): Promise<string | null> {
  const r = await git(["rev-parse", "--abbrev-ref", "HEAD"], repoPath);
  if (r.code !== 0) return null;
  const branch = r.stdout.trim();
  return branch && branch !== "HEAD" ? branch : null;
}

export interface WorktreeEntry {
  /** Absolute path of the worktree checkout. */
  path: string;
  /** Short branch name, or null when detached / bare. */
  branch: string | null;
  /** Commit SHA at HEAD. */
  head: string | null;
  /** HEAD commit time in epoch milliseconds, or null when unavailable. */
  committedAt: number | null;
  /** True for the repo's primary (first) working tree. */
  isPrimary: boolean;
}

/**
 * Enumerate the repo's worktrees via `git worktree list --porcelain`. The first
 * entry git reports is the primary working tree. Returns `[]` for a
 * non-repo path.
 */
export async function listWorktrees(repoPath: string): Promise<WorktreeEntry[]> {
  const r = await git(["worktree", "list", "--porcelain"], repoPath);
  if (r.code !== 0) return [];

  const out: WorktreeEntry[] = [];
  let cur: Partial<WorktreeEntry> | null = null;
  const flush = () => {
    if (cur?.path) {
      out.push({
        path: cur.path,
        branch: cur.branch ?? null,
        head: cur.head ?? null,
        committedAt: null,
        isPrimary: out.length === 0,
      });
    }
    cur = null;
  };

  for (const line of r.stdout.split("\n")) {
    if (line.startsWith("worktree ")) {
      flush();
      cur = { path: line.slice("worktree ".length).trim() };
    } else if (line.startsWith("HEAD ")) {
      if (cur) cur.head = line.slice("HEAD ".length).trim();
    } else if (line.startsWith("branch ")) {
      // e.g. "branch refs/heads/main" → "main"
      const ref = line.slice("branch ".length).trim();
      if (cur) cur.branch = ref.replace(/^refs\/heads\//, "");
    } else if (line === "detached") {
      if (cur) cur.branch = null;
    }
  }
  flush();

  // Best-effort HEAD commit time per worktree (epoch ms), in parallel but
  // bounded — one wall-clock git latency instead of one per worktree, without
  // spawning a git process per worktree all at once. A git failure or
  // unparseable value leaves committedAt null.
  await mapLimit(out, WORKTREE_READ_CONCURRENCY, async (e) => {
    const r2 = await git(["log", "-1", "--format=%ct"], e.path);
    const secs = r2.code === 0 ? Number.parseInt(r2.stdout.trim(), 10) : NaN;
    e.committedAt = Number.isFinite(secs) ? secs * 1000 : null;
  });
  return out;
}

export interface DiffStat {
  insertions: number;
  deletions: number;
  filesChanged: number;
  /**
   * Whether the target ref could be resolved, so callers can tell "no committed
   * delta" from "we could not measure one".
   *
   * Without this the two are indistinguishable: when the `target...HEAD` leg
   * fails, only *that* leg is skipped — working-tree and untracked files still
   * count — so an absent target yields a plausible SMALL number rather than a
   * zero. That is strictly harder to notice than a zero, and it renders a
   * stacked worktree as though it had barely diverged. A null target is
   * `true`: there is nothing to resolve and the working-tree-only reading is
   * the intended answer (see the note on `target` below).
   */
  targetResolved: boolean;
}

const ZERO_DIFF: DiffStat = { insertions: 0, deletions: 0, filesChanged: 0, targetResolved: true };

/**
 * Total change size of a worktree relative to `targetBranch` — the branch this
 * work is destined for: committed diff (`target...HEAD`, three-dot, so git
 * finds the merge base live) plus uncommitted working-tree changes (staged +
 * unstaged + untracked). In other words, **what a pull request into `target`
 * would contain**.
 *
 * When `targetBranch` is null or equals the worktree's own branch we count
 * working-tree changes only — there is no destination to compare against, so
 * the number legitimately means "uncommitted".
 *
 * Best-effort on the counts, but NOT silent about the ref: a target that cannot
 * be resolved sets `targetResolved: false` rather than quietly degrading to a
 * working-tree-only figure that reads like a small real diff.
 */
export async function diffStat(worktreePath: string, targetBranch: string | null): Promise<DiffStat> {
  const totals = { ...ZERO_DIFF };
  const files = new Set<string>();

  const addNumstat = (stdout: string) => {
    for (const line of stdout.split("\n")) {
      if (!line.trim()) continue;
      const [add, del, ...rest] = line.split("\t");
      const file = rest.join("\t");
      // Binary files report "-\t-"; skip their line counts but count the file.
      const ins = add === "-" ? 0 : Number.parseInt(add, 10);
      const dels = del === "-" ? 0 : Number.parseInt(del, 10);
      if (Number.isFinite(ins)) totals.insertions += ins;
      if (Number.isFinite(dels)) totals.deletions += dels;
      if (file) files.add(file);
    }
  };

  // The three git reads are independent — run them concurrently.
  const cur = await detectCurrentBranch(worktreePath);
  // Only a target that is BOTH set and different from our own branch implies a
  // committed-delta measurement that could fail. Equal/null means "nothing to
  // resolve", which is a success, not a silent skip.
  const measuresTarget = Boolean(targetBranch) && cur !== targetBranch;
  const [committed, working, untracked] = await Promise.all([
    // Committed delta vs the merge base with the target branch (three-dot).
    measuresTarget
      ? git(["diff", "--numstat", `${targetBranch}...HEAD`], worktreePath)
      : Promise.resolve(null),
    // Uncommitted: staged + unstaged tracked changes.
    git(["diff", "--numstat", "HEAD"], worktreePath),
    // Untracked files: count each as an added file (no cheap line count).
    git(["ls-files", "--others", "--exclude-standard"], worktreePath),
  ]);

  if (committed && committed.code === 0) addNumstat(committed.stdout);
  // A requested-but-failed committed leg is the whole point of the flag: report
  // it so the caller suppresses the pill instead of publishing a partial count.
  if (measuresTarget && committed?.code !== 0) totals.targetResolved = false;
  // A path that is not a git repo at all resolves nothing, even with no target:
  // `git diff HEAD` failing is the only signal we get that the read was void.
  if (!measuresTarget && working.code !== 0) totals.targetResolved = false;
  if (working.code === 0) addNumstat(working.stdout);
  if (untracked.code === 0) {
    for (const line of untracked.stdout.split("\n")) if (line.trim()) files.add(line.trim());
  }

  totals.filesChanged = files.size;
  return totals;
}

/**
 * Every local branch, sorted. `for-each-ref` (not `git branch`) so the output is
 * plain refnames with no decoration, no `*` marker and no colour.
 */
export async function listLocalBranches(repoPath: string): Promise<string[]> {
  const r = await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], repoPath);
  if (r.code !== 0) return [];
  return r.stdout
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .sort();
}

/**
 * Branch names that exist on a remote, with the remote prefix stripped
 * (`origin/feat/x` -> `feat/x`).
 *
 * Used to mark a candidate as unusable for a pull request: a PR base must exist
 * on the remote, so a local-only branch is offered but disabled rather than
 * silently accepted and rejected later by `gh`.
 *
 * `origin/HEAD` is skipped — it is a symbolic alias for the default branch, not a
 * branch of its own, and offering it would list the default twice.
 */
export async function listRemoteBranchNames(repoPath: string): Promise<Set<string>> {
  const r = await git(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], repoPath);
  const out = new Set<string>();
  if (r.code !== 0) return out;
  for (const line of r.stdout.split("\n")) {
    const ref = line.trim();
    if (!ref) continue;
    const slash = ref.indexOf("/");
    if (slash < 0) continue;
    const name = ref.slice(slash + 1);
    if (!name || name === "HEAD") continue;
    out.add(name);
  }
  return out;
}

/** True when the repo has at least one remote configured. */
export async function hasAnyRemote(repoPath: string): Promise<boolean> {
  const r = await git(["remote"], repoPath);
  return r.code === 0 && r.stdout.trim().length > 0;
}

/**
 * The branch a worktree most likely forked from: the *closest* ancestor of HEAD
 * among `candidates`.
 *
 * "Ancestor" alone is not enough — after `feat/parent` forks off `main`, both are
 * ancestors of `feat/child`, and only the nearer one is the real parent. So among
 * the ancestors we take the one with the fewest commits between it and HEAD.
 *
 * Deliberately NOT `git merge-base --fork-point`: that consults the reflog, which
 * is empty for a freshly created worktree and absent entirely after a clone or a
 * prune, so it answers "unknown" exactly when we most need a suggestion. This is
 * a *suggestion source* for the picker, not a stored value.
 *
 * Ties are broken by **candidate order**, so callers should pass candidates in
 * preference order: two branches can sit on the same commit (a freshly cut alias),
 * in which case they are equidistant and the caller's ranking is the only
 * meaningful discriminator.
 *
 * Returns null when nothing qualifies (not a repo, unborn HEAD, or every
 * candidate is unrelated).
 */
export async function closestAncestorBranch(
  worktreePath: string,
  candidates: readonly string[],
): Promise<string | null> {
  const own = await detectCurrentBranch(worktreePath);
  let best: { branch: string; distance: number } | null = null;
  for (const branch of candidates) {
    // Its own branch is an ancestor of itself; targeting yourself is meaningless.
    if (!branch || branch === own) continue;
    const isAncestor = await git(
      ["merge-base", "--is-ancestor", branch, "HEAD"],
      worktreePath,
    );
    if (isAncestor.code !== 0) continue;
    const count = await git(["rev-list", "--count", `${branch}..HEAD`], worktreePath);
    if (count.code !== 0) continue;
    const distance = Number.parseInt(count.stdout.trim(), 10);
    if (!Number.isFinite(distance)) continue;
    // Strictly `<`, so an equidistant later candidate never displaces an earlier
    // one — that is what makes the caller's ordering the tie-breaker.
    if (best === null || distance < best.distance) best = { branch, distance };
  }
  return best?.branch ?? null;
}

/** True when a local branch `refs/heads/<branch>` exists. */
export async function branchExists(repoPath: string, branch: string): Promise<boolean> {
  const r = await git(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], repoPath);
  return r.code === 0;
}

export interface PullRequestInfo {
  number: number;
  url: string;
  /** OPEN | CLOSED | MERGED */
  state: string;
  title: string;
  isDraft: boolean;
  mergeable: string | null;
  mergeStateStatus: string | null;
  /**
   * The branch the PR merges into (`main`, a release branch, …). Drives the
   * fast-forward leg of "wrap up". Optional: null when the lookup did not
   * report it, absent on a fixture that predates the field.
   */
  baseRefName?: string | null;
  checks: PrCheckDTO[];
  checkRollup: PrCheckRollup;
  /** Count of unresolved review threads on the PR (via GraphQL). */
  unresolvedComments: number;
  /**
   * True when {@link unresolvedComments} was NOT actually fetched (the field was
   * shed to save quota, or REST — which cannot express it — supplied the PR).
   * The count is then a placeholder 0, not a measured fact (SPEC-32 §6.5).
   */
  unresolvedUnknown?: boolean;
}

/** Raw `statusCheckRollup` entry as emitted by `gh` (either shape). */
interface RawRollupEntry {
  __typename?: string;
  // CheckRun shape
  name?: string;
  status?: string;
  conclusion?: string;
  detailsUrl?: string;
  workflowName?: string;
  // StatusContext shape
  context?: string;
  state?: string;
  targetUrl?: string;
}

/**
 * Classify one raw `statusCheckRollup` entry into a {@link PrCheckBucket}.
 * Handles both the GitHub Actions `CheckRun` shape (status + conclusion) and
 * the legacy `StatusContext` shape (state). Unknown values fall back to
 * `pending` so an unfinished/unrecognized check never masquerades as passing.
 */
function bucketForRollupEntry(e: RawRollupEntry): PrCheckBucket {
  // CheckRun: not COMPLETED means still running/queued.
  if (e.status !== undefined) {
    if (e.status !== "COMPLETED") return "pending";
    switch ((e.conclusion ?? "").toUpperCase()) {
      case "SUCCESS":
        return "pass";
      case "SKIPPED":
      case "NEUTRAL":
        return "skipping";
      case "CANCELLED":
        return "cancel";
      case "FAILURE":
      case "TIMED_OUT":
      case "STARTUP_FAILURE":
      case "ACTION_REQUIRED":
        return "fail";
      default:
        return "pending";
    }
  }
  // StatusContext: a legacy commit status.
  switch ((e.state ?? "").toUpperCase()) {
    case "SUCCESS":
      return "pass";
    case "FAILURE":
    case "ERROR":
      return "fail";
    case "PENDING":
    case "EXPECTED":
      return "pending";
    default:
      return "pending";
  }
}

/** Normalize `gh`'s mixed `statusCheckRollup` array into flat {@link PrCheckDTO}s. */
export function normalizeChecks(rollup: unknown): PrCheckDTO[] {
  if (!Array.isArray(rollup)) return [];
  return rollup.map((raw) => {
    const e = raw as RawRollupEntry;
    return {
      name: e.name ?? e.context ?? "check",
      bucket: bucketForRollupEntry(e),
      workflowName: e.workflowName ?? null,
      detailsUrl: e.detailsUrl ?? e.targetUrl ?? null,
    };
  });
}

/**
 * Aggregate a check list into a single verdict for the pill tint. Any hard
 * failure (`fail`/`cancel`) dominates; else any `pending`; else any `pass`;
 * else `none` (empty, or every check skipped).
 */
export function rollupChecks(checks: PrCheckDTO[]): PrCheckRollup {
  let sawPending = false;
  let sawPass = false;
  for (const c of checks) {
    if (c.bucket === "fail" || c.bucket === "cancel") return "fail";
    if (c.bucket === "pending") sawPending = true;
    if (c.bucket === "pass") sawPass = true;
  }
  if (sawPending) return "pending";
  if (sawPass) return "pass";
  return "none";
}

/**
 * The open PR whose head is `branch`, via the {@link GithubGateway}. The gateway
 * owns cache, dedupe, concurrency, spend accounting, and 403 classification;
 * this is a thin passthrough that keeps `git.ts` the public API surface (spec
 * §5). It returns the three-way {@link PrLookup} so callers can tell a genuine
 * "no open PR" (`none`) apart from a throttled/failed lookup (`unknown`) — the
 * distinction the missing-pill bug turned on (§6.5). Never rejects.
 */
export function fetchOpenPr(gateway: GithubGateway, repoPath: string, branch: string): Promise<PrLookup> {
  return gateway.prForBranch(repoPath, branch);
}

/**
 * Lenient {@link fetchOpenPr}: collapses `none` *and* `unknown` into `null`. PR
 * info is a nice-to-have for these callers (rename guard), never a hard
 * dependency. **Must not** be used on any path that can clear a pill — it
 * cannot distinguish a vanished PR from a throttled lookup.
 *
 * Pass `interactive` when a *user action* depends on the answer. Collapsing
 * `unknown` to null errs towards permitting, which is right for a guard — but on
 * a button press it turns a shed lookup into "no pull request for <branch>", a
 * flat contradiction of the PR the user is looking at. Interactive lookups draw
 * on SPEC-32's reserve, which exists for exactly this.
 */
export async function findOpenPr(
  gateway: GithubGateway,
  repoPath: string,
  branch: string,
  opts?: { interactive?: boolean },
): Promise<PullRequestInfo | null> {
  const result = await gateway.prForBranch(repoPath, branch, opts);
  return result.kind === "pr" ? result.pr : null;
}

/**
 * Count of files with uncommitted changes in a worktree (staged + unstaged +
 * untracked), via `git status --porcelain` (one line per file). Best-effort —
 * 0 on any git failure.
 */
export async function uncommittedFileCount(worktreePath: string): Promise<number> {
  const r = await git(["status", "--porcelain", "--untracked-files=all"], worktreePath);
  if (r.code !== 0) return 0;
  return r.stdout.split("\n").filter((l) => l.trim().length > 0).length;
}

/**
 * Count of commits on this worktree's branch that are not yet on its remote
 * (i.e. what a push would send). Prefers the upstream tracking branch
 * (`@{upstream}..HEAD`); when the branch has no upstream (never pushed), falls
 * back to commits not reachable from [targetBranch] — the commits a first
 * `git push -u` would publish. Best-effort — 0 on any git failure.
 */
export async function commitsAhead(worktreePath: string, targetBranch: string | null): Promise<number> {
  const parse = (s: string): number => {
    const n = Number.parseInt(s.trim(), 10);
    return Number.isFinite(n) ? n : 0;
  };
  const up = await git(["rev-list", "--count", "@{upstream}..HEAD"], worktreePath);
  if (up.code === 0) return parse(up.stdout);
  // No upstream configured: count commits ahead of the base branch instead.
  if (!targetBranch) return 0;
  const base = await git(["rev-list", "--count", `${targetBranch}..HEAD`], worktreePath);
  return base.code === 0 ? parse(base.stdout) : 0;
}

/**
 * Count of commits on this worktree's upstream that are not yet local (what a
 * pull would fetch). Requires a tracking branch — a branch with no upstream has
 * nothing to pull, so this returns 0. Best-effort — 0 on any git failure.
 */
export async function commitsBehind(worktreePath: string): Promise<number> {
  const r = await git(["rev-list", "--count", "HEAD..@{upstream}"], worktreePath);
  if (r.code !== 0) return 0;
  const n = Number.parseInt(r.stdout.trim(), 10);
  return Number.isFinite(n) ? n : 0;
}

/** A single open pull request, as listed for the "New worktree from PR" flow. */
export interface OpenPr {
  number: number;
  title: string;
  headRefName: string;
  isDraft: boolean;
  url: string;
}

/**
 * All open PRs for the repo, newest first, via the {@link GithubGateway}.
 * Returns [] when `gh` is missing/unauthenticated or the repo has no GitHub
 * remote — the picker just shows an empty list rather than erroring.
 */
export function listOpenPrs(
  gateway: GithubGateway,
  repoPath: string,
  limit = 50,
  opts?: { interactive?: boolean },
): Promise<OpenPr[]> {
  return gateway.openPrs(repoPath, limit, opts);
}

/**
 * Create a worktree that checks out an existing PR's head branch. A fresh
 * detached worktree is added first, then `gh pr checkout` fetches the PR head
 * (handling same-repo and fork PRs) and switches the worktree to it. Returns
 * the canonical worktree path + the checked-out branch name. Throws on
 * failure — this is a user-initiated mutation whose error must surface.
 */
export async function addWorktreeForPr(opts: {
  repoPath: string;
  prNumber: number;
  headRefName: string;
  baseDir?: string;
}): Promise<{ path: string; branch: string }> {
  const base = opts.baseDir ?? worktreeBaseDir();
  const repoName = basename(resolve(opts.repoPath));
  // Include the PR number so two PRs whose head refs slugify to the same string
  // (e.g. `feature/foo` and `feature-foo`) can't collide on the same directory.
  const slug = slugify(opts.headRefName);
  const name = slug ? `pr-${opts.prNumber}-${slug}` : `pr-${opts.prNumber}`;
  const target = join(base, repoName, name);
  // Detached checkout of HEAD so the worktree dir exists; gh then moves it to
  // the PR head. No timeout: populating a worktree can take a while.
  const add = await run("git", ["worktree", "add", "--detach", target], opts.repoPath);
  if (add.code !== 0) {
    throw new Error(`git worktree add failed: ${add.stderr.trim() || add.stdout.trim() || `exit ${add.code}`}`);
  }
  // Always check out onto a PR-unique local branch (`name`). gh's default
  // reuses the PR head-ref as the branch name, which git rejects when that
  // branch is already checked out in another worktree of this repo (commonly
  // the primary checkout sits on it), breaking the flow. A dedicated per-PR
  // branch avoids the collision entirely; `--branch` still tracks the PR head,
  // so pushes update the PR.
  const checkout = await run(
    "gh",
    ["pr", "checkout", String(opts.prNumber), "--branch", name],
    target,
  );
  if (checkout.code !== 0) {
    // Roll back the empty detached worktree so we don't leave litter behind.
    // Best-effort: don't let a rollback failure mask the real checkout error.
    await removeWorktree(opts.repoPath, target, true).catch(() => {});
    throw new Error(`gh pr checkout ${opts.prNumber} failed: ${checkout.stderr.trim() || `exit ${checkout.code}`}`);
  }
  // Report the actual checked-out branch (`name`, from --branch above) by
  // reading HEAD, falling back to headRefName only if the read fails. Callers
  // use this to highlight the worktree's row.
  const head = await run("git", ["rev-parse", "--abbrev-ref", "HEAD"], target);
  const actual = head.code === 0 ? head.stdout.trim() : "";
  const branch = actual && actual !== "HEAD" ? actual : name;
  return { path: realpathSync(target), branch };
}

/**
 * Rename a worktree's local branch via `git branch -m`. Runs in the worktree
 * so the currently checked-out branch is the one renamed. Throws on failure.
 */
export async function renameBranch(worktreePath: string, oldName: string, newName: string): Promise<void> {
  // `--` terminates option parsing so a name beginning with `-` is treated as a
  // ref rather than a git flag.
  const r = await run("git", ["branch", "-m", "--", oldName, newName], worktreePath);
  if (r.code !== 0) {
    throw new Error(`git branch -m failed: ${r.stderr.trim() || `exit ${r.code}`}`);
  }
}

/**
 * Turn free-form text into a git-safe, kebab-case slug capped at ~6 words.
 * Empty / punctuation-only input yields "" so the caller can fall back to a
 * generated id.
 */
export function slugify(text: string, maxWords = 6): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, maxWords)
    .join("-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

/**
 * Slugify a user-typed branch name into a git-safe ref, PRESERVING `/` so
 * hierarchical names like `feat/new-ui` survive. Each `/`-separated segment is
 * slugified like {@link slugify} (lowercase, non-`[a-z0-9-]` runs → `-`); empty
 * segments are dropped, which also strips leading/trailing/duplicate slashes.
 * The result is capped at `maxLength` chars (trailing `/`/`-` trimmed) so a
 * pasted string can't produce an oversized git ref or an over-long worktree
 * directory path. Returns `""` when nothing usable remains (caller falls back
 * to an auto name). The worktree DIRECTORY name is derived separately by
 * flattening `/` → `-`, since a slash in the dir path would nest a subfolder.
 */
export function slugifyBranch(text: string, maxLength = 80): string {
  const slug = text
    .toLowerCase()
    .replace(/[^a-z0-9\s/-]/g, " ")
    .split("/")
    .map((seg) =>
      seg
        .trim()
        .split(/\s+/)
        .filter(Boolean)
        .join("-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, ""),
    )
    .filter(Boolean)
    .join("/");
  return slug.slice(0, maxLength).replace(/[/-]+$/g, "");
}

/**
 * Create a new worktree at `<worktreeBaseDir()>/<repoName>/<name>` on a fresh
 * branch `branch`, forked from `startPoint`. Returns the absolute worktree path,
 * canonicalized (symlinks resolved) so it matches what `git worktree list`
 * reports — callers store this as `session.worktreePath` and later compare it
 * against git's output to link sessions to worktrees, which silently breaks if
 * the base contains a symlink (e.g. macOS `/var`→`/private/var`, or a symlinked
 * projects dir). Throws on failure (the caller surfaces it) — unlike the read
 * helpers this is a user-initiated mutation whose error must not be swallowed.
 */
export async function addWorktree(opts: {
  repoPath: string;
  name: string;
  branch: string;
  /**
   * Where the new branch forks FROM — git's own noun for this argument is a
   * commit-ish, and it legally accepts a tag or a SHA. Deliberately NOT called
   * `targetBranch`: a merge destination must be a branch, and this function
   * already uses `target` for the filesystem path it creates and `baseDir` for
   * the worktree root. Callers pass the user's chosen target here because at
   * creation time you fork from the branch you intend to land back in.
   */
  startPoint?: string | null;
  baseDir?: string;
}): Promise<string> {
  const base = opts.baseDir ?? worktreeBaseDir();
  const repoName = basename(resolve(opts.repoPath));
  const target = join(base, repoName, opts.name);
  const args = ["worktree", "add", "-b", opts.branch, target];
  if (opts.startPoint) args.push(opts.startPoint);
  // No timeout: populating a worktree on a big repo can take a while.
  const r = await run("git", args, opts.repoPath);
  if (r.code !== 0) {
    throw new Error(`git worktree add failed: ${r.stderr.trim() || r.stdout.trim() || `exit ${r.code}`}`);
  }
  // Canonicalize so the returned path matches `git worktree list` output
  // (which realpaths); the dir exists now that `git worktree add` succeeded.
  return realpathSync(target);
}

/**
 * Remove a managed worktree. Throws on non-zero git exit (after logging) so
 * callers — and the UI — see the failure instead of a false success. Pass
 * `force` to drop even with uncommitted changes.
 */
export async function removeWorktree(repoPath: string, worktreePath: string, force = false): Promise<void> {
  const args = ["worktree", "remove", worktreePath];
  if (force) args.push("--force");
  const r = await git(args, repoPath);
  if (r.code !== 0) {
    const detail = r.stderr.trim() || `exit ${r.code}`;
    log.warn(`[makit] git worktree remove ${worktreePath} failed: ${detail}`);
    throw new Error(`git worktree remove ${worktreePath} failed: ${detail}`);
  }
}

/** Outcome of a {@link syncBaseBranch} attempt. */
export interface BaseSyncResult {
  /** True when the local base branch actually moved. */
  updated: boolean;
  /**
   * Why it did not move, when that is worth telling the user. Absent for the
   * benign "already up to date" case — that is a success, not a problem.
   */
  reason?: string;
}

/**
 * Bring the local base branch (usually `main`) up to date after a PR landed on
 * it — the second half of "wrap up" (SPEC: PR actions).
 *
 * **Fast-forward only, always.** A divergent local base means there are commits
 * on it that were never pushed, and silently discarding those while tidying up a
 * merged PR would be indefensible. So a non-fast-forward is reported, not forced.
 *
 * Two paths, because git treats a checked-out branch differently:
 *  - checked out somewhere (normally the primary checkout) → `merge --ff-only`
 *    inside that worktree, so the working tree follows the ref,
 *  - only a ref → `fetch origin <branch>:<branch>`, which refuses a
 *    non-fast-forward by itself and needs no checkout.
 *
 * Best-effort by contract: every failure (no remote, no such branch, offline)
 * comes back as `updated: false` with a reason. The caller has already removed
 * the worktree by this point, so throwing here would report a half-done job as
 * a total failure.
 */
export async function syncBaseBranch(repoPath: string, branch: string): Promise<BaseSyncResult> {
  // `run` without a cap, not `git`: this talks to the network inside a
  // user-initiated action, and a large or slow repo can legitimately outlast the
  // 15s read cap (see GIT_READ_TIMEOUT_MS — mutations are deliberately uncapped).
  // Capping it would report "could not fetch" for a fetch that was merely slow.
  const fetched = await run("git", ["fetch", "origin", branch], repoPath);
  if (fetched.code !== 0) {
    return { updated: false, reason: `could not fetch origin/${branch}` };
  }
  // Nothing to do is the common case (the watcher may already have fetched).
  const ahead = await git(["rev-list", "--count", `${branch}..origin/${branch}`], repoPath);
  if (ahead.code === 0 && ahead.stdout.trim() === "0") return { updated: false };

  const trees = await listWorktrees(repoPath);
  // Normally 0 or 1. `git worktree add --ignore-other-worktrees` permits the same
  // branch in several, and updating the shared ref through one of them would
  // leave the others' index and working tree on the old commit — spuriously
  // dirty, and confusing to debug. Refuse rather than pick one arbitrarily.
  const hosts = trees.filter((t) => t.branch === branch);
  if (hosts.length > 1) {
    return {
      updated: false,
      reason: `${branch} is checked out in more than one worktree`,
    };
  }
  const host = hosts[0];
  if (host) {
    const merged = await run("git", ["merge", "--ff-only", `origin/${branch}`], host.path);
    if (merged.code !== 0) {
      // Divergence is the *likely* cause but not the only one — a dirty index or
      // working tree in the host worktree fails `--ff-only` too. Asserting
      // "local commits" then sends the user hunting a commit that does not exist
      // and hides the thing they could actually fix, so git's own words lead.
      return {
        updated: false,
        reason:
          `could not fast-forward ${branch}: ` +
          (merged.stderr.trim() ||
            `it has local commits that are not on origin/${branch}`),
      };
    }
    return { updated: true };
  }
  // Not a force: no `+` on the refspec, so git itself rejects a non-fast-forward.
  const refUpdate = await run("git", ["fetch", "origin", `${branch}:${branch}`], repoPath);
  if (refUpdate.code !== 0) {
    return {
      updated: false,
      reason: `${branch} has local commits that are not on origin/${branch}`,
    };
  }
  return { updated: true };
}

/**
 * Delete the local branch `<branch>`, if it is still there.
 *
 * Uses `-D`, not `-d`: a PR that GitHub squashed or rebased on merge leaves a
 * local branch whose commits git cannot find on the base, so `-d` would refuse
 * to delete a branch that has demonstrably landed. The caller only reaches here
 * having read `state: MERGED` (or `CLOSED`) from GitHub, which is the better
 * authority on whether the work survived.
 *
 * Silent when the branch is already gone — wrap up is meant to be re-runnable.
 */
export async function deleteBranch(repoPath: string, branch: string): Promise<void> {
  if (!(await branchExists(repoPath, branch))) return;
  const r = await git(["branch", "-D", branch], repoPath);
  if (r.code !== 0) {
    const detail = r.stderr.trim() || `exit ${r.code}`;
    throw new Error(`git branch -D ${branch} failed: ${detail}`);
  }
}
