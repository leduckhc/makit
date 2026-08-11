import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { targetCandidates, PREVIEW_LIMIT, resolveThroughChain } from "./target_candidates.js";
import { addWorktree } from "./git.js";

/**
 * A repo with a real two-level stack plus extra branches, so ranking has
 * something to discriminate:
 *   main            (default)
 *   feat/parent     forked off main, has a commit, checked out in a worktree
 *   feat/child      forked off feat/parent, has a commit  <- the subject
 *   zz-other        a plain local branch, no worktree
 */
async function makeStack(): Promise<{
  repo: string;
  base: string;
  child: string;
  cleanup: () => void;
}> {
  const repo = mkdtempSync(join(tmpdir(), "makit-cand-repo-"));
  const base = mkdtempSync(join(tmpdir(), "makit-cand-wt-"));
  const g = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd });
  g(repo, "init", "-q", "-b", "main");
  g(repo, "config", "user.email", "t@t.io");
  g(repo, "config", "user.name", "Test");
  writeFileSync(join(repo, "README.md"), "base\n");
  g(repo, "add", ".");
  g(repo, "commit", "-q", "-m", "initial");

  const parent = await addWorktree({
    repoPath: repo,
    name: "parent",
    branch: "feat/parent",
    startPoint: "main",
    baseDir: base,
  });
  writeFileSync(join(parent, "p.txt"), "p1\np2\n");
  g(parent, "add", ".");
  g(parent, "commit", "-q", "-m", "parent");

  const child = await addWorktree({
    repoPath: repo,
    name: "child",
    branch: "feat/child",
    startPoint: "feat/parent",
    baseDir: base,
  });
  writeFileSync(join(child, "c.txt"), "c1\n");
  g(child, "add", ".");
  g(child, "commit", "-q", "-m", "child");

  g(repo, "branch", "zz-other", "main");

  return {
    repo,
    base,
    child,
    cleanup: () => {
      rmSync(repo, { recursive: true, force: true });
      rmSync(base, { recursive: true, force: true });
    },
  };
}

test("ranks forkedFrom first, then default, then other worktrees, then the rest", async () => {
  const s = await makeStack();
  try {
    const cands = await targetCandidates(s.repo, s.child);
    const order = cands.map((c) => `${c.group}:${c.branch}`);
    assert.deepEqual(order, [
      "forkedFrom:feat/parent",
      "default:main",
      "other:zz-other",
      "other:feat/child",
    ]);
  } finally {
    s.cleanup();
  }
});

test("a branch checked out in another worktree ranks in the worktree group", async () => {
  const s = await makeStack();
  try {
    // A sibling worktree on a branch that is neither the child's fork point nor
    // the repo default — the only thing that lands in the `worktree` group.
    await addWorktree({
      repoPath: s.repo,
      name: "sibling",
      branch: "feat/sibling",
      startPoint: "main",
      baseDir: s.base,
    });
    const cands = await targetCandidates(s.repo, s.child);
    const sib = cands.find((c) => c.branch === "feat/sibling")!;
    assert.equal(sib.group, "worktree", "a sibling worktree's branch is group 3");
    const iSib = cands.findIndex((c) => c.branch === "feat/sibling");
    const iOther = cands.findIndex((c) => c.branch === "zz-other");
    assert.ok(iSib < iOther, "the worktree group ranks ahead of the plain other group");
  } finally {
    s.cleanup();
  }
});

test("the worktree's own branch is offered but flagged, and sorts last in its group", async () => {
  const s = await makeStack();
  try {
    const cands = await targetCandidates(s.repo, s.child);
    const self = cands.find((c) => c.branch === "feat/child")!;
    assert.equal(self.isSelf, true, "must be flagged, not hidden — the UI explains it");
    assert.equal(cands[cands.length - 1]!.branch, "feat/child");
    assert.equal(cands.filter((c) => c.isSelf).length, 1);
  } finally {
    s.cleanup();
  }
});

test("previews carry the diff each candidate would produce", async () => {
  const s = await makeStack();
  try {
    const cands = await targetCandidates(s.repo, s.child);
    const parent = cands.find((c) => c.branch === "feat/parent")!;
    const main = cands.find((c) => c.branch === "main")!;
    // vs its parent: only the child's own line.
    assert.equal(parent.insertions, 1, `vs parent, got ${parent.insertions}`);
    // vs main: the parent's two lines come too — the inflated figure, correctly.
    assert.equal(main.insertions, 3, `vs main, got ${main.insertions}`);
  } finally {
    s.cleanup();
  }
});

test("self is never previewed (it would measure nothing meaningful)", async () => {
  const s = await makeStack();
  try {
    const cands = await targetCandidates(s.repo, s.child);
    const self = cands.find((c) => c.isSelf)!;
    assert.equal(self.insertions, undefined);
    assert.equal(self.deletions, undefined);
  } finally {
    s.cleanup();
  }
});

test("previews are capped, so opening the picker cannot storm git", async () => {
  const s = await makeStack();
  try {
    const g = (...args: string[]) => execFileSync("git", args, { cwd: s.repo });
    for (let i = 0; i < 12; i++) g("branch", `bulk/${i}`, "main");
    const cands = await targetCandidates(s.repo, s.child);
    assert.equal(cands.length, 16, `expected every local branch, got ${cands.length}`);
    const previewed = cands.filter((c) => c.insertions !== undefined);
    assert.equal(
      previewed.length <= PREVIEW_LIMIT,
      true,
      `previewed ${previewed.length}, cap is ${PREVIEW_LIMIT}`,
    );
    // The cap must fall on the RANKED head, not an arbitrary slice.
    assert.equal(previewed[0]!.branch, "feat/parent");
    assert.equal(previewed[1]!.branch, "main");
  } finally {
    s.cleanup();
  }
});

