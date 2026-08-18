import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import { createForgeRouter } from "./forge/router.js";
import { createNoForgeGateway } from "./forge/none.js";
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

/** As {@link manager}, but with a gateway that also answers forge inspection. */
function managerWithInspector(
  projects: Array<{ id: string; path: string; settings?: Record<string, unknown> }>,
  inspector: {
    forgeFor: (p: string) => unknown;
    hasRemoteFor: (p: string) => boolean | undefined;
  },
) {
  const m = manager(projects);
  Object.assign((m as unknown as { _gateway: object })._gateway, inspector);
  return m;
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
  // The home directory is required, not incidental: `validateWorktreeRoot` refuses a
  // root outside $HOME. `mkdtempSync` gives it a unique name so parallel runs cannot
  // collide, and the `finally` removes it -- this used to leave a directory behind in
  // the developer's home on every run.
  const real = mkdtempSync(join(homedir(), ".makit-test-trees-real-"));
  // Created before the `try` so the `finally` always owns it: removing it on the last
  // line of the body leaked the directory whenever an assertion above it failed.
  const a = mkdtempSync(join(tmpdir(), "makit-d-"));
  try {
    const checked = validateWorktreeRoot(real);
    assert.equal(checked.ok, true);
    const m = manager([{ id: "a", path: a, settings: { worktreeRoot: real } }]);
    assert.equal(m.worktreeRootFor(a), (checked as { value: string }).value);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(real, { recursive: true, force: true });
  }
});

test("collision detection looks in the repo's OWN root, not the global one", () => {
  // Reviewer finding R5: if `uniqueWorktreeDir` consulted the inherited root while
  // `addWorktree` wrote to the override, the two would disagree and a real
  // collision would slip through. Proven by making a name collide in the
  // OVERRIDDEN root only.
  const repo = mkdtempSync(join(tmpdir(), "makit-coll-"));
  const repoName = repo.split("/").pop()!;
  // Unique per run and removed afterwards: a fixed name accumulated one
  // `<repoName>` subdirectory in the developer's home on every single run.
  const overrideRoot = mkdtempSync(join(homedir(), ".makit-test-trees-collide-"));
  try {
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
  } finally {
    rmSync(repo, { recursive: true, force: true });
    rmSync(overrideRoot, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// P2 — the provider choice reaches the router, and the DTO stops conflating
// "no remote" with "not measured yet".
// ---------------------------------------------------------------------------

test("the manager reports a repo's stored provider choice, so routing can honour it", () => {
  // The router asks this at routing time (not at construction), which is what lets
  // a changed setting take effect without restarting the daemon.
  const a = mkdtempSync(join(tmpdir(), "makit-p1-"));
  const b = mkdtempSync(join(tmpdir(), "makit-p2-"));
  const m = manager([
    { id: "a", path: a, settings: { provider: "forgejo" } },
    { id: "b", path: b },
  ]);
  assert.equal(m.providerFor(a), "forgejo");
  assert.equal(m.providerFor(b), "auto", "no override means believe detection");
});

test("a repo makit does not know reports auto rather than throwing", () => {
  const m = manager([]);
  assert.equal(m.providerFor("/nowhere"), "auto");
});

test("an un-routed repo reports hasRemote true — not measured is not 'no remote'", async () => {
  // The bug this pins: hasRemote was `forge !== undefined`, so a repo the router had
  // not reached yet claimed to have no origin. That made the app's "not identified
  // yet" wording unreachable and sent the reader looking for a missing remote that
  // was never missing.
  const a = mkdtempSync(join(tmpdir(), "makit-hr1-"));
  const m = manager([{ id: "a", path: a }]);
  const [repo] = await m.listRepos({ includePrs: false });
  assert.equal(repo.settings?.hasRemote, true);
  assert.equal(repo.settings?.forge, undefined, "and the forge is still absent");
});

test("a routed repo with no readable origin reports hasRemote false", async () => {
  const a = mkdtempSync(join(tmpdir(), "makit-hr2-"));
  const m = managerWithInspector([{ id: "a", path: a }], {
    forgeFor: () => undefined,
    hasRemoteFor: () => false,
  });
  const [repo] = await m.listRepos({ includePrs: false });
  assert.equal(repo.settings?.hasRemote, false);
});

test("a routed repo with a forge reports hasRemote true and the forge", async () => {
  const a = mkdtempSync(join(tmpdir(), "makit-hr3-"));
  const forge = { software: "forgejo" as const, host: "git.example", authed: true, source: "override" as const };
  const m = managerWithInspector([{ id: "a", path: a }], {
    forgeFor: () => forge,
    hasRemoteFor: () => true,
  });
  const [repo] = await m.listRepos({ includePrs: false });
  assert.equal(repo.settings?.hasRemote, true);
  assert.deepEqual(repo.settings?.forge, forge);
});

// ---------------------------------------------------------------------------
// SPEC-per-repo-settings — the default-branch override reaches all THREE consumers.
//
// The same shape as the worktree-root fix (T2/R5): a resolver is not a feature
// until every consumer reads from it. `detectDefaultBranch` was called directly in
// three places, so the stored override affected none of them — the diff numbers,
// the base a new worktree branches from, and the branch wrap-up syncs.
// ---------------------------------------------------------------------------

/**
 * A real repo with one commit on `main`, plus each of [extra] as a branch carrying
 * its OWN extra commit.
 *
 * The divergent commit is load-bearing, not decoration: a branch created from
 * `main` without one has the same tip, so `merge-base` cannot tell which of the two
 * a worktree forked from and the assertion would pass no matter what the production
 * code chose.
 */
function repoWithBranches(extra: string[]): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-db-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir });
  g("init", "-q", "-b", "main");
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(dir, "README.md"), "hi\n");
  g("add", ".");
  g("commit", "-q", "-m", "initial");
  for (const b of extra) {
    g("checkout", "-q", "-b", b);
    writeFileSync(join(dir, `${b}.txt`), `${b}\n`);
    g("add", ".");
    g("commit", "-q", "-m", `on ${b}`);
    g("checkout", "-q", "main");
  }
  return dir;
}

