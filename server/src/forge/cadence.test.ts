import { test } from "node:test";
import assert from "node:assert/strict";

import { forgePollIntervalMs } from "./cadence.js";
import { POLL_FAST_MS } from "../github/policy.js";
import type { GithubGateway } from "../github/gateway.js";

/** A gateway stub exposing just what the cadence helper reads. */
function stub(opts: { level?: string; providers?: string[] }): GithubGateway {
  const g: Record<string, unknown> = {
    // The real BudgetLike shape: hourly buckets plus a level and retry window.
    budget: () => ({
      level: opts.level ?? "unknown",
      retryAfterMs: null,
      buckets: { core: { remaining: 5000 }, graphql: { remaining: 5000 } },
    }),
  };
  if (opts.providers !== undefined) g.providersInUse = () => new Set(opts.providers);
  return g as unknown as GithubGateway;
}

test("a Forgejo-only setup polls at the fast rung, ignoring GitHub's ladder", () => {
  // The bug this fixes: with no GitHub repo, the rate_limit read never succeeds,
  // the level stays `unknown`, and the ladder treated that as the warm rung --
  // throttling Forgejo polling to 30s against a quota that does not apply.
  assert.equal(forgePollIntervalMs(stub({ level: "unknown", providers: ["forgejo"] })), POLL_FAST_MS);
  assert.equal(forgePollIntervalMs(stub({ level: "critical", providers: ["forgejo"] })), POLL_FAST_MS);
});

test("any GitHub repo in play hands the cadence back to the GitHub ladder", () => {
  const mixed = forgePollIntervalMs(stub({ level: "unknown", providers: ["forgejo", "github"] }));
  assert.ok(mixed > POLL_FAST_MS, `mixed setups must stay conservative, got ${mixed}`);
});

test("before anything is routed the cadence stays conservative", () => {
  // An empty mix is "not known yet", not "no GitHub" -- guessing fast here would
  // burn GitHub quota for the first few ticks after startup.
  const idle = forgePollIntervalMs(stub({ level: "unknown", providers: [] }));
  assert.ok(idle > POLL_FAST_MS);
});

test("a gateway that cannot report a mix falls back to the ladder", () => {
  const legacy = forgePollIntervalMs(stub({ level: "unknown" }));
  assert.ok(legacy > POLL_FAST_MS);
});

test("a healthy GitHub budget still yields the fast rung", () => {
  assert.equal(forgePollIntervalMs(stub({ level: "healthy", providers: ["github"] })), POLL_FAST_MS);
});
