/**
 * forward_route — authenticated HTTP proxy for a forwarded loopback port
 * (SPEC-ports-forward D1/D5).
 *
 * This is `media/route.ts` again, not a new transport: one more `request`
 * listener on the HTTPS listener(s) that already carry the WebSocket, gated by
 * the same paired-device bearer and the same `trustLoopback` dev carve-out.
 * `request` and `upgrade` are separate events, so installing it cannot disturb
 * the `noServer` WS forwarding.
 *
 * Why not a multiplexed byte stream inside the WS frame protocol (as the mockup
 * guessed): `codec.ts` is a *message* protocol. Reimplementing request/response
 * framing, half-close and backpressure inside it would be reinventing HTTP
 * badly, while Node pipes streaming bodies and arbitrary verbs natively. Both
 * designs open **no new host port** — this route runs on an already-bound
 * listener and dials the dev server with an *outbound* loopback socket.
 *
 * Two rules that keep the proxy honest rather than magic:
 *  - **The HMR WebSocket is refused (426), never half-proxied.** Vite/webpack
 *    compute the HMR socket URL from `location`, so behind a proxy the client
 *    dials the wrong `ws://` and silently degrades. A loud refusal beats a
 *    mystery: the preview is a snapshot, and a refresh reloads it.
 *  - **`Location` and `Set-Cookie` are rewritten/stripped**, because the origin
 *    the phone sees is not the origin the dev server thinks it is.
 */

import { request as httpRequest } from "node:http";
import type { IncomingHttpHeaders, IncomingMessage, Server, ServerResponse } from "node:http";

import { log } from "../log.js";
import type { ForwardGrants } from "./forward_grants.js";

/** Path prefix this route owns: `/forward/<grantId>/<rest>`. */
export const FORWARD_PREFIX = "/forward/";

/** The registry slice the route needs (same shape the media route uses). */
export interface ForwardAuthRegistry {
  authenticate(bearer: string): { id: string; label: string } | null;
}

export interface ForwardRouteDeps {
  grants: ForwardGrants;
  registry: ForwardAuthRegistry;
  /** Mirror of the WS `trustLocalhost` rule; never widens beyond loopback. */
  trustLoopback?: boolean;
  /**
   * Device id to attribute a loopback dev-mode request to. Without it, a
   * `trustLoopback` caller has no identity and could not resolve its own grant.
   */
  loopbackDeviceId?: string;
}

/**
 * Hop-by-hop headers: meaningful only between two adjacent peers, so forwarding
 * them corrupts the next hop (RFC 9110 §7.6.1). `host` is dropped separately —
 * the upstream must see its own authority, not the phone's proxy origin.
 */
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "host",
  // Our own credential must never be forwarded to the dev server.
  "authorization",
]);

export function attachForwardRoute(server: Server, deps: ForwardRouteDeps): void {
  server.on("request", (req, res) => {
    const path = req.url?.split("?")[0] ?? "";
    if (!path.startsWith(FORWARD_PREFIX)) return; // not ours — leave it alone
    try {
      handle(req, res, deps);
    } catch (err) {
      log.error(`[makit] forward route failed: ${(err as Error).message}`);
      if (!res.headersSent) json(res, 500, "forward_failed");
    }
  });
}

