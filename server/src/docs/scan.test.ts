import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { scanWorktree } from "./scan.js";
import type { DocDTO } from "../protocol.js";

/**
 * A worktree with the four things the walk must get right: allowlisted files in
 * roots, an excluded directory (never descended), a dot-directory, and a
 * root-level markdown file.
 */
function fixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-scan-")));
  mkdirSync(join(root, "mockups"), { recursive: true });
  mkdirSync(join(root, "docs", "specs"), { recursive: true });
  mkdirSync(join(root, "node_modules", "pkg"), { recursive: true });
  mkdirSync(join(root, ".hidden"), { recursive: true });

  writeFileSync(join(root, "mockups", "board.html"), "<title>The Board</title>");
  writeFileSync(join(root, "docs", "specs", "spec.md"), "# The Spec\n**Status:** Draft\n");
  writeFileSync(join(root, "README.md"), "# Readme\n");
  // These must never appear in the index.
  writeFileSync(join(root, "node_modules", "pkg", "readme.md"), "# secret dep\n");
  writeFileSync(join(root, ".hidden", "notes.md"), "# hidden\n");
  writeFileSync(join(root, "docs", "notdoc.txt"), "not a doc\n");

  // mtimes: board newest, spec middle, readme oldest — the sort must reflect this.
  utimesSync(join(root, "mockups", "board.html"), new Date(3000), new Date(3000));
  utimesSync(join(root, "docs", "specs", "spec.md"), new Date(2000), new Date(2000));
  utimesSync(join(root, "README.md"), new Date(1000), new Date(1000));
  return root;
}

test("indexes allowlisted docs across the roots and root markdown", async () => {
  const { docs, scanOk } = await scanWorktree(fixture());
  assert.equal(scanOk, true);
  const rels = docs.map((d) => d.relPath).sort();
  assert.deepEqual(rels, ["README.md", "docs/specs/spec.md", "mockups/board.html"]);
});

test("never descends into excluded or dot directories", async () => {
  const { docs } = await scanWorktree(fixture());
  const rels = docs.map((d) => d.relPath);
  assert.ok(!rels.some((r) => r.includes("node_modules")), "node_modules was walked");
  assert.ok(!rels.some((r) => r.includes(".hidden")), "a dot-directory was walked");
});

test("extracts title, kind, bytes, mtime and status", async () => {
  const { docs } = await scanWorktree(fixture());
  const spec = docs.find((d) => d.relPath === "docs/specs/spec.md")!;
  assert.equal(spec.title, "The Spec");
  assert.equal(spec.kind, "md");
  assert.equal(spec.docStatus, "Draft");
  assert.equal(spec.modifiedAt, 2000);
  assert.ok(spec.bytes > 0);

  const board = docs.find((d) => d.relPath === "mockups/board.html")!;
  assert.equal(board.title, "The Board");
  assert.equal(board.kind, "html");
});

test("the key is <worktreePath>:<relPath> and worktreePath is set", async () => {
  const root = fixture();
  const { docs } = await scanWorktree(root);
  const readme = docs.find((d) => d.relPath === "README.md")!;
  assert.equal(readme.key, `${root}:README.md`);
  assert.equal(readme.worktreePath, root);
});

test("sorts by mtime descending within the worktree", async () => {
  const { docs } = await scanWorktree(fixture());
  assert.deepEqual(
    docs.map((d) => d.relPath),
    ["mockups/board.html", "docs/specs/spec.md", "README.md"],
  );
});

test("does not carry changed or sessionId — those are enriched later", async () => {
  const { docs } = await scanWorktree(fixture());
  for (const d of docs) {
    assert.equal(d.changed, undefined);
    assert.equal(d.sessionId, undefined);
  }
});

test("an unreadable file is skipped without failing the walk (scanOk stays true)", async () => {
  const root = fixture();
  // Inject a meta reader that throws for the spec: the walk must skip it and
  // keep going — scanOk means "the walk ran", not "the list is complete".
  const { docs, scanOk } = await scanWorktree(root, {
    readMeta: (absPath, kind) => {
      if (absPath.endsWith("spec.md")) throw new Error("boom");
      return { title: absPath.split("/").pop()!, ...(kind === "md" ? {} : {}) };
    },
  });
  assert.equal(scanOk, true);
  const rels = docs.map((d) => d.relPath);
  assert.ok(!rels.includes("docs/specs/spec.md"), "the unreadable file was included");
  assert.ok(rels.includes("mockups/board.html"), "the walk stopped early");
});

