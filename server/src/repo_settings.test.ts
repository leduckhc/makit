import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";

import {
  defaultWorktreeRoot,
  parseRepoSettings,
  resolveProvider,
  resolveWorktreeRoot,
  validateBranch,
  validateProvider,
  validateWorktreeRoot,
} from "./repo_settings.js";

/** A throwaway "home" so the containment rule can be exercised for real. */
function home(): string {
  return mkdtempSync(join(tmpdir(), "makit-home-"));
}

// ---------------------------------------------------------------------------
// Resolution: the effective value AND its source, because the UI labels it.
// ---------------------------------------------------------------------------

test("an override wins, and is reported as an override", () => {
  const r = resolveWorktreeRoot({ worktreeRoot: "/h/custom" }, { MAKIT_WORKTREE_DIR: "/h/env" }, "/h");
  assert.deepEqual(r, { value: "/h/custom", source: "override" });
});

test("with no override the env var is used, and named as the environment", () => {
  // Named, because the app cannot change the daemon's env and must render it
  // read-only rather than offering an edit that would silently fail.
  const r = resolveWorktreeRoot({}, { MAKIT_WORKTREE_DIR: "/h/env" }, "/h");
  assert.deepEqual(r, { value: "/h/env", source: "environment" });
});

test("with neither, the built-in default is used", () => {
  const r = resolveWorktreeRoot(undefined, {}, "/h");
  assert.deepEqual(r, { value: join("/h", ".worktrees"), source: "default" });
  assert.equal(defaultWorktreeRoot("/h"), join("/h", ".worktrees"));
});

test("an exported-but-empty env var falls through to the default", () => {
  // Honouring "" would create worktrees at the filesystem root.
  const r = resolveWorktreeRoot({}, { MAKIT_WORKTREE_DIR: "" }, "/h");
  assert.equal(r.source, "default");
});

test("an empty override string is not an override", () => {
  const r = resolveWorktreeRoot({ worktreeRoot: "" }, {}, "/h");
  assert.equal(r.source, "default");
});

test("provider resolves to auto when unset, and to an override when set", () => {
  assert.deepEqual(resolveProvider(undefined), { value: "auto", source: "default" });
  assert.deepEqual(resolveProvider({ provider: "none" }), { value: "none", source: "override" });
});

// ---------------------------------------------------------------------------
// Validation. Each case is chosen to reach a DIFFERENT rule, in the order the
// rules actually run — a case that trips an earlier rule proves nothing about a
// later one.
// ---------------------------------------------------------------------------

test("a relative path is rejected by the absolute rule", () => {
  const v = validateWorktreeRoot("work/trees", "/h");
  assert.equal(v.ok, false);
  assert.match((v as { error: string }).error, /absolute/i);
});

test("an absolute path containing '..' is rejected ON SIGHT, not collapsed", () => {
  // Collapsing would yield a valid path that is not the one the user typed.
  const h = home();
  // Built by string concatenation, NOT `path.join`: join collapses `..` itself, so
  // a joined path can never exercise this rule.
  const v = validateWorktreeRoot(`${h}${sep}work${sep}..${sep}..${sep}etc`, h);
  assert.equal(v.ok, false);
  assert.match((v as { error: string }).error, /\.\./);
});

test("a not-yet-existing root is ACCEPTED and canonicalised via its ancestor", () => {
  // The common case: the user names a directory before creating it. `realpath`
  // fails outright on a missing path, so a naive rule would reject this.
  const h = home();
  const v = validateWorktreeRoot(join(h, "work", "trees", "deep"), h);
  assert.equal(v.ok, true);
  // Compared against the REAL home: on macOS /var is a symlink to /private/var, so
  // the canonicalised result legitimately differs from the input. Resolving that is
  // the point of the rule, not a bug in it.
  assert.equal(
    (v as { value: string }).value,
    join(realpathSync(h), "work", "trees", "deep"),
  );
});

test("an existing root is stored canonicalised", () => {
  const h = home();
  mkdirSync(join(h, "trees"));
  const v = validateWorktreeRoot(join(h, "trees"), h);
  assert.equal(v.ok, true);
  assert.ok((v as { value: string }).value.endsWith(`${sep}trees`));
});

test("a symlink whose target escapes home is rejected", () => {
  // Reached with a REAL symlink: a '..' string is rejected by the earlier rule and
  // never gets here, so it cannot exercise canonicalisation.
  const h = home();
  const outside = mkdtempSync(join(tmpdir(), "makit-outside-"));
  symlinkSync(outside, join(h, "escape"));
  const v = validateWorktreeRoot(join(h, "escape", "trees"), h);
  assert.equal(v.ok, false);
  assert.match((v as { error: string }).error, /home directory/i);
});

test("a path outside home is rejected even when it exists", () => {
  const h = home();
  const v = validateWorktreeRoot(tmpdir(), h);
  assert.equal(v.ok, false);
});

test("a file where a directory is required is rejected", () => {
  const h = home();
  writeFileSync(join(h, "afile"), "x");
  const v = validateWorktreeRoot(join(h, "afile"), h);
  assert.equal(v.ok, false);
  assert.match((v as { error: string }).error, /not a directory/i);
});

test("empty input is rejected", () => {
  assert.equal(validateWorktreeRoot("   ", "/h").ok, false);
});

test("home itself is allowed", () => {
  const h = home();
  assert.equal(validateWorktreeRoot(h, h).ok, true);
});

// ---------------------------------------------------------------------------
// Provider + branch
// ---------------------------------------------------------------------------

test("provider accepts exactly the five choices and nothing else", () => {
  for (const p of ["auto", "none", "forgejo", "gitea", "github"]) {
    assert.equal(validateProvider(p).ok, true, p);
  }
  for (const bad of ["gitlab", "", "GITHUB", 7, null, undefined]) {
    assert.equal(validateProvider(bad).ok, false, String(bad));
  }
});

test("branch validation rejects what git itself would refuse", () => {
  assert.equal(validateBranch("main").ok, true);
  assert.equal(validateBranch("feat/thing-1").ok, true);
  for (const bad of ["", "  ", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a..b", "-lead", "x.lock"]) {
    assert.equal(validateBranch(bad).ok, false, JSON.stringify(bad));
  }
});

// ---------------------------------------------------------------------------
// Defensive parse: a hand-edited file must never stop the daemon.
// ---------------------------------------------------------------------------

test("a known key of the wrong type is dropped, not trusted", () => {
  // `worktreeRoot: 42` must never reach path handling.
  assert.deepEqual(parseRepoSettings({ worktreeRoot: 42 }), {});
  assert.deepEqual(parseRepoSettings({ provider: "gitlab" }), {});
  assert.deepEqual(parseRepoSettings({ defaultBranch: "a b" }), {});
  assert.deepEqual(parseRepoSettings({ logoHue: -1 }), {});
  assert.deepEqual(parseRepoSettings({ logoHue: 1.5 }), {});
});

test("a non-object degrades to inherit-everything rather than throwing", () => {
  for (const bad of [null, undefined, 7, "x", []]) {
    assert.deepEqual(parseRepoSettings(bad), {});
  }
});

test("provider 'auto' is not stored — the default stays implicit", () => {
  assert.deepEqual(parseRepoSettings({ provider: "auto" }), {});
});

test("valid values survive the parse", () => {
  assert.deepEqual(
    parseRepoSettings({
      worktreeRoot: "/h/trees",
      provider: "gitea",
      defaultBranch: "develop",
      logoHue: 3,
    }),
    { worktreeRoot: "/h/trees", provider: "gitea", defaultBranch: "develop", logoHue: 3 },
  );
});