function handle(req: IncomingMessage, res: ServerResponse, deps: ForwardRouteDeps): void {
  // D5: an upgrade attempt on a forwarded path is refused outright. A
  // half-working HMR socket is worse than none.
  if (typeof req.headers.upgrade === "string" && req.headers.upgrade.length > 0) {
    json(res, 426, "upgrade_not_supported");
    return;
  }

  const auth = authenticate(req, deps);
  // A bearer that was SUPPLIED and is wrong is a stale pairing — a different
  // fault from no bearer at all, and worth its own status.
  if (auth.kind === "invalid") {
    res.writeHead(401, { "WWW-Authenticate": "Bearer", "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  const parsed = splitPath(req.url ?? "");
  if (parsed === null) {
    json(res, 404, "not_found");
    return;
  }
  // `get` enforces the credential mode: a browser grant resolves on its id, a
  // strict one only for the device it was minted for.
  const grant = deps.grants.get(
    parsed.grantId,
    auth.kind === "device" ? auth.deviceId : undefined,
  );
  if (grant === null) {
    // 401 when the caller could have authenticated and did not AND the grant is
    // strict; 403 otherwise — the grant, not the resource, is what is gone.
    const strictExists = deps.grants.isStrict(parsed.grantId);
    if (auth.kind === "anonymous" && strictExists) {
      res.writeHead(401, { "WWW-Authenticate": "Bearer", "content-type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    json(res, 403, "no_such_grant");
    return;
  }

  const upstream = httpRequest(
    {
      host: "127.0.0.1",
      port: grant.port,
      method: req.method,
      path: parsed.rest,
      headers: forwardableHeaders(req.headers),
    },
    (up) => {
      res.writeHead(up.statusCode ?? 502, rewriteResponseHeaders(up.headers, grant.port, parsed.grantId));
      // Pipe, never buffer: a chunked or `text/event-stream` response must
      // stream through, exactly as the media GET streams a file.
      up.pipe(res);
    },
  );
  upstream.on("error", (err) => {
    // The dev server died or was never there — distinct from a missing grant.
    log.debug(`[ports] forward upstream :${grant.port} failed: ${err.message}`);
    if (!res.headersSent) json(res, 502, "upstream_unreachable");
    else res.end();
  });
  // Stream the request body too, so POST/PUT/PATCH work without a size cap here.
  req.pipe(upstream);
}

/**
 * How this request identified itself.
 *
 * A tagged union, NOT `string | "anonymous" | "invalid"`: those literals are
 * already members of `string`, so that type collapses and the compiler cannot
 * check a sentinel comparison — and a device whose id happened to be
 * `"anonymous"` would be mistaken for one. The tag makes both impossible.
 */
type CallerIdentity =
  /** A valid paired-device bearer. */
  | { kind: "device"; deviceId: string }
  /** No bearer at all — which is all a system browser can do. */
  | { kind: "anonymous" }
  /** A bearer that matches no paired device (a stale pairing). */
  | { kind: "invalid" };

function authenticate(req: IncomingMessage, deps: ForwardRouteDeps): CallerIdentity {
  const bearer = bearerOf(req);
  if (bearer !== undefined) {
    const device = deps.registry.authenticate(bearer);
    return device !== null ? { kind: "device", deviceId: device.id } : { kind: "invalid" };
  }
  const remote = req.socket.remoteAddress ?? "";
  const isLoopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
  if (deps.trustLoopback === true && isLoopback && deps.loopbackDeviceId !== undefined) {
    return { kind: "device", deviceId: deps.loopbackDeviceId };
  }
  return { kind: "anonymous" };
}

function bearerOf(req: IncomingMessage): string | undefined {
  const raw = req.headers.authorization;
  if (typeof raw !== "string") return undefined;
  return /^Bearer (.+)$/.exec(raw.trim())?.[1];
}

/** `/forward/<grantId>/rest?query` → `{grantId, rest: "/rest?query"}`. */
export function splitPath(url: string): { grantId: string; rest: string } | null {
  if (!url.startsWith(FORWARD_PREFIX)) return null;
  const after = url.slice(FORWARD_PREFIX.length);
  const slash = after.indexOf("/");
  const queryStart = after.indexOf("?");
  // `/forward/<id>` with no trailing slash still means the upstream root.
  if (slash < 0) {
    const grantId = queryStart < 0 ? after : after.slice(0, queryStart);
    if (grantId.length === 0) return null;
    return { grantId, rest: queryStart < 0 ? "/" : `/${after.slice(queryStart)}` };
  }
  const grantId = after.slice(0, slash);
  if (grantId.length === 0) return null;
  return { grantId, rest: after.slice(slash) };
}

function forwardableHeaders(headers: IncomingHttpHeaders): IncomingHttpHeaders {
  const out: IncomingHttpHeaders = {};
  for (const [name, value] of Object.entries(headers)) {
    if (HOP_BY_HOP.has(name.toLowerCase())) continue;
    if (value !== undefined) out[name] = value;
  }
  return out;
}

/**
 * Fix up the headers a dev server writes for its own origin:
 *  - a `Location` pointing at the target loopback `host:port` is rewritten onto
 *    the proxy path, so a redirect does not send the WebView to an address the
 *    phone cannot reach; any other absolute host passes through untouched.
 *  - `Set-Cookie` loses `Domain=` (it named the desktop's loopback) and
 *    `Secure` (the phone-side proxy origin is http-on-loopback), so a session
 *    cookie is not silently dropped.
 */
export function rewriteResponseHeaders(
  headers: IncomingHttpHeaders,
  targetPort: number,
  grantId: string,
): IncomingHttpHeaders {
  const out: IncomingHttpHeaders = {};
  for (const [name, value] of Object.entries(headers)) {
    const key = name.toLowerCase();
    if (HOP_BY_HOP.has(key) || value === undefined) continue;
    // Ours, not the dev server's: in browser mode the URL is the credential, so a
    // link to any external site would hand the grant over in `Referer`. An
    // upstream policy must not be able to loosen this, so it is dropped here and
    // set unconditionally below.
    if (key === "referrer-policy") continue;
    if (key === "location" && typeof value === "string") {
      out[name] = rewriteLocation(value, targetPort, grantId);
      continue;
    }
    if (key === "set-cookie") {
      const cookies = Array.isArray(value) ? value : [value];
      out[name] = cookies.map(stripCookieOrigin);
      continue;
    }
    out[name] = value;
  }
  out["referrer-policy"] = "no-referrer";
  return out;
}

function rewriteLocation(location: string, targetPort: number, grantId: string): string {
  for (const host of ["127.0.0.1", "localhost", "[::1]"]) {
    const origin = `http://${host}:${targetPort}`;
    if (location.startsWith(origin)) {
      const rest = location.slice(origin.length) || "/";
      return `${FORWARD_PREFIX}${grantId}${rest}`;
    }
  }
  return location;
}

function stripCookieOrigin(cookie: string): string {
  return cookie
    .split(";")
    .filter((part) => {
      const flag = part.trim().toLowerCase();
      return !flag.startsWith("domain=") && flag !== "secure";
    })
    .join(";");
}

function json(res: ServerResponse, status: number, error: string): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify({ error }));
}
