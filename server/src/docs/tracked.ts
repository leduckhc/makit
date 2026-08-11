/**
 * makit — SPEC-46 D1 rev 2: the candidate list for a worktree's doc index.
 *
 * rev 1 walked an allowlist (`mockups/`, `docs/`, plus root `*.md`). That was
 * tuned for *this* repo and generalises badly — a project keeping its docs in
 * `flutter/learning-records/` showed 3 of its 69 documents, because makit only
 * looked where makit keeps things. Since the sidebar holds many repos, the
 * layout of one of them is the wrong default.
 *
 * rev 2 asks git for every file it does not ignore. That finds docs wherever
 * they actually live, and it *tightens* security as a side effect: a gitignored
 * `secrets.md` can no longer be indexed or served, where rev 1 would have
 * indexed it happily (the dotfile rule never covered it).
 *
 * **This module owns the fallback.** A worktree that names `roots` itself, or one
 * git cannot answer for, is walked the rev 1 way — but the caller never sees
 * which happened: it gets one list of worktree-relative candidate paths either
 * way. That is what keeps `scanWorktree` a single loop instead of two shapes.
 *
 * Extension filtering happens here, not at the security boundary, so a large
 * repo does not pay a realpath + stat for every non-document file it tracks.
 */

import { execFile } from "node:child_process";
import { readdirSync, type Dirent } from "node:fs";
import { join } from "node:path";

import { EXCLUDED_DIRS } from "./resolve.js";
import { DEFAULT_DOC_DIRS, type DocRoots } from "./roots.js";

/** Extensions worth handing to the security boundary (D2 re-checks them). */
const DOC_EXT = /\.(md|markdown|html?)$/i;

/** Cap on git's output, so a pathological repo cannot exhaust memory. */
const MAX_OUTPUT_BYTES = 64 * 1024 * 1024;

/**
 * Ceiling on the `git ls-files` call. A repo on a slow or stalled filesystem
 * must degrade to the walk, not hang the re-index (and with it every watcher).
 */
export const GIT_LIST_TIMEOUT_MS = 10_000;

/**
 * Every worktree-relative `.md`/`.html` path worth considering, from git when it
 * can answer and from the allowlist walk when it cannot.
 *
 * Async because `git ls-files` is a subprocess: doing it synchronously blocks
 * the event loop for its whole duration, which stalls every connected client on
 * a large repo.
 */
export async function docCandidates(root: string, roots: DocRoots): Promise<string[]> {
  // A project that named its own roots has opted out of the breadth (D1 rev 2),
  // so do not ask git at all.
  if (roots.kind === "walk") return walkRoots(root, roots);

  const tracked = await gitDocPaths(root);
  return tracked ?? walkRoots(root, defaultWalk());
}

/** The rev 1 shape, used as the fallback when git cannot answer. */
function defaultWalk(): Extract<DocRoots, { kind: "walk" }> {
  return { kind: "walk", dirs: [...DEFAULT_DOC_DIRS], rootMarkdown: true, exclude: [] };
}

/** `git ls-files` doc paths, or undefined when git cannot answer. */
async function gitDocPaths(root: string): Promise<string[] | undefined> {
  const stdout = await new Promise<string | undefined>((resolve) => {
    execFile(
      "git",
      ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
      { encoding: "utf8", maxBuffer: MAX_OUTPUT_BYTES, timeout: GIT_LIST_TIMEOUT_MS },
      (err, out) => resolve(err === null ? out : undefined),
    );
  });
  if (stdout === undefined) return undefined; // not a repo, git missing, timed out

  // `--cached` and `--others` cannot overlap, but a deduping set costs nothing
  // and makes a duplicate path impossible to turn into a duplicate row.
  const paths = new Set<string>();
  for (const rel of stdout.split("\0")) {
    if (rel !== "" && DOC_EXT.test(rel)) paths.add(rel);
  }
  return [...paths];
}

/**
 * rev 1's allowlist walk, reduced to what it should always have been: a lister
 * of candidate paths. It no longer builds `DocDTO`s, so traversal and DTO
 * construction stop being entangled in one of the two code paths.
 *
 * D2's exclusions are applied **before descending**, so an excluded tree is
 * never entered rather than filtered afterwards.
 */
function walkRoots(root: string, roots: Extract<DocRoots, { kind: "walk" }>): string[] {
  const out: string[] = [];
  const exclude = new Set(roots.exclude);

  if (roots.rootMarkdown) {
    for (const entry of readDir(root)) {
      if (entry.isFile() && DOC_EXT.test(entry.name)) out.push(entry.name);
    }
  }
  for (const dir of roots.dirs) {
    const rel = dir.replace(/[\\/]+$/, "");
    if (rel === "" || exclude.has(rel)) continue;
    descend(root, rel, exclude, out);
  }
  return out;
}

function descend(root: string, dirRel: string, exclude: ReadonlySet<string>, out: string[]): void {
  for (const entry of readDir(join(root, dirRel))) {
    const childRel = `${dirRel}/${entry.name}`;
    if (exclude.has(childRel)) continue;
    if (entry.isDirectory()) {
      if (entry.name.startsWith(".") || EXCLUDED_DIRS.has(entry.name)) continue;
      descend(root, childRel, exclude, out);
    } else if (entry.isFile() && DOC_EXT.test(entry.name)) {
      out.push(childRel);
    }
  }
}

/** An unreadable directory is skipped: the scan still ran (the scanOk rule). */
function readDir(absPath: string): Dirent[] {
  try {
    return readdirSync(absPath, { withFileTypes: true });
  } catch {
    return [];
  }
}
