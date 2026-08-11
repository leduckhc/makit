/**
 * Rules 2, 3 and 4 of the target-branch contract, against real git.
 *
 *  2. Renaming a branch must follow through to every worktree that lands in it.
 *  3. Wrapping up a branch hands its own target down to whoever was landing in
 *     it — recursively, because the branch we hand them may already be gone.
 *  4. A target that vanishes WITHOUT a wrap-up (a manual `git branch -D`, or a
 *     forge auto-deleting a merged head) falls back to the repo default, and the
 *     change is recorded so it can be announced rather than done silently.
 *
 * These go through the manager rather than the store so the wiring is covered,
 * not just the helpers.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import { loadTargets, worktreeTargetsFile } from "./worktree-target-store.js";

interface Fixture {
  repo: string;
  manager: SessionManager;
  projectId: string;
  cleanup: () => void;
}

/** A repo with `main`, plus however many worktrees the caller asks for. */
async function fixture(): Promise<Fixture> {
  const home = mkdtempSync(join(tmpdir(), "makit-rules-home-"));
  const repo = mkdtempSync(join(tmpdir(), "makit-rules-repo-"));
  const wtDir = mkdtempSync(join(tmpdir(), "makit-rules-wt-"));
  const prevHome = process.env.MAKIT_HOME;
  const prevWt = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_HOME = home;
  process.env.MAKIT_WORKTREE_DIR = wtDir;

  const g = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd });
  g(repo, "init", "-q", "-b", "main");
  g(repo, "config", "user.email", "t@t.io");
  g(repo, "config", "user.name", "Test");
  writeFileSync(join(repo, "README.md"), "base\n");
  g(repo, "add", ".");
  g(repo, "commit", "-q", "-m", "initial");

  const manager = new SessionManager({ projects: [repo] });
  const projectId = manager.listProjects()[0]!.id;
  return {
    repo,
    manager,
    projectId,
    cleanup: () => {
      if (prevHome === undefined) delete process.env.MAKIT_HOME;
      else process.env.MAKIT_HOME = prevHome;
      if (prevWt === undefined) delete process.env.MAKIT_WORKTREE_DIR;
      else process.env.MAKIT_WORKTREE_DIR = prevWt;
      rmSync(home, { recursive: true, force: true });
      rmSync(repo, { recursive: true, force: true });
      rmSync(wtDir, { recursive: true, force: true });
    },
  };
}

/** Create a worktree via the manager and give it a commit. */
async function branchWorktree(
  f: Fixture,
  branchName: string,
  target: string,
): Promise<string> {
  const { path } = await f.manager.createWorktree(f.projectId, target, branchName);
  writeFileSync(join(path, `${branchName.replace(/\//g, "-")}.txt`), "x\n");
  execFileSync("git", ["add", "."], { cwd: path });
  execFileSync("git", ["commit", "-q", "-m", branchName], { cwd: path });
  return path;
}

// ── rule 2 ───────────────────────────────────────────────────────────────────

test("rule 2: renaming a branch repoints every worktree that lands in it", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const parentBranch = (await f.manager.listRepos({ includePrs: false }))[0]!.worktrees.find(
      (w) => w.path === parent,
    )!.branch!;
    const childA = await branchWorktree(f, "child-a", parentBranch);
    const childB = await branchWorktree(f, "child-b", parentBranch);

    await f.manager.renameWorktreeBranch(f.projectId, parent, "parent-renamed");

    const all = loadTargets(worktreeTargetsFile());
    assert.equal(all[childA]?.target, "parent-renamed");
    assert.equal(all[childB]?.target, "parent-renamed");
    // The rename is not an automatic retarget — nothing to announce.
    assert.equal(all[childA]?.retargetedFrom, undefined);
  } finally {
    f.cleanup();
  }
});

