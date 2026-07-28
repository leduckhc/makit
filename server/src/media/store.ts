/**
 * MediaStore — content-addressed blob store for assistant display media
 * (SPEC-22): images and GIFs an agent produced (a `read` of a PNG, an MCP
 * screenshot tool, a file the agent referenced in markdown).
 *
 * Why a store instead of inlining bytes in the event: session events are
 * persisted to SQLite and replayed **in full** on every reconnect/resume
 * (docs/ARCHITECTURE.md §2.2), so a base64 blob in an event would be re-sent
 * forever. Events carry a small descriptor; the bytes are served once by the
 * `/media` route and cached by the client under the immutable `mediaId`.
 *
 * Writes are **synchronous** on purpose. The event log's ordering invariant is
 * "durable before fan-out", and `EventStore.append` is sync; a sync
 * write-temp → fsync → rename keeps "blob durable before the event that
 * references it" true without threading promises through the pure ACP mapper.
 */

import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createHash, randomBytes } from "node:crypto";

/**
 * MIME types makit will store and serve. An allowlist, not a denylist: the
 * route hands `Content-Type` straight to an image decoder / native player, so
 * anything script-bearing (`image/svg+xml`, `text/html`) stays out.
 */
export const MEDIA_MIME_ALLOWLIST: ReadonlySet<string> = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "image/bmp",
]);

/** Hard cap on one blob. Guards decompression bombs + runaway agents. */
export const DEFAULT_MAX_MEDIA_BYTES = 24 * 1024 * 1024;

/** What an event carries and the route serves — never the bytes themselves. */
export interface MediaDescriptor {
  /** sha256 of the bytes, lowercase hex. The blob's filename and cache key. */
  mediaId: string;
  mime: string;
  sizeBytes: number;
}

export interface MediaStoreOpts {
  /** Blob directory. Defaults to `$MAKIT_HOME/media` (`~/.makit/media`). */
  dir?: string;
  maxBytes?: number;
}

const SHA256_RE = /^[a-f0-9]{64}$/;

export class MediaStore {
  private readonly dir: string;
  private readonly maxBytes: number;

  constructor(opts: MediaStoreOpts = {}) {
    this.dir = opts.dir ?? join(process.env.MAKIT_HOME || join(homedir(), ".makit"), "media");
    this.maxBytes = opts.maxBytes ?? DEFAULT_MAX_MEDIA_BYTES;
  }

  /**
   * Store `bytes` and return its descriptor. Idempotent: identical bytes hash
   * to the same id and the existing blob is reused.
   */
  put(bytes: Buffer, mime: string): MediaDescriptor {
    const mediaId = createHash("sha256").update(bytes).digest("hex");
    const descriptor: MediaDescriptor = { mediaId, mime, sizeBytes: bytes.length };
    mkdirSync(this.dir, { recursive: true });
    // Blob first, sidecar second: `stat()` requires the sidecar, so a crash
    // between the two leaves an unservable (GC-able) blob, never a servable
    // blob with no metadata.
    this.publish(mediaId, bytes);
    this.publish(`${mediaId}.json`, Buffer.from(JSON.stringify(descriptor)));
    return descriptor;
  }

  /**
   * Store a base64 payload (an ACP `{type:"image",data,mimeType}` block).
   * Returns `null` — never throws — when the mime is not allowlisted, the
   * base64 is malformed, or the decoded size exceeds the cap. The size check
   * happens on the **encoded** length first, so an oversized payload is never
   * decoded into memory.
   */
  putBase64(data: string, mime: string): MediaDescriptor | null {
    if (!MEDIA_MIME_ALLOWLIST.has(mime)) return null;
    if (typeof data !== "string" || data.length === 0) return null;
    // 4 base64 chars → 3 bytes. Bail before allocating the decoded buffer.
    if (Math.floor((data.length * 3) / 4) > this.maxBytes) return null;
    let bytes: Buffer;
    try {
      bytes = Buffer.from(data, "base64");
    } catch {
      return null;
    }
    // Node's base64 decoder is lenient (it skips junk), so verify the round
    // trip rather than trusting a non-empty result.
    if (bytes.length === 0 || bytes.toString("base64").replace(/=+$/, "") !== data.replace(/=+$/, "")) {
      return null;
    }
    if (bytes.length > this.maxBytes) return null;
    return this.put(bytes, mime);
  }

  /** Descriptor for a stored id, or `null` when unknown/invalid/unservable. */
  stat(mediaId: string): MediaDescriptor | null {
    if (!SHA256_RE.test(mediaId)) return null;
    try {
      const raw = readFileSync(join(this.dir, `${mediaId}.json`), "utf8");
      const meta = JSON.parse(raw) as MediaDescriptor;
      if (!MEDIA_MIME_ALLOWLIST.has(meta.mime)) return null;
      const size = statSync(join(this.dir, mediaId)).size;
      return { mediaId, mime: meta.mime, sizeBytes: size };
    } catch {
      return null;
    }
  }

  /** The per-blob size cap, so callers can bail before reading a huge file. */
  get maxBlobBytes(): number {
    return this.maxBytes;
  }

  /** Absolute blob path for a **validated** id (see {@link stat}). */
  pathOf(mediaId: string): string {
    if (!SHA256_RE.test(mediaId)) throw new Error("invalid mediaId");
    return join(this.dir, mediaId);
  }

  /** Write to a temp name, fsync, then rename — an atomic same-dir publish. */
  private publish(name: string, bytes: Buffer): void {
    const target = join(this.dir, name);
    const tmp = `${target}.${randomBytes(6).toString("hex")}.tmp`;
    const fd = openSync(tmp, "w");
    try {
      writeSync(fd, bytes);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    try {
      renameSync(tmp, target);
    } catch (err) {
      try {
        unlinkSync(tmp);
      } catch {
        /* best-effort */
      }
      throw err;
    }
  }
}

/**
 * Process-wide store, so the ingesting adapters and the serving route address
 * the same directory. Lazy so `MAKIT_HOME` overrides set by tests/CLI still
 * apply, and so no directory is created until media is actually stored.
 */
let shared: MediaStore | undefined;
export function sharedMediaStore(): MediaStore {
  shared ??= new MediaStore();
  return shared;
}
