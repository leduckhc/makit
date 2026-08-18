/**
 * BudgetTracker — the GitHub quota measurement layer (SPEC-github-gateway-and-budget §6.1).
 *
 * Pure and clock-injected: no `Date.now()`, no timers, no I/O. The gateway feeds
 * it `gh api rate_limit` output and its own spend; everything else keys off the
 * snapshot it produces.
 *
 * The interesting number here is `others`: it is *derived*, not observed. GitHub
 * only tells us how much of a bucket is left, not who spent it. By subtracting
 * our own counted spend from the total consumption, we surface quota burned by
 * the user's terminal, Codex, or any other agent sharing the same `gh` token —
 * spend that is completely invisible today and explains most real exhaustion.
 */

export type BucketName = "core" | "graphql" | "search";

export interface BucketState {
  limit: number;
  remaining: number;
  /** Epoch ms when the window resets (GitHub's reset is absolute, not rolling). */
  resetAt: number;
  /** Requests we attribute to makit in this window. */
  mine: number;
  /** limit - remaining - mine; spend by other tools on the same token. */
  others: number;
}

export interface BudgetSnapshot {
  buckets: Record<BucketName, BucketState | null>;
  /** Observed requests/hour over the trailing 10-minute window. */
  burnPerHour: number;
  /** Ms until the governing bucket empties at `burnPerHour`, or null if never. */
  msUntilEmpty: number | null;
  level: "healthy" | "warm" | "critical" | "paused" | "unknown";
  /** Active throttles, in ladder order — drives the popover's banner + badge. */
  throttles: string[];
  /** Set while a secondary (burst) limit is in force. */
  retryAfterMs: number | null;
  measuredAt: number;
}

/** The hourly buckets. `search` is per-minute and handled separately (see below). */
const HOURLY_BUCKETS: readonly BucketName[] = ["core", "graphql"];
const ALL_BUCKETS: readonly BucketName[] = ["core", "graphql", "search"];

const SLOT_COUNT = 60; // one minute per slot
const SLOT_MS = 60_000;
const BURN_WINDOW_MINUTES = 10;
const MS_PER_HOUR = 3_600_000;

const WARM_MS = 30 * SLOT_MS; // <30 min headroom
const CRITICAL_MS = 5 * SLOT_MS; // <5 min headroom

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Parse one bucket from a `gh api rate_limit` resource. Returns `null` for
 * anything malformed — an unmeasured bucket is never a zeroed object.
 */
function parseBucket(raw: unknown): BucketState | null {
  if (!isRecord(raw)) return null;
  const { limit, remaining, reset } = raw;
  if (
    typeof limit !== "number" ||
    typeof remaining !== "number" ||
    typeof reset !== "number" ||
    !Number.isFinite(limit) ||
    !Number.isFinite(remaining) ||
    !Number.isFinite(reset)
  ) {
    return null;
  }
  return {
    limit,
    remaining,
    resetAt: reset * 1000, // GitHub reports reset in epoch SECONDS
    mine: 0,
    others: Math.max(0, limit - remaining),
  };
}

/**
 * Tolerant parse of `gh api rate_limit` output into the buckets we track.
 * Unknown resources are ignored; missing or garbage buckets become `null`.
 */
export function parseRateLimit(json: unknown): Record<BucketName, BucketState | null> {
  const out: Record<BucketName, BucketState | null> = { core: null, graphql: null, search: null };
  const resources = isRecord(json) && isRecord(json.resources) ? json.resources : undefined;
  if (!resources) return out;
  for (const name of ALL_BUCKETS) out[name] = parseBucket(resources[name]);
  return out;
}

interface Slot {
  mine: number;
  others: number;
}

/**
 * A 60-slot per-minute ring buffer of our own spend, advanced by wall clock.
 * Index 0 is the oldest minute, index 59 the newest.
 */
class MinuteRing {
  private slots: Slot[] = MinuteRing.fresh();
  private anchorMinute: number | null = null;

