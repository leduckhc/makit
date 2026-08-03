/**
 * Churn-proof CPU ledger (SPEC-37 decision 4).
 *
 * Agents spawn short-lived children (ripgrep, bash) that exit between the 1 Hz
 * ticks. If we only summed the pids present in the current tick, a turn that
 * spawned fifty ripgreps would report almost no CPU, because each child's CPU
 * time vanishes with the child.
 *
 * The fix: per root, keep a frozen credit for every pid we have ever seen. The
 * returned total is the live CPU of pids present this tick plus the frozen CPU of
 * pids that have since vanished — which is what makes the total monotonic.
 */

import type { ProcLike } from "./tree.js";

interface Credit {
  seconds: number;
  comm: string;
}

export class CpuLedger {
  /** root pid -> (pid -> last credited CPU seconds + comm). */
  private readonly byRoot = new Map<number, Map<number, Credit>>();

  /**
   * Fold this tick's tree into `root`'s monotonic CPU total.
   *
   * @param root  the agent's root pid (the ledger key)
   * @param pids  every pid in the tree this tick (from `descendants`)
   * @param table the current process table
   * @returns the root's cpuSeconds — never less than the previous call for this root
   */
  observe(root: number, pids: number[], table: Map<number, ProcLike>): number {
    let credited = this.byRoot.get(root);
    if (!credited) {
      credited = new Map<number, Credit>();
      this.byRoot.set(root, credited);
    }

    const seen = new Set<number>();
    for (const pid of pids) {
      const proc = table.get(pid);
      if (!proc) continue;
      seen.add(pid);

      // Pid-reuse guard: a pid reappearing with a different comm is an unrelated
      // process the OS assigned the recycled pid to. Its frozen credit is stale, so
      // drop it and start fresh rather than carrying it forward and double-counting.
      const prior = credited.get(pid);
      if (prior && prior.comm !== proc.comm) credited.delete(pid);

      credited.set(pid, { seconds: proc.cpuSeconds, comm: proc.comm });
    }

    let live = 0;
    let frozen = 0;
    for (const [pid, credit] of credited) {
      if (seen.has(pid)) live += credit.seconds;
      else frozen += credit.seconds; // frozen contribution of vanished pids
    }
    return live + frozen;
  }
}
