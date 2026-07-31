/**
 * queries.ts — the `gh` argv for each GitHub read + its cost declaration
 * (SPEC-32 §6.4/§5, purity column). Pure: builds argument vectors and static
 * {@link RequestPlan} costs, spawns nothing. The gateway (T4) owns exec.
 *
 * The argv here is lifted verbatim from `git.ts` (`fetchOpenPr`,
 * `unresolvedReviewThreadCount`, `listOpenPrs`) so behaviour — including the
 * review-thread pagination — is preserved, not silently re-tuned.
 *
 * Costs rest on spec §4's quota facts:
 *   - `gh pr list --json` is **GraphQL-backed** (points bucket), ~1 point.
 *   - The REST equivalent is 3–4 `core` calls (list + detail-for-mergeable +
 *     check-runs + status) → declared as a ~4-unit `core` fallback.
 *   - Unresolved review threads are **GraphQL-only** (REST carries no
 *     `resolved` field), so that plan has no fallback and `degraded: "omit"`.
 *   - `GET /rate_limit` is **exempt** — it must never be recorded as spend, so
 *     it declares no {@link RequestPlan} at all.
 */

import type { RequestPlan } from "./router.js";

/** Timeout (ms) for `gh pr` reads, matching git.ts. */
export const PR_TIMEOUT_MS = 5_000;
/** Timeout (ms) for the open-PR list, matching git.ts. */
export const OPEN_PRS_TIMEOUT_MS = 8_000;
/** Timeout (ms) for the exempt rate_limit read. */
export const RATE_LIMIT_TIMEOUT_MS = 5_000;

/** Page size for the review-thread connection (matches git.ts). */
export const REVIEW_THREADS_PAGE_SIZE = 100;
/** Safety cap on the review-thread pagination loop (matches git.ts). */
export const REVIEW_THREADS_MAX_PAGES = 100;

/**
 * `prForBranch` — the hot path. Primary is GraphQL-backed `gh pr list --head`
 * (§4), returning identity + mergeability + check rollup in one ~1-point call.
 * REST fallback costs ~4 `core` calls and cannot supply unresolved threads.
 */
export const PR_FOR_BRANCH_PLAN: RequestPlan = {
  primary: { bucket: "graphql", units: 1 },
  fallback: { bucket: "core", units: 4 },
};

/**
 * `unresolvedThreads` — GraphQL-only (REST exposes no `resolved` field, §4), so
 * no fallback: when the graphql bucket is dry the field is dropped, not
 * re-sourced.
 */
export const UNRESOLVED_THREADS_PLAN: RequestPlan = {
  primary: { bucket: "graphql", units: 1 },
  degraded: "omit",
};

/**
 * `openPrs` — GraphQL-backed `gh pr list` for the picker, with a REST fallback.
 *
 * Unlike {@link PR_FOR_BRANCH_PLAN} the fallback costs only ONE `core` call:
 * listing PRs is a plain REST endpoint, and the picker needs no mergeability or
 * check rollup. So the fallback is nearly as cheap as the primary — there is no
 * reason for a dry graphql bucket to leave the picker empty, which the user
 * would read as "this repo has no open PRs".
 */
export const OPEN_PRS_PLAN: RequestPlan = {
  primary: { bucket: "graphql", units: 1 },
  fallback: { bucket: "core", units: 1 },
};

/**
 * REST fallback argv for the picker's open-PR list. `sort`/`direction` reproduce
 * `gh pr list`'s newest-first ordering, which the picker relies on.
 */
export function openPrsRestArgv(owner: string, repo: string, limit: number): string[] {
  return [
    "api",
    `/repos/${owner}/${repo}/pulls?state=open&per_page=${limit}&sort=created&direction=desc`,
  ];
}

/**
 * Map one REST list-pulls row onto the {@link OpenPr}-shaped fields the picker
 * uses. REST nests the head ref under `head.ref` and names the link `html_url`,
 * where `gh pr list --json` returns `headRefName`/`url`.
 */
export function restOpenPr(raw: unknown): {
  number: number;
  title: string;
  headRefName: string;
  isDraft: boolean;
  url: string;
} | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.number !== "number") return null;
  const head = r.head as { ref?: unknown } | undefined;
  return {
    number: r.number,
    title: typeof r.title === "string" ? r.title : "",
    headRefName: typeof head?.ref === "string" ? head.ref : "",
    isDraft: r.draft === true,
    url: typeof r.html_url === "string" ? r.html_url : "",
  };
}

/**
 * Primary (GraphQL-backed) argv for the open PR on `branch`: identity,
 * mergeability, and the CI check rollup in one call.
 */
export function prForBranchArgv(branch: string): string[] {
  return [
    "pr",
    "list",
    "--head",
    branch,
    "--state",
    "open",
    "--json",
    "number,url,state,title,isDraft,mergeable,mergeStateStatus,statusCheckRollup",
    "--limit",
    "1",
  ];
}

/**
 * REST fallback argv for the open PR on `branch` (spec §4's ~4× path). Lists
 * open PRs whose head is `owner:branch`; {@link prDetailRestArgv} then supplies
 * `mergeable` (absent from the list response) and the two check argv builders
 * supply the CI rollup — four `core` calls for what GraphQL does in one.
 */
export function prForBranchRestArgv(owner: string, repo: string, branch: string): string[] {
  return ["api", `/repos/${owner}/${repo}/pulls?head=${owner}:${branch}&state=open&per_page=1`];
}

