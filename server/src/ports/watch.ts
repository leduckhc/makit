/**
 * watch.ts — the down-detector behind "`:5173` stopped listening" (SPEC-ports-forward D8).
 *
 * The whole design is one rule: **a watched port must be continuously
 * absent-or-refused for {@link WATCH_DOWN_GRACE_MS} before anything is sent, and
 * a recovery inside that window cancels the pending alert and re-arms.** Without
 * it, "a build restarts its dev server ten times an hour" becomes ten
 * notifications an hour, and the feature gets muted on day one.
 *
 * Two more properties that keep it honest:
 *  - it only alerts about a port it has **seen up** (an alert says "it stopped",
 *    which presumes a start), so switching a watch on before starting the server
 *    is silent;
 *  - each outage produces **exactly one** alert, not one per scan tick.
 *
 * State only — no I/O, no timers of its own: it is driven by the scan cadence
 * that already exists (`observe` per snapshot), which is also why it needs no
 * cleanup and cannot leak a timer.
 */

import type { PortDTO } from "../protocol.js";
import { isWatched, type WatchedPort } from "./watch_store.js";

/**
 * How long a watched port must stay down before makit says so. 20 s ≈ five scan
 * ticks: long enough to ride out a dev-server restart, a rebuild, or a moment of
 * `lsof` blindness; short enough that the alert still arrives while the user
 * could plausibly do something about it.
 */
export const WATCH_DOWN_GRACE_MS = 20_000;

export interface PortDownDetectorDeps {
  now: () => number;
  /** Fired ONCE per outage, after the grace window. Must not throw. */
  onDown: (port: WatchedPort) => void;
}

/** Per-endpoint tracking state. */
interface Track {
  /** True once this endpoint has been seen serving — an alert presumes a start. */
  seenUp: boolean;
  /** Epoch ms of the first tick that saw it down; undefined while it is up. */
  downSince?: number;
  /** True once this outage has been reported, so it reports only once. */
  notified: boolean;
}

/** `(worktreePath, port)` — the identity D7 fixes, never the snapshot key. */
function keyOf(port: WatchedPort): string {
  return `${port.worktreePath}\u0000${port.port}`;
}

export class PortDownDetector {
  private readonly tracks = new Map<string, Track>();

  constructor(private readonly deps: PortDownDetectorDeps) {}

  /**
   * Feed one snapshot. `ports` is the scan's port list, `watched` the current
   * watch list — passed in per call so toggling a watch takes effect on the very
   * next scan, and un-watching mid-outage cancels the pending alert.
   */
  observe(ports: PortDTO[], watched: WatchedPort[]): void {
    // Drop tracking for anything no longer watched: this is what makes
    // "Ignore this port" (D9) instant, and keeps the map bounded by the watch
    // list rather than by everything that has ever been watched.
    const live = new Set(watched.map(keyOf));
    for (const key of [...this.tracks.keys()]) {
      if (!live.has(key)) this.tracks.delete(key);
    }
    if (watched.length === 0) return;

    for (const target of watched) {
      const key = keyOf(target);
      const track = this.tracks.get(key) ?? { seenUp: false, notified: false };
      this.tracks.set(key, track);

      if (this.isServing(ports, target)) {
        track.seenUp = true;
        // Recovery: forget the outage entirely, so the next one gets a full
        // window and its own alert.
        delete track.downSince;
        track.notified = false;
        continue;
      }

      // Down (absent, or bound but refusing — a crashed server holding its
      // socket is exactly what someone watching wants to hear about).
      if (!track.seenUp) continue;
      const now = this.deps.now();
      track.downSince ??= now;
      if (!track.notified && now - track.downSince >= WATCH_DOWN_GRACE_MS) {
        track.notified = true;
        this.deps.onDown({ worktreePath: target.worktreePath, port: target.port });
      }
    }
  }

  /** Whether this watched endpoint is present AND not refusing connections. */
  private isServing(ports: PortDTO[], target: WatchedPort): boolean {
    return ports.some((p) => {
      if (p.port !== target.port) return false;
      if (!isWatched([target], p.worktreePath, p.port)) return false;
      // `refused`/`timeout` mean "bound but unusable" — the same verdicts the UI
      // paints as an error, so they are not "serving".
      return p.health?.kind !== "refused" && p.health?.kind !== "timeout";
    });
  }
}
