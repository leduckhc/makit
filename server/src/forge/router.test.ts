import { test } from "node:test";
import assert from "node:assert/strict";

import { createForgeRouter, forgejoRefFromRemote, isGitHubHost, ORIGIN_REMOTE_ARGV } from "./router.js";
import type { ForgeGateway, ForgeSoftwareName, GatewayStats, PrLookup } from "./types.js";
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

/**
 * [hosts] maps a repo path to its origin host (null = unreadable remote), and
 * [software] maps a host to what detection reports for it. A host with no entry
 * defaults to "forgejo", which keeps the routing tests focused on routing.
 */
function harness(hosts: Record<string, string | null>, software: Record<string, ForgeSoftwareName> = {}) {
  const calls: string[] = [];
  const lookups: string[] = [];
  const probes: string[] = [];
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    unsupported: fake("unsupported", calls),
    resolveInstance: async (repoPath: string) => {
      lookups.push(repoPath);
      const host = hosts[repoPath];
      if (host === undefined || host === null) return null;
      return { host, baseUrl: `https://${host}`, token: "t" };
    },
    detect: async (baseUrl: string) => {
      probes.push(baseUrl);
      const host = baseUrl.replace("https://", "");
      return software[host] ?? "forgejo";
    },
    onUnsupported: (host, sw) => calls.push(`warn(${host},${sw})`),
  });
  return { router, calls, lookups, probes };
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
  assert.equal(
    pick({
      MAKIT_FORGEJO_TOKEN: "m",
      FORGEJO_ACCESS_TOKEN: "a",
      FORGEJO_TOKEN: "f",
      GITEA_TOKEN: "g",
    }),
    "m",
  );
  assert.equal(pick({ FORGEJO_ACCESS_TOKEN: "a", FORGEJO_TOKEN: "f" }), "a");
  assert.equal(pick({ FORGEJO_TOKEN: "f", GITEA_TOKEN: "g" }), "f");
  assert.equal(pick({ GITEA_TOKEN: "g" }), "g");
  assert.equal(pick({}), undefined);
});

test("forgejoRefFromRemote honours a base-URL override for the host it names", () => {
  for (const key of ["MAKIT_FORGEJO_BASE_URL", "FORGEJO_BASE_URL"]) {
    const ref = forgejoRefFromRemote("https://git.example.com/a/b", {
      [key]: "https://git.example.com/forge",
    });
    assert.equal(ref?.baseUrl, "https://git.example.com/forge", key);
  }
});

// A configured instance URL scopes the credentials to THAT host. Without this a
// single global FORGEJO_ACCESS_TOKEN -- the normal way to configure one instance
// -- would be attached to every non-GitHub remote, so cloning any public Gitea
// repo would ship the user's internal token to a third party.
test("a configured instance never lends its token to a different host", () => {
  const env = {
    FORGEJO_BASE_URL: "https://forgejo.internal.example",
    FORGEJO_ACCESS_TOKEN: "secret",
  };
  const own = forgejoRefFromRemote("https://forgejo.internal.example/a/b", env);
  assert.equal(own?.token, "secret");
  assert.equal(own?.baseUrl, "https://forgejo.internal.example");

  const foreign = forgejoRefFromRemote("https://codeberg.org/a/b", env);
  assert.equal(foreign?.token, undefined, "the internal token must not leave its host");
  // Still usable unauthenticated against its own host, not the configured one.
  assert.equal(foreign?.baseUrl, "https://codeberg.org");
});

test("the base-URL override matches on host, ignoring scheme, port and path", () => {
  const env = { FORGEJO_BASE_URL: "http://git.example.com:3000/forge", FORGEJO_TOKEN: "t" };
  const ref = forgejoRefFromRemote("git@git.example.com:a/b.git", env);
  assert.equal(ref?.baseUrl, "http://git.example.com:3000/forge");
  assert.equal(ref?.token, "t");
});

test("with no instance configured the token applies to the remote's own host", () => {
  // The single-instance case: there is nothing to scope against, so the token is
  // attached to whatever host the remote names.
  const ref = forgejoRefFromRemote("https://git.example.com/a/b", { FORGEJO_TOKEN: "t" });
  assert.equal(ref?.token, "t");
  assert.equal(ref?.baseUrl, "https://git.example.com");
});

test("forgejoRefFromRemote returns null for a remote it cannot read", () => {
  assert.equal(forgejoRefFromRemote("", {}), null);
  assert.equal(forgejoRefFromRemote("https://git.example.com/only-owner", {}), null);
});

