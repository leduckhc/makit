/**
 * makit — SPEC-doc-preview D9: publication grants for the static doc route.
 *
 * A grant is the capability to fetch one published document over `/docs/<grantId>/…`.
 * Same shape discipline as SPEC-ports-forward's forward grant: in-memory only (never
 * survives a restart), keyed by an unguessable 32-byte CSPRNG id, hard-capped by
 * a 30-minute TTL, reaped when idle, revocable, and enumerable in one place so
 * the app can say "3 docs are shared".
 *
 * Reaping is lazy: `resolve`/`list` drop expired grants on the way through, so
 * there is no timer to leak. `resolve` also *touches* the grant — a doc that is
 * still being fetched keeps its idle window alive; one no one has opened for
 * {@link DOC_GRANT_IDLE_MS} falls away on its own, and the hard TTL bounds it
 * regardless.
 */

import { randomBytes as cryptoRandomBytes } from "node:crypto";

import type { DocGrantDTO } from "../protocol.js";

/** Hard cap from creation. What `expiresAt` reports; a touch never extends it. */
export const DOC_GRANT_TTL_MS = 30 * 60_000;

/**
 * Idle window: a published doc unfetched for this long is reaped early, so the
 * shared-docs list reflects what is actually in use rather than every doc ever
 * published in the last half hour. Shorter than the TTL so the two are distinct
 * reasons a grant can end.
 */
export const DOC_GRANT_IDLE_MS = 10 * 60_000;

/**
 * Ceiling on simultaneously-published documents. Generous for the human use case
 * ("3 docs are currently shared") and small enough that a runaway publish loop
 * cannot grow the map without bound.
 */
export const MAX_LIVE_GRANTS = 64;

interface DocGrant extends DocGrantDTO {
  createdAt: number;
  lastSeenAt: number;
  /** Minting device (SPEC-ports-forward owner model). Never projected onto the wire DTO. */
  ownerDeviceId?: string;
}

export interface MintInput {
  worktreePath: string;
  relPath: string;
  reach: "tailnet" | "lan";
  /**
   * The device that minted the grant, so `revoke`/`listOwnedBy` can scope by
   * owner (SPEC-ports-forward's forward-grant model). Undefined only under `--no-auth`
   * loopback, where there is a single anonymous owner.
   */
  ownerDeviceId?: string;
  /** Builds the URL from the freshly-minted id — the capability lives in the path (D9). */
  buildUrl: (grantId: string) => string;
}

export interface DocGrantStoreDeps {
  now?: () => number;
  /** Injected for tests; defaults to `crypto.randomBytes`. */
  randomBytes?: (size: number) => Buffer;
}

export class DocGrantStore {
  private readonly grants = new Map<string, DocGrant>();
  private readonly now: () => number;
  private readonly randomBytes: (size: number) => Buffer;

  constructor(deps: DocGrantStoreDeps = {}) {
    this.now = deps.now ?? Date.now;
    this.randomBytes = deps.randomBytes ?? cryptoRandomBytes;
  }

  /**
   * Mint a grant for one document and return its public DTO.
   *
   * Reaps expired grants first, then enforces {@link MAX_LIVE_GRANTS}. Reaping is
   * otherwise lazy (it happens inside `resolve`/`list`), so without this a
   * publish loop could grow the map unboundedly between reads — each entry
   * holding a path and keeping the doc listener alive.
   */
  mint(input: MintInput): DocGrantDTO {
    const now = this.now();
    this.reap(now);
    if (this.grants.size >= MAX_LIVE_GRANTS) {
      // Evict the least recently used: a share nobody has fetched in the longest
      // time is the one whose loss is least surprising.
      const oldest = [...this.grants.values()].reduce((a, b) =>
        a.lastSeenAt <= b.lastSeenAt ? a : b,
      );
      this.grants.delete(oldest.grantId);
    }
    const grantId = this.randomBytes(32).toString("hex");
    const grant: DocGrant = {
      grantId,
      worktreePath: input.worktreePath,
      relPath: input.relPath,
      url: input.buildUrl(grantId),
      reach: input.reach,
      expiresAt: now + DOC_GRANT_TTL_MS,
      createdAt: now,
      lastSeenAt: now,
      ownerDeviceId: input.ownerDeviceId,
    };
    this.grants.set(grantId, grant);
    return toDto(grant);
  }

  /**
   * The live grant for `grantId`, or undefined when it is unknown, expired, or
   * idle-reaped. On a hit it touches the idle clock (the request heartbeat).
   * The route turns undefined into a 404 — never a 403, so existence is not
   * confirmed.
   */
  resolve(grantId: string): DocGrantDTO | undefined {
    const now = this.now();
    const grant = this.grants.get(grantId);
    if (grant === undefined || this.reapable(grant, now)) {
      if (grant !== undefined) this.grants.delete(grantId);
      return undefined;
    }
    grant.lastSeenAt = now;
    return toDto(grant);
  }

  /**
   * Revoke a grant the caller owns. Returns true only when a grant was actually
   * removed. A grant owned by a DIFFERENT device is left untouched and reports
   * `false` — the SAME answer an unknown id gives, so the result cannot be used
   * to probe whether some other device's grant id exists.
   */
  revoke(grantId: string, ownerDeviceId?: string): boolean {
    const grant = this.grants.get(grantId);
    if (grant === undefined) return false;
    if (grant.ownerDeviceId !== ownerDeviceId) return false;
    return this.grants.delete(grantId);
  }

  /** The live grants as DTOs, reaping expired/idle ones on the way through. */
  list(): DocGrantDTO[] {
    const now = this.now();
    this.reap(now);
    return [...this.grants.values()].map(toDto);
  }

  /**
   * The live grants minted by one device, as DTOs (reaping on the way through).
   * The command layer uses this so a client only ever sees — and can only revoke
   * — its own shares, never another device's.
   */
  listOwnedBy(ownerDeviceId?: string): DocGrantDTO[] {
    const now = this.now();
    this.reap(now);
    return [...this.grants.values()]
      .filter((g) => g.ownerDeviceId === ownerDeviceId)
      .map(toDto);
  }

  /** Drop every expired or idle-reaped grant. Shared by `list` and `mint`. */
  private reap(now: number): void {
    for (const [grantId, grant] of this.grants) {
      if (this.reapable(grant, now)) this.grants.delete(grantId);
    }
  }

  private reapable(grant: DocGrant, now: number): boolean {
    return now >= grant.expiresAt || now - grant.lastSeenAt >= DOC_GRANT_IDLE_MS;
  }
}

/** Project the internal record to the wire DTO — no `createdAt`/`lastSeenAt`. */
function toDto(grant: DocGrant): DocGrantDTO {
  return {
    grantId: grant.grantId,
    worktreePath: grant.worktreePath,
    relPath: grant.relPath,
    url: grant.url,
    reach: grant.reach,
    expiresAt: grant.expiresAt,
  };
}
