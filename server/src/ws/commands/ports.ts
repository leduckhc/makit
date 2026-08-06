/**
 * Ports-domain `cmd` handler (SPEC-41): `ports.watch {on}`.
 *
 * Mirrors `metrics.watch` exactly. Setting the flag changes the port scanner's
 * watcher count (a 4 s `lsof`/`ps` scan while any client watches, nothing at
 * all otherwise); on a false→true transition the client is handed the cached
 * snapshot once so a freshly-mounted list paints immediately, and the service
 * kicks off one immediate scan (armed inside `onPortsWatchersChanged`). The
 * flag is also cleared on socket close in `server.ts` — a panel closed by
 * killing the window never sends `{on:false}`, and a leaked flag would poll
 * `lsof` forever.
 */

import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  r.register("ports.watch", async (ctx) => {
    ctx.ack();
    // A malformed payload is a NO-OP (plan T8): only a real boolean toggles the
    // flag. Coercing a non-boolean to `false` would let `{on:"yes"}` silently
    // turn a watching client OFF and disarm the scanner — leave it untouched.
    const on = ctx.env.on;
    if (typeof on !== "boolean") return;
    const wasWatching = ctx.client.watchingPorts === true;
    ctx.client.watchingPorts = on;
    deps.onPortsWatchersChanged();
    // Cached snapshot only on a false → true transition. A client that re-sends
    // {on:true} (a rebuild, a reconnect handler firing twice) must NOT re-send
    // the snapshot or re-trigger a scan.
    if (on && !wasWatching) deps.sendPortsSnapshot(ctx.client);
  });
}
