/**
 * Ports-domain `cmd` handlers — all six of them:
 *
 *  * `ports.watch {on}`                        SPEC-41: hold/release the scan
 *  * `ports.kill {address,port,pid,startedAt}` SPEC-43: terminate one listener
 *  * `ports.killOrphans`                       SPEC-43 P3b: every orphan
 *  * `ports.watchPort {worktreePath,port,on}`  SPEC-44 P4a: alert me if it stops
 *  * `ports.forward {worktreePath,port,browser?}` SPEC-44 P4b: mint a grant
 *  * `ports.forward.stop {grantId}`            SPEC-44 P4b: revoke one
 *
 * `ports.watch` mirrors `metrics.watch` exactly. Setting the flag changes the
 * port scanner's watcher count (a 4 s `lsof`/`ps` scan while any client watches,
 * nothing at all otherwise); on a false→true transition the client is handed the
 * cached snapshot once so a freshly-mounted list paints immediately, and the
 * service kicks off one immediate scan (armed inside
 * `onPortsWatchersChanged`). The flag is also cleared on socket close in
 * `server.ts` — a panel closed by killing the window never sends `{on:false}`,
 * and a leaked flag would poll `lsof` forever.
 *
 * `ports.kill` is the first place makit signals a process it did not spawn, so
 * this file's only job is to be a strict gate: it validates the four tuple
 * fields and hands them, unchanged, to the service that re-verifies them
 * (SPEC-43 D1). Nothing is coerced or defaulted — a defaulted `startedAt` would
 * silently disable the identity check the whole spec rests on.
 */

import type { PortKillTarget } from "../../protocol.js";
import { WireErrorCode } from "../../protocol/codec.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

/** Highest valid TCP port. */
const MAX_PORT = 65_535;

/** A real, finite, positive integer — a type predicate, so no cast follows it. */
function isPositiveInt(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v > 0;
}

/**
 * A usable TCP port number. Extracted because all three payload validators need
 * exactly this check, and each one previously repeated it and then cast.
 */
function isValidPort(v: unknown): v is number {
  return isPositiveInt(v) && v <= MAX_PORT;
}

/**
 * Read the kill tuple out of a `cmd` frame, or null when ANY field is missing or
 * not the right shape. Deliberately total and deliberately strict: this is the
 * only place a client's numbers become a signal target.
 */
export function parseKillTarget(env: Record<string, unknown>): PortKillTarget | null {
  const { address, port, pid, startedAt } = env as {
    address?: unknown;
    port?: unknown;
    pid?: unknown;
    startedAt?: unknown;
  };
  if (typeof address !== "string" || address.length === 0) return null;
  if (!isValidPort(port)) return null;
  if (!isPositiveInt(pid)) return null;
  // `startedAt` may legitimately be any epoch ms, but it must be a real finite
  // number: it is the field that makes pid reuse detectable (D1).
  if (typeof startedAt !== "number" || !Number.isFinite(startedAt)) return null;
  return { address, port, pid, startedAt };
}

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

  r.register("ports.kill", async (ctx) => {
    const target = parseKillTarget(ctx.env as unknown as Record<string, unknown>);
    // A malformed payload is the ONE case that is an error rather than an
    // outcome: there is no endpoint to report about.
    if (target === null) {
      ctx.err(
        WireErrorCode.BadRequest,
        "ports.kill needs {address, port, pid, startedAt} exactly as displayed",
      );
      return;
    }
    const result = await deps.killPort(target, ctx.client.deviceId);
    // Every refusal ACKS: the app renders a specific sentence per outcome, which
    // a generic `err` could not carry.
    ctx.ack({ ...result });
    // Only a kill that actually freed the endpoint changes what other clients
    // should see, so only that earns the extra scan.
    if (result.outcome === "released" || result.outcome === "force-killed") {
      deps.rescanPorts();
    }
  });

  r.register("ports.forward", async (ctx) => {
    const worktreePath = ctx.env.worktreePath;
    const port = ctx.env.port;
    if (typeof worktreePath !== "string" || worktreePath.length === 0 || !isValidPort(port)) {
      ctx.err(WireErrorCode.BadRequest, "ports.forward needs {worktreePath, port}");
      return;
    }
    // `browser:true` is the client saying "I will hand this to the system
    // browser", which is what makes the id a capability. Anything but a literal
    // true is the strict mode — a truthy string must not weaken a grant.
    const browser = ctx.env.browser === true;
    const result = await deps.forwardPort({ worktreePath, port, browser }, ctx.client.deviceId);
    // A refusal is an `err` here, not an outcome: unlike a kill there is nothing
    // to report about a grant that was never minted, and the reason IS the
    // message the sheet shows.
    if (result.grant === undefined) {
      ctx.err(WireErrorCode.BadRequest, result.refusal ?? "cannot forward that port");
      return;
    }
    ctx.ack({ grant: result.grant });
  });

  r.register("ports.forward.stop", async (ctx) => {
    const grantId = ctx.env.grantId;
    if (typeof grantId !== "string" || grantId.length === 0) {
      ctx.err(WireErrorCode.BadRequest, "ports.forward.stop needs {grantId}");
      return;
    }
    // Always acks: revoking something already gone (expired, idle-reaped, or a
    // duplicate Stop) is a success from the caller's point of view.
    deps.stopForward(grantId, ctx.client.deviceId);
    ctx.ack();
  });

  r.register("ports.watchPort", async (ctx) => {
    const worktreePath = ctx.env.worktreePath;
    const port = ctx.env.port;
    const on = ctx.env.on;
    // A malformed payload is a no-op with an error, never a coerced write: a
    // watch silently toggled the wrong way is a notification that never comes.
    if (
      typeof worktreePath !== "string" ||
      worktreePath.length === 0 ||
      !isValidPort(port) ||
      typeof on !== "boolean"
    ) {
      ctx.err(WireErrorCode.BadRequest, "ports.watchPort needs {worktreePath, port, on}");
      return;
    }
    deps.setWatchedPort({ worktreePath, port }, on);
    ctx.ack();
  });

  r.register("ports.killOrphans", async (ctx) => {
    // No payload at all: the orphan SET is the server's, derived from the fresh
    // scan (D5). A client cannot name the endpoints — which is also what keeps
    // this from becoming a way to kill an arbitrary list.
    const { results } = await deps.killOrphans();
    ctx.ack({ results });
    if (results.some((r) => r.outcome === "released" || r.outcome === "force-killed")) {
      deps.rescanPorts();
    }
  });
}
