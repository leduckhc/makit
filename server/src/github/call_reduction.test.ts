/**
 * SPEC-32 §10 criterion 1, as an executable guard: with 10 tracked branches idle
 * for 10 minutes, GitHub calls must drop **≥80%** versus the pre-SPEC-32
 * behaviour.
 *
 * This is the number the whole spec exists to move, so it is asserted rather
 * than claimed in a commit message. The baseline is what the code actually did
 * before: `server.ts` hardcoded `fastMs = slowMs = 5_000`, every `fetchOpenPr`
 * additionally paid an `unresolvedReviewThreadCount`, and there was no cache —
 * so 2 calls per branch per 5s tick, plus the duplication between `enrichPrs`
 * and `pr_watcher` asking the same question seconds apart.
 *
 * The simulation asks **twice per tick** per branch precisely to include that
 * duplication, which the gateway's in-flight dedupe now collapses.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { createGithubGateway } from "./gateway.js";

const BRANCHES = Array.from({ length: 10 }, (_, i) => `feature/b${i}`);

const PR_JSON = JSON.stringify([
  {
    number: 1,
    url: "https://github.com/o/r/pull/1",
    state: "OPEN",
    title: "t",
    isDraft: false,
    mergeable: "MERGEABLE",
    mergeStateStatus: "CLEAN",
    statusCheckRollup: [],
  },
]);
const THREADS_JSON = JSON.stringify({
  data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false }, nodes: [] } } } },
});
const RATE_LIMIT_JSON = JSON.stringify({
  resources: {
    core: { limit: 5000, remaining: 5000, reset: 9e9 },
    graphql: { limit: 5000, remaining: 5000, reset: 9e9 },
    search: { limit: 30, remaining: 30, reset: 9e9 },
  },
});

const POLL_MS = 5_000;
const WINDOW_MS = 10 * 60 * 1000;
const TICKS = WINDOW_MS / POLL_MS;
/** Must track `TTL_PR_MS` in gateway.ts — the refresh cadence the cache implies. */
const TTL_PR_MS = 20_000;

test("10 idle branches over 10 minutes cost >=80% fewer gh calls", async () => {
  let t = 0;
  const gateway = createGithubGateway({
    exec: async (_cmd, args) => {
      const a = args.join(" ");
      if (a.includes("rate_limit")) return { code: 0, stdout: RATE_LIMIT_JSON, stderr: "" };
      if (a.includes("graphql")) return { code: 0, stdout: THREADS_JSON, stderr: "" };
      return { code: 0, stdout: PR_JSON, stderr: "" };
    },
    now: () => t,
    setTimer: () => ({ unref() {} }), // the periodic refresh never fires here
    clearTimer: () => {},
  });
  await gateway.refresh();

  // Pre-SPEC-32: 2 uncached calls per branch per tick.
  const before = TICKS * BRANCHES.length * 2;

  for (let tick = 0; tick < TICKS; tick++) {
    // Twice per branch per tick: enrichPrs and pr_watcher both asking.
    await Promise.all(
      BRANCHES.flatMap((b) => [gateway.prForBranch("/repo", b), gateway.prForBranch("/repo", b)]),
    );
    t += POLL_MS;
  }

  // `stats.execs` counts quota-spending calls only: the exempt rate_limit read
  // lands in `exemptExecs`, so no hand-rolled subtraction is needed here.
  const after = gateway.stats().execs;
  const reduction = (before - after) / before;

  assert.ok(
    reduction >= 0.8,
    `expected >=80% fewer calls, got ${(reduction * 100).toFixed(1)}% (${before} -> ${after})`,
  );

  // Guard the OTHER direction too, and precisely. `after > 0` alone is toothless:
  // an over-caching regression (say a 5-minute PR TTL instead of 20s) would
  // report ~99% "savings" while actually meaning permanently stale PR status —
  // a regression dressed as a win. Pin the expected number of refreshes implied
  // by the TTL, so drifting materially in EITHER direction fails.
  const expected = Math.ceil(WINDOW_MS / TTL_PR_MS) * BRANCHES.length;
  assert.ok(
    after >= expected * 0.85 && after <= expected * 1.15,
    `expected ~${expected} refreshes (one per branch per ${TTL_PR_MS}ms TTL), got ${after}`,
  );
  gateway.close();
});