// ---------------------------------------------------------------------------
// Which providers are actually in play. The poll cadence needs this: GitHub's
// degradation ladder exists to ration GitHub quota, and must not throttle a
// Forgejo-only setup where there is no quota to ration.
// ---------------------------------------------------------------------------

test("providersInUse is empty until a repo has been routed", () => {
  const { router } = harness({ "/fj": "git.example.com" });
  assert.deepEqual([...router.providersInUse()], []);
});

test("providersInUse learns each provider as repos are routed", async () => {
  const { router } = harness({ "/fj": "git.example.com", "/gh": "github.com" });
  await router.prForBranch("/fj", "b");
  assert.deepEqual([...router.providersInUse()], ["forgejo"]);
  await router.prForBranch("/gh", "b");
  assert.deepEqual([...router.providersInUse()].sort(), ["forgejo", "github"]);
});

test("close() forgets the provider mix along with the routing cache", async () => {
  const { router } = harness({ "/fj": "git.example.com" });
  await router.prForBranch("/fj", "b");
  router.close();
  assert.deepEqual([...router.providersInUse()], []);
});

// ---------------------------------------------------------------------------
// Detection-driven routing. Before this, EVERY non-GitHub host was assumed to be
// Forgejo, so a GitLab remote was polled against an API that does not exist there
// and reported `unknown` -- identical to the instance being down.
// ---------------------------------------------------------------------------

test("a Gitea instance routes to the Forgejo provider (same REST API)", async () => {
  const { router, calls } = harness({ "/gt": "gitea.example" }, { "gitea.example": "gitea" });
  await router.prForBranch("/gt", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/gt,b)"]);
});

test("a GitLab instance routes to the unsupported provider, not Forgejo", async () => {
  const { router, calls } = harness({ "/gl": "gitlab.example" }, { "gitlab.example": "gitlab" });
  await router.prForBranch("/gl", "b");
  assert.ok(calls.includes("unsupported.prForBranch(/gl,b)"), calls.join(","));
  assert.ok(!calls.some((c) => c.startsWith("forgejo.")), "must not query a Forgejo API that is not there");
});

test("an unidentifiable forge routes to the unsupported provider", async () => {
  const { router, calls } = harness({ "/x": "mystery.example" }, { "mystery.example": "unknown" });
  await router.prForBranch("/x", "b");
  assert.ok(calls.includes("unsupported.prForBranch(/x,b)"), calls.join(","));
});

test("an unsupported host is reported once, not once per poll", async () => {
  const { router, calls } = harness({ "/gl": "gitlab.example" }, { "gitlab.example": "gitlab" });
  await router.prForBranch("/gl", "a");
  await router.prForBranch("/gl", "b");
  await router.openPrs("/gl", 30);
  assert.equal(calls.filter((c) => c.startsWith("warn(")).length, 1, calls.join(","));
  assert.deepEqual(
    calls.filter((c) => c.startsWith("warn(")),
    ["warn(gitlab.example,gitlab)"],
  );
});

test("GitHub is never probed -- the host is decisive", async () => {
  const { router, probes } = harness({ "/gh": "github.com" });
  await router.prForBranch("/gh", "b");
  assert.deepEqual(probes, [], "no round trip should be spent identifying github.com");
});

test("detection runs once per repo, like the rest of the routing decision", async () => {
  const { router, probes } = harness({ "/fj": "git.example" });
  await router.prForBranch("/fj", "a");
  await router.prForBranch("/fj", "b");
  await router.openPrs("/fj", 30);
  assert.deepEqual(probes, ["https://git.example"]);
});

test("an unsupported forge counts as its own provider in the mix", async () => {
  const { router } = harness({ "/gl": "gitlab.example" }, { "gitlab.example": "gitlab" });
  await router.prForBranch("/gl", "b");
  assert.deepEqual([...router.providersInUse()], ["unsupported"]);
});

test("a detection failure falls back to GitHub rather than breaking the poll", async () => {
  const calls: string[] = [];
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    unsupported: fake("unsupported", calls),
    resolveInstance: async () => ({ host: "git.example", baseUrl: "https://git.example" }),
    detect: async () => {
      throw new Error("probe exploded");
    },
  });
  await router.prForBranch("/fj", "b");
  assert.deepEqual(calls, ["github.prForBranch(/fj,b)"]);
});
