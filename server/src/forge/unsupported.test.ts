import { test } from "node:test";
import assert from "node:assert/strict";

import { createUnsupportedGateway } from "./unsupported.js";
import { hasBudgetReporting } from "./types.js";

test("a lookup is unknown, never none -- we never asked", async () => {
  const g = createUnsupportedGateway();
  assert.deepEqual(await g.prForBranch("/r", "b"), { kind: "unknown", reason: "error" });
});

test("it makes no requests, so polling an unsupported forge costs nothing", async () => {
  const g = createUnsupportedGateway();
  await g.prForBranch("/r", "b");
  await g.openPrs("/r", 30);
  assert.deepEqual(g.stats(), { execs: 0, exemptExecs: 0, cacheHits: 0 });
});

test("a mutation names the forge, so the user learns why the button did nothing", async () => {
  const g = createUnsupportedGateway({ software: () => "gitlab" });
  const r = await g.mutatePr("/r", "b", 1, "merge-squash");
  assert.equal(r.ok, false);
  assert.match(r.error ?? "", /GitLab/);
  assert.match(r.error ?? "", /merge-squash/);
});

test("an unidentified forge gets a vaguer but still honest message", async () => {
  const g = createUnsupportedGateway({ software: () => "unknown" });
  const r = await g.mutatePr("/r", "b", 1, "ready");
  assert.match(r.error ?? "", /this forge/);
});

test("it claims no budget", () => {
  assert.equal(hasBudgetReporting(createUnsupportedGateway()), false);
});
