/**
 * kill.ts — the pure half of SPEC-43: *may* this endpoint be signalled?
 *
 * Everything here is a total function over a **fresh** scan. It cannot signal,
 * spawn or wait, which is the point: the one decision that turns a user's tap
 * into a signal to a process makit did not spawn is reviewable in isolation and
 * testable without a victim (`kill.test.ts` is the refusal table).
 *
 * Two disciplines the rest of the codebase already follows, applied here:
 *  - **Re-verify, never trust the snapshot key** (D1, SPEC-41 D6). A pid is a
 *    time-of-check-to-time-of-use hazard: pids are reused and a restart changes
 *    the pid for the same endpoint. So the client sends the whole
 *    `{address, port, pid, startedAt}` tuple it displayed and the server matches
 *    all four against a scan it ran *now* — the `expectBranch` pattern from
 *    `wrap_up.dart` and the pid-reuse guard in `daemon/service.ts`.
 *  - **Whitelist, not blacklist** (D3). An endpoint the scan cannot positively
 *    classify as a user-owned dev server (or a known orphan) is refused. A
 *    process makit cannot explain is never signalled.
 */

import type { PortDTO, PortKillOutcome, PortKillTarget } from "../protocol.js";

/**
 * SIGTERM → SIGKILL window. Long enough for a dev server to run its exit
 * handlers and release the socket, short enough that the user is still looking
 * at the confirm they just tapped. The window is only ever *entered* after a
 * successful SIGTERM, and D1 is re-run before the SIGKILL, so pid churn inside
 * it can never redirect the escalation onto a recycled pid.
 */
export const KILL_GRACE_MS = 2_000;

/**
 * How far apart two `startedAt` values may be and still mean the same process.
 *
 * `startedAt` is NOT reported by the OS — it is derived per scan as
 * `now - etime`, and `ps` reports `etime` at **one-second** granularity. So the
 * same untouched process yields a `startedAt` that moves by up to ~1000 ms
 * between two scans (the reason `service.ts` excludes it from the broadcast
 * dedup projection). Exact equality would therefore make D1 refuse *every* real
 * kill — which is exactly what the real-listener acceptance test caught.
 *
 * 2 s keeps the check meaningful: a target is only mistaken for its replacement
 * if the pid is reused **and** the replacement started within two seconds of the
 * original — the "practically unreachable" collision D1 already accepts — while
 * a restarted dev server (seconds to minutes later) still reads as a mismatch.
 */
export const STARTED_AT_TOLERANCE_MS = 2_000;

/** Everything the whitelist needs to know about *this* makit process. */
export interface KillGuards {
  /** `process.pid` — killing it would take the server down with the port. */
  serverPid: number;
  /** Ancestors of {@link serverPid}; killing one of those also kills us. */
  serverAncestors: Set<number>;
  /** Agent-root pids of live sessions — `session.kill` owns that lifecycle. */
  sessionRoots: Set<number>;
}

/** Either "signal exactly this pid" or "refuse, and say why". */
export type KillDecision =
  | { signal: true; pid: number }
  | { signal: false; outcome: PortKillOutcome };

/** The fresh scan the decision is made against. */
export interface KillScan {
  ports: PortDTO[];
  /** False when the scanner's commands did not run (SPEC-41 D7). */
  scanOk: boolean;
}

/**
 * Apply R1–R7 (spec §"The killable whitelist") in order; the first rule that
 * fires wins. Order is load-bearing and deliberately puts ownership (R4) ahead
 * of the pid guards (R5–R7): an unowned pid 1 reads as `not_owned`, which is the
 * more informative refusal, and the pid guards then protect the case that
 * actually needs them — a pid that IS attributed to a worktree.
 */
export function classifyKillTarget(
  target: PortKillTarget,
  scan: KillScan,
  guards: KillGuards,
): KillDecision {
  // R1 — a scan that did not run proves nothing. `listListeners`/`readProcs`
  // resolve `{ok:false}` rather than rejecting, so without this the handler
  // would happily classify against the LAST GOOD (i.e. stale) port list.
  if (!scan.scanOk) return { signal: false, outcome: "scan_unavailable" };

  const atEndpoint = scan.ports.filter(
    (p) => p.port === target.port && p.address === target.address,
  );
  // R2 — already gone (or never there). Not an error: the user's list was just
  // a few seconds stale, and "nothing to kill" is a success for their intent.
  if (atEndpoint.length === 0) return { signal: false, outcome: "not_found" };

  // R3 — the endpoint is taken, but is it the same process? `startedAt` is the
  // tie-breaker that makes pid reuse detectable; a listener whose start time
  // could not be parsed is unverifiable and therefore never killable. The
  // comparison is a tolerance, not an equality — see STARTED_AT_TOLERANCE_MS.
  const matched = atEndpoint.find(
    (p) =>
      p.pid === target.pid &&
      p.startedAt !== undefined &&
      Math.abs(p.startedAt - target.startedAt) <= STARTED_AT_TOLERANCE_MS,
  );
  if (matched === undefined) return { signal: false, outcome: "identity_mismatch" };

  // R4 — the whitelist proper: a live worktree owns it, or SPEC-42 proved it is
  // an orphan (whose worktree is gone, so it can never have a `worktreePath`).
  const owned = matched.worktreePath !== undefined || matched.orphan !== undefined;
  if (!owned) return { signal: false, outcome: "not_owned" };

  // R5–R7 — the three pids that are owned-looking but must never be signalled.
  if (matched.pid === 1) return { signal: false, outcome: "refused_protected" };
  if (matched.pid === guards.serverPid || guards.serverAncestors.has(matched.pid)) {
    return { signal: false, outcome: "refused_self" };
  }
  if (guards.sessionRoots.has(matched.pid)) {
    return { signal: false, outcome: "refused_session" };
  }

  return { signal: true, pid: matched.pid };
}
