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
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { log } from "./log.js";

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

const git = (args: string[], cwd: string) => run("git", args, cwd);

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

  // Committed delta vs the merge-base with the default branch.
  const cur = await detectCurrentBranch(worktreePath);
  if (baseBranch && cur !== baseBranch) {
    const committed = await git(["diff", "--numstat", `${baseBranch}...HEAD`], worktreePath);
    if (committed.code === 0) addNumstat(committed.stdout);
  }

  // Uncommitted: staged + unstaged tracked changes.
  const working = await git(["diff", "--numstat", "HEAD"], worktreePath);
  if (working.code === 0) addNumstat(working.stdout);

  // Untracked files: count each line as an added file (no cheap line count).
  const untracked = await git(["ls-files", "--others", "--exclude-standard"], worktreePath);
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
}

/**
 * The open PR whose head is `branch`, via `gh`. Returns null when `gh` is
 * missing/unauthenticated, the repo has no GitHub remote, or no PR exists —
 * PR info is a nice-to-have, never a hard dependency.
 */
export async function findOpenPr(repoPath: string, branch: string): Promise<PullRequestInfo | null> {
  const r = await run(
    "gh",
    ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url,state,title,isDraft", "--limit", "1"],
    repoPath,
    5000,
  );
  if (r.code !== 0) return null;
  try {
    const parsed = JSON.parse(r.stdout.trim() || "[]") as PullRequestInfo[];
    return Array.isArray(parsed) && parsed.length > 0 ? parsed[0] : null;
  } catch {
    return null;
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
 * branch `branch`, based off `baseBranch`. Returns the absolute worktree path.
 * Throws on failure (the caller surfaces it) — unlike the read helpers this is
 * a user-initiated mutation whose error must not be swallowed.
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
  const r = await git(args, opts.repoPath);
  if (r.code !== 0) {
    throw new Error(`git worktree add failed: ${r.stderr.trim() || r.stdout.trim() || `exit ${r.code}`}`);
  }
  return target;
}

/**
 * Remove a managed worktree. Best-effort: logs and swallows failures so
 * teardown never blocks session cleanup. Pass `force` to drop even with
 * uncommitted changes.
 */
export async function removeWorktree(repoPath: string, worktreePath: string, force = false): Promise<void> {
  const args = ["worktree", "remove", worktreePath];
  if (force) args.push("--force");
  const r = await git(args, repoPath);
  if (r.code !== 0) {
    log.warn(`[makit] git worktree remove ${worktreePath} failed: ${r.stderr.trim() || `exit ${r.code}`}`);
  }
}
