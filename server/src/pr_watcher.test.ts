import { test } from "node:test";
import assert from "node:assert/strict";

import { watchPrs } from "./pr_watcher.js";
import type { PullRequestInfo } from "./git.js";
import type { PrLookup } from "./github/gateway.js";
import type { RepoDTO } from "./protocol.js";

/** Build a PullRequestInfo with sensible defaults for the fields under test. */
function pr(overrides: Partial<PullRequestInfo> = {}): PullRequestInfo {
  return {
    number: 1,
    url: "https://example.test/1",
    state: "OPEN",
    title: "t",
    isDraft: false,
    mergeable: "MERGEABLE",
    mergeStateStatus: "CLEAN",
    checks: [],
    checkRollup: "none",
    unresolvedComments: 0,
    ...overrides,
  };
}

/** A one-repo snapshot with a single open-PR worktree on `branch`. */
function repos(branch: string, prInfo: PullRequestInfo | null): RepoDTO[] {
  return [
    {
      id: "r1",
      name: "r1",
      path: "/repo",
      pinned: false,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: "main",
      currentBranch: "main",
      worktrees: [
        {
          id: "/wt",
          path: "/wt",
          branch,
          isPrimary: false,
      targetBranch: "main",
      targetResolved: true,
      retargetedFrom: null,
          insertions: 0,
          deletions: 0,
          filesChanged: 0,
          uncommittedFiles: 0,
          aheadCount: 0,
          behindCount: 0,
          committedAt: null,
          pr: prInfo,
          sessionIds: [],
        },
      ],
    },
  ];
}

/** A watcher whose scheduler is a no-op, so only explicit pollOnce() runs. */
function makeWatcher(fetchPr: (repoPath: string, branch: string) => Promise<PrLookup>) {
  let changes = 0;
  const w = watchPrs({
    fetchPr,
    onChange: () => {
      changes += 1;
    },
    setTimer: () => ({ unref() {} }), // never actually fires
    clearTimer: () => {},
  });
  return { w, changes: () => changes };
}

test("pollOnce does not fire when status matches the synced baseline", async () => {
  const seeded = pr({ checkRollup: "pass", checks: [{ name: "test", bucket: "pass", workflowName: null, detailsUrl: null }] });
  const { w, changes } = makeWatcher(async () => ({ kind: "pr", pr: seeded }));
  w.sync(repos("feature", seeded));
  const fired = await w.pollOnce();
  assert.equal(fired, false, "identical status must not broadcast");
  assert.equal(changes(), 0);
  w.close();
});

test("pollOnce fires once when a check transitions pending → pass", async () => {
  const pending = pr({ checkRollup: "pending", checks: [{ name: "test", bucket: "pending", workflowName: null, detailsUrl: null }] });
  let current = pending;
  const { w, changes } = makeWatcher(async () => ({ kind: "pr", pr: current }));
  w.sync(repos("feature", pending));

  // CI finishes: same PR, now passing.
  current = pr({ checkRollup: "pass", checks: [{ name: "test", bucket: "pass", workflowName: null, detailsUrl: null }] });
  assert.equal(await w.pollOnce(), true, "a real change broadcasts");
  assert.equal(changes(), 1);

  // Nothing else changed: the next poll is quiet.
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 1);
  w.close();
});

test("pollOnce fires when PR state flips to MERGED", async () => {
  const open = pr({ state: "OPEN" });
  let current = open;
  const { w, changes } = makeWatcher(async () => ({ kind: "pr", pr: current }));
  w.sync(repos("feature", open));
  current = pr({ state: "MERGED" });
  assert.equal(await w.pollOnce(), true);
  assert.equal(changes(), 1);
  w.close();
});

test("pollOnce fires when a tracked PR vanishes (merged/closed)", async () => {
  // The lookup resolves to `none` (not `unknown`) once the PR leaves the open set.
  let current: PrLookup = { kind: "pr", pr: pr({ state: "OPEN" }) };
  const { w, changes } = makeWatcher(async () => current);
  w.sync(repos("feature", pr({ state: "OPEN" })));

  // PR merged/closed — drops out of the open-PR lookup.
  current = { kind: "none" };
  assert.equal(await w.pollOnce(), true, "a vanished PR must broadcast the drop");
  assert.equal(changes(), 1);

  // Still gone: the baseline is now NO_PR, so the next poll is quiet.
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 1);
  w.close();
});

test("an unknown result does not broadcast (retains the tracked PR)", async () => {
  // Regression guard for the reported bug: a throttled/failed lookup must never
  // clear a tracked PR nor spuriously broadcast.
  const seeded = pr({ checkRollup: "pass" });
  let current: PrLookup = { kind: "pr", pr: seeded };
  const { w, changes } = makeWatcher(async () => current);
  w.sync(repos("feature", seeded));

  current = { kind: "unknown", reason: "throttled" };
  assert.equal(await w.pollOnce(), false, "an unknown lookup must not broadcast");
  assert.equal(changes(), 0, "the tracked PR is retained, no drop");

  // The lookup recovers with the same PR: still no change (baseline intact).
  current = { kind: "pr", pr: seeded };
  assert.equal(await w.pollOnce(), false, "baseline was never lost");
  assert.equal(changes(), 0);
  w.close();
});

