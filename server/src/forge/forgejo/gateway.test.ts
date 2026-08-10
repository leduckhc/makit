import { test } from "node:test";
import assert from "node:assert/strict";

import { createForgejoGateway, type Http, type HttpRequest, type ForgejoRepoRef } from "./gateway.js";

const REF: ForgejoRepoRef = {
  baseUrl: "https://git.example.com",
  owner: "acme",
  repo: "app",
  token: "t0ken",
};

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
  timeoutMs: number;
}

/** Build a gateway over a scripted HTTP seam. Routes are matched by substring. */
function harness(routes: Array<[string, { status?: number; json?: unknown; body?: string }]>, ref = REF) {
  const calls: Call[] = [];
  const http: Http = async (req: HttpRequest) => {
    calls.push({ url: req.url, method: req.method, headers: req.headers, body: req.body, timeoutMs: req.timeoutMs });
    for (const [needle, res] of routes) {
      if (req.url.includes(needle)) {
        return {
          status: res.status ?? 200,
          body: res.body ?? JSON.stringify(res.json ?? null),
        };
      }
    }
    return { status: 404, body: '{"message":"not found"}' };
  };
  let nowMs = 1_000;
  const gateway = createForgejoGateway({
    http,
    resolveRepo: async () => ref,
    now: () => nowMs,
  });
  return { gateway, calls, tick: (ms: number) => (nowMs += ms) };
}

const openPrRow = {
  number: 42,
  state: "open",
  merged: false,
  title: "feat: thing",
  draft: false,
  mergeable: true,
  html_url: "https://git.example.com/acme/app/pulls/42",
  base: { ref: "main" },
  head: { ref: "feat/x", sha: "cafebabe" },
};

// ---------------------------------------------------------------------------
// prForBranch
// ---------------------------------------------------------------------------

test("prForBranch returns the PR with checks composed from the combined status", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { state: "failure", statuses: [{ context: "test", status: "failure" }] } }],
  ]);
  const got = await gateway.prForBranch("/repo", "feat/x");
  assert.equal(got.kind, "pr");
  if (got.kind !== "pr") return;
  assert.equal(got.pr.number, 42);
  assert.equal(got.pr.state, "OPEN");
  assert.equal(got.pr.mergeable, "MERGEABLE");
  assert.equal(got.pr.mergeStateStatus, null);
  assert.equal(got.pr.checkRollup, "fail");
  assert.deepEqual(
    got.pr.checks.map((c) => c.name),
    ["test"],
  );
  // The head filter must be the bare branch name.
  assert.ok(calls[0].url.includes("head=feat%2Fx"));
  assert.ok(!calls[0].url.includes("acme%3Afeat"));
});

test("prForBranch sends the token as a Forgejo `token` credential", async () => {
  const { gateway, calls } = harness([["/pulls?", { json: [] }]]);
  await gateway.prForBranch("/repo", "b");
  assert.equal(calls[0].headers.Authorization, "token t0ken");
});

test("prForBranch omits Authorization entirely when there is no token", async () => {
  const { gateway, calls } = harness([["/pulls?", { json: [] }]], { ...REF, token: undefined });
  await gateway.prForBranch("/repo", "b");
  assert.equal("Authorization" in calls[0].headers, false);
});

test("prForBranch returns none only for a genuinely empty result", async () => {
  const { gateway } = harness([["/pulls?", { json: [] }]]);
  assert.deepEqual(await gateway.prForBranch("/repo", "b"), { kind: "none" });
});

test("prForBranch reports unknown -- never none -- on a transport failure", async () => {
  const { gateway } = harness([["/pulls?", { status: 0, body: "" }]]);
  assert.deepEqual(await gateway.prForBranch("/repo", "b"), { kind: "unknown", reason: "error" });
});

test("prForBranch reports unknown on a 5xx and on unparseable JSON", async () => {
  const a = harness([["/pulls?", { status: 500, body: "boom" }]]);
  assert.deepEqual(await a.gateway.prForBranch("/repo", "b"), { kind: "unknown", reason: "error" });
  const b = harness([["/pulls?", { body: "<html>not json</html>" }]]);
  assert.deepEqual(await b.gateway.prForBranch("/repo", "b"), { kind: "unknown", reason: "error" });
});

test("prForBranch reports unknown when the repo has no Forgejo remote", async () => {
  const http: Http = async () => ({ status: 200, body: "[]" });
  const gateway = createForgejoGateway({ http, resolveRepo: async () => null });
  assert.deepEqual(await gateway.prForBranch("/repo", "b"), { kind: "unknown", reason: "error" });
});

