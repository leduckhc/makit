import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { scanWorktree } from "./scan.js";

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

test("indexes allowlisted docs across the roots and root markdown", () => {
  const { docs, scanOk } = scanWorktree(fixture());
  assert.equal(scanOk, true);
  const rels = docs.map((d) => d.relPath).sort();
  assert.deepEqual(rels, ["README.md", "docs/specs/spec.md", "mockups/board.html"]);
});

test("never descends into excluded or dot directories", () => {
  const { docs } = scanWorktree(fixture());
  const rels = docs.map((d) => d.relPath);
  assert.ok(!rels.some((r) => r.includes("node_modules")), "node_modules was walked");
  assert.ok(!rels.some((r) => r.includes(".hidden")), "a dot-directory was walked");
});

test("extracts title, kind, bytes, mtime and status", () => {
  const { docs } = scanWorktree(fixture());
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

test("the key is <worktreePath>:<relPath> and worktreePath is set", () => {
  const root = fixture();
  const { docs } = scanWorktree(root);
  const readme = docs.find((d) => d.relPath === "README.md")!;
  assert.equal(readme.key, `${root}:README.md`);
  assert.equal(readme.worktreePath, root);
});

test("sorts by mtime descending within the worktree", () => {
  const { docs } = scanWorktree(fixture());
  assert.deepEqual(
    docs.map((d) => d.relPath),
    ["mockups/board.html", "docs/specs/spec.md", "README.md"],
  );
});

test("does not carry changed or sessionId — those are enriched later", () => {
  const { docs } = scanWorktree(fixture());
  for (const d of docs) {
    assert.equal(d.changed, undefined);
    assert.equal(d.sessionId, undefined);
  }
});

test("an unreadable file is skipped without failing the walk (scanOk stays true)", () => {
  const root = fixture();
  // Inject a meta reader that throws for the spec: the walk must skip it and
  // keep going — scanOk means "the walk ran", not "the list is complete".
  const { docs, scanOk } = scanWorktree(root, {
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

test("honours a configured exclude before descending", () => {
  const root = fixture();
  mkdirSync(join(root, ".makit"), { recursive: true });
  writeFileSync(join(root, ".makit", "docs.json"), '{"exclude":["docs/specs"]}');
  const { docs } = scanWorktree(root);
  const rels = docs.map((d) => d.relPath);
  assert.ok(!rels.includes("docs/specs/spec.md"), "the excluded dir was still walked");
  assert.ok(rels.includes("mockups/board.html"));
});
