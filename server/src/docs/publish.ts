/**
 * makit — SPEC-46 D10/D15: publish one document and produce a URL that works.
 *
 * `publishDoc` validates the document through {@link resolveDocPath} (the same
 * boundary the route uses), then asks an injected `reach()` for a **verified**
 * reachable origin fronting the doc listener. It mints a grant only when there
 * is somewhere real to serve from.
 *
 * Degrade loudly (D15): `reach()` returns a verified origin for the doc
 * listener, or `null` when there is no usable address — in which case we publish
 * NOTHING and hand back a stated reason. `reach` is never invented: it reflects
 * what actually bound, so a publish button can never yield a dead URL.
 */

import { resolveDocPath, type DocPathResult } from "./resolve.js";
import type { DocGrantStore } from "./grants.js";
import type { DocGrantDTO } from "../protocol.js";

/** A verified origin that fronts the doc listener, plus how it was reached. */
export interface DocReach {
  /**
   * No trailing slash. `DocListener` builds this as `http://<bindHost>:<port>`
   * from the tailnet IP it bound to — plain HTTP is deliberate (D10 rev 2):
   * WireGuard already encrypts the tailnet, and a self-signed cert would make
   * the URL unopenable in Safari. So in P1 this is always e.g.
   * `http://100.92.14.7:53187`, never an `https://` MagicDNS origin.
   */
  origin: string;
  /**
   * How the origin is reachable. Per D15 rev 2 the tailnet is the ONLY reach
   * `DocListener` ever produces in P1; `"lan"` is retained in the union (and
   * mintable if a caller injects it) purely so the wire contract and the app's
   * pills need no change if LAN is ever reinstated behind an explicit opt-in.
   */
  reach: "tailnet" | "lan";
}

export interface PublishDeps {
  grants: DocGrantStore;
  /**
   * Establish (or reuse) a verified reachable origin for the doc listener, or
   * `null` when there is no usable address (publish nothing). Only consulted
   * once the document has been validated.
   */
  reach: () => Promise<DocReach | null>;
  /** Injected for tests; defaults to {@link resolveDocPath}. */
  resolveDoc?: (worktreeRoot: string, relPath: string) => DocPathResult;
}

export type PublishResult = { ok: true; grant: DocGrantDTO } | { ok: false; reason: string };

export async function publishDoc(
  input: { worktreePath: string; relPath: string; ownerDeviceId?: string },
  deps: PublishDeps,
): Promise<PublishResult> {
  const resolveDoc = deps.resolveDoc ?? resolveDocPath;

  const resolved = resolveDoc(input.worktreePath, input.relPath);
  if (!resolved.ok) {
    return { ok: false, reason: `cannot publish ${input.relPath}: ${resolved.reason}` };
  }

  // Only now probe reachability — an invalid doc must never spawn `tailscale`.
  // A probe that throws (bind failure, spawn error) is a refusal with a reason,
  // not an unhandled rejection escaping into the command router.
  let reach: DocReach | null;
  try {
    reach = await deps.reach();
  } catch (err) {
    return { ok: false, reason: `could not establish a reachable address: ${(err as Error).message}` };
  }
  if (reach === null) {
    return {
      ok: false,
      reason:
        "no reachable address: makit is loopback-only. Start Tailscale and try again.",
    };
  }
  // Bind the narrowed value to a `const` so the `buildUrl` closure below does not
  // rely on TS's version-specific narrowing of a `let` captured after its last
  // assignment.
  const reached = reach;

  const relPath = resolved.relPath;
  const grant = deps.grants.mint({
    worktreePath: input.worktreePath,
    relPath,
    reach: reached.reach,
    ownerDeviceId: input.ownerDeviceId,
    buildUrl: (grantId) => `${reached.origin}/docs/${grantId}/${encodePath(relPath)}`,
  });
  return { ok: true, grant };
}

/**
 * Percent-encode each segment, keeping the separators. The URL is copied,
 * QR-encoded and opened in Safari, so a raw space is malformed and a raw `#` or
 * `?` would truncate the path — the route would then compare a different
 * relPath against the grant and answer 404 for a perfectly valid document.
 */
function encodePath(relPath: string): string {
  return relPath.split("/").map(encodeURIComponent).join("/");
}
