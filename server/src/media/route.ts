/**
 * Media route — `GET`/`HEAD /media/<sha256>` and `POST /media` over the same
 * HTTPS listener(s) that carry the WS (SPEC-assistant-display-media for serving, SPEC-user-attachments for upload).
 *
 * Auth is the **paired-device bearer in an `Authorization` header**, verified
 * against the same {@link DeviceRegistry} the WS handshake uses. SPEC-assistant-display-media
 * originally proposed HMAC capability tokens in the query string plus a mint
 * RPC; that only exists to serve loaders that can't set headers. makit's app
 * fetches media through its own pinned `HttpClient`, so it *can* send a header
 * — which is both simpler and safer: no capability ends up in a URL that is
 * persisted in the replayed event log, screenshotted, or written to logs. The
 * upload verb inherits all of that unchanged, which is why it costs so little.
 *
 * The `GET` response is cacheable forever (`immutable`): the URL is a content
 * hash, so bytes for a given `mediaId` can never change.
 */

import { createReadStream } from "node:fs";
import type { IncomingMessage, Server, ServerResponse } from "node:http";

import { log } from "../log.js";
import { MEDIA_MIME_ALLOWLIST, type MediaStore } from "./store.js";

/** The slice of the device registry the route depends on. */
export interface MediaAuthRegistry {
  authenticate(bearer: string): { id: string; label: string } | null;
}

export interface MediaRouteDeps {
  store: MediaStore;
  registry: MediaAuthRegistry;
  /**
   * Mirror of the WS `trustLocalhost` rule (`server.ts`): in `--no-auth` dev
   * mode a loopback client has no bearer, so media would 401 while the socket
   * works. Never widens beyond loopback.
   */
  trustLoopback?: boolean;
}

const MEDIA_PREFIX = "/media/";
/** Upload target. Exactly `/media` — `/media/<id>` is the per-blob resource. */
const MEDIA_UPLOAD_PATH = "/media";

/**
 * Install the media handler on `server`. Safe to call on several listeners
 * (external + loopback) with the same deps — media must be reachable on both,
 * or the dev/loopback path serves nothing. Adding a `request` listener does not
 * disturb the `noServer` WS upgrade forwarding: `upgrade` and `request` are
 * separate events.
 */
export function attachMediaRoute(server: Server, deps: MediaRouteDeps): void {
  server.on("request", (req, res) => {
    const path = req.url?.split("?")[0] ?? "";
    if (path === MEDIA_UPLOAD_PATH) {
      try {
        handleUpload(req, res, deps);
      } catch (err) {
        log.error(`[makit] media upload failed: ${(err as Error).message}`);
        if (!res.headersSent) status(res, 500, "upload_failed");
      }
      return;
    }
    if (!req.url?.startsWith(MEDIA_PREFIX)) return; // not ours — leave it alone
    try {
      handle(req, res, deps);
    } catch (err) {
      log.error(`[makit] media route failed: ${(err as Error).message}`);
      if (!res.headersSent) notFound(res);
    }
  });
}

/**
 * `POST /media` — store one blob, return its descriptor (SPEC-user-attachments §3.1).
 *
 * Ordering is the whole point of this function: **authenticate, then check the
 * declared size and mime, and only then read a byte of body.** An
 * unauthenticated or unstorable request must never cause an allocation. The
 * declared `Content-Length` is not trusted either — the running total is checked
 * per chunk, so a sender that lies about its length is destroyed mid-stream
 * rather than admitted under a length it then exceeds.
 */
function handleUpload(req: IncomingMessage, res: ServerResponse, deps: MediaRouteDeps): void {
  if (req.method !== "POST") {
    res.writeHead(405, { Allow: "POST" });
    res.end();
    return;
  }
  if (!authorized(req, deps)) {
    res.writeHead(401, { "WWW-Authenticate": "Bearer" });
    res.end();
    // Nothing has been read from the socket; destroy so a large in-flight body
    // is not drained on behalf of a caller we just rejected.
    req.destroy();
    return;
  }

  // Mime comes from the header, not from sniffing: the store's allowlist is what
  // keeps script-bearing types (SVG, HTML) out of the serving path entirely.
  const mime = (req.headers["content-type"] ?? "").split(";")[0]!.trim().toLowerCase();
  if (!MEDIA_MIME_ALLOWLIST.has(mime)) {
    status(res, 415, "unsupported_media_type");
    req.destroy();
    return;
  }

  const declared = Number(req.headers["content-length"]);
  if (!Number.isInteger(declared) || declared <= 0) {
    status(res, 411, "length_required");
    req.destroy();
    return;
  }
  const max = deps.store.maxBlobBytes;
  if (declared > max) {
    status(res, 413, "payload_too_large");
    req.destroy();
    return;
  }

  const chunks: Buffer[] = [];
  let received = 0;
  let settled = false;
  const reply = (code: number, error: string) => {
    // `end` and `error` can BOTH fire on one request — e.g. a sender that writes
    // past its Content-Length: the body completes, then the surplus fails to
    // parse as the next request and the socket errors. Without this guard the
    // second one throws ERR_HTTP_HEADERS_SENT out of an event handler.
    if (settled) return;
    settled = true;
    if (!res.headersSent) status(res, code, error);
    req.destroy();
  };

  req.on("data", (chunk: Buffer) => {
    if (settled) return;
    received += chunk.length;
    // Both bounds matter: the store's cap, and the length this request was
    // admitted under. Exceeding either means we stop before storing anything.
    if (received > max || received > declared) {
      reply(413, "payload_too_large");
      return;
    }
    chunks.push(chunk);
  });

  req.on("end", () => {
    if (settled) return;
    if (received !== declared) {
      // Short body: a truncated image must not be stored under a hash that the
      // client will then reference as if it were the whole file.
      reply(400, "incomplete_body");
      return;
    }
    // `store.put` is synchronous fs work (mkdir/write/fsync/rename) and DOES
    // throw on a full disk, EACCES, or a failed rename. We are inside an `end`
    // event callback, so the try/catch around `handleUpload` cannot see it: an
    // unguarded throw here becomes an uncaught exception that takes the whole
    // daemon down and leaves the client hanging. Hence a local guard, and
    // `settled` is set only once the write has actually succeeded.
    let descriptor;
    try {
      descriptor = deps.store.put(Buffer.concat(chunks), mime);
    } catch (err) {
      log.error(`[makit] media upload could not be stored: ${(err as Error).message}`);
      reply(500, "upload_failed");
      return;
    }
    settled = true;
    // Metadata only — never a filename (the client's, and not ours to log) and
    // never bytes.
    log.info(`[makit] media upload mime=${mime} bytes=${descriptor.sizeBytes}`);
    const body = JSON.stringify(descriptor);
    res.writeHead(201, {
      "Content-Type": "application/json",
      "Content-Length": String(Buffer.byteLength(body)),
      // The descriptor is cheap to recompute and must never be served stale.
      "Cache-Control": "no-store",
    });
    res.end(body);
  });

  req.on("error", () => reply(400, "upload_aborted"));
}

