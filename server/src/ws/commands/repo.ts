/**
 * Repo-domain `cmd` handlers (SPEC-decomposition-and-dedup, moved verbatim from server.ts's
 * `buildCommandRouter`): repo.refresh.
 */

import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { broadcastReposSnapshot } = deps;

  r.register("repo.refresh", async (ctx) => {
    ctx.ack();
    await broadcastReposSnapshot();
  });
}
