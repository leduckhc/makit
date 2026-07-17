import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
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
