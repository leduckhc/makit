/**
 * Bounded waits on an agent, shared by the adapters and the manager.
 *
 * Extracted from `codex.ts` when `AgentAdapter.close()` landed: every wait on an
 * agent must be bounded. An unbounded one turns "release then reap" into "hang
 * forever and never reap" — precisely the RSS leak the close path exists to fix,
 * in the one case that matters most, since a wedged agent is the one that needs
 * killing.
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
