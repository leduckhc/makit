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
import type {
  ForgeGateway,
  ForgeProviderId,
  ForgeSoftwareName,
  GatewayStats,
  PrLookup,
  PrMutation,
  ProviderMix,
} from "./types.js";
import { createFetchHttp, createForgejoGateway, type ForgejoRepoRef } from "./forgejo/gateway.js";
import { parseForgejoRemote } from "./forgejo/map.js";
import { createForgeDetector, isGitHubHost } from "./detect.js";
import { createUnsupportedGateway } from "./unsupported.js";
import { createNoForgeGateway } from "./none.js";
import type { ProviderChoice } from "../repo_settings.js";

// Re-exported: routing is where callers reach for it, detection is where it lives.
export { isGitHubHost };

/**
 * Reads the origin URL. Declared here rather than imported from
 * `github/queries.ts` so the neutral router does not depend on a provider.
 */
export const ORIGIN_REMOTE_ARGV = ["remote", "get-url", "origin"] as const;

/** Where a repo lives, and how to reach its API. */
export interface ForgeInstance {
  /** Host of the `origin` remote, including a non-default port. */
  host: string;
  /** API base, e.g. `https://git.example.com` or a sub-path install. */
  baseUrl: string;
  /** Token for this instance, if one is configured for it. */
  token?: string;
}

/** Timeout for the local `git remote` read. Local, so this is generous. */
const REMOTE_TIMEOUT_MS = 5_000;


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

/**
 * What routing concluded about one repo. Recorded because nothing else retains it:
 * `chosen` holds only the gateway promise, so without this a caller asking "which
 * forge is this repo on?" would have to re-probe.
 */
export interface RepoForge {
  software: ForgeSoftwareName;
  host: string;
  /**
   * Whether a credential is configured **for that host**. Never the token itself,
   * and omitted for GitHub, where `gh`'s budget is not host-specific
   * authentication and reporting it would be a guess dressed as a fact.
   */
  authed?: boolean;
  /**
   * Whether this repo's provider came from probing the instance or from the user's
   * override (SPEC-48 D3").
   *
   * Recorded because the UI must not caption an override "detected": whether the
   * answer was measured or asserted is the one thing a reader would use to decide
   * how much to trust it — and when an override is in force, detection's answer is
   * deliberately never asked for.
   */
  source: "detected" | "override";
}

/**
 * The narrow port `repo_service` needs. Deliberately not part of the gateway:
 * `listRepos` receives a `GithubGateway`, and widening that contract to carry
 * inspection would put two responsibilities on one interface.
 */
export interface ForgeInspector {
  forgeFor(repoPath: string): RepoForge | undefined;
  /**
   * Whether `origin` could be read, or `undefined` when this repo has not been
   * routed yet.
   *
   * Its own fact rather than `forgeFor(p) !== undefined`, because those two
   * questions have three answers between them and one boolean cannot hold them:
   * *not measured yet*, *no remote so no forge is possible*, and *a forge we
   * identified*. Deriving "has a remote" from the forge decision collapsed the
   * first two, which made the app's "not identified yet" wording unreachable and
   * had every un-polled repo claim to have no remote.
   */
  hasRemoteFor(repoPath: string): boolean | undefined;
}

/**
 * Invalidation, kept apart from {@link ForgeInspector} on purpose: inspection is a
 * read and this is a write, and the consumers are different components. Only the
 * one place that re-points a project needs it (SPEC-48 D4′), so putting it on the
 * read port would hand every reader a way to clear the cache.
 */
export interface ForgeForgetful {
  forgetRepo(repoPath: string): void;
}

export interface ForgeRouterDeps {
  github: GithubGateway;
  forgejo: ForgeGateway;
  /** Used for a forge makit cannot talk to (GitLab, or unidentifiable). */
  unsupported: ForgeGateway;
  /** Used for a repo whose provider the user set to `none`. See `none.ts`. */
  none: ForgeGateway;
  /**
   * The user's per-repo provider override (SPEC-48 D3"), or `auto` to believe
   * detection. Read at routing time rather than injected once, because the setting
   * changes while the daemon runs.
   */
  providerFor?: (repoPath: string) => ProviderChoice;
  /** Where a repo lives, or null when the remote cannot be read. */
  resolveInstance: (repoPath: string) => Promise<ForgeInstance | null>;
  /** Ask the instance what software it runs. See `detect.ts`. */
  detect: (baseUrl: string, token?: string) => Promise<ForgeSoftwareName>;
  /** Called once per host that turns out to be unsupported, for logging. */
  onUnsupported?: (host: string, software: ForgeSoftwareName) => void;
}

