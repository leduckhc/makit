/**
 * router.ts — picks a forge provider per repository.
 *
 * Deliberately implements {@link GithubGateway} rather than a narrower type, so
 * `server.ts` and `manager.ts` need no changes: the budget surface they depend on
 * is forwarded to the gh-backed gateway, which is the only provider that HAS a
 * quota (Forgejo exposes no `rate_limit` endpoint and no rate-limit headers). A
 * Forgejo repo therefore contributes nothing to the budget panel, which is
 * accurate rather than a stub.
 *
 * Provider choice is by the `origin` remote's host, cached per repo:
 *
 *   github.com (or a subdomain)  -> the `gh`-backed gateway
 *   anything else                -> the Forgejo/Gitea REST gateway
 *   unreadable remote            -> the `gh`-backed gateway
 *
 * "Anything else" is a judgement call worth stating. A hostname cannot tell you
 * that a server runs Forgejo, so this is a guess — but it is a *safe* one:
 * makit previously sent every non-GitHub remote to `gh`, where it failed and
 * surfaced as `unknown`. Sending it to Forgejo instead makes Forgejo and Gitea
 * work, and leaves GitLab/Bitbucket exactly as broken as they already were
 * (a failed REST call is also `unknown`). No case gets worse.
 *
 * An unreadable remote stays on `gh` on purpose: that is the status quo for every
 * directory that is not a git checkout, and changing where such repos fail would
 * be a behaviour change with no upside.
 */

import type { Exec } from "../github/gateway.js";
import { createGithubGateway, type GithubGateway } from "../github/gateway.js";
import type { OpenPr } from "../git.js";
import type { ForgeGateway, GatewayStats, PrLookup, PrMutation } from "./types.js";
import { createFetchHttp, createForgejoGateway, type ForgejoRepoRef } from "./forgejo/gateway.js";
import { parseForgejoRemote } from "./forgejo/map.js";

/**
 * Reads the origin URL. Declared here rather than imported from
 * `github/queries.ts` so the neutral router does not depend on a provider.
 */
export const ORIGIN_REMOTE_ARGV = ["remote", "get-url", "origin"] as const;

/** Timeout for the local `git remote` read. Local, so this is generous. */
const REMOTE_TIMEOUT_MS = 5_000;

/**
 * Whether a host is GitHub. Matches the apex and its subdomains, and nothing
 * else: a suffix test alone would route `github.com.evil.test` to the gh gateway
 * along with any credentials it holds.
 */
export function isGitHubHost(host: string): boolean {
  const h = host.toLowerCase().split(":")[0];
  return h === "github.com" || h.endsWith(".github.com");
}

/**
 * Turn a git remote URL into Forgejo coordinates, or null when it cannot be read.
 *
 * Configuration comes from the environment:
 *
 *   `MAKIT_FORGEJO_BASE_URL` / `FORGEJO_BASE_URL`
 *       The instance's URL. Needed only when `https://<host>` is not right --
 *       an instance behind a sub-path, or plain HTTP on a private network.
 *   `MAKIT_FORGEJO_TOKEN` / `FORGEJO_ACCESS_TOKEN` / `FORGEJO_TOKEN` /
 *   `GITEA_TOKEN`
 *       API token, most specific name first.
 *
 * **A configured instance URL scopes the credentials to that host.** This is a
 * security property, not a convenience: configuring one instance means setting a
 * single global token, and without scoping that token would be attached to every
 * non-GitHub remote — so opening any public Gitea/Forgejo repo would send the
 * user's internal token to a third party. A foreign host is still queried, just
 * unauthenticated, which is the correct outcome for a public repo.
 *
 * With no instance configured there is nothing to scope against (the
 * single-instance case), so the token applies to the remote's own host.
 */
export function forgejoRefFromRemote(
  remoteUrl: string,
  env: Record<string, string | undefined>,
): ForgejoRepoRef | null {
  const parsed = parseForgejoRemote(remoteUrl);
  if (parsed === null) return null;

  const configured = firstSet(env, ["MAKIT_FORGEJO_BASE_URL", "FORGEJO_BASE_URL"]);
  const token = firstSet(env, [
    "MAKIT_FORGEJO_TOKEN",
    "FORGEJO_ACCESS_TOKEN",
    "FORGEJO_TOKEN",
    "GITEA_TOKEN",
  ]);

  // Compared on HOSTNAME alone -- no scheme, no port, no path. The override
  // exists precisely to supply those, and an scp-form remote
  // (`git@host:owner/repo`) cannot express a port at all, so an instance whose
  // API is on :3000 would never match if the port counted.
  const configuredHost = configured === undefined ? undefined : hostnameOf(configured);
  const isConfiguredInstance =
    configuredHost !== undefined && configuredHost.length > 0 && configuredHost === hostnameOnly(parsed.host);

  return {
    baseUrl: isConfiguredInstance && configured !== undefined ? configured : `https://${parsed.host}`,
    owner: parsed.owner,
    repo: parsed.repo,
    // Withheld from any host other than the configured one -- see the note above.
    token: configuredHost === undefined || isConfiguredInstance ? token : undefined,
  };
}

