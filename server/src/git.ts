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
function run(cmd: string, args: string[], cwd?: string, timeoutMs?: number): Promise<RunResult> {
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
  checks: PrCheckDTO[];
  checkRollup: PrCheckRollup;
  /** Count of unresolved review threads on the PR (via GraphQL). */
  unresolvedComments: number;
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
 * The open PR whose head is `branch`, via `gh`, distinguishing "no open PR"
 * from a *failed* lookup:
 *   - returns a {@link PullRequestInfo} when one exists,
 *   - returns `null` when the lookup succeeded but there is genuinely no open
 *     PR (e.g. it was merged/closed and left the open set),
 *   - **throws** when the lookup itself failed (`gh` missing/unauthenticated,
 *     no GitHub remote, network/parse error).
 *
 * The PR watcher relies on this three-way distinction: a returned `null` means
 * a tracked PR vanished (broadcast the drop), whereas a throw is a transient
 * failure (retain the last-known status). {@link findOpenPr} is the lenient
 * wrapper for callers that only care whether a PR exists.
 *
 * One `gh pr list` call fetches identity + mergeability + the CI check rollup
 * together (verified: `--head` list output includes `statusCheckRollup`), so a
 * poll costs a single subprocess per open PR.
 */
export async function fetchOpenPr(repoPath: string, branch: string): Promise<PullRequestInfo | null> {
  const r = await run(
    "gh",
    [
      "pr",
      "list",
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "number,url,state,title,isDraft,mergeable,mergeStateStatus,statusCheckRollup",
      "--limit",
      "1",
    ],
    repoPath,
    5000,
  );
  if (r.code !== 0) throw new Error(`gh pr list --head ${branch} failed (exit ${r.code})`);
  const parsed = JSON.parse(r.stdout.trim() || "[]") as Array<Record<string, unknown>>;
  if (!Array.isArray(parsed) || parsed.length === 0) return null;
  const p = parsed[0];
  const checks = normalizeChecks(p.statusCheckRollup);
  const url = typeof p.url === "string" ? p.url : "";
  return {
    number: typeof p.number === "number" ? p.number : 0,
    url,
    state: typeof p.state === "string" ? p.state : "OPEN",
    title: typeof p.title === "string" ? p.title : "",
    isDraft: p.isDraft === true,
    mergeable: typeof p.mergeable === "string" ? p.mergeable : null,
    mergeStateStatus: typeof p.mergeStateStatus === "string" ? p.mergeStateStatus : null,
    checks,
    checkRollup: rollupChecks(checks),
    unresolvedComments: url ? await unresolvedReviewThreadCount(repoPath, url) : 0,
  };
}

/**
 * Lenient {@link fetchOpenPr}: returns null for *both* "no open PR" and a failed
 * lookup. PR info is a nice-to-have for these callers (snapshot enrichment,
 * rename guard), never a hard dependency, and folding the error case into null
 * keeps a single flaky `gh` call from aborting a whole batch.
 */
export async function findOpenPr(repoPath: string, branch: string): Promise<PullRequestInfo | null> {
  try {
    return await fetchOpenPr(repoPath, branch);
  } catch {
    return null;
  }
}

/**
 * Number of *unresolved* review threads on a PR, via `gh api graphql`. GitHub's
 * `gh pr` JSON exposes no resolved-thread field, so GraphQL is the only way to
 * surface "N unresolved comments". Owner/repo/number are parsed from the PR
 * URL to avoid an extra `gh` call. Best-effort — 0 when `gh` is missing /
 * unauthenticated, the URL is unparseable, or the query fails.
 */
export async function unresolvedReviewThreadCount(repoPath: string, prUrl: string): Promise<number> {
  const m = /github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(prUrl);
  if (!m) return 0;
  const [, owner, repo, number] = m;
  const query =
    "query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}";
  const r = await run(
    "gh",
    ["api", "graphql", "-f", `query=${query}`, "-F", `owner=${owner}`, "-F", `repo=${repo}`, "-F", `number=${number}`],
    repoPath,
    5000,
  );
  if (r.code !== 0) return 0;
  try {
    const data = JSON.parse(r.stdout) as {
      data?: {
        repository?: { pullRequest?: { reviewThreads?: { nodes?: Array<{ isResolved?: boolean }> } } };
      };
    };
    const nodes = data.data?.repository?.pullRequest?.reviewThreads?.nodes ?? [];
    return nodes.filter((n) => n && n.isResolved === false).length;
  } catch {
    return 0;
  }
}

/**
 * Count of files with uncommitted changes in a worktree (staged + unstaged +
 * untracked), via `git status --porcelain` (one line per file). Best-effort —
 * 0 on any git failure.
 */
export async function uncommittedFileCount(worktreePath: string): Promise<number> {
  const r = await git(["status", "--porcelain"], worktreePath);
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

/** A single open pull request, as listed for the "New worktree from PR" flow. */
export interface OpenPr {
  number: number;
  title: string;
  headRefName: string;
  isDraft: boolean;
  url: string;
}

/**
 * All open PRs for the repo, newest first, via `gh`. Returns [] when `gh` is
 * missing/unauthenticated or the repo has no GitHub remote — the picker just
 * shows an empty list rather than erroring.
 */
export async function listOpenPrs(repoPath: string, limit = 50): Promise<OpenPr[]> {
  const r = await run(
    "gh",
    ["pr", "list", "--state", "open", "--json", "number,title,headRefName,isDraft,url", "--limit", String(limit)],
    repoPath,
    8000,
  );
  if (r.code !== 0) return [];
  try {
    const parsed = JSON.parse(r.stdout.trim() || "[]") as OpenPr[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
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
