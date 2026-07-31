import { test } from "node:test";
import assert from "node:assert/strict";

import {
  ConcurrencyGate,
  createGithubGateway,
  type Exec,
  type ExecResult,
  type GithubGateway,
} from "./gateway.js";
import type { BudgetSnapshot } from "./budget.js";

/** A `gh pr list --head` result with one open PR. */
const PR_JSON = JSON.stringify([
  {
    number: 7,
    url: "https://github.com/o/r/pull/7",
    state: "OPEN",
    title: "t",
    isDraft: false,
    mergeable: "MERGEABLE",
    mergeStateStatus: "CLEAN",
    statusCheckRollup: [],
  },
]);

/** An empty (but successful) review-threads page. */
const THREADS_JSON = JSON.stringify({
  data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false }, nodes: [] } } } },
});

/** A `gh api rate_limit` body with the given remaining counts. */
function rateLimitJson(coreRemaining: number, graphqlRemaining: number): string {
  return JSON.stringify({
    resources: {
      core: { limit: 5000, remaining: coreRemaining, reset: 3600 },
      graphql: { limit: 5000, remaining: graphqlRemaining, reset: 3600 },
    },
  });
}

const ok = (stdout: string): ExecResult => ({ code: 0, stdout, stderr: "" });
const fail = (stderr: string): ExecResult => ({ code: 1, stdout: "", stderr });

interface Harness {
  gateway: GithubGateway;
  calls: string[][];
  clock: { advance(ms: number): void };
}

/** Build a gateway over a fake exec; no timers ever fire, no process spawns. */
function makeGateway(handler: (args: string[]) => ExecResult | Promise<ExecResult>): Harness {
  const calls: string[][] = [];
  let t = 0;
  const exec: Exec = async (_cmd, args) => {
    calls.push(args);
    return handler(args);
  };
  const gateway = createGithubGateway({
    exec,
    now: () => t,
    setTimer: () => ({ unref() {} }), // periodic refresh never fires in tests
    clearTimer: () => {},
  });
  return { gateway, calls, clock: { advance: (ms) => (t += ms) } };
}

function kindOf(args: string[]): "pr" | "threads" | "rate_limit" | "other" {
  if (args[0] === "api" && args[1] === "rate_limit") return "rate_limit";
  if (args[0] === "api" && args[1] === "graphql") return "threads";
  if (args[0] === "pr" && args[1] === "list") return "pr";
  return "other";
}

test("two concurrent identical prForBranch calls run exactly one exec", async () => {
  let prExecs = 0;
  const { gateway, calls } = makeGateway((args) => {
    if (kindOf(args) === "pr") prExecs += 1;
    return ok(PR_JSON);
  });
  const [a, b] = await Promise.all([
    gateway.prForBranch("/repo", "br"),
    gateway.prForBranch("/repo", "br"),
  ]);
  assert.equal(a.kind, "pr");
  assert.equal(b.kind, "pr");
  assert.equal(prExecs, 1, "dedupe must coalesce concurrent identical calls");
  assert.equal(calls.filter((c) => kindOf(c) === "pr").length, 1);
});

test("a second prForBranch within the TTL runs zero further execs", async () => {
  let prExecs = 0;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "pr") prExecs += 1;
    return ok(PR_JSON);
  });
  await gateway.prForBranch("/repo", "br");
  await gateway.prForBranch("/repo", "br");
  assert.equal(prExecs, 1, "TTL hit must avoid a second exec");
  assert.equal(gateway.stats().cacheHits, 1);
});

test("interactive:true bypasses the TTL and re-execs", async () => {
  let prExecs = 0;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "pr") prExecs += 1;
    return ok(PR_JSON);
  });
  await gateway.prForBranch("/repo", "br");
  await gateway.prForBranch("/repo", "br", { interactive: true });
  assert.equal(prExecs, 2, "interactive must bypass the cache read");
});

test("exit 0 with an empty list yields kind:none (the only path to none)", async () => {
  const { gateway } = makeGateway(() => ok("[]"));
  const r = await gateway.prForBranch("/repo", "br");
  assert.deepEqual(r, { kind: "none" });
});

