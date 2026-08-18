/**
 * gateway.ts — the Forgejo implementation of {@link ForgeGateway}, over REST.
 *
 * No subprocess. Forgejo's API is plain REST with a token, so a request is a
 * `fetch`, which removes three whole classes of problem the `gh`-backed GitHub
 * gateway has to manage: process fan-out (the reason `concurrency.ts` exists),
 * CLI discovery and version skew, and stdout parsing.
 *
 * It also implements NO budget facet on purpose. Forgejo exposes no `rate_limit`
 * endpoint and sends no rate-limit response headers, so there is no quota to
 * ration — the GitHub gateway's router/policy/budget machinery has no counterpart
 * here, and faking one would put a number on screen that means nothing. See
 * `../types.ts`.
 *
 * What remains is a cache (to keep the home-screen fan-out cheap) and strict
 * discipline about the difference between "no PR" and "could not tell", which is
 * SPEC-github-gateway-and-budget §6.5 and the reason every failure path below returns `unknown`.
 */

import type { OpenPr, PullRequestInfo } from "../../git.js";
import { rollupChecks } from "../../git.js";
import type { PrCheckDTO } from "../../protocol.js";
import type { ForgeGateway, GatewayStats, PrLookup, PrMutation } from "../types.js";
import {
  DEFAULT_WIP_PREFIXES,
  combinedStatusUrl,
  forgejoChecks,
  mapForgejoPr,
  mergeUrl,
  openPrsUrl,
  pickLatestPr,
  prDetailUrl,
  prForBranchUrl,
  readyTitle,
  updateBranchUrl,
} from "./map.js";

/** One HTTP request. `timeoutMs` is advisory to the adapter. */
export interface HttpRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
  timeoutMs: number;
}

/**
 * An HTTP response. `status: 0` means the request never completed (DNS, TLS,
 * timeout, connection refused).
 */
export interface HttpResponse {
  status: number;
  body: string;
  /**
   * Response headers, keys lower-cased. Only `retry-after` is read today, but a
   * throttled response is useless without it: guessing a backoff either ignores
   * the server's instruction or parks the poller far longer than it asked for.
   */
  headers?: Record<string, string>;
}

/**
 * The injectable HTTP seam. Mirrors {@link import("../../github/gateway.js").Exec}
 * in one important respect: it MUST NOT reject. A transport failure is data
 * (`status: 0`), not an exception, so a single unreachable instance can never
 * take down the poller that fans out across every worktree.
 */
export type Http = (req: HttpRequest) => Promise<HttpResponse>;

/** Where a local repo path lives on a Forgejo instance. */
export interface ForgejoRepoRef {
  /** Instance origin, e.g. `https://git.example.com` (no trailing slash needed). */
  baseUrl: string;
  owner: string;
  repo: string;
  /** API token. Absent means unauthenticated — fine for public reads. */
  token?: string;
}

/** Resolve a local repo path to its Forgejo coordinates, or null if it isn't one. */
export type ResolveRepo = (repoPath: string) => Promise<ForgejoRepoRef | null>;

export interface ForgejoGatewayDeps {
  http: Http;
  resolveRepo: ResolveRepo;
  /** Clock, injectable so cache expiry is testable without real time. */
  now?: () => number;
  /**
   * The instance's `WORK_IN_PROGRESS_PREFIXES`. Defaults to Forgejo's own
   * defaults; pass the server's real value when it can be read, because "mark
   * ready for review" strips one of these from the title.
   */
  wipPrefixes?: readonly string[];
}

/** Read timeout for cheap, indexed reads (combined status, PR detail). */
const READ_TIMEOUT_MS = 5_000;
/**
 * Timeout for the branch->PR lookup specifically.
 *
 * Far above {@link READ_TIMEOUT_MS} because Forgejo's `head` filter is an
 * unindexed scan: measured against codeberg.org (Forgejo 16, ~9.5k PRs) the same
 * `state=all&head=X&limit=5` query returned in 1.5s on some attempts and 20-30s
 * on others. A tight cap turns that variance into a stream of `unknown` results,
 * which flickers the PR pill to "unmeasured" on a repo that is merely busy.
 *
 * A self-hosted instance with a normal repo is expected to be far quicker; this
 * cap exists for the pathological end. If a real instance proves slow enough for
 * this to hurt, the known optimisation is the dedicated
 * `/pulls/{base}/{head}` endpoint (~1.9s, single object) once the base ref is
 * known -- deliberately not built yet, since it trades a guess about `base` for
 * speed we may not need.
 */
