import { test } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_WIP_PREFIXES,
  PR_PAGE_SIZE,
  forgejoChecks,
  isEpochTimestamp,
  mapForgejoPr,
  parseForgejoRemote,
  pickLatestPr,
  prForBranchUrl,
  openPrsUrl,
  readyTitle,
  updateBranchUrl,
} from "./map.js";

// ---------------------------------------------------------------------------
// URL building. Forgejo's `head` filter takes a BARE branch name -- passing
// GitHub's `owner:branch` returns an empty list, which the gateway would map to
// `none` and erase the pill (the very defect SPEC-github-gateway-and-budget §6.5 exists to prevent).
// ---------------------------------------------------------------------------

test("prForBranchUrl filters by bare branch name, never owner:branch", () => {
  const u = new URL(prForBranchUrl("https://git.example.com", "acme", "app", "feat/x"));
  assert.equal(u.pathname, "/api/v1/repos/acme/app/pulls");
  assert.equal(u.searchParams.get("head"), "feat/x");
  assert.equal(u.searchParams.get("state"), "all");
});

test("prForBranchUrl percent-encodes refs that would otherwise inject query params", () => {
  const u = new URL(prForBranchUrl("https://git.example.com", "acme", "app", "a&state=closed"));
  assert.equal(u.searchParams.get("head"), "a&state=closed");
  assert.equal(u.searchParams.get("state"), "all");
});

test("prForBranchUrl requests a page, not limit=1, because order is not guaranteed", () => {
  const u = new URL(prForBranchUrl("https://git.example.com", "acme", "app", "b"));
  assert.ok(Number(u.searchParams.get("limit")) > 1);
  // Forgejo's sort enum has no created-desc, so we must not pretend to ask for one.
  assert.equal(u.searchParams.get("sort"), null);
  assert.equal(u.searchParams.get("direction"), null);
});

// Measured against codeberg.org (Forgejo 16, ~9.5k PRs): `state=all` combined with
// a `head` filter costs ~1.3s at limit=5 but 17-19s at limit=30, and 504s outright
// often enough to matter. The scan is unindexed, so this page size is a latency
// cliff on the hot path, not a tuning preference.
test("prForBranchUrl keeps the page small -- the head-filtered scan is unindexed", () => {
  assert.ok(PR_PAGE_SIZE >= 3, "too small to survive imperfect default ordering");
  assert.ok(PR_PAGE_SIZE <= 10, `page size ${PR_PAGE_SIZE} risks a multi-second or 504 hot path`);
  const u = new URL(prForBranchUrl("https://git.example.com", "acme", "app", "b"));
  assert.equal(u.searchParams.get("limit"), String(PR_PAGE_SIZE));
});

test("openPrsUrl asks only for open PRs and honours the caller's limit", () => {
  const u = new URL(openPrsUrl("https://git.example.com", "acme", "app", 30));
  assert.equal(u.searchParams.get("state"), "open");
  assert.equal(u.searchParams.get("limit"), "30");
});

test("updateBranchUrl targets the PR index with an explicit merge style", () => {
  const u = new URL(updateBranchUrl("https://git.example.com", "acme", "app", 7));
  assert.equal(u.pathname, "/api/v1/repos/acme/app/pulls/7/update");
  assert.equal(u.searchParams.get("style"), "merge");
});

// ---------------------------------------------------------------------------
// Hazard 3: no created-desc sort. `limit=1` is unsafe -- an older CLOSED PR
// could win the slot over a newer OPEN one and flip the glyph.
// ---------------------------------------------------------------------------

test("pickLatestPr takes the highest number regardless of arrival order", () => {
  const rows = [{ number: 3 }, { number: 91 }, { number: 12 }];
  assert.equal(pickLatestPr(rows)?.number, 91);
});

test("pickLatestPr returns null for an empty list", () => {
  assert.equal(pickLatestPr([]), null);
});

test("pickLatestPr ignores rows without a usable number", () => {
  const rows = [{ number: "nope" }, { number: 4 }, {}, null];
  assert.equal(pickLatestPr(rows)?.number, 4);
});

