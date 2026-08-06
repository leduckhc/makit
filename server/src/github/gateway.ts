/**
 * gateway.ts — the single door for every GitHub read (SPEC-32 §5, §6.4).
 *
 * All five call sites (repo_service, pr_watcher, worktree cmds) route through
 * here so cost, cache, dedupe, concurrency, and spend accounting live in one
 * place. It composes the three pure Phase-1 units:
 *   - {@link BudgetTracker} — measures quota + attributes spend (clock-injected)
 *   - `route` (router.ts) — cost-aware bucket choice / omit decision
 *   - `decide`/`allow` (policy.ts) — degradation ladder + reserve floor
 *
 * The gateway is the one side-effecting piece, and even its side effects are
 * injected: `exec` shells out to `gh`, `now` is the clock (shared with the
 * tracker so spend and snapshots agree), and the timer pair drives the free 60s
 * rate_limit refresh. Tests supply fakes and spawn **zero** subprocesses.
 *
 * The three-way {@link PrLookup} is the crux of the missing-pill bug (§1
 * defect 2, §6.5): a throttled or failed lookup must be distinguishable from a
 * genuinely-absent PR, so it can never masquerade as a deletion and erase a
 * pill. Only an exit-0 empty list yields `none`.
 */

import type { BudgetSnapshot } from "./budget.js";
import { BudgetTracker } from "./budget.js";
import { route, type RequestPlan, type RouteChoice } from "./router.js";
import { allow, decide } from "./policy.js";
import { normalizeChecks, rollupChecks } from "../git.js";
import type { OpenPr, PullRequestInfo } from "../git.js";
import {
  OPEN_PRS_PLAN,
  OPEN_PRS_TIMEOUT_MS,
  PR_FOR_BRANCH_PLAN,
  PR_TIMEOUT_MS,
  RATE_LIMIT_TIMEOUT_MS,
  REVIEW_THREADS_MAX_PAGES,
  UNRESOLVED_THREADS_PLAN,
  checkRunsRestArgv,
  combinedStatusRestArgv,
  openPrsArgv,
  prMutationArgv,
  type PrMutation,
  openPrsRestArgv,
  originRemoteArgv,
  parsePrUrl,
  parseRemoteSlug,
  prDetailRestArgv,
  prForBranchArgv,
  prForBranchRestArgv,
  rateLimitArgv,
  restChecksToRollup,
  restOpenPr,
  restMergeable,
  unresolvedThreadsArgv,
} from "./queries.js";

/** Three-way PR lookup result — a failed lookup is never `none` (§6.5). */
export type PrLookup =
  | { kind: "pr"; pr: PullRequestInfo }
  | { kind: "none" }
  | { kind: "unknown"; reason: "throttled" | "error" };

/** Result of a `gh` invocation. Matches git.ts's private `run` — never rejects. */
export interface ExecResult {
  code: number;
  stdout: string;
  stderr: string;
}

/** `exec` shape: identical to git.ts's `run`, so `run` can be passed directly. */
export type Exec = (cmd: string, args: string[], cwd?: string, timeoutMs?: number) => Promise<ExecResult>;

/** An injectable timer handle (mirrors pr_watcher's seam). */
export interface TimerHandle {
  unref?: () => void;
}

/** Exec/cache counters — spec §10 success criterion 1 (measure the ≥80% cut). */
export interface GatewayStats {
  /**
   * `gh` calls that SPENT quota. Excludes the exempt `/rate_limit` read (see
   * {@link exemptExecs}) and the local `git remote` lookup, so this is the number
   * the >=80% call-reduction claim is measured against without arithmetic.
   */
  execs: number;
  /** Quota-exempt `gh api rate_limit` reads. Free, but still subprocesses. */
  exemptExecs: number;
  /** Reads served from cache without an exec. */
  cacheHits: number;
}

