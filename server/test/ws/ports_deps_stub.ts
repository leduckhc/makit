/**
 * Shared stubs for the ports-domain `CommandDeps` members (SPEC-ports-kill/44).
 *
 * Four `CommandRouter` harnesses need these six functions only so the object
 * satisfies `CommandDeps`; none of them exercises ports. Extracted so a signature
 * change breaks ONE place instead of drifting silently in four — the harnesses
 * end with `as unknown as CommandDeps`, which type-checks nothing.
 *
 * `satisfies` is the load-bearing word: it checks every member against
 * `CommandDeps` while keeping the object usable in a spread.
 */

import type { CommandDeps } from "../../src/ws/commands/deps.js";

/** No-op ports deps: refuse everything, record nothing, signal nothing. */
export const portsDepsStub = {
  killPort: async (target: { address: string; port: number }) => ({
    outcome: "not_found" as const,
    address: target.address,
    port: target.port,
  }),
  killOrphans: async () => ({ results: [] }),
  rescanPorts: () => {},
  setWatchedPort: () => {},
  forwardPort: async () => ({ refusal: "ports are not part of this harness" }),
  stopForward: () => {},
} satisfies Pick<
  CommandDeps,
  "killPort" | "killOrphans" | "rescanPorts" | "setWatchedPort" | "forwardPort" | "stopForward"
>;
