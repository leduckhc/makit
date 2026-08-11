/**
 * map.ts — pure Forgejo REST mapping: URL builders and payload adapters.
 *
 * Pure by design (no I/O, no clock), because every hazard in Forgejo's API that
 * can silently corrupt a PR signal lives here and must be unit-testable:
 *
 *   1. `draft` is a READ-only projection of the title: Forgejo marks a PR draft
 *      when its title starts with a `WORK_IN_PROGRESS_PREFIXES` entry (default
 *      `WIP:,[WIP]`, matched case-insensitively, configurable per instance).
 *      `EditPullRequestOption` has no `draft` field, so "mark ready for review"
 *      is a TITLE REWRITE -- see {@link readyTitle}.
 *   2. There is no `mergeStateStatus`. GitHub's BEHIND/BLOCKED/CLEAN vocabulary
 *      has no Forgejo counterpart, so it is reported as `null` (unknown) rather
 *      than guessed -- a wrong CLEAN would tell the user a blocked PR is ready.
 *   3. The `sort` enum has no created-desc member and there is no `direction`
 *      param, so "the newest PR on this branch" is NOT expressible as a query.
 *      Default order is newest-first in practice but is not part of the contract,
 *      so we page and pick -- see {@link pickLatestPr}.
 *   4. Each combined-status entry keys its state as `status` (GitHub REST uses
 *      `state`) and the enum includes `skipped`, which GitHub's status vocabulary
 *      cannot express -- see {@link forgejoChecks}.
 *   5. Unset timestamps come back as the zero time (`1970-01-01T01:00:00+01:00`)
 *      rather than null -- see {@link isEpochTimestamp}.
 *
 * The `head` filter takes a BARE branch name. GitHub's `owner:branch` form
 * returns an empty list here, which the gateway would map to `none` and erase the
 * pill -- exactly the null-versus-zero defect SPEC-32 §6.5 exists to prevent.
 */

import type { PrCheckBucket, PrCheckDTO } from "../../protocol.js";

/**
 * Page size for a branch->PR lookup.
 *
 * Two forces set this. It must be >1 because hazard 3 means we cannot ask the
 * server for "the newest" and must choose locally. It must be SMALL because the
 * `head` filter is unindexed: measured against codeberg.org (Forgejo 16, ~9.5k
 * PRs), `state=all` with a `head` filter costs ~1.3s at limit=5 but 17-19s at
 * limit=30 -- and returns 504 often enough to matter. This is the hot path,
 * polled per worktree, so a deep page would stall the whole home screen.
 *
 * 5 is enough to absorb the default ordering being merely "roughly newest-first"
 * while staying an order of magnitude inside the read timeout.
 */
export const PR_PAGE_SIZE = 5;

/**
 * Forgejo's default `[repository.pull-request] WORK_IN_PROGRESS_PREFIXES`.
 *
 * A default, not a constant: an instance can redefine this list, so any caller
 * that can read the server's config should pass its real value through rather
 * than assume this one.
 */
export const DEFAULT_WIP_PREFIXES: readonly string[] = ["WIP:", "[WIP]"];

/** Forgejo's API root for an instance base URL (`https://git.example.com`). */
function apiRoot(baseUrl: string): string {
  return `${baseUrl.replace(/\/+$/, "")}/api/v1`;
}

/** Percent-encode one path segment; owner/repo may contain URL-significant bytes. */
function seg(value: string | number): string {
  return encodeURIComponent(String(value));
}

/** `.../pulls` for a repo. */
function pullsPath(baseUrl: string, owner: string, repo: string): string {
  return `${apiRoot(baseUrl)}/repos/${seg(owner)}/${seg(repo)}/pulls`;
}

/**
 * The PRs whose head is `branch`, newest LAST-resort-sorted by us (hazard 3).
 *
 * `state=all` (not `open`) so a merged or closed PR keeps rendering with its own
 * glyph instead of vanishing to the bare-branch icon. Note the absence of
 * `sort`/`direction`: Forgejo offers no created-desc, and sending a bogus value
 * would be a silent no-op that reads as if ordering were guaranteed.
 *
 * `state=all` is also what makes this query expensive -- see {@link PR_PAGE_SIZE}.
 * `state=open` is ~15x faster, but would erase the pill on a merged PR, which is
 * the regression this whole lookup exists to avoid.
 */
export function prForBranchUrl(baseUrl: string, owner: string, repo: string, branch: string): string {
  const u = new URL(pullsPath(baseUrl, owner, repo));
  u.searchParams.set("state", "all");
  // Bare branch name -- NOT `owner:branch`. See the module note.
  u.searchParams.set("head", branch);
  u.searchParams.set("limit", String(PR_PAGE_SIZE));
  return u.toString();
}