const BRANCH_LOOKUP_TIMEOUT_MS = 20_000;
/** The picker's list is larger, so it gets the same slack `gh` got. */
const OPEN_PRS_TIMEOUT_MS = 8_000;
/**
 * Write timeout — deliberately far above the read timeout. Abandoning a read
 * costs a stale pill; abandoning a write costs correctness, because the server
 * may apply it anyway while the caller, told it failed, skips its cache
 * invalidation and reports pre-mutation state until the TTL runs out.
 */
const MUTATION_TIMEOUT_MS = 60_000;

const TTL_PR_MS = 20_000;
const TTL_OPEN_PRS_MS = 60_000;

/**
 * Statuses that mean "stop asking": 429 from a rate limiter, 503 from a server
 * shedding load. Forgejo core has no rate limiter, but instances routinely sit
 * behind nginx `limit_req`, Cloudflare or an anti-scraper gate.
 */
const THROTTLE_STATUSES = new Set([429, 503]);
/** Backoff when the server throttles us without saying for how long. */
const DEFAULT_BACKOFF_MS = 60_000;
/**
 * Ceiling on an honoured `Retry-After`. A misconfigured proxy (or a hostile one)
 * can answer `86400`, and obeying that literally would silently disable PR
 * polling for a day with no way for the user to tell why.
 */
const MAX_BACKOFF_MS = 5 * 60_000;

/** Parse `Retry-After`: delta-seconds or an HTTP date. Null when unusable. */
function parseRetryAfter(value: string | undefined, now: number): number | null {
  if (value === undefined) return null;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000;
  const at = Date.parse(trimmed);
  return Number.isFinite(at) ? Math.max(0, at - now) : null;
}

interface CacheEntry {
  value: unknown;
  expiresAt: number;
}

function isOk(res: HttpResponse): boolean {
  return res.status >= 200 && res.status < 300;
}

/** Parse a JSON body, returning `undefined` rather than throwing. */
function parseJson(body: string): unknown {
  try {
    return JSON.parse(body) as unknown;
  } catch {
    return undefined;
  }
}

/**
 * The most useful error text available: Forgejo's own `message` when it sent
 * one, else the raw body, else the status. Surfacing the server's wording keeps
 * the diagnosis accurate (a branch-protection refusal reads as such).
 */
function errorText(res: HttpResponse): string {
  const parsed = parseJson(res.body);
  if (typeof parsed === "object" && parsed !== null) {
    const msg = (parsed as { message?: unknown }).message;
    if (typeof msg === "string" && msg.trim().length > 0) return msg.trim();
  }
  const raw = res.body.trim();
  if (raw.length > 0 && raw.length < 300) return raw;
  return res.status === 0 ? "request failed" : `HTTP ${res.status}`;
}

