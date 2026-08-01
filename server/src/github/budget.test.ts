import { test } from "node:test";
import assert from "node:assert/strict";

import { BudgetTracker, parseRateLimit } from "./budget.js";

/** A `gh api rate_limit` payload with the three buckets we care about. */
function rateLimit(
  over: Partial<Record<"core" | "graphql" | "search", { limit: number; remaining: number; reset: number }>> = {},
) {
  const base = {
    core: { limit: 5000, remaining: 5000, reset: 1000 },
    graphql: { limit: 5000, remaining: 5000, reset: 1000 },
    search: { limit: 30, remaining: 30, reset: 1000 },
  };
  return { resources: { ...base, ...over } };
}

const MIN = 60_000;

// ---------------------------------------------------------------------------
// parseRateLimit
// ---------------------------------------------------------------------------

test("parseRateLimit maps each resource and converts reset seconds → ms", () => {
  const out = parseRateLimit(rateLimit({ core: { limit: 5000, remaining: 4000, reset: 1700 } }));
  assert.equal(out.core?.limit, 5000);
  assert.equal(out.core?.remaining, 4000);
  assert.equal(out.core?.resetAt, 1700 * 1000, "reset is epoch seconds → ms");
  assert.equal(out.core?.others, 1000, "others derived from limit - remaining when mine = 0");
  assert.equal(out.core?.mine, 0);
});

test("parseRateLimit yields null for a missing bucket (unmeasured, not empty)", () => {
  const payload = rateLimit();
  delete (payload.resources as Record<string, unknown>).graphql;
  const out = parseRateLimit(payload);
  assert.equal(out.graphql, null);
  assert.notEqual(out.core, null);
});

test("parseRateLimit tolerates garbage without throwing", () => {
  for (const bad of [null, undefined, "nope", 42, [], {}, { resources: 7 }]) {
    const out = parseRateLimit(bad);
    assert.deepEqual(out, { core: null, graphql: null, search: null });
  }
});

test("parseRateLimit ignores unknown resources and non-numeric fields", () => {
  const out = parseRateLimit({
    resources: {
      core: { limit: 5000, remaining: 100, reset: 1000 },
      graphql: { limit: "x", remaining: 1, reset: 1 },
      integration_manifest: { limit: 5000, remaining: 5000, reset: 1 },
    },
  });
  assert.notEqual(out.core, null);
  assert.equal(out.graphql, null, "non-numeric field → null bucket");
  assert.equal(out.search, null, "missing → null");
});

// ---------------------------------------------------------------------------
// others attribution (the point of the whole module)
// ---------------------------------------------------------------------------

test("others = max(0, limit - remaining - mine): reveals other tools' spend", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({ core: { limit: 5000, remaining: 4000, reset: 1000 } }));
  // GitHub says 1000 consumed. We know we spent 200 → the other 800 is someone else.
  t.recordSpend("core", 200);
  const snap = t.snapshot();
  assert.equal(snap.buckets.core?.mine, 200);
  assert.equal(snap.buckets.core?.others, 800);
});

test("others clamps to 0 when our count exceeds observed consumption (skew/double count)", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({ core: { limit: 5000, remaining: 4000, reset: 1000 } }));
  t.recordSpend("core", 2000); // more than the 1000 GitHub observed
  assert.equal(t.snapshot().buckets.core?.others, 0, "never negative");
});

test("a bucket never seen is null, distinct from a measured-and-empty one", () => {
  const t = new BudgetTracker(() => 0);
  // Only ever measure core; graphql/search are never present in any reading.
  t.applyRateLimit({ resources: { core: { limit: 5000, remaining: 0, reset: 1000 } } });
  const snap = t.snapshot();
  assert.notEqual(snap.buckets.core, null, "measured, empty → object with remaining 0");
  assert.equal(snap.buckets.core?.remaining, 0);
  assert.equal(snap.buckets.graphql, null, "never measured → null");
});

// ---------------------------------------------------------------------------
// ring buffer + burn rate
// ---------------------------------------------------------------------------

test("history is always 60 slots, oldest → newest", () => {
  const t = new BudgetTracker(() => 0);
  const h = t.history();
  assert.equal(h.length, 60);
  assert.deepEqual(h[59], { mine: 0, others: 0 });
});

test("burnPerHour extrapolates the trailing 10 minutes × 6", () => {
  let clock = 0;
  const t = new BudgetTracker(() => clock);
  for (let m = 0; m < 15; m++) {
    clock = m * MIN;
    t.recordSpend("core", 10); // 10/min for 15 minutes
  }
  clock = 14 * MIN;
  // Only the trailing 10 minutes count: 10 × 10 = 100, × 6 = 600/hr.
  assert.equal(t.snapshot().burnPerHour, 600);
});

test("ring buffer rolls over: spend older than 60 minutes drops out", () => {
  let clock = 0;
  const t = new BudgetTracker(() => clock);
  t.recordSpend("core", 500);
  clock = 61 * MIN; // advance past the whole window
  const snap = t.snapshot();
  assert.equal(snap.burnPerHour, 0, "stale spend no longer counts");
  assert.ok(
    t.history().every((s) => s.mine === 0),
    "all slots reset after full rollover",
  );
});

