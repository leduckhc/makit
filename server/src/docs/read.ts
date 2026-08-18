/**
 * makit — SPEC-doc-preview D7: read one markdown document's text over the WSS channel.
 *
 * A spec file is smaller than the transcript it would sit next to, so it needs
 * no second transport — but HTML is **never** sent this way (it is only useful
 * once a browser engine renders it), and the text is capped at 1 MB so a
 * pathological file cannot balloon a frame. Every path goes through
 * {@link resolveDocPath}, the shared security boundary.
 */

import { readFileSync } from "node:fs";

import { resolveDocPath } from "./resolve.js";

/** Hard cap on markdown delivered over WSS (D7). resolveDocPath's 5 MB is the outer bound. */
export const MAX_READ_BYTES = 1024 * 1024;

export type DocReadResult = { ok: true; text: string } | { ok: false; message: string };

export function readDocText(worktreePath: string, relPath: string): DocReadResult {
  const resolved = resolveDocPath(worktreePath, relPath);
  if (!resolved.ok) return { ok: false, message: `cannot read ${relPath}: ${resolved.reason}` };

  // HTML only makes sense once a browser renders it; shipping its bytes to Dart
  // would be pointless, so it is published, not read (D7/D8).
  if (resolved.kind === "html") {
    return { ok: false, message: "html documents are published, not read over this channel" };
  }
  if (resolved.bytes > MAX_READ_BYTES) {
    return { ok: false, message: "document too large to read (over 1 MB)" };
  }

  try {
    return { ok: true, text: readFileSync(resolved.absPath, "utf8") };
  } catch (err) {
    return { ok: false, message: `could not read ${relPath}: ${(err as Error).message}` };
  }
}
