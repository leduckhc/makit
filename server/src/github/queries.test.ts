import { test } from "node:test";
import assert from "node:assert/strict";

import {
  PR_FOR_BRANCH_PLAN,
  UNRESOLVED_THREADS_PLAN,
  OPEN_PRS_PLAN,
  prForBranchArgv,
  prForBranchRestArgv,
  unresolvedThreadsArgv,
  openPrsArgv,
  openPrsRestArgv,
  checkRunsRestArgv,
  combinedStatusRestArgv,
  prDetailRestArgv,
  restOpenPr,
  rateLimitArgv,
  parsePrUrl,
  parseRemoteSlug,
  restMergeable,
  restChecksToRollup,
  REVIEW_THREADS_PAGE_SIZE,
} from "./queries.js";

test("prForBranch plan is graphql-primary with a ~4x core REST fallback", () => {
  assert.deepEqual(PR_FOR_BRANCH_PLAN.primary, { bucket: "graphql", units: 1 });
  assert.deepEqual(PR_FOR_BRANCH_PLAN.fallback, { bucket: "core", units: 4 });
  assert.equal(PR_FOR_BRANCH_PLAN.degraded, undefined);
});

test("unresolvedThreads plan is graphql-only and omits when starved", () => {
  assert.deepEqual(UNRESOLVED_THREADS_PLAN.primary, { bucket: "graphql", units: 1 });
  assert.equal(UNRESOLVED_THREADS_PLAN.fallback, undefined);
  assert.equal(UNRESOLVED_THREADS_PLAN.degraded, "omit");
});

test("openPrs plan has a REST fallback that costs the same as the primary", () => {
  // The picker's fallback is ONE core call, unlike prForBranch's four: listing
  // PRs is a plain REST endpoint and the picker needs no mergeability or check
  // rollup. Being equally cheap, there is no reason for a dry graphql bucket to
  // leave the picker empty -- which the user would read as "no open PRs".
  assert.deepEqual(OPEN_PRS_PLAN.primary, { bucket: "graphql", units: 1 });
  assert.deepEqual(OPEN_PRS_PLAN.fallback, { bucket: "core", units: 1 });
});

test("openPrsRestArgv lists open PRs newest-first, matching gh pr list", () => {
  const argv = openPrsRestArgv("o", "r", 50);
  assert.equal(argv[0], "api");
  assert.match(argv[1], /^\/repos\/o\/r\/pulls\?/);
  assert.match(argv[1], /state=open/);
  assert.match(argv[1], /per_page=50/);
  // The picker relies on newest-first ordering.
  assert.match(argv[1], /sort=created/);
  assert.match(argv[1], /direction=desc/);
});

test("restOpenPr maps REST's nested head.ref and html_url", () => {
  assert.deepEqual(
    restOpenPr({
      number: 7,
      title: "t",
      draft: true,
      html_url: "https://github.com/o/r/pull/7",
      head: { ref: "feature/x" },
    }),
    {
      number: 7,
      title: "t",
      headRefName: "feature/x",
      isDraft: true,
      url: "https://github.com/o/r/pull/7",
    },
  );
  assert.equal(restOpenPr({ title: "no number" }), null);
  assert.equal(restOpenPr(null), null);
  // A missing head ref yields "" rather than dropping the row: the picker still
  // shows the PR, it just cannot pre-fill a branch name.
  assert.equal(restOpenPr({ number: 1 })?.headRefName, "");
});

test("prForBranchArgv preserves the git.ts json field set and --head/--limit", () => {
  const argv = prForBranchArgv("feature/x");
  assert.deepEqual(argv, [
    "pr",
    "list",
    "--head",
    "feature/x",
    "--state",
    "all",
    "--json",
    "number,url,state,title,isDraft,mergeable,mergeStateStatus,statusCheckRollup",
    "--limit",
    "1",
  ]);
});

test("prForBranchRestArgv targets the repo pulls endpoint filtered by head", () => {
  assert.deepEqual(prForBranchRestArgv("o", "r", "br"), [
    "api",
    "/repos/o/r/pulls?head=o:br&state=all&per_page=1&sort=created&direction=desc",
  ]);
});

test("unresolvedThreadsArgv pages with the 100/page connection query", () => {
  const first = unresolvedThreadsArgv("o", "r", 7);
  assert.equal(first[0], "api");
  assert.equal(first[1], "graphql");
  assert.ok(first.some((a) => a.includes("reviewThreads(first:100")));
  assert.ok(!first.some((a) => a.startsWith("after=")));
  assert.equal(REVIEW_THREADS_PAGE_SIZE, 100);

  const next = unresolvedThreadsArgv("o", "r", 7, "CURSOR");
  assert.ok(next.includes("after=CURSOR"));
});

