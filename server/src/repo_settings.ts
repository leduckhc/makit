/**
 * repo_settings.ts — per-repo settings: the schema, how a value resolves, and
 * what is allowed to be written.
 *
 * Three responsibilities, kept apart on purpose:
 *
 *   1. {@link RepoSettings} — the persisted shape. Every field optional, because
 *      **absent means "inherit"**, never "empty". A blank worktree root that
 *      silently means `~/.worktrees` is how worktrees end up somewhere the user
 *      did not expect.
 *   2. {@link resolveWorktreeRoot} and friends — the effective value plus the
 *      SOURCE it came from, so the UI can label it rather than guess.
 *   3. {@link validateWorktreeRoot} — what a client may store.
 *
 * The resolution chain is deliberately three levels, not four:
 * `repo override → env var → built-in default`. There is no global settings store
 * to inherit from, and inventing a level for one that does not exist would be a
 * framework rather than a capability.
 */

import { existsSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, normalize, sep } from "node:path";

/** Where an effective value came from. Rendered as a badge; never inferred by the app. */
export type SettingSource = "override" | "environment" | "default";

/** One resolved setting: the value in force, and why. */
export interface Resolved<T> {
  value: T;
  source: SettingSource;
}

/**
 * The provider a repo should use, or `auto` to believe detection.
 *
 * `none` is not the absence of a choice — it is the instruction "talk to no forge
 * for this repository". A purely local repo and a mirror whose forge you do not
 * care about both need it, and neither is served by `auto` failing.
 */
export type ProviderChoice = "auto" | "none" | "forgejo" | "gitea" | "github";

const PROVIDER_CHOICES: readonly ProviderChoice[] = [
  "auto",
  "none",
  "forgejo",
  "gitea",
  "github",
];

/** Persisted per-repo settings. Absent field = inherit; never a sentinel value. */
export interface RepoSettings {
  /** Absolute, canonicalised worktree root for this repo. */
  worktreeRoot?: string;
  /** Provider override; `auto` is stored as absent so the default stays implicit. */
  provider?: Exclude<ProviderChoice, "auto">;
  /** Default branch override, used when `origin/HEAD` is absent or wrong. */
  defaultBranch?: string;
  /** Monogram hue index, chosen from a fixed palette (see the app's RepoMonogram). */
  logoHue?: number;
}

/** Built-in worktree root when nothing else says otherwise. */
export function defaultWorktreeRoot(home: string = homedir()): string {
  return join(home, ".worktrees");
}

/**
 * The worktree root in force for a repo, and where it came from.
 *
 * `MAKIT_WORKTREE_DIR` is a **level in the chain**, not a competitor: it already
 * exists and must keep working, and because the app cannot change the daemon's
 * environment it is reported as `environment` and rendered read-only.
 *
 * An empty-string env var resolves to the default rather than to `""` — an
 * exported-but-blank variable is a mistake, and honouring it would create
 * worktrees at the filesystem root.
 */
export function resolveWorktreeRoot(
  settings: RepoSettings | undefined,
  env: Record<string, string | undefined>,
  home: string = homedir(),
): Resolved<string> {
  const override = settings?.worktreeRoot;
  if (override !== undefined && override.length > 0) {
    return { value: override, source: "override" };
  }
  const fromEnv = env.MAKIT_WORKTREE_DIR;
  if (fromEnv !== undefined && fromEnv.length > 0) {
    return { value: fromEnv, source: "environment" };
  }
  return { value: defaultWorktreeRoot(home), source: "default" };
}

/** The provider choice in force. Absent = `auto`. */
export function resolveProvider(settings: RepoSettings | undefined): Resolved<ProviderChoice> {
  const p = settings?.provider;
  return p === undefined ? { value: "auto", source: "default" } : { value: p, source: "override" };
}