export interface GithubGateway {
  prForBranch(repoPath: string, branch: string, opts?: { interactive?: boolean }): Promise<PrLookup>;
  /**
   * All open PRs for a repo (the "New worktree from PR" picker).
   *
   * Pass `interactive: true` for a user-initiated call: the picker is a click,
   * not a poller, so it must draw on the reserve rather than silently return an
   * empty list — which the user would read as "this repo has no open PRs"
   * (spec §6.3).
   */
  openPrs(repoPath: string, limit: number, opts?: { interactive?: boolean }): Promise<OpenPr[]>;
  /**
   * Run a state-changing `gh pr` verb on the user's behalf (`ready` to take a PR
   * out of draft, `update-branch` to merge the base into it).
   *
   * Always interactive — it is a button press, never a poller — so it spends from
   * the reserve rather than being shed. Invalidates the cached lookup for
   * [branch] on success, otherwise the UI would keep reporting the state the
   * mutation just changed until the TTL expired.
   */
  mutatePr(
    repoPath: string,
    branch: string,
    number: number,
    verb: PrMutation,
  ): Promise<{ ok: boolean; error?: string }>;
  budget(): BudgetSnapshot;
  /** 60-slot per-minute `{mine, others}` ring for the sparkline (spec §6.6). */
  history(): Array<{ mine: number; others: number }>;
  refresh(): Promise<BudgetSnapshot>;
  setPaused(paused: boolean): void;
  onBudgetChange(fn: (s: BudgetSnapshot) => void): () => void;
  close(): void;
  /** Exec vs. cache-hit counters (T6 surfaces this for the ≥80% claim). */
  stats(): GatewayStats;
}

export interface GatewayDeps {
  /** Shells out to `gh`; must never reject (git.ts's `run` satisfies this). */
  exec: Exec;
  /** Clock — the SAME one handed to the tracker, so spend and snapshots agree. */
  now?: () => number;
  /** Injectable timer (tests); defaults to global setTimeout. */
  setTimer?: (fn: () => void, ms: number) => TimerHandle;
  /** Injectable clearer (tests); defaults to global clearTimeout. */
  clearTimer?: (handle: unknown) => void;
}

/** Cache TTLs per kind (spec §6.4). */
const TTL_PR_MS = 20_000;
const TTL_UNRESOLVED_MS = 5 * 60_000;
const TTL_OPEN_PRS_MS = 60_000;
/** Free rate_limit refresh cadence (spec §6.4). */
const REFRESH_INTERVAL_MS = 60_000;

/** stderr language that means "throttled", split so secondary limits are distinct. */
const SECONDARY_LIMIT_RE = /secondary rate limit/i;
const PRIMARY_LIMIT_RE = /(api rate limit exceeded|\b403\b|rate limit exceeded)/i;
/** A conservative default backoff for a secondary (burst) limit. */
const SECONDARY_RETRY_MS = 60_000;

type FailureKind = "throttled" | "secondary" | "error";

/** Classify a non-zero `gh` result: throttle vs. secondary-limit vs. generic. */
function classifyFailure(stderr: string): FailureKind {
  if (SECONDARY_LIMIT_RE.test(stderr)) return "secondary";
  if (PRIMARY_LIMIT_RE.test(stderr)) return "throttled";
  return "error";
}

interface CacheEntry {
  value: unknown;
  expiresAt: number;
}

/** A synthetic success with no body — used when a step is skipped (no head sha). */
function ok0(): ExecResult {
  return { code: 0, stdout: "", stderr: "" };
}

/**
 * A counting semaphore with a *dynamic* limit — the policy's concurrency drops
 * from 6 to 2 under a secondary limit, so the cap is read per-acquire rather
 * than fixed at construction. No dependency added (spec §6.4).
 */
export class ConcurrencyGate {
  private active = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(private readonly limit: () => number) {}

  async acquire(): Promise<void> {
    while (this.active >= Math.max(1, this.limit())) {
      await new Promise<void>((resolve) => this.waiters.push(resolve));
    }
    this.active += 1;
  }

  release(): void {
    this.active -= 1;
    // Wake every waiter the *current* limit can now admit, not just one. The
    // limit grows again when a secondary limit clears (2 -> 6); waking a single
    // waiter per release would leave the extra headroom unused until the next
    // release, keeping throughput throttled after the throttle is gone.
    const room = Math.max(1, this.limit()) - this.active;
    for (let i = 0; i < room; i++) {
      const next = this.waiters.shift();
      if (!next) break;
      next();
    }
  }
}

