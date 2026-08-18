import { test } from "node:test";
import assert from "node:assert/strict";

import { createNoForgeGateway } from "./none.js";
import { createUnsupportedGateway } from "./unsupported.js";
import { hasBudgetReporting } from "./types.js";

test("a lookup is none, not unknown — there is nothing to look for, by instruction", async () => {
  // The distinction from `unsupported` is the reason this gateway exists. `unknown`
  // makes the app hold a stale PR pill and keep retrying (SPEC-github-gateway-and-budget §6.5), which is
  // precisely the chatter setting the provider to None is meant to stop.
  const g = createNoForgeGateway();
  assert.deepEqual(await g.prForBranch("/r", "b"), { kind: "none" });
});

test("None and unsupported do NOT report the same thing", async () => {
  // Pinned as a comparison rather than two separate assertions: if these ever
  // collapse into one value, a deliberate choice starts reading as a defect.
  const chosen = await createNoForgeGateway().prForBranch("/r", "b");
  const cannot = await createUnsupportedGateway().prForBranch("/r", "b");
  assert.notDeepEqual(chosen, cannot);
});

test("it makes no requests at all, so a None repo costs nothing to poll", async () => {
  const g = createNoForgeGateway();
  await g.prForBranch("/r", "b");
  await g.openPrs("/r", 30);
  assert.deepEqual(g.stats(), { execs: 0, exemptExecs: 0, cacheHits: 0 });
});

test("there are no open PRs to offer, so the picker is empty rather than wrong", async () => {
  assert.deepEqual(await createNoForgeGateway().openPrs("/r", 30), []);
});

test("a mutation names the setting, so the fix is one hop away", async () => {
  // "It failed" is useless here: the cause is a choice the user made, and the
  // message has to say where to unmake it.
  const r = await createNoForgeGateway().mutatePr("/r", "b", 1, "merge-squash");
  assert.equal(r.ok, false);
  assert.match(r.error ?? "", /None/);
  assert.match(r.error ?? "", /Settings/);
  assert.match(r.error ?? "", /merge-squash/);
});

test("it claims no budget", () => {
  assert.equal(hasBudgetReporting(createNoForgeGateway()), false);
});
