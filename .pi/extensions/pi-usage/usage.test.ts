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

// ---- activate(): delivery + dedupe -----------------------------------------

import activate from "./index.js";

type Handler = (
  event: { message?: { role?: string; usage?: { cost?: { total?: number | null } } } },
  ctx: { getContextUsage?: () => { tokens?: number | null; contextWindow?: number | null } },
) => void;

/** Minimal pi host: captures the `message_end` handler and any logs. */
function fakeHost() {
  let handler: Handler | undefined;
  const logs: string[] = [];
  return {
    host: {
      on: (_e: "message_end", h: Handler) => {
        handler = h;
      },
      log: (m: string) => logs.push(m),
    },
    fire: (tokens: number, cost?: number) =>
      handler?.(
        { message: { role: "assistant", usage: { cost: { total: cost ?? null } } } },
        { getContextUsage: () => ({ tokens, contextWindow: 200000 }) },
      ),
    logs,
  };
}

/** Installs a fetch stub whose status is scripted per call; restores on return. */
function stubFetch(statuses: number[]) {
  const calls: Array<Record<string, unknown>> = [];
  const original = globalThis.fetch;
  let i = 0;
  globalThis.fetch = (async (_url: string, init: { body: string }) => {
    calls.push(JSON.parse(init.body) as Record<string, unknown>);
    const status = statuses[Math.min(i++, statuses.length - 1)]!;
    return { ok: status >= 200 && status < 300, status } as Response;
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = original) };
}

/** Let the fire-and-forget promise chain settle. */
const flush = () => new Promise((r) => setImmediate(r));

const BRIDGE_VARS = [
  "MAKIT_BRIDGE_URL",
  "MAKIT_BRIDGE_TOKEN",
  "MAKIT_SESSION_ID",
] as const;

/**
 * Run [fn] with the bridge env set to [values], restoring the previous values
 * afterwards.
 *
 * Both directions are set EXPLICITLY rather than relying on what happens to be
 * in the ambient environment: these very variables are present whenever the test
 * suite itself is run from inside a makit session, so a test that assumed their
 * absence passed on CI and failed locally.
 */
function withBridgeEnv<T>(values: Record<string, string | undefined>, fn: () => T): T {
  const saved = Object.fromEntries(BRIDGE_VARS.map((k) => [k, process.env[k]]));
  for (const k of BRIDGE_VARS) {
    const v = values[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const k of BRIDGE_VARS) {
      const v = saved[k];
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

const withEnv = <T,>(fn: () => T): T =>
  withBridgeEnv(
    {
      MAKIT_BRIDGE_URL: "http://127.0.0.1:1",
      MAKIT_BRIDGE_TOKEN: "tok",
      MAKIT_SESSION_ID: "s1",
    },
    fn,
  );

/** Same, with every bridge variable removed — i.e. pi outside makit. */
const withoutEnv = <T,>(fn: () => T): T => withBridgeEnv({}, fn);

test("an accepted report is not resent while the reading is unchanged", async () => {
  const f = stubFetch([200]);
  try {
    const { host, fire } = fakeHost();
    await withEnv(() => activate(host));
    fire(1000);
    await flush();
    fire(1000);
    await flush();
    assert.equal(f.calls.length, 1, "identical reading must not be re-posted");
  } finally {
    f.restore();
  }
});

test("a REJECTED report is retried, not treated as delivered", async () => {
  // The regression: `fetch` does not throw on 401/400, so recording the payload
  // as sent up front let a rejected post silence every identical retry — leaving
  // the session with no usage until the numbers happened to change. A stale
  // bearer after a server restart is exactly this case.
  const f = stubFetch([401, 200]);
  try {
    const { host, fire, logs } = fakeHost();
    await withEnv(() => activate(host));

    fire(1000);
    await flush();
    assert.equal(f.calls.length, 1);
    assert.ok(
      logs.some((l) => l.includes("401")),
      "a rejection must be logged, not swallowed",
    );

    fire(1000); // same reading — must be attempted again
    await flush();
    assert.equal(f.calls.length, 2, "a rejected payload must be retried");

    fire(1000); // now accepted, so this one is deduped
    await flush();
    assert.equal(f.calls.length, 2);
  } finally {
    f.restore();
  }
});

test("a network error is retried too", async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async () => {
    calls++;
    throw new Error("ECONNREFUSED");
  }) as typeof fetch;
  try {
    const { host, fire, logs } = fakeHost();
    await withEnv(() => activate(host));
    fire(1000);
    await flush();
    fire(1000);
    await flush();
    assert.equal(calls, 2);
    assert.ok(logs.some((l) => l.includes("ECONNREFUSED")));
  } finally {
    globalThis.fetch = original;
  }
});

test("registers nothing outside makit (no bridge env)", async () => {
  const f = stubFetch([200]);
  try {
    let registered = false;
    await withoutEnv(() =>
      activate({
        on: () => {
          registered = true;
        },
      } as never),
    );
    assert.equal(registered, false);
    assert.equal(f.calls.length, 0);
  } finally {
    f.restore();
  }
});

test("ignores non-assistant messages", async () => {
  const f = stubFetch([200]);
  try {
    let handler: Handler | undefined;
    await withEnv(() =>
      activate({ on: (_e: "message_end", h: Handler) => (handler = h) } as never),
    );
    handler?.({ message: { role: "user" } }, { getContextUsage: () => ({ tokens: 5 }) });
    await flush();
    assert.equal(f.calls.length, 0);
  } finally {
    f.restore();
  }
});
