/**
 * makit — SPEC-46 D1 rev 2: the candidate list for a worktree's doc index.
 *
 * rev 1 walked an allowlist (`mockups/`, `docs/`, plus root `*.md`). That was
 * tuned for *this* repo and generalises badly — a project keeping its docs in
 * `flutter/learning-records/` showed 3 of its 69 documents, because makit only
 * looked where makit keeps things. Since the sidebar holds many repos, the
 * layout of one of them is the wrong default.
 *
 * rev 2 asks git for every file it does not ignore. That finds docs wherever
 * they actually live, and it *tightens* security as a side effect: a gitignored
 * `secrets.md` can no longer be indexed or served, where rev 1 would have
 * indexed it happily (the dotfile rule never covered it).
 *
 * Extension filtering happens here, not in `resolveDocPath`, so a large repo
 * does not pay a realpath + stat for every non-document file it tracks.
 */

import { execFileSync } from "node:child_process";

/** Extensions worth handing to the security boundary (D2 re-checks them). */
const DOC_EXT = /\.(md|markdown|html?)$/i;

/** Cap on git's output, so a pathological repo cannot exhaust memory. */
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;

/** Lists worktree-relative doc candidates, or undefined when it cannot answer. */
export type DocLister = (worktreeRoot: string) => string[] | undefined;

/**
 * Every `.md`/`.html` path in `worktreeRoot` that git does not ignore — tracked
 * files plus untracked-but-not-ignored ones, so a doc written seconds ago by an
 * agent appears without being committed first.
 *
 * Returns `undefined` when git cannot answer (not a repository, git absent,
 * output too large). The caller then falls back to rev 1's allowlist walk, so a
 * non-git directory still gets an index.
 */
export function trackedDocPaths(worktreeRoot: string): string[] | undefined {
  let stdout: string;
  try {
    stdout = execFileSync(
      "git",
      ["-C", worktreeRoot, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      { encoding: "utf8", maxBuffer: MAX_OUTPUT_BYTES, stdio: ["ignore", "pipe", "ignore"] },
    );
  } catch {
    return undefined; // not a git worktree, git missing, or output over the cap
  }

  // `--cached` and `--others` cannot overlap, but a deduping set costs nothing
  // and makes a duplicate impossible to turn into a duplicate row.
  const paths = new Set<string>();
  for (const rel of stdout.split("\0")) {
    if (rel === "" || !DOC_EXT.test(rel)) continue;
    paths.add(rel);
  }
  return [...paths];
}
