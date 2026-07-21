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
  renameBranch,
  isGitRepo,
  normalizeChecks,
  rollupChecks,
  uncommittedFileCount,
  unresolvedReviewThreadCount,
  commitsAhead,
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

test("renameBranch renames the worktree's checked-out branch", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const wtPath = await addWorktree({
      repoPath: repo,
      name: "feature-x",
      branch: "old-name",
      baseBranch: "main",
      baseDir: base,
    });
    await renameBranch(wtPath, "old-name", "new-name");
    const after = await listWorktrees(repo);
    const wt = after.find((w) => w.path === wtPath);
    assert.equal(wt!.branch, "new-name");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("removeWorktree throws when git cannot remove the path", async () => {
  const repo = makeRepo();
  try {
    // Not a registered worktree of this repo: git refuses, and the failure must
    // surface rather than resolve as a false success.
    await assert.rejects(
      () => removeWorktree(repo, join(tmpdir(), "makit-not-a-worktree-xyz"), true),
      /git worktree remove .* failed/,
    );
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

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
    assert.equal(await uncommittedFileCount(plain), 0);
  } finally {
    rmSync(plain, { recursive: true, force: true });
  }
});

test("uncommittedFileCount counts staged, unstaged, and untracked files", async () => {
  const repo = makeRepo();
  try {
    assert.equal(await uncommittedFileCount(repo), 0);
    const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
    // Modify a tracked file (unstaged), stage a new file, add an untracked one.
    writeFileSync(join(repo, "README.md"), "hello\nchanged\n");
    writeFileSync(join(repo, "staged.txt"), "s\n");
    g("add", "staged.txt");
    writeFileSync(join(repo, "untracked.txt"), "u\n");
    assert.equal(await uncommittedFileCount(repo), 3);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("unresolvedReviewThreadCount returns 0 for a non-parseable PR URL", async () => {
  // A non-GitHub URL short-circuits before any `gh` call.
  assert.equal(await unresolvedReviewThreadCount(process.cwd(), "https://example.com/x"), 0);
  assert.equal(await unresolvedReviewThreadCount(process.cwd(), ""), 0);
});

test("commitsAhead counts commits ahead of the base branch when no upstream", async () => {
  const repo = makeRepo();
  try {
    const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
    // main has no commits ahead of itself.
    assert.equal(await commitsAhead(repo, "main"), 0);
    // A branch with two extra commits and no upstream: ahead of main by 2.
    g("checkout", "-q", "-b", "feature");
    writeFileSync(join(repo, "a.txt"), "a\n");
    g("add", "a.txt");
    g("commit", "-q", "-m", "a");
    writeFileSync(join(repo, "b.txt"), "b\n");
    g("add", "b.txt");
    g("commit", "-q", "-m", "b");
    assert.equal(await commitsAhead(repo, "main"), 2);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("normalizeChecks maps CheckRun and StatusContext shapes to flat buckets", () => {
  const rollup = [
    // CheckRun: completed + success
    { __typename: "CheckRun", name: "test", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "u1", workflowName: "CI" },
    // CheckRun: still running
    { __typename: "CheckRun", name: "build", status: "IN_PROGRESS", detailsUrl: "u2", workflowName: "CI" },
    // CheckRun: failure
    { __typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "u3", workflowName: "CI" },
    // CheckRun: skipped
    { __typename: "CheckRun", name: "e2e", status: "COMPLETED", conclusion: "SKIPPED" },
    // CheckRun: cancelled
    { __typename: "CheckRun", name: "slow", status: "COMPLETED", conclusion: "CANCELLED" },
    // StatusContext: legacy success
    { __typename: "StatusContext", context: "CodeRabbit", state: "SUCCESS", targetUrl: "u6" },
    // StatusContext: legacy pending
    { __typename: "StatusContext", context: "deploy", state: "PENDING", targetUrl: "" },
  ];
  const checks = normalizeChecks(rollup);
  assert.deepEqual(
    checks.map((c) => [c.name, c.bucket]),
    [
      ["test", "pass"],
      ["build", "pending"],
      ["lint", "fail"],
      ["e2e", "skipping"],
      ["slow", "cancel"],
      ["CodeRabbit", "pass"],
      ["deploy", "pending"],
    ],
  );
  // CheckRun keeps its workflow/detailsUrl; StatusContext maps targetUrl → detailsUrl.
  assert.equal(checks[0].workflowName, "CI");
  assert.equal(checks[0].detailsUrl, "u1");
  assert.equal(checks[5].workflowName, null);
  assert.equal(checks[5].detailsUrl, "u6");
});

test("normalizeChecks tolerates non-array / missing rollup", () => {
  assert.deepEqual(normalizeChecks(undefined), []);
  assert.deepEqual(normalizeChecks(null), []);
  assert.deepEqual(normalizeChecks("nope"), []);
});

test("rollupChecks: fail dominates, then pending, then pass, else none", () => {
  const mk = (bucket: string) => ({ name: "x", bucket, workflowName: null, detailsUrl: null }) as never;
  assert.equal(rollupChecks([]), "none");
  assert.equal(rollupChecks([mk("skipping")]), "none");
  assert.equal(rollupChecks([mk("pass"), mk("skipping")]), "pass");
  assert.equal(rollupChecks([mk("pass"), mk("pending")]), "pending");
  assert.equal(rollupChecks([mk("pending"), mk("fail")]), "fail");
  assert.equal(rollupChecks([mk("pass"), mk("cancel")]), "fail");
});