test("rate-limit stderr yields kind:unknown throttled AND triggers a refresh", async () => {
  let sawRateLimit = false;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") {
      sawRateLimit = true;
      return ok(rateLimitJson(4000, 4000));
    }
    return fail("gh: API rate limit exceeded for user");
  });
  const r = await gateway.prForBranch("/repo", "br");
  assert.deepEqual(r, { kind: "unknown", reason: "throttled" });
  assert.ok(sawRateLimit, "a 403/throttle must trigger a rate_limit refresh");
});

test("a generic failure yields kind:unknown error and is NEVER kind:none (the missing-pill bug)", async () => {
  const { gateway } = makeGateway(() => fail("fatal: could not resolve host github.com"));
  const r = await gateway.prForBranch("/repo", "br");
  assert.deepEqual(r, { kind: "unknown", reason: "error" });
  assert.notEqual(r.kind, "none", "a failed lookup must never look like a deleted PR");
});

test("spend is recorded before the exec resolves", async () => {
  let mineAtExecTime: number | null = null;
  let g: GithubGateway;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") return ok(rateLimitJson(4000, 4000));
    if (kindOf(args) === "pr") mineAtExecTime = g.budget().buckets.graphql?.mine ?? -1;
    return ok(kindOf(args) === "pr" ? PR_JSON : THREADS_JSON);
  });
  g = gateway;
  await gateway.refresh(); // measure the graphql bucket so `mine` is observable
  await gateway.prForBranch("/repo", "br");
  assert.equal(mineAtExecTime, 1, "graphql spend must be recorded before the pr-list exec");
});

test("the concurrency cap is never exceeded", async () => {
  let inFlight = 0;
  let peak = 0;
  const { gateway } = makeGateway(async () => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight -= 1;
    return ok("[]");
  });
  // Distinct branches ⇒ no dedupe; unmeasured budget ⇒ concurrency 6.
  await Promise.all(
    Array.from({ length: 20 }, (_, i) => gateway.prForBranch("/repo", `br${i}`)),
  );
  assert.ok(peak <= 6, `peak concurrency ${peak} exceeded the cap of 6`);
});

test("onBudgetChange fires on a level change but not on an unchanged level", async () => {
  const { gateway } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(rateLimitJson(4000, 4000)) : ok("[]"),
  );
  const levels: BudgetSnapshot["level"][] = [];
  gateway.onBudgetChange((s) => levels.push(s.level));

  await gateway.refresh(); // unknown → healthy (a change)
  await gateway.refresh(); // healthy → healthy (no change)
  assert.deepEqual(levels, ["healthy"], "unchanged level must not re-fire");

  gateway.setPaused(true); // healthy → paused (a change)
  assert.deepEqual(levels, ["healthy", "paused"]);
});

test("refresh (rate_limit) records no spend — the endpoint is exempt", async () => {
  const { gateway } = makeGateway(() => ok(rateLimitJson(4000, 4000)));
  await gateway.refresh();
  assert.equal(gateway.budget().buckets.graphql?.mine, 0);
  assert.equal(gateway.budget().buckets.core?.mine, 0);
});

test("close clears listeners so no further budget events fire", async () => {
  const { gateway } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(rateLimitJson(4000, 4000)) : ok("[]"),
  );
  let fired = 0;
  gateway.onBudgetChange(() => (fired += 1));
  gateway.close();
  gateway.setPaused(true);
  await gateway.refresh();
  assert.equal(fired, 0);
});

// ── REST failover (spec §6.2 G5) ──────────────────────────────────────────────

/** Harness variant that records the command too, so git vs gh is observable. */
function makeGatewayWithCmds(handler: (cmd: string, args: string[]) => ExecResult): {
  gateway: GithubGateway;
  execs: Array<{ cmd: string; args: string[] }>;
} {
  const execs: Array<{ cmd: string; args: string[] }> = [];
  const exec: Exec = async (cmd, args) => {
    execs.push({ cmd, args });
    return handler(cmd, args);
  };
  const gateway = createGithubGateway({
    exec,
    now: () => 0,
    setTimer: () => ({ unref() {} }),
    clearTimer: () => {},
  });
  return { gateway, execs };
}