/** All open PRs for the repo (the "New worktree from PR" picker). */
export function openPrsUrl(baseUrl: string, owner: string, repo: string, limit: number): string {
  const u = new URL(pullsPath(baseUrl, owner, repo));
  u.searchParams.set("state", "open");
  u.searchParams.set("limit", String(limit));
  return u.toString();
}

/** Combined commit status for a head sha — Forgejo's `statusCheckRollup`. */
export function combinedStatusUrl(baseUrl: string, owner: string, repo: string, ref: string): string {
  return `${apiRoot(baseUrl)}/repos/${seg(owner)}/${seg(repo)}/commits/${seg(ref)}/status`;
}

/** A single PR, by index. Used to re-read a title before rewriting it. */
export function prDetailUrl(baseUrl: string, owner: string, repo: string, index: number): string {
  return `${pullsPath(baseUrl, owner, repo)}/${seg(index)}`;
}

/**
 * Merge the base branch into the PR head — Forgejo's `gh pr update-branch`.
 *
 * `style` is explicit: the instance default (`DEFAULT_UPDATE_STYLE`) is
 * configurable, and silently inheriting it would make the same button rebase on
 * one server and merge on another.
 */
export function updateBranchUrl(
  baseUrl: string,
  owner: string,
  repo: string,
  index: number,
  style: "merge" | "rebase" = "merge",
): string {
  const u = new URL(`${pullsPath(baseUrl, owner, repo)}/${seg(index)}/update`);
  u.searchParams.set("style", style);
  return u.toString();
}

/** Squash-merge a PR. */
export function mergeUrl(baseUrl: string, owner: string, repo: string, index: number): string {
  return `${pullsPath(baseUrl, owner, repo)}/${seg(index)}/merge`;
}

/**
 * The newest PR in a page, by index — hazard 3's mitigation.
 *
 * Highest `number` wins rather than first-returned, so an older CLOSED PR can
 * never take the slot from a newer OPEN one on the same branch and flip the
 * glyph. Rows without a numeric index are skipped rather than coerced.
 */
export function pickLatestPr<T extends { number?: unknown }>(rows: readonly (T | null)[]): T | null {
  let best: T | null = null;
  for (const row of rows) {
    if (row === null || typeof row !== "object") continue;
    if (typeof row.number !== "number" || !Number.isFinite(row.number)) continue;
    if (best === null || row.number > (best.number as number)) best = row;
  }
  return best;
}

/** Identity + mergeability of a Forgejo PR, in the vocabulary the DTO speaks. */
export interface ForgejoPrCore {
  number: number;
  url: string;
  /** OPEN | CLOSED | MERGED */
  state: string;
  title: string;
  isDraft: boolean;
  /** MERGEABLE | CONFLICTING | UNKNOWN */
  mergeable: string | null;
  /** Always null: Forgejo has no equivalent concept (hazard 2). */
  mergeStateStatus: null;
  baseRefName: string | null;
  /** Head commit, needed to fetch the check rollup. Null when unreported. */
  headSha: string | null;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

/**
 * Map one Forgejo PR row onto {@link ForgejoPrCore}.
 *
 * `mergeable` is taken verbatim from the API rather than being ANDed with the
 * open state: conflating the two is a presentation choice, and the pill already
 * derives its own tint from `state`. Absent means "not computed yet" — Forgejo
 * resolves conflicts asynchronously — which is `UNKNOWN`, not "conflicting".
 */
export function mapForgejoPr(raw: unknown): ForgejoPrCore | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.number !== "number" || !Number.isFinite(r.number)) return null;

  const merged = r.merged === true;
  const rawState = typeof r.state === "string" ? r.state.toUpperCase() : "";
  // REST has no distinct "merged" state; the flag disambiguates it from a plain
  // close, which is what keeps a merged PR from rendering with the closed glyph.
  const state = merged ? "MERGED" : rawState === "OPEN" ? "OPEN" : "CLOSED";

  let mergeable: string;
  if (r.mergeable === true) mergeable = "MERGEABLE";
  else if (r.mergeable === false) mergeable = "CONFLICTING";
  else mergeable = "UNKNOWN";

  const base = r.base as { ref?: unknown } | undefined;
  const head = r.head as { ref?: unknown; sha?: unknown } | undefined;

  return {
    number: r.number,
    // `html_url` is the human page; `url` is the API resource. The UI links out.
    url: str(r.html_url) ?? "",
    state,
    title: typeof r.title === "string" ? r.title : "",
    isDraft: r.draft === true,
    mergeable,
    mergeStateStatus: null,
    baseRefName: str(base?.ref),
    headSha: str(head?.sha),
  };
}

/**
 * The title a PR must be given to leave draft — hazard 1's mitigation.
 *
 * Returns null when no configured prefix matches, so a caller can never blindly
 * rewrite a title it did not recognise as a draft marker. Matching is anchored
 * and case-insensitive (mirroring Forgejo), so `WIPE the cache` is untouched
 * while `wip: x` is not missed. Also returns null when stripping would leave an
 * empty title, which Forgejo would reject anyway.
 */
