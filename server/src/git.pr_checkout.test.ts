/**
 * Checking out a pull request when the forge is NOT GitHub (SPEC-per-repo-settings P2).
 *
 * The gap this closes: "New worktree from PR" listed Forgejo PRs correctly — the
 * picker routes through the forge gateway — and then ran `gh pr checkout` to create
 * the worktree. On a Forgejo remote that fails, so the flow was broken exactly
 * halfway: the user sees their PRs, picks one, and the worktree never appears.
 *
 * Tested against a real local bare repo carrying `refs/pull/<n>/head`, which is how
 * Gitea and Forgejo actually expose PR heads — so this exercises the real git
 * plumbing with no network and no forge.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

import { addWorktreeForPr } from "./git.js";

interface Fixture {
  origin: string;
  clone: string;
  base: string;
  /** The commit at the tip of the PR head. */
  prHead: string;
  cleanup: () => void;
}

/**
 * A bare "origin" with one PR published at `refs/pull/7/head`, plus a clone.
 *
 * The PR commit is deliberately NOT reachable from any branch in the clone: that is
 * the whole point of fetching the pull ref, and a fixture where the commit is
 * already present would pass even if nothing were fetched.
 */
function fixture(opts: { sameRepoBranch?: boolean } = {}): Fixture {
  const dir = mkdtempSync(join(tmpdir(), "makit-prco-"));
  const origin = join(dir, "origin.git");
  const work = join(dir, "work");
  const clone = join(dir, "clone");
  const g = (cwd: string, ...a: string[]) => execFileSync("git", a, { cwd }).toString();

  execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin]);
  execFileSync("git", ["clone", "-q", origin, work]);
  g(work, "config", "user.email", "t@t.io");
  g(work, "config", "user.name", "T");
  writeFileSync(join(work, "README.md"), "base\n");
  g(work, "add", ".");
  g(work, "commit", "-q", "-m", "base");
  g(work, "push", "-q", "origin", "main");

  // The PR's head commit.
  g(work, "checkout", "-q", "-b", "feature/login");
  writeFileSync(join(work, "feature.txt"), "pr work\n");
  g(work, "add", ".");
  g(work, "commit", "-q", "-m", "the PR commit");
  const prHead = g(work, "rev-parse", "HEAD").trim();
  // Published the way a forge publishes it. `sameRepoBranch` also pushes the branch,
  // which is what distinguishes a same-repo PR from a fork's.
  g(work, "push", "-q", "origin", "HEAD:refs/pull/7/head");
  if (opts.sameRepoBranch === true) g(work, "push", "-q", "origin", "feature/login");

  execFileSync("git", ["clone", "-q", origin, clone]);
  const base = mkdtempSync(join(tmpdir(), "makit-prco-wt-"));
  return {
    origin,
    clone,
    base,
    prHead,
    cleanup: () => {
      rmSync(dir, { recursive: true, force: true });
      rmSync(base, { recursive: true, force: true });
    },
  };
}

test("a non-GitHub PR is checked out from refs/pull/<n>/head, without gh", async () => {
  const f = fixture();
  try {
    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "feature/login",
      baseDir: f.base,
      checkout: "pull-ref",
    });
    // The PR's actual commit is checked out — not the base, which is what a silently
    // skipped fetch would leave behind.
    const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: r.path }).toString().trim();
    assert.equal(head, f.prHead);
    assert.equal(readFileSync(join(r.path, "feature.txt"), "utf8"), "pr work\n");
  } finally {
    f.cleanup();
  }
});

test("it lands on a PR-unique branch, not the PR's head ref name", async () => {
  // Same reason the gh path passes `--branch`: the primary checkout commonly sits on
  // the head ref already, and git refuses to check out a branch twice in one repo.
  const f = fixture({ sameRepoBranch: true });
  try {
    execFileSync("git", ["checkout", "-q", "-b", "feature/login", "origin/feature/login"], {
      cwd: f.clone,
    });
    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "feature/login",
      baseDir: f.base,
      checkout: "pull-ref",
    });
    assert.equal(r.branch, "pr-7-feature-login");
  } finally {
    f.cleanup();
  }
});

test("a same-repo PR tracks its head branch, so a push updates the PR", async () => {
  const f = fixture({ sameRepoBranch: true });
  try {
    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "feature/login",
      baseDir: f.base,
      checkout: "pull-ref",
    });
    const upstream = execFileSync(
      "git",
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
      { cwd: r.path },
    )
      .toString()
      .trim();
    assert.equal(upstream, "origin/feature/login");
  } finally {
    f.cleanup();
  }
});

test("a fork PR still checks out, just without an upstream", async () => {
  // The head branch does not exist on `origin` for a fork. Refusing the checkout
  // would make reviewing a contributor's PR impossible; the worktree is the point,
  // and pushing to someone else's fork was never possible anyway.
  const f = fixture();
  try {
    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "contributor-branch",
      baseDir: f.base,
      checkout: "pull-ref",
    });
    const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: r.path }).toString().trim();
    assert.equal(head, f.prHead);
    // And genuinely has no upstream: `@{u}` fails rather than resolving to something
    // wrong, which would send a push to the wrong branch.
    assert.throws(() =>
      execFileSync("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], {
        cwd: r.path,
        stdio: ["ignore", "pipe", "ignore"],
      }),
    );
  } finally {
    f.cleanup();
  }
});

