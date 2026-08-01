/**
 * Degradation ladder for GitHub reads (SPEC-32 §6.3). Pure decision function:
 * given the current budget health it returns the concrete knobs the gateway and
 * poller run with, and decides whether a single request may proceed.
 *
 * The ladder sheds the most expensive, least essential data first and always
 * holds a reserve so a user-initiated action never fails because a background
 * poller drained the quota.
 *
 * ── The seam (T4 adapts this) ────────────────────────────────────────────────
 * We only consume a minimal structural slice of the real BudgetSnapshot (built
 * in parallel as T1's `budget.ts`): `BudgetLike`. Keeping the seam this small
 * lets policy compile and be tested standalone; T4 maps a BudgetSnapshot onto it.
 *
 * Deliberately NOT consumed: `msUntilEmpty`. The 30-min / 5-min headroom
 * thresholds are owned by `budget.ts` and already surfaced as `level`
 * ("warm" < 30 min, "critical" < 5 min). Re-reading `msUntilEmpty` here would
 * duplicate those thresholds (DRY/SRP), so policy branches on `level` instead.
 *
 * ── Design invariants ────────────────────────────────────────────────────────
 * 1. `includeUnresolved` is the FIRST rung. The unresolved-review-thread count
 *    is our single most expensive call (paged GraphQL, per PR, every tick) and
 *    the least essential number on screen. It is GraphQL-only — no REST
 *    equivalent exists — so it cannot be re-sourced from the other bucket;
 *    shedding is the only lever. It is therefore dropped the moment we leave the
 *    fast rung: `includeUnresolved === (pollIntervalMs === POLL_FAST_MS)`.
 * 2. `allow()` is where the reserve earns its keep. Below `reserve`, background
 *    requests are denied but `interactive` requests are ALWAYS allowed.
 *
 * ── Unmeasured (`level: "unknown"`) default ──────────────────────────────────
 * Conservative-but-alive: treat it as the warm rung — shed unresolved and poll
 * at 30s, but do NOT pause. Pausing on a not-yet-measured budget would freeze
 * the UI on startup for no evidence of exhaustion. `allow()` likewise permits
 * background work when unmeasured, since the first `rate_limit` read is free and
 * immediate.
 */

/** The per-bucket slice we read; only `remaining` matters to the ladder. */
export interface BucketRemaining {
  remaining: number;
}

/** Minimal structural view of a BudgetSnapshot consumed by the ladder. */
export interface BudgetLike {
  /**
   * Rate-limit buckets; `null` when unmeasured. Only the **hourly** buckets
   * ({@link HOURLY_BUCKETS}) govern the ladder — see {@link governingRemaining}.
   */
  buckets: Record<string, BucketRemaining | null>;
  /** Quota health, driven by headroom in `budget.ts`. */
  level: "healthy" | "warm" | "critical" | "paused" | "unknown";
  /** Ms to wait under a secondary (burst) limit, or `null` when none is active. */
  retryAfterMs: number | null;
}

export interface Policy {
  /** 5s → 30s → 120s → Infinity (paused). */
  pollIntervalMs: number;
  /** The first thing shed: expensive, GraphQL-only, least essential. */
  includeUnresolved: boolean;
  /** 6 normally, 2 under a secondary limit. */
  concurrency: number;
  /** Requests withheld from background work to protect interactive actions. */
  reserve: number;
}

const POLL_FAST_MS = 5_000;
const POLL_SLOW_MS = 30_000;
const POLL_CRAWL_MS = 120_000;
const POLL_PAUSED_MS = Infinity;

const RESERVE = 300;
const CONCURRENCY_NORMAL = 6;
const CONCURRENCY_LIMITED = 2;

/** Levels whose headroom warrants shedding unresolved + a 30s poll floor. */
const HEADROOM_SHED_LEVELS: ReadonlySet<BudgetLike["level"]> = new Set([
  "warm",
  "critical",
  "unknown",
]);

/**
 * Governing-remaining rungs, cumulative: a request-budget below `below` forces
 * at least `pollIntervalMs`. The most restrictive (slowest) matching rung wins.
 */
const REMAINING_RUNGS: ReadonlyArray<{ below: number; pollIntervalMs: number }> = [
  { below: RESERVE, pollIntervalMs: POLL_PAUSED_MS },
  { below: 900, pollIntervalMs: POLL_CRAWL_MS },
];

/**
 * The hourly, fixed-reset buckets — the only ones allowed to govern the ladder.
 *
 * `search` is deliberately excluded: its limit is **30 per MINUTE**, so a naive
 * `min()` across every bucket reports a governing remaining of 30 on a perfectly
 * healthy account, which is below {@link RESERVE} and silently pins the poll
 * interval to `Infinity` — PR status would never refresh again. It also recovers
 * on its own within the minute, so it can never justify slowing an hourly poller.
 * Mirrors the same exclusion in `budget.ts`'s `msUntilEmpty`.
 */
const HOURLY_BUCKETS: readonly string[] = ["core", "graphql"];

/**
 * Headroom in the bucket the router can **still spend from** — the *best*
 * measured hourly bucket, not the worst.
 *
 * `core` and `graphql` are independent budgets and `router.ts` picks whichever
 * can better afford a call, so an exhausted graphql bucket must not pause the
 * ladder while REST has thousands left. Taking the minimum here did exactly
 * that: observed live with graphql 0 and core 4,999, the governing remaining
 * read 0, which sits below {@link RESERVE} — so polling paused and `allow()`
 * denied all background work despite ~1,249 REST-served PR lookups being
 * available. We are blocked only when EVERY usable bucket is dry.
 */
function governingRemaining(budget: BudgetLike): number | null {
  const measured = HOURLY_BUCKETS.map((name) => budget.buckets[name])
    .filter((b): b is BucketRemaining => b != null)
    .map((b) => b.remaining);
  return measured.length > 0 ? Math.max(...measured) : null;
}

function pollIntervalFor(budget: BudgetLike, gov: number | null, paused: boolean): number {
  if (paused || budget.level === "paused") return POLL_PAUSED_MS;

  // Slowest applicable rung wins (Infinity > 120s > 30s > 5s), so the ladder is
  // naturally cumulative without ordering the checks by hand.
  let pollIntervalMs = HEADROOM_SHED_LEVELS.has(budget.level) ? POLL_SLOW_MS : POLL_FAST_MS;
  if (gov !== null) {
    for (const rung of REMAINING_RUNGS) {
      if (gov < rung.below) pollIntervalMs = Math.max(pollIntervalMs, rung.pollIntervalMs);
    }
  }
  return pollIntervalMs;
}

export function decide(budget: BudgetLike, opts: { paused?: boolean } = {}): Policy {
  const gov = governingRemaining(budget);
  const pollIntervalMs = pollIntervalFor(budget, gov, opts.paused ?? false);
  return {
    pollIntervalMs,
    // Invariant 1: unresolved is shed the instant we leave the fast rung.
    includeUnresolved: pollIntervalMs === POLL_FAST_MS,
    concurrency: budget.retryAfterMs != null ? CONCURRENCY_LIMITED : CONCURRENCY_NORMAL,
    reserve: RESERVE,
  };
}

/**
 * Whether a single request may proceed. Interactive requests always may — they
 * bypass the ladder and draw on the reserve (invariant 2). Background requests
 * are denied once the governing bucket falls below the reserve. An unmeasured
 * budget permits background work (no evidence of exhaustion).
 */
export function allow(budget: BudgetLike, policy: Policy, interactive: boolean): boolean {
  if (interactive) return true;
  const gov = governingRemaining(budget);
  if (gov === null) return true;
  return gov >= policy.reserve;
}