test("spend lands in the newest slot and ages toward the oldest as the clock advances", () => {
  let clock = 0;
  const t = new BudgetTracker(() => clock);
  t.recordSpend("core", 7);
  assert.equal(t.history()[59].mine, 7, "fresh spend is the newest slot");
  clock = 3 * MIN;
  assert.equal(t.history()[59 - 3].mine, 7, "3 minutes later it has aged 3 slots back");
  assert.equal(t.history()[59].mine, 0);
});

// ---------------------------------------------------------------------------
// msUntilEmpty — governing bucket
// ---------------------------------------------------------------------------

test("msUntilEmpty is null when nothing is burning", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit());
  assert.equal(t.snapshot().msUntilEmpty, null);
});

test("msUntilEmpty follows graphql when graphql is the routable bucket", () => {
  // The governing bucket is the one we can still SPEND FROM -- the roomiest --
  // because router.ts routes to whichever can afford the call. (This previously
  // followed whichever emptied *first*, which reported 0ms of headroom while the
  // other bucket still held thousands of requests.)
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(
    rateLimit({
      core: { limit: 5000, remaining: 50, reset: 1000 },
      graphql: { limit: 5000, remaining: 1000, reset: 1000 },
    }),
  );
  t.recordSpend("core", 100); // burn = 600/hr
  // graphql governs (1000 > 50): 1000 / 600 h = 6_000_000 ms.
  assert.equal(t.snapshot().msUntilEmpty, 6_000_000);
});

test("msUntilEmpty follows core when core is the routable bucket", () => {
  // Mirror of the above, so the choice is proven to follow the numbers rather
  // than being hardcoded to one bucket.
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(
    rateLimit({
      core: { limit: 5000, remaining: 1000, reset: 1000 },
      graphql: { limit: 5000, remaining: 50, reset: 1000 },
    }),
  );
  t.recordSpend("core", 100);
  assert.equal(t.snapshot().msUntilEmpty, 6_000_000);
});

test("msUntilEmpty ignores the per-minute search bucket even when it is tiny", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(
    rateLimit({
      core: { limit: 5000, remaining: 1000, reset: 1000 },
      graphql: { limit: 5000, remaining: 1000, reset: 1000 },
      search: { limit: 30, remaining: 1, reset: 1000 },
    }),
  );
  t.recordSpend("core", 100); // burn = 600/hr
  // If search counted it would dominate; instead core/graphql govern: 1000/600 h.
  assert.equal(t.snapshot().msUntilEmpty, (1000 / 600) * 3_600_000);
});

// ---------------------------------------------------------------------------
// level — test AT each boundary
// ---------------------------------------------------------------------------

test("level is unknown before any measurement", () => {
  const t = new BudgetTracker(() => 0);
  assert.equal(t.snapshot().level, "unknown");
});

test("level is unknown after a garbage measurement (never truly measured)", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit("nonsense");
  assert.equal(t.snapshot().level, "unknown");
});

test("level: exactly 5 minutes of headroom is warm, not critical (boundary is <5)", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({
      // Both hourly buckets: the roomiest governs, so a single low bucket
      // beside a full one is (correctly) not a constraint at all.
      core: { limit: 5000, remaining: 50, reset: 1000 },
      graphql: { limit: 5000, remaining: 50, reset: 1000 },
    }));
  t.recordSpend("core", 100); // burn 600 → 50/600 h = 300_000 ms = 5 min exactly
  assert.equal(t.snapshot().msUntilEmpty, 5 * MIN);
  assert.equal(t.snapshot().level, "warm");
});

test("level: just under 5 minutes is critical", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({
      // Both hourly buckets: the roomiest governs, so a single low bucket
      // beside a full one is (correctly) not a constraint at all.
      core: { limit: 5000, remaining: 49, reset: 1000 },
      graphql: { limit: 5000, remaining: 49, reset: 1000 },
    }));
  t.recordSpend("core", 100); // 49/600 h = 294_000 ms < 5 min
  assert.equal(t.snapshot().level, "critical");
});

test("level: exactly 30 minutes of headroom is healthy, not warm (boundary is <30)", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({
      // Both hourly buckets: the roomiest governs, so a single low bucket
      // beside a full one is (correctly) not a constraint at all.
      core: { limit: 5000, remaining: 300, reset: 1000 },
      graphql: { limit: 5000, remaining: 300, reset: 1000 },
    }));
  t.recordSpend("core", 100); // 300/600 h = 1_800_000 ms = 30 min exactly
  assert.equal(t.snapshot().msUntilEmpty, 30 * MIN);
  assert.equal(t.snapshot().level, "healthy");
});

test("level: just under 30 minutes is warm", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({
      // Both hourly buckets: the roomiest governs, so a single low bucket
      // beside a full one is (correctly) not a constraint at all.
      core: { limit: 5000, remaining: 299, reset: 1000 },
      graphql: { limit: 5000, remaining: 299, reset: 1000 },
    }));
  t.recordSpend("core", 100);
  assert.equal(t.snapshot().level, "warm");
});