/** REST payloads for one open PR on `feature` with a single passing check. */
const REST_LIST = JSON.stringify([
  { number: 7, html_url: "https://github.com/o/r/pull/7", state: "open", title: "t", draft: false, head: { sha: "abc" } },
]);
const REST_DETAIL = JSON.stringify({ mergeable: true, mergeable_state: "clean" });
const REST_CHECKS = JSON.stringify({
  check_runs: [{ name: "test", status: "completed", conclusion: "success", details_url: "u" }],
});
const REST_STATUS = JSON.stringify({ statuses: [] });

/** Route every REST/gh/git argv of the failover path to its canned payload. */
function restHandler(coreRemaining: number, graphqlRemaining: number) {
  return (cmd: string, args: string[]): ExecResult => {
    if (cmd === "git") return ok("git@github.com:o/r.git\n");
    const path = args[1] ?? "";
    if (path === "rate_limit") return ok(rateLimitJson(coreRemaining, graphqlRemaining));
    if (path.includes("/pulls?head=")) return ok(REST_LIST);
    if (/\/pulls\/\d+$/.test(path)) return ok(REST_DETAIL);
    if (path.includes("/check-runs")) return ok(REST_CHECKS);
    if (path.endsWith("/status")) return ok(REST_STATUS);
    if (args[0] === "pr") return ok(PR_JSON);
    return fail("unexpected");
  };
}

test("fails over to REST when graphql is starved and core has room", async () => {
  // graphql 1,000 vs core 5,000: score 1/1000 > 4/5000, so REST is the better
  // buy in relative-headroom terms and the router must be OBEYED, not merely
  // consulted (the whole point of G5).
  const { gateway, execs } = makeGatewayWithCmds(restHandler(5_000, 1_000));
  await gateway.refresh();
  const res = await gateway.prForBranch("/repo", "feature");
  assert.equal(res.kind, "pr");
  if (res.kind !== "pr") return;
  assert.equal(res.pr.number, 7);
  assert.equal(res.pr.url, "https://github.com/o/r/pull/7");
  assert.equal(res.pr.mergeable, "MERGEABLE", "REST boolean maps to the GraphQL vocabulary");
  assert.equal(res.pr.mergeStateStatus, "CLEAN");
  assert.equal(res.pr.checkRollup, "pass", "lowercase REST 'completed/success' must classify as pass");
  assert.equal(
    res.pr.unresolvedUnknown,
    true,
    "REST cannot express resolved threads, so the 0 must be flagged as not-a-fact",
  );
  assert.equal(res.pr.unresolvedComments, 0);
  const usedGraphqlList = execs.some((e) => e.cmd === "gh" && e.args[0] === "pr" && e.args[1] === "list");
  assert.equal(usedGraphqlList, false, "must not spend the starved graphql bucket");
});

test("stays on GraphQL while it has headroom", async () => {
  const { gateway, execs } = makeGatewayWithCmds(restHandler(5_000, 4_000));
  await gateway.refresh();
  const res = await gateway.prForBranch("/repo", "feature");
  assert.equal(res.kind, "pr");
  assert.equal(
    execs.some((e) => e.args[0] === "pr" && e.args[1] === "list"),
    true,
    "graphql is ~9x cheaper in relative headroom; do not pay the 4x REST path",
  );
});

test("resolves owner/repo from git, spending no GitHub quota", async () => {
  const { gateway, execs } = makeGatewayWithCmds(restHandler(5_000, 1_000));
  await gateway.refresh();
  const before = gateway.stats().execs;
  await gateway.prForBranch("/repo", "feature");
  const gitCalls = execs.filter((e) => e.cmd === "git");
  assert.equal(gitCalls.length, 1, "one local remote read");
  assert.deepEqual(gitCalls[0].args, ["remote", "get-url", "origin"]);
  const ghCalls = execs.filter((e) => e.cmd === "gh").length;
  assert.equal(gateway.stats().execs - before + 1, ghCalls, "stats counts gh (quota) calls only");
});

