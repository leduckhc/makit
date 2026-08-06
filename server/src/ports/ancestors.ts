/**
 * ancestors.ts — the pid set whose cwd the scan must read.
 *
 * A `pnpm dev` PARENT owns the worktree cwd while the listening `node` CHILD it
 * spawned may sit in a package subdirectory (or inherit `/`). Requesting cwds
 * for listener pids ONLY makes the documented ancestor fallback dead code — the
 * rev-1 review blocker. So the single `lsof -d cwd` covers every listener PLUS
 * its ancestors, derived here from the `ps` table before that `lsof` runs.
 */

import type { ProcInfo } from "./proc.js";

/**
 * How far up the ppid chain to climb. A dev server is one or two hops below its
 * shell (`pnpm` → `node`, `flutter` → `dart`); a handful of generations covers
 * every real case while capping the work on a pathological tree. Also the
 * belt-and-braces bound alongside the cycle guard.
 */
export const MAX_ANCESTOR_DEPTH = 8;

/**
 * The union of `listenerPids` and their ancestors (bounded, cycle-safe).
 *
 * Cycle-safe via the shared `seen` set: a (theoretically impossible) ppid cycle
 * is walked at most once. `pid 1`/`0` terminate the climb naturally as their
 * ppid either self-references or is absent from the table.
 */
export function cwdPidSet(
  listenerPids: number[],
  procs: Map<number, ProcInfo>,
): Set<number> {
  const seen = new Set<number>();
  for (const start of listenerPids) {
    let pid: number | undefined = start;
    let depth = 0;
    while (pid !== undefined && !seen.has(pid) && depth <= MAX_ANCESTOR_DEPTH) {
      seen.add(pid);
      const proc = procs.get(pid);
      if (!proc || proc.ppid === pid) break; // unknown pid, or self-parent root
      pid = proc.ppid;
      depth++;
    }
  }
  return seen;
}