/** A rejected write, with a reason the UI can show verbatim. */
export interface Invalid {
  ok: false;
  error: string;
}
export interface Valid<T> {
  ok: true;
  value: T;
}
export type Validation<T> = Valid<T> | Invalid;

/**
 * Validate and canonicalise a worktree root.
 *
 * The order of the rules matters, and each exists for a different attack or
 * mistake:
 *
 *   1. **Absolute only.** A relative root would resolve against the daemon's cwd,
 *      which is not a place the user can see or reason about.
 *   2. **No `..` segment, rejected on sight** — not collapsed. Collapsing would
 *      silently produce a valid path that is not the one the user typed, which is
 *      exactly how a confused write becomes a surprising delete later (prune).
 *   3. **Canonicalise through the nearest EXISTING ancestor.** A worktree root
 *      that does not exist yet is the common case — `~/work/worktrees` before it
 *      has been created — and `realpath` fails outright on a missing path, so a
 *      naive rule would reject the normal case. The remaining, not-yet-created
 *      segments are then required to be plain names.
 *   4. **The resolved ancestor must be inside `$HOME`.** The daemon creates and,
 *      via prune, REMOVES directories under this root; a root outside the home
 *      directory turns a settings row into a filesystem weapon.
 *
 * Callers must re-validate on read-back before use: `projects.json` is plain JSON
 * a user can edit by hand, so a write-time check alone is not a guarantee.
 */
export function validateWorktreeRoot(
  raw: string,
  home: string = homedir(),
): Validation<string> {
  const input = raw.trim();
  if (input.length === 0) return { ok: false, error: "Worktree root cannot be empty." };
  if (!isAbsolute(input)) {
    return { ok: false, error: "Worktree root must be an absolute path." };
  }
  // Split the RAW input, not a normalised copy: `normalize` COLLAPSES `..`, so
  // checking the normalised form makes this rule dead code and lets
  // `/home/you/work/../../etc` through to be rejected later by the containment
  // rule with a misleading message. Found by a test that could not fail until the
  // test itself stopped using `path.join`, which collapses too.
  if (input.split(sep).some((seg) => seg === "..")) {
    return {
      ok: false,
      error: "Worktree root must not contain '..'. Give the path you mean, not a path relative to another.",
    };
  }

  // Walk up to the nearest existing ancestor and canonicalise THAT, so a
  // not-yet-created root is accepted while symlink escapes are still resolved.
  let existing = normalize(input);
  const trailing: string[] = [];
  while (!existsSync(existing)) {
    const parent = dirname(existing);
    if (parent === existing) {
      return { ok: false, error: `No part of ${input} exists, so it cannot be checked.` };
    }
    trailing.unshift(existing.slice(parent.length + 1));
    existing = parent;
  }

  let realAncestor: string;
  try {
    realAncestor = realpathSync(existing);
    if (!statSync(realAncestor).isDirectory()) {
      return { ok: false, error: `${existing} is not a directory.` };
    }
  } catch {
    return { ok: false, error: `Could not resolve ${existing}.` };
  }

  const realHome = (() => {
    try {
      return realpathSync(home);
    } catch {
      return home;
    }
  })();
  if (realAncestor !== realHome && !realAncestor.startsWith(realHome + sep)) {
    return {
      ok: false,
      error: "Worktree root must be inside your home directory.",
    };
  }

  return { ok: true, value: trailing.length === 0 ? realAncestor : join(realAncestor, ...trailing) };
}

