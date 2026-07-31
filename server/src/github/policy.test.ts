import { test } from "node:test";
import assert from "node:assert/strict";

import { decide, allow, type BudgetLike, type Policy } from "./policy.js";

/**
 * A healthy budget by default: two full buckets, no throttles.
 * Individual cases override only the field(s) under test.
 */
function budget(overrides: Partial<BudgetLike> = {}): BudgetLike {
  return {
    buckets: { core: { remaining: 5_000 }, graphql: { remaining: 5_000 } },
    level: "healthy",
    retryAfterMs: null,
    ...overrides,
  };
}

/**
 * Both hourly buckets set to exactly `remaining`.
 *
 * The ladder is governed by the bucket the router can still SPEND FROM (the
 * roomiest), so leaving one bucket full would mean no constraint at all -- the
 * rung under test would never engage.
 */
function withRemaining(remaining: number, overrides: Partial<BudgetLike> = {}): BudgetLike {
  return budget({
    buckets: { core: { remaining }, graphql: { remaining } },
    ...overrides,
  });
}

// ── Rung 0: healthy ────────────────────────────────────────────────────────

test("healthy budget polls fast, keeps unresolved, full concurrency", () => {
  const p = decide(budget());
  assert.deepEqual(p, {
    pollIntervalMs: 5_000,
    includeUnresolved: true,
    concurrency: 6,
    reserve: 300,
  } satisfies Policy);
});

// ── Rung 1: warm (<30 min headroom) — sheds unresolved first, poll → 30s ─────

test("warm level sheds unresolved and slows poll to 30s", () => {
  const p = decide(budget({ level: "warm" }));
  assert.equal(p.includeUnresolved, false, "unresolved is the first thing shed");
  assert.equal(p.pollIntervalMs, 30_000);
  assert.equal(p.concurrency, 6, "warm alone does not touch concurrency");
});

test("healthy level (the rung above warm) keeps unresolved on", () => {
  // The 30-min headroom boundary is owned by budget.ts's `level`; policy trusts it.
  // Just below the boundary is `warm` (tested above); at/above it is `healthy`.
  assert.equal(decide(budget({ level: "healthy" })).includeUnresolved, true);
});

test("critical level (<5 min headroom) behaves as a deeper warm rung", () => {
  const p = decide(budget({ level: "critical" }));
  assert.equal(p.includeUnresolved, false);
  assert.equal(p.pollIntervalMs, 30_000, "headroom alone slows to 30s; remaining drives further");
});

// ── Per-minute `search` bucket must not govern the ladder ────────────────────

test("a healthy account's search bucket does not pause polling", () => {
  // Regression guard. `gh api rate_limit` always reports `search` with a limit of
  // **30** (it is a per-MINUTE bucket), so a min() across every bucket makes the
  // governing remaining 30 on a perfectly healthy account — below the 300 reserve.
  // That silently pinned pollIntervalMs to Infinity and denied all background work,
  // i.e. PR status would never refresh again. Only the hourly (fixed-reset) buckets
  // may govern the ladder, matching budget.ts's msUntilEmpty.
  const b = budget({
    buckets: {
      core: { remaining: 5_000 },
      graphql: { remaining: 5_000 },
      search: { remaining: 30 },
    },
  });
  const p = decide(b);
  assert.equal(p.pollIntervalMs, 5_000, "search must not force the paused rung");
  assert.equal(p.includeUnresolved, true);
  assert.equal(allow(b, p, false), true, "background work must stay allowed");
});

test("an exhausted search bucket still does not pause polling", () => {
  const b = budget({
    buckets: {
      core: { remaining: 4_000 },
      graphql: { remaining: 4_000 },
      search: { remaining: 0 },
    },
  });
  assert.equal(decide(b).pollIntervalMs, 5_000);
});

// ── Rung 2: governing remaining < 900 — poll → 120s ──────────────────────────

test("remaining === 900 stays on the fast rung", () => {
  const p = decide(withRemaining(900));
  assert.equal(p.pollIntervalMs, 5_000, "900 is not < 900");
  assert.equal(p.includeUnresolved, true);
});

test("remaining === 899 drops to the 120s rung", () => {
  const p = decide(withRemaining(899));
  assert.equal(p.pollIntervalMs, 120_000);
});

test("cumulative: at the 120s rung unresolved is still shed", () => {
  // Governing remaining alone (level stays healthy) must still shed unresolved,
  // because 120s is a lower rung than warm and rungs are cumulative.
  const p = decide(withRemaining(899, { level: "healthy" }));
  assert.equal(p.pollIntervalMs, 120_000);
  assert.equal(p.includeUnresolved, false);
});

// ── Rung 3: governing remaining < reserve (300) — poll → Infinity (paused) ────

