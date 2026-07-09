/**
 * project-store — pure persistence + filesystem-browse helpers for the
 * multi-project feature. Kept side-effect-free (beyond fs at a caller-given
 * path) so it is trivially unit-testable.
 *
 * Persistence lives in a small JSON file (`~/.makit/projects.json` by default,
 * overridable via MAKIT_PROJECTS_FILE) shaped `{ "projects": ["/abs", …] }`.
 * Load/save never throw on bad input — a corrupt or missing file degrades to
 * an empty list so the server always starts.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { log } from "./log.js";

/** Absolute path of the projects persistence file. */
export function projectsFile(): string {
  return process.env.MAKIT_PROJECTS_FILE ?? join(homedir(), ".makit", "projects.json");
}

/**
 * Read persisted project paths. A missing or malformed file yields `[]` —
 * this must never throw so startup is robust against a corrupt store.
 */
export function loadProjectPaths(file: string): string[] {
  try {
    if (!existsSync(file)) return [];
    const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null) return [];
    const projects = (parsed as { projects?: unknown }).projects;
    if (!Array.isArray(projects)) return [];
    return projects.filter((p): p is string => typeof p === "string");
  } catch (e) {
    log.warn(`[makit] failed to read projects file ${file}: ${(e as Error).message}`);
    return [];
  }
}

/**
 * Persist project paths as pretty JSON, creating the parent dir if needed.
 * Never throws — a write failure is logged and swallowed.
 */
export function saveProjectPaths(file: string, paths: string[]): void {
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify({ projects: paths }, null, 2) + "\n");
  } catch (e) {
    log.warn(`[makit] failed to write projects file ${file}: ${(e as Error).message}`);
  }
}

export interface BrowseEntry {
  name: string;
  path: string;
  isRepo: boolean;
}

export interface BrowseResult {
  path: string;
  parent: string | null;
  entries: BrowseEntry[];
}

/**
 * List the subdirectories of `path` for the folder-picker. Returns directories
 * only (files skipped), skipping hidden entries (name starts with "."), sorted
 * by name (case-insensitive ascending). `isRepo` is true when the dir contains
 * a `.git` entry.
 *
 * Throws only when `path` is not an existing directory, so the caller can map
 * that to a BadRequest. Individual entries that fail to stat are skipped rather
 * than aborting the whole listing.
 */
export function browseDirectory(path: string): BrowseResult {
  const full = resolve(path);
  if (!existsSync(full) || !statSync(full).isDirectory()) {
    throw new Error(`not a directory: ${full}`);
  }

  const parent = dirname(full);
  const entries: BrowseEntry[] = [];
  for (const name of readdirSync(full)) {
    if (name.startsWith(".")) continue;
    const entryPath = join(full, name);
    try {
      if (!statSync(entryPath).isDirectory()) continue;
      entries.push({
        name,
        path: entryPath,
        isRepo: existsSync(join(entryPath, ".git")),
      });
    } catch {
      // Permission-denied or race on an individual entry — skip it.
      continue;
    }
  }
  entries.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));

  return {
    path: full,
    parent: parent === full ? null : parent,
    entries,
  };
}

/** basename helper re-exported so callers avoid a second path import. */
export function projectName(path: string): string {
  return basename(path);
}