test("a PR number the forge does not publish fails and leaves no litter", async () => {
  // The empty detached worktree must be rolled back, exactly as the gh path does —
  // otherwise a mistyped or closed PR leaves a directory that looks like a worktree.
  const f = fixture();
  try {
    await assert.rejects(
      addWorktreeForPr({
        repoPath: f.clone,
        prNumber: 999,
        headRefName: "nope",
        baseDir: f.base,
        checkout: "pull-ref",
      }),
    );
    const worktrees = execFileSync("git", ["worktree", "list"], { cwd: f.clone }).toString();
    assert.equal(worktrees.includes("pr-999"), false, "the failed worktree was removed");
  } finally {
    f.cleanup();
  }
});

test("the honoured worktree root is the caller's, so per-repo roots still apply", async () => {
  const f = fixture();
  try {
    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "feature/login",
      baseDir: f.base,
      checkout: "pull-ref",
    });
    // The EXACT path, not a prefix: `startsWith` also accepts a sibling such as
    // `${base}-other/...`, so the assertion held for a worktree outside the root the
    // caller chose -- which is the only thing this test exists to check.
    const base = execFileSync("realpath", [f.base]).toString().trim();
    const repoName = basename(f.clone);
    assert.equal(r.path, join(base, repoName, "pr-7-feature-login"));
  } finally {
    f.cleanup();
  }
});

// ---------------------------------------------------------------------------
// The GitHub path, which had NO test before this refactor.
//
// `addWorktreeForPr` was one function that always ran `gh pr checkout`; it is now two
// strategies behind a discriminator. That is exactly the shape of change where a
// working path regresses silently, so the gh invocation is pinned here — argv and
// all — via a PATH shim, the same technique manager.test.ts uses.
// ---------------------------------------------------------------------------

test("the GitHub strategy still runs `gh pr checkout <n> --branch <unique>`", async () => {
  const f = fixture({ sameRepoBranch: true });
  const bin = mkdtempSync(join(tmpdir(), "makit-fake-gh-"));
  const argvLog = join(bin, "argv.txt");
  const prevPath = process.env.PATH;
  try {
    const gh = join(bin, "gh");
    // Records its argv, then does what the real `gh pr checkout --branch` does, so the
    // rest of the function (HEAD read, branch reporting) runs against a real result.
    writeFileSync(
      gh,
      [
        "#!/bin/sh",
        `printf '%s\\n' "$*" >> "${argvLog}"`,
        'git fetch --quiet origin refs/pull/7/head || exit 1',
        'git checkout -q -b "$5" FETCH_HEAD || exit 1',
        "",
      ].join("\n"),
    );
    chmodSync(gh, 0o755);
    process.env.PATH = `${bin}:${prevPath ?? ""}`;

    const r = await addWorktreeForPr({
      repoPath: f.clone,
      prNumber: 7,
      headRefName: "feature/login",
      baseDir: f.base,
      // No `checkout` passed: the default must remain gh, so every existing caller
      // keeps its behaviour.
    });

    assert.equal(
      readFileSync(argvLog, "utf8").trim(),
      "pr checkout 7 --branch pr-7-feature-login",
      "argv unchanged, including the PR-unique --branch that avoids a checkout collision",
    );
    assert.equal(r.branch, "pr-7-feature-login");
    const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: r.path }).toString().trim();
    assert.equal(head, f.prHead);
  } finally {
    if (prevPath === undefined) delete process.env.PATH;
    else process.env.PATH = prevPath;
    rmSync(bin, { recursive: true, force: true });
    f.cleanup();
  }
});

test("a failing gh still rolls back the empty worktree", async () => {
  // The rollback moved into a shared branch during the refactor; pinned for gh too so
  // one strategy cannot keep it while the other loses it.
  const f = fixture();
  const bin = mkdtempSync(join(tmpdir(), "makit-fake-gh-"));
  const prevPath = process.env.PATH;
  try {
    const gh = join(bin, "gh");
    writeFileSync(gh, "#!/bin/sh\necho 'no PR for you' >&2\nexit 1\n");
    chmodSync(gh, 0o755);
    process.env.PATH = `${bin}:${prevPath ?? ""}`;

    await assert.rejects(
      addWorktreeForPr({
        repoPath: f.clone,
        prNumber: 7,
        headRefName: "feature/login",
        baseDir: f.base,
      }),
      /no PR for you|gh pr checkout/,
    );
    const worktrees = execFileSync("git", ["worktree", "list"], { cwd: f.clone }).toString();
    assert.equal(worktrees.includes("pr-7"), false, "no litter left behind");
  } finally {
    if (prevPath === undefined) delete process.env.PATH;
    else process.env.PATH = prevPath;
    rmSync(bin, { recursive: true, force: true });
    f.cleanup();
  }
});