test("level: measured with zero burn and quota left is healthy", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit());
  assert.equal(t.snapshot().level, "healthy");
});

test("level: explicit pause wins over everything", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit());
  t.setPaused(true);
  assert.equal(t.snapshot().level, "paused");
  assert.deepEqual(t.snapshot().throttles, ["paused"]);
});

// ---------------------------------------------------------------------------
// throttles & retryAfter
// ---------------------------------------------------------------------------

test("throttles surface a secondary limit and pause in ladder order", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit());
  t.setRetryAfter(2000);
  t.setPaused(true);
  const snap = t.snapshot();
  assert.deepEqual(snap.throttles, ["secondary limit", "paused"]);
  assert.equal(snap.retryAfterMs, 2000);
});

test("setRetryAfter(null) clears the secondary-limit throttle", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit());
  t.setRetryAfter(2000);
  t.setRetryAfter(null);
  assert.deepEqual(t.snapshot().throttles, []);
  assert.equal(t.snapshot().retryAfterMs, null);
});

// ---------------------------------------------------------------------------
// window reset
// ---------------------------------------------------------------------------

test("a new window (later resetAt) clears our attributed spend", () => {
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(rateLimit({ core: { limit: 5000, remaining: 4000, reset: 1000 } }));
  t.recordSpend("core", 200);
  assert.equal(t.snapshot().buckets.core?.mine, 200);
  // Window rolls over: reset jumps forward, quota restored.
  t.applyRateLimit(rateLimit({ core: { limit: 5000, remaining: 5000, reset: 4600 } }));
  assert.equal(t.snapshot().buckets.core?.mine, 0, "mine resets on a new window");
});

// ── one dry bucket must not pause us while the other can serve ────────────────

/** `gh api rate_limit` as observed live: graphql exhausted, REST barely touched. */
function graphqlExhaustedJson(): string {
  return JSON.stringify({
    resources: {
      core: { limit: 5000, remaining: 4999, reset: 3600 },
      graphql: { limit: 5000, remaining: 0, reset: 3600 },
      search: { limit: 30, remaining: 30, reset: 60 },
    },
  });
}

test("an exhausted graphql bucket is not 'paused' while REST has room", () => {
  // Observed live: GraphQL 0/5,000 but REST 4,999/5,000 — and the UI read
  // "paused". It should not: these are INDEPENDENT budgets and router.ts exists
  // precisely to fail over to REST, so there is still ~1,249 PR lookups of work
  // available. Reporting paused stops polling for no reason and contradicts the
  // headline ("4,999 REST calls left") shown right beside it.
  const tracker = new BudgetTracker(() => 0);
  tracker.applyRateLimit(JSON.parse(graphqlExhaustedJson()));
  const snap = tracker.snapshot();
  assert.equal(snap.buckets.graphql?.remaining, 0);
  assert.equal(snap.buckets.core?.remaining, 4999);
  assert.notEqual(snap.level, "paused", "a routable bucket remains — not paused");
  assert.equal(snap.level, "healthy");
});

test("level is paused only when every hourly bucket is dry", () => {
  const tracker = new BudgetTracker(() => 0);
  tracker.applyRateLimit({
    resources: {
      core: { limit: 5000, remaining: 0, reset: 3600 },
      graphql: { limit: 5000, remaining: 0, reset: 3600 },
    },
  });
  assert.equal(tracker.snapshot().level, "paused");
});

test("msUntilEmpty follows the bucket we can still use, not the dry one", () => {
  // With graphql dry, "time until we cannot work" is governed by REST, not by
  // the bucket that already hit zero — otherwise every estimate reads 0ms and
  // the level pins to critical while thousands of REST calls remain.
  const tracker = new BudgetTracker(() => 0);
  tracker.applyRateLimit(JSON.parse(graphqlExhaustedJson()));
  tracker.recordSpend("core", 100); // 100 in the last minute => 600/h
  const snap = tracker.snapshot();
  assert.ok(snap.msUntilEmpty !== null);
  assert.ok(
    snap.msUntilEmpty! > 60_000,
    `expected hours of REST headroom, got ${snap.msUntilEmpty}ms`,
  );
});

test("an exhausted bucket names the failover, not just the failure", () => {
  // This string is rendered verbatim in the popover banner, so it should say
  // what we are DOING about it. "graphql exhausted" alone leaves the user to
  // guess whether PR status still works; naming the failover answers that.
  const t = new BudgetTracker(() => 0);
  t.applyRateLimit(JSON.parse(graphqlExhaustedJson()));
  assert.deepEqual(t.snapshot().throttles, ["graphql exhausted — using core"]);
});

test("an exhausted bucket is surfaced as a throttle, so the state is explained", () => {
  // The user must be able to tell "GraphQL is gone, we switched to REST" from
  // "everything is fine" — otherwise a healthy level beside a 0/5,000 bar looks
  // like a bug.
  const tracker = new BudgetTracker(() => 0);
  tracker.applyRateLimit(JSON.parse(graphqlExhaustedJson()));
  assert.ok(
    tracker.snapshot().throttles.some((t) => /graphql/i.test(t)),
    "an exhausted graphql bucket must be named in throttles",
  );
});
