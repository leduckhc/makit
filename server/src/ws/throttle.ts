/**
 * throttleTrailing — rate-limit a zero-arg function to at most one call per
 * `intervalMs`, firing immediately on the leading edge and coalescing any
 * calls made during the interval into ONE trailing call.
 *
 * Used to keep per-event broadcast work (e.g. the sessions snapshot, which
 * re-encodes every session DTO for every client) off the hot streaming path:
 * a burst of agent deltas produces one leading + one trailing snapshot instead
 * of one per delta, and the trailing call guarantees the final state is sent.
 */
export function throttleTrailing(fn: () => void, intervalMs: number): () => void {
  let timer: NodeJS.Timeout | undefined;
  let lastRun = -Infinity;
  return () => {
    if (timer) return; // a trailing call is already scheduled
    const elapsed = Date.now() - lastRun;
    if (elapsed >= intervalMs) {
      lastRun = Date.now();
      fn();
      return;
    }
    timer = setTimeout(() => {
      timer = undefined;
      lastRun = Date.now();
      fn();
    }, intervalMs - elapsed);
    // Never keep the process alive just for a pending snapshot.
    timer.unref?.();
  };
}