test("prForBranch picks the highest-numbered PR, not the first row", async () => {
  const { gateway } = harness([
    [
      "/pulls?",
      {
        json: [
          { ...openPrRow, number: 7, state: "closed", merged: false, head: { ref: "b", sha: "aa" } },
          { ...openPrRow, number: 99, state: "open", head: { ref: "b", sha: "bb" } },
        ],
      },
    ],
    ["/commits/bb/status", { json: { statuses: [] } }],
  ]);
  const got = await gateway.prForBranch("/repo", "b");
  assert.equal(got.kind === "pr" && got.pr.number, 99);
  assert.equal(got.kind === "pr" && got.pr.state, "OPEN");
});

test("prForBranch still returns the PR when the status call fails, with checks unmeasured", async () => {
  const { gateway } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { status: 500, body: "nope" }],
  ]);
  const got = await gateway.prForBranch("/repo", "b");
  assert.equal(got.kind, "pr");
  if (got.kind !== "pr") return;
  // A PR we found must not vanish because CI could not be read.
  assert.deepEqual(got.pr.checks, []);
  assert.equal(got.pr.checkRollup, "none");
});

test("prForBranch marks unresolved comments as unmeasured rather than reporting zero", async () => {
  const { gateway } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  const got = await gateway.prForBranch("/repo", "b");
  assert.equal(got.kind === "pr" && got.pr.unresolvedUnknown, true);
  assert.equal(got.kind === "pr" && got.pr.unresolvedComments, 0);
});

test("prForBranch skips the status call when the PR reports no head sha", async () => {
  const { gateway, calls } = harness([["/pulls?", { json: [{ ...openPrRow, head: { ref: "b" } }] }]]);
  const got = await gateway.prForBranch("/repo", "b");
  assert.equal(got.kind, "pr");
  assert.equal(calls.length, 1);
});

// Forgejo's `head` filter is an unindexed scan: measured against codeberg.org
// (~9.5k PRs) `state=all&head=X` is bimodal at 1.5s or 20-30s, while the combined
// status read stays sub-second. A single timeout for both would either abandon
// good lookups or hold a fast call open far too long -- and abandoning a lookup
// reports `unknown`, which flickers the pill.
test("the branch lookup gets a longer timeout than the sub-second status read", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  await gateway.prForBranch("/repo", "b");
  const list = calls.find((c) => c.url.includes("/pulls?"));
  const status = calls.find((c) => c.url.includes("/status"));
  assert.ok(list && status);
  assert.ok(
    list.timeoutMs >= 15_000,
    `branch lookup timeout ${list.timeoutMs}ms is below the observed p90 of the unindexed scan`,
  );
  assert.ok(status.timeoutMs < list.timeoutMs);
});

// ---------------------------------------------------------------------------
// Caching
// ---------------------------------------------------------------------------

test("prForBranch serves a repeat poll from cache and counts the hit", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  await gateway.prForBranch("/repo", "b");
  const n = calls.length;
  await gateway.prForBranch("/repo", "b");
  assert.equal(calls.length, n, "second poll should not hit the network");
  assert.equal(gateway.stats().cacheHits, 1);
});

test("an interactive call bypasses the cache", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  await gateway.prForBranch("/repo", "b");
  const n = calls.length;
  await gateway.prForBranch("/repo", "b", { interactive: true });
  assert.ok(calls.length > n);
});

test("a failed lookup is not cached, so the next poll retries", async () => {
  const { gateway, calls } = harness([["/pulls?", { status: 500, body: "x" }]]);
  await gateway.prForBranch("/repo", "b");
  await gateway.prForBranch("/repo", "b");
  assert.equal(calls.length, 2);
});

test("the cache expires", async () => {
  const { gateway, calls, tick } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  await gateway.prForBranch("/repo", "b");
  const n = calls.length;
  tick(120_000);
  await gateway.prForBranch("/repo", "b");
  assert.ok(calls.length > n);
});

// ---------------------------------------------------------------------------
// openPrs
// ---------------------------------------------------------------------------

test("openPrs maps rows and orders them newest-first regardless of server order", async () => {
  const { gateway } = harness([
    [
      "/pulls?",
      {
        json: [
          { number: 3, title: "c", draft: false, html_url: "u3", head: { ref: "b3" } },
          { number: 51, title: "a", draft: true, html_url: "u51", head: { ref: "b51" } },
          { number: 12, title: "b", draft: false, html_url: "u12", head: { ref: "b12" } },
        ],
      },
    ],
  ]);
  const prs = await gateway.openPrs("/repo", 30);
  assert.deepEqual(
    prs.map((p) => p.number),
    [51, 12, 3],
  );
  assert.deepEqual(prs[0], { number: 51, title: "a", headRefName: "b51", isDraft: true, url: "u51" });
});

