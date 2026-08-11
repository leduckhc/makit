import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import { resolveWorktreeRoot, validateWorktreeRoot } from "./repo_settings.js";

/**
 * The behaviour the feature exists for: two repos, different roots, resolved from
 * persisted settings — and the invalid-value path, which must degrade rather than
 * break worktree creation.
 *
 * Exercised through `SessionManager.worktreeRootFor`, the ONE place all three
 * consumers (`addWorktree`, `addWorktreeForPr`, `uniqueWorktreeDir`) now read
 * from. Before this, only the env var was consulted and every repo shared a root.
 */
function manager(projects: Array<{ id: string; path: string; settings?: Record<string, unknown> }>) {
  return new SessionManager({
    adapterFactory: (() => {
      throw new Error("not used");
    }) as never,
    onProjectsChanged: () => {},
    defaultModel: "m",
    store: undefined as never,
    capabilityCache: undefined as never,
    projects,
    gateway: {
      prForBranch: async () => ({ kind: "none" }) as never,
      openPrs: async () => [],
      mutatePr: async () => ({ ok: true }),
      budget: () => ({}) as never,
      history: () => [],
      refresh: async () => ({}) as never,
      setPaused: () => {},
      onBudgetChange: () => () => {},
      close: () => {},
      stats: () => ({ execs: 0, exemptExecs: 0, cacheHits: 0 }),
    } as never,
  });
}

test("two repos with different overrides get different worktree roots", () => {
  const home = homedir();
  const a = mkdtempSync(join(tmpdir(), "makit-a-"));
  const b = mkdtempSync(join(tmpdir(), "makit-b-"));
  const rootA = join(home, ".makit-test-trees-a");
  const m = manager([
    { id: "a", path: a, settings: { worktreeRoot: rootA } },
    { id: "b", path: b },
  ]);
  assert.equal(m.worktreeRootFor(a), rootA, "A follows its override");
  assert.equal(
    m.worktreeRootFor(b),
    resolveWorktreeRoot(undefined, process.env).value,
    "B inherits",
  );
});

test("an override that is no longer valid degrades to the inherited root", () => {
  // `projects.json` is hand-editable, so a stored value can go bad after the write
  // check passed. Worktree creation must still work.
  const a = mkdtempSync(join(tmpdir(), "makit-c-"));
  const m = manager([{ id: "a", path: a, settings: { worktreeRoot: "/etc/nope" } }]);
  assert.equal(m.worktreeRootFor(a), resolveWorktreeRoot(undefined, process.env).value);
});

test("a repo makit does not know inherits rather than throwing", () => {
  const m = manager([]);
  assert.equal(
    m.worktreeRootFor("/tmp/not-a-project"),
    resolveWorktreeRoot(undefined, process.env).value,
  );
});

test("the stored root is used verbatim once validated, symlinks resolved", () => {
  const home = homedir();
  const real = join(home, ".makit-test-trees-real");
  mkdirSync(real, { recursive: true });
  const checked = validateWorktreeRoot(real);
  assert.equal(checked.ok, true);
  const a = mkdtempSync(join(tmpdir(), "makit-d-"));
  const m = manager([{ id: "a", path: a, settings: { worktreeRoot: real } }]);
  assert.equal(m.worktreeRootFor(a), (checked as { value: string }).value);
});

test("collision detection looks in the repo's OWN root, not the global one", () => {
  // Reviewer finding R5: if `uniqueWorktreeDir` consulted the inherited root while
  // `addWorktree` wrote to the override, the two would disagree and a real
  // collision would slip through. Proven by making a name collide in the
  // OVERRIDDEN root only.
  const home = homedir();
  const repo = mkdtempSync(join(tmpdir(), "makit-coll-"));
  const repoName = repo.split("/").pop()!;
  const overrideRoot = join(home, ".makit-test-trees-collide");
  mkdirSync(join(overrideRoot, repoName, "feat-x"), { recursive: true });

  const overridden = manager([
    { id: "a", path: repo, settings: { worktreeRoot: overrideRoot } },
  ]);
  assert.notEqual(
    overridden.uniqueWorktreeDir(repo, "feat-x"),
    "feat-x",
    "the existing dir under the OVERRIDE must be seen",
  );

  const inherited = manager([{ id: "a", path: repo }]);
  assert.equal(
    inherited.uniqueWorktreeDir(repo, "feat-x"),
    "feat-x",
    "the same name is free under the inherited root",
  );
});