/**
 * REST PR detail. Needed only for `mergeable`/`mergeable_state`, which GitHub
 * computes asynchronously and therefore omits from the list response.
 */
export function prDetailRestArgv(owner: string, repo: string, number: string | number): string[] {
  return ["api", `/repos/${owner}/${repo}/pulls/${number}`];
}

/** REST Actions check-runs for a head sha. */
export function checkRunsRestArgv(owner: string, repo: string, ref: string): string[] {
  return ["api", `/repos/${owner}/${repo}/commits/${ref}/check-runs?per_page=100`];
}

/** REST legacy combined status for a head sha (non-Actions CI still uses it). */
export function combinedStatusRestArgv(owner: string, repo: string, ref: string): string[] {
  return ["api", `/repos/${owner}/${repo}/commits/${ref}/status`];
}

/** Read the origin remote URL. Plain `git` — local, and free of GitHub quota. */
export function originRemoteArgv(): string[] {
  return ["remote", "get-url", "origin"];
}

/**
 * Parse `owner/repo` out of a git remote URL. Handles the SSH
 * (`git@github.com:o/r.git`) and HTTPS (`https://github.com/o/r.git`) forms, and
 * returns null for a non-GitHub remote — in which case there is no REST path to
 * fall back to.
 */
export function parseRemoteSlug(url: string): { owner: string; repo: string } | null {
  const m = /github\.com[:/]([^/]+)\/([^/\s]+?)(?:\.git)?\s*$/.exec(url.trim());
  if (!m) return null;
  return { owner: m[1], repo: m[2] };
}

/**
 * Map GitHub's REST `mergeable` (boolean | null) onto the GraphQL vocabulary the
 * DTO already speaks, so the two paths are indistinguishable downstream. REST
 * `null` means "not computed yet", which is exactly GraphQL's `UNKNOWN`.
 */
export function restMergeable(raw: unknown): string | null {
  if (raw === true) return "MERGEABLE";
  if (raw === false) return "CONFLICTING";
  return "UNKNOWN";
}

/**
 * Adapt REST check-runs + combined-status payloads into the *same* shape `gh`
 * emits for `statusCheckRollup`, so `git.ts`'s `normalizeChecks` classifies both
 * paths through one code path. REST uses snake_case keys and lowercase enum
 * values, hence the rename + upper-casing: `bucketForRollupEntry` compares
 * `status` against `"COMPLETED"` verbatim, so a raw lowercase `"completed"` would
 * be misread as still-pending — i.e. a finished build would render as running.
 *
 * `workflowName` is left null: the REST check-run exposes `app.name` (e.g.
 * "GitHub Actions"), which is the *provider*, not the workflow — reporting it as
 * a workflow name would be a small lie for no gain.
 */
export function restChecksToRollup(checkRunsJson: unknown, statusJson: unknown): unknown[] {
  const out: unknown[] = [];
  const runs = (checkRunsJson as { check_runs?: unknown } | null)?.check_runs;
  if (Array.isArray(runs)) {
    for (const raw of runs) {
      const r = raw as { name?: unknown; status?: unknown; conclusion?: unknown; details_url?: unknown };
      out.push({
        name: typeof r.name === "string" ? r.name : "check",
        status: typeof r.status === "string" ? r.status.toUpperCase() : "QUEUED",
        conclusion: typeof r.conclusion === "string" ? r.conclusion.toUpperCase() : undefined,
        detailsUrl: typeof r.details_url === "string" ? r.details_url : null,
        workflowName: null,
      });
    }
  }
  const statuses = (statusJson as { statuses?: unknown } | null)?.statuses;
  if (Array.isArray(statuses)) {
    for (const raw of statuses) {
      const s = raw as { context?: unknown; state?: unknown; target_url?: unknown };
      out.push({
        context: typeof s.context === "string" ? s.context : "status",
        state: typeof s.state === "string" ? s.state.toUpperCase() : "PENDING",
        targetUrl: typeof s.target_url === "string" ? s.target_url : null,
      });
    }
  }
  return out;
}

/** The paged GraphQL query counting unresolved review threads (verbatim from git.ts). */
export const REVIEW_THREADS_QUERY =
  `query($owner:String!,$repo:String!,$number:Int!,$after:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:${REVIEW_THREADS_PAGE_SIZE},after:$after){pageInfo{hasNextPage endCursor}nodes{isResolved}}}}}`;

/** One page of the unresolved-review-threads query; `after` paginates. */
export function unresolvedThreadsArgv(
  owner: string,
  repo: string,
  number: string | number,
  after?: string | null,
): string[] {
  const args = [
    "api",
    "graphql",
    "-f",
    `query=${REVIEW_THREADS_QUERY}`,
    "-F",
    `owner=${owner}`,
    "-F",
    `repo=${repo}`,
    "-F",
    `number=${number}`,
  ];
  if (after) args.push("-f", `after=${after}`);
  return args;
}

/** All open PRs for the repo, newest first (picker flow). */
export function openPrsArgv(limit: number): string[] {
  return ["pr", "list", "--state", "open", "--json", "number,title,headRefName,isDraft,url", "--limit", String(limit)];
}

/** The exempt rate_limit read. Zero cost — never recorded as spend. */
export function rateLimitArgv(): string[] {
  return ["api", "rate_limit"];
}

/** Parse owner/repo/number out of a PR URL, or null when unparseable. */
export function parsePrUrl(prUrl: string): { owner: string; repo: string; number: string } | null {
  const m = /github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/.exec(prUrl);
  if (!m) return null;
  return { owner: m[1], repo: m[2], number: m[3] };
}
