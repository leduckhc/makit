import { test } from "node:test";
import assert from "node:assert/strict";

import { route } from "./router.js";
import type { BudgetLike, RequestPlan, RouteChoice } from "./router.js";

const NOW = 1_000_000;
const FAR_RESET = NOW + 3_600_000; // an hour away — never "imminent"

/** A GraphQL-primary / REST-fallback plan, the real hot path (`gh pr list`). */
function prPlan(overrides: Partial<RequestPlan> = {}): RequestPlan {
  return {
    primary: { bucket: "graphql", units: 1 },
    fallback: { bucket: "core", units: 4 },
    ...overrides,
  };
}

function budget(opts: {
  core?: number;
  graphql?: number;
  retryAfterMs?: number | null;
  graphqlResetAt?: number;
} = {}): BudgetLike {
  return {
    buckets: {
      core: { remaining: opts.core ?? 5000, resetAt: FAR_RESET },
      graphql: { remaining: opts.graphql ?? 5000, resetAt: opts.graphqlResetAt ?? FAR_RESET },
      search: { remaining: 30, resetAt: FAR_RESET },
    },
    retryAfterMs: opts.retryAfterMs ?? null,
  };
}

test("prefers graphql when it is plentiful (the normal case)", () => {
  // graphql 1/4188 ≈ 0.00024 beats REST 4/1769 ≈ 0.00226 by ~9×.
  const choice = route(prPlan(), budget({ graphql: 4188, core: 1769 }), undefined, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "graphql", path: "primary" });
});

test("flips to REST when graphql is starved and core has room", () => {
  // graphql 1/400 = 0.0025 now loses to REST 4/1769 ≈ 0.00226 — the arithmetic
  // flips on its own, with no hand-tuned threshold.
  const choice = route(prPlan(), budget({ graphql: 400, core: 1769 }), undefined, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "core", path: "fallback" });
});

test("hysteresis: a marginal (<20%) improvement does NOT switch", () => {
  // Previously on REST. graphql=491 makes primary ~10% cheaper — below the 20%
  // bar — so we must stay on REST rather than flap.
  const previous: RouteChoice = { bucket: "core", path: "fallback" };
  const choice = route(prPlan(), budget({ graphql: 491, core: 1769 }), previous, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "core", path: "fallback" });
});

test("hysteresis: a large (>=20%) improvement does switch", () => {
  // Previously on REST, but graphql is now plentiful — a huge improvement, so switch.
  const previous: RouteChoice = { bucket: "core", path: "fallback" };
  const choice = route(prPlan(), budget({ graphql: 4188, core: 1769 }), previous, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "graphql", path: "primary" });
});

test("does not fail over while a secondary limit is in force", () => {
  // Secondary (burst) limits are per-token and hit BOTH buckets, so even though
  // REST scores far better here, failing over cannot help and paying 4× hurts.
  const choice = route(
    prPlan(),
    budget({ graphql: 1, core: 5000, retryAfterMs: 3000 }),
    undefined,
    NOW,
  );
  assert.deepEqual<RouteChoice>(choice, { bucket: "graphql", path: "primary" });
});

test("reset-imminence: waits rather than paying 4×", () => {
  // graphql is starved (REST would normally win), but its window resets in 90s and
  // REST costs 4× — prefer to wait for the whole allowance to return at once.
  const choice = route(
    prPlan(),
    budget({ graphql: 100, core: 100000, graphqlResetAt: NOW + 90_000 }),
    undefined,
    NOW,
  );
  assert.deepEqual<RouteChoice>(choice, { bucket: "graphql", path: "primary" });
});

test("omit when the only path is starved and no fallback exists", () => {
  // unresolvedComments is GraphQL-only: drop the field when graphql is dry.
  const plan: RequestPlan = {
    primary: { bucket: "graphql", units: 1 },
    degraded: "omit",
  };
  const choice = route(plan, budget({ graphql: 0 }), undefined, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "graphql", path: "omit" });
});

test("max(1, remaining) guard: remaining 0 does not divide by zero", () => {
  // graphql remaining 0 → score = 1/max(1,0) = 1 (not Infinity/NaN); REST wins cleanly.
  const choice = route(prPlan(), budget({ graphql: 0, core: 1769 }), undefined, NOW);
  assert.deepEqual<RouteChoice>(choice, { bucket: "core", path: "fallback" });
});

// ── balancing, not merely failing over ────────────────────────────────────────

test("draining both buckets serves more work than either alone", () => {
  // The point of relative-headroom scoring is that it BALANCES: as graphql
  // drains its score rises until REST becomes the better buy, then REST drains
  // until graphql is better again. Neither bucket is left stranded with unused
  // headroom while the other is dry, so total capacity exceeds the 5,000 lookups
  // graphql alone could serve.
  const plan: RequestPlan = {
    primary: { bucket: "graphql", units: 1 },
    fallback: { bucket: "core", units: 4 },
  };
  let graphql = 5000;
  let core = 5000;
  let previous: RouteChoice | undefined;
  let served = 0;
  let viaGraphql = 0;
  let viaRest = 0;

  while (graphql >= 1 || core >= 4) {
    const choice = route(
      plan,
      {
        buckets: {
          graphql: { remaining: graphql, resetAt: 9e12 },
          core: { remaining: core, resetAt: 9e12 },
        },
        retryAfterMs: null,
      },
      previous,
      0,
    );
    previous = choice;
    if (choice.path === "primary") {
      if (graphql < 1) break;
      graphql -= 1;
      viaGraphql += 1;
    } else {
      if (core < 4) break;
      core -= 4;
      viaRest += 1;
    }
    served += 1;
    if (served > 20_000) break; // safety net against a routing livelock
  }

  assert.ok(viaGraphql > 0, "the cheap path must carry the bulk of the work");
  assert.ok(viaRest > 0, "the REST path must actually be used, not just planned");
  assert.ok(
    served > 5000,
    `balancing must beat graphql alone (5000 lookups); served ${served}`,
  );
  // Both buckets end spent: nothing stranded.
  assert.ok(graphql < 1, `graphql left unspent: ${graphql}`);
  assert.ok(core < 4, `core left unspent: ${core}`);
});

test("the switch happens while graphql still has room, not at zero", () => {
  // "Nearing 0" must be early enough to matter: with core full the flip lands
  // around a quarter of the graphql bucket (1 unit vs 4 = a 4x cost ratio), so
  // PR status keeps flowing instead of stalling the moment graphql empties.
  const plan: RequestPlan = {
    primary: { bucket: "graphql", units: 1 },
    fallback: { bucket: "core", units: 4 },
  };
  const at = (graphql: number) =>
    route(
      plan,
      {
        buckets: {
          graphql: { remaining: graphql, resetAt: 9e12 },
          core: { remaining: 5000, resetAt: 9e12 },
        },
        retryAfterMs: null,
      },
      undefined,
      0,
    ).path;

  assert.equal(at(2000), "primary", "plenty of graphql: stay on the cheap path");
  assert.equal(at(1000), "fallback", "graphql getting low: switch before it dies");
  assert.equal(at(0), "fallback");
});
