/**
 * IdleReaper — closes sessions nobody is working with, so their agent processes
 * stop costing memory (SPEC-session-lifecycle-resume-list-delete option D).
 *
 * makit runs ONE agent process per session (60–450 MB each) and, before this,
 * nothing ever took an idle one down: agents accumulated for days. Measured on a
 * dev host: 19 resident agents, ~0.95 GB RSS, the oldest 5 days old.
 *
 * A policy collaborator rather than manager behaviour, matching `MetricsCollector`
 * and the ports service: it owns its own window, interval, clock and timer, and
 * reaches the session world through the narrow {@link IdleReaperDeps} seam. That
 * keeps the "when may we release a session?" rules in one readable place instead
 * of as another few fields and branches inside `SessionManager`.
 *
 * Auto-closing is safe because closing keeps the transcript and the resume
 * handle: every sweep is reversible, and a later message reopens the session
 * transparently (`SessionManager.ensureLiveForInput`).
 */

import { isBusy } from "./protocol.js";
import type { Session } from "./session.js";
import { log } from "./log.js";

/**
 * Default window: quiet for this long and the agent is released.
 *
 * A fortnight, deliberately generous. An hour reclaimed more memory, but it moved
 * sessions a user was still working through out of their worktree and into the
 * Closed list several times a day, which reads as lost work. Two weeks keep the
 * hygiene for genuinely abandoned sessions and leave live work where the user
 * left it. Shorten it with `MAKIT_IDLE_CLOSE_MIN` on a memory-tight host.
 */
export const DEFAULT_IDLE_CLOSE_MS = 14 * 24 * 60 * 60_000;

/** Floor on the sweep interval, so a short window can't busy-loop the daemon. */
const MIN_SWEEP_MS = 30_000;

/**
 * Ceiling on the sweep interval. A quarter of the fortnight-long default is 84
 * hours, far longer than a typical daemon lifetime, so the derived interval alone
 * would let a session sit released-but-resident indefinitely. A sweep with no
 * candidate is an in-memory filter over a few hundred sessions, so a 15-minute
 * tick costs nothing.
 */
const MAX_SWEEP_MS = 15 * 60_000;

export interface IdleReaperDeps {
  /** Every session the server currently holds. */
  sessions: () => Iterable<Session>;
  /** Release one session's agent and mark it closed (`SessionManager.closeSession`). */
  close: (sessionId: string) => Promise<void>;
  /** Quiet period before a session is eligible. `0` disables the reaper. */
  idleCloseMs?: number;
  /** Sweep interval. Defaults to a quarter of the window, floored at 30s. */
  sweepMs?: number;
  now?: () => number;
  /** Injectable interval, mirroring `MetricsCollector`. */
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

/**
 * Resolve the idle window from the environment. `MAKIT_IDLE_CLOSE_MIN` overrides
 * the default; `0` disables auto-close. A garbage value falls back to the default
 * rather than silently disabling memory hygiene.
 */
export function resolveIdleCloseMs(env = process.env): number {
  const raw = env.MAKIT_IDLE_CLOSE_MIN;
  if (raw === undefined || raw.trim() === "") return DEFAULT_IDLE_CLOSE_MS;
  const min = Number(raw);
  if (!Number.isFinite(min) || min < 0) {
    log.warn(
      `[makit] ignoring MAKIT_IDLE_CLOSE_MIN="${raw}" (not a non-negative number); using ${DEFAULT_IDLE_CLOSE_MS / 60_000}min`,
    );
    return DEFAULT_IDLE_CLOSE_MS;
  }
  if (min === 0) log.info("[makit] MAKIT_IDLE_CLOSE_MIN=0: idle auto-close disabled");
  return Math.round(min * 60_000);
}

export class IdleReaper {
  private readonly idleCloseMs: number;
  private readonly sweepMs: number;
  private readonly now: () => number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;
  private handle?: unknown;
  /** Guards against overlapping sweeps (a close awaits the agent). */
  private sweeping = false;

