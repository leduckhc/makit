/**
 * The authenticated subject behind a WS connection (SPEC-cli-as-client D17).
 *
 * Before SPEC-cli-as-client an authed socket had a `deviceId` + `deviceLabel` and nothing
 * else, so every authed socket could dispatch every command and received every
 * session's events. That was correct while the only clients were the user's own
 * phone and desktop app; it stops being correct the moment an **agent** holds a
 * credential (D3), because an agent is not the user.
 *
 * A `Principal` is that subject, resolved once at `hello` and carried on the
 * client for the life of the socket. Two things read it:
 *
 *  1. the command router, which refuses a `cmd` outside the principal's
 *     capability map (see `capabilities.ts`), and
 *  2. event fanout, which must not mirror an unrelated session's transcript to a
 *     session-scoped principal.
 *
 * Both are needed. Enforcing only (1) would leave an agent token able to read
 * every session on the machine, because fanout is not a command — the same shape
 * of hole as `srv.response`, which is not a command either.
 */

import type { DeviceCap } from "../protocol.js";

export interface Principal {
  /** Registry id of the paired device, or the session id for an agent token. */
  readonly deviceId: string;
  /** Human label, for logs and `devices.list`. */
  readonly label: string;
  /**
   * What this credential may do. **Undefined means full access** — every device
   * paired before SPEC-cli-as-client has no `caps`, and must keep working untouched.
   */
  readonly caps?: readonly DeviceCap[];
  /**
   * Set only for an agent-scoped per-session token (D3): the session the token
   * was minted for. This is the anchor for D9's lineage derivation (the parent
   * of a spawn *is* this session) and for the fanout gate.
   */
  readonly sessionId?: string;
}

/**
 * True when the principal is unrestricted — i.e. it has no `caps` at all.
 *
 * Deliberately `undefined`-only, not "undefined or empty": an explicitly empty
 * array means "a credential that may do nothing", which is a revocation, not a
 * phone. Treating `[]` as full access would turn a mistake into a privilege
 * escalation.
 */
export function isFullAccess(principal: Principal | undefined): boolean {
  return principal === undefined || principal.caps === undefined;
}

/** True when the principal holds `cap` (or is unrestricted). */
export function hasCap(principal: Principal | undefined, cap: DeviceCap): boolean {
  if (isFullAccess(principal)) return true;
  return principal!.caps!.includes(cap);
}

/**
 * True when this principal is an agent-scoped token (D3) rather than a human
 * client. Used by D13(c) to refuse an `srv.response` from an agent — an agent
 * approving its own tool call is exactly the supervision gap the ladder exists
 * to close — and by `--yolo`, which only a human may set.
 */
export function isAgentScoped(principal: Principal | undefined): boolean {
  return principal?.sessionId !== undefined;
}