export function readyTitle(title: string, prefixes: readonly string[] = DEFAULT_WIP_PREFIXES): string | null {
  const lower = title.toLowerCase();
  for (const prefix of prefixes) {
    if (prefix.length === 0) continue;
    if (!lower.startsWith(prefix.toLowerCase())) continue;
    const stripped = title.slice(prefix.length).trim();
    return stripped.length > 0 ? stripped : null;
  }
  return null;
}

/**
 * Map Forgejo's `CommitStatusState` onto a {@link PrCheckBucket}.
 *
 * Forgejo's enum is `pending | success | error | failure | warning | skipped`.
 * Two notes on the edges:
 *   - `skipped` exists here but not in GitHub's status vocabulary, which is why
 *     these entries are classified locally instead of being reshaped into
 *     GitHub's `statusCheckRollup` form and run through `normalizeChecks`.
 *   - An unrecognised value buckets as `pending`, never `pass`: a check we cannot
 *     classify must not be reported as green.
 */
function bucketForForgejoStatus(status: string): PrCheckBucket {
  switch (status.toLowerCase()) {
    case "success":
      return "pass";
    case "failure":
    case "error":
      return "fail";
    case "pending":
      return "pending";
    case "skipped":
    // `warning` is Forgejo's advisory state — the closest honest bucket is the
    // one already used for GitHub's NEUTRAL: present, but not a pass or a fail.
    case "warning":
      return "skipping";
    default:
      return "pending";
  }
}

/**
 * Adapt a Forgejo combined-status payload into flat {@link PrCheckDTO}s.
 *
 * `workflowName` is left null: Forgejo's commit status carries only a `context`
 * string, and splitting it on `/` to invent a workflow name would be a guess
 * (`testing / test-unit` and `a/b` are indistinguishable).
 */
export function forgejoChecks(combined: unknown): PrCheckDTO[] {
  if (typeof combined !== "object" || combined === null) return [];
  const statuses = (combined as { statuses?: unknown }).statuses;
  if (!Array.isArray(statuses)) return [];
  const out: PrCheckDTO[] = [];
  for (const raw of statuses) {
    if (typeof raw !== "object" || raw === null) continue;
    const s = raw as Record<string, unknown>;
    out.push({
      // Forgejo keys the state as `status`; GitHub REST uses `state`.
      name: str(s.context) ?? "check",
      bucket: bucketForForgejoStatus(typeof s.status === "string" ? s.status : ""),
      workflowName: null,
      detailsUrl: str(s.target_url),
    });
  }
  return out;
}

/**
 * True when a Forgejo timestamp is the zero-time sentinel (hazard 5).
 *
 * Forgejo serialises an unset time as the zero `time.Time` in the server's local
 * zone (`1970-01-01T01:00:00+01:00`), not as null. Fed into a duration that
 * renders as ~56 years, so callers must treat these as "absent" rather than
 * "epoch". `<= 0` rather than `=== 0` so a negative offset zone is caught too.
 */
export function isEpochTimestamp(value: unknown): boolean {
  if (typeof value !== "string" || value.length === 0) return false;
  const t = Date.parse(value);
  return Number.isFinite(t) && t <= 0;
}

/** Host + slug of a git remote, for any self-hosted instance. */
export interface ForgejoRemote {
  /** Host including a non-default port, e.g. `git.example.com:2222`. */
  host: string;
  owner: string;
  repo: string;
}

/**
 * Parse `owner/repo` and the host out of a git remote URL.
 *
 * Unlike the GitHub parser this cannot anchor on a known hostname — a Forgejo
 * instance is self-hosted, so the host is data. Both git forms are accepted: the
 * scp-like `git@host:owner/repo.git` and any explicit scheme. Exactly two path
 * segments are required, so a group URL or a bare owner returns null rather than
 * a half-parsed slug that would 404 on every call.
 */
export function parseForgejoRemote(url: string): ForgejoRemote | null {
  const trimmed = url.trim();
  if (trimmed.length === 0) return null;

  let host: string;
  let path: string;

  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) {
    let parsed: URL;
    try {
      parsed = new URL(trimmed);
    } catch {
      return null;
    }
    // `host` keeps an explicit port; userinfo (`git@`) is dropped by the parser.
    host = parsed.host;
    path = parsed.pathname;
  } else {
    // scp-like syntax: [user@]host:path — the colon separates host from path,
    // so a port cannot be expressed and any digits after it are part of the path.
    const m = /^(?:[^@/]+@)?([^:/]+):(.+)$/.exec(trimmed);
    if (!m) return null;
    host = m[1];
    path = m[2];
  }

  if (host.length === 0) return null;
  const parts = path
    .replace(/\.git$/i, "")
    .split("/")
    .filter((p) => p.length > 0);
  if (parts.length !== 2) return null;
  return { host, owner: parts[0], repo: parts[1] };
}