// ---------------------------------------------------------------------------
// PR mapping. Forgejo has no mergeStateStatus, and reports MERGED via a bool.
// ---------------------------------------------------------------------------

test("mapForgejoPr distinguishes MERGED from CLOSED via the merged flag", () => {
  const closed = mapForgejoPr({ number: 1, state: "closed", merged: false });
  const merged = mapForgejoPr({ number: 2, state: "closed", merged: true });
  assert.equal(closed?.state, "CLOSED");
  assert.equal(merged?.state, "MERGED");
});

test("mapForgejoPr upper-cases the open state", () => {
  assert.equal(mapForgejoPr({ number: 1, state: "open", merged: false })?.state, "OPEN");
});

test("mapForgejoPr maps mergeable onto the GraphQL vocabulary the DTO speaks", () => {
  assert.equal(mapForgejoPr({ number: 1, state: "open", mergeable: true })?.mergeable, "MERGEABLE");
  assert.equal(mapForgejoPr({ number: 1, state: "open", mergeable: false })?.mergeable, "CONFLICTING");
  assert.equal(mapForgejoPr({ number: 1, state: "open" })?.mergeable, "UNKNOWN");
});

test("mapForgejoPr reports mergeStateStatus as null -- Forgejo has no such concept", () => {
  const pr = mapForgejoPr({ number: 1, state: "open", mergeable: true });
  assert.equal(pr?.mergeStateStatus, null);
});

test("mapForgejoPr reads url from html_url, not the API url", () => {
  const pr = mapForgejoPr({
    number: 5,
    state: "open",
    html_url: "https://git.example.com/acme/app/pulls/5",
    url: "https://git.example.com/api/v1/repos/acme/app/pulls/5",
  });
  assert.equal(pr?.url, "https://git.example.com/acme/app/pulls/5");
});

test("mapForgejoPr carries draft, base ref and head sha", () => {
  const pr = mapForgejoPr({
    number: 5,
    state: "open",
    draft: true,
    base: { ref: "main" },
    head: { ref: "feat/x", sha: "deadbeef" },
  });
  assert.equal(pr?.isDraft, true);
  assert.equal(pr?.baseRefName, "main");
  assert.equal(pr?.headSha, "deadbeef");
});

test("mapForgejoPr rejects a row with no usable number", () => {
  assert.equal(mapForgejoPr({ state: "open" }), null);
  assert.equal(mapForgejoPr(null), null);
});

// ---------------------------------------------------------------------------
// Hazard 1: `draft` is derived from a title prefix, and the prefix list is
// server-configurable. "Mark ready" is a title rewrite, not a flag flip.
// ---------------------------------------------------------------------------

test("readyTitle strips a configured WIP prefix", () => {
  assert.equal(readyTitle("WIP: add thing", DEFAULT_WIP_PREFIXES), "add thing");
  assert.equal(readyTitle("[WIP] add thing", DEFAULT_WIP_PREFIXES), "add thing");
});

test("readyTitle matches prefixes case-insensitively, as Forgejo does", () => {
  assert.equal(readyTitle("wip: add thing", DEFAULT_WIP_PREFIXES), "add thing");
  assert.equal(readyTitle("Wip: add thing", DEFAULT_WIP_PREFIXES), "add thing");
});

test("readyTitle returns null when no prefix matches, so we never rewrite blindly", () => {
  assert.equal(readyTitle("add thing", DEFAULT_WIP_PREFIXES), null);
  // "WIPE" is not the "WIP:" prefix -- a substring match would corrupt the title.
  assert.equal(readyTitle("WIPE the cache", DEFAULT_WIP_PREFIXES), null);
});

test("readyTitle honours a server's custom prefix list", () => {
  assert.equal(readyTitle("Draft: x", ["Draft:"]), "x");
  assert.equal(readyTitle("WIP: x", ["Draft:"]), null);
});

