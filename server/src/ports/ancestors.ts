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
 * Walk the ppid chain from `start` upward, yielding each pid (starting with
 * `start` itself), bounded by {@link MAX_ANCESTOR_DEPTH} and cycle-safe.
 *
 * This is the ONE bounded ancestor traversal, consumed by both {@link cwdPidSet}
 * (which needs the whole set) and attribute.ts's `ownerOf` (which stops at the
 * first cwd that resolves under a worktree). Keeping a single copy keeps the
 * load-bearing bound + cycle guard from drifting between two hand-rolled walks.
 *
 * `seen` doubles as the cycle guard AND, when a caller passes a shared set, the
 * cross-start dedup: a later start whose chain reconverges onto an already-walked
 * one stops at the join. `pid 1`/`0` terminate the climb naturally (their ppid
 * self-references or is absent from the table).
 */
export function* walkAncestors(
  start: number,
  procs: Map<number, ProcInfo>,
  seen: Set<number> = new Set(),
): Generator<number> {
  let pid: number | undefined = start;
  let depth = 0;
  while (pid !== undefined && !seen.has(pid) && depth <= MAX_ANCESTOR_DEPTH) {
    seen.add(pid);
    yield pid;
    const proc = procs.get(pid);
    if (!proc || proc.ppid === pid) break; // unknown pid, or self-parent root
    pid = proc.ppid;
    depth++;
  }
}

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
  // One shared `seen` across every start: walkAncestors records each visited pid
  // in it, so `seen` IS the result. Drain the generator for its side effect.
  for (const start of listenerPids) for (const _pid of walkAncestors(start, procs, seen));
  return seen;
}
