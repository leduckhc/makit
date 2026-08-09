import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { resolveDocPath, isInsideRoot, MAX_DOC_BYTES } from "./resolve.js";

/**
 * The security boundary of SPEC-46 (D2). Every path that reaches the serving
 * layer goes through resolveDocPath, so this suite is the one that must be
 * paranoid: traversal, prefix confusion, escaping symlinks, extension and
 * dotfile policy, and the size cap.
 */

/** A worktree with the shape this repo actually has. Returns the real root. */
function fixture(): string {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "makit-docs-")));
  const root = join(base, "repo");
  mkdirSync(join(root, "mockups"), { recursive: true });
  mkdirSync(join(root, "docs", "specs"), { recursive: true });
  mkdirSync(join(root, ".git"), { recursive: true });
  writeFileSync(join(root, "mockups", "board.html"), "<title>Board</title>");
  writeFileSync(join(root, "docs", "specs", "spec.md"), "# Spec\n");
  writeFileSync(join(root, ".git", "config"), "[remote]\n  token = hunter2\n");
  writeFileSync(join(root, ".env"), "SECRET=1\n");
  writeFileSync(join(root, "README.md"), "# Readme\n");
  // A sibling directory whose name shares a textual prefix with the root.
  mkdirSync(join(base, "repo-evil"), { recursive: true });
  writeFileSync(join(base, "repo-evil", "steal.md"), "# not yours\n");
  return root;
}

test("accepts an allowlisted file inside the worktree", () => {
  const root = fixture();
  const got = resolveDocPath(root, "mockups/board.html");
  assert.equal(got.ok, true);
  assert.equal(got.ok && got.absPath, join(root, "mockups", "board.html"));
  assert.equal(got.ok && got.kind, "html");
});

test("classifies markdown by extension", () => {
  const root = fixture();
  const got = resolveDocPath(root, "docs/specs/spec.md");
  assert.equal(got.ok && got.kind, "md");
});

test("rejects a traversal escape", () => {
  const root = fixture();
  for (const rel of [
    "../repo-evil/steal.md",
    "mockups/../../repo-evil/steal.md",
    "mockups/../.env",
    "..%2Frepo-evil%2Fsteal.md",
  ]) {
    const got = resolveDocPath(root, rel);
    assert.equal(got.ok, false, `expected rejection for ${rel}`);
  }
});

test("rejects an absolute path", () => {
  const root = fixture();
  assert.equal(resolveDocPath(root, join(root, "README.md")).ok, false);
  assert.equal(resolveDocPath(root, "/etc/passwd").ok, false);
});

test("rejects prefix confusion: <root>-evil must not pass as inside <root>", () => {
  const root = fixture();
  // This must NOT go through a ".." relPath — that is rejected by the segment
  // rule long before the containment check, which made an earlier version of
  // this test vacuous. A symlink reaches the containment check with a clean
  // relPath, and "<base>/repo-evil/steal.md".startsWith("<base>/repo") is true,
  // so only a segment-aware comparison rejects it.
  symlinkSync(join(root, "..", "repo-evil", "steal.md"), join(root, "docs", "sibling.md"));
  const got = resolveDocPath(root, "docs/sibling.md");
  assert.equal(got.ok, false);
  assert.equal(got.ok === false && got.reason, "escapes-root");
});

test("treats the worktree root itself as not a document", () => {
  const root = fixture();
  assert.equal(isInsideRoot(root, root), false);
  assert.equal(isInsideRoot(root, root + "-evil"), false);
  assert.equal(isInsideRoot(root, join(root, "README.md")), true);
});

test("rejects a symlink whose target escapes the worktree", () => {
  const root = fixture();
  const outside = join(root, "..", "repo-evil", "steal.md");
  symlinkSync(outside, join(root, "docs", "leak.md"));
  const got = resolveDocPath(root, "docs/leak.md");
  assert.equal(got.ok, false, "an escaping symlink must not resolve");
});

test("allows a symlink that stays inside the worktree", () => {
  const root = fixture();
  symlinkSync(join(root, "docs", "specs", "spec.md"), join(root, "docs", "alias.md"));
  const got = resolveDocPath(root, "docs/alias.md");
  assert.equal(got.ok, true);
});

test("rejects any extension outside the allowlist", () => {
  const root = fixture();
  writeFileSync(join(root, "docs", "key.pem"), "-----BEGIN-----");
  writeFileSync(join(root, "docs", "notes.txt"), "hi");
  for (const rel of ["docs/key.pem", "docs/notes.txt", "docs/specs"]) {
    assert.equal(resolveDocPath(root, rel).ok, false, `expected rejection for ${rel}`);
  }
});

test("rejects dotfiles and anything inside a dot-directory", () => {
  const root = fixture();
  // .env is not allowlisted by extension either, but .git/config.md would be —
  // so the dot-directory rule has to bite independently.
  writeFileSync(join(root, ".git", "notes.md"), "# leaked\n");
  writeFileSync(join(root, ".secret.md"), "# leaked\n");
  assert.equal(resolveDocPath(root, ".git/notes.md").ok, false);
  assert.equal(resolveDocPath(root, ".secret.md").ok, false);
  assert.equal(resolveDocPath(root, ".env").ok, false);
});

test("rejects excluded build directories even with an allowed extension", () => {
  const root = fixture();
  for (const dir of ["node_modules", "build", "dist", "coverage"]) {
    mkdirSync(join(root, dir), { recursive: true });
    writeFileSync(join(root, dir, "readme.md"), "# vendored\n");
    assert.equal(resolveDocPath(root, `${dir}/readme.md`).ok, false, `expected rejection for ${dir}`);
  }
});

test("rejects a file over the size cap", () => {
  const root = fixture();
  writeFileSync(join(root, "mockups", "huge.html"), "x".repeat(MAX_DOC_BYTES + 1));
  assert.equal(resolveDocPath(root, "mockups/huge.html").ok, false);
});

test("rejects a missing file and a directory", () => {
  const root = fixture();
  assert.equal(resolveDocPath(root, "mockups/nope.html").ok, false);
  assert.equal(resolveDocPath(root, "mockups").ok, false);
});

test("rejects an empty or non-string relPath rather than resolving to the root", () => {
  const root = fixture();
  for (const rel of ["", ".", "./", undefined as unknown as string]) {
    assert.equal(resolveDocPath(root, rel).ok, false, `expected rejection for ${JSON.stringify(rel)}`);
  }
});
