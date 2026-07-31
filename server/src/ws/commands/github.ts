/**
 * GitHub-domain `cmd` handlers (SPEC-32 §6.6): manual budget refresh + pause.
 *
 * Both ack immediately, then mutate the gateway and re-broadcast the budget so
 * every connected client re-renders the footer. `github.refresh` hits the
 * quota-exempt `GET /rate_limit`, so it costs nothing; `github.pause` flips the
 * ladder to (or off) the paused rung.
 */

import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { gateway, broadcastBudget } = deps;

  r.register("github.refresh", async (ctx) => {
    ctx.ack();
    // `/rate_limit` is quota-exempt (spec §4), so this read is free.
    await gateway.refresh();
    broadcastBudget();
  });

  r.register("github.pause", async (ctx) => {
    ctx.ack();
    const paused = ctx.env.paused === true;
    gateway.setPaused(paused);
    broadcastBudget();
  });
}
