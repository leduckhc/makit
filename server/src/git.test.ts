import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  detectDefaultBranch,
  detectCurrentBranch,
  listWorktrees,
  diffStat,
  slugify,
  slugifyBranch,
  addWorktree,
  removeWorktree,
  renameBranch,
  isGitRepo,
  normalizeChecks,
  rollupChecks,
  uncommittedFileCount,
  commitsAhead,
  commitsBehind,
  syncBaseBranch,
  deleteBranch,
  branchExists,
  listLocalBranches,
  listRemoteBranchNames,
  hasAnyRemote,
  closestAncestorBranch,
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
      startPoint: "main",
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
      startPoint: "main",
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
      startPoint: "main",
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

/**
 * B5: `diffStat` used to have no error channel, so an unresolvable target
 * silently degraded to a working-tree-only count that looks like a small,
 * legitimate diff — strictly harder to notice than a zero. These pin the
 * `targetResolved` flag that lets callers suppress rather than mislead.
 */
test("diffStat reports targetResolved=true when the target resolves", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const wtPath = await addWorktree({
      repoPath: repo,
      name: "resolves",
      branch: "makit/resolves",
      startPoint: "main",
      baseDir: base,
    });
    const stat = await diffStat(wtPath, "main");
    assert.equal(stat.targetResolved, true);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("diffStat flags an unresolvable target instead of returning a partial count", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const wtPath = await addWorktree({
      repoPath: repo,
      name: "gone",
      branch: "makit/gone",
      startPoint: "main",
      baseDir: base,
    });
    const g = (...args: string[]) => execFileSync("git", args, { cwd: wtPath });
    // A committed change, so a resolvable target would report insertions.
    writeFileSync(join(wtPath, "README.md"), "hello\nline2\n");
    g("add", ".");
    g("commit", "-q", "-m", "add line");
    // ...and uncommitted work, which is the part that used to leak through as a
    // plausible small number when the committed leg failed.
    writeFileSync(join(wtPath, "dirty.txt"), "wip\n");

    const stat = await diffStat(wtPath, "no-such-branch");
    assert.equal(stat.targetResolved, false, "an absent target must be reported, not swallowed");
    // Defence in depth: a consumer that forgets the flag must degrade to
    // "nothing", not a plausible small working-tree figure. The working-tree
    // truth still lives in `uncommittedFiles`, so no information is lost.
    assert.deepEqual(
      { i: stat.insertions, d: stat.deletions, f: stat.filesChanged },
      { i: 0, d: 0, f: 0 },
      "an unresolvable target must zero the counts, not ship a partial reading",
    );
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("diffStat treats a null target as resolved (working-tree reading is intended)", async () => {
  const repo = makeRepo();
  try {
    // The primary checkout has no target; its numbers legitimately mean
    // "uncommitted", so nothing is unresolved and callers must not suppress.
    const stat = await diffStat(repo, null);
    assert.equal(stat.targetResolved, true);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("slugify produces git-safe kebab-case and caps words", () => {
  assert.equal(slugify("Add a login form to the app!"), "add-a-login-form-to-the");
  assert.equal(slugify("   Fix   the:: BUG  "), "fix-the-bug");
  assert.equal(slugify("!!! ???"), "");
  assert.equal(slugify("hi"), "hi");
});

test("slugifyBranch preserves slashes, sanitizes segments, and caps length", () => {
  // Hierarchy is kept; each segment is kebab-cased.
  assert.equal(slugifyBranch("feat/New UI"), "feat/new-ui");
  // Leading/trailing/duplicate slashes and stray punctuation are cleaned up.
  assert.equal(slugifyBranch("/feat//new::ui/"), "feat/new-ui");
  // Nothing usable -> empty (caller falls back to an auto name).
  assert.equal(slugifyBranch("!!! ///"), "");
  // Length cap trims an oversized paste and any partial trailing segment.
  const long = "a".repeat(200);
  assert.equal(slugifyBranch(long).length, 80);
  assert.equal(slugifyBranch("feat/" + "x".repeat(200), 8), "feat/xxx");
});

test("read helpers degrade gracefully on a non-repo path", async () => {
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    assert.equal(await detectDefaultBranch(plain), null);
    assert.equal(await detectCurrentBranch(plain), null);
    assert.deepEqual(await listWorktrees(plain), []);
    assert.deepEqual(await diffStat(plain, "main"), {
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      // Not a repo at all: the target could not be resolved either.
      targetResolved: false,
    });
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

test("commitsBehind counts upstream commits missing locally (0 without upstream)", async () => {
  // Two clones sharing a remote: advance the remote, then the stale clone is
  // "behind" by the number of commits it hasn't fetched.
  const remote = mkdtempSync(join(tmpdir(), "makit-remote-"));
  const a = mkdtempSync(join(tmpdir(), "makit-a-"));
  const b = mkdtempSync(join(tmpdir(), "makit-b-"));
  try {
    const ga = (...args: string[]) => execFileSync("git", args, { cwd: a });
    const gb = (...args: string[]) => execFileSync("git", args, { cwd: b });
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", remote]);
    // Clone A: seed a commit and push.
    execFileSync("git", ["clone", "-q", remote, a]);
    ga("config", "user.email", "t@t.io");
    ga("config", "user.name", "T");
    writeFileSync(join(a, "f.txt"), "1\n");
    ga("add", ".");
    ga("commit", "-q", "-m", "one");
    ga("push", "-q", "origin", "main");
    // Clone B tracks origin/main and is up to date.
    execFileSync("git", ["clone", "-q", remote, b]);
    assert.equal(await commitsBehind(b), 0);
    // A pushes two more commits; B fetches but doesn't merge → behind by 2.
    writeFileSync(join(a, "f.txt"), "2\n");
    ga("commit", "-aqm", "two");
    writeFileSync(join(a, "f.txt"), "3\n");
    ga("commit", "-aqm", "three");
    ga("push", "-q", "origin", "main");
    gb("fetch", "-q", "origin");
    assert.equal(await commitsBehind(b), 2);
  } finally {
    for (const d of [remote, a, b]) rmSync(d, { recursive: true, force: true });
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

test("uncommittedFileCount enumerates files inside nested untracked dirs", async () => {
  const repo = makeRepo();
  try {
    // A nested untracked directory: `git status --porcelain` alone collapses it
    // to a single `?? nested/` line, but --untracked-files=all lists each file.
    mkdirSync(join(repo, "nested", "deep"), { recursive: true });
    writeFileSync(join(repo, "nested", "a.txt"), "a\n");
    writeFileSync(join(repo, "nested", "deep", "b.txt"), "b\n");
    writeFileSync(join(repo, "toplevel.txt"), "x\n");
    // Two files under nested/ + one top-level = 3 (not 2 with nested/ collapsed).
    assert.equal(await uncommittedFileCount(repo), 3);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

// ── wrap up: delete the landed branch, catch the base branch up ─────────────
// A merged PR leaves two things behind that the app never cleaned up: the local
// branch, and a base branch that is now behind the remote. These cover the git
// half of `worktree.wrapUp`.

/** A bare repo to act as `origin`, plus a clone of it with one commit on main. */
function makeRepoWithOrigin(): { repo: string; origin: string } {
  const origin = mkdtempSync(join(tmpdir(), "makit-origin-"));
  execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
  const repo = mkdtempSync(join(tmpdir(), "makit-clone-"));
  execFileSync("git", ["clone", "-q", origin, repo]);
  const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(repo, "README.md"), "hello\n");
  g("add", ".");
  g("commit", "-q", "-m", "initial");
  g("push", "-q", "-u", "origin", "main");
  return { repo, origin };
}

/** Land a commit straight on `origin/main`, as a merged PR would. */
function pushToOrigin(origin: string, message: string): void {
  const scratch = mkdtempSync(join(tmpdir(), "makit-scratch-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: scratch });
  execFileSync("git", ["clone", "-q", origin, scratch]);
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(scratch, `${message}.txt`), "x\n");
  g("add", ".");
  g("commit", "-q", "-m", message);
  g("push", "-q", "origin", "main");
  rmSync(scratch, { recursive: true, force: true });
}

const headOf = (dir: string, ref: string) =>
  execFileSync("git", ["rev-parse", ref], { cwd: dir }).toString().trim();

test("syncBaseBranch fast-forwards the base branch that is checked out", async () => {
  const { repo, origin } = makeRepoWithOrigin();
  try {
    pushToOrigin(origin, "landed");
    const before = headOf(repo, "main");
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, true);
    assert.notEqual(headOf(repo, "main"), before);
    // It landed on exactly what the remote has — no merge commit.
    assert.equal(headOf(repo, "main"), headOf(repo, "origin/main"));
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
  }
});

test("syncBaseBranch reports no-op when the base is already current", async () => {
  const { repo, origin } = makeRepoWithOrigin();
  try {
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, false);
    assert.equal(result.reason, undefined, "up to date is not a failure");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
  }
});

test("syncBaseBranch refuses to clobber divergent local commits", async () => {
  const { repo, origin } = makeRepoWithOrigin();
  try {
    pushToOrigin(origin, "landed");
    // A local-only commit on main makes the update a non-fast-forward. Wrap up
    // must never discard it — losing unpushed work would be unforgivable.
    const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
    writeFileSync(join(repo, "local.txt"), "mine\n");
    g("add", ".");
    g("commit", "-q", "-m", "local only");
    const before = headOf(repo, "main");
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, false);
    assert.ok(result.reason, "it must say why it declined");
    assert.equal(headOf(repo, "main"), before, "the local commit survives");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
  }
});

test("syncBaseBranch reports git's own reason when the merge fails for another cause", async () => {
  // `merge --ff-only` fails for more than divergence: a dirty index or working
  // tree in the host worktree fails it too. Blaming "local commits" then sends
  // the user looking for a commit that is not there, and hides the one thing they
  // could act on — so git's own message travels with the refusal.
  const { repo, origin } = makeRepoWithOrigin();
  try {
    pushToOrigin(origin, "landed");
    // A conflicting *uncommitted* edit to the same file the remote moved: main is
    // still a strict ancestor of origin/main, so this is not divergence.
    writeFileSync(join(repo, "landed.txt"), "local edit, uncommitted\n");
    const before = headOf(repo, "main");
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, false);
    assert.equal(headOf(repo, "main"), before, "nothing moved");
    assert.ok(
      !/has local commits/.test(result.reason ?? ""),
      `divergence is the wrong diagnosis here, got: ${result.reason}`,
    );
    assert.match(result.reason ?? "", /could not fast-forward main/);
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
  }
});

test("syncBaseBranch updates a base branch that is not checked out anywhere", async () => {
  const { repo, origin } = makeRepoWithOrigin();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    // Park the primary checkout on another branch, so `main` is only a ref.
    execFileSync("git", ["checkout", "-q", "-b", "parked"], { cwd: repo });
    pushToOrigin(origin, "landed");
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, true);
    assert.equal(headOf(repo, "main"), headOf(repo, "origin/main"));
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("syncBaseBranch degrades quietly when there is no remote", async () => {
  // A local-only repo is legitimate; wrap up should still remove the worktree
  // and simply report that there was nothing to catch up to.
  const repo = makeRepo();
  try {
    const result = await syncBaseBranch(repo, "main");
    assert.equal(result.updated, false);
    assert.ok(result.reason);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("deleteBranch removes a merged branch", async () => {
  const repo = makeRepo();
  try {
    execFileSync("git", ["branch", "landed"], { cwd: repo });
    await deleteBranch(repo, "landed");
    assert.equal(await branchExists(repo, "landed"), false);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("deleteBranch force-deletes a branch git considers unmerged", async () => {
  // The PR merged on GitHub (often squashed), so the local branch looks
  // unmerged to git even though its content landed. `-d` would refuse.
  const repo = makeRepo();
  try {
    const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
    g("checkout", "-q", "-b", "landed");
    writeFileSync(join(repo, "f.txt"), "x\n");
    g("add", ".");
    g("commit", "-q", "-m", "work");
    g("checkout", "-q", "main");
    await deleteBranch(repo, "landed");
    assert.equal(await branchExists(repo, "landed"), false);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("deleteBranch does not throw for a branch that is already gone", async () => {
  const repo = makeRepo();
  try {
    await deleteBranch(repo, "never-existed");
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("syncBaseBranch refuses when the branch is checked out in two worktrees", async () => {
  // `git worktree add -f -f` allows it (older git spells this
  // `--ignore-other-worktrees`). Fast-forwarding the shared ref through one
  // checkout would leave the other one's index and working tree based on the old
  // commit, so it would look spuriously dirty.
  const { repo, origin } = makeRepoWithOrigin();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    execFileSync("git", ["checkout", "-q", "-b", "parked"], { cwd: repo });
    execFileSync(
      "git",
      ["worktree", "add", "-q", "-f", "-f", join(base, "a"), "main"],
      { cwd: repo },
    );
    execFileSync(
      "git",
      ["worktree", "add", "-q", "-f", "-f", join(base, "b"), "main"],
      { cwd: repo },
    );
    pushToOrigin(origin, "landed");
    const before = headOf(repo, "main");

    const result = await syncBaseBranch(repo, "main");

    assert.equal(result.updated, false);
    assert.match(String(result.reason), /more than one worktree|two worktrees/i);
    assert.equal(headOf(repo, "main"), before, "the ref is left alone");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Target-candidate primitives (phase 2: the picker)
// ─────────────────────────────────────────────────────────────────────────────

test("listLocalBranches returns every local branch, sorted", async () => {
  const repo = makeRepo();
  try {
    const g = (...args: string[]) => execFileSync("git", args, { cwd: repo });
    g("branch", "feat/b");
    g("branch", "feat/a");
    assert.deepEqual(await listLocalBranches(repo), ["feat/a", "feat/b", "main"]);
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

test("listLocalBranches is empty for a non-repo", async () => {
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    assert.deepEqual(await listLocalBranches(plain), []);
  } finally {
    rmSync(plain, { recursive: true, force: true });
  }
});

test("listRemoteBranchNames strips the remote prefix and skips HEAD", async () => {
  const origin = makeRepo();
  const clone = mkdtempSync(join(tmpdir(), "makit-clone-"));
  try {
    execFileSync("git", ["clone", "-q", origin, clone]);
    const g = (...args: string[]) => execFileSync("git", args, { cwd: clone });
    g("config", "user.email", "t@t.io");
    g("config", "user.name", "Test");
    g("checkout", "-q", "-b", "pushed-branch");
    g("push", "-q", "origin", "pushed-branch");
    g("checkout", "-q", "-b", "local-only");
    const remote = await listRemoteBranchNames(clone);
    assert.equal(remote.has("pushed-branch"), true, "a pushed branch is on the remote");
    assert.equal(remote.has("local-only"), false, "an unpushed branch is not");
    // `origin/HEAD` is a symbolic alias, not a branch a PR can target.
    assert.equal(remote.has("HEAD"), false);
    // A branch that exists only on a NON-origin remote (e.g. `upstream`) is not a
    // valid PR base — `gh` resolves against `origin` — so it must be excluded.
    execFileSync("git", ["update-ref", "refs/remotes/upstream/upstream-only", "HEAD"], {
      cwd: clone,
    });
    const remote2 = await listRemoteBranchNames(clone);
    assert.equal(
      remote2.has("upstream-only"),
      false,
      "a branch on a non-origin remote is not a PR base",
    );
  } finally {
    rmSync(origin, { recursive: true, force: true });
    rmSync(clone, { recursive: true, force: true });
  }
});

test("hasAnyRemote distinguishes a plain init from a clone", async () => {
  // Gates the whole "a PR base must exist on the remote" rule in the picker; the
  // no-remote regression it guards was found only by driving the real app.
  const origin = makeRepo();
  const clone = mkdtempSync(join(tmpdir(), "makit-clone-"));
  try {
    assert.equal(await hasAnyRemote(origin), false, "a plain `git init` has no remote");
    execFileSync("git", ["clone", "-q", origin, clone]);
    assert.equal(await hasAnyRemote(clone), true);
  } finally {
    rmSync(origin, { recursive: true, force: true });
    rmSync(clone, { recursive: true, force: true });
  }
});

test("closestAncestorBranch finds the branch a worktree forked from", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    // main -> feat/parent -> feat/child. Both main and feat/parent are ancestors
    // of the child, so "closest" is what distinguishes the real fork parent.
    const parent = await addWorktree({
      repoPath: repo,
      name: "parent",
      branch: "feat/parent",
      startPoint: "main",
      baseDir: base,
    });
    writeFileSync(join(parent, "p.txt"), "p\n");
    execFileSync("git", ["add", "."], { cwd: parent });
    execFileSync("git", ["commit", "-q", "-m", "parent"], { cwd: parent });

    const child = await addWorktree({
      repoPath: repo,
      name: "child",
      branch: "feat/child",
      startPoint: "feat/parent",
      baseDir: base,
    });
    writeFileSync(join(child, "c.txt"), "c\n");
    execFileSync("git", ["add", "."], { cwd: child });
    execFileSync("git", ["commit", "-q", "-m", "child"], { cwd: child });

    const found = await closestAncestorBranch(child, ["main", "feat/parent", "feat/child"]);
    assert.equal(found, "feat/parent");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("closestAncestorBranch ignores the worktree's own branch and non-ancestors", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    const wt = await addWorktree({
      repoPath: repo,
      name: "solo",
      branch: "feat/solo",
      startPoint: "main",
      baseDir: base,
    });
    writeFileSync(join(wt, "s.txt"), "s\n");
    execFileSync("git", ["add", "."], { cwd: wt });
    execFileSync("git", ["commit", "-q", "-m", "solo"], { cwd: wt });
    // A sibling with its OWN commit is genuinely not an ancestor of feat/solo.
    // (Branching at `main` without committing would leave it *equal* to main and
    // therefore a legitimate ancestor — which is why this needs a real commit.)
    const sib = await addWorktree({
      repoPath: repo,
      name: "sibling",
      branch: "feat/sibling",
      startPoint: "main",
      baseDir: base,
    });
    writeFileSync(join(sib, "sib.txt"), "sib\n");
    execFileSync("git", ["add", "."], { cwd: sib });
    execFileSync("git", ["commit", "-q", "-m", "sibling"], { cwd: sib });
    const found = await closestAncestorBranch(wt, ["feat/solo", "feat/sibling", "main"]);
    assert.equal(found, "main");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("closestAncestorBranch returns null when nothing qualifies", async () => {
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    assert.equal(await closestAncestorBranch(plain, ["main"]), null);
  } finally {
    rmSync(plain, { recursive: true, force: true });
  }
});

test("closestAncestorBranch breaks a distance tie by candidate order", async () => {
  const repo = makeRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wt-"));
  try {
    // `alias` points at the same commit as `main`, so both are ancestors at the
    // same distance. The caller passes candidates in preference order, so the
    // earlier one must win — deterministically, not by Object key order.
    execFileSync("git", ["branch", "alias", "main"], { cwd: repo });
    const wt = await addWorktree({
      repoPath: repo,
      name: "tie",
      branch: "feat/tie",
      startPoint: "main",
      baseDir: base,
    });
    writeFileSync(join(wt, "t.txt"), "t\n");
    execFileSync("git", ["add", "."], { cwd: wt });
    execFileSync("git", ["commit", "-q", "-m", "tie"], { cwd: wt });
    assert.equal(await closestAncestorBranch(wt, ["main", "alias"]), "main");
    assert.equal(await closestAncestorBranch(wt, ["alias", "main"]), "alias");
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});
