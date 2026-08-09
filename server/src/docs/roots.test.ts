import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resolveDocRoots, DEFAULT_DOC_DIRS } from "./roots.js";

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

test("defaults to mockups/, docs/ and root markdown when there is no config", () => {
  const roots = resolveDocRoots(bareWorktree());
  assert.deepEqual(roots.dirs, DEFAULT_DOC_DIRS);
  assert.equal(roots.rootMarkdown, true);
  assert.deepEqual(roots.exclude, []);
});

test("honours a configured roots list, replacing the defaults", () => {
  const roots = resolveDocRoots(withConfig('{"roots":["docs",".agents/skills"]}'));
  assert.deepEqual(roots.dirs, ["docs", ".agents/skills"]);
  // A user who lists roots explicitly opts out of the implicit root-markdown scan.
  assert.equal(roots.rootMarkdown, false);
});

test("honours a configured exclude list", () => {
  const roots = resolveDocRoots(withConfig('{"exclude":["docs/archive"]}'));
  assert.deepEqual(roots.dirs, DEFAULT_DOC_DIRS);
  assert.deepEqual(roots.exclude, ["docs/archive"]);
});

test("a malformed config falls back to defaults rather than throwing", () => {
  const roots = resolveDocRoots(withConfig("{ this is not json"));
  assert.deepEqual(roots.dirs, DEFAULT_DOC_DIRS);
  assert.equal(roots.rootMarkdown, true);
});

test("a config whose roots is not a string array is ignored", () => {
  const roots = resolveDocRoots(withConfig('{"roots":[1,2,3]}'));
  assert.deepEqual(roots.dirs, DEFAULT_DOC_DIRS);
});

test("rejects a configured root that escapes the worktree", () => {
  const roots = resolveDocRoots(withConfig('{"roots":["docs","../../etc","/abs"]}'));
  // Only the contained root survives; `..` and absolute roots are dropped.
  assert.deepEqual(roots.dirs, ["docs"]);
});

test("an unreadable/absent config file falls back to defaults", () => {
  // A worktree that does not even exist on disk must not throw.
  const roots = resolveDocRoots("/no/such/worktree/anywhere");
  assert.deepEqual(roots.dirs, DEFAULT_DOC_DIRS);
});