test("openPrsArgv lists open PRs with the picker json fields and limit", () => {
  assert.deepEqual(openPrsArgv(25), [
    "pr",
    "list",
    "--state",
    "open",
    "--json",
    "number,title,headRefName,isDraft,url",
    "--limit",
    "25",
  ]);
});

test("rateLimitArgv is the exempt rate_limit read", () => {
  assert.deepEqual(rateLimitArgv(), ["api", "rate_limit"]);
});

test("parsePrUrl extracts owner/repo/number, null when unparseable", () => {
  assert.deepEqual(parsePrUrl("https://github.com/o/r/pull/42"), {
    owner: "o",
    repo: "r",
    number: "42",
  });
  assert.equal(parsePrUrl("not a url"), null);
});

// ── REST fallback helpers (spec §4 / §6.2) ────────────────────────────────────

test("parseRemoteSlug handles the SSH and HTTPS remote forms", () => {
  assert.deepEqual(parseRemoteSlug("git@github.com:owner/repo.git"), { owner: "owner", repo: "repo" });
  assert.deepEqual(parseRemoteSlug("https://github.com/owner/repo.git\n"), { owner: "owner", repo: "repo" });
  assert.deepEqual(parseRemoteSlug("https://github.com/owner/repo"), { owner: "owner", repo: "repo" });
  assert.equal(parseRemoteSlug("/srv/git/local.git"), null, "a non-GitHub remote has no REST path");
  assert.equal(parseRemoteSlug("git@gitlab.com:owner/repo.git"), null);
});

test("restMergeable maps REST's boolean onto the GraphQL vocabulary", () => {
  // The DTO already speaks GraphQL's words, so both paths must be
  // indistinguishable downstream. REST null = 'not computed yet' = UNKNOWN.
  assert.equal(restMergeable(true), "MERGEABLE");
  assert.equal(restMergeable(false), "CONFLICTING");
  assert.equal(restMergeable(null), "UNKNOWN");
  assert.equal(restMergeable(undefined), "UNKNOWN");
});

test("restChecksToRollup upper-cases REST's lowercase enums", () => {
  // git.ts's bucketForRollupEntry compares status against "COMPLETED" verbatim,
  // so a raw lowercase "completed" would classify a finished build as pending.
  const out = restChecksToRollup(
    { check_runs: [{ name: "test", status: "completed", conclusion: "success", details_url: "u" }] },
    { statuses: [{ context: "ci/legacy", state: "failure", target_url: "t" }] },
  ) as Array<Record<string, unknown>>;
  assert.equal(out.length, 2);
  assert.equal(out[0].status, "COMPLETED");
  assert.equal(out[0].conclusion, "SUCCESS");
  assert.equal(out[0].detailsUrl, "u");
  assert.equal(out[0].workflowName, null, "app.name is the provider, not the workflow");
  assert.equal(out[1].state, "FAILURE");
  assert.equal(out[1].targetUrl, "t");
});

test("restChecksToRollup tolerates missing and malformed payloads", () => {
  assert.deepEqual(restChecksToRollup(null, null), []);
  assert.deepEqual(restChecksToRollup({}, {}), []);
  assert.deepEqual(restChecksToRollup({ check_runs: "nope" }, { statuses: 3 }), []);
});

// ── REST path interpolation must be URL-safe (CodeRabbit #8) ───────────────────

test("prForBranchRestArgv percent-encodes the branch", () => {
  // Git permits `#`, `&` and `+` in ref names, all of which are meaningful in a
  // URL. Unencoded, `feature#1` truncates the query at the fragment and
  // `a&state=open` injects a second parameter -- the lookup then returns the
  // wrong PR or an empty list, which the gateway maps to `none` and which ERASES
  // THE PILL. That is the exact defect this spec exists to fix, so the fallback
  // path must not reintroduce it.
  const argv = prForBranchRestArgv("o", "r", "feature#1");
  // The colon separating owner from ref is legal unencoded in a query, so only
  // the parts are escaped -- keeping the common case readable.
  assert.match(argv[1], /head=o:feature%231/);
  assert.ok(!argv[1].includes("#"), "a raw # truncates the query string");

  const injected = prForBranchRestArgv("o", "r", "a&state=open");
  assert.ok(!injected[1].includes("a&state=open"), "a raw & injects a parameter");
  assert.match(injected[1], /state=all/);
  assert.equal(injected[1].match(/state=/g)?.length, 1, "exactly one state param");
});

test("the other REST builders encode their ref and slug segments", () => {
  // A ref can legitimately contain `+`, which decodes to a space if unencoded.
  assert.match(checkRunsRestArgv("o", "r", "a+b")[1], /a%2Bb/);
  assert.match(combinedStatusRestArgv("o", "r", "a+b")[1], /a%2Bb/);
  assert.match(prDetailRestArgv("o/x", "r", 7)[1], /o%2Fx/);
  assert.match(openPrsRestArgv("o", "r+s", 50)[1], /r%2Bs/);
});
