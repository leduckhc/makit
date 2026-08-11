import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resolveDocRoots } from "./roots.js";

/** A worktree root with no `.makit/docs.json`. */
function bareWorktree(): string {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "makit-roots-")));
  const root = join(base, "repo");
  mkdirSync(root, { recursive: true });
  return root;
}

function withConfig(json: string): string {
  const root = bareWorktree();
  mkdirSync(join(root, ".makit"), { recursive: true });
  writeFileSync(join(root, ".makit", "docs.json"), json);
  return root;
}

// D1 rev 2: with no config the index is git's view, so there are no dirs to
// name. The allowlist survives only as the fallback inside the lister.
test("defaults to the git-wide index when there is no config", () => {
  const roots = resolveDocRoots(bareWorktree());
  assert.equal(roots.kind, "git");
  assert.deepEqual(roots.exclude, []);
});

test("a configured roots list narrows the index to a walk of exactly those", () => {
  const roots = resolveDocRoots(withConfig('{"roots":["docs",".agents/skills"]}'));
  assert.equal(roots.kind, "walk");
  if (roots.kind !== "walk") return;
  assert.deepEqual(roots.dirs, ["docs", ".agents/skills"]);
  // Naming roots opts out of the implicit root-markdown scan.
  assert.equal(roots.rootMarkdown, false);
});

test("an exclude list applies without narrowing the index", () => {
  const roots = resolveDocRoots(withConfig('{"exclude":["docs/archive"]}'));
  assert.equal(roots.kind, "git");
  assert.deepEqual(roots.exclude, ["docs/archive"]);
});

test("a malformed config falls back to the default rather than throwing", () => {
  assert.equal(resolveDocRoots(withConfig("{ this is not json")).kind, "git");
});

test("a config whose roots is not a string array is ignored", () => {
  assert.equal(resolveDocRoots(withConfig('{"roots":[1,2,3]}')).kind, "git");
});

test("rejects a configured root that escapes the worktree", () => {
  const roots = resolveDocRoots(withConfig('{"roots":["docs","../../etc","/abs"]}'));
  assert.equal(roots.kind, "walk");
  if (roots.kind !== "walk") return;
  // Only the contained root survives; `..` and absolute roots are dropped.
  assert.deepEqual(roots.dirs, ["docs"]);
});

test("an unreadable/absent config file falls back to the default", () => {
  // A worktree that does not even exist on disk must not throw.
  assert.equal(resolveDocRoots("/no/such/worktree/anywhere").kind, "git");
});

test("an oversize config is treated as malformed, not read into memory", () => {
  // `.makit/docs.json` is user-supplied and unbounded; a huge file must degrade
  // to the default rather than block the event loop on every re-index.
  const big = '{"exclude":["' + "x".repeat(128 * 1024) + '"]}';
  const roots = resolveDocRoots(withConfig(big));
  assert.equal(roots.kind, "git");
  assert.deepEqual(roots.exclude, [], "an over-cap config yields the default, not its contents");
});