test("rule 2: an unrelated worktree's target is untouched by a rename", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const other = await branchWorktree(f, "other", "main");
    await f.manager.renameWorktreeBranch(f.projectId, parent, "parent-renamed");
    assert.equal(loadTargets(worktreeTargetsFile())[other]?.target, "main");
  } finally {
    f.cleanup();
  }
});

// ── rule 4 ───────────────────────────────────────────────────────────────────

test("rule 4: a target deleted outside makit falls back to the default and says so", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);

    // Someone tidies the parent up by hand: no wrap-up, so nothing was handed down.
    execFileSync("git", ["worktree", "remove", "--force", parent], { cwd: f.repo });
    execFileSync("git", ["branch", "-D", parentBranch], { cwd: f.repo });

    const repos = await f.manager.listRepos({ includePrs: false });
    const w = repos[0]!.worktrees.find((x) => x.path === child)!;
    assert.equal(w.targetBranch, "main", "must fall back rather than dangle");
    assert.equal(w.targetResolved, true, "and the fallback must actually resolve");
    assert.equal(
      w.retargetedFrom,
      parentBranch,
      "the automatic change must be announceable, not silent",
    );
  } finally {
    f.cleanup();
  }
});

test("rule 4: the repair is persisted, not recomputed on every snapshot", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    execFileSync("git", ["worktree", "remove", "--force", parent], { cwd: f.repo });
    execFileSync("git", ["branch", "-D", parentBranch], { cwd: f.repo });

    await f.manager.listRepos({ includePrs: false });
    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(stored?.target, "main");
    assert.equal(stored?.retargetedFrom, parentBranch);
  } finally {
    f.cleanup();
  }
});

test("rule 4: an explicit choice clears the announcement", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    execFileSync("git", ["worktree", "remove", "--force", parent], { cwd: f.repo });
    execFileSync("git", ["branch", "-D", parentBranch], { cwd: f.repo });
    await f.manager.listRepos({ includePrs: false });

    // The user takes ownership of the value; there is nothing left to tell them.
    await f.manager.setWorktreeTarget(f.projectId, child, "main");
    assert.equal(loadTargets(worktreeTargetsFile())[child]?.retargetedFrom, undefined);

    const repos = await f.manager.listRepos({ includePrs: false });
    assert.equal(repos[0]!.worktrees.find((x) => x.path === child)!.retargetedFrom, null);
  } finally {
    f.cleanup();
  }
});

test("a healthy repo is never repaired, so the store is not churned", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    await f.manager.listRepos({ includePrs: false });
    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(stored?.target, parentBranch, "an intact target must be left alone");
    assert.equal(stored?.retargetedFrom, undefined);
  } finally {
    f.cleanup();
  }
});

// ── rule 3 ───────────────────────────────────────────────────────────────────

test("rule 3: wrapping up a branch hands its target down to whoever landed in it", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);

    // The parent lands. makit does the tidying, so it knows where it went.
    await f.manager.wrapUpWorktree(f.projectId, parent, "main");

    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(stored?.target, "main", "the child follows the parent to where it landed");
    assert.equal(
      stored?.retargetedFrom,
      parentBranch,
      "and the hand-down is announced, not silent",
    );
  } finally {
    f.cleanup();
  }
});

test("rule 3: the hand-down follows a chain when the middle link is already gone", async () => {
  const f = await fixture();
  try {
    // grand -> mid -> leaf, all landing on the one below. `mid` is wrapped up
    // first, then `grand`; by the time `grand` is wrapped the branch it names is
    // already gone, so a single hop would dead-end and fall back to the default.
    const grand = await branchWorktree(f, "grand", "main");
    let repos = await f.manager.listRepos({ includePrs: false });
    const grandBranch = repos[0]!.worktrees.find((w) => w.path === grand)!.branch!;

    const mid = await branchWorktree(f, "mid", grandBranch);
    repos = await f.manager.listRepos({ includePrs: false });
    const midBranch = repos[0]!.worktrees.find((w) => w.path === mid)!.branch!;

    const leaf = await branchWorktree(f, "leaf", midBranch);

    // `mid` lands in `grand`. The leaf now aims at `grand`.
    await f.manager.wrapUpWorktree(f.projectId, mid, grandBranch);
    assert.equal(loadTargets(worktreeTargetsFile())[leaf]?.target, grandBranch);

    // Now `grand` lands in main. The leaf must follow to main.
    await f.manager.wrapUpWorktree(f.projectId, grand, "main");
    assert.equal(
      loadTargets(worktreeTargetsFile())[leaf]?.target,
      "main",
      "the chain must collapse to where the stack actually landed",
    );
  } finally {
    f.cleanup();
  }
});

