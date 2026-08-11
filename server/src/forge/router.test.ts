import { test } from "node:test";
import assert from "node:assert/strict";

import { createForgeRouter, forgejoRefFromRemote, isGitHubHost, ORIGIN_REMOTE_ARGV } from "./router.js";
import type { ForgeGateway, ForgeSoftwareName, GatewayStats, PrLookup } from "./types.js";
import type { ProviderChoice } from "../repo_settings.js";
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
  /**
   * Per-repo provider overrides, MUTABLE on purpose: the setting is changed while
   * the daemon runs, so a test that could only set it before the first route
   * would never catch the routing cache serving a stale decision.
   */
  const choices = new Map<string, ProviderChoice>();
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    unsupported: fake("unsupported", calls),
    none: fake("none", calls),
    providerFor: (repoPath: string) => choices.get(repoPath) ?? "auto",
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
  return { router, calls, lookups, probes, choices };
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
    none: fake("none", calls),
    resolveInstance: async () => ({ host: "git.example", baseUrl: "https://git.example" }),
    detect: async () => {
      throw new Error("probe exploded");
    },
  });
  await router.prForBranch("/fj", "b");
  assert.deepEqual(calls, ["github.prForBranch(/fj,b)"]);
});

// ---------------------------------------------------------------------------
// F1/F2 — the router records what it decided, because nothing else retains it:
// `chosen` holds only the gateway promise.
// ---------------------------------------------------------------------------

test("forgeFor is undefined until a repo has been routed", () => {
  const { router } = harness({ "/fj": "git.example" });
  assert.equal(router.forgeFor("/fj"), undefined);
});

test("forgeFor reports the software, host and whether a credential exists", async () => {
  const { router } = harness({ "/gt": "gitea.example" }, { "gitea.example": "gitea" });
  await router.prForBranch("/gt", "b");
  assert.deepEqual(router.forgeFor("/gt"), {
    software: "gitea",
    host: "gitea.example",
    authed: true,
    source: "detected",
  });
});

test("a GitHub repo reports no authed flag — gh's budget is not host auth", async () => {
  const { router } = harness({ "/gh": "github.com" });
  await router.prForBranch("/gh", "b");
  assert.deepEqual(router.forgeFor("/gh"), {
    software: "github",
    host: "github.com",
    source: "detected",
  });
});

test("an unsupported forge is still recorded, so the UI can name it", async () => {
  const { router } = harness({ "/gl": "gitlab.example" }, { "gitlab.example": "gitlab" });
  await router.prForBranch("/gl", "b");
  assert.equal(router.forgeFor("/gl")?.software, "gitlab");
});

test("a repo with no readable remote records nothing rather than guessing github.com", async () => {
  // `forge: undefined` on the DTO means "not measured"; inventing a host here
  // would make a local-only repo claim to be on GitHub.
  const { router } = harness({ "/mystery": null });
  await router.prForBranch("/mystery", "b");
  assert.equal(router.forgeFor("/mystery"), undefined);
});

test("close() forgets the decisions", async () => {
  const { router } = harness({ "/fj": "git.example" });
  await router.prForBranch("/fj", "b");
  router.close();
  assert.equal(router.forgeFor("/fj"), undefined);
});

// ---------------------------------------------------------------------------
// P2 / D3" — the provider override DRIVES ROUTING.
//
// The whole point of the control: detection returns `unknown` for a private
// instance that answers 401 to an anonymous probe, and for one behind a proxy
// that hides `/api/forgejo/v1/version`. Both route to the *unsupported* provider,
// where the repo is unusable with no recourse. The override is the recourse — so
// it must pick the gateway, not merely be displayed.
// ---------------------------------------------------------------------------

test("an override to Forgejo rescues a repo detection could not identify", async () => {
  // Detection says `unknown`, which today lands on `unsupported` — unusable.
  const { router, calls, choices } = harness({ "/fj": "private.example" }, { "private.example": "unknown" });
  choices.set("/fj", "forgejo");
  await router.prForBranch("/fj", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/fj,b)"]);
});