test("openPrs returns an empty list on failure rather than throwing", async () => {
  const { gateway } = harness([["/pulls?", { status: 500, body: "x" }]]);
  assert.deepEqual(await gateway.openPrs("/repo", 30), []);
});

// ---------------------------------------------------------------------------
// mutatePr — `ready` is a title rewrite on Forgejo, not a flag flip.
// ---------------------------------------------------------------------------

test("mutatePr ready re-reads the title and PATCHes it with the prefix stripped", async () => {
  const { gateway, calls } = harness([
    ["/pulls/42", { json: { number: 42, title: "WIP: feat: thing", state: "open" } }],
  ]);
  const res = await gateway.mutatePr("/repo", "b", 42, "ready");
  assert.equal(res.ok, true);
  const patch = calls.find((c) => c.method === "PATCH");
  assert.ok(patch, "expected a PATCH");
  assert.deepEqual(JSON.parse(patch.body ?? "{}"), { title: "feat: thing" });
});

test("mutatePr ready refuses when the title carries no known draft prefix", async () => {
  const { gateway, calls } = harness([["/pulls/42", { json: { number: 42, title: "feat: thing" } }]]);
  const res = await gateway.mutatePr("/repo", "b", 42, "ready");
  assert.equal(res.ok, false);
  assert.match(res.error ?? "", /draft/i);
  assert.equal(
    calls.some((c) => c.method === "PATCH"),
    false,
    "must not rewrite a title it did not recognise",
  );
});

test("mutatePr ready honours a server's configured WIP prefixes", async () => {
  const http: Http = async (req) => {
    if (req.method === "GET") return { status: 200, body: JSON.stringify({ number: 1, title: "Draft: x" }) };
    return { status: 200, body: "{}" };
  };
  const gateway = createForgejoGateway({
    http,
    resolveRepo: async () => REF,
    wipPrefixes: ["Draft:"],
  });
  assert.equal((await gateway.mutatePr("/repo", "b", 1, "ready")).ok, true);
});

test("mutatePr update-branch POSTs to /update with an explicit style", async () => {
  const { gateway, calls } = harness([["/update", { json: {} }]]);
  const res = await gateway.mutatePr("/repo", "b", 42, "update-branch");
  assert.equal(res.ok, true);
  assert.equal(calls[0].method, "POST");
  assert.ok(calls[0].url.includes("/pulls/42/update"));
  assert.ok(calls[0].url.includes("style=merge"));
});

test("mutatePr merge-squash POSTs the PascalCase Do field Forgejo requires", async () => {
  const { gateway, calls } = harness([["/merge", { json: {} }]]);
  const res = await gateway.mutatePr("/repo", "b", 42, "merge-squash");
  assert.equal(res.ok, true);
  assert.deepEqual(JSON.parse(calls[0].body ?? "{}"), { Do: "squash" });
});

test("mutatePr surfaces the server's own error message", async () => {
  const { gateway } = harness([["/update", { status: 409, json: { message: "merge conflict" } }]]);
  const res = await gateway.mutatePr("/repo", "b", 42, "update-branch");
  assert.equal(res.ok, false);
  assert.match(res.error ?? "", /merge conflict/);
});

test("a successful mutation invalidates the cached lookup for that branch", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
    ["/update", { json: {} }],
  ]);
  await gateway.prForBranch("/repo", "b");
  await gateway.mutatePr("/repo", "b", 42, "update-branch");
  const n = calls.length;
  await gateway.prForBranch("/repo", "b");
  assert.ok(calls.length > n, "post-mutation poll must refetch, not serve stale state");
});

test("a failed mutation leaves the cache intact", async () => {
  const { gateway, calls } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
    ["/update", { status: 500, body: "x" }],
  ]);
  await gateway.prForBranch("/repo", "b");
  await gateway.mutatePr("/repo", "b", 42, "update-branch");
  const n = calls.length;
  await gateway.prForBranch("/repo", "b");
  assert.equal(calls.length, n);
});

// ---------------------------------------------------------------------------
// Contract: no budget facet, because Forgejo has no quota to report.
// ---------------------------------------------------------------------------

test("the Forgejo gateway does not pretend to report a budget", async () => {
  const { gateway } = harness([]);
  const { hasBudgetReporting } = await import("../types.js");
  assert.equal(hasBudgetReporting(gateway), false);
});

test("stats counts network calls and close() is safe to call twice", async () => {
  const { gateway } = harness([
    ["/pulls?", { json: [openPrRow] }],
    ["/commits/cafebabe/status", { json: { statuses: [] } }],
  ]);
  await gateway.prForBranch("/repo", "b");
  assert.equal(gateway.stats().execs, 2);
  gateway.close();
  gateway.close();
});