export function createForgejoGateway(deps: ForgejoGatewayDeps): ForgeGateway {
  const now = deps.now ?? (() => Date.now());
  const wipPrefixes = deps.wipPrefixes ?? DEFAULT_WIP_PREFIXES;
  const cache = new Map<string, CacheEntry>();
  const stats: GatewayStats = { execs: 0, exemptExecs: 0, cacheHits: 0 };
  /** Epoch ms until which background requests are withheld. 0 = not throttled. */
  let backoffUntil = 0;

  /** True while a server-requested pause is in force. */
  const throttled = (): boolean => backoffUntil > now();

  /**
   * Record a throttling response. Interactive callers are still allowed through
   * (a button press must reach the server), so this only gates polling.
   */
  function noteThrottle(res: HttpResponse): void {
    const asked = parseRetryAfter(res.headers?.["retry-after"], now());
    const wait = Math.min(asked ?? DEFAULT_BACKOFF_MS, MAX_BACKOFF_MS);
    backoffUntil = now() + Math.max(wait, 1);
  }

  function cacheGet<T>(key: string): T | undefined {
    const hit = cache.get(key);
    if (hit === undefined) return undefined;
    if (hit.expiresAt <= now()) {
      cache.delete(key);
      return undefined;
    }
    return hit.value as T;
  }

  function cacheSet(key: string, value: unknown, ttlMs: number): void {
    cache.set(key, { value, expiresAt: now() + ttlMs });
  }

  /**
   * In-flight requests, so N callers asking the same question issue ONE request.
   *
   * The cache alone is not enough: it is only populated once a response arrives, so on
   * a cold cache the home-screen fan-out -- every worktree of a repo at once -- issued
   * one copy per worktree of a query this module measures at 1.5-30s against a real
   * instance (see BRANCH_LOOKUP_TIMEOUT_MS). The GitHub gateway shares in-flight work
   * for the same reason.
   *
   * Keyed exactly like the cache entry it will produce, so a branch never receives
   * another branch's answer.
   */
  const inflight = new Map<string, Promise<unknown>>();

  function share<T>(key: string, run: () => Promise<T>): Promise<T> {
    const hit = inflight.get(key) as Promise<T> | undefined;
    if (hit !== undefined) return hit;
    // `finally` rather than `then`: a rejection must also release the slot, or one
    // failure would wedge that key for the process lifetime.
    const p = run().finally(() => {
      if (inflight.get(key) === p) inflight.delete(key);
    });
    inflight.set(key, p);
    return p;
  }

  /** Drop every cached open-PR list for a repo, whatever limit it was asked with. */
  function dropOpenPrLists(repoPath: string): void {
    const prefix = `open:${repoPath}:`;
    for (const key of cache.keys()) if (key.startsWith(prefix)) cache.delete(key);
  }

  function headers(ref: ForgejoRepoRef, withBody: boolean): Record<string, string> {
    const h: Record<string, string> = { Accept: "application/json" };
    // Forgejo/Gitea's own credential form. Omitted entirely when absent, so an
    // unauthenticated read of a public repo is not sent a bogus header.
    if (ref.token !== undefined && ref.token.length > 0) h.Authorization = `token ${ref.token}`;
    if (withBody) h["Content-Type"] = "application/json";
    return h;
  }

  /**
   * Issue one request. Defensive against an adapter that rejects despite the
   * {@link Http} contract — a throwing adapter must degrade to `unknown`, not
   * take down the caller.
   */
  async function call(
    ref: ForgejoRepoRef,
    url: string,
    opts: { method?: string; body?: unknown; timeoutMs?: number } = {},
  ): Promise<HttpResponse> {
    const method = opts.method ?? "GET";
    const body = opts.body === undefined ? undefined : JSON.stringify(opts.body);
    stats.execs += 1;
    let res: HttpResponse;
    try {
      res = await deps.http({
        url,
        method,
        headers: headers(ref, body !== undefined),
        body,
        timeoutMs: opts.timeoutMs ?? READ_TIMEOUT_MS,
      });
    } catch {
      res = { status: 0, body: "" };
    }
    if (THROTTLE_STATUSES.has(res.status)) noteThrottle(res);
    // Any completed, non-throttled answer means the server is talking to us
    // again -- holding the backoff after that would throttle us on our own.
    else if (res.status !== 0) backoffUntil = 0;
    return res;
  }

  const prKey = (repoPath: string, branch: string) => `pr:${repoPath}:${branch}`;

  async function prForBranch(
    repoPath: string,
    branch: string,
    opts?: { interactive?: boolean },
  ): Promise<PrLookup> {
    const ref = await deps.resolveRepo(repoPath);
    // Not a Forgejo repo (or the remote could not be read): we never queried, so
    // the answer is unmeasured. Returning `none` here would erase the pill and
    // read as "this branch has no PR" -- a fact we do not have.
    if (ref === null) return { kind: "unknown", reason: "error" };

    const key = prKey(repoPath, branch);
    if (opts?.interactive !== true) {
      const hit = cacheGet<PrLookup>(key);
      if (hit !== undefined) {
        stats.cacheHits += 1;
        return hit;
      }
      // The server asked us to wait. `throttled`, not `none`: a pause is not
      // evidence that the branch has no PR (SPEC-github-gateway-and-budget §6.5).
      if (throttled()) return { kind: "unknown", reason: "throttled" };
    }

    // Shared, so the fan-out across a repo's worktrees issues one request per
    // (repo, branch) rather than one per caller.
    const listed = await share(`req:${key}`, () =>
      call(ref, prForBranchUrl(ref.baseUrl, ref.owner, ref.repo, branch), {
        timeoutMs: BRANCH_LOOKUP_TIMEOUT_MS,
      }),
    );
    if (!isOk(listed)) {
      return {
        kind: "unknown",
        reason: THROTTLE_STATUSES.has(listed.status) ? "throttled" : "error",
      };
    }
    const rows = parseJson(listed.body);
    // A non-array body is a malformed or error response, not an empty repo.
    if (!Array.isArray(rows)) return { kind: "unknown", reason: "error" };

    const raw = pickLatestPr(rows as Array<Record<string, unknown> | null>);
    if (raw === null) {
      const miss: PrLookup = { kind: "none" };
      cacheSet(key, miss, TTL_PR_MS);
      return miss;
    }
    const core = mapForgejoPr(raw);
    // We found a row but could not read it — again unmeasured, not absent.
    if (core === null) return { kind: "unknown", reason: "error" };

    let checks: PrCheckDTO[] = [];
    if (core.headSha !== null) {
      const status = await call(ref, combinedStatusUrl(ref.baseUrl, ref.owner, ref.repo, core.headSha));
      // A PR we already found must not disappear because CI could not be read;
      // an empty check list renders as "no checks", which is the honest fallback.
      if (isOk(status)) checks = forgejoChecks(parseJson(status.body));
    }

    const pr: PullRequestInfo = {
      number: core.number,
      url: core.url,
      state: core.state,
      title: core.title,
      isDraft: core.isDraft,
      mergeable: core.mergeable,
      mergeStateStatus: core.mergeStateStatus,
      baseRefName: core.baseRefName,
      checks,
      checkRollup: rollupChecks(checks),
      // Forgejo exposes resolution per review COMMENT (`resolver`), not per
      // thread, and only via a reviews -> comments walk. Until that walk is
      // verified against an instance with real review threads, the count is
      // declared unmeasured rather than reported as 0 -- a plain 0 would render
      // as "no unresolved comments" and be believed (SPEC-github-gateway-and-budget §6.5).
      unresolvedComments: 0,
      unresolvedUnknown: true,
    };
    const found: PrLookup = { kind: "pr", pr };
    cacheSet(key, found, TTL_PR_MS);
    return found;
  }

  async function openPrs(repoPath: string, limit: number, opts?: { interactive?: boolean }): Promise<OpenPr[]> {
    const ref = await deps.resolveRepo(repoPath);
    if (ref === null) return [];

    const key = `open:${repoPath}:${limit}`;
    if (opts?.interactive !== true) {
      const hit = cacheGet<OpenPr[]>(key);
      if (hit !== undefined) {
        stats.cacheHits += 1;
        return hit;
      }
      if (throttled()) return [];
    }

    const res = await share(`req:${key}`, () =>
      call(ref, openPrsUrl(ref.baseUrl, ref.owner, ref.repo, limit), {
        timeoutMs: OPEN_PRS_TIMEOUT_MS,
      }),
    );
    if (!isOk(res)) return [];
    const rows = parseJson(res.body);
    if (!Array.isArray(rows)) return [];

    const out: OpenPr[] = [];
    for (const raw of rows) {
      if (typeof raw !== "object" || raw === null) continue;
      const r = raw as Record<string, unknown>;
      if (typeof r.number !== "number") continue;
      const head = r.head as { ref?: unknown } | undefined;
      out.push({
        number: r.number,
        title: typeof r.title === "string" ? r.title : "",
        headRefName: typeof head?.ref === "string" ? head.ref : "",
        isDraft: r.draft === true,
        url: typeof r.html_url === "string" ? r.html_url : "",
      });
    }
    // Newest first. Sorted here rather than requested from the server because
    // Forgejo's `sort` enum has no created-desc member: the default order is
    // newest-first in practice but is not part of the contract, and the picker
    // relies on it.
    out.sort((a, b) => b.number - a.number);
    cacheSet(key, out, TTL_OPEN_PRS_MS);
    return out;
  }

  /**
   * Take a PR out of draft. On Forgejo this is a TITLE REWRITE, not a flag flip:
   * `draft` is a read-only projection of the title's WIP prefix and
   * `EditPullRequestOption` has no `draft` field.
   *
   * The title is re-read immediately before the write instead of being taken from
   * the cached lookup, because a PATCH sends the whole title: acting on a stale
   * copy would silently revert an edit made in the web UI since the last poll.
   */
  async function markReady(ref: ForgejoRepoRef, number: number): Promise<{ ok: boolean; error?: string }> {
    const url = prDetailUrl(ref.baseUrl, ref.owner, ref.repo, number);
    const res = await call(ref, url);
    if (!isOk(res)) return { ok: false, error: errorText(res) };
    const parsed = parseJson(res.body);
    const title = typeof parsed === "object" && parsed !== null ? (parsed as { title?: unknown }).title : undefined;
    if (typeof title !== "string") return { ok: false, error: "could not read the pull request title" };

    const next = readyTitle(title, wipPrefixes);
    if (next === null) {
      return {
        ok: false,
        error: `#${number} is not a draft: its title carries none of the instance's work-in-progress prefixes (${wipPrefixes.join(", ")})`,
      };
    }
    const patched = await call(ref, url, { method: "PATCH", body: { title: next }, timeoutMs: MUTATION_TIMEOUT_MS });
    return isOk(patched) ? { ok: true } : { ok: false, error: errorText(patched) };
  }

  async function mutatePr(
    repoPath: string,
    branch: string,
    number: number,
    verb: PrMutation,
  ): Promise<{ ok: boolean; error?: string }> {
    const ref = await deps.resolveRepo(repoPath);
    if (ref === null) return { ok: false, error: "not a Forgejo repository" };

    let result: { ok: boolean; error?: string };
    if (verb === "ready") {
      result = await markReady(ref, number);
    } else if (verb === "update-branch") {
      const res = await call(ref, updateBranchUrl(ref.baseUrl, ref.owner, ref.repo, number), {
        method: "POST",
        timeoutMs: MUTATION_TIMEOUT_MS,
      });
      result = isOk(res) ? { ok: true } : { ok: false, error: errorText(res) };
    } else {
      // `Do` is PascalCase and required by MergePullRequestOption. Naming the
      // strategy explicitly also avoids inheriting the instance's configurable
      // default, which would make the same button squash on one server and
      // rebase on another.
      const res = await call(ref, mergeUrl(ref.baseUrl, ref.owner, ref.repo, number), {
        method: "POST",
        body: { Do: "squash" },
        timeoutMs: MUTATION_TIMEOUT_MS,
      });
      result = isOk(res) ? { ok: true } : { ok: false, error: errorText(res) };
    }

    // Only a success invalidates: dropping the entry after a failed mutation
    // would spend a fresh round trip to re-learn the state we already hold.
    //
    // BOTH the branch lookup and every open-PR list go: that list backs the "New
    // worktree from PR" picker, so a squash-merged PR left in it leads to a checkout
    // that fails, and a PR just marked ready still reads as a draft. The key carries
    // the limit, and the picker and the home screen ask with different ones, so one
    // delete is not enough.
    if (result.ok) {
      cache.delete(prKey(repoPath, branch));
      dropOpenPrLists(repoPath);
    }
    return result;
  }

  return {
    prForBranch,
    openPrs,
    mutatePr,
    stats: () => ({ ...stats }),
    close: () => {
      cache.clear();
      inflight.clear();
    },
  };
}

/**
 * Production {@link Http} over global `fetch`, upholding the never-reject
 * contract: every failure mode becomes `status: 0`.
 */
export function createFetchHttp(): Http {
  return async (req: HttpRequest): Promise<HttpResponse> => {
    try {
      const res = await fetch(req.url, {
        method: req.method,
        headers: req.headers,
        body: req.body,
        signal: AbortSignal.timeout(req.timeoutMs),
      });
      const headers: Record<string, string> = {};
      const retryAfter = res.headers.get("retry-after");
      if (retryAfter !== null) headers["retry-after"] = retryAfter;
      return { status: res.status, body: await res.text(), headers };
    } catch {
      return { status: 0, body: "" };
    }
  };
}