  constructor(private readonly deps: IdleReaperDeps) {
    this.idleCloseMs = deps.idleCloseMs ?? 0;
    // Sweep four times per window, bounded at both ends: prompt enough that a
    // cold session is released soon after it goes quiet, coarse enough to cost
    // nothing, and never so coarse that a long window stops being enforced.
    this.sweepMs =
      deps.sweepMs ?? Math.min(MAX_SWEEP_MS, Math.max(MIN_SWEEP_MS, Math.floor(this.idleCloseMs / 4)));
    this.now = deps.now ?? (() => Date.now());
    this.setTimer = deps.setTimer ?? ((fn, ms) => setInterval(fn, ms));
    this.clearTimer = deps.clearTimer ?? ((h) => clearInterval(h as NodeJS.Timeout));
  }

  /** True when a window is configured. */
  get enabled(): boolean {
    return this.idleCloseMs > 0;
  }

  /** Arm the periodic sweep. No-op when disabled or already armed. */
  start(): void {
    if (!this.enabled || this.handle !== undefined) return;
    this.handle = this.setTimer(() => {
      void this.sweep().catch((e) =>
        log.warn(`[makit] idle sweep failed: ${e instanceof Error ? e.message : String(e)}`),
      );
    }, this.sweepMs);
    log.info(
      `[makit] idle auto-close armed: releasing sessions idle > ${Math.round(this.idleCloseMs / 60_000)}min (sweep every ${Math.round(this.sweepMs / 1000)}s)`,
    );
  }

  /** Disarm (shutdown). Idempotent. */
  stop(): void {
    if (this.handle === undefined) return;
    this.clearTimer(this.handle);
    this.handle = undefined;
  }

  /**
   * May this session be released right now? A stale timestamp is never enough on
   * its own; each exclusion below would otherwise lose work or free nothing:
   *
   *  - `closed` — already released.
   *  - `pending` (draft) — no agent to free, and closing would persist an empty
   *    row in the Closed list.
   *  - cold — the agent process is already gone, so there is nothing to reclaim.
   *  - {@link isBusy} — the agent is working or holding a question for the user.
   *    Such a session can carry an old `lastActivityAt`: a long tool call or an
   *    unanswered prompt is quiet on the wire but very much alive.
   *  - not `resumable` — no native handle to come back through, so releasing it
   *    would cost the user the session. Held deliberately; a manual close still
   *    works.
   */
  private closable(session: Session, now: number): boolean {
    return (
      !session.closed &&
      !session.pending &&
      !session.cold &&
      !isBusy(session.status) &&
      session.resumable &&
      now - session.lastActivityAt > this.idleCloseMs
    );
  }

  /** Close every session that has gone quiet. Returns the ids closed. */
  async sweep(): Promise<string[]> {
    if (!this.enabled) return [];
    // A close awaits the agent, so a slow sweep could otherwise overlap the next
    // tick and try to close the same session twice.
    if (this.sweeping) return [];
    this.sweeping = true;
    try {
      const candidates = [...this.deps.sessions()].filter((s) => this.closable(s, this.now()));
      const closed: string[] = [];
      for (const session of candidates) {
        // Re-check against a FRESH clock. Every close awaits an agent round-trip
        // plus up to the SIGTERM grace period, so this loop can run for tens of
        // seconds across several sessions — easily long enough for a message to
        // arrive and start a turn on a session further down the list. Closing it
        // on the strength of a stale check would tear the agent out from under a
        // live turn.
        const checkedAt = this.now();
        if (!this.closable(session, checkedAt)) {
          log.info(
            `[makit] idle auto-close: skipping ${session.id.slice(0, 8)} — became active during the sweep`,
          );
          continue;
        }
        const idleMin = Math.round((checkedAt - session.lastActivityAt) / 60_000);
        try {
          await this.deps.close(session.id);
          closed.push(session.id);
          log.info(
            `[makit] idle auto-close: ${session.id.slice(0, 8)} ("${session.title}") idle ${idleMin}min — agent released, reopen to resume`,
          );
        } catch (e) {
          // One stuck session must not stop the rest from being reclaimed.
          log.warn(
            `[makit] idle auto-close failed for ${session.id.slice(0, 8)}: ${e instanceof Error ? e.message : String(e)}`,
          );
        }
      }
      return closed;
    } finally {
      this.sweeping = false;
    }
  }
}