/**
 * Validate and canonicalise a repository's root path, for re-pointing a project
 * that moved on disk (D4′).
 *
 * Shares two rules with {@link validateWorktreeRoot} — absolute only, and `..`
 * rejected on sight rather than collapsed — and deliberately differs on two:
 *
 *   - **It must already exist.** A worktree root is created on demand, so naming
 *     one before it exists is the normal case. A repository you have not got is
 *     not a repository: accepting the path would detach the project from its
 *     sessions with nothing to reattach to, which is the exact failure the P1
 *     notice existed to avoid.
 *   - **It is NOT confined to `$HOME`.** That rule protects the worktree root
 *     because the daemon creates and, via prune, REMOVES directories beneath it.
 *     makit never deletes a repo path, and a checkout on an external volume or a
 *     shared mount is ordinary — refusing it would be security theatre with a real
 *     cost to real users.
 *
 * Canonicalised so `/tmp` and `/private/tmp` cannot become two projects for one
 * directory: settings and the forge decision are both looked up BY PATH, so two
 * spellings of one repo would silently disagree about its configuration.
 *
 * Being a git repository is NOT checked here — that needs a subprocess, and this
 * stays synchronous and pure-ish so it can be unit-tested and reused. The caller
 * checks it (see `SessionManager.repointProject`).
 */
export function validateRepoPath(raw: string): Validation<string> {
  const input = raw.trim();
  if (input.length === 0) return { ok: false, error: "Repository path cannot be empty." };
  if (!isAbsolute(input)) {
    return { ok: false, error: "Repository path must be an absolute path." };
  }
  // Split the RAW input: `normalize` collapses `..`, which would make this dead
  // code — the mistake this file has already made once.
  if (input.split(sep).some((seg) => seg === "..")) {
    return {
      ok: false,
      error: "Repository path must not contain '..'. Give the path you mean.",
    };
  }
  let real: string;
  try {
    real = realpathSync(normalize(input));
  } catch {
    return { ok: false, error: `${input} does not exist.` };
  }
  try {
    if (!statSync(real).isDirectory()) {
      return { ok: false, error: `${input} is not a directory.` };
    }
  } catch {
    return { ok: false, error: `Could not read ${input}.` };
  }
  return { ok: true, value: real };
}

/** Validate a provider choice coming off the wire. */
export function validateProvider(raw: unknown): Validation<ProviderChoice> {
  if (typeof raw !== "string" || !PROVIDER_CHOICES.includes(raw as ProviderChoice)) {
    return { ok: false, error: `Unknown provider '${String(raw)}'.` };
  }
  return { ok: true, value: raw as ProviderChoice };
}

/**
 * Validate a default-branch override.
 *
 * Rejects the characters git itself refuses in a ref name, so a typo cannot be
 * stored and then fail deep inside a `git` invocation where the message is
 * unrecognisable.
 */
export function validateBranch(raw: string): Validation<string> {
  const b = raw.trim();
  if (b.length === 0) return { ok: false, error: "Branch name cannot be empty." };
  if (/[\s~^:?*[\\]/.test(b) || b.includes("..") || b.startsWith("-") || b.endsWith(".lock")) {
    return { ok: false, error: `'${b}' is not a valid branch name.` };
  }
  return { ok: true, value: b };
}

/**
 * Parse a persisted `settings` object defensively.
 *
 * Unknown keys are **preserved** by the caller (see `project-store`), but a KNOWN
 * key of the wrong type is dropped rather than trusted: a hand-edited
 * `worktreeRoot: 42` must not reach path handling. Never throws — a bad settings
 * object degrades that one repo to "inherit everything".
 */
export function parseRepoSettings(raw: unknown): RepoSettings {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return {};
  const r = raw as Record<string, unknown>;
  const out: RepoSettings = {};
  if (typeof r.worktreeRoot === "string" && r.worktreeRoot.length > 0) {
    out.worktreeRoot = r.worktreeRoot;
  }
  const provider = validateProvider(r.provider);
  if (provider.ok && provider.value !== "auto") out.provider = provider.value;
  if (typeof r.defaultBranch === "string") {
    const b = validateBranch(r.defaultBranch);
    if (b.ok) out.defaultBranch = b.value;
  }
  if (typeof r.logoHue === "number" && Number.isInteger(r.logoHue) && r.logoHue >= 0) {
    out.logoHue = r.logoHue;
  }
  return out;
}
