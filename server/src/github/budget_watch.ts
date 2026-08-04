/**
 * Foreground budget watch (SPEC-32 §6.6) — the fast `/rate_limit` loop that runs
 * only while a client actually has the budget panel open.
 *
 * The background cadence is deliberately slow (`REFRESH_INTERVAL_MS`, 60s) and
 * the gateway's own broadcast is gated on `{level, throttles}` changing, because
 * the footer is idle almost all of the time. That gate makes the *open* panel
 * misleading: `remaining`, `mine`, `others` and the burn rate move constantly
 * without ever crossing a level boundary, so a panel left open showed numbers
 * frozen at the moment it was opened.
 *
 * This closes that gap without raising the idle cost: while at least one client
 * watches, re-read every {@link WATCH_INTERVAL_MS} and broadcast every time.
 * `GET /rate_limit` is quota-exempt (spec §4), so the extra reads spend no
 * quota — but they are not free either (one `gh` subprocess each, through the
 * gateway's concurrency gate), which is exactly why this is scoped to an open
 * panel rather than made the global cadence.
 */

/** Fast cadence while the panel is open. Slower than the UI could use, on purpose:
 * the sparkline buckets per minute, so this is about the live counters, not
 * chart resolution. */
export const WATCH_INTERVAL_MS = 10_000;

/** The subset of a timer handle we use; `unref` keeps the process exit-able. */
interface TimerHandle {
  unref?: () => void;
}

export interface BudgetWatchDeps<W extends object> {
  /** Re-read the quota (the gateway's exempt `/rate_limit` read). */
  refresh(): Promise<unknown>;
  /**
   * Send the current snapshot to exactly [watchers] — not to every client. A
   * paired phone has no budget panel, so broadcasting the ~1KB snapshot to it
   * six times a minute because a desktop opened the panel is pure waste.
   */
  broadcast(watchers: readonly W[]): void;
  /** Injectable timer (tests); defaults to `setInterval`. */
  setTimer?: (fn: () => void, ms: number) => TimerHandle;
  /** Injectable clearer (tests); defaults to `clearInterval`. */
  clearTimer?: (handle: unknown) => void;
}

export interface BudgetWatch<W extends object> {
  /** Start watching for [watcher] (a client identity). Idempotent per watcher. */
  add(watcher: W): void;
  /** Stop watching for [watcher]. Unknown watchers are ignored. */
  remove(watcher: W): void;
  /** How many clients currently have the panel open. */
  readonly size: number;
  /** Resolve once the in-flight tick (if any) has finished — for tests. */
  settled(): Promise<void>;
  /** Drop every watcher and disarm; further `add`s are ignored. */
  close(): void;
}

export function watchBudget<W extends object>(deps: BudgetWatchDeps<W>): BudgetWatch<W> {
  const setTimer = deps.setTimer ?? ((fn, ms) => setInterval(fn, ms));
  const clearTimer = deps.clearTimer ?? ((h) => clearInterval(h as NodeJS.Timeout));

  const watchers = new Set<W>();
  let timer: unknown;
  let inFlight: Promise<void> = Promise.resolve();
  let busy = false;
  let closed = false;

  /** One read + broadcast. Broadcasts even when the read failed: the last-known
   * snapshot is still the truth we have, and one bad `gh` must not stall the loop.
   *
   * Skipped while a read is still in flight: `/rate_limit` shares the gateway's
   * concurrency gate with PR lookups, so a read can outlive the interval, and
   * each stacked tick would spawn another `gh`. */
  function tick(): void {
    if (busy) return;
    busy = true;
    inFlight = deps
      .refresh()
      .catch(() => undefined)
      .then(() => {
        busy = false;
        if (!closed) deps.broadcast([...watchers]);
      });
  }

  /** Disarm the loop if it is armed. Idempotent, so `close()` on an unwatched
   * gateway does not clear a handle it never created. */
  function disarm(): void {
    if (timer === undefined) return;
    clearTimer(timer);
    timer = undefined;
  }

  return {
    add(watcher) {
      if (closed || watchers.has(watcher)) return;
      watchers.add(watcher);
      if (watchers.size > 1) return;
      // First watcher: read immediately so the panel opens on fresh numbers
      // instead of waiting out a whole interval, then arm the loop.
      tick();
      const handle = setTimer(tick, WATCH_INTERVAL_MS);
      handle.unref?.();
      timer = handle;
    },
    remove(watcher) {
      if (!watchers.delete(watcher)) return;
      if (watchers.size > 0) return;
      disarm();
    },
    get size() {
      return watchers.size;
    },
    settled: () => inFlight,
    close() {
      closed = true;
      watchers.clear();
      disarm();
    },
  };
}
