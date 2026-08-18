/**
 * forward_grants — who may proxy which loopback port, for how long (SPEC-ports-forward D3).
 *
 * A grant is **in-memory only**, keyed by an unguessable id, bound to ONE device
 * and ONE port, and dies three ways: an explicit `stop`, a hard TTL, or an idle
 * reap. Every one of those is deliberate:
 *
 *  - **In-memory** — a server restart proxies nothing. Resurrecting a tunnel the
 *    user has forgotten about would be strictly worse than a refused request.
 *  - **Not bound to a socket** — a WS reconnect must not kill a live preview.
 *  - **Hard TTL** (no extension on use) — "for 30 min" has to mean it, even for
 *    a browser tab that keeps polling.
 *  - **Idle reap** — "as long as the preview is open" is unobservable from the
 *    server; a browser keeps fetching after the user has moved on and a `stop`
 *    can be lost, so *activity* is the operational definition of "still open".
 *
 * Two credential modes, and the difference is recorded on the grant itself:
 *
 *  - **strict** (`browser:false`) — every request carries the paired-device
 *    bearer AND the grant must belong to that device. Used by anything that can
 *    set a header.
 *  - **browser** (`browser:true`) — the system browser cannot set a header, so
 *    the id in the path is the capability. Chosen deliberately when the user asks
 *    to open a preview in their own browser; the id is 32 random bytes, the TTL
 *    and idle reap are unchanged, and the proxy sends `Referrer-Policy:
 *    no-referrer` so the previewed page cannot leak the URL onward.
 */

import { randomBytes } from "node:crypto";

/** Hard cap on a forward's life, regardless of activity. */
export const FORWARD_TTL_MS = 30 * 60_000;

/** No proxied request for this long ⇒ the sheet is gone; reap the grant. */
export const FORWARD_IDLE_MS = 60_000;

/** What a forward grant records. */
export interface ForwardGrant {
  grantId: string;
  deviceId: string;
  port: number;
  /** The worktree that owned the port when the grant was minted (for auditing). */
  worktreePath: string;
  /**
   * True when this grant is used by the **system browser**, which cannot send an
   * `Authorization` header — so for these the unguessable id in the path IS the
   * capability, and any holder of the URL may use it until it expires.
   *
   * A recorded flag, not an inference from "no bearer arrived": the weaker mode
   * has to be a deliberate property of the grant, or a missing header would
   * silently downgrade a strict one.
   */
  browser: boolean;
  createdAt: number;
  expiresAt: number;
  /** Epoch ms of the last proxied request — drives the idle reap. */
  lastSeenAt: number;
}

export interface ForwardGrantsDeps {
  now: () => number;
}

export class ForwardGrants {
  private readonly byId = new Map<string, ForwardGrant>();

  constructor(private readonly deps: ForwardGrantsDeps) {}

  /** Live grant count (post-reap). Exposed for tests and diagnostics. */
  get size(): number {
    this.reap();
    return this.byId.size;
  }

  /** Mint a grant for one device + port. */
  mint({
    deviceId,
    port,
    worktreePath,
    browser = false,
  }: {
    deviceId: string;
    port: number;
    worktreePath: string;
    /** See {@link ForwardGrant.browser}. Defaults to the strict, bearer-bound mode. */
    browser?: boolean;
  }): ForwardGrant {
    this.reap();
    const now = this.deps.now();
    const grant: ForwardGrant = {
      // 32 bytes: in browser mode this id IS the credential, so it is sized to be
      // unguessable on its own, not merely unique.
      grantId: randomBytes(32).toString("base64url"),
      deviceId,
      port,
      worktreePath,
      browser,
      createdAt: now,
      expiresAt: now + FORWARD_TTL_MS,
      lastSeenAt: now,
    };
    this.byId.set(grant.grantId, grant);
    return grant;
  }

  /**
   * Resolve a grant for a request, refreshing its idle clock.
   *
   * A **browser** grant resolves for any caller (the id is the capability); a
   * strict grant requires the device it was minted for. Returns null for unknown,
   * expired, idle-reaped or foreign grants — the caller answers 403 for all of
   * them, because the *grant*, not the resource, is what is missing.
   */
  get(grantId: string, deviceId: string | undefined): ForwardGrant | null {
    if (grantId.length === 0) return null;
    const grant = this.byId.get(grantId);
    if (grant === undefined) return null;
    if (!grant.browser && (deviceId === undefined || grant.deviceId !== deviceId)) {
      return null;
    }
    const now = this.deps.now();
    if (this.isDead(grant, now)) {
      this.byId.delete(grantId);
      return null;
    }
    grant.lastSeenAt = now;
    return grant;
  }

  /** Revoke a grant. True when this device actually held it. */
  stop(grantId: string, deviceId: string | undefined): boolean {
    const grant = this.byId.get(grantId);
    if (grant === undefined || deviceId === undefined || grant.deviceId !== deviceId) {
      return false;
    }
    this.byId.delete(grantId);
    return true;
  }

  /** Drop every grant a device held — used when it unpairs (D3). */
  dropDevice(deviceId: string): void {
    for (const [id, grant] of this.byId) {
      if (grant.deviceId === deviceId) this.byId.delete(id);
    }
  }

  /**
   * Whether a live grant with this id exists and is in **strict** mode. Lets the
   * route answer 401 ("authenticate and retry") instead of 403 for a caller that
   * could have sent a bearer and did not — without leaking anything about ids
   * that do not exist.
   */
  isStrict(grantId: string): boolean {
    const grant = this.byId.get(grantId);
    if (grant === undefined) return false;
    return !grant.browser && !this.isDead(grant, this.deps.now());
  }

  /** Evict everything expired or idle, so the map is bounded by live previews. */
  reap(): void {
    const now = this.deps.now();
    for (const [id, grant] of this.byId) {
      if (this.isDead(grant, now)) this.byId.delete(id);
    }
  }

  private isDead(grant: ForwardGrant, now: number): boolean {
    return now > grant.expiresAt || now - grant.lastSeenAt > FORWARD_IDLE_MS;
  }
}
