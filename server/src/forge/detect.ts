/**
 * detect.ts — identify which forge software an instance runs.
 *
 * Replaces a guess. Routing previously keyed off the hostname alone — github.com
 * meant GitHub, everything else was ASSUMED to be Forgejo — which sent GitLab and
 * Bitbucket remotes to the Forgejo provider, where they failed as `unknown`,
 * indistinguishable from "your instance is down". A hostname cannot tell you what
 * software a server runs; asking the server can.
 *
 * The discriminators are endpoints, not version-string sniffing, and each was
 * verified against a live instance:
 *
 *   GET /api/forgejo/v1/version   200 on Forgejo (codeberg.org, and a self-hosted
 *                                 16.0.0), 404 on Gitea (gitea.com)
 *   GET /api/v1/version           200 + {"version":...} on both Forgejo and Gitea;
 *                                 GitLab answers a 302 to its sign-in page
 *   GET /api/v4/version           401 unauthenticated on gitlab.com — which is
 *                                 still proof it is GitLab
 *
 * Forgejo is probed first because it is decisive in ONE call, and it is the case
 * we care about; Gitea costs two, and anything else three. Results are cached per
 * instance, so this never touches the PR hot path more than once.
 */

import type { Http } from "./forgejo/gateway.js";

/** Which software an instance runs. `unknown` means we could not tell. */
export type ForgeSoftware = "github" | "forgejo" | "gitea" | "gitlab" | "unknown";

/** Probe timeout. A version endpoint is trivial; a slow answer is a bad sign. */
const PROBE_TIMEOUT_MS = 8_000;

/**
 * How long a FAILED detection is remembered.
 *
 * Short on purpose. Caching a failure forever would pin an instance that happened
 * to be down during the first probe as unsupported until the server restarts —
 * the user would see "unsupported forge" on a perfectly good Forgejo. Short
 * enough to recover quickly, long enough not to re-probe a down host every tick.
 */
export const NEGATIVE_TTL_MS = 60_000;

const trim = (base: string): string => base.replace(/\/+$/, "");

/** Forgejo's own API namespace — absent on Gitea. */
export function forgejoProbeUrl(baseUrl: string): string {
  return `${trim(baseUrl)}/api/forgejo/v1/version`;
}

/** The Gitea-compatible version endpoint, served by both Forgejo and Gitea. */
export function giteaProbeUrl(baseUrl: string): string {
  return `${trim(baseUrl)}/api/v1/version`;
}

/** GitLab's version endpoint. */
export function gitlabProbeUrl(baseUrl: string): string {
  return `${trim(baseUrl)}/api/v4/version`;
}

/**
 * Whether a host is GitHub. Matches the apex and its subdomains and nothing else:
 * a bare suffix test would classify `github.com.evil.test` as GitHub and hand it
 * whatever credentials that path carries.
 */
export function isGitHubHost(host: string): boolean {
  const h = host.toLowerCase().split(":")[0];
  return h === "github.com" || h.endsWith(".github.com");
}

/** Whether a body is a Gitea-family `{"version": "..."}` payload. */
export function isGiteaFamilyVersion(body: string): boolean {
  try {
    const parsed = JSON.parse(body) as { version?: unknown };
    return typeof parsed.version === "string" && parsed.version.length > 0;
  } catch {
    return false;
  }
}

/**
 * Whether a Gitea-family version string is actually Forgejo. Forgejo reports its
 * own version with a `+gitea-x.y.z` API-compatibility suffix (`16.0.0+gitea-1.22.0`)
 * where Gitea reports a bare `1.27.0`. Only used as a fallback for an instance
 * whose `/api/forgejo` namespace is hidden by a proxy.
 */
function looksLikeForgejoVersion(body: string): boolean {
  try {
    const v = (JSON.parse(body) as { version?: unknown }).version;
    return typeof v === "string" && /\+gitea-/i.test(v);
  } catch {
    return false;
  }
}

export interface ForgeDetectorDeps {
  http: Http;
  now?: () => number;
}

export interface ForgeDetector {
  /**
   * Identify the software at `baseUrl`. `token` is used for the probe because a
   * private instance (`REQUIRE_SIGNIN_VIEW`) answers 401 to anonymous callers,
   * which would otherwise read as "not a forge".
   */
  detect(baseUrl: string, token?: string): Promise<ForgeSoftware>;
  /** Forget everything learned (tests, and gateway close). */
  clear(): void;
}

interface CachedDetection {
  value: ForgeSoftware;
  /** null = never expires (a positive result); a number = epoch ms. */
  expiresAt: number | null;
}

export function createForgeDetector(deps: ForgeDetectorDeps): ForgeDetector {
  const now = deps.now ?? (() => Date.now());
  const settled = new Map<string, CachedDetection>();
  /** In-flight probes, so a fan-out across worktrees shares one round trip. */
  const inFlight = new Map<string, Promise<ForgeSoftware>>();

  async function probe(url: string, token: string | undefined) {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (token !== undefined && token.length > 0) headers.Authorization = `token ${token}`;
    try {
      return await deps.http({ url, method: "GET", headers, timeoutMs: PROBE_TIMEOUT_MS });
    } catch {
      return { status: 0, body: "" };
    }
  }

  const ok = (status: number): boolean => status >= 200 && status < 300;

  async function classify(baseUrl: string, token: string | undefined): Promise<ForgeSoftware> {
    // 1. Forgejo's own namespace: decisive, and one call.
    const fj = await probe(forgejoProbeUrl(baseUrl), token);
    if (ok(fj.status) && isGiteaFamilyVersion(fj.body)) return "forgejo";

    // 2. Gitea-compatible version endpoint: Forgejo and Gitea both serve it.
    const gt = await probe(giteaProbeUrl(baseUrl), token);
    if (ok(gt.status) && isGiteaFamilyVersion(gt.body)) {
      return looksLikeForgejoVersion(gt.body) ? "forgejo" : "gitea";
    }

    // 3. GitLab. Any answer at all counts -- 401 is what gitlab.com returns
    // unauthenticated, and only GitLab serves that path.
    const gl = await probe(gitlabProbeUrl(baseUrl), token);
    if (ok(gl.status) || gl.status === 401 || gl.status === 403) return "gitlab";

    return "unknown";
  }

  return {
    async detect(baseUrl: string, token?: string): Promise<ForgeSoftware> {
      const key = trim(baseUrl).toLowerCase();
      const hit = settled.get(key);
      if (hit !== undefined && (hit.expiresAt === null || hit.expiresAt > now())) return hit.value;

      const running = inFlight.get(key);
      if (running !== undefined) return running;

      const p = classify(baseUrl, token)
        .then((value) => {
          settled.set(key, {
            value,
            // Only a failure expires; a server does not change software often
            // enough to be worth re-probing, and a wrong positive is loud.
            expiresAt: value === "unknown" ? now() + NEGATIVE_TTL_MS : null,
          });
          return value;
        })
        .finally(() => inFlight.delete(key));
      inFlight.set(key, p);
      return p;
    },
    clear(): void {
      settled.clear();
      inFlight.clear();
    },
  };
}
