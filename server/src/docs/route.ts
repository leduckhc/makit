/**
 * makit — SPEC-46 D9/D10: the static doc route, `GET`/`HEAD /docs/<grantId>/<relPath>`.
 *
 * Installed on the separate plain-HTTP doc listener (D10), never the pinned
 * WSS listener. There is NO bearer: a URL that must open in Safari cannot carry
 * an `Authorization` header, so the unguessable `grantId` in the path IS the
 * capability. The route builds no path itself — every candidate goes through
 * {@link resolveDocPath}, the one boundary it shares with `docs.read`, so the two
 * cannot disagree about what is servable.
 *
 * Every refusal is a **404, never a 403**: a wrong, unknown, expired, or
 * traversing request must not confirm that anything exists. The grant is scoped
 * to exactly one document, so a valid grant pointed at a different relPath is
 * also a 404.
 */

import { createReadStream } from "node:fs";
import type { IncomingMessage, Server, ServerResponse } from "node:http";

import { log } from "../log.js";
import { resolveDocPath, type DocKind } from "./resolve.js";
import type { DocGrantStore } from "./grants.js";

const DOCS_PREFIX = "/docs/";

const CONTENT_TYPE: Record<DocKind, string> = {
  md: "text/markdown; charset=utf-8",
  html: "text/html; charset=utf-8",
};

export interface DocRouteDeps {
  grants: DocGrantStore;
}

/**
 * Install the doc handler on `server`. Only touches `/docs/…`; anything else is
 * left for another `request` listener, so a harness fallthrough must scope
 * itself the same way or it wins the race against this handler.
 */
export function attachDocRoute(server: Server, deps: DocRouteDeps): void {
  server.on("request", (req, res) => {
    const path = (req.url ?? "").split("?")[0] ?? "";
    if (!path.startsWith(DOCS_PREFIX)) return; // not ours — leave it alone
    try {
      handle(req, res, deps);
    } catch (err) {
      log.error(`[makit] doc route failed: ${(err as Error).message}`);
      if (!res.headersSent) notFound(res);
    }
  });
}

function handle(req: IncomingMessage, res: ServerResponse, deps: DocRouteDeps): void {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD" });
    res.end();
    return;
  }

  // `/docs/<grantId>/<relPath…>` — split off the grant, keep the rest as the path.
  const rest = (req.url ?? "").split("?")[0]!.slice(DOCS_PREFIX.length);
  const slash = rest.indexOf("/");
  if (slash <= 0) {
    notFound(res);
    return;
  }
  const grantId = rest.slice(0, slash);
  let relPath: string;
  try {
    relPath = decodeURIComponent(rest.slice(slash + 1));
  } catch {
    notFound(res); // malformed percent-encoding is not a served path
    return;
  }

  // Unknown / expired / idle-reaped grant → 404 (touches the idle clock on a hit).
  const grant = deps.grants.resolve(grantId);
  if (grant === undefined) {
    notFound(res);
    return;
  }

  // The one boundary: resolve+validate through the shared function. A traversal,
  // a dotfile, a disallowed extension, an oversize file — all become 404 here.
  const resolved = resolveDocPath(grant.worktreePath, relPath);
  // The grant is scoped to exactly one document; a valid grant aimed at any
  // other file is refused, not served.
  if (!resolved.ok || resolved.relPath !== grant.relPath) {
    notFound(res);
    return;
  }

  res.writeHead(200, {
    "Content-Type": CONTENT_TYPE[resolved.kind],
    "Content-Length": String(resolved.bytes),
    // A published doc is a live artefact of a branch; never let it be cached as
    // if it were immutable content-addressed media.
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  if (req.method === "HEAD") {
    res.end();
    return;
  }

  const stream = createReadStream(resolved.absPath);
  stream.on("error", () => res.destroy());
  res.on("close", () => stream.destroy());
  stream.pipe(res);
}

/** Plain 404 — never confirms existence, never a 403. */
function notFound(res: ServerResponse): void {
  const body = JSON.stringify({ error: "not_found" });
  res.writeHead(404, {
    "Content-Type": "application/json",
    "Content-Length": String(Buffer.byteLength(body)),
  });
  res.end(body);
}

/**
 * Terminate any request {@link attachDocRoute} chose not to answer.
 *
 * `attachDocRoute` ignores non-`/docs/` paths on purpose, so it can share a
 * listener and so a test harness can own other paths. The doc listener in
 * `server.ts` is **dedicated**, though: nothing else is attached, so without a
 * terminator an unmatched request gets no response at all and the socket hangs
 * until Node's 60 s headers timeout. Safari asks for `/favicon.ico` on every
 * visit and the listener is bound to a routable address, so that is a free
 * socket-exhaustion vector. Attach this LAST, only on a dedicated listener.
 */
export function attachDocNotFound(server: Server): void {
  server.on("request", (_req, res) => {
    // The doc route answers synchronously, so anything still unanswered here is
    // genuinely unmatched — this cannot race ahead of a real reply.
    if (res.headersSent || res.writableEnded) return;
    notFound(res);
  });
}
