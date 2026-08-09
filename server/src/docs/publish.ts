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
  /** e.g. `https://host.ts.net` or `http://192.168.1.9:8123` — no trailing slash. */
  origin: string;
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
  input: { worktreePath: string; relPath: string },
  deps: PublishDeps,
): Promise<PublishResult> {
  const resolveDoc = deps.resolveDoc ?? resolveDocPath;

  const resolved = resolveDoc(input.worktreePath, input.relPath);
  if (!resolved.ok) {
    return { ok: false, reason: `cannot publish ${input.relPath}: ${resolved.reason}` };
  }

  // Only now probe reachability — an invalid doc must never spawn `tailscale`.
  const reach = await deps.reach();
  if (reach === null) {
    return {
      ok: false,
      reason:
        "no reachable address: makit is loopback-only. Start Tailscale (or pass --lan) and try again.",
    };
  }

  const relPath = resolved.relPath;
  const grant = deps.grants.mint({
    worktreePath: input.worktreePath,
    relPath,
    reach: reach.reach,
    buildUrl: (grantId) => `${reach.origin}/docs/${grantId}/${encodePath(relPath)}`,
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