test("a failed REST step yields unknown, never none", async () => {
  // Regression guard for the missing-pill bug on the fallback path: the PR
  // demonstrably exists (the list succeeded), so reporting "no PR" would erase
  // a live pill.
  const { gateway, execs } = makeGatewayWithCmds((cmd, args) => {
    if (cmd === "git") return ok("https://github.com/o/r.git");
    const path = args[1] ?? "";
    if (path === "rate_limit") return ok(rateLimitJson(5_000, 1_000));
    if (path.includes("/pulls?head=")) return ok(REST_LIST);
    return fail("HTTP 403: API rate limit exceeded");
  });
  await gateway.refresh();
  const res = await gateway.prForBranch("/repo", "feature");
  assert.equal(
    execs.some((e) => /\/pulls\/\d+$/.test(e.args[1] ?? "")),
    true,
    "the REST path must actually have been taken, or this proves nothing",
  );
  assert.equal(res.kind, "unknown");
  if (res.kind === "unknown") assert.equal(res.reason, "throttled");
});

test("falls back to GraphQL when the repo has no GitHub remote", async () => {
  // No slug means no REST path at all; better to try the starved primary than
  // to report a lookup failure we have not actually attempted.
  const { gateway, execs } = makeGatewayWithCmds((cmd, args) => {
    if (cmd === "git") return ok("/srv/git/local.git");
    if ((args[1] ?? "") === "rate_limit") return ok(rateLimitJson(5_000, 1_000));
    if (args[0] === "pr") return ok(PR_JSON);
    return fail("unexpected");
  });
  await gateway.refresh();
  const res = await gateway.prForBranch("/repo", "feature");
  assert.equal(res.kind, "pr");
  assert.equal(execs.some((e) => e.args[0] === "pr" && e.args[1] === "list"), true);
});

// ── unresolvedUnknown: honesty about a shed count (spec §6.5, T6) ─────────────

test("unresolvedUnknown is false when the count was actually fetched", async () => {
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") return ok(rateLimitJson(5000, 5000));
    if (kindOf(args) === "threads") return ok(THREADS_JSON);
    return ok(PR_JSON);
  });
  // Healthy budget ⇒ policy.includeUnresolved is true ⇒ the threads query runs.
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "br", { interactive: true });
  assert.equal(r.kind, "pr");
  assert.equal(r.kind === "pr" && r.pr.unresolvedComments, 0);
  assert.equal(r.kind === "pr" && r.pr.unresolvedUnknown, false, "a measured count is not unknown");
});

test("unresolvedUnknown is true when the count was shed to save quota", async () => {
  let threadsExecs = 0;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "threads") threadsExecs += 1;
    return ok(PR_JSON);
  });
  // No refresh ⇒ level 'unknown' ⇒ policy sheds unresolved (poll ≠ fast rung),
  // so the field is never fetched and the reported 0 is not a fact.
  const r = await gateway.prForBranch("/repo", "br");
  assert.equal(r.kind, "pr");
  assert.equal(r.kind === "pr" && r.pr.unresolvedUnknown, true, "a shed count must be flagged unknown");
  assert.equal(threadsExecs, 0, "the review-threads query must not run when shed");
});

// ── the PR picker is user-initiated, so it draws on the reserve ────────────────

/** A rate_limit body whose hourly buckets sit BELOW the 300 reserve floor. */
function starvedRateLimitJson(): string {
  return JSON.stringify({
    resources: {
      core: { limit: 5000, remaining: 120, reset: 9e9 },
      graphql: { limit: 5000, remaining: 120, reset: 9e9 },
    },
  });
}

test("openPrs marked interactive still runs below the reserve floor", async () => {
  // The "New worktree from PR" picker is a click, not a poller. Spec §6.3: an
  // interactive request bypasses the ladder and may draw on the reserve, because
  // a throttled account is exactly when the user reaches for the picker — and a
  // silently empty list reads as "this repo has no open PRs", which is a lie.
  const { gateway, calls } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(starvedRateLimitJson()) : ok(JSON.stringify([{ number: 3 }])),
  );
  await gateway.refresh();
  const prs = await gateway.openPrs("/repo", 50, { interactive: true });
  assert.equal(prs.length, 1, "an interactive picker must not be starved");
  assert.equal(
    calls.some((a) => a[0] === "pr" && a[1] === "list"),
    true,
    "the list must actually have been fetched",
  );
});

