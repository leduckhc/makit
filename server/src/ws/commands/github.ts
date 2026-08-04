/**
 * GitHub-domain `cmd` handlers (SPEC-32 §6.6): manual budget refresh, pause, and
 * the foreground watch.
 *
 * `github.refresh` and `github.pause` ack immediately, then mutate the gateway
 * and re-broadcast the budget so every connected client re-renders the footer:
 * refresh hits the quota-exempt `GET /rate_limit`, so it costs nothing; pause
 * flips the ladder to (or off) the paused rung.
 *
 * `github.watch` touches neither. It only adds or removes this client from
 * {@link CommandDeps.budgetWatch}, recording whether it has the panel open —
 * which is what licenses the faster read cadence. Any snapshot that follows is
 * the watch loop's own doing, not this handler's.
 */

import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { gateway, broadcastBudget, budgetWatch } = deps;

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

  // The panel opened/closed. Only a *visible* panel justifies the fast loop: the
  // reads spend no quota but do cost a `gh` subprocess each, and an idle footer
  // has nobody to show the moving numbers to.
  r.register("github.watch", (ctx) => {
    ctx.ack();
    if (ctx.env.watching === true) budgetWatch.add(ctx.client);
    else budgetWatch.remove(ctx.client);
  });
}