export function createForgeRouter(
  deps: ForgeRouterDeps,
): GithubGateway & ProviderMix & ForgeInspector & ForgeForgetful {
  /**
   * Cache of the chosen provider per repo. Stores the PROMISE, not the resolved
   * value, so the home-screen fan-out — which hits every worktree of a repo at
   * once — shares one `git remote` read instead of spawning one per worktree.
   *
   * The CHOICE that produced it is stored alongside, so a changed override
   * re-routes on the next call. Without that, setting a provider would appear to do
   * nothing until the daemon restarted, which is indistinguishable from the feature
   * being broken.
   */
  const chosen = new Map<string, { choice: ProviderChoice; gateway: Promise<ForgeGateway> }>();
  /**
   * Providers actually reached. Recorded rather than inferred from config because
   * only routing knows the truth, and the poll cadence depends on it.
   */
  const inUse = new Set<ForgeProviderId>();
  /** Hosts already reported as unsupported, so the log says it once, not per tick. */
  const warned = new Set<string>();
  /** What routing concluded, per repo. See {@link RepoForge}. */
  const decided = new Map<string, RepoForge>();
  /** Whether `origin` was readable, per repo. See {@link ForgeInspector.hasRemoteFor}. */
  const remotes = new Map<string, boolean>();

  function pick(repoPath: string): Promise<ForgeGateway> {
    const choice = deps.providerFor?.(repoPath) ?? "auto";
    const hit = chosen.get(repoPath);
    // Re-check the choice, but keep the cache when it has not changed: re-resolving
    // on every call would throw away the read-sharing the fan-out depends on.
    if (hit !== undefined && hit.choice === choice) return hit.gateway;
    const p = route(repoPath, choice);
    chosen.set(repoPath, { choice, gateway: p });
    return p;
  }

  function route(repoPath: string, choice: ProviderChoice): Promise<ForgeGateway> {
    return (async (): Promise<ForgeGateway> => {
      // `none` short-circuits before the remote is even read. "Talks to no forge"
      // has to include not looking one up, or it is a label rather than an
      // instruction — and the decision is the user's, so there is nothing to learn.
      if (choice === "none") {
        inUse.add("none");
        decided.delete(repoPath);
        remotes.delete(repoPath);
        return deps.none;
      }

      const inst = await deps.resolveInstance(repoPath);
      remotes.set(repoPath, inst !== null);

      // An override is honoured WITHOUT probing. That is the point: the cases it
      // exists for are exactly the ones where the probe cannot answer — a private
      // instance that 401s an anonymous request, or one behind a proxy that hides
      // the version endpoint. Spending the probe anyway would delay every poll to
      // learn nothing.
      if (choice !== "auto") {
        if (inst !== null) {
          decided.set(repoPath, {
            software: choice,
            host: inst.host,
            // Omitted for GitHub for the same reason detection omits it.
            ...(choice === "github"
              ? {}
              : { authed: inst.token !== undefined && inst.token.length > 0 }),
            source: "override",
          });
        }
        if (choice === "github") {
          inUse.add("github");
          return deps.github;
        }
        inUse.add("forgejo");
        return deps.forgejo;
      }

      // No readable remote: stay on gh, which is the status quo for anything that
      // is not a checkout. Routing it elsewhere would change where such a
      // directory fails, for no gain.
      if (inst === null || isGitHubHost(inst.host)) {
        inUse.add("github");
        if (inst !== null) {
          decided.set(repoPath, { software: "github", host: inst.host, source: "detected" });
        }
        return deps.github;
      }
      const software = await deps.detect(inst.baseUrl, inst.token);
      decided.set(repoPath, {
        software,
        host: inst.host,
        authed: inst.token !== undefined && inst.token.length > 0,
        source: "detected",
      });
      if (software === "forgejo" || software === "gitea") {
        inUse.add("forgejo");
        return deps.forgejo;
      }
      inUse.add("unsupported");
      if (!warned.has(inst.host)) {
        warned.add(inst.host);
        deps.onUnsupported?.(inst.host, software);
      }
      return deps.unsupported;
    })().catch(() => {
      // A transient failure must not discard an EXPLICIT choice. Falling back to gh
      // here would ignore an instruction the user gave and send the repo to a
      // provider that cannot talk to its host — and because the result is cached
      // against the choice that produced it, one failed `git remote` read would pin
      // the repo to the wrong provider until the setting changed or the daemon
      // restarted.
      //
      // Record the remote as unreadable ONLY if nothing was recorded, because two
      // different failures land here: the remote read failing (no remote) and
      // DETECTION failing (a good remote we could not classify, already recorded as
      // `true`). Setting `false` unconditionally would turn the second into a claim
      // that the repo has no origin — a fact we just measured otherwise.
      if (!remotes.has(repoPath)) remotes.set(repoPath, false);
      // `auto` keeps the original behaviour: with no opinion attached, gh is the
      // status quo for a repo we could not read.
      if (choice === "forgejo" || choice === "gitea") {
        inUse.add("forgejo");
        return deps.forgejo;
      }
      if (choice === "none") {
        inUse.add("none");
        return deps.none;
      }
      inUse.add("github");
      return deps.github;
    });
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

    /**
     * Summed across EVERY provider, so the ≥80% call-reduction figure covers every
     * one in play.
     *
     * `unsupported` and `none` report zeros today, so omitting them was right by
     * accident — and would have drifted silently the moment either started counting a
     * call. Reading all four costs nothing and keeps the number honest by
     * construction rather than by coincidence.
     */
    stats(): GatewayStats {
      const all = [deps.github, deps.forgejo, deps.unsupported, deps.none].map((g) => g.stats());
      return {
        execs: all.reduce((n, s) => n + s.execs, 0),
        exemptExecs: all.reduce((n, s) => n + s.exemptExecs, 0),
        cacheHits: all.reduce((n, s) => n + s.cacheHits, 0),
      };
    },
    providersInUse: () => new Set(inUse),
    forgeFor: (repoPath: string) => decided.get(repoPath),
    hasRemoteFor: (repoPath: string) => remotes.get(repoPath),
    /**
     * Discard everything routing learned about [repoPath].
     *
     * Called when a project is re-pointed (SPEC-48 D4′): the repo at the old path is
     * no longer the project's repo, so its cached gateway, forge decision and remote
     * fact must not be reported — and detection has to run again for the new path,
     * because the forge may have changed with the move.
     */
    forgetRepo(repoPath: string): void {
      chosen.delete(repoPath);
      decided.delete(repoPath);
      remotes.delete(repoPath);
    },
    close(): void {
      chosen.clear();
      inUse.clear();
      warned.clear();
      decided.clear();
      remotes.clear();
      // All four, for the same reason `stats` reads all four: the two no-op gateways
      // close to nothing today, and a provider that later acquires a timer or socket
      // must not depend on someone remembering to add it here.
      for (const g of [deps.github, deps.forgejo, deps.unsupported, deps.none]) g.close();
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
  /** See {@link ForgeRouterDeps.providerFor}. */
  providerFor?: (repoPath: string) => ProviderChoice;
}): GithubGateway {
  const env = opts.env ?? process.env;
  const readRemote = async (repoPath: string): Promise<string | null> => {
    const r = await opts.exec("git", [...ORIGIN_REMOTE_ARGV], repoPath, REMOTE_TIMEOUT_MS);
    if (r.code !== 0) return null;
    const url = r.stdout.trim();
    return url.length > 0 ? url : null;
  };
  const http = createFetchHttp();
  const detector = createForgeDetector({ http });
  let currentSoftware: ForgeSoftwareName = "unknown";
  const router = createForgeRouter({
    github: createGithubGateway({ exec: opts.exec }),
    forgejo: createForgejoGateway({
      http,
      resolveRepo: async (repoPath) => {
        const url = await readRemote(repoPath);
        return url === null ? null : forgejoRefFromRemote(url, env);
      },
    }),
    unsupported: createUnsupportedGateway({ software: () => currentSoftware }),
    none: createNoForgeGateway(),
    providerFor: opts.providerFor,
    resolveInstance: async (repoPath) => {
      const url = await readRemote(repoPath);
      if (url === null) return null;
      const ref = forgejoRefFromRemote(url, env);
      if (ref === null) return null;
      const host = parseForgejoRemote(url)?.host;
      return host === undefined ? null : { host, baseUrl: ref.baseUrl, token: ref.token };
    },
    detect: async (baseUrl, token) => {
      currentSoftware = await detector.detect(baseUrl, token);
      return currentSoftware;
    },
    onUnsupported: (host, software) => {
      const what = software === "unknown" ? "an unrecognised forge" : software;
      // Once per host. Silent failure here is what made this class of bug
      // indistinguishable from an outage.
      console.warn(
        `[makit] ${host} looks like ${what}; makit has no provider for it, so pull-request status is unavailable for repositories there.`,
      );
    },
  });
  return router;
}