test("openPrs left as background is withheld below the reserve floor", async () => {
  const { gateway } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(starvedRateLimitJson()) : ok(JSON.stringify([{ number: 3 }])),
  );
  await gateway.refresh();
  assert.deepEqual(await gateway.openPrs("/repo", 50), [], "background work respects the reserve");
});

test("the concurrency gate admits waiters up to the NEW limit when it grows", async () => {
  // The gate's limit is dynamic: 6 normally, 2 under a secondary (burst) limit.
  // When the limit grows back, parked waiters must be admitted up to the new cap
  // — waking exactly one per release would leave the recovered headroom unused
  // and keep throughput throttled after the throttle is gone.
  let limit = 2;
  const gate = new ConcurrencyGate(() => limit);
  let active = 0;
  let peak = 0;
  const hold: Array<() => void> = [];

  const start = (): Promise<void> =>
    gate.acquire().then(() => {
      active += 1;
      peak = Math.max(peak, active);
      return new Promise<void>((release) => {
        hold.push(() => {
          active -= 1;
          gate.release();
          release();
        });
      });
    });

  const running = Array.from({ length: 6 }, start);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(peak, 2, "the throttled cap is honoured while it is in force");

  // The burst limit clears: releasing ONE holder must admit the rest, not one.
  limit = 6;
  hold.shift()!();
  await Promise.resolve();
  await Promise.resolve();
  assert.ok(peak > 2, `expected >2 concurrent once the limit grew, saw ${peak}`);

  while (hold.length) hold.shift()!();
  await Promise.all(running);
});

// ── a partial page count is not a measured count (§6.5) ───────────────────────

/** Two-page review-thread response; the caller must fetch both to know the total. */
const THREADS_PAGE_1 = JSON.stringify({
  data: {
    repository: {
      pullRequest: {
        reviewThreads: {
          pageInfo: { hasNextPage: true, endCursor: "cur" },
          nodes: [{ isResolved: false }, { isResolved: false }],
        },
      },
    },
  },
});

test("a mid-pagination failure marks the count unmeasured, not partial", async () => {
  // Page 1 finds 2 unresolved threads and says there are more; page 2 is
  // throttled. Reporting "2" would present a partial tally as fact — the pill
  // would show a confident wrong number, which is the null-vs-zero hazard
  // SPEC-32 §6.5 exists to prevent.
  let threadPages = 0;
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") return ok(rateLimitJson(5_000, 5_000));
    if (kindOf(args) === "threads") {
      threadPages += 1;
      return threadPages === 1 ? ok(THREADS_PAGE_1) : fail("HTTP 403: API rate limit exceeded");
    }
    return ok(PR_JSON);
  });
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "br");
  assert.equal(r.kind, "pr");
  if (r.kind !== "pr") return;
  assert.equal(r.pr.unresolvedUnknown, true, "a partial tally must be flagged unmeasured");
});

test("an unparseable review-thread page marks the count unmeasured", async () => {
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") return ok(rateLimitJson(5_000, 5_000));
    if (kindOf(args) === "threads") return ok("{not json");
    return ok(PR_JSON);
  });
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "br");
  assert.equal(r.kind === "pr" && r.pr.unresolvedUnknown, true);
});

test("an interactive call is not served by a shed background lookup", async () => {
  // The dedupe key must distinguish the two: below the reserve a background
  // lookup resolves to `unknown` (shed), and an interactive caller joining that
  // promise would inherit the shed answer instead of drawing on the reserve —
  // silently undoing the guarantee in §6.3.
  const { gateway } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(starvedRateLimitJson()) : ok(PR_JSON),
  );
  await gateway.refresh();
  const background = gateway.prForBranch("/repo", "br");
  const interactive = gateway.prForBranch("/repo", "br", { interactive: true });
  const [bg, ia] = await Promise.all([background, interactive]);
  assert.equal(bg.kind, "unknown", "background work is shed below the reserve");
  assert.equal(ia.kind, "pr", "the interactive caller must still get a real answer");
});

// ── the PR picker must survive an exhausted graphql bucket ─────────────────────