test("rule 3: hands children down to a remote-only landing branch (offline fetch)", async () => {
  const f = await fixture();
  try {
    // `release` exists only as a remote-tracking ref — as if a prior fetch saw it
    // but the wrap-up's own fetch cannot land it locally (offline / transient).
    // It must still count as a live landing branch, or every child is dragged to
    // the repo default instead of the branch the PR actually targeted.
    const sha = execFileSync("git", ["rev-parse", "HEAD"], { cwd: f.repo })
      .toString()
      .trim();
    execFileSync("git", ["update-ref", "refs/remotes/origin/release", sha], { cwd: f.repo });

    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);

    // The parent lands in the remote-only `release`.
    await f.manager.wrapUpWorktree(f.projectId, parent, "release");

    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(
      stored?.target,
      "release",
      "a remote-only landing branch is live, so the child follows it — not the default",
    );
    assert.equal(stored?.retargetedFrom, parentBranch);
  } finally {
    f.cleanup();
  }
});

test("rule 3: a worktree that landed elsewhere is not dragged along", async () => {
  const f = await fixture();
  try {
    const parent = await branchWorktree(f, "parent", "main");
    const repos1 = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos1[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    const bystander = await branchWorktree(f, "bystander", "main");

    await f.manager.wrapUpWorktree(f.projectId, parent, "main");

    const all = loadTargets(worktreeTargetsFile());
    assert.equal(all[child]?.retargetedFrom, parentBranch, "the child moved");
    assert.equal(
      all[bystander]?.retargetedFrom,
      undefined,
      "the bystander already landed in main and must not be marked as moved",
    );
  } finally {
    f.cleanup();
  }
});

// ── B7: pull-request lifecycle ───────────────────────────────────────────────
//
// The design has two backing stores for one value: a live PR's base wins, the
// persisted choice applies otherwise. The TRANSITIONS between those were
// unspecified, and each one is a window where the displayed target is wrong:
//
//  * PR created with a base we did not choose (`gh pr create --base` by hand) —
//    the persisted value must catch up, or closing the PR later reverts to a
//    value that was never true.
//  * PR closed / reopened — the fallback must be where the PR actually pointed,
//    not a stale pre-PR value.
//  * GitHub auto-retargets a stacked PR and then auto-closes it — without a
//    write-back we would fall back to a target that no longer matches reality.
//
// The fix is convergence: whenever a live PR's base wins, persist it.

/**
 * A `LastKnownPr` that reports one fake pull request for the worktree at `path`.
 *
 * Stands in for the previous broadcast's enrichment, which is exactly what the
 * adoption step reads — so these tests exercise the real code path rather than a
 * shortcut.
 */
function withPr(
  f: Fixture,
  path: string,
  pr: { state: string; baseRefName: string },
) {
  return (repoPath: string, branch: string) =>
    repoPath === f.repo && branchCache[path] === branch
      ? ({
          number: 1,
          url: "u",
          state: pr.state,
          title: "t",
          isDraft: false,
          mergeable: "MERGEABLE",
          mergeStateStatus: "CLEAN",
          checks: [],
          checkRollup: "none",
          unresolvedComments: 0,
          baseRefName: pr.baseRefName,
        } as never)
      : null;
}

/** Worktree path -> its branch, filled in by each test after creation. */
let branchCache: Record<string, string> = {};

test("B7: a live PR's base is adopted into the persisted value", async () => {
  const f = await fixture();
  branchCache = {};
  try {
    const parent = await branchWorktree(f, "parent", "main");
    let repos = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    repos = await f.manager.listRepos({ includePrs: false });
    branchCache[child] = repos[0]!.worktrees.find((w) => w.path === child)!.branch!;

    // The user opened the PR against main by hand, not against the parent.
    await f.manager.listRepos(
      { includePrs: false },
      withPr(f, child, { state: "OPEN", baseRefName: "main" }),
    );

    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(stored?.target, "main", "the persisted value must catch up to the PR");
    assert.equal(
      stored?.retargetedFrom,
      parentBranch,
      "and the change is announced, since it overrode a value we had",
    );
  } finally {
    branchCache = {};
    f.cleanup();
  }
});

test("B7: closing the PR keeps the adopted target instead of reverting", async () => {
  const f = await fixture();
  branchCache = {};
  try {
    const parent = await branchWorktree(f, "parent", "main");
    let repos = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    repos = await f.manager.listRepos({ includePrs: false });
    branchCache[child] = repos[0]!.worktrees.find((w) => w.path === child)!.branch!;

    // Live PR against main -> adopted.
    await f.manager.listRepos(
      { includePrs: false },
      withPr(f, child, { state: "OPEN", baseRefName: "main" }),
    );
    // Now it closes. Before the write-back this fell back to `parentBranch` — a
    // value that had not been true since the PR was opened.
    const after = await f.manager.listRepos(
      { includePrs: false },
      withPr(f, child, { state: "CLOSED", baseRefName: "main" }),
    );
    assert.equal(
      after[0]!.worktrees.find((w) => w.path === child)!.targetBranch,
      "main",
      "the fallback must be where the PR actually pointed",
    );
  } finally {
    branchCache = {};
    f.cleanup();
  }
});

test("B7: a merged PR stops overriding the user's own choice", async () => {
  const f = await fixture();
  branchCache = {};
  try {
    const parent = await branchWorktree(f, "parent", "main");
    let repos = await f.manager.listRepos({ includePrs: false });
    const parentBranch = repos[0]!.worktrees.find((w) => w.path === parent)!.branch!;
    const child = await branchWorktree(f, "child", parentBranch);
    repos = await f.manager.listRepos({ includePrs: false });
    branchCache[child] = repos[0]!.worktrees.find((w) => w.path === child)!.branch!;

    // The user deliberately points at the parent while a MERGED PR names main.
    await f.manager.setWorktreeTarget(f.projectId, child, parentBranch);
    const after = await f.manager.listRepos(
      { includePrs: false },
      withPr(f, child, { state: "MERGED", baseRefName: "main" }),
    );
    assert.equal(
      after[0]!.worktrees.find((w) => w.path === child)!.targetBranch,
      parentBranch,
      "history must not outrank a live choice",
    );
    assert.equal(loadTargets(worktreeTargetsFile())[child]?.target, parentBranch);
  } finally {
    branchCache = {};
    f.cleanup();
  }
});

test("B7: adopting a base that already matches announces nothing", async () => {
  const f = await fixture();
  branchCache = {};
  try {
    const child = await branchWorktree(f, "child", "main");
    const repos = await f.manager.listRepos({ includePrs: false });
    branchCache[child] = repos[0]!.worktrees.find((w) => w.path === child)!.branch!;
    await f.manager.listRepos(
      { includePrs: false },
      withPr(f, child, { state: "OPEN", baseRefName: "main" }),
    );
    const stored = loadTargets(worktreeTargetsFile())[child];
    assert.equal(stored?.target, "main");
    assert.equal(stored?.retargetedFrom, undefined, "agreement is not news");
  } finally {
    branchCache = {};
    f.cleanup();
  }
});