test("an override skips the probe entirely — the probe is what failed", async () => {
  // Not an optimisation. A proxy that hides the version endpoint makes the probe
  // useless; spending it anyway would delay every poll for no information.
  const { router, probes, choices } = harness({ "/fj": "private.example" }, { "private.example": "unknown" });
  choices.set("/fj", "forgejo");
  await router.prForBranch("/fj", "b");
  assert.deepEqual(probes, []);
});

test("an override to Gitea routes to the Forgejo provider and records gitea", async () => {
  const { router, calls, choices } = harness({ "/gt": "gt.example" }, { "gt.example": "unknown" });
  choices.set("/gt", "gitea");
  await router.prForBranch("/gt", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/gt,b)"]);
  assert.equal(router.forgeFor("/gt")?.software, "gitea");
});

test("an override to GitHub sends a non-github.com host to the gh gateway", async () => {
  // A GitHub Enterprise host is not github.com, so the host rule alone sends it to
  // Forgejo, where it fails. This is the only way to reach `gh` for such a repo.
  const { router, calls, choices } = harness({ "/ghe": "github.acme.test" });
  choices.set("/ghe", "github");
  await router.prForBranch("/ghe", "b");
  assert.deepEqual(calls, ["github.prForBranch(/ghe,b)"]);
});

test("an override to None talks to no forge at all", async () => {
  // "Stops checking pull requests" has to mean no provider call and no remote read,
  // otherwise it is a label rather than an instruction.
  const { router, calls, lookups, probes, choices } = harness({ "/mirror": "gt.example" });
  choices.set("/mirror", "none");
  const lookup = await router.prForBranch("/mirror", "b");
  assert.deepEqual(calls, ["none.prForBranch(/mirror,b)"]);
  assert.deepEqual(lookups, [], "None must not even read the origin remote");
  assert.deepEqual(probes, []);
  // `none`, not `unknown`: we are not failing to look, we were told not to.
  assert.deepEqual(lookup, { kind: "none" });
});

test("None counts as its own provider in the mix, so cadence can ignore it", async () => {
  const { router, choices } = harness({ "/mirror": "gt.example" });
  choices.set("/mirror", "none");
  await router.prForBranch("/mirror", "b");
  assert.deepEqual([...router.providersInUse()], ["none"]);
});

test("changing the override re-routes WITHOUT a restart", async () => {
  // The routing cache keys on the repo path alone, so without re-checking the
  // choice the setting would appear to do nothing until the daemon restarted —
  // which is indistinguishable from the feature being broken.
  const { router, calls, choices } = harness({ "/r": "git.example" });
  await router.prForBranch("/r", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/r,b)"]);
  choices.set("/r", "github");
  await router.prForBranch("/r", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/r,b)", "github.prForBranch(/r,b)"]);
});

test("an unchanged override still resolves the host only once", async () => {
  // Re-checking the choice must not throw away the cache that makes the home-screen
  // fan-out cheap.
  const { router, lookups, choices } = harness({ "/r": "git.example" });
  choices.set("/r", "forgejo");
  await router.prForBranch("/r", "b");
  await router.prForBranch("/r", "c");
  await router.openPrs("/r", 10);
  assert.deepEqual(lookups, ["/r"]);
});

test("forgeFor says the decision came from the override, not from detection", async () => {
  // The UI must not caption an override "detected": that is the one thing the
  // reader would use to decide whether to trust it.
  const { router, choices } = harness({ "/fj": "private.example" }, { "private.example": "unknown" });
  choices.set("/fj", "forgejo");
  await router.prForBranch("/fj", "b");
  assert.deepEqual(router.forgeFor("/fj"), {
    software: "forgejo",
    host: "private.example",
    authed: true,
    source: "override",
  });
});

