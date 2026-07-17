import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { watchWorktrees } from "./worktree_watcher.js";

/** Init a throwaway repo with one commit on `main`. Returns its path. */
function makeRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-wtw-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir });
  g("init", "-q", "-b", "main");
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(dir, "README.md"), "hello\n");
  g("add", ".");
  g("commit", "-q", "-m", "initial");
  return dir;
}

const delay = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** Poll [pred] until true or the timeout elapses (state-driven, not a fixed sleep). */
async function waitFor(
  pred: () => boolean,
  { timeoutMs = 3000, stepMs = 20 } = {},
): Promise<void> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > timeoutMs) throw new Error("waitFor: condition not met in time");
    await delay(stepMs);
  }
}

test("watchWorktrees fires when a worktree is added via git (external CLI)", async () => {
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  let resolveFired: (() => void) | undefined;
  const fired = new Promise<void>((res) => (resolveFired = res));

  const watcher = watchWorktrees(() => resolveFired?.(), { debounceMs: 20 });
  watcher.sync([repo]);
  try {
    // Give the fs watchers a moment to arm before mutating the tree.
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "feat", join(wtBase, "feat")], {
      cwd: repo,
    });
    const won = await Promise.race([fired.then(() => true), delay(3000).then(() => false)]);
    assert.equal(won, true, "expected onChange to fire after `git worktree add`");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees fires when the watched repo path is itself a LINKED worktree", async () => {
  // Regression: a project registered at a linked-worktree path has `.git` as a
  // FILE pointing at `<common>/.git/worktrees/<name>`. The shared worktrees dir
  // lives under the common gitdir, not `<linked>/.git/worktrees` (absent), so a
  // new `git worktree add` must still fire via the resolved common path.
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  const linked = join(wtBase, "linked");
  execFileSync("git", ["worktree", "add", "-b", "linked-branch", linked], { cwd: repo });

  let resolveFired: (() => void) | undefined;
  const fired = new Promise<void>((res) => (resolveFired = res));
  const watcher = watchWorktrees(() => resolveFired?.(), { debounceMs: 20 });
  watcher.sync([linked]); // watch the LINKED worktree path, not the primary
  try {
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "another", join(wtBase, "another")], {
      cwd: linked,
    });
    const won = await Promise.race([fired.then(() => true), delay(3000).then(() => false)]);
    assert.equal(won, true, "expected onChange to fire for a worktree added from a linked checkout");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees fires when the watched path is a SUBDIRECTORY of the repo", async () => {
  // Regression: the dev daemon registers e.g. `--project <repo>/server`, a
  // subdir with no `.git` of its own. The watcher must walk up to the repo's
  // `.git/worktrees` so worktree adds still surface.
  const repo = makeRepo();
  const sub = join(repo, "server");
  mkdirSync(sub, { recursive: true });
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));

  let resolveFired: (() => void) | undefined;
  const fired = new Promise<void>((res) => (resolveFired = res));
  const watcher = watchWorktrees(() => resolveFired?.(), { debounceMs: 20 });
  watcher.sync([sub]); // watch the SUBDIR, not the repo root
  try {
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "sub-feat", join(wtBase, "sub-feat")], {
      cwd: repo,
    });
    const won = await Promise.race([fired.then(() => true), delay(3000).then(() => false)]);
    assert.equal(won, true, "expected onChange to fire for a worktree added when watching a subdir");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees.sync drops watchers for removed repos and is idempotent", async () => {
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 10 });
  try {
    watcher.sync([repo]);
    watcher.sync([repo]); // idempotent — must not leave a duplicate watcher
    watcher.sync([]); // repo dropped — its watchers are closed
    await delay(80);
    // A worktree added AFTER the repo was dropped must not fire the callback
    // (proves both removal and that the duplicate sync left no orphan watcher).
    execFileSync("git", ["worktree", "add", "-b", "dropped", join(wtBase, "dropped")], {
      cwd: repo,
    });
    await delay(150);
    assert.equal(fired, 0, "dropped repo must not fire after a worktree add");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees tolerates a non-existent / non-repo path", async () => {
  const watcher = watchWorktrees(() => {}, { debounceMs: 10 });
  assert.doesNotThrow(() => watcher.sync(["/no/such/path/makit-nope"]));
  watcher.close();
});

test("watchWorktrees keeps firing (and does not crash) when a worktree is removed", async () => {
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 20 });
  watcher.sync([repo]);
  try {
    await delay(80); // let the fs watchers arm (no callback to await on setup)
    execFileSync("git", ["worktree", "add", "-b", "gone", join(wtBase, "gone")], {
      cwd: repo,
    });
    await waitFor(() => fired > 0);
    const afterAdd = fired;
    assert.ok(afterAdd > 0, "expected a fire on add");

    // Removing the last worktree deletes `.git/worktrees`, which makes the
    // inner FSWatcher emit an async `'error'`. With the error handler this is
    // absorbed (process stays up) and still triggers a re-scan.
    execFileSync("git", ["worktree", "remove", "--force", join(wtBase, "gone")], {
      cwd: repo,
    });
    await waitFor(() => fired > afterAdd);
    assert.ok(fired > afterAdd, "expected a fire on removal");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});