  private static fresh(): Slot[] {
    return Array.from({ length: SLOT_COUNT }, () => ({ mine: 0, others: 0 }));
  }

  /** Shift the buffer forward to `now`, zero-filling elapsed minutes. */
  advance(now: number): void {
    const minute = Math.floor(now / SLOT_MS);
    if (this.anchorMinute === null) {
      this.anchorMinute = minute;
      return;
    }
    const delta = minute - this.anchorMinute;
    if (delta <= 0) return;
    if (delta >= SLOT_COUNT) {
      this.slots = MinuteRing.fresh();
    } else {
      for (let i = 0; i < delta; i++) {
        this.slots.shift();
        this.slots.push({ mine: 0, others: 0 });
      }
    }
    this.anchorMinute = minute;
  }

  addMine(units: number): void {
    this.slots[SLOT_COUNT - 1].mine += units;
  }

  addOthers(units: number): void {
    this.slots[SLOT_COUNT - 1].others += units;
  }

  trailingMine(minutes: number): number {
    let sum = 0;
    for (let i = SLOT_COUNT - minutes; i < SLOT_COUNT; i++) sum += this.slots[i].mine;
    return sum;
  }

  snapshot(): Slot[] {
    return this.slots.map((s) => ({ mine: s.mine, others: s.others }));
  }
}

interface RawBucket {
  limit: number;
  remaining: number;
  resetAt: number;
}

export class BudgetTracker {
  private readonly buckets: Record<BucketName, RawBucket | null> = {
    core: null,
    graphql: null,
    search: null,
  };
  private readonly mine: Record<BucketName, number> = { core: 0, graphql: 0, search: 0 };
  private readonly ring = new MinuteRing();
  private measured = false;
  private measuredAt = 0;
  private paused = false;
  private retryAfterMs: number | null = null;
  /** Last observed aggregate `others`, to attribute per-minute other-tool spend. */
  private lastOthersTotal: number | null = null;

  constructor(private readonly now: () => number) {}

  /** Ingest parsed `gh api rate_limit` output. Never throws on bad input. */
  applyRateLimit(json: unknown): void {
    const parsed = parseRateLimit(json);
    let measured = false;
    for (const name of ALL_BUCKETS) {
      const next = parsed[name];
      if (!next) continue;
      const prev = this.buckets[name];
      // A later reset means the fixed-reset window rolled over: our attributed
      // spend belongs to the previous window, so drop it.
      if (prev && next.resetAt > prev.resetAt) this.mine[name] = 0;
      this.buckets[name] = { limit: next.limit, remaining: next.remaining, resetAt: next.resetAt };
      measured = true;
    }
    if (!measured) return;
    this.measured = true;
    this.measuredAt = this.now();
    this.sampleOthers();
  }

  recordSpend(bucket: BucketName, units: number): void {
    this.ring.advance(this.now());
    this.ring.addMine(units);
    this.mine[bucket] += units;
  }

  setPaused(paused: boolean): void {
    this.paused = paused;
  }

  setRetryAfter(ms: number | null): void {
    this.retryAfterMs = ms;
  }

  snapshot(): BudgetSnapshot {
    this.ring.advance(this.now());
    const burnPerHour = this.ring.trailingMine(BURN_WINDOW_MINUTES) * (60 / BURN_WINDOW_MINUTES);
    const msUntilEmpty = this.computeMsUntilEmpty(burnPerHour);
    return {
      buckets: {
        core: this.bucketState("core"),
        graphql: this.bucketState("graphql"),
        search: this.bucketState("search"),
      },
      burnPerHour,
      msUntilEmpty,
      level: this.computeLevel(msUntilEmpty),
      throttles: this.computeThrottles(),
      retryAfterMs: this.retryAfterMs,
      measuredAt: this.measuredAt,
    };
  }

  history(): Array<{ mine: number; others: number }> {
    this.ring.advance(this.now());
    return this.ring.snapshot();
  }

