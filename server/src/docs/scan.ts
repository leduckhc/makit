/**
 * makit — SPEC-46: collect a worktree's documents into `DocDTO[]`.
 *
 * D1 rev 2: the candidate list comes from {@link trackedDocPaths} — everything
 * git does not ignore — so docs are found wherever a project keeps them. A
 * worktree that names `roots` in `.makit/docs.json`, or one git cannot answer
 * for, falls back to rev 1's allowlist walk, which applies D2's exclusions
 * **before descending** (so `node_modules` is never entered).
 *
 * Either way every candidate is routed through {@link resolveDocPath} — the one
 * security boundary this and the static route share — and its title/status read
 * with {@link readDocMeta}.
 *
 * An unreadable file is skipped without failing the scan: `scanOk` means "the
 * scan ran", not "the list is complete" (the `PortsSnapshotDTO.scanOk` rule).
 * The service enriches each doc with `changed` (D5) and `sessionId` afterwards.
 */

import { readdirSync, statSync, type Dirent } from "node:fs";
import { join } from "node:path";

import type { DocDTO } from "../protocol.js";
import { EXCLUDED_DIRS, resolveDocPath, type DocKind } from "./resolve.js";
import { readDocMeta, type DocMeta } from "./title.js";
import { resolveDocRoots, type DocRoots } from "./roots.js";
import { trackedDocPaths, type DocLister } from "./tracked.js";

export interface ScanOptions {
  /** Injected for tests; defaults to {@link resolveDocRoots}. */
  resolveRoots?: (worktreeRoot: string) => DocRoots;
  /** Injected for tests; defaults to {@link readDocMeta}. */
  readMeta?: (absPath: string, kind: DocKind) => DocMeta;
  /** Injected for tests; defaults to {@link trackedDocPaths}. */
  listDocs?: DocLister;
}

export interface WorktreeScan {
  /** Docs in this worktree, mtime-descending. */
  docs: DocDTO[];
  /** True when the walk ran — not that every file was read (D7 discipline). */
  scanOk: boolean;
  /** One-line reason when the walk itself could not run. */
  scanError?: string;
}

/**
 * Walk `worktreePath`'s doc roots and return its documents, mtime-descending.
 * Never throws: a per-file failure is skipped, and a catastrophic failure sets
 * `scanOk:false` with the last (empty) list.
 */
export function scanWorktree(worktreePath: string, opts: ScanOptions = {}): WorktreeScan {
  const resolveRoots = opts.resolveRoots ?? resolveDocRoots;
  const readMeta = opts.readMeta ?? readDocMeta;
  const listDocs = opts.listDocs ?? trackedDocPaths;

  try {
    const roots = resolveRoots(worktreePath);
    const exclude = new Set(roots.exclude);
    const docs: DocDTO[] = [];

    // D1 rev 2: git's view of the worktree, unless the project narrowed the
    // index itself (`roots`) or git cannot answer (not a repository).
    const candidates = roots.explicit ? undefined : listDocs(worktreePath);
    if (candidates !== undefined) {
      for (const rel of candidates) {
        if (isExcluded(rel, exclude)) continue;
        consider(worktreePath, rel, docs, readMeta);
      }
    } else {
      // rev 1's allowlist walk: root markdown first (non-recursive), then each
      // configured directory recursively. Order is irrelevant — sorted below.
      if (roots.rootMarkdown) collectTopLevel(worktreePath, worktreePath, docs, readMeta);
      for (const dir of roots.dirs) {
        const rel = dir.replace(/[\\/]+$/, "");
        if (exclude.has(rel)) continue;
        walk(worktreePath, join(worktreePath, rel), rel, exclude, docs, readMeta);
      }
    }

    docs.sort((a, b) => b.modifiedAt - a.modifiedAt);
    return { docs, scanOk: true };
  } catch (err) {
    return { docs: [], scanOk: false, scanError: (err as Error).message };
  }
}

/**
 * True when `rel`, or any directory above it, is in the config's exclude list.
 * The recursive walk skips an excluded directory before descending; a flat
 * candidate list has to test each ancestor instead.
 */
function isExcluded(rel: string, exclude: ReadonlySet<string>): boolean {
  if (exclude.size === 0) return false;
  if (exclude.has(rel)) return true;
  for (let i = rel.indexOf("/"); i !== -1; i = rel.indexOf("/", i + 1)) {
    if (exclude.has(rel.slice(0, i))) return true;
  }
  return false;
}

/** Index only the allowlisted files sitting directly in `dirAbs` (no descent). */
function collectTopLevel(
  worktreeRoot: string,
  dirAbs: string,
  out: DocDTO[],
  readMeta: (absPath: string, kind: DocKind) => DocMeta,
): void {
  let entries: Dirent[];
  try {
    entries = readdirSync(dirAbs, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    consider(worktreeRoot, entry.name, out, readMeta);
  }
}

/**
 * Walk `dirAbs` recursively, excluding D2's hard directory list, any
 * dot-directory, and the config's extra exclusions — **before** descending, so
 * an excluded tree is never entered.
 */
function walk(
  worktreeRoot: string,
  dirAbs: string,
  dirRel: string,
  exclude: ReadonlySet<string>,
  out: DocDTO[],
  readMeta: (absPath: string, kind: DocKind) => DocMeta,
): void {
  let entries: Dirent[];
  try {
    entries = readdirSync(dirAbs, { withFileTypes: true });
  } catch {
    return; // unreadable directory: skip it, the walk still ran
  }
  for (const entry of entries) {
    const childRel = dirRel === "" ? entry.name : `${dirRel}/${entry.name}`;
    if (entry.isDirectory()) {
      if (entry.name.startsWith(".")) continue;
      if (EXCLUDED_DIRS.has(entry.name)) continue;
      if (exclude.has(childRel)) continue;
      walk(worktreeRoot, join(dirAbs, entry.name), childRel, exclude, out, readMeta);
    } else if (entry.isFile()) {
      if (exclude.has(childRel)) continue;
      consider(worktreeRoot, childRel, out, readMeta);
    }
  }
}

/**
 * Route one candidate through {@link resolveDocPath} (the security boundary) and
 * append a {@link DocDTO} if it survives. A per-file failure — a race delete, an
 * unreadable file — is swallowed so it cannot fail the walk (scanOk).
 */
function consider(
  worktreeRoot: string,
  relPath: string,
  out: DocDTO[],
  readMeta: (absPath: string, kind: DocKind) => DocMeta,
): void {
  const resolved = resolveDocPath(worktreeRoot, relPath);
  if (!resolved.ok) return;
  try {
    const modifiedAt = statSync(resolved.absPath).mtimeMs;
    const meta = readMeta(resolved.absPath, resolved.kind);
    const doc: DocDTO = {
      key: `${worktreeRoot}:${resolved.relPath}`,
      relPath: resolved.relPath,
      title: meta.title,
      kind: resolved.kind,
      bytes: resolved.bytes,
      modifiedAt,
      worktreePath: worktreeRoot,
    };
    if (meta.docStatus !== undefined) doc.docStatus = meta.docStatus;
    out.push(doc);
  } catch {
    // Unreadable at read time: skip without failing the walk.
  }
}