export function createGithubGateway(deps: GatewayDeps): GithubGateway {
  const now = deps.now ?? (() => Date.now());
  const setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));

  const tracker = new BudgetTracker(now);
  const cache = new Map<string, CacheEntry>();
  const inflight = new Map<string, Promise<unknown>>();
  const previousChoice = new Map<string, RouteChoice>();
  /** owner/repo per repo path. A remote effectively never changes; cache forever. */
  const slugCache = new Map<string, { owner: string; repo: string } | null>();
  const listeners = new Set<(s: BudgetSnapshot) => void>();
  const stats: GatewayStats = { execs: 0, exemptExecs: 0, cacheHits: 0 };

  let paused = false;
  let closed = false;
  let refreshTimer: TimerHandle | null = null;
  /** Last broadcast (level, throttles) signature — gate onBudgetChange on change. */
  let lastSignature: string | null = null;

  const gate = new ConcurrencyGate(() => decide(tracker.snapshot(), { paused }).concurrency);

  /**
   * The tracker snapshot plus throttles only the gateway knows about — currently
   * the active routing path, which lives in the router's memory, not the
   * tracker's.
   *
   * Both {@link GithubGateway.budget} and {@link emitIfChanged} must go through
   * here: composing only in the getter meant the routing throttle never entered
   * the change signature, so flipping to REST fired no event and subscribers kept
   * a stale throttle list until an unrelated level change.
   */
  function composedSnapshot(): BudgetSnapshot {
    const snapshot = tracker.snapshot();
    if (previousChoice.get("prForBranch")?.path !== "fallback") return snapshot;
    return {
      ...snapshot,
      throttles: [...snapshot.throttles, "PR status via REST (graphql low)"],
    };
  }

  function signatureOf(s: BudgetSnapshot): string {
    return JSON.stringify({ level: s.level, throttles: s.throttles });
  }

  function emitIfChanged(): void {
    const snap = composedSnapshot();
    const sig = signatureOf(snap);
    if (sig === lastSignature) return;
    lastSignature = sig;
    for (const fn of listeners) fn(snap);
  }

  function cacheGet<T>(key: string): T | undefined {
    const entry = cache.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= now()) {
      cache.delete(key);
      return undefined;
    }
    return entry.value as T;
  }

  function cacheSet(key: string, value: unknown, ttlMs: number): void {
    cache.set(key, { value, expiresAt: now() + ttlMs });
  }

  /**
   * Bumped whenever a mutation invalidates a key. A lookup that was already in
   * flight when that happened describes the *pre*-mutation state, so it must not
   * be written to the cache on arrival — otherwise the invalidation is undone and
   * the UI keeps reporting the state the mutation just changed (SPEC-38 §7).
   */
  const generation = new Map<string, number>();
  const generationOf = (key: string) => generation.get(key) ?? 0;
  function invalidate(key: string): void {
    cache.delete(key);
    generation.set(key, generationOf(key) + 1);
  }

  /** One in-flight promise per key; cleared in `finally` so dedupe is per-burst. */
  function dedupe<T>(key: string, run: () => Promise<T>): Promise<T> {
    const existing = inflight.get(key);
    if (existing) return existing as Promise<T>;
    const promise = run().finally(() => inflight.delete(key));
    inflight.set(key, promise);
    return promise;
  }

  /**
   * Ask the router which path to take. Does NOT persist the answer: a fallback
   * can still be abandoned (a repo with no GitHub remote has no REST path), and
   * recording a route we did not take made `budget()` advertise REST routing that
   * never happened and seeded hysteresis with an unusable path. Callers commit
   * via {@link commitRoute} once the path is settled.
   */
  function routeFor(planKey: string, plan: RequestPlan): RouteChoice {
    return route(plan, tracker.snapshot(), previousChoice.get(planKey), now());
  }

  /**
   * Record the path actually taken, so hysteresis holds across ticks.
   *
   * A change here alters the composed snapshot (the routing throttle), so it must
   * emit: otherwise flipping to REST changes what `budget()` reports while no
   * subscriber is ever told, and the footer keeps showing the old routing state.
   */
  function commitRoute(planKey: string, choice: RouteChoice): void {
    const previous = previousChoice.get(planKey);
    previousChoice.set(planKey, choice);
    if (previous?.path !== choice.path) emitIfChanged();
  }

  /**
   * Execute a costed `gh` call: spend is recorded on `bucket` **before** the
   * exec so a burst can never outrun the accounting (§6.4). Returns the raw
   * result; callers classify success/failure.
   */
  async function costedExec(
    bucket: RequestPlan["primary"]["bucket"],
    units: number,
    args: string[],
    cwd: string,
    timeoutMs: number,
  ): Promise<ExecResult> {
    tracker.recordSpend(bucket, units);
    await gate.acquire();
    try {
      stats.execs += 1;
      return await deps.exec("gh", args, cwd, timeoutMs);
    } finally {
      gate.release();
    }
  }

  /** React to a `gh` failure: refresh on any throttle, back off on secondary. */
  async function handleFailure(kind: FailureKind): Promise<void> {
    if (kind === "secondary") {
      tracker.setRetryAfter(SECONDARY_RETRY_MS);
      emitIfChanged();
    }
    if (kind === "throttled" || kind === "secondary") {
      try {
        await refresh();
      } catch {
        /* rate_limit read is best-effort; ignore */
      }
    }
  }

  async function fetchUnresolvedCount(
    repoPath: string,
    prUrl: string,
    interactive: boolean,
  ): Promise<number | "throttled" | "omit"> {
    const parsed = parsePrUrl(prUrl);
    // Fails for any non-github.com host (GitHub Enterprise). We never queried,
    // so the count is unmeasured -- returning 0 would report "no unresolved
    // comments" as fact (the null-versus-zero hazard, §6.5).
    if (!parsed) return "omit";
    const key = `threads:${repoPath}:${prUrl}`;
    if (!interactive) {
      const hit = cacheGet<number>(key);
      if (hit !== undefined) {
        stats.cacheHits += 1;
        return hit;
      }
    }
    return dedupe(key, async () => {
      const budget = tracker.snapshot();
      const policy = decide(budget, { paused });
      if (!allow(budget, policy, interactive)) return "throttled";
      const choice = routeFor("unresolvedThreads", UNRESOLVED_THREADS_PLAN);
      commitRoute("unresolvedThreads", choice);
      if (choice.path === "omit") return "omit"; // graphql dry: shed the field (§6.2)

      let count = 0;
      let after: string | null = null;
      let recorded = false;
      let complete = false;
      for (let page = 0; page < REVIEW_THREADS_MAX_PAGES; page++) {
        // One unit for the whole operation (spec's coarse point cost), recorded
        // before the first page so accounting leads the exec.
        const units = recorded ? 0 : UNRESOLVED_THREADS_PLAN.primary.units;
        recorded = true;
        const r = await costedExec(
          "graphql",
          units,
          unresolvedThreadsArgv(parsed.owner, parsed.repo, parsed.number, after),
          repoPath,
          PR_TIMEOUT_MS,
        );
        if (r.code !== 0) {
          const kind = classifyFailure(r.stderr);
          if (kind !== "error") await handleFailure(kind);
          // A mid-pagination failure leaves a PARTIAL tally, which is not a
          // fact: reporting it would show the pill a confident wrong number
          // (§6.5). Signal "unmeasured" so the count is hidden instead.
          return "throttled";
        }
        try {
          const data = JSON.parse(r.stdout) as {
            data?: {
              repository?: {
                pullRequest?: {
                  reviewThreads?: {
                    pageInfo?: { hasNextPage?: boolean; endCursor?: string | null };
                    nodes?: Array<{ isResolved?: boolean }>;
                  };
                };
              };
            };
          };
          const threads = data.data?.repository?.pullRequest?.reviewThreads;
          const nodes = threads?.nodes ?? [];
          count += nodes.filter((n) => n && n.isResolved === false).length;
          if (!threads?.pageInfo?.hasNextPage) {
            complete = true;
            break;
          }
          after = threads.pageInfo.endCursor ?? null;
          if (!after) {
            complete = true;
            break;
          }
        } catch {
          // An unparseable page means the tally is incomplete — unmeasured, not
          // "however many we happened to count" (§6.5).
          return "throttled";
        }
      }
      // Falling out of the loop with pages still pending leaves a PARTIAL tally.
      // The mid-pagination failure path above already refuses to report that as
      // fact; this exit must agree, or a PR with >100 pages of threads would show
      // a confident wrong number.
      if (!complete) return "throttled";
      cacheSet(key, count, TTL_UNRESOLVED_MS);
      return count;
    });
  }

  /**
   * Resolve `owner/repo` for the REST fallback from the **local** git remote.
   * Deliberately not `gh repo view`, which would spend the very quota the
   * fallback exists to conserve. Cached per repo path and excluded from
   * {@link GatewayStats.execs}, which counts quota-spending `gh` calls only.
   * `null` means "no GitHub remote" — there is no REST path for this repo.
   */
  async function resolveSlug(repoPath: string): Promise<{ owner: string; repo: string } | null> {
    const cached = slugCache.get(repoPath);
    if (cached !== undefined) return cached;
    const r = await deps.exec("git", originRemoteArgv(), repoPath, PR_TIMEOUT_MS);
    const slug = r.code === 0 ? parseRemoteSlug(r.stdout) : null;
    slugCache.set(repoPath, slug);
    return slug;
  }

  /**
   * REST fallback for the hot path: four `core` calls (list → detail → check-runs
   * → combined status) reproducing what one GraphQL query returns, minus
   * unresolved review threads, which REST cannot express at all (spec §4).
   *
   * A failure at any step after a successful list returns `unknown`, never
   * `none`: the PR demonstrably exists, so claiming otherwise would erase a live
   * pill — the exact bug this spec exists to fix.
   */
  async function fetchPrViaRest(
    repoPath: string,
    branch: string,
    slug: { owner: string; repo: string },
  ): Promise<PrLookup> {
    const { owner, repo } = slug;
    // Whole-operation cost recorded once, up front, so a burst cannot outrun it.
    const list = await costedExec(
      "core",
      PR_FOR_BRANCH_PLAN.fallback?.units ?? 4,
      prForBranchRestArgv(owner, repo, branch),
      repoPath,
      PR_TIMEOUT_MS,
    );
    if (list.code !== 0) {
      const kind = classifyFailure(list.stderr);
      await handleFailure(kind);
      return { kind: "unknown", reason: kind === "error" ? "error" : "throttled" };
    }
    let rows: Array<Record<string, unknown>>;
    try {
      rows = JSON.parse(list.stdout.trim() || "[]") as Array<Record<string, unknown>>;
    } catch {
      return { kind: "unknown", reason: "error" };
    }
    if (!Array.isArray(rows) || rows.length === 0) return { kind: "none" };

    const row = rows[0];
    const number = typeof row.number === "number" ? row.number : 0;
    const rawState = typeof row.state === "string" ? row.state.toUpperCase() : "OPEN";
    const head = row.head as { sha?: unknown } | undefined;
    const sha = typeof head?.sha === "string" ? head.sha : "";

    const [detail, checkRuns, status] = await Promise.all([
      costedExec("core", 0, prDetailRestArgv(owner, repo, number), repoPath, PR_TIMEOUT_MS),
      sha
        ? costedExec("core", 0, checkRunsRestArgv(owner, repo, sha), repoPath, PR_TIMEOUT_MS)
        : Promise.resolve(ok0()),
      sha
        ? costedExec("core", 0, combinedStatusRestArgv(owner, repo, sha), repoPath, PR_TIMEOUT_MS)
        : Promise.resolve(ok0()),
    ]);
    for (const step of [detail, checkRuns, status]) {
      if (step.code !== 0) {
        const kind = classifyFailure(step.stderr);
        await handleFailure(kind);
        return { kind: "unknown", reason: kind === "error" ? "error" : "throttled" };
      }
    }

    let mergeable: string | null = "UNKNOWN";
    let mergeStateStatus: string | null = null;
    let merged = false;
    try {
      const d = JSON.parse(detail.stdout) as {
        mergeable?: unknown;
        mergeable_state?: unknown;
        merged?: unknown;
      };
      mergeable = restMergeable(d.mergeable);
      mergeStateStatus =
        typeof d.mergeable_state === "string" ? d.mergeable_state.toUpperCase() : null;
      // REST has no distinct "merged" state — a merged PR lists as `closed`. The
      // detail's `merged` boolean is the only way to tell it apart, so the UI
      // can draw the merged (purple) glyph rather than the closed (red) one.
      merged = d.merged === true;
    } catch {
      return { kind: "unknown", reason: "error" };
    }

    let checks: PullRequestInfo["checks"] = [];
    try {
      checks = normalizeChecks(
        restChecksToRollup(
          checkRuns.stdout ? JSON.parse(checkRuns.stdout) : null,
          status.stdout ? JSON.parse(status.stdout) : null,
        ),
      );
    } catch {
      return { kind: "unknown", reason: "error" };
    }

    const pr: PullRequestInfo = {
      number,
      url: typeof row.html_url === "string" ? row.html_url : "",
      // REST reports lowercase state and no distinct "merged"; the DTO speaks
      // GraphQL's uppercase MERGED/CLOSED/OPEN, so map a merged-flagged PR to
      // MERGED and otherwise upper-case the raw open/closed state.
      state: merged ? "MERGED" : rawState,
      title: typeof row.title === "string" ? row.title : "",
      isDraft: row.draft === true,
      mergeable,
      mergeStateStatus,
      baseRefName:
        typeof (row as { base?: { ref?: unknown } }).base?.ref === "string"
          ? ((row as { base: { ref: string } }).base.ref)
          : null,
      checks,
      checkRollup: rollupChecks(checks),
      // REST cannot supply this (no `resolved` field): report 0 but flag it as
      // unmeasured so the UI never claims "0 unresolved" as fact (§6.5).
      unresolvedComments: 0,
      unresolvedUnknown: true,
    };
    return { kind: "pr", pr };
  }

  async function doPrForBranch(repoPath: string, branch: string, interactive: boolean): Promise<PrLookup> {
    const budget = tracker.snapshot();
    const policy = decide(budget, { paused });
    if (!allow(budget, policy, interactive)) {
      // Background work below the reserve: we cannot tell, so retain the pill.
      return { kind: "unknown", reason: "throttled" };
    }
    const choice = routeFor("prForBranch", PR_FOR_BRANCH_PLAN);
    if (choice.path === "fallback") {
      // The graphql bucket is the worse buy right now (spec §6.2). Take the REST
      // path — but only if we can name the repo without spending quota; with no
      // GitHub remote there is no REST path, so try the primary anyway rather
      // than report a failure we never attempted.
      const slug = await resolveSlug(repoPath);
      if (slug) {
        commitRoute("prForBranch", choice);
        return fetchPrViaRest(repoPath, branch, slug);
      }
    }
    // Either the router chose GraphQL, or the REST path was unavailable and we
    // fell back to it — record what we are actually about to do.
    commitRoute("prForBranch", { bucket: PR_FOR_BRANCH_PLAN.primary.bucket, path: "primary" });
    const r = await costedExec(
      PR_FOR_BRANCH_PLAN.primary.bucket,
      PR_FOR_BRANCH_PLAN.primary.units,
      prForBranchArgv(branch),
      repoPath,
      PR_TIMEOUT_MS,
    );
    if (r.code !== 0) {
      const kind = classifyFailure(r.stderr);
      await handleFailure(kind);
      return { kind: "unknown", reason: kind === "error" ? "error" : "throttled" };
    }

    let parsed: Array<Record<string, unknown>>;
    try {
      parsed = JSON.parse(r.stdout.trim() || "[]") as Array<Record<string, unknown>>;
    } catch {
      // A successful exit with unparseable output is a lookup failure, NOT "none".
      return { kind: "unknown", reason: "error" };
    }
    if (!Array.isArray(parsed) || parsed.length === 0) return { kind: "none" };

    const p = parsed[0];
    const checks = normalizeChecks(p.statusCheckRollup);
    const url = typeof p.url === "string" ? p.url : "";
    let unresolvedComments = 0;
    let unresolvedUnknown = false;
    if (policy.includeUnresolved && url) {
      const threads = await fetchUnresolvedCount(repoPath, url, interactive);
      // A number is a measured count; "throttled"/"omit" mean we never looked, so
      // the 0 fallback is a placeholder, not a fact — flag it (§6.5).
      if (typeof threads === "number") unresolvedComments = threads;
      else unresolvedUnknown = true;
    } else {
      // Shed by the ladder (includeUnresolved=false) or no PR url to query: the
      // count was not fetched, so 0 is not a measured fact.
      unresolvedUnknown = true;
    }
    const pr: PullRequestInfo = {
      number: typeof p.number === "number" ? p.number : 0,
      url,
      state: typeof p.state === "string" ? p.state : "OPEN",
      title: typeof p.title === "string" ? p.title : "",
      isDraft: p.isDraft === true,
      mergeable: typeof p.mergeable === "string" ? p.mergeable : null,
      mergeStateStatus: typeof p.mergeStateStatus === "string" ? p.mergeStateStatus : null,
      baseRefName: typeof p.baseRefName === "string" ? p.baseRefName : null,
      checks,
      checkRollup: rollupChecks(checks),
      unresolvedComments,
      unresolvedUnknown,
    };
    return { kind: "pr", pr };
  }

  async function refresh(): Promise<BudgetSnapshot> {
    // `GET /rate_limit` is exempt (spec §4): NO recordSpend, callable freely.
    await gate.acquire();
    let r: ExecResult;
    try {
      stats.exemptExecs += 1;
      r = await deps.exec("gh", rateLimitArgv(), undefined, RATE_LIMIT_TIMEOUT_MS);
    } finally {
      gate.release();
    }
    if (r.code === 0) {
      try {
        tracker.applyRateLimit(JSON.parse(r.stdout));
      } catch {
        /* malformed rate_limit output: leave the tracker as-is */
      }
    }
    emitIfChanged();
    return tracker.snapshot();
  }

  function scheduleRefresh(): void {
    if (closed) return;
    const handle = setTimer(() => {
      void refresh()
        .catch(() => undefined)
        .finally(() => scheduleRefresh());
    }, REFRESH_INTERVAL_MS);
    handle.unref?.();
    refreshTimer = handle;
  }

  scheduleRefresh();

  return {
    prForBranch(repoPath, branch, opts) {
      const interactive = opts?.interactive ?? false;
      const key = `pr:${repoPath}:${branch}`;
      if (!interactive) {
        const hit = cacheGet<PrLookup>(key);
        if (hit) {
          stats.cacheHits += 1;
          return Promise.resolve(hit);
        }
      }
      // The dedupe key includes `interactive`: a background lookup below the
      // reserve resolves to `unknown` (shed), and an interactive caller joining
      // that promise would inherit the shed answer instead of drawing on the
      // reserve — silently undoing §6.3's guarantee.
      return dedupe(`${key}:${interactive}`, async () => {
        const started = generationOf(key);
        const result = await doPrForBranch(repoPath, branch, interactive);
        // Only cache definite answers; a throttled/errored lookup must retry. And
        // only if no mutation invalidated this key while we were in flight — see
        // `generation`.
        if (
          (result.kind === "pr" || result.kind === "none") &&
          generationOf(key) === started
        ) {
          cacheSet(key, result, TTL_PR_MS);
        }
        return result;
      });
    },

    async mutatePr(repoPath, branch, number, verb) {
      // Costed on `core`: both verbs are REST mutations under the hood. Spend is
      // recorded even on failure (costedExec records before the exec), which is
      // the honest accounting — GitHub charged us either way.
      const r = await costedExec(
        "core",
        1,
        prMutationArgv(verb, number),
        repoPath,
        PR_TIMEOUT_MS,
      );
      if (r.code !== 0) {
        const kind = classifyFailure(r.stderr);
        if (kind !== "error") await handleFailure(kind);
        return { ok: false, error: r.stderr.trim() || `gh pr ${verb} failed` };
      }
      // The PR's state just changed, so every cached view of it is a lie. Drop
      // them and bump their generations, so a lookup already in flight cannot
      // re-seed the pre-mutation answer when it lands.
      //
      // `openPrs` matters as much as the single lookup: it backs the "New worktree
      // from PR" picker, where a squash-merged PR that is still listed leads to a
      // checkout that fails, and a marked-ready PR still reads as a draft. Its key
      // carries a `limit`, so every limit for this repo goes.
      invalidate(`pr:${repoPath}:${branch}`);
      for (const key of [...cache.keys(), ...generation.keys()]) {
        if (key.startsWith(`openPrs:${repoPath}:`)) invalidate(key);
      }
      return { ok: true };
    },

    async openPrs(repoPath, limit, opts) {
      const interactive = opts?.interactive ?? false;
      const key = `openPrs:${repoPath}:${limit}`;
      if (!interactive) {
        const hit = cacheGet<OpenPr[]>(key);
        if (hit) {
          stats.cacheHits += 1;
          return hit;
        }
      }
      // Keyed by `interactive` for the same reason as prForBranch: the picker
      // must not inherit a background call's reserve-shed empty list.
      return dedupe(`${key}:${interactive}`, async () => {
        const started = generationOf(key);
        const budget = tracker.snapshot();
        const policy = decide(budget, { paused });
        if (!allow(budget, policy, interactive)) return [];
        const choice = routeFor("openPrs", OPEN_PRS_PLAN);
        // Listing PRs is a plain REST endpoint, so a dry graphql bucket has no
        // business emptying the picker (which reads as "no open PRs").
        const slug =
          choice.path === "fallback" ? await resolveSlug(repoPath) : null;
        const useRest = slug !== null;
        commitRoute("openPrs", {
          bucket: useRest ? "core" : OPEN_PRS_PLAN.primary.bucket,
          path: useRest ? "fallback" : "primary",
        });
        const r = await costedExec(
          useRest ? "core" : OPEN_PRS_PLAN.primary.bucket,
          useRest
            ? (OPEN_PRS_PLAN.fallback?.units ?? 1)
            : OPEN_PRS_PLAN.primary.units,
          useRest ? openPrsRestArgv(slug.owner, slug.repo, limit) : openPrsArgv(limit),
          repoPath,
          OPEN_PRS_TIMEOUT_MS,
        );
        if (r.code !== 0) {
          const kind = classifyFailure(r.stderr);
          if (kind !== "error") await handleFailure(kind);
          return [];
        }
        try {
          const parsed = JSON.parse(r.stdout.trim() || "[]") as unknown;
          if (!Array.isArray(parsed)) return [];
          // The REST rows need mapping (head.ref/html_url); the gh --json rows
          // already match OpenPr.
          const value = useRest
            ? parsed.map(restOpenPr).filter((p): p is OpenPr => p !== null)
            : (parsed as OpenPr[]);
          // Same generation guard as prForBranch: a list fetched before a mutation
          // must not be written back after it.
          if (generationOf(key) === started) cacheSet(key, value, TTL_OPEN_PRS_MS);
          return value;
        } catch {
          return [];
        }
      });
    },

    budget() {
      return composedSnapshot();
    },

    history() {
      return tracker.history();
    },

    refresh,

    setPaused(next) {
      paused = next;
      tracker.setPaused(next);
      emitIfChanged();
    },

    onBudgetChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },

    close() {
      closed = true;
      if (refreshTimer) clearTimer(refreshTimer);
      refreshTimer = null;
      listeners.clear();
    },

    stats() {
      return { ...stats };
    },
  };
}
