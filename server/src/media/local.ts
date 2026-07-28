/**
 * Local-file media ingestion (SPEC-22 phase 1b) — the *other* way an agent
 * shows you something.
 *
 * A wire capture of a real pi-acp turn ("copy this png, then display it")
 * ended with the agent writing `![/tmp/out2.png](/tmp/out2.png)` in its prose.
 * A local path is meaningless on the phone, so the app can never resolve it:
 * the bytes must be pulled in **here**, on the machine that has the file, and
 * the markdown rewritten to a `makit-media:<mediaId>` URI the app can fetch
 * from the `/media` route.
 *
 * SPEC-22 deferred file references to a later phase over symlink/TOCTOU risk.
 * Copying the bytes into the content-addressed store **at ingestion time**
 * removes that risk: what the phone later fetches is an immutable snapshot
 * keyed by its own hash, not a path re-read at serve time. What remains is a
 * *disclosure* risk, handled by containment: the realpath of the file must sit
 * inside an allowed root (the session's worktree, or the temp dir where
 * screenshot tools write), and only allowlisted image types are accepted.
 */

import { readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, resolve as resolvePath, sep } from "node:path";
import { fileURLToPath } from "node:url";

import { MEDIA_MIME_ALLOWLIST, type MediaDescriptor, type MediaStore } from "./store.js";

/** Extension → mime. Only what the store will serve; deliberately no SVG. */
const MIME_BY_EXT: ReadonlyMap<string, string> = new Map([
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".gif", "image/gif"],
  [".webp", "image/webp"],
  [".bmp", "image/bmp"],
]);

export interface LocalMediaResolverOpts {
  store: MediaStore;
  /**
   * Directories a referenced file may live under, compared after `realpath`.
   * The first root also anchors relative paths (the session's worktree).
   */
  roots: string[];
}

export class LocalMediaResolver {
  constructor(private readonly opts: LocalMediaResolverOpts) {}

  /**
   * Ingest the image at `ref` (an absolute path, a `file://` URL, or a path
   * relative to the first root) and return its descriptor. Returns `null` — and
   * never throws — for anything not allowed: remote URLs, escapes from the
   * roots, non-image types, directories, missing files, oversized files.
   */
  resolve(ref: string): MediaDescriptor | null {
    try {
      const path = this.toContainedPath(ref);
      if (!path) return null;

      const mime = MIME_BY_EXT.get(extensionOf(path));
      if (!mime || !MEDIA_MIME_ALLOWLIST.has(mime)) return null;

      const st = statSync(path);
      if (!st.isFile()) return null;
      // Cap first: `readFileSync` on a huge file would allocate it all.
      if (st.size > this.maxBytes()) return null;

      return this.opts.store.put(readFileSync(path), mime);
    } catch {
      return null; // ENOENT, EACCES, ELOOP, bad URL — all just "not media"
    }
  }

  /** The real path of `ref` if it resolves inside a root, else `null`. */
  private toContainedPath(ref: string): string | null {
    const raw = ref.trim();
    if (!raw || raw.includes("\u0000")) return null;
    const roots = this.opts.roots;
    let candidate: string;
    if (raw.startsWith("file:")) {
      candidate = fileURLToPath(raw); // throws on a malformed URL → caught
    } else if (isAbsolute(raw)) {
      // Before the scheme check: on Windows `C:\\path\\shot.png` matches a
      // scheme regex, so testing for a scheme first would reject every absolute
      // Windows path as "remote".
      candidate = raw;
    } else if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) {
      // A non-file scheme is remote (or a data: URI, which carries its own
      // bytes and is not our business).
      return null;
    } else {
      if (roots.length === 0) return null;
      candidate = join(roots[0]!, raw);
    }

    // realpath BOTH sides: a symlink inside a root that points out of it must
    // fail, and on macOS the roots themselves are often /var → /private/var.
    const real = realpathSync(resolvePath(candidate));
    for (const root of roots) {
      let realRoot: string;
      try {
        realRoot = realpathSync(root);
      } catch {
        continue;
      }
      // The `sep` guard stops `/root-evil/x` matching root `/root`.
      if (real === realRoot || real.startsWith(realRoot.endsWith(sep) ? realRoot : realRoot + sep)) {
        return real;
      }
    }
    return null;
  }

  private maxBytes(): number {
    return this.opts.store.maxBlobBytes;
  }
}

/** URI scheme the app resolves against the `/media` route. */
export const MEDIA_URI_SCHEME = "makit-media";

/**
 * Rewrite `![alt](local/path)` to `![alt](makit-media:<mediaId>)` for every
 * image whose target `resolveRef` can ingest. Remote URLs, already-rewritten
 * URIs, plain links, and anything unresolvable are left byte-identical, so this
 * is safe to run over arbitrary agent prose (and is idempotent).
 */
export function rewriteMarkdownImages(
  text: string,
  resolveRef: (ref: string) => MediaDescriptor | null,
): string {
  if (!text.includes("![")) return text; // fast path: the vast majority
  return text.replace(/!\[([^\]]*)\]\(\s*([^)\s]+)\s*\)/g, (whole, alt: string, ref: string) => {
    if (/^(https?|data|makit-media):/i.test(ref)) return whole;
    const stored = resolveRef(ref);
    return stored ? `![${alt}](${MEDIA_URI_SCHEME}:${stored.mediaId})` : whole;
  });
}

function extensionOf(path: string): string {
  const i = path.lastIndexOf(".");
  return i === -1 ? "" : path.slice(i).toLowerCase();
}
