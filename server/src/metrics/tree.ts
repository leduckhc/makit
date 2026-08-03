/**
 * Whole-tree process attribution (SPEC-37 decision 3).
 *
 * Pure functions. The ppid index is built **once per tick** and reused for every
 * agent root, so a machine-wide `ps` costs one traversal, not one per pid.
 */

/**
 * Structural shape of a process row. Declared here rather than imported from
 * `proc_table.ts` (T1, built concurrently): TypeScript's structural typing means
 * T1's `ProcRow` satisfies this, and a later commit can collapse the duplication.
 */
export interface ProcLike {
  pid: number;
  ppid: number;
  rssBytes: number;
  cpuSeconds: number;
  comm: string;
}

export interface TreeTotals {
  rssBytes: number;
  procs: number;
}

/** Map each parent pid to the list of its direct children. Built once per tick. */
export function childIndex(table: Map<number, ProcLike>): Map<number, number[]> {
  const index = new Map<number, number[]>();
  for (const { pid, ppid } of table.values()) {
    const siblings = index.get(ppid);
    if (siblings) siblings.push(pid);
    else index.set(ppid, [pid]);
  }
  return index;
}

/**
 * Every pid in the subtree rooted at `root`, including `root` itself.
 *
 * Cycle-safe: a `visited` set makes a (theoretically impossible) ppid cycle a
 * no-op rather than an infinite loop that would freeze the 1 Hz event loop.
 * An unknown root simply returns `[root]`.
 */
export function descendants(index: Map<number, number[]>, root: number): number[] {
  const out: number[] = [];
  const visited = new Set<number>();
  const stack = [root];
  while (stack.length > 0) {
    const pid = stack.pop()!;
    if (visited.has(pid)) continue;
    visited.add(pid);
    out.push(pid);
    const children = index.get(pid);
    if (children) stack.push(...children);
  }
  return out;
}

/**
 * Sum RSS and process count over the whole tree rooted at `root`.
 *
 * Deliberately does **not** return `cpuSeconds`: summing only the pids present in
 * this tick would silently lose every short-lived child, which is exactly the
 * failure {@link CpuLedger} exists to prevent (SPEC-37 decision 4). CPU comes from
 * the ledger, exclusively — two functions returning a differently-meaning
 * `cpuSeconds` was a trap the first reviewer of this file walked into.
 *
 * An **unknown root yields zeros**, and does so before traversal: an absent pid can
 * still appear as the `ppid` of an orphan, in which case walking the index would
 * attribute that unrelated process's whole subtree to a dead agent.
 */
export function sumTree(
  table: Map<number, ProcLike>,
  index: Map<number, number[]>,
  root: number,
): TreeTotals {
  if (!table.has(root)) return { rssBytes: 0, procs: 0 };
  let rssBytes = 0;
  let procs = 0;
  for (const pid of descendants(index, root)) {
    const proc = table.get(pid);
    if (!proc) continue;
    rssBytes += proc.rssBytes;
    procs += 1;
  }
  return { rssBytes, procs };
}
