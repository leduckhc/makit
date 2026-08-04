/**
 * Metrics-domain `cmd` handler (SPEC-37): `metrics.watch {on}`.
 *
 * Mirrors `github.refresh`/`github.pause` rather than overloading the
 * session-scoped `sub` flag (spec decision 7). Setting the flag changes the
 * collector's watcher count (1 Hz while any client watches, 5 s otherwise); on
 * `{on:true}` the client is handed the ring history once so a freshly-opened
 * panel draws a populated chart immediately. The flag is also cleared on socket
 * close in `server.ts` — a panel closed by killing the window never sends
 * `{on:false}`, and a leaked flag would pin the collector at 1 Hz forever.
 */

import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  r.register("metrics.watch", async (ctx) => {
    ctx.ack();
    const on = ctx.env.on === true;
    const wasWatching = ctx.client.watchingMetrics;
    ctx.client.watchingMetrics = on;
    deps.onMetricsWatchersChanged();
    // History only on a false -> true transition. A client that re-sends {on:true}
    // (a rebuild, a reconnect handler firing twice) would otherwise be shipped up
    // to 30 minutes of samples again on every repeat.
    if (on && !wasWatching) deps.sendMetricsHistory(ctx.client);
  });
}
