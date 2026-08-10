/**
 * makit — SPEC-46: collect a worktree's documents into `DocDTO[]`.
 *
 * One shape, one loop: {@link docCandidates} yields worktree-relative paths
 * (from git under D1 rev 2, or the allowlist walk when git cannot answer or the
 * project narrowed its own roots), and each is mapped to a `DocDTO` here. The
 * fallback lives in the lister, so this module has no idea which source it got.
 *
 * Every candidate is routed through {@link resolveDocPath} — the one security
 * boundary this and the static route share — and its title/status read with
 * {@link readDocMeta}.
 *
 * An unreadable file is skipped without failing the scan: `scanOk` means "the
 * scan ran", not "the list is complete" (the `PortsSnapshotDTO.scanOk` rule).
 * The service enriches each doc with `changed` (D5) and `sessionId` afterwards.
 */

import type { DocDTO } from "../protocol.js";
import { resolveDocPath, type DocKind } from "./resolve.js";
import { readDocMeta, type DocMeta } from "./title.js";
import { resolveDocRoots, type DocRoots } from "./roots.js";
import { docCandidates } from "./tracked.js";

export interface ScanOptions {
  /** Injected for tests; defaults to {@link resolveDocRoots}. */
  resolveRoots?: (worktreeRoot: string) => DocRoots;
  /** Injected for tests; defaults to {@link readDocMeta}. */
  readMeta?: (absPath: string, kind: DocKind) => DocMeta;
  /** Injected for tests; defaults to {@link docCandidates}. */
  listCandidates?: (root: string, roots: DocRoots) => Promise<string[]>;
}

export interface WorktreeScan {
  /** Docs in this worktree, mtime-descending. */
  docs: DocDTO[];
  /** True when the scan ran — not that every file was read (D7 discipline). */
  scanOk: boolean;
  /** One-line reason when the scan itself could not run. */
  scanError?: string;
}

/**
 * Collect `worktreePath`'s documents, mtime-descending. Never throws: a per-file
 * failure is skipped, and a catastrophic failure sets `scanOk:false`.
 */
export async function scanWorktree(
  worktreePath: string,
  opts: ScanOptions = {},
): Promise<WorktreeScan> {
  const resolveRoots = opts.resolveRoots ?? resolveDocRoots;
  const readMeta = opts.readMeta ?? readDocMeta;
  const listCandidates = opts.listCandidates ?? docCandidates;

  try {
    const roots = resolveRoots(worktreePath);
    const exclude = new Set(roots.exclude);
    const candidates = await listCandidates(worktreePath, roots);

    const docs: DocDTO[] = [];
    for (const rel of candidates) {
      if (isExcluded(rel, exclude)) continue;
      const doc = toDoc(worktreePath, rel, readMeta);
      if (doc !== undefined) docs.push(doc);
    }

    docs.sort((a, b) => b.modifiedAt - a.modifiedAt);
    return { docs, scanOk: true };
  } catch (err) {
    return { docs: [], scanOk: false, scanError: (err as Error).message };
  }
}

/**
 * True when `rel`, or any directory above it, is in the config's exclude list.
 * The walk skips an excluded directory before descending; a flat candidate list
 * has to test each ancestor instead.
 */
function isExcluded(rel: string, exclude: ReadonlySet<string>): boolean {
  if (exclude.size === 0) return false;
  if (exclude.has(rel)) return true;
  for (let i = rel.indexOf("/"); i !== -1; i = rel.indexOf("/", i + 1)) {
    if (exclude.has(rel.slice(0, i))) return true;
  }
  return false;
}

/**
 * One candidate → one `DocDTO`, or undefined when the security boundary refuses
 * it or it cannot be read. A per-file failure is swallowed so it cannot fail the
 * scan (scanOk).
 *
 * `resolveDocPath` already stat'd the file, so its `bytes` and `modifiedAt` are
 * reused rather than stat'ing a second time.
 */
function toDoc(
  worktreeRoot: string,
  relPath: string,
  readMeta: (absPath: string, kind: DocKind) => DocMeta,
): DocDTO | undefined {
  const resolved = resolveDocPath(worktreeRoot, relPath);
  if (!resolved.ok) return undefined;
  try {
    const meta = readMeta(resolved.absPath, resolved.kind);
    const doc: DocDTO = {
      key: `${worktreeRoot}:${resolved.relPath}`,
      relPath: resolved.relPath,
      title: meta.title,
      kind: resolved.kind,
      bytes: resolved.bytes,
      modifiedAt: resolved.modifiedAt,
      worktreePath: worktreeRoot,
    };
    if (meta.docStatus !== undefined) doc.docStatus = meta.docStatus;
    return doc;
  } catch {
    return undefined; // unreadable at read time
  }
}