test("a detected decision is labelled detected", async () => {
  const { router } = harness({ "/gt": "gitea.example" }, { "gitea.example": "gitea" });
  await router.prForBranch("/gt", "b");
  assert.equal(router.forgeFor("/gt")?.source, "detected");
});

test("Auto is unchanged: detection still decides", async () => {
  const { router, calls, probes } = harness({ "/gl": "gitlab.example" }, { "gitlab.example": "gitlab" });
  await router.prForBranch("/gl", "b");
  assert.deepEqual(probes, ["https://gitlab.example"]);
  assert.equal(calls[0], "warn(gitlab.example,gitlab)");
  assert.equal(calls[1], "unsupported.prForBranch(/gl,b)");
});

// ---------------------------------------------------------------------------
// P2 — "no remote" and "not measured yet" must be separable.
//
// `settingsDtoFor` derived hasRemote from `forge !== undefined`, which made the
// app's "Auto: not identified yet" branch UNREACHABLE: every repo that had not
// been polled yet claimed to have no remote. rev 3.2 pinned that these two read
// differently, so the router has to record the remote as its own fact.
// ---------------------------------------------------------------------------

test("hasRemoteFor is undefined until the repo has been routed", () => {
  const { router } = harness({ "/r": "git.example" });
  assert.equal(router.hasRemoteFor("/r"), undefined);
});

test("hasRemoteFor is true once a readable remote has been routed", async () => {
  const { router } = harness({ "/r": "git.example" });
  await router.prForBranch("/r", "b");
  assert.equal(router.hasRemoteFor("/r"), true);
});

test("hasRemoteFor is false for a repo whose origin cannot be read", async () => {
  // The local-only repo. `forgeFor` is undefined here too — which is exactly why
  // one field cannot carry both facts.
  const { router } = harness({ "/local": null });
  await router.prForBranch("/local", "b");
  assert.equal(router.hasRemoteFor("/local"), false);
  assert.equal(router.forgeFor("/local"), undefined);
});

test("close() forgets the remote facts along with the decisions", async () => {
  const { router } = harness({ "/r": "git.example" });
  await router.prForBranch("/r", "b");
  router.close();
  assert.equal(router.hasRemoteFor("/r"), undefined);
});

test("a transient lookup failure does NOT discard an explicit override", async () => {
  // Found while reviewing the override work. The router falls back to GitHub when
  // routing throws, which was right when nothing could contradict it. With an
  // override it is wrong twice over: it ignores an explicit instruction, and `gh`
  // cannot talk to the host anyway — so every call fails.
  //
  // Worse, the fallback is CACHED against the choice that produced it, so one
  // transient error pins the repo to the wrong provider until the setting changes
  // or the daemon restarts.
  const calls: string[] = [];
  const choices = new Map<string, ProviderChoice>([["/fj", "forgejo"]]);
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    unsupported: fake("unsupported", calls),
    none: fake("none", calls),
    providerFor: (p) => choices.get(p) ?? "auto",
    resolveInstance: async () => {
      throw new Error("git remote read exploded");
    },
    detect: async () => "forgejo",
  });
  await router.prForBranch("/fj", "b");
  assert.deepEqual(calls, ["forgejo.prForBranch(/fj,b)"]);
  // And it is not pinned to a wrong answer by that one failure.
  await router.openPrs("/fj", 10);
  assert.deepEqual(calls, ["forgejo.prForBranch(/fj,b)", "forgejo.openPrs(/fj)"]);
});

test("Auto still falls back to GitHub when routing throws", async () => {
  // The status quo for a repo with no opinion attached, unchanged.
  const calls: string[] = [];
  const router = createForgeRouter({
    github: githubFake(calls),
    forgejo: fake("forgejo", calls),
    unsupported: fake("unsupported", calls),
    none: fake("none", calls),
    resolveInstance: async () => {
      throw new Error("boom");
    },
    detect: async () => "forgejo",
  });
  await router.prForBranch("/x", "b");
  assert.deepEqual(calls, ["github.prForBranch(/x,b)"]);
});
