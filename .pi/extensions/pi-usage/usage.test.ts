import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveBridge, buildUsage, isWorthSending } from "./usage.js";

test("resolveBridge needs url, token and session id together", () => {
  const full = { MAKIT_BRIDGE_URL: "http://127.0.0.1:1", MAKIT_BRIDGE_TOKEN: "t", MAKIT_SESSION_ID: "s1" };
  assert.deepEqual(resolveBridge(full), { url: "http://127.0.0.1:1", token: "t", sessionId: "s1" });

  // A pi started from a plain terminal has none of these and must stay silent.
  assert.equal(resolveBridge({}), undefined);
  for (const drop of Object.keys(full)) {
    const partial: Record<string, string | undefined> = { ...full };
    delete partial[drop];
    assert.equal(resolveBridge(partial), undefined, `missing ${drop} must disable reporting`);
  }
});

test("buildUsage carries pi's context reading and cost", () => {
  assert.deepEqual(buildUsage({ tokens: 60000, contextWindow: 200000 }, { total: 0.42 }), {
    contextTokens: 60000,
    contextWindow: 200000,
    cost: { amount: 0.42, currency: "USD" },
  });
});

test("buildUsage omits a null token count instead of sending 0", () => {
  // pi returns null tokens right after compaction until a fresh assistant
  // response lands; a 0 would draw an empty bar instead of "not measured".
  const p = buildUsage({ tokens: null, contextWindow: 200000 });
  assert.deepEqual(p, { contextWindow: 200000 });
  assert.ok(!("contextTokens" in p!));
});

test("buildUsage omits cost when pi priced nothing", () => {
  const p = buildUsage({ tokens: 10, contextWindow: 100 }, { total: null });
  assert.ok(!("cost" in p!));
});

test("buildUsage keeps a real zero cost, which is not the same as unpriced", () => {
  // A free/local model legitimately costs 0.00 — that is a measurement.
  assert.deepEqual(buildUsage({ tokens: 10 }, { total: 0 })!.cost, { amount: 0, currency: "USD" });
});

test("buildUsage returns undefined when pi knows nothing yet", () => {
  assert.equal(buildUsage(undefined), undefined);
  assert.equal(buildUsage(null, null), undefined);
  assert.equal(buildUsage({ tokens: null, contextWindow: null }), undefined);
});

test("isWorthSending suppresses an unchanged repeat", () => {
  // pi fires message_end for tool-call-only messages too, so identical readings
  // are common; one request per real change, not per message.
  const a = { contextTokens: 10, contextWindow: 100 };
  assert.equal(isWorthSending(undefined, a), true);
  assert.equal(isWorthSending(a, { ...a }), false);
  assert.equal(isWorthSending(a, { contextTokens: 11, contextWindow: 100 }), true);
});

test("isWorthSending reacts to a cost change alone", () => {
  const base = { contextTokens: 10, contextWindow: 100 };
  assert.equal(
    isWorthSending({ ...base, cost: { amount: 0.1, currency: "USD" } }, { ...base, cost: { amount: 0.2, currency: "USD" } }),
    true,
  );
  assert.equal(
    isWorthSending({ ...base, cost: { amount: 0.1, currency: "USD" } }, { ...base, cost: { amount: 0.1, currency: "USD" } }),
    false,
  );
});
