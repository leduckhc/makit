/**
 * Deadline helpers shared by the adapters and the manager.
 *
 * Extracted from `codex.ts` when `AgentAdapter.close()` landed: a graceful
 * agent-side release is only ever best-effort, so every wait on an agent must be
 * bounded. An unbounded one turns "release then reap" into "hang forever and
 * never reap" — precisely the RSS leak the close path exists to fix, in the one
 * case that matters most (a wedged agent is the one that needs killing).
 */

/** Thrown when a bounded wait on an agent does not settle in time. */
export class RequestTimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RequestTimeoutError";
  }
}

/** Rejects with a labelled error when [p] doesn't settle within [ms]. */
export function withDeadline<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  const deadline = new Promise<T>((_, reject) => {
    timer = setTimeout(() => reject(new RequestTimeoutError(`${label} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([p, deadline]).finally(() => clearTimeout(timer));
}

/**
 * Await [p], but never for longer than [ms] and never throwing: on timeout or
 * rejection the reason is handed to [onGaveUp] and the call resolves anyway.
 *
 * For teardown steps that are courtesies rather than requirements — the caller
 * has a hard fallback (killing the process) that MUST still run.
 */
export async function bestEffort(
  p: () => Promise<void>,
  ms: number,
  label: string,
  onGaveUp: (why: string) => void,
): Promise<void> {
  try {
    await withDeadline(p(), ms, label);
  } catch (e) {
    onGaveUp(e instanceof Error ? e.message : String(e));
  }
}
