/**
 * makit — SPEC-doc-preview D2: the one way a document path enters the serving layer.
 *
 * `resolveDocPath` is the security boundary of the Docs feature. Both
 * `docs.read` (WSS) and the static doc route call it, so they cannot disagree
 * about what is servable. It is deliberately paranoid and deliberately dull:
 * no globbing, no cleverness, and it never throws — a rejection is a value.
 */

import { realpathSync, statSync } from "node:fs";
import { isAbsolute, normalize, resolve, sep } from "node:path";

/** Extensions a document may have (SPEC-doc-preview D2). */
const ALLOWED_EXT = new Map<string, DocKind>([
  [".md", "md"],
  [".markdown", "md"],
  [".html", "html"],
  [".htm", "html"],
]);

/**
 * Directories never descended into or served from. Dot-directories are covered
 * by the separate dotfile rule, but `.git` is listed for the reader's benefit:
 * it holds credentials, which is the reason this list exists at all.
 */
export const EXCLUDED_DIRS: ReadonlySet<string> = new Set([
  ".git",
  "node_modules",
  "build",
  "dist",
  "coverage",
  ".dart_tool",
]);

/** Hard ceiling on a single document (SPEC-doc-preview D2). */
export const MAX_DOC_BYTES = 5 * 1024 * 1024;

export type DocKind = "md" | "html";

/** Why a path was refused. Surfaced in logs, never to an unauthenticated caller. */
export type DocRejection =
  | "empty"
  | "absolute"
  | "escapes-root"
  | "dotfile"
  | "excluded-dir"
  | "extension"
  | "not-a-file"
  | "too-large";

export type DocPathResult =
  | {
      ok: true;
      absPath: string;
      relPath: string;
      kind: DocKind;
      bytes: number;
      /** Epoch ms of the file's mtime. Carried because the `stat` that validated
       * this path already read it — callers must not stat a second time. */
      modifiedAt: number;
    }
  | { ok: false; reason: DocRejection };

/** True when `child` is inside `parent` by path *segment*, not by string prefix. */
export function isInsideRoot(parent: string, child: string): boolean {
  if (child === parent) return false; // the root itself is not a document
  return child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
}

/**
 * Resolve a worktree-relative document path, or explain the refusal.
 *
 * `worktreeRoot` must already be a real path (the caller holds it from the
 * worktree registry); we realpath it again anyway so a symlinked root does not
 * make every comparison fail.
 */
export function resolveDocPath(worktreeRoot: string, relPath: string): DocPathResult {
  if (typeof relPath !== "string" || relPath.trim() === "") return { ok: false, reason: "empty" };
  if (isAbsolute(relPath)) return { ok: false, reason: "absolute" };

  // Normalise first so "mockups/../.env" is judged as ".env", then reject any
  // residual traversal outright rather than trusting the join below.
  const normalised = normalize(relPath);
  if (normalised === "." || normalised === "" || normalised.startsWith("..")) {
    return { ok: false, reason: normalised.startsWith("..") ? "escapes-root" : "empty" };
  }

  const segments = normalised.split(/[\\/]/).filter((s) => s !== "");
  if (segments.length === 0) return { ok: false, reason: "empty" };
  for (const segment of segments) {
    if (segment === "..") return { ok: false, reason: "escapes-root" };
    if (segment.startsWith(".")) return { ok: false, reason: "dotfile" };
    if (EXCLUDED_DIRS.has(segment)) return { ok: false, reason: "excluded-dir" };
  }

  const ext = extensionOf(segments[segments.length - 1]!);
  const kind = ext === undefined ? undefined : ALLOWED_EXT.get(ext);
  if (kind === undefined) return { ok: false, reason: "extension" };

  // realpath both sides, then compare by segment. This is what defeats both an
  // escaping symlink and "/repo-evil" masquerading as inside "/repo".
  let realRoot: string;
  let realTarget: string;
  try {
    realRoot = realpathSync(worktreeRoot);
    realTarget = realpathSync(resolve(realRoot, normalised));
  } catch {
    return { ok: false, reason: "not-a-file" };
  }
  if (!isInsideRoot(realRoot, realTarget)) return { ok: false, reason: "escapes-root" };

  let bytes: number;
  let modifiedAt: number;
  try {
    const st = statSync(realTarget);
    if (!st.isFile()) return { ok: false, reason: "not-a-file" };
    bytes = st.size;
    modifiedAt = st.mtimeMs;
  } catch {
    return { ok: false, reason: "not-a-file" };
  }
  if (bytes > MAX_DOC_BYTES) return { ok: false, reason: "too-large" };

  return { ok: true, absPath: realTarget, relPath: segments.join("/"), kind, bytes, modifiedAt };
}

/** Lowercased extension including the dot, or undefined when there is none. */
function extensionOf(basename: string): string | undefined {
  const dot = basename.lastIndexOf(".");
  if (dot <= 0) return undefined; // no dot, or a leading dot (a dotfile)
  return basename.slice(dot).toLowerCase();
}
