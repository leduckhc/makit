import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  detectDefaultBranch,
  detectCurrentBranch,
  listWorktrees,
  diffStat,
  slugify,
  addWorktree,
  removeWorktree,
  isGitRepo,
} from "./git.js";

/** Init a throwaway repo with one commit on `main`. Returns its path. */
function makeRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-git-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir });
  g("init", "-q", "-b", "main");
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(dir, "README.md"), "hello\n");
  g("add", ".");
  g("commit", "-q", "-m", "initial");
  return dir;
}

test("isGitRepo distinguishes repos from plain dirs", async () => {
  const repo = makeRepo();
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    assert.equal(await isGitRepo(repo), true);
    assert.equal(await isGitRepo(plain), false);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(plain, { recursive: true, force: true });
  }
});

test("detectCurrentBranch / detectDefaultBranch report main", async () => {
  const repo = makeRepo();
  try {
    assert.equal(await detectCurrentBranch(repo), "main");
    assert.equal(await detectDefaultBranch(repo), "main");
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("detectDefaultBranch falls back to master when present", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-git-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir });
  try {
    g("init", "-q", "-b", "master");
    g("config", "user.email", "t@t.io");
    g("config", "user.name", "Test");
    writeFileSync(join(dir, "f.txt"), "x\n");
    g("add", ".");
    g("commit", "-q", "-m", "init");
    assert.equal(await detectDefaultBranch(dir), "master");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("listWorktrees returns the primary tree, then added worktrees", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const first = await listWorktrees(repo);
    assert.equal(first.length, 1);
    assert.equal(first[0].isPrimary, true);
    assert.equal(first[0].branch, "main");

    const wtPath = await addWorktree({
      repoPath: repo,
      name: "feature-x",
      branch: "makit/feature-x",
      baseBranch: "main",
      baseDir: base,
    });

    const after = await listWorktrees(repo);
    assert.equal(after.length, 2);
    const added = after.find((w) => w.path === wtPath);
    assert.ok(added, "added worktree should be listed");
    assert.equal(added!.branch, "makit/feature-x");
    assert.equal(added!.isPrimary, false);

    await removeWorktree(repo, wtPath, true);
    assert.equal((await listWorktrees(repo)).length, 1);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("diffStat counts committed + uncommitted + untracked changes vs base", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const wtPath = await addWorktree({
      repoPath: repo,
      name: "work",
      branch: "makit/work",
      baseBranch: "main",
      baseDir: base,
    });
    const g = (...args: string[]) => execFileSync("git", args, { cwd: wtPath });

    // A committed change on the branch: append two lines to README.
    writeFileSync(join(wtPath, "README.md"), "hello\nline2\nline3\n");
    g("add", ".");
    g("commit", "-q", "-m", "add lines");

    // An uncommitted new (untracked) file.
    writeFileSync(join(wtPath, "new.txt"), "fresh\n");

    const stat = await diffStat(wtPath, "main");
    assert.equal(stat.insertions >= 2, true, `insertions ${stat.insertions}`);
    assert.equal(stat.filesChanged >= 2, true, `files ${stat.filesChanged}`);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("slugify produces git-safe kebab-case and caps words", () => {
  assert.equal(slugify("Add a login form to the app!"), "add-a-login-form-to-the");
  assert.equal(slugify("   Fix   the:: BUG  "), "fix-the-bug");
  assert.equal(slugify("!!! ???"), "");
  assert.equal(slugify("hi"), "hi");
});

test("read helpers degrade gracefully on a non-repo path", async () => {
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    assert.equal(await detectDefaultBranch(plain), null);
    assert.equal(await detectCurrentBranch(plain), null);
    assert.deepEqual(await listWorktrees(plain), []);
    assert.deepEqual(await diffStat(plain, "main"), { insertions: 0, deletions: 0, filesChanged: 0 });
  } finally {
    rmSync(plain, { recursive: true, force: true });
  }
});
