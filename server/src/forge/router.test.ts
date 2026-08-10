import { test } from "node:test";
import assert from "node:assert/strict";

import { createForgeRouter, forgejoRefFromRemote, isGitHubHost, ORIGIN_REMOTE_ARGV } from "./router.js";
import type { ForgeGateway, GatewayStats, PrLookup } from "./types.js";
import type { GithubGateway } from "../github/gateway.js";

/** A recording stand-in for either provider. */
function fake(name: string, calls: string[]): ForgeGateway {
  return {
    prForBranch: async (repoPath, branch) => {
      calls.push(`${name}.prForBranch(${repoPath},${branch})`);
      return { kind: "none" } as PrLookup;
    },
    openPrs: async (repoPath) => {
      calls.push(`${name}.openPrs(${repoPath})`);
      return [];
    },
    mutatePr: async (repoPath, _branch, _number, verb) => {
      calls.push(`${name}.mutatePr(${repoPath},${verb})`);
      return { ok: true };
    },
    stats: () => ({ execs: name === "github" ? 3 : 5, exemptExecs: 1, cacheHits: 2 }) as GatewayStats,
    close: () => calls.push(`${name}.close`),
  };
}

function githubFake(calls: string[]): GithubGateway {
  const base = fake("github", calls);
  return {
    ...base,
    budget: () => {
      calls.push("github.budget");
      return { level: "high" } as never;
    },
    history: () => {
      calls.push("github.history");
      return [];
    },
    refresh: async () => {
      calls.push("github.refresh");
      return { level: "high" } as never;
    },
    setPaused: (p: boolean) => calls.push(`github.setPaused(${p})`),
    onBudgetChange: (fn) => {
      calls.push("github.onBudgetChange");
      void fn;
      return () => {};
    },
  } as GithubGateway;
}

function harness(hosts: Record<string, string | null>) {
  const calls: string[] = [];
  const lookups: string[] = [];
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    resolveHost: async (repoPath) => {
      lookups.push(repoPath);
      return hosts[repoPath] ?? null;
    },
  });
  return { router, calls, lookups };
}

// ---------------------------------------------------------------------------
// Host classification
// ---------------------------------------------------------------------------

test("isGitHubHost accepts github.com and its subdomains only", () => {
  assert.equal(isGitHubHost("github.com"), true);
  assert.equal(isGitHubHost("GitHub.com"), true);
  assert.equal(isGitHubHost("www.github.com"), true);
  assert.equal(isGitHubHost("git.example.com"), false);
  assert.equal(isGitHubHost("codeberg.org"), false);
  // Must not be fooled by a lookalike host.
  assert.equal(isGitHubHost("github.com.evil.test"), false);
  assert.equal(isGitHubHost("notgithub.com"), false);
});

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

test("a github.com repo goes to the gh-backed gateway", async () => {
  const { router, calls } = harness({ "/gh": "github.com" });
  await router.prForBranch("/gh", "b");
  assert.deepEqual(calls, ["github.prForBranch(/gh,b)"]);
});

test("a self-hosted repo goes to the Forgejo gateway", async () => {
  const { router, calls } = harness({ "/fj": "git.example.com" });
  await router.prForBranch("/fj", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/fj,b)"]);
});

test("openPrs and mutatePr route the same way as prForBranch", async () => {
  const { router, calls } = harness({ "/fj": "git.example.com", "/gh": "github.com" });
  await router.openPrs("/fj", 30);
  await router.mutatePr("/fj", "b", 1, "ready");
  await router.openPrs("/gh", 30);
  assert.deepEqual(calls, [
    "forgejo.openPrs(/fj)",
    "forgejo.mutatePr(/fj,ready)",
    "github.openPrs(/gh)",
  ]);
});

test("an unreadable remote falls back to GitHub, preserving today's behaviour", async () => {
  // Routing elsewhere would change the failure mode for every non-git directory;
  // the gh gateway already degrades such a repo to `unknown`.
  const { router, calls } = harness({ "/mystery": null });
  await router.prForBranch("/mystery", "b");
  assert.deepEqual(calls, ["github.prForBranch(/mystery,b)"]);
});

test("the host is resolved once per repo, not once per call", async () => {
  const { router, lookups } = harness({ "/fj": "git.example.com" });
  await router.prForBranch("/fj", "a");
  await router.prForBranch("/fj", "b");
  await router.openPrs("/fj", 30);
  assert.deepEqual(lookups, ["/fj"]);
});

test("concurrent first calls for one repo still resolve the host once", async () => {
  const { router, lookups } = harness({ "/fj": "git.example.com" });
  await Promise.all([router.prForBranch("/fj", "a"), router.prForBranch("/fj", "b")]);
  assert.deepEqual(lookups, ["/fj"], "an in-flight lookup must be shared, not duplicated");
});

// ---------------------------------------------------------------------------
// Budget: GitHub-only, so it delegates rather than being averaged or faked.
// ---------------------------------------------------------------------------

test("budget reporting delegates to GitHub, the only provider with a quota", async () => {
  const { router, calls } = harness({});
  router.budget();
  router.history();
  await router.refresh();
  router.setPaused(true);
  router.onBudgetChange(() => {});
  assert.deepEqual(calls, [
    "github.budget",
    "github.history",
    "github.refresh",
    "github.setPaused(true)",
    "github.onBudgetChange",
  ]);
});

test("stats sums both providers so the call-reduction figure stays whole", () => {
  const { router } = harness({});
  assert.deepEqual(router.stats(), { execs: 8, exemptExecs: 2, cacheHits: 4 });
});

test("close closes both providers", () => {
  const { router, calls } = harness({});
  router.close();
  assert.deepEqual(calls.sort(), ["forgejo.close", "github.close"]);
});

// ---------------------------------------------------------------------------
// Turning a git remote into Forgejo coordinates
// ---------------------------------------------------------------------------

test("ORIGIN_REMOTE_ARGV reads the origin URL without touching the network", () => {
  assert.deepEqual(ORIGIN_REMOTE_ARGV, ["remote", "get-url", "origin"]);
});

test("forgejoRefFromRemote derives base URL, slug and token", () => {
  const ref = forgejoRefFromRemote("git@git.example.com:acme/app.git", {
    MAKIT_FORGEJO_TOKEN: "t0k",
  });
  assert.deepEqual(ref, {
    baseUrl: "https://git.example.com",
    owner: "acme",
    repo: "app",
    token: "t0k",
  });
});

test("forgejoRefFromRemote accepts the common token env names in priority order", () => {
  const pick = (env: Record<string, string>) =>
    forgejoRefFromRemote("https://git.example.com/a/b", env)?.token;
  assert.equal(pick({ MAKIT_FORGEJO_TOKEN: "m", FORGEJO_TOKEN: "f", GITEA_TOKEN: "g" }), "m");
  assert.equal(pick({ FORGEJO_TOKEN: "f", GITEA_TOKEN: "g" }), "f");
  assert.equal(pick({ GITEA_TOKEN: "g" }), "g");
  assert.equal(pick({}), undefined);
});

test("forgejoRefFromRemote honours a base-URL override for subpath installs", () => {
  const ref = forgejoRefFromRemote("https://git.example.com/a/b", {
    MAKIT_FORGEJO_BASE_URL: "https://example.com/forge",
  });
  assert.equal(ref?.baseUrl, "https://example.com/forge");
});

test("forgejoRefFromRemote returns null for a remote it cannot read", () => {
  assert.equal(forgejoRefFromRemote("", {}), null);
  assert.equal(forgejoRefFromRemote("https://git.example.com/only-owner", {}), null);
});
