/**
 * Cost-aware REST/GraphQL path selection (SPEC-github-gateway-and-budget §6.2).
 *
 * GitHub gives us two independent hourly budgets — `core` (REST) and `graphql`
 * (points) — that drain separately. Our hot path (`gh pr list --json`) is
 * secretly GraphQL, so we exhaust one bucket while the other sits idle. This
 * module is the pure decision function that routes each request to whichever
 * bucket can better afford it, measured as the fraction of that bucket's own
 * remaining headroom the call would consume. It is deliberately arithmetic, not
 * threshold-based (see spec §4): REST is a ~4× fallback, not a peer, and some
 * fields (unresolved review threads) have no REST equivalent at all.
 */

export type BucketName = "core" | "graphql" | "search";

export interface PathCost {
  bucket: BucketName;
  units: number;
}

export interface RequestPlan {
  primary: PathCost;
  fallback?: PathCost;
  /** GraphQL-only fields drop rather than source elsewhere when the bucket is dry. */
  degraded?: "omit";
}

export type RouteChoice = {
  bucket: BucketName;
  path: "primary" | "fallback" | "omit";
};

/**
 * The minimal shape this module reads from the BudgetTracker (T1/`budget.ts`).
 * Declared locally so router.ts compiles and tests standalone; T4 adapts the
 * real `BudgetSnapshot` to it. Keep this seam small — only the fields we score
 * on belong here.
 */
export interface BucketLike {
  /** Requests/points left in this bucket's current window. */
  remaining: number;
  /** Epoch ms when the window resets (GitHub's reset is absolute, not rolling). */
  resetAt: number;
}

export interface BudgetLike {
  buckets: Partial<Record<BucketName, BucketLike | null>>;
  /** Set while a secondary (burst) limit is in force; null otherwise. */
  retryAfterMs: number | null;
}

/** Primary resets within this window ⇒ consider waiting instead of paying the fallback. */
const RESET_IMMINENT_MS = 2 * 60 * 1000;
/** Fallback this much (or more) pricier than primary ⇒ waiting for a reset beats paying it. */
const FALLBACK_EXPENSIVE_RATIO = 3;
/** Switch only when the alternative is this much cheaper (>=20% better) — anti-flap. */
const HYSTERESIS_FACTOR = 0.8;

function remainingOf(budget: BudgetLike, bucket: BucketName): number {
  // Unmeasured buckets are treated as empty: conservative, and the max(1, …)
  // guard below keeps the score finite.
  return budget.buckets[bucket]?.remaining ?? 0;
}

/** Fraction of a bucket's own remaining headroom this call would consume. */
function score(cost: PathCost, budget: BudgetLike): number {
  return cost.units / Math.max(1, remainingOf(budget, cost.bucket));
}

export function route(
  plan: RequestPlan,
  budget: BudgetLike,
  previous?: RouteChoice,
  now: number = Date.now(),
): RouteChoice {
  const primaryChoice: RouteChoice = { bucket: plan.primary.bucket, path: "primary" };

  // Refinement 2 — never fail over under a secondary (burst) limit.
  // Secondary limits are per-TOKEN and apply to BOTH buckets at once, so
  // switching path cannot help, and spending 4× on the fallback actively makes
  // it worse. The correct response is lower concurrency + honouring Retry-After,
  // which belongs to the policy/gateway layer (T3/T4), not to routing.
  if (budget.retryAfterMs != null) return primaryChoice;

  if (!plan.fallback) {
    // GraphQL-only field (e.g. unresolvedComments): when its sole bucket cannot
    // afford the call, drop the field rather than sourcing it elsewhere.
    if (plan.degraded === "omit" && remainingOf(budget, plan.primary.bucket) < plan.primary.units) {
      return { bucket: plan.primary.bucket, path: "omit" };
    }
    return primaryChoice;
  }

  const fallbackChoice: RouteChoice = { bucket: plan.fallback.bucket, path: "fallback" };

  // Refinement 3 — reset-imminence. GitHub's window is a FIXED reset: the entire
  // allowance returns at once. If the primary resets within 2 minutes and the
  // fallback costs >=3×, prefer to wait rather than pay the multiplier.
  const primaryResetAt = budget.buckets[plan.primary.bucket]?.resetAt;
  if (
    primaryResetAt != null &&
    primaryResetAt >= now &&
    primaryResetAt - now <= RESET_IMMINENT_MS &&
    plan.fallback.units >= plan.primary.units * FALLBACK_EXPENSIVE_RATIO
  ) {
    return primaryChoice;
  }

  const primaryScore = score(plan.primary, budget);
  const fallbackScore = score(plan.fallback, budget);
  const cheaper = fallbackScore < primaryScore ? fallbackChoice : primaryChoice;
  const cheaperScore = Math.min(primaryScore, fallbackScore);

  // Refinement 1 — hysteresis. Once switched, stay switched until the argmin
  // winner is >=20% better by score, so the router does not flap bucket-to-bucket
  // every tick as the numbers drift.
  if (previous && (previous.path === "primary" || previous.path === "fallback")) {
    if (cheaper.path !== previous.path) {
      const previousCost = previous.path === "primary" ? plan.primary : plan.fallback;
      const previousScore = score(previousCost, budget);
      if (cheaperScore > previousScore * HYSTERESIS_FACTOR) {
        return previous.path === "primary" ? primaryChoice : fallbackChoice;
      }
    }
  }

  return cheaper;
}