test("local-only branches are marked so the UI can refuse them as a PR base", async () => {
  const origin = mkdtempSync(join(tmpdir(), "makit-cand-origin-"));
  const clone = mkdtempSync(join(tmpdir(), "makit-cand-clone-"));
  const base = mkdtempSync(join(tmpdir(), "makit-cand-cwt-"));
  try {
    const g = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd });
    g(origin, "init", "-q", "-b", "main");
    g(origin, "config", "user.email", "t@t.io");
    g(origin, "config", "user.name", "Test");
    writeFileSync(join(origin, "R.md"), "x\n");
    g(origin, "add", ".");
    g(origin, "commit", "-q", "-m", "init");
    execFileSync("git", ["clone", "-q", origin, clone]);
    g(clone, "config", "user.email", "t@t.io");
    g(clone, "config", "user.name", "Test");
    g(clone, "branch", "never-pushed", "main");

    const wt = await addWorktree({
      repoPath: clone,
      name: "w",
      branch: "feat/w",
      startPoint: "main",
      baseDir: base,
    });
    const cands = await targetCandidates(clone, wt);
    assert.equal(cands.find((c) => c.branch === "main")!.onRemote, true);
    assert.equal(cands.find((c) => c.branch === "never-pushed")!.onRemote, false);
  } finally {
    rmSync(origin, { recursive: true, force: true });
    rmSync(clone, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("a non-repo yields no candidates rather than throwing", async () => {
  const plain = mkdtempSync(join(tmpdir(), "makit-cand-plain-"));
  try {
    assert.deepEqual(await targetCandidates(plain, plain), []);
  } finally {
    rmSync(plain, { recursive: true, force: true });
  }
});

/**
 * Found by driving the real app: in a repo created with `git init` and no
 * `origin`, every candidate came back `onRemote: false`, so the picker rendered
 * every row disabled with "not pushed yet" and could not be used at all.
 *
 * The "must exist on the remote" rule exists because a PULL REQUEST base must.
 * With no remote there is no pull request to constrain, and the target still
 * drives the diff and the merge destination — so the constraint is vacuous and
 * must not be enforced.
 */
test("with no remote configured, every branch is selectable", async () => {
  const s = await makeStack();
  try {
    const cands = await targetCandidates(s.repo, s.child);
    assert.equal(cands.length > 0, true);
    const blocked = cands.filter((c) => !c.isSelf && !c.onRemote);
    assert.deepEqual(
      blocked.map((c) => c.branch),
      [],
      "a repo with no remote must not gate on push state",
    );
  } finally {
    s.cleanup();
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// resolveThroughChain — rule 3's recursion, plus rule 4's fallback.
// ─────────────────────────────────────────────────────────────────────────────

test("resolveThroughChain returns a live branch unchanged", () => {
  assert.equal(
    resolveThroughChain("feat/parent", {
      live: new Set(["feat/parent", "main"]),
      branchTarget: {},
      defaultBranch: "main",
    }),
    "feat/parent",
  );
});

test("resolveThroughChain follows one dead link to where it landed", () => {
  // feat/child -> feat/parent (gone, landed in main)
  assert.equal(
    resolveThroughChain("feat/parent", {
      live: new Set(["main"]),
      branchTarget: { "feat/parent": "main" },
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveThroughChain walks a multi-link chain", () => {
  // A -> B -> C -> release/1.4, where B and C are both gone. The point of the
  // recursion: the answer is where the chain ENDS, not the repo default.
  assert.equal(
    resolveThroughChain("B", {
      live: new Set(["release/1.4", "main"]),
      branchTarget: { B: "C", C: "release/1.4" },
      defaultBranch: "main",
    }),
    "release/1.4",
  );
});

test("resolveThroughChain falls back to the default when the chain dead-ends", () => {
  assert.equal(
    resolveThroughChain("B", {
      live: new Set(["main"]),
      branchTarget: { B: "C" },
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveThroughChain survives a cycle instead of looping forever", () => {
  // Reachable: A lands in B while B lands in A, then both branches vanish.
  assert.equal(
    resolveThroughChain("A", {
      live: new Set(["main"]),
      branchTarget: { A: "B", B: "A" },
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveThroughChain returns null when even the default is gone", () => {
  assert.equal(
    resolveThroughChain("B", {
      live: new Set<string>(),
      branchTarget: {},
      defaultBranch: null,
    }),
    null,
  );
});

test("resolveThroughChain never returns the branch it started from", () => {
  // A self-referencing entry must not resolve to itself: that would leave a
  // worktree targeting a branch that does not exist.
  assert.equal(
    resolveThroughChain("A", {
      live: new Set(["main"]),
      branchTarget: { A: "A" },
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveThroughChain refuses a default branch that does not exist either", () => {
  // A repo whose origin/HEAD still names a deleted branch: handing that back
  // would move the "target is gone" problem one branch over rather than fix it.
  assert.equal(
    resolveThroughChain("B", {
      live: new Set(["some-other"]),
      branchTarget: {},
      defaultBranch: "main",
    }),
    null,
  );
});
