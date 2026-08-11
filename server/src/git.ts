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

/**
 * The default branch in force for a repo: the user's override when it still
 * resolves, otherwise git's own answer.
 *
 * The **one** place that rule lives, so the repo snapshot's diff numbers, worktree
 * creation and wrap-up's base sync cannot disagree about what "default" means —
 * three consumers reading `detectDefaultBranch` directly is how the override ended
 * up affecting none of them.
 *
 * The override is CHECKED, not trusted. It is stored after a syntax check only
 * (`validateBranch`), it is chosen from branches that existed at the time, and a
 * branch can be deleted afterwards. A stale override is a worse base than
 * detection, not a better one, so it loses rather than winning and then failing
 * deep inside a `git diff` where the message is unrecognisable.
 *
 * "Known" includes `origin/<branch>`, and the RETURNED FORM differs by which ref
 * exists: a local branch comes back bare (the sync path fast-forwards a local
 * branch), a remote-only one comes back as `origin/<branch>` (so every `git`
 * invocation can resolve it). Callers must therefore treat the result as a REV, and
 * only `syncBaseBranch` cares about the distinction -- which it checks.
 *
 * Checking costs one `rev-parse` and REPLACES detection's one-to-three calls when
 * the override holds, so the common case gets cheaper rather than dearer.
 */
export async function resolveDefaultBranch(
  repoPath: string,
  override: string | undefined,
): Promise<string | null> {
  if (override !== undefined && override.length > 0) {
    // A local branch is returned BARE, because `syncBaseBranch` fetches and
    // fast-forwards a local branch and a qualified name would break it.
    if (await branchExists(repoPath, override)) return override;
    // Known only on the remote: returned QUALIFIED, because git's revision rules never
    // resolve a bare name against `refs/remotes/origin/` (`gitrevisions` checks
    // `refs/<name>`, `refs/tags/<name>`, `refs/heads/<name>`, `refs/remotes/<name>` --
    // not `refs/remotes/origin/<name>`). Returning the bare name handed `diffStat`,
    // `commitsAhead` and `git worktree add` a base that resolves nowhere: silent zero
    // diffs, zero counts, and failed worktree creation.
    if (await remoteBranchExists(repoPath, override)) return `origin/${override}`;
  }
  return detectDefaultBranch(repoPath);
}