test("a none result broadcasts the drop", async () => {
  const seeded = pr({ state: "OPEN" });
  let current: PrLookup = { kind: "pr", pr: seeded };
  const { w, changes } = makeWatcher(async () => current);
  w.sync(repos("feature", seeded));

  current = { kind: "none" };
  assert.equal(await w.pollOnce(), true, "a definite 'none' broadcasts the drop");
  assert.equal(changes(), 1);
  w.close();
});

test("a fetch error leaves the baseline untouched (no spurious broadcast)", async () => {
  const seeded = pr({ checkRollup: "pass" });
  let mode: "ok" | "throw" = "ok";
  const { w, changes } = makeWatcher(async () => {
    if (mode === "throw") throw new Error("gh exploded");
    return { kind: "pr", pr: seeded };
  });
  w.sync(repos("feature", seeded));
  mode = "throw";
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 0);
  w.close();
});

test("tracks a branch with no PR yet and fires when one is created (any source)", async () => {
  // A branch created/pushed outside makit (manual, GitHub UI, another agent)
  // has no PR in the snapshot yet. The poller must still watch it so a PR that
  // later appears is discovered without a manual refresh.
  let current: PrLookup = { kind: "none" };
  const { w, changes } = makeWatcher(async () => current);
  w.sync(repos("feature", null)); // eligible branch, no PR yet

  // Still no PR: quiet.
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 0);

  // A PR appears (created by anyone): the poller detects it and broadcasts.
  current = { kind: "pr", pr: pr() };
  assert.equal(await w.pollOnce(), true, "a newly-created PR must broadcast");
  assert.equal(changes(), 1);

  // No further change: quiet again.
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 1);
  w.close();
});

test("the primary worktree is never tracked (its branch is not PR'd)", async () => {
  let calls = 0;
  const { w } = makeWatcher(async () => {
    calls += 1;
    return { kind: "none" };
  });
  const snapshot = repos("main", null);
  snapshot[0].worktrees[0].isPrimary = true;
  w.sync(snapshot);
  assert.equal(await w.pollOnce(), false);
  assert.equal(calls, 0, "primary worktree → no fetch");
  w.close();
});

test("closed watcher ignores sync and polling", async () => {
  const seeded = pr({ state: "OPEN" });
  let current: PrLookup = { kind: "pr", pr: seeded };
  const { w, changes } = makeWatcher(async () => current);
  w.sync(repos("feature", seeded));
  w.close();
  current = { kind: "pr", pr: pr({ state: "MERGED" }) };
  w.sync(repos("feature", pr({ state: "MERGED" })));
  assert.equal(await w.pollOnce(), false);
  assert.equal(changes(), 0);
});

// ── SPEC-32 T6: the cadence comes from the policy, and Infinity STOPS ─────────

/** A watcher that records every delay passed to setTimer (nothing ever fires). */
function makeIntervalWatcher(intervalMs: () => number) {
  const delays: number[] = [];
  const w = watchPrs({
    fetchPr: async () => ({ kind: "none" }) as PrLookup,
    onChange: () => {},
    jitterMs: 0, // deterministic: delay === base
    intervalMs,
    setTimer: (_fn, ms) => {
      delays.push(ms);
      return { unref() {} };
    },
    clearTimer: () => {},
  });
  return { w, delays };
}

test("the poll interval comes from the injected policy interval", async () => {
  const { w, delays } = makeIntervalWatcher(() => 42_000);
  w.sync(repos("feature", null));
  assert.deepEqual(delays, [42_000], "schedule must use the policy interval, not fast/slow");
  w.close();
});

test("an Infinity interval STOPS polling rather than busy-looping", async () => {
  const { w, delays } = makeIntervalWatcher(() => Infinity);
  w.sync(repos("feature", null));
  assert.deepEqual(delays, [], "Infinity (paused rung) must arm no timer");
  w.close();
});

test("a paused poller re-arms via poke() once the interval becomes finite", async () => {
  // The paused rung arms NO timer, so something must re-arm it when quota
  // recovers. Nothing else does: `sync()` is driven only by a repos-snapshot
  // broadcast (worktree change / session event / client auth), so without an
  // explicit poke a recovered account could sit with dead PR polling
  // indefinitely -- pills stale long after the quota came back.
  let interval = Number.POSITIVE_INFINITY;
  const { w, delays } = makeIntervalWatcher(() => interval);
  w.sync(repos("feature", null));
  assert.deepEqual(delays, [], "paused: no timer armed");

  interval = 30_000; // quota recovered
  w.poke();
  assert.deepEqual(delays, [30_000], "poke must re-arm at the new interval");
  w.close();
});

test("poke() on a still-paused poller stays paused", async () => {
  const { w, delays } = makeIntervalWatcher(() => Infinity);
  w.sync(repos("feature", null));
  w.poke();
  assert.deepEqual(delays, [], "poke must not busy-loop while still paused");
  w.close();
});