test("readyTitle never yields an empty title", () => {
  assert.equal(readyTitle("WIP:", DEFAULT_WIP_PREFIXES), null);
  assert.equal(readyTitle("WIP:   ", DEFAULT_WIP_PREFIXES), null);
});

// ---------------------------------------------------------------------------
// Check rollup. Forgejo's per-status field is `status` (GitHub REST uses
// `state`), and its enum includes `skipped`, which GitHub's status vocabulary
// has no member for.
// ---------------------------------------------------------------------------

test("forgejoChecks reads the `status` field and maps the full enum", () => {
  const checks = forgejoChecks({
    statuses: [
      { context: "a", status: "success" },
      { context: "b", status: "failure" },
      { context: "c", status: "error" },
      { context: "d", status: "pending" },
      { context: "e", status: "skipped" },
      { context: "f", status: "warning" },
    ],
  });
  assert.deepEqual(
    checks.map((c) => [c.name, c.bucket]),
    [
      ["a", "pass"],
      ["b", "fail"],
      ["c", "fail"],
      ["d", "pending"],
      ["e", "skipping"],
      ["f", "skipping"],
    ],
  );
});

test("forgejoChecks does not silently bucket an unknown state as passing", () => {
  const [c] = forgejoChecks({ statuses: [{ context: "x", status: "something-new" }] });
  assert.equal(c.bucket, "pending");
});

test("forgejoChecks carries target_url as detailsUrl and leaves workflowName null", () => {
  const [c] = forgejoChecks({
    statuses: [{ context: "x", status: "success", target_url: "https://ci/1" }],
  });
  assert.equal(c.detailsUrl, "https://ci/1");
  assert.equal(c.workflowName, null);
});

test("forgejoChecks tolerates a missing or malformed statuses array", () => {
  assert.deepEqual(forgejoChecks({}), []);
  assert.deepEqual(forgejoChecks(null), []);
  assert.deepEqual(forgejoChecks({ statuses: "nope" }), []);
});

// ---------------------------------------------------------------------------
// Hazard: Forgejo returns epoch for unset timestamps instead of null. Feeding
// that into a duration renders as ~56 years (SPEC-session-timings's timings).
// ---------------------------------------------------------------------------

test("isEpochTimestamp recognises Forgejo's unset-time sentinel", () => {
  assert.equal(isEpochTimestamp("1970-01-01T01:00:00+01:00"), true);
  assert.equal(isEpochTimestamp("1970-01-01T00:00:00Z"), true);
  assert.equal(isEpochTimestamp("2026-07-24T18:20:47+02:00"), false);
  assert.equal(isEpochTimestamp(undefined), false);
  assert.equal(isEpochTimestamp("not a date"), false);
});

// ---------------------------------------------------------------------------
// Remote parsing: any host, since a Forgejo instance is self-hosted.
// ---------------------------------------------------------------------------

test("parseForgejoRemote handles ssh and https remotes on an arbitrary host", () => {
  assert.deepEqual(parseForgejoRemote("git@git.example.com:acme/app.git"), {
    host: "git.example.com",
    owner: "acme",
    repo: "app",
  });
  assert.deepEqual(parseForgejoRemote("https://git.example.com/acme/app.git"), {
    host: "git.example.com",
    owner: "acme",
    repo: "app",
  });
  assert.deepEqual(parseForgejoRemote("https://git.example.com/acme/app"), {
    host: "git.example.com",
    owner: "acme",
    repo: "app",
  });
});

test("parseForgejoRemote keeps an explicit port and strips ssh:// and userinfo", () => {
  assert.deepEqual(parseForgejoRemote("ssh://git@git.example.com:2222/acme/app.git"), {
    host: "git.example.com:2222",
    owner: "acme",
    repo: "app",
  });
});

test("parseForgejoRemote returns null for a remote it cannot read", () => {
  assert.equal(parseForgejoRemote(""), null);
  assert.equal(parseForgejoRemote("not-a-remote"), null);
  assert.equal(parseForgejoRemote("https://git.example.com/acme"), null);
});
