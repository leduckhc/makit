/**
 * Bridge tests (SPEC-37): the loopback endpoint a pi extension posts usage to.
 *
 * The bridge is reachable by anything running on the host, so the bearer check
 * and the body validation are the security boundary, not a formality.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { startBridge, type BridgeHandle } from "./bridge.js";
import type { SessionUsageDTO } from "./protocol.js";

async function withBridge(
  fn: (b: BridgeHandle, seen: Array<{ sessionId: string; usage: SessionUsageDTO }>) => Promise<void>,
): Promise<void> {
  const seen: Array<{ sessionId: string; usage: SessionUsageDTO }> = [];
  const bridge = await startBridge({
    askDevice: async () => ({ kind: "cancelled" }) as never,
    onUsage: (sessionId, usage) => seen.push({ sessionId, usage }),
  });
  try {
    await fn(bridge, seen);
  } finally {
    await bridge.stop();
  }
}

const post = (b: BridgeHandle, body: unknown, token?: string) =>
  fetch(`${b.url}/usage`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    body: JSON.stringify(body),
  });

test("POST /usage forwards a snapshot for the named session", async () => {
  await withBridge(async (b, seen) => {
    const res = await post(
      b,
      {
        sessionId: "s1",
        usage: { contextTokens: 19508, contextWindow: 258400, cost: { amount: 0.42, currency: "USD" } },
      },
      b.token,
    );
    assert.equal(res.status, 200);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].sessionId, "s1");
    assert.equal(seen[0].usage.contextTokens, 19508);
    assert.equal(seen[0].usage.contextWindow, 258400);
    assert.deepEqual(seen[0].usage.cost, { amount: 0.42, currency: "USD" });
    assert.equal(typeof seen[0].usage.measuredAt, "number", "stamped server-side");
  });
});

test("POST /usage rejects a wrong or missing bearer", async () => {
  await withBridge(async (b, seen) => {
    assert.equal((await post(b, { sessionId: "s1", usage: { contextTokens: 1 } }, "nope")).status, 401);
    assert.equal((await post(b, { sessionId: "s1", usage: { contextTokens: 1 } })).status, 401);
    assert.equal(seen.length, 0, "an unauthenticated post must not reach the session");
  });
});

test("POST /usage rejects a body with no sessionId or no numbers", async () => {
  await withBridge(async (b, seen) => {
    assert.equal((await post(b, { usage: { contextTokens: 1 } }, b.token)).status, 400);
    assert.equal((await post(b, { sessionId: "s1" }, b.token)).status, 400);
    assert.equal((await post(b, { sessionId: "s1", usage: {} }, b.token)).status, 400);
    assert.equal(seen.length, 0);
  });
});

test("POST /usage drops non-numeric fields instead of trusting the extension", async () => {
  // The extension is ordinary user-editable code; a string where a token count
  // belongs must not reach the app and render as "NaN%".
  await withBridge(async (b, seen) => {
    const res = await post(
      b,
      { sessionId: "s1", usage: { contextTokens: 100, contextWindow: "lots", cost: { amount: "free" } } },
      b.token,
    );
    assert.equal(res.status, 200);
    assert.equal(seen[0].usage.contextTokens, 100);
    assert.ok(!("contextWindow" in seen[0].usage), "bad window dropped, not coerced");
    assert.ok(!("cost" in seen[0].usage), "bad cost dropped, not coerced");
  });
});

test("an unknown bridge path is still a 404", async () => {
  await withBridge(async (b) => {
    const res = await fetch(`${b.url}/nope`, { method: "POST" });
    assert.equal(res.status, 404);
  });
});