/** First env var of [names] that is set and non-empty. */
function firstSet(env: Record<string, string | undefined>, names: string[]): string | undefined {
  for (const name of names) {
    const v = env[name];
    if (v !== undefined && v.length > 0) return v;
  }
  return undefined;
}

/** Hostname of a URL (no port), lower-cased; empty string when unparseable. */
function hostnameOf(url: string): string {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/** Strip a `:port` suffix from a bare host. */
function hostnameOnly(host: string): string {
  return host.toLowerCase().split(":")[0];
}

export interface ForgeRouterDeps {
  github: GithubGateway;
  forgejo: ForgeGateway;
  /** The `origin` host for a repo, or null when the remote cannot be read. */
  resolveHost: (repoPath: string) => Promise<string | null>;
}

export function createForgeRouter(deps: ForgeRouterDeps): GithubGateway {
  /**
   * Cache of the chosen provider per repo. Stores the PROMISE, not the resolved
   * value, so the home-screen fan-out — which hits every worktree of a repo at
   * once — shares one `git remote` read instead of spawning one per worktree.
   */
  const chosen = new Map<string, Promise<ForgeGateway>>();

  function pick(repoPath: string): Promise<ForgeGateway> {
    const hit = chosen.get(repoPath);
    if (hit !== undefined) return hit;
    const p = deps
      .resolveHost(repoPath)
      .then((host) => (host === null || isGitHubHost(host) ? deps.github : deps.forgejo))
      .catch(() => deps.github);
    chosen.set(repoPath, p);
    return p;
  }

  return {
    async prForBranch(repoPath: string, branch: string, opts?: { interactive?: boolean }): Promise<PrLookup> {
      return (await pick(repoPath)).prForBranch(repoPath, branch, opts);
    },
    async openPrs(repoPath: string, limit: number, opts?: { interactive?: boolean }): Promise<OpenPr[]> {
      return (await pick(repoPath)).openPrs(repoPath, limit, opts);
    },
    async mutatePr(
      repoPath: string,
      branch: string,
      number: number,
      verb: PrMutation,
    ): Promise<{ ok: boolean; error?: string }> {
      return (await pick(repoPath)).mutatePr(repoPath, branch, number, verb);
    },

    // Budget: forwarded verbatim. See the module note on why this is not merged.
    budget: () => deps.github.budget(),
    history: () => deps.github.history(),
    refresh: () => deps.github.refresh(),
    setPaused: (paused: boolean) => deps.github.setPaused(paused),
    onBudgetChange: (fn) => deps.github.onBudgetChange(fn),

    /** Summed, so the ≥80% call-reduction figure covers every provider in play. */
    stats(): GatewayStats {
      const a = deps.github.stats();
      const b = deps.forgejo.stats();
      return {
        execs: a.execs + b.execs,
        exemptExecs: a.exemptExecs + b.exemptExecs,
        cacheHits: a.cacheHits + b.cacheHits,
      };
    },
    close(): void {
      chosen.clear();
      deps.github.close();
      deps.forgejo.close();
    },
  };
}

/**
 * The production wiring: a gh-backed GitHub gateway, a REST-backed Forgejo
 * gateway, and the router over both. `exec` is git.ts's `run`, so `gh` still
 * resolves through PATH and the test PATH-shim keeps working.
 */
export function createDefaultForgeGateway(opts: {
  exec: Exec;
  env?: Record<string, string | undefined>;
}): GithubGateway {
  const env = opts.env ?? process.env;
  const readRemote = async (repoPath: string): Promise<string | null> => {
    const r = await opts.exec("git", [...ORIGIN_REMOTE_ARGV], repoPath, REMOTE_TIMEOUT_MS);
    if (r.code !== 0) return null;
    const url = r.stdout.trim();
    return url.length > 0 ? url : null;
  };
  return createForgeRouter({
    github: createGithubGateway({ exec: opts.exec }),
    forgejo: createForgejoGateway({
      http: createFetchHttp(),
      resolveRepo: async (repoPath) => {
        const url = await readRemote(repoPath);
        return url === null ? null : forgejoRefFromRemote(url, env);
      },
    }),
    resolveHost: async (repoPath) => {
      const url = await readRemote(repoPath);
      return url === null ? null : (parseForgejoRemote(url)?.host ?? null);
    },
  });
}
