/**
 * derive.ts — pure orphan/collision annotation (SPEC-ports-global-view D10/D12).
 *
 * Takes the attributed `PortDTO[]` plus the port-history store and fills in the
 * optional `orphan` / `collision` fields. No I/O, no clock read beyond the
 * caller-supplied `now`, no mutation of its inputs, and it never throws — exactly
 * like `attribute.ts`.
 *
 * The honesty bar (SPEC-open-ports D7, SPEC-ports-global-view D10): a date is only ever ECHOED from
 * history (`removedAt` = the worktree's recorded `lastSeen`), never fabricated.
 * On empty/first-run history there is no orphan and no date at all.
 */

import type { PortDTO } from "../protocol.js";
import type { ProcInfo } from "./proc.js";
import { HISTORY_TTL_MS, type PortHistory, type PortHistoryEntry } from "./history_store.js";
import { walkAncestors } from "./ancestors.js";

/**
 * Path-segment helpers. `attribute.ts` keeps private copies of these, but that
 * file is intentionally not edited here (it owns live attribution), so the two
 * trivial, well-tested prefix predicates are re-stated rather than exported from
 * it — a smaller change than widening `attribute.ts`'s surface.
 */
function segments(path: string): string[] {
  return path.split("/").filter((s) => s.length > 0);
}

/** True when `prefix` is a whole-segment prefix of `path` (so /a/b ⊄ /a/b-2). */
function isSegmentPrefix(prefix: string[], path: string[]): boolean {
  if (prefix.length > path.length) return false;
  return prefix.every((seg, i) => seg === path[i]);
}

export interface AnnotateInput {
  ports: PortDTO[];
  /** cwd per pid — covers listeners AND their ancestors (see ancestors.ts). */
  cwds: Map<number, string>;
  procs: Map<number, ProcInfo>;
  history: PortHistory;
  /** Absolute worktree paths currently live (the cached repos snapshot). */
  activeWorktreePaths: string[];
  /** Memoised realpath resolver (macOS /tmp aliasing) — see proc.ts. */
  resolveReal: (path: string) => string;
  /** Epoch ms of this scan — used only to ignore history past the TTL, never to
   *  fabricate a date (D10). */
  now: number;
}

export function annotate(input: AnnotateInput): PortDTO[] {
  const { ports, cwds, procs, history, activeWorktreePaths, resolveReal, now } = input;

  // Only history fresher than the TTL is trusted, so a ghost that survived in a
  // hand-edited file (or a not-yet-resaved store) can never fabricate an orphan
  // or a collision — the same bound saveHistory prunes to.
  const cutoff = now - HISTORY_TTL_MS;
  const fresh = history.entries.filter((e) => e.lastSeen >= cutoff);

  const activeSet = new Set(activeWorktreePaths.map((p) => resolveReal(p)));

  // Removed historical worktrees (fresh, in history, no longer active), with
  // precomputed real-path segments for longest-prefix matching.
  const removed = fresh
    .filter((e) => !activeSet.has(resolveReal(e.worktreePath)))
    .map((e) => ({ entry: e, segs: segments(resolveReal(e.worktreePath)) }));

  const resolveOrphan = (pid: number): PortHistoryEntry | undefined => {
    // Climb own cwd then ancestors; the first cwd under a removed worktree wins
    // (longest-segment prefix among the removed set).
    for (const current of walkAncestors(pid, procs)) {
      const cwd = cwds.get(current);
      if (cwd === undefined) continue;
      const cwdSegs = segments(resolveReal(cwd));
      let best: PortHistoryEntry | undefined;
      let bestLen = -1;
      for (const { entry, segs } of removed) {
        if (isSegmentPrefix(segs, cwdSegs) && segs.length > bestLen) {
          best = entry;
          bestLen = segs.length;
        }
      }
      if (best !== undefined) return best;
    }
    return undefined;
  };

  const findCollision = (worktreePath: string, port: number): PortHistoryEntry | undefined => {
    const owner = resolveReal(worktreePath);
    for (const entry of fresh) {
      if (resolveReal(entry.worktreePath) === owner) continue; // same worktree
      if (!activeSet.has(resolveReal(entry.worktreePath))) continue; // rival must still be active
      if (entry.ports.includes(port)) return entry;
    }
    return undefined;
  };

  return ports.map((port): PortDTO => {
    if (port.worktreePath === undefined) {
      const entry = resolveOrphan(port.pid);
      if (entry === undefined) return port;
      const orphan: NonNullable<PortDTO["orphan"]> = { formerWorktreePath: entry.worktreePath };
      if (entry.branch !== undefined) orphan.formerBranch = entry.branch;
      orphan.removedAt = entry.lastSeen;
      return { ...port, orphan };
    }
    const rival = findCollision(port.worktreePath, port.port);
    if (rival === undefined) return port;
    const collision: NonNullable<PortDTO["collision"]> = { withWorktreePath: rival.worktreePath };
    if (rival.branch !== undefined) collision.withBranch = rival.branch;
    return { ...port, collision };
  });
}
