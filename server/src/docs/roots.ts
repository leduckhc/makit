/**
 * makit — SPEC-46 D1: which directories a worktree's doc index walks.
 *
 * An allowlist of roots, never a file tree: a tree invites traversal, needs
 * lazy loading, and buries the four directories a human opens under twelve they
 * do not. Defaults are `mockups/`, `docs/`, and `*.md` at the worktree root;
 * `.agents/skills/**\/SKILL.md` is opt-in via `.makit/docs.json` (`{roots?,
 * exclude?}`). A malformed or unreadable config falls back to the defaults —
 * this never throws, because a bad config file must degrade the index, not
 * break it.
 */

import { readFileSync, realpathSync } from "node:fs";
import { isAbsolute, join, normalize, resolve } from "node:path";

import { isInsideRoot } from "./resolve.js";

/** Directories walked recursively when there is no `roots` override. */
export const DEFAULT_DOC_DIRS: readonly string[] = ["mockups", "docs"];

const CONFIG_REL_PATH = join(".makit", "docs.json");

export interface DocRoots {
  /** Worktree-relative directories to walk recursively. */
  dirs: string[];
  /** When true, also index `*.md` sitting directly in the worktree root (D1). */
  rootMarkdown: boolean;
  /** Extra worktree-relative paths to exclude (in addition to D2's hard list). */
  exclude: string[];
  /**
   * True when `.makit/docs.json` named `roots` itself. D1 rev 2 indexes the
   * whole worktree by default, so naming roots is now the way to **narrow** the
   * index back to a walk of exactly those directories.
   */
  explicit: boolean;
}

/**
 * Resolve the doc roots for `worktreeRoot`, honouring `.makit/docs.json` when it
 * is present and well-formed. Any failure — missing file, unreadable directory,
 * invalid JSON, wrong shape — yields the D1 defaults.
 */
export function resolveDocRoots(worktreeRoot: string): DocRoots {
  const defaults: DocRoots = {
    dirs: [...DEFAULT_DOC_DIRS],
    rootMarkdown: true,
    exclude: [],
    explicit: false,
  };

  const config = readConfig(worktreeRoot);
  if (config === undefined) return defaults;

  const exclude = stringArray(config.exclude) ?? [];

  const rawRoots = stringArray(config.roots);
  if (rawRoots === undefined) {
    // No (or malformed) roots key: keep the defaults, but a valid exclude list
    // still applies.
    return { ...defaults, exclude };
  }

  // A user who lists roots explicitly opts out of the implicit root-markdown
  // scan and replaces the default directories (D1). Roots that escape the
  // worktree are dropped, reusing the containment check the serving layer uses.
  const dirs = rawRoots.filter((rel) => isContained(worktreeRoot, rel));
  return { dirs, rootMarkdown: false, exclude, explicit: true };
}

/** Parse `.makit/docs.json`, or undefined on any read/parse failure. */
function readConfig(worktreeRoot: string): { roots?: unknown; exclude?: unknown } | undefined {
  let text: string;
  try {
    text = readFileSync(join(worktreeRoot, CONFIG_REL_PATH), "utf8");
  } catch {
    return undefined; // absent or unreadable — the common case
  }
  try {
    const parsed: unknown = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined;
    return parsed as { roots?: unknown; exclude?: unknown };
  } catch {
    return undefined; // malformed JSON — fall back, never throw
  }
}

/** The value as a string[] when it is exactly that, otherwise undefined. */
function stringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  if (!value.every((v) => typeof v === "string")) return undefined;
  return value as string[];
}

/**
 * True when `rel` names a location inside `worktreeRoot`. Rejects absolute
 * paths and any `..` escape by segment, then confirms containment by realpath
 * when the target exists (defeating an escaping symlink) or textually when it
 * does not (a not-yet-created root is still allowed).
 */
function isContained(worktreeRoot: string, rel: string): boolean {
  if (rel.trim() === "" || isAbsolute(rel)) return false;
  const normalised = normalize(rel);
  if (normalised === ".." || normalised.startsWith(".." + "/") || normalised.startsWith(".." + "\\")) {
    return false;
  }
  if (normalised.split(/[\\/]/).some((seg) => seg === "..")) return false;

  const target = resolve(worktreeRoot, normalised);
  let realRoot: string;
  try {
    realRoot = realpathSync(worktreeRoot);
  } catch {
    return false; // no worktree, nothing to contain
  }
  try {
    return isInsideRoot(realRoot, realpathSync(target));
  } catch {
    // Not created yet: textual containment against the real root.
    return isInsideRoot(realRoot, resolve(realRoot, normalised));
  }
}
