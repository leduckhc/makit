/**
 * forward_eligibility — may this port be forwarded to a phone? (SPEC-44 D4/D6)
 *
 * Pure and separate from the grant store for the same reason `kill.ts` is
 * separate from the signal: this is the security decision, and it should be
 * reviewable and testable without a socket in sight.
 *
 * Every rule answers a concrete failure:
 *  - **loopback only** — an `exposed`/`tailnet` port is already reachable, so
 *    forwarding it is pointless *and* would suggest makit had made it reachable.
 *  - **owned by a worktree** — the same trust boundary the kill whitelist draws;
 *    forwarding something unattributed is forwarding a stranger's service.
 *  - **spoke HTTP** — the proxy is an HTTP proxy. A port that never answered a
 *    probe is guaranteed-broken behind it, so it is refused rather than
 *    half-working.
 *  - **not makit itself** — proxying our own listener is a loop.
 *  - **not a database port** — the deny-listed services are exactly the "assumed
 *    loopback-only, no auth of its own" case the threat model is about (D6).
 */

import type { PortDTO } from "../protocol.js";
import { NO_HTTP_PROBE_PORTS } from "./health.js";

/** Why a forward was refused. One sentence per reason, shown verbatim. */
export type ForwardRefusal =
  | "not_found"
  | "not_loopback"
  | "not_owned"
  | "no_http"
  | "is_makit"
  | "protected_service";

export interface ForwardEligibility {
  ok: boolean;
  refusal?: ForwardRefusal;
  port?: PortDTO;
}

/** Human sentence for a refusal — the app shows this, so it must be specific. */
export function forwardRefusalMessage(refusal: ForwardRefusal): string {
  switch (refusal) {
    case "not_found":
      return "that port is not listening any more";
    case "not_loopback":
      return "that port is already reachable off this machine — no forward needed";
    case "not_owned":
      return "that port belongs to no worktree, so makit will not forward it";
    case "no_http":
      return "that port never answered HTTP, and the forward only proxies HTTP";
    case "is_makit":
      return "that is makit's own listener";
    case "protected_service":
      return "database and shell ports are never forwarded";
  }
}

/**
 * Decide whether `(worktreePath, port)` from the client may be forwarded, against
 * the CURRENT snapshot. Rules are checked in order; the first that fires wins.
 */
export function classifyForward({
  worktreePath,
  port,
  ports,
  serverPort,
}: {
  worktreePath: string;
  port: number;
  ports: PortDTO[];
  /** makit's own listening port. */
  serverPort: number;
}): ForwardEligibility {
  const match = ports.find((p) => p.port === port && p.worktreePath === worktreePath);
  // Checked before ownership so a stale row reads as "gone", not "not yours".
  if (match === undefined) {
    const anywhere = ports.find((p) => p.port === port);
    if (anywhere === undefined) return { ok: false, refusal: "not_found" };
    return { ok: false, refusal: "not_owned" };
  }
  if (port === serverPort) return { ok: false, refusal: "is_makit" };
  if (NO_HTTP_PROBE_PORTS.includes(port)) return { ok: false, refusal: "protected_service" };
  if (match.reach !== "loopback") return { ok: false, refusal: "not_loopback" };
  // `openUrl` is present only when something actually answered HTTP under the
  // SPEC-41 probe, which makes it the exact "is this proxyable" signal.
  if (match.openUrl === undefined) return { ok: false, refusal: "no_http" };
  return { ok: true, port: match };
}
