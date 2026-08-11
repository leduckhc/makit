/**
 * makit — SPEC-46 D5: which docs differ from the branch's merge base.
 *
 * `changed` is the review question — *what did this branch add or touch* — not
 * "dirty in the working tree". It reuses the same `base...HEAD` merge-base diff
 * that the worktree row's `+412/−38` badge runs (`git.ts` / `repo_service.ts`).
 *
 * TRAP (D14): `git.ts`'s `run()` NEVER rejects — a spawn fault or timeout
 * resolves as `{code:127, stdout:""}`. Reading that as an empty diff would make
 * a missing git binary silently mean "nothing changed". So a non-zero exit is
 * UNDETERMINED (undefined), and the caller leaves `changed` **absent** — absent
 * must never decay into `false`.
 */

/** The `run`-shaped exec `git.ts` provides: resolves with an exit code, never rejects. */
/** Ceiling on the merge-base diff. Past it, `changed` is undetermined. */
export const GIT_DIFF_TIMEOUT_MS = 10_000;

export type Exec = (
  cmd: string,
  args: string[],
  cwd?: string,
  timeoutMs?: number,
) => Promise<{ code: number; stdout: string; stderr: string }>;

/**
 * The worktree-relative paths that differ from the merge base with
 * `baseBranch`, or `undefined` when it cannot be determined (no base, or git
 * failed). On the base branch itself the answer is a determined empty set —
 * HEAD is its own merge base, so nothing differs.
 */
export async function changedPaths(
  worktreePath: string,
  baseBranch: string | null,
  currentBranch: string | null,
  exec: Exec,
): Promise<ReadonlySet<string> | undefined> {
  // No base to diff against, or a detached HEAD: undetermined. Absent, not false.
  if (!baseBranch) return undefined;
  // On the base branch the merge base is HEAD, so nothing differs — determined
  // empty, and no need to shell out.
  if (currentBranch === baseBranch) return new Set();

  // Bounded for the same reason `git ls-files` is: a slow or lock-contended repo
  // must degrade to "undetermined" (D14: absent, never guessed) rather than
  // stall the re-index and every watcher behind it.
  const r = await exec(
    "git",
    // core.quotePath=false keeps non-ASCII paths (e.g. `été.md`) as literal UTF-8
    // rather than git's default C-style octal escapes. The candidate list comes
    // from `git ls-files -z` (never quoted), so without this the two disagree and
    // a changed non-ASCII doc would report `changed: false`.
    ["-c", "core.quotePath=false", "diff", "--name-only", `${baseBranch}...HEAD`],
    worktreePath,
    GIT_DIFF_TIMEOUT_MS,
  );
  // Explicit code check: 127 (missing git / spawn fault / timeout) is a failure,
  // not an empty diff. Undetermined → absent.
  if (r.code !== 0) return undefined;

  const changed = new Set<string>();
  for (const line of r.stdout.split("\n")) {
    const rel = line.trim();
    if (rel !== "") changed.add(rel);
  }
  return changed;
}