test("honours a configured exclude before descending", async () => {
  const root = fixture();
  mkdirSync(join(root, ".makit"), { recursive: true });
  writeFileSync(join(root, ".makit", "docs.json"), '{"exclude":["docs/specs"]}');
  const { docs } = await scanWorktree(root);
  const rels = docs.map((d) => d.relPath);
  assert.ok(!rels.includes("docs/specs/spec.md"), "the excluded dir was still walked");
  assert.ok(rels.includes("mockups/board.html"));
});

/**
 * A worktree laid out like a real *other* project: docs live in a directory that
 * D1's `mockups/`+`docs/` allowlist never heard of, one doc is gitignored, and
 * one sits in an ignored build directory. This is the teachme case — 3 docs
 * found where 69 exist — and the reason D1 grew a rev 2.
 */
function gitFixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-scan-git-")));
  mkdirSync(join(root, "flutter", "learning-records"), { recursive: true });
  mkdirSync(join(root, "build"), { recursive: true });

  writeFileSync(join(root, "NOTES.md"), "# Notes\n");
  writeFileSync(join(root, "flutter", "MISSION.md"), "# Mission\n");
  writeFileSync(join(root, "flutter", "learning-records", "0001-prior.md"), "# Prior knowledge\n");
  writeFileSync(join(root, "page.html"), "<title>A Page</title>");
  // Ignored: must never be indexed, so a gitignored secret cannot be served.
  writeFileSync(join(root, ".gitignore"), "secrets.md\nbuild/\n");
  writeFileSync(join(root, "secrets.md"), "# tokens\n");
  writeFileSync(join(root, "build", "generated.md"), "# generated\n");

  execFileSync("git", ["init", "-q"], { cwd: root });
  execFileSync("git", ["add", "-A"], { cwd: root });
  return root;
}

test("D1 rev 2: indexes docs anywhere in the worktree, not just the old allowlist", async () => {
  const { docs, scanOk } = await scanWorktree(gitFixture());
  assert.equal(scanOk, true);
  const rels = docs.map((d) => d.relPath).sort();
  assert.deepEqual(rels, [
    "NOTES.md",
    "flutter/MISSION.md",
    "flutter/learning-records/0001-prior.md",
    "page.html",
  ]);
});

test("D1 rev 2: a gitignored doc is never indexed", async () => {
  const result = await scanWorktree(gitFixture());
  const rels = result.docs.map((d: DocDTO) => d.relPath);
  assert.ok(!rels.includes("secrets.md"), "a gitignored file must not become servable");
  assert.ok(!rels.includes("build/generated.md"), "an ignored build dir must stay out");
});

// D1 rev 2 inverts what `.makit/docs.json` roots are FOR: the index is now
// whole-worktree by default, so naming roots is how a project narrows it back
// down. That must beat git's list, or a project could not opt out of the breadth.
test("D1 rev 2: an explicit roots config narrows the index, beating git's list", async () => {
  const root = gitFixture();
  const { docs } = await scanWorktree(root, {
    resolveRoots: () => ({
      kind: "walk" as const,
      dirs: ["flutter/learning-records"],
      rootMarkdown: false,
      exclude: [],
    }),
  });
  assert.deepEqual(
    docs.map((d) => d.relPath),
    ["flutter/learning-records/0001-prior.md"],
    "only the named root is indexed, even though git lists four docs",
  );
});

// A worktree git cannot answer for (not a repository) must still get an index,
// or a plain directory added to makit would silently show zero docs. No
// injection needed: the fixtures are temp dirs, not repos, so every allowlist
// test above already runs through this fallback.
test("D1 rev 2: a non-git directory still gets an index, via the allowlist walk", async () => {
  const { docs, scanOk } = await scanWorktree(fixture());
  assert.equal(scanOk, true);
  assert.deepEqual(
    docs.map((d) => d.relPath).sort(),
    ["README.md", "docs/specs/spec.md", "mockups/board.html"],
  );
});