test("remaining === 300 (== reserve) crawls but is not paused", () => {
  const p = decide(withRemaining(300));
  assert.equal(p.pollIntervalMs, 120_000, "300 is not < 300, so not paused; but 300 < 900 → crawl");
});

test("remaining === 299 (< reserve) pauses polling", () => {
  const p = decide(withRemaining(299));
  assert.equal(p.pollIntervalMs, Infinity);
});

// ── Secondary (burst) limit — concurrency drop, INDEPENDENT of poll rungs ─────

test("secondary limit drops concurrency to 2 without pausing a healthy poll", () => {
  const p = decide(budget({ retryAfterMs: 1_000 }));
  assert.equal(p.concurrency, 2, "burst limit lowers concurrency");
  assert.equal(p.pollIntervalMs, 5_000, "a burst limit with full quota must NOT slow/pause polling");
  assert.equal(p.includeUnresolved, true);
});

test("no secondary limit uses full concurrency of 6", () => {
  assert.equal(decide(budget()).concurrency, 6);
});

// ── Manual pause — poll → Infinity regardless of a healthy budget ────────────

test("opts.paused forces Infinity even with a healthy budget", () => {
  assert.equal(decide(budget(), { paused: true }).pollIntervalMs, Infinity);
});

test("level 'paused' forces Infinity", () => {
  assert.equal(decide(budget({ level: "paused" })).pollIntervalMs, Infinity);
});

// ── allow(): the reserve protects interactive work from background greed ──────

test("allow: background is denied at remaining = reserve - 1", () => {
  const b = withRemaining(299); // reserve is 300
  const p = decide(b);
  assert.equal(allow(b, p, false), false, "background must not draw on the reserve");
});

test("allow: interactive is ALWAYS allowed at remaining = reserve - 1", () => {
  const b = withRemaining(299);
  const p = decide(b);
  assert.equal(allow(b, p, true), true, "a user action never fails because polling was greedy");
});

test("allow: both background and interactive allowed when healthy", () => {
  const b = budget();
  const p = decide(b);
  assert.equal(allow(b, p, false), true);
  assert.equal(allow(b, p, true), true);
});

test("allow: background allowed exactly at the reserve floor (== reserve)", () => {
  const b = withRemaining(300);
  const p = decide(b);
  assert.equal(allow(b, p, false), true, "300 >= reserve 300 → still allowed");
});

// ── Unknown / unmeasured budget — conservative default ────────────────────────

test("unknown budget defaults to the warm rung (shed unresolved, 30s, not paused)", () => {
  const p = decide({ buckets: {}, level: "unknown", retryAfterMs: null });
  assert.equal(p.includeUnresolved, false);
  assert.equal(p.pollIntervalMs, 30_000);
  assert.equal(p.concurrency, 6);
  assert.equal(p.reserve, 300);
});

test("allow: background is allowed when the budget is unmeasured", () => {
  const b: BudgetLike = { buckets: {}, level: "unknown", retryAfterMs: null };
  const p = decide(b);
  assert.equal(allow(b, p, false), true, "no evidence of exhaustion → do not freeze background work");
  assert.equal(allow(b, p, true), true);
});

// ── a dry bucket must not pause the ladder while another can serve ─────────────

test("an exhausted graphql bucket does not pause polling while REST has room", () => {
  // Observed live: graphql 0, core 4,999. Taking min() across buckets made the
  // governing remaining 0 -- below the 300 reserve -- so the ladder paused
  // polling and allow() denied all background work, even though router.ts can
  // serve every PR lookup over REST. We are only blocked when EVERY usable
  // bucket is dry.
  const b = budget({
    buckets: { core: { remaining: 4_999 }, graphql: { remaining: 0 } },
  });
  const p = decide(b);
  assert.equal(p.pollIntervalMs, 5_000, "REST can still serve: keep polling");
  assert.equal(allow(b, p, false), true, "background work must stay allowed");
});

test("the ladder pauses when every hourly bucket is dry", () => {
  const b = budget({
    buckets: { core: { remaining: 0 }, graphql: { remaining: 0 } },
    level: "paused",
  });
  assert.equal(decide(b).pollIntervalMs, Number.POSITIVE_INFINITY);
  assert.equal(allow(b, decide(b), false), false);
});

test("the reserve applies to the best usable bucket, not the worst", () => {
  // graphql dry, core just under the reserve => genuinely out of headroom.
  const b = budget({
    buckets: { core: { remaining: 299 }, graphql: { remaining: 0 } },
  });
  const p = decide(b);
  assert.equal(allow(b, p, false), false, "no usable bucket above the reserve");
  assert.equal(allow(b, p, true), true, "interactive still draws on the reserve");
});
