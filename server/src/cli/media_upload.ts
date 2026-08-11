/**
 * Uploading an attachment from the terminal (SPEC-46 `send --attach`, SPEC-33).
 *
 * `POST /media` rides the same HTTPS listener as the socket and authenticates
 * with the same bearer, so this is a plain request — with two deliberate choices:
 *
 *   - **The mime comes from the file extension, never from sniffing.** That
 *     mirrors the server, which trusts the declared `Content-Type` against an
 *     allowlist precisely so script-bearing types (SVG, HTML) can never enter the
 *     serving path. Sniffing here would only invent a disagreement with it.
 *   - **`rejectUnauthorized: false`**, matching the socket: makit's own cert is
 *     self-signed and the CLI talks to loopback. (Remote contexts pin a
 *     fingerprint instead — that is D11, and it is P3.)
 */
import { request } from "node:https";
import { basename, extname } from "node:path";

/** What the server will store, keyed by extension (`MEDIA_MIME_ALLOWLIST`). */
const MIME_BY_EXT: Readonly<Record<string, string>> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
};

/** Human list of what `--attach` accepts, for the refusal message. */
export const ATTACHABLE = Object.keys(MIME_BY_EXT).join(" ");

/**
 * How long an upload may take before it is abandoned. Generous enough for a
 * large attachment on a slow link, but finite: an unbounded wait means the verb
 * produces no exit code at all, which is the one result automation cannot handle.
 */
export const UPLOAD_TIMEOUT_MS = 30_000;

/** The mime for a path, or undefined when the server would refuse to store it. */
export function mimeForPath(path: string): string | undefined {
  return MIME_BY_EXT[extname(path).toLowerCase()];
}

export interface UploadTarget {
  host: string;
  port: number;
  bearer: string;
}

/**
 * Upload one blob, resolving with its `mediaId`. Rejects on any non-201 so the
 * caller can refuse the turn rather than send a message about an image the agent
 * will never receive.
 */
export function uploadMedia(
  target: UploadTarget,
  path: string,
  bytes: Buffer,
  mime: string,
  timeoutMs: number = UPLOAD_TIMEOUT_MS,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: target.host,
        port: target.port,
        path: "/media",
        method: "POST",
        rejectUnauthorized: false,
        headers: {
          Authorization: `Bearer ${target.bearer}`,
          "Content-Type": mime,
          "Content-Length": bytes.byteLength,
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString();
          if (res.statusCode !== 201) {
            const detail = body ? `: ${body}` : "";
            reject(new Error(`${basename(path)} was refused (${res.statusCode})${detail}`));
            return;
          }
          try {
            const mediaId = (JSON.parse(body) as { mediaId?: unknown }).mediaId;
            if (typeof mediaId !== "string" || mediaId === "") throw new Error("no mediaId");
            resolve(mediaId);
          } catch {
            reject(new Error(`${basename(path)}: the server's upload reply was not a descriptor`));
          }
        });
      },
    );
    req.on("error", (e) => reject(new Error(`${basename(path)}: ${e.message}`)));
    // This leg does not ride the WebSocket, so `client.close()` cannot rescue it:
    // a server that takes the connection and then stalls left the promise
    // unsettled, keeping the event loop alive so the verb never reached an exit
    // code at all (D8). `destroy()` makes the `error` handler above fire, so the
    // rejection still names the file.
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`upload timed out after ${timeoutMs}ms`));
    });
    req.end(bytes);
  });
}
