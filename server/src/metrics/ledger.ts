/**
 * Churn-proof CPU ledger (SPEC-37 decision 4).
 *
 * Agents spawn short-lived children (ripgrep, bash) that exit between the 1 Hz
 * ticks. If we only summed the pids present in the current tick, a turn that
 * spawned fifty ripgreps would report almost no CPU, because each child's CPU
 * time vanishes with the child.
 *
 * The fix, per root: `total = base + Σ (cpuSeconds of the pids alive this tick)`,
 * where `base` accumulates the final CPU time of every pid that has since exited.
 * The moment a pid disappears from the table its last observation is folded into
 * `base` and its entry is dropped, which buys three properties at once:
 *
 *  - **Monotonic.** Nothing is ever un-counted, so the total never decreases —
 *    which matters because the collector derives `cpuPercent` from its delta and
 *    a decrease would render a *negative* CPU% on the dashboard.
 *  - **Bounded.** `live` only ever holds the pids seen in the most recent tick,
 *    so it is O(tree size), not O(every pid ever seen). This runs at 1 Hz for the
 *    lifetime of the process; an ever-growing map would be a slow leak in the very
 *    feature that claims makit is cheap.
 *  - **Reuse-safe.** A recycled pid starts a fresh live credit on top of `base`,
 *    so the previous owner's CPU is neither lost nor double-counted.
 *
 * Reuse is detected by a *dropped* cumulative CPU time or a changed `comm`: one
 * process's CPU time can only ever increase, so either signal means the pid now
 * belongs to somebody else.
 */

import type { ProcLike } from "./tree.js";

interface Live {
  seconds: number;
  comm: string;
}

interface RootState {
  /** Final CPU seconds of every pid in this tree that has exited. */
  base: number;
  /** pid -> last observation, for pids alive as of the previous tick. */
  live: Map<number, Live>;
}

export class CpuLedger {
  private readonly byRoot = new Map<number, RootState>();

  /**
   * Fold this tick's tree into `root`'s monotonic CPU total.
   *
   * @param root  the agent's root pid (the ledger key)
   * @param pids  every pid in the tree this tick (from `descendants`)
   * @param table the current process table
   * @returns the root's cumulative cpuSeconds — never less than the previous call
   */
  observe(root: number, pids: number[], table: Map<number, ProcLike>): number {
    let state = this.byRoot.get(root);
    if (!state) {
      state = { base: 0, live: new Map<number, Live>() };
      this.byRoot.set(root, state);
    }

    const next = new Map<number, Live>();
    for (const pid of pids) {
      const proc = table.get(pid);
      if (!proc) continue;

      const prior = state.live.get(pid);
      // A single process's cumulative CPU time cannot fall, and its name cannot
      // change: either signal means the OS recycled this pid for an unrelated
      // process. Retire the previous owner into `base` before counting the new one.
      if (prior && (proc.cpuSeconds < prior.seconds || prior.comm !== proc.comm)) {
        state.base += prior.seconds;
      }
      next.set(pid, { seconds: proc.cpuSeconds, comm: proc.comm });
    }

    // Anything alive last tick but absent now has exited for good: bank its final
    // reading and stop tracking it, keeping `live` bounded by the live tree.
    for (const [pid, credit] of state.live) {
      if (!next.has(pid)) state.base += credit.seconds;
    }
    state.live = next;

    let total = state.base;
    for (const credit of next.values()) total += credit.seconds;
    return total;
  }

  /**
   * Forget a root entirely. Called when its session ends — without this, a server
   * that has spawned and killed many sessions keeps one `RootState` per dead pid
   * forever.
   */
  dispose(root: number): void {
    this.byRoot.delete(root);
  }

  /** Drop every root not in `keep` (the live agent set). */
  retainOnly(keep: Iterable<number>): void {
    const live = new Set(keep);
    for (const root of this.byRoot.keys()) {
      if (!live.has(root)) this.byRoot.delete(root);
    }
  }

  /** Number of tracked roots — for tests asserting the absence of a leak. */
  get trackedRoots(): number {
    return this.byRoot.size;
  }

  /** Pids currently tracked for `root` — for tests asserting bounded growth. */
  trackedPids(root: number): number {
    return this.byRoot.get(root)?.live.size ?? 0;
  }
}