test("the manager resolves a repo's default branch through the override", async () => {
  const a = repoWithBranches(["trunk"]);
  try {
    const m = manager([{ id: "a", path: a, settings: { defaultBranch: "trunk" } }]);
    assert.equal(await m.defaultBranchFor(a), "trunk");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("without an override the manager falls back to git's answer", async () => {
  const a = repoWithBranches([]);
  try {
    const m = manager([{ id: "a", path: a }]);
    assert.equal(await m.defaultBranchFor(a), "main");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("the repos snapshot reports the overridden default branch, so the diff base follows", async () => {
  // `RepoDTO.defaultBranch` is what `diffStat` and `commitsAhead` measure against
  // (repo_service.ts). If the snapshot ignores the override, every +/- number in the
  // UI is measured from the wrong base while the Settings row claims otherwise.
  const a = repoWithBranches(["trunk"]);
  try {
    const m = manager([{ id: "a", path: a, settings: { defaultBranch: "trunk" } }]);
    const [repo] = await m.listRepos({ includePrs: false });
    assert.equal(repo.defaultBranch, "trunk");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("a new worktree branches from the overridden default", async () => {
  // The base a session's branch forks from. Getting this wrong means the PR is
  // opened against the wrong base and shows unrelated commits.
  const a = repoWithBranches(["trunk"]);
  const root = mkdtempSync(join(homedir(), ".makit-test-db-"));
  try {
    const m = manager([{ id: "a", path: a, settings: { defaultBranch: "trunk", worktreeRoot: root } }]);
    const { path: wt } = await m.createWorktree("a", undefined, "from-trunk");
    const mergeBase = execFileSync("git", ["merge-base", "HEAD", "trunk"], { cwd: wt })
      .toString()
      .trim();
    const trunkTip = execFileSync("git", ["rev-parse", "trunk"], { cwd: a }).toString().trim();
    assert.equal(mergeBase, trunkTip, "the new branch forked from trunk, not main");
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(root, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// SPEC-per-repo-settings D4' — re-pointing a project that moved on disk.
//
// Why this is not "remove and re-add": that mints a new `PersistedProject.id`, and
// everything keyed to it — per-repo settings, session history — is lost. Preserving
// the id across a move is the entire reason the id exists.
// ---------------------------------------------------------------------------

test("re-pointing keeps the project id and its settings", async () => {
  // The whole justification. If the settings do not survive, the user has done
  // remove-and-re-add by a longer route.
  const from = repoWithBranches([]);
  const to = repoWithBranches([]);
  try {
    const m = manager([{ id: "a", path: from, settings: { logoHue: 4 } }]);
    const r = await m.repointProject("a", to);
    assert.equal(r.ok, true);
    const [dto] = m.listProjects();
    assert.equal(dto.id, "a", "the id is preserved");
    assert.equal(dto.path, realpathSync(to));
    assert.deepEqual(m.projectSettings("a"), { logoHue: 4 });
  } finally {
    rmSync(from, { recursive: true, force: true });
    rmSync(to, { recursive: true, force: true });
  }
});

test("re-pointing at something that is not a git repo is refused", async () => {
  // The constraint D4' names explicitly: re-validate that the target is a git repo,
  // because a project silently pointed at a plain directory has no branches, no
  // forge and no diff — and looks merely broken rather than misconfigured.
  const from = repoWithBranches([]);
  const plain = mkdtempSync(join(tmpdir(), "makit-plain-"));
  try {
    const m = manager([{ id: "a", path: from }]);
    const r = await m.repointProject("a", plain);
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.error, /git/i);
    assert.equal(m.listProjects()[0].path, from, "and the project is untouched");
  } finally {
    rmSync(from, { recursive: true, force: true });
    rmSync(plain, { recursive: true, force: true });
  }
});

test("re-pointing onto another project's path is refused", async () => {
  // Two projects at one path makes settings and the forge decision — both looked up
  // BY PATH — ambiguous, so one repo would silently answer for the other.
  const a = repoWithBranches([]);
  const b = repoWithBranches([]);
  try {
    const m = manager([
      { id: "a", path: a },
      { id: "b", path: b },
    ]);
    const r = await m.repointProject("a", b);
    assert.equal(r.ok, false);
    assert.match(r.ok ? "" : r.error, /already/i);
    assert.equal(m.listProjects()[0].path, a);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("re-pointing a project at its own path is a no-op, not a duplicate error", async () => {
  // Re-submitting the same value must not read as a conflict with itself.
  const a = repoWithBranches([]);
  try {
    const m = manager([{ id: "a", path: a }]);
    assert.equal((await m.repointProject("a", a)).ok, true);
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("re-pointing an unknown project is refused rather than creating one", async () => {
  const a = repoWithBranches([]);
  try {
    const m = manager([]);
    const r = await m.repointProject("ghost", a);
    assert.equal(r.ok, false);
    assert.equal(m.listProjects().length, 0);
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("a new path given via a symlink is stored canonicalised", async () => {
  // `settingsForPath` and the router's decision map are both keyed by path, so an
  // uncanonicalised value would mean the repo's own settings stop resolving for it.
  // The symlink must point at a DIFFERENT directory: aliasing the project's own path
  // is the no-op case and would prove nothing about the stored value.
  const from = repoWithBranches([]);
  const to = repoWithBranches([]);
  const link = join(mkdtempSync(join(tmpdir(), "makit-link-")), "alias");
  symlinkSync(to, link);
  try {
    const m = manager([{ id: "a", path: from, settings: { provider: "gitea" } }]);
    assert.equal((await m.repointProject("a", link)).ok, true);
    const stored = m.listProjects()[0].path;
    assert.equal(stored, realpathSync(to), "stored resolved, not as the alias");
    assert.equal(m.providerFor(stored), "gitea", "and its settings still resolve");
  } finally {
    rmSync(from, { recursive: true, force: true });
    rmSync(to, { recursive: true, force: true });
  }
});

test("re-pointing at an equivalent spelling of the same directory changes nothing", async () => {
  // `/tmp/x` and `/private/tmp/x` are one directory on macOS. Treating that as a
  // move would re-run detection for no reason and report a path the store does not
  // hold, so the no-op reports what is actually in force.
  const a = repoWithBranches([]);
  const alias = join(mkdtempSync(join(tmpdir(), "makit-alias-")), "same");
  symlinkSync(a, alias);
  try {
    const m = manager([{ id: "a", path: a }]);
    const r = await m.repointProject("a", alias);
    assert.equal(r.ok, true);
    assert.equal(r.ok && r.path, m.listProjects()[0].path, "reports the path in force");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("re-pointing re-runs detection rather than keeping the old forge decision", async () => {
  // D4' names this: the forge and the default branch may both change with the move,
  // so a cached decision for the OLD path must not be what the UI reports.
  const from = repoWithBranches([]);
  const to = repoWithBranches([]);
  const forgotten: string[] = [];
  try {
    const m = manager([{ id: "a", path: from }]);
    Object.assign((m as unknown as { _gateway: object })._gateway, {
      forgetRepo: (p: string) => forgotten.push(p),
    });
    assert.equal((await m.repointProject("a", to)).ok, true);
    assert.deepEqual(forgotten, [from], 'keyed on the path the gateway was called with');
  } finally {
    rmSync(from, { recursive: true, force: true });
    rmSync(to, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// SPEC-per-repo-settings — "New worktree from PR" has to work on BOTH providers.
//
// Listing already routed through the gateway, so the picker showed Forgejo PRs
// correctly. The CHECKOUT did not: it ran `gh pr checkout` unconditionally, which
// speaks only to GitHub. The flow was therefore broken exactly halfway — the user
// saw their PRs, picked one, and the worktree never appeared.
//
// The strategy is chosen from the router's own decision, so it agrees with whichever
// provider actually served the list.
// ---------------------------------------------------------------------------

test("a GitHub repo checks out via gh, preserving today's behaviour", async () => {
  const a = repoWithBranches([]);
  try {
    const m = managerWithInspector([{ id: "a", path: a }], {
      forgeFor: () => ({ software: "github", host: "github.com", source: "detected" }),
      hasRemoteFor: () => true,
    });
    assert.equal(m.prCheckoutStrategyFor(a), "gh");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("a Forgejo repo checks out via the pull ref, because gh cannot reach it", async () => {
  const a = repoWithBranches([]);
  try {
    const m = managerWithInspector([{ id: "a", path: a }], {
      forgeFor: () => ({ software: "forgejo", host: "git.example", authed: true, source: "detected" }),
      hasRemoteFor: () => true,
    });
    assert.equal(m.prCheckoutStrategyFor(a), "pull-ref");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("a Gitea repo does the same — one REST API, one checkout path", async () => {
  const a = repoWithBranches([]);
  try {
    const m = managerWithInspector([{ id: "a", path: a }], {
      forgeFor: () => ({ software: "gitea", host: "git.example", authed: true, source: "detected" }),
      hasRemoteFor: () => true,
    });
    assert.equal(m.prCheckoutStrategyFor(a), "pull-ref");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("an OVERRIDE to Forgejo also changes how the PR is checked out", async () => {
  // The override's whole purpose is a repo detection could not identify. If it moved
  // the listing but not the checkout, "New worktree from PR" would still fail for
  // exactly the repos the override exists to rescue.
  const a = repoWithBranches([]);
  try {
    const m = managerWithInspector([{ id: "a", path: a, settings: { provider: "forgejo" } }], {
      // Detection reports the unidentifiable case; the override is what decides.
      forgeFor: () => ({ software: "forgejo", host: "priv.example", authed: true, source: "override" }),
      hasRemoteFor: () => true,
    });
    assert.equal(m.prCheckoutStrategyFor(a), "pull-ref");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("an unrouted or unreadable repo falls back to gh, the status quo", async () => {
  // Same rule the router itself follows for an unreadable remote: don't change where
  // such a repo fails.
  const a = repoWithBranches([]);
  try {
    const m = manager([{ id: "a", path: a }]);
    assert.equal(m.prCheckoutStrategyFor(a), "gh");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("the provider override wins over a stale detection record", async () => {
  // Belt and braces: the strategy is read from the same override the router honours,
  // so it cannot disagree with the gateway that served the list even if the decision
  // record is behind.
  const a = repoWithBranches([]);
  try {
    const m = managerWithInspector([{ id: "a", path: a, settings: { provider: "github" } }], {
      forgeFor: () => ({ software: "forgejo", host: "old.example", authed: true, source: "detected" }),
      hasRemoteFor: () => true,
    });
    assert.equal(m.prCheckoutStrategyFor(a), "gh", "the user said GitHub");
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("the picker itself routes per repo: Forgejo and GitHub side by side", async () => {
  // The end of the chain the user actually touches: `manager.listOpenPrs` is what the
  // `worktree.prs` command calls. Two repos in ONE manager, so this cannot pass by a
  // global default -- which is the way a routing bug usually hides.
  const served: string[] = [];
  const fj = repoWithBranches([]);
  const gh = repoWithBranches([]);
  const stub = (name: string) => ({
    prForBranch: async () => ({ kind: "none" }) as never,
    openPrs: async () => {
      served.push(name);
      return [];
    },
    mutatePr: async () => ({ ok: true }),
    stats: () => ({ execs: 0, exemptExecs: 0, cacheHits: 0 }),
    close: () => {},
  });
  try {
    const router = createForgeRouter({
      github: {
        ...stub("github"),
        budget: () => ({}) as never,
        history: () => [],
        refresh: async () => ({}) as never,
        setPaused: () => {},
        onBudgetChange: () => () => {},
      } as never,
      forgejo: stub("forgejo") as never,
      unsupported: stub("unsupported") as never,
      none: stub("none") as never,
      // Wired to the manager below, exactly as production wires it.
      providerFor: (p) => m.providerFor(p),
      resolveInstance: async (p) => ({
        host: p === gh ? "github.com" : "git.example",
        baseUrl: "https://git.example",
      }),
      detect: async () => "unknown" as never,
    });
    const m = manager([
      { id: "fj", path: fj, settings: { provider: "forgejo" } },
      { id: "gh", path: gh },
    ]);
    Object.assign((m as unknown as { _gateway: object })._gateway, router);

    await m.listOpenPrs("fj");
    await m.listOpenPrs("gh");
    assert.deepEqual(served, ["forgejo", "github"], "each repo's PRs came from its own provider");
  } finally {
    rmSync(fj, { recursive: true, force: true });
    rmSync(gh, { recursive: true, force: true });
  }
});

test("a repo set to None offers no PRs, so the picker cannot reach a checkout", async () => {
  // The checkout strategy for `none` is moot only because the list is empty. Asserted
  // rather than assumed: if None ever returned PRs, the user could pick one and the
  // checkout would run against a forge they told makit to ignore.
  const a = repoWithBranches([]);
  try {
    const router = createForgeRouter({
      github: {
        prForBranch: async () => ({ kind: "none" }) as never,
        openPrs: async () => [{ number: 1, title: "t", headRefName: "h", isDraft: false, url: "u" }],
        mutatePr: async () => ({ ok: true }),
        stats: () => ({ execs: 0, exemptExecs: 0, cacheHits: 0 }),
        close: () => {},
        budget: () => ({}) as never,
        history: () => [],
        refresh: async () => ({}) as never,
        setPaused: () => {},
        onBudgetChange: () => () => {},
      } as never,
      forgejo: {} as never,
      unsupported: {} as never,
      none: createNoForgeGateway(),
      providerFor: (p) => m.providerFor(p),
      resolveInstance: async () => ({ host: "github.com", baseUrl: "https://github.com" }),
      detect: async () => "unknown" as never,
    });
    const m = manager([{ id: "a", path: a, settings: { provider: "none" } }]);
    Object.assign((m as unknown as { _gateway: object })._gateway, router);
    assert.deepEqual(await m.listOpenPrs("a"), []);
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Review findings on the P2 work itself.
// ---------------------------------------------------------------------------

test("addProject will not open one directory twice under two spellings", async () => {
  // Found while reviewing `repointProject`: that method refuses a duplicate path
  // using a CANONICAL comparison, but `addProject` compared with `resolve` only,
  // which does not follow symlinks. So the state repointProject carefully forbids —
  // two projects at one directory, where settings and the forge decision are both
  // looked up BY PATH and therefore answer for each other — was still reachable by
  // the ordinary "add a project" route, and the two entry points disagreed about
  // what counts as the same repo.
  const real = repoWithBranches([]);
  const link = join(mkdtempSync(join(tmpdir(), "makit-addlink-")), "alias");
  symlinkSync(real, link);
  try {
    const m = manager([]);
    const first = m.addProject(real);
    const second = m.addProject(link);
    assert.equal(second.id, first.id, "the same directory is the same project");
    assert.equal(m.listProjects().length, 1);
  } finally {
    rmSync(real, { recursive: true, force: true });
  }
});

test("a project reached by its canonical path still resolves its own settings", async () => {
  // Review finding: `addProject` stores the RESOLVED (not canonicalised) spelling,
  // while `settingsForPath` compared with `resolve` on both sides. A project added via
  // a symlinked path therefore failed lookup when a caller supplied the canonical
  // path, and `worktreeRootFor`, `providerFor` and `defaultBranchFor` all silently
  // fell back to the defaults -- the override present on disk and shown in the UI,
  // doing nothing.
  const real = repoWithBranches([]);
  // The parent is retained so it can be removed too: only the symlink inside it was
  // being cleaned up, leaving one empty temp directory per run.
  const linkParent = mkdtempSync(join(tmpdir(), "makit-slink-"));
  const link = join(linkParent, "alias");
  symlinkSync(real, link);
  try {
    const m = manager([{ id: "a", path: link, settings: { provider: "gitea" } }]);
    assert.equal(m.providerFor(link), "gitea", "found by the stored spelling");
    assert.equal(
      m.providerFor(realpathSync(real)),
      "gitea",
      "and by the canonical one, which is what git hands back",
    );
  } finally {
    rmSync(linkParent, { recursive: true, force: true });
    rmSync(real, { recursive: true, force: true });
  }
});

test("an invalid override falls back WITHOUT mislabelling an environment root", async () => {
  // Review finding: the fallback re-resolved correctly and then overwrote the source
  // with "default". `SettingSourceDTO` exists so the app labels the origin rather than
  // guessing, so with MAKIT_WORKTREE_DIR set the badge stated the wrong one.
  const a = repoWithBranches([]);
  const envRoot = mkdtempSync(join(homedir(), ".makit-test-env-"));
  const prev = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = envRoot;
  try {
    const m = manager([{ id: "a", path: a, settings: { worktreeRoot: "/etc/nope" } }]);
    const [repo] = await m.listRepos({ includePrs: false });
    assert.equal(repo.settings?.worktreeRoot.value, envRoot);
    assert.equal(repo.settings?.worktreeRoot.source, "environment");
  } finally {
    if (prev === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prev;
    rmSync(a, { recursive: true, force: true });
    rmSync(envRoot, { recursive: true, force: true });
  }
});