  private bucketState(name: BucketName): BucketState | null {
    const b = this.buckets[name];
    if (!b) return null;
    const mine = this.mine[name];
    return {
      limit: b.limit,
      remaining: b.remaining,
      resetAt: b.resetAt,
      mine,
      others: Math.max(0, b.limit - b.remaining - mine),
    };
  }

  /** Record the per-minute rise in other tools' spend for the sparkline. */
  private sampleOthers(): void {
    this.ring.advance(this.now());
    let total = 0;
    for (const name of HOURLY_BUCKETS) total += this.bucketState(name)?.others ?? 0;
    if (this.lastOthersTotal !== null) {
      const delta = total - this.lastOthersTotal;
      if (delta > 0) this.ring.addOthers(delta);
    }
    this.lastOthersTotal = total;
  }

  private computeMsUntilEmpty(burnPerHour: number): number | null {
    if (burnPerHour <= 0) return null; // nothing will ever empty
    const remaining = this.usableRemaining();
    if (remaining === null) return null;
    return (remaining / burnPerHour) * MS_PER_HOUR;
  }

  /**
   * Headroom in the bucket we can **still route to**, i.e. the *best* measured
   * hourly bucket — not the worst.
   *
   * `core` and `graphql` are independent budgets and `router.ts` spends from
   * whichever can better afford a call, so an exhausted graphql bucket does not
   * block us while REST has thousands left (observed live: graphql 0/5,000 with
   * core 4,999/5,000). Taking the minimum here reported "paused" and a 0ms
   * time-to-empty in exactly that state, which stopped polling for no reason.
   *
   * `search` is excluded for the same reason as everywhere else: it is a
   * per-MINUTE bucket that recovers on its own.
   *
   * Note this is deliberately measured in *requests*, not PR lookups. REST costs
   * ~4 requests per lookup versus GraphQL's ~1, so a REST-served hour buys fewer
   * lookups than the raw number suggests — the burn rate already reflects that
   * once we are on the REST path, so the estimate self-corrects rather than
   * needing the cost model duplicated here.
   */
  private usableRemaining(): number | null {
    let best: number | null = null;
    for (const name of HOURLY_BUCKETS) {
      const b = this.buckets[name];
      if (!b) continue;
      if (best === null || b.remaining > best) best = b.remaining;
    }
    return best;
  }

  private computeLevel(msUntilEmpty: number | null): BudgetSnapshot["level"] {
    if (!this.measured) return "unknown";
    if (this.paused) return "paused";
    // Paused only when EVERY usable bucket is dry. One exhausted bucket is not a
    // stop: the router fails over to the other one (see usableRemaining).
    const usable = this.usableRemaining();
    if (usable !== null && usable <= 0) return "paused";
    if (msUntilEmpty !== null) {
      if (msUntilEmpty < CRITICAL_MS) return "critical";
      if (msUntilEmpty < WARM_MS) return "warm";
    }
    return "healthy";
  }

  private computeThrottles(): string[] {
    const throttles: string[] = [];
    if (this.retryAfterMs !== null) throttles.push("secondary limit");
    if (this.paused) throttles.push("paused");
    // Name an individually-exhausted bucket *and the failover*. Without this a
    // `healthy` level next to a 0/5,000 bar looks like a bug; and "graphql
    // exhausted" alone leaves the user guessing whether PR status still works.
    // Saying which bucket we switched to answers that in the same breath. When
    // every bucket is dry there is no failover to name, and `paused` covers it.
    for (const name of HOURLY_BUCKETS) {
      const b = this.buckets[name];
      if (!b || b.remaining > 0) continue;
      const alternative = HOURLY_BUCKETS.find(
        (other) => other !== name && (this.buckets[other]?.remaining ?? 0) > 0,
      );
      throttles.push(
        alternative ? `${name} exhausted — using ${alternative}` : `${name} exhausted`,
      );
    }
    return throttles;
  }
}