/** `gh api rate_limit` with graphql spent and REST untouched (observed live). */
function graphqlDryJson(): string {
  return JSON.stringify({
    resources: {
      core: { limit: 5000, remaining: 4999, reset: 9e9 },
      graphql: { limit: 5000, remaining: 0, reset: 9e9 },
    },
  });
}

/** REST list-pulls payload for the picker. */
const REST_OPEN_PRS = JSON.stringify([
  { number: 12, title: "t", draft: false, html_url: "https://github.com/o/r/pull/12", head: { ref: "feature/x" } },
]);

test("openPrs falls over to REST when graphql is dry", async () => {
  // `gh pr list --json` is GraphQL-backed, so with graphql at 0 the picker used
  // to spend a doomed call and return [] -- which the user reads as "this repo
  // has no open PRs". Listing PRs is plain REST, so there is no reason to fail.
  const { gateway, execs } = makeGatewayWithCmds((cmd, args) => {
    if (cmd === "git") return ok("git@github.com:o/r.git\n");
    const path = args[1] ?? "";
    if (path === "rate_limit") return ok(graphqlDryJson());
    if (path.startsWith("/repos/o/r/pulls?")) return ok(REST_OPEN_PRS);
    if (args[0] === "pr") return fail("HTTP 403: API rate limit exceeded");
    return fail("unexpected");
  });
  await gateway.refresh();
  const prs = await gateway.openPrs("/repo", 50, { interactive: true });
  assert.equal(prs.length, 1, "the picker must still list PRs over REST");
  assert.equal(prs[0].number, 12);
  assert.equal(prs[0].headRefName, "feature/x", "REST head.ref maps to headRefName");
  assert.equal(prs[0].url, "https://github.com/o/r/pull/12");
  assert.equal(
    execs.some((e) => e.args[0] === "pr" && e.args[1] === "list"),
    false,
    "must not spend the dry graphql bucket",
  );
});

test("openPrs stays on graphql while it has headroom", async () => {
  const { gateway, execs } = makeGatewayWithCmds((cmd, args) => {
    if (cmd === "git") return ok("git@github.com:o/r.git\n");
    if ((args[1] ?? "") === "rate_limit") return ok(rateLimitJson(5_000, 5_000));
    if (args[0] === "pr") return ok(JSON.stringify([{ number: 3 }]));
    return fail("unexpected");
  });
  await gateway.refresh();
  await gateway.openPrs("/repo", 50);
  assert.equal(execs.some((e) => e.args[0] === "pr" && e.args[1] === "list"), true);
});

test("the budget names the REST path while PR status is routed there", async () => {
  // The balancing is otherwise invisible: the user sees graphql draining, then
  // stopping, with no indication that PR status is still flowing over REST.
  const { gateway } = makeGatewayWithCmds(restHandler(5_000, 1_000));
  await gateway.refresh();
  assert.equal(
    gateway.budget().throttles.some((t) => /REST/i.test(t)),
    false,
    "nothing to say before any lookup has been routed",
  );
  await gateway.prForBranch("/repo", "feature");
  assert.ok(
    gateway.budget().throttles.some((t) => /PR status via REST/i.test(t)),
    `expected a REST-routing note, got ${JSON.stringify(gateway.budget().throttles)}`,
  );
});

test("the budget says nothing about REST while graphql is serving", async () => {
  const { gateway } = makeGatewayWithCmds(restHandler(5_000, 4_000));
  await gateway.refresh();
  await gateway.prForBranch("/repo", "feature");
  assert.equal(
    gateway.budget().throttles.some((t) => /REST/i.test(t)),
    false,
  );
});

// ── CodeRabbit review findings ─────────────────────────────────────────────────

test("flipping to the REST path broadcasts a budget change", async () => {
  // #3: budget() composes the "PR status via REST" throttle, but emitIfChanged
  // compared raw tracker snapshots -- so the composed throttle never entered the
  // change signature and no event fired when routing flipped. Subscribers kept
  // the old throttle list until some unrelated level change, meaning the UI
  // reported the wrong routing state: exactly the information the throttle
  // exists to convey.
  const { gateway } = makeGatewayWithCmds(restHandler(5_000, 1_000));
  const seen: string[][] = [];
  gateway.onBudgetChange((s) => seen.push(s.throttles));
  await gateway.refresh();
  await gateway.prForBranch("/repo", "feature");
  assert.ok(
    seen.some((t) => t.some((x) => /PR status via REST/i.test(x))),
    `expected a broadcast naming the REST route, saw ${JSON.stringify(seen)}`,
  );
});