/** Whether `refs/remotes/origin/<branch>` exists. */
async function remoteBranchExists(repoPath: string, branch: string): Promise<boolean> {
  const r = await git(
    ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${branch}`],
    repoPath,
  );
  return r.code === 0;
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
}

const ZERO_DIFF: DiffStat = { insertions: 0, deletions: 0, filesChanged: 0 };

/**
 * Total change size of a worktree relative to `baseBranch`: committed diff
 * (`base...HEAD`) plus uncommitted working-tree changes (staged + unstaged +
 * untracked). Best-effort — any git failure yields zeros. When `baseBranch` is
 * null or equals the worktree's branch we count working-tree changes only.
 */
export async function diffStat(worktreePath: string, baseBranch: string | null): Promise<DiffStat> {
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
  const [committed, working, untracked] = await Promise.all([
    // Committed delta vs the merge-base with the default branch.
    baseBranch && cur !== baseBranch
      ? git(["diff", "--numstat", `${baseBranch}...HEAD`], worktreePath)
      : Promise.resolve(null),
    // Uncommitted: staged + unstaged tracked changes.
    git(["diff", "--numstat", "HEAD"], worktreePath),
    // Untracked files: count each as an added file (no cheap line count).
    git(["ls-files", "--others", "--exclude-standard"], worktreePath),
  ]);

  if (committed && committed.code === 0) addNumstat(committed.stdout);
  if (working.code === 0) addNumstat(working.stdout);
  if (untracked.code === 0) {
    for (const line of untracked.stdout.split("\n")) if (line.trim()) files.add(line.trim());
  }

  totals.filesChanged = files.size;
  return totals;
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
 * back to commits not reachable from [baseBranch] — the commits a first
 * `git push -u` would publish. Best-effort — 0 on any git failure.
 */
export async function commitsAhead(worktreePath: string, baseBranch: string | null): Promise<number> {
  const parse = (s: string): number => {
    const n = Number.parseInt(s.trim(), 10);
    return Number.isFinite(n) ? n : 0;
  };
  const up = await git(["rev-list", "--count", "@{upstream}..HEAD"], worktreePath);
  if (up.code === 0) return parse(up.stdout);
  // No upstream configured: count commits ahead of the base branch instead.
  if (!baseBranch) return 0;
  const base = await git(["rev-list", "--count", `${baseBranch}..HEAD`], worktreePath);
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
 * How a PR's head is fetched into a worktree.
 *
 * Two strategies rather than one, because neither generalises:
 *
 *   `gh`        — `gh pr checkout`. Kept for GitHub because it already handles the
 *                 fork case and sets up push tracking, and replacing a working path
 *                 with a hand-rolled equivalent would be a regression risk taken for
 *                 tidiness.
 *   `pull-ref`  — plain git against `refs/pull/<n>/head`, which is how Gitea and
 *                 Forgejo publish PR heads. `gh` cannot be used here at all: it
 *                 speaks only to GitHub, so on a Forgejo remote the picker listed the
 *                 PRs and the checkout then failed.
 */
export type PrCheckoutStrategy = "gh" | "pull-ref";

/**
 * Create a worktree that checks out an existing PR's head branch. A fresh
 * detached worktree is added first, then the PR head is fetched into it and a
 * PR-unique local branch is created. Returns the canonical worktree path + the
 * checked-out branch name. Throws on failure — this is a user-initiated mutation
 * whose error must surface.
 *
 * [checkout] selects the provider strategy; see {@link PrCheckoutStrategy}. It
 * defaults to `gh` so GitHub's behaviour is unchanged for any caller that does not
 * pass one.
 */
export async function addWorktreeForPr(opts: {
  repoPath: string;
  prNumber: number;
  headRefName: string;
  baseDir?: string;
  checkout?: PrCheckoutStrategy;
}): Promise<{ path: string; branch: string }> {
  const base = opts.baseDir ?? worktreeBaseDir();
  const repoName = basename(resolve(opts.repoPath));
  // Include the PR number so two PRs whose head refs slugify to the same string
  // (e.g. `feature/foo` and `feature-foo`) can't collide on the same directory.
  const slug = slugify(opts.headRefName);
  const name = slug ? `pr-${opts.prNumber}-${slug}` : `pr-${opts.prNumber}`;
  const target = join(base, repoName, name);
  // Detached checkout of HEAD so the worktree dir exists; the strategy then moves
  // it to the PR head. No timeout: populating a worktree can take a while.
  const add = await run("git", ["worktree", "add", "--detach", target], opts.repoPath);
  if (add.code !== 0) {
    throw new Error(`git worktree add failed: ${add.stderr.trim() || add.stdout.trim() || `exit ${add.code}`}`);
  }

  const failed =
    (opts.checkout ?? "gh") === "pull-ref"
      ? await checkoutViaPullRef(target, opts.prNumber, opts.headRefName, name)
      : await checkoutViaGh(target, opts.prNumber, name);
  if (failed !== null) {
    // Roll back the empty detached worktree so we don't leave litter behind.
    // Best-effort: don't let a rollback failure mask the real checkout error.
    await removeWorktree(opts.repoPath, target, true).catch(() => {});
    throw new Error(failed);
  }

  // Report the actual checked-out branch (`name`) by reading HEAD, falling back to
  // `name` only if the read fails. Callers use this to highlight the worktree's row.
  const head = await run("git", ["rev-parse", "--abbrev-ref", "HEAD"], target);
  const actual = head.code === 0 ? head.stdout.trim() : "";
  const branch = actual && actual !== "HEAD" ? actual : name;
  return { path: realpathSync(target), branch };
}

/** GitHub: `gh` does the work. Returns an error message, or null on success. */
async function checkoutViaGh(
  target: string,
  prNumber: number,
  branchName: string,
): Promise<string | null> {
  // Always check out onto a PR-unique local branch. gh's default reuses the PR
  // head-ref as the branch name, which git rejects when that branch is already
  // checked out in another worktree of this repo (commonly the primary checkout sits
  // on it), breaking the flow. A dedicated per-PR branch avoids the collision
  // entirely; `--branch` still tracks the PR head, so pushes update the PR.
  const r = await run("gh", ["pr", "checkout", String(prNumber), "--branch", branchName], target);
  return r.code === 0
    ? null
    : `gh pr checkout ${prNumber} failed: ${r.stderr.trim() || `exit ${r.code}`}`;
}

/**
 * Forgejo / Gitea: fetch `refs/pull/<n>/head` and branch from it.
 *
 * That ref is created by the forge for **every** PR including forks', which is why
 * it is used instead of the head branch name — a fork's branch does not exist on
 * `origin` at all.
 *
 * Upstream tracking is set only when the head branch really is on `origin` (a
 * same-repo PR), so a push updates the PR. For a fork it is deliberately left
 * unset: pointing it anywhere would aim a push at a branch that is not the PR's,
 * and pushing to a contributor's fork was never possible from here anyway.
 */
async function checkoutViaPullRef(
  target: string,
  prNumber: number,
  headRefName: string,
  branchName: string,
): Promise<string | null> {
  const ref = `refs/pull/${prNumber}/head`;
  const fetched = await run("git", ["fetch", "--quiet", "origin", ref], target);
  if (fetched.code !== 0) {
    return `fetching ${ref} failed: ${fetched.stderr.trim() || `exit ${fetched.code}`}. The forge may not publish this pull request, or it may be closed.`;
  }
  const checkout = await run("git", ["checkout", "-q", "-b", branchName, "FETCH_HEAD"], target);
  if (checkout.code !== 0) {
    return `checking out PR #${prNumber} failed: ${checkout.stderr.trim() || `exit ${checkout.code}`}`;
  }
  // Best-effort, and only when the branch genuinely exists on origin. `--` is not
  // available here, so the ref is checked first rather than trusted.
  if (headRefName.length > 0) {
    const onOrigin = await run(
      "git",
      ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${headRefName}`],
      target,
    );
    if (onOrigin.code === 0) {
      const upstream = await run(
        "git",
        ["branch", `--set-upstream-to=origin/${headRefName}`, branchName],
        target,
      );
      // Best-effort, but not silent: without an upstream a later `git push` in this
      // worktree does not update the PR, and "my push did nothing" is unanswerable
      // if the reason was never recorded. Not fatal -- the worktree is the point,
      // and it is checked out correctly either way.
      if (upstream.code !== 0) {
        log.warn(
          `[makit] PR #${prNumber}: could not track origin/${headRefName}, so pushing from this worktree will not update the pull request: ${upstream.stderr.trim() || `exit ${upstream.code}`}`,
        );
      }
    }
  }
  return null;
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
 * branch `branch`, based off `baseBranch`. Returns the absolute worktree path,
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
  baseBranch?: string | null;
  baseDir?: string;
}): Promise<string> {
  const base = opts.baseDir ?? worktreeBaseDir();
  const repoName = basename(resolve(opts.repoPath));
  const target = join(base, repoName, opts.name);
  const args = ["worktree", "add", "-b", opts.branch, target];
  if (opts.baseBranch) args.push(opts.baseBranch);
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
  // A remote-tracking base (`origin/trunk`) has no local branch to fast-forward, so
  // there is nothing to catch up -- and running the local path on it would issue
  // `git fetch origin origin/trunk` and compare `origin/trunk..origin/origin/trunk`,
  // both nonsense. `resolveDefaultBranch` returns this form when the default exists
  // only on the remote.
  //
  // BUT: a local branch can be *literally* named `origin/release` (i.e.
  // `refs/heads/origin/release`). Check if it's actually local before refusing.
  if (branch.startsWith("origin/") && !(await branchExists(repoPath, branch))) {
    return { updated: false, reason: `${branch} has no local branch to catch up` };
  }
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
