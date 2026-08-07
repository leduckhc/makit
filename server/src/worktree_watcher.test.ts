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

test("watchWorktrees fires when the watched repo is a SUBMODULE checkout", async () => {
  const repo = makeRepo();
  const submoduleSource = makeRepo();
  const submodule = join(repo, "modules", "child");
  execFileSync(
    "git",
    ["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleSource, "modules/child"],
    { cwd: repo },
  );
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));

  let resolveFired: (() => void) | undefined;
  const fired = new Promise<void>((res) => (resolveFired = res));
  const watcher = watchWorktrees(() => resolveFired?.(), { debounceMs: 20 });
  watcher.sync([submodule]);
  try {
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "submodule-feat", join(wtBase, "submodule-feat")], {
      cwd: submodule,
    });
    const won = await Promise.race([fired.then(() => true), delay(3000).then(() => false)]);
    assert.equal(won, true, "expected onChange to fire for a worktree added from a submodule checkout");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(submoduleSource, { recursive: true, force: true });
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

test("watchWorktrees does not attach a missing project path to an ancestor repo", async () => {
  const repo = makeRepo();
  const missingProject = join(repo, "removed-project");
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 10 });
  watcher.sync([missingProject]);
  try {
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "unrelated", join(wtBase, "unrelated")], {
      cwd: repo,
    });
    await delay(150);
    assert.equal(fired, 0, "a missing project path must not watch an ancestor repository");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
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

test("watchWorktrees tracks multiple repos independently, including a LINKED worktree", async () => {
  // Regression: resolveGitPaths is computed per-repo. Watching a primary repo
  // and a linked worktree of a *different* repo at the same time must not let
  // either resolution bleed into the other, and dropping one must not disturb
  // the other's still-active watcher.
  const repoA = makeRepo();
  const repoB = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  const linkedB = join(wtBase, "linkedB");
  execFileSync("git", ["worktree", "add", "-b", "linkedB-branch", linkedB], { cwd: repoB });

  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 20 });
  watcher.sync([repoA, linkedB]);
  try {
    await delay(80);

    execFileSync("git", ["worktree", "add", "-b", "a-feat", join(wtBase, "a-feat")], {
      cwd: repoA,
    });
    await waitFor(() => fired > 0);
    const afterA = fired;

    // A worktree add from the linked checkout of repoB must also fire, via
    // its own resolved common gitdir (distinct from repoA's).
    execFileSync("git", ["worktree", "add", "-b", "b-feat", join(wtBase, "b-feat")], {
      cwd: linkedB,
    });
    await waitFor(() => fired > afterA);

    // Dropping repoA must not disturb the still-registered linkedB watcher.
    watcher.sync([linkedB]);
    await delay(80);
    const beforeDrop = fired;
    execFileSync("git", ["worktree", "add", "-b", "a-feat-2", join(wtBase, "a-feat-2")], {
      cwd: repoA,
    });
    await delay(150);
    assert.equal(fired, beforeDrop, "dropped repoA must not fire anymore");

    execFileSync("git", ["worktree", "add", "-b", "b-feat-2", join(wtBase, "b-feat-2")], {
      cwd: linkedB,
    });
    await waitFor(() => fired > beforeDrop);
  } finally {
    watcher.close();
    rmSync(repoA, { recursive: true, force: true });
    rmSync(repoB, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees.sync idempotently drops a watcher on a LINKED worktree path", async () => {
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  const linked = join(wtBase, "linked");
  execFileSync("git", ["worktree", "add", "-b", "linked-branch", linked], { cwd: repo });

  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 10 });
  try {
    watcher.sync([linked]);
    watcher.sync([linked]); // idempotent — must not leave a duplicate watcher
    watcher.sync([]); // dropped — watchers on the resolved common gitdir are closed
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "after-drop", join(wtBase, "after-drop")], {
      cwd: linked,
    });
    await delay(150);
    assert.equal(fired, 0, "dropped linked-worktree watcher must not fire after a worktree add");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees does not fire for an existing directory that is not part of any git repo", async () => {
  // Boundary case distinct from the non-existent-path test: the directory
  // exists (so `realpathSync` succeeds), but `git rev-parse` fails because it
  // isn't inside any repo at all, so resolution must fall back to a no-op
  // rather than throwing or wandering into an unrelated repo.
  const plainDir = mkdtempSync(join(tmpdir(), "makit-plain-"));
  const repo = makeRepo(); // unrelated repo, to prove nothing bleeds across
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  let fired = 0;
  const watcher = watchWorktrees(() => fired++, { debounceMs: 10 });
  assert.doesNotThrow(() => watcher.sync([plainDir]));
  try {
    await delay(80);
    execFileSync("git", ["worktree", "add", "-b", "unrelated", join(wtBase, "unrelated")], {
      cwd: repo,
    });
    await delay(150);
    assert.equal(fired, 0, "a plain non-repo directory must not fire on unrelated git activity");
  } finally {
    watcher.close();
    rmSync(plainDir, { recursive: true, force: true });
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});

test("watchWorktrees fires when a commit lands in the primary checkout", async () => {
  // The snapshot carries `uncommittedFiles`/`aheadCount` per worktree, and the
  // only other triggers are connect/spawn/kill/pull-to-refresh — so without this
  // the composer's next-step bar kept asserting a file count that was true when
  // the client connected, and offered `Commit & push` for files already
  // committed and pushed.
  const repo = makeRepo();
  let fires = 0;
  const watcher = watchWorktrees(() => fires++, { debounceMs: 20 });
  watcher.sync([repo]);
  try {
    await delay(80);
    writeFileSync(join(repo, "new.txt"), "x\n");
    execFileSync("git", ["add", "."], { cwd: repo });
    execFileSync("git", ["commit", "-q", "-m", "second"], { cwd: repo });
    await waitFor(() => fires > 0);
    assert.ok(fires > 0, "expected onChange after a commit");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
  }
});

test("watchWorktrees fires when a commit lands in a LINKED worktree", async () => {
  // The branch ref lives in the *common* git dir whatever worktree moved it, so
  // one watch on `refs/heads` covers every worktree of the repo — which is the
  // case that matters, because agents work in linked worktrees.
  const repo = makeRepo();
  const wtBase = mkdtempSync(join(tmpdir(), "makit-wt-"));
  const wt = join(wtBase, "feat");
  execFileSync("git", ["worktree", "add", "-q", "-b", "feat", wt], { cwd: repo });

  let fires = 0;
  const watcher = watchWorktrees(() => fires++, { debounceMs: 20 });
  watcher.sync([repo]);
  try {
    await delay(120);
    fires = 0; // ignore any settling from arming
    writeFileSync(join(wt, "in-worktree.txt"), "x\n");
    execFileSync("git", ["add", "."], { cwd: wt });
    execFileSync("git", ["commit", "-q", "-m", "from the linked worktree"], { cwd: wt });
    await waitFor(() => fires > 0);
    assert.ok(fires > 0, "expected onChange after a commit in a linked worktree");
  } finally {
    watcher.close();
    rmSync(repo, { recursive: true, force: true });
    rmSync(wtBase, { recursive: true, force: true });
  }
});