test("a repo with no GitHub remote does not claim REST routing", async () => {
  // #6: routeFor persisted the choice BEFORE checking whether the REST path was
  // usable. With no GitHub remote the code proceeds over GraphQL, yet the stored
  // choice stayed "fallback" -- so budget() advertised a REST route that never
  // happened, and hysteresis was seeded with a path that cannot be used.
  const { gateway } = makeGatewayWithCmds((cmd, args) => {
    if (cmd === "git") return ok("/srv/git/local.git"); // not a GitHub remote
    if ((args[1] ?? "") === "rate_limit") return ok(rateLimitJson(5_000, 1_000));
    if (args[0] === "pr") return ok(PR_JSON);
    return fail("unexpected");
  });
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "feature");
  assert.equal(r.kind, "pr", "the GraphQL primary still serves the lookup");
  assert.equal(
    gateway.budget().throttles.some((t) => /REST/i.test(t)),
    false,
    "must not advertise a route it could not take",
  );
});

test("an unparseable PR url leaves the comment count unmeasured", async () => {
  // #4: parsePrUrl fails for any non-github.com host (GitHub Enterprise), and
  // returning 0 reported "no unresolved comments" as fact although no query ever
  // ran -- the null-versus-zero hazard this file documents.
  const ENTERPRISE_PR = JSON.stringify([
    {
      number: 7,
      url: "https://github.example.com/o/r/pull/7",
      state: "OPEN",
      title: "t",
      isDraft: false,
      mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN",
      statusCheckRollup: [],
    },
  ]);
  const { gateway } = makeGateway((args) =>
    kindOf(args) === "rate_limit" ? ok(rateLimitJson(5_000, 5_000)) : ok(ENTERPRISE_PR),
  );
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "br");
  assert.equal(r.kind === "pr" && r.pr.unresolvedUnknown, true);
});

test("exhausting the review-thread page cap leaves the count unmeasured", async () => {
  // #5: after REVIEW_THREADS_MAX_PAGES with hasNextPage still true the tally is
  // partial, yet it was cached and returned as measured -- disagreeing with the
  // mid-pagination failure path, which correctly reports unmeasured.
  const NEVER_ENDING = JSON.stringify({
    data: {
      repository: {
        pullRequest: {
          reviewThreads: {
            pageInfo: { hasNextPage: true, endCursor: "next" },
            nodes: [{ isResolved: false }],
          },
        },
      },
    },
  });
  const { gateway } = makeGateway((args) => {
    if (kindOf(args) === "rate_limit") return ok(rateLimitJson(5_000, 5_000));
    if (kindOf(args) === "threads") return ok(NEVER_ENDING);
    return ok(PR_JSON);
  });
  await gateway.refresh();
  const r = await gateway.prForBranch("/repo", "br");
  assert.equal(r.kind === "pr" && r.pr.unresolvedUnknown, true);
});

test("the exempt rate_limit read is counted separately from quota spend", async () => {
  // #2: stats.execs was used for the >=80% reduction claim while also counting
  // the quota-EXEMPT rate_limit read, which forced call-reduction arithmetic to
  // subtract it by hand and made a test assert an invariant that was not true.
  const { gateway, execs } = makeGatewayWithCmds(restHandler(5_000, 1_000));
  await gateway.refresh();
  assert.equal(gateway.stats().execs, 0, "an exempt read spends no quota");
  assert.equal(gateway.stats().exemptExecs, 1);

  await gateway.prForBranch("/repo", "feature");
  assert.equal(gateway.stats().exemptExecs, 1, "no further exempt reads");
  // graphql is the worse buy here, so this takes the 4-call REST path.
  assert.equal(gateway.stats().execs, 4, "the four REST calls, and nothing else");
  // The local `git remote` read is a subprocess but costs no GitHub quota, so it
  // must not inflate either counter.
  assert.equal(execs.filter((e) => e.cmd === "git").length, 1, "git was consulted");
});