/** Small JSON error body. Never an image — see {@link notFound}. */
function status(res: ServerResponse, code: number, error: string): void {
  const body = JSON.stringify({ error });
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Content-Length": String(Buffer.byteLength(body)),
  });
  res.end(body);
}

function handle(req: IncomingMessage, res: ServerResponse, deps: MediaRouteDeps): void {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD" });
    res.end();
    return;
  }

  if (!authorized(req, deps)) {
    res.writeHead(401, { "WWW-Authenticate": "Bearer" });
    res.end();
    return;
  }

  // Path only — a query string is not part of the id.
  const rawId = req.url!.slice(MEDIA_PREFIX.length).split("?")[0] ?? "";
  // A malformed id and a GC'd id are the same 404: the client can't tell them
  // apart and doesn't need to, and it keeps store layout out of the response.
  const media = deps.store.stat(decodeURIComponent(rawId));
  if (!media) {
    notFound(res);
    return;
  }

  const headers: Record<string, string> = {
    "Content-Type": media.mime,
    "Accept-Ranges": "bytes",
    "Cache-Control": "public, max-age=31536000, immutable",
    // Content-addressed bytes must never be sniffed into another type.
    "X-Content-Type-Options": "nosniff",
  };

  const range = parseRange(req.headers.range, media.sizeBytes);
  if (range === "unsatisfiable") {
    res.writeHead(416, { "Content-Range": `bytes */${media.sizeBytes}` });
    res.end();
    return;
  }

  const start = range ? range.start : 0;
  const end = range ? range.end : media.sizeBytes - 1;
  headers["Content-Length"] = String(end - start + 1);
  if (range) headers["Content-Range"] = `bytes ${start}-${end}/${media.sizeBytes}`;

  res.writeHead(range ? 206 : 200, headers);
  if (req.method === "HEAD") {
    res.end();
    return;
  }

  // Streamed (not read into memory) so a large blob can't balloon the daemon,
  // and destroyed with the response so an aborted fetch doesn't leak an fd.
  const stream = createReadStream(deps.store.pathOf(media.mediaId), { start, end });
  stream.on("error", () => res.destroy());
  res.on("close", () => stream.destroy());
  stream.pipe(res);
}

function notFound(res: ServerResponse): void {
  // JSON, never an image: an error body handed to an image decoder would be
  // cached under the mediaId and poison the content-addressed cache.
  const body = JSON.stringify({ error: "media_not_found" });
  res.writeHead(404, { "Content-Type": "application/json", "Content-Length": String(body.length) });
  res.end(body);
}

function authorized(req: IncomingMessage, deps: MediaRouteDeps): boolean {
  const bearer = bearerOf(req);
  if (bearer && deps.registry.authenticate(bearer)) return true;
  const remote = req.socket.remoteAddress ?? "";
  const isLoopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
  return deps.trustLoopback === true && isLoopback;
}

function bearerOf(req: IncomingMessage): string | undefined {
  const raw = req.headers.authorization;
  if (typeof raw !== "string") return undefined;
  const m = /^Bearer (.+)$/.exec(raw.trim());
  return m?.[1];
}

/**
 * Parse a single-range `Range: bytes=…` header against `size`. Returns the
 * resolved byte window, `null` when there is no (or an unusable) range header
 * — the caller then serves the full body, per RFC 9110 — or `"unsatisfiable"`
 * when the range starts past the end.
 */
function parseRange(
  header: string | undefined,
  size: number,
): { start: number; end: number } | null | "unsatisfiable" {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return null; // malformed or multi-range → ignore, send everything
  const [, rawStart, rawEnd] = m;
  if (rawStart === "" && rawEnd === "") return null;

  if (rawStart === "") {
    // Suffix range: the last N bytes.
    const n = Number(rawEnd);
    if (n <= 0) return "unsatisfiable";
    return { start: Math.max(0, size - n), end: size - 1 };
  }
  const start = Number(rawStart);
  if (start >= size) return "unsatisfiable";
  const end = rawEnd === "" ? size - 1 : Math.min(Number(rawEnd), size - 1);
  if (end < start) return "unsatisfiable";
  return { start, end };
}
