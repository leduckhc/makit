import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveBridge, buildUsage, addUsage, sumUsage, isWorthSending } from "./usage.js";

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

test("buildUsage carries pi's context reading and the accumulated totals", () => {
  const acc = addUsage({}, { input: 100, output: 20, cacheRead: 900, cacheWrite: 50, cost: { total: 0.42 } });
  assert.deepEqual(buildUsage({ tokens: 60000, contextWindow: 200000 }, acc), {
    contextTokens: 60000,
    contextWindow: 200000,
    // `input` is every prompt token (100 + 900 + 50) because makit treats cached
    // input as a subset of input; pi splits them instead.
    totals: { total: 1070, input: 1050, cachedInput: 900, cacheWrite: 50, output: 20 },
    cost: { amount: 0.42, currency: "USD" },
  });
});

test("buildUsage nests the cache inside input, not beside it", () => {
  // The panel's cache-share bar is cachedInput/input, so pi's uncached-only
  // `input` would nest a 900-token cache row under a 100-token parent.
  const t = buildUsage({ tokens: 1 }, addUsage({}, { input: 100, cacheRead: 900 }))!.totals!;
  assert.ok(t.cachedInput! <= t.input!, "cache share must not exceed 100%");
});

test("sumUsage counts every billed entry, exactly as pi's /sessions does", () => {
  // Mirrors `AgentSession.getSessionStats`: assistant messages, billed tool
  // results (tool-side summarisation) and compaction/branch summaries all count,
  // while user messages and unbilled tool results contribute nothing.
  const acc = sumUsage([
    { type: "message", message: { role: "user" } },
    { type: "message", message: { role: "assistant", usage: { input: 10, output: 1, cacheRead: 100, cost: { total: 0.1 } } } },
    { type: "message", message: { role: "toolResult" } },
    { type: "message", message: { role: "toolResult", usage: { input: 5, output: 2, cost: { total: 0.02 } } } },
    { type: "compaction", usage: { input: 7, output: 3, cost: { total: 0.03 } } },
    { type: "branch_summary", usage: { input: 1, output: 1, cost: { total: 0.01 } } },
    { type: "file_change" },
  ]);
  assert.deepEqual({ ...acc, cost: undefined }, { input: 23, cachedInput: 100, output: 7, cost: undefined });
  // Summed floats, so compared with a tolerance rather than exactly.
  assert.ok(Math.abs(acc.cost! - 0.16) < 1e-9, `cost was ${acc.cost}`);
});

test("sumUsage covers a RESUMED session: history it never saw still counts", () => {
  // The regression this fixes: an in-process accumulator only ever saw the turns
  // of its own pi process, so resuming a $22 session reported it as brand new.
  const earlierProcess: Parameters<typeof sumUsage>[0] = [
    { type: "message", message: { role: "assistant", usage: { input: 4, cacheRead: 18391, cacheWrite: 18448, output: 50, cost: { total: 0.116 } } } },
  ];
  const resumed = [...earlierProcess, { type: "message", message: { role: "assistant", usage: { input: 2, output: 3, cost: { total: 0.01 } } } }];
  assert.equal(sumUsage(resumed).cost, 0.126);
  assert.equal(buildUsage({ tokens: 1 }, sumUsage(resumed))!.totals!.total, 36898);
});

test("sumUsage drops junk instead of poisoning the totals with NaN", () => {
  // Entries come from a user-editable JSONL file; `NaN` would surface as `NaN%`.
  const acc = sumUsage([
    { type: "message", message: { role: "assistant", usage: { input: "lots" as never, output: 2, cost: { total: null } } } },
    { type: "message", message: null },
    undefined as never,
  ]);
  assert.deepEqual(acc, { output: 2 });
  assert.deepEqual(sumUsage(undefined), {});
});

test("addUsage accumulates instead of overwriting with the latest reading", () => {
  // The regression: pi's `message_end` usage is PER MESSAGE, but makit's `totals`
  // and `cost` are cumulative for the session. Reporting the last message showed
  // $0.20 where pi's own /sessions said $22.16.
  let acc = addUsage({}, { input: 10, output: 1, cacheRead: 1000, cacheWrite: 5, cost: { total: 0.2 } });
  acc = addUsage(acc, { input: 20, output: 2, cacheRead: 2000, cacheWrite: 0, cost: { total: 0.3 } });
  assert.deepEqual(acc, { input: 30, output: 3, cachedInput: 3000, cacheWrite: 5, cost: 0.5 });
  // `total` mirrors pi's own /session arithmetic — input + output + cache reads +
  // cache writes — so the panel and `/sessions` agree to the token.
  assert.equal(buildUsage({ tokens: 1 }, acc)!.totals!.total, 3038);
});

test("addUsage keeps reasoning apart, and only once pi reports it", () => {
  // `reasoning` is a SUBSET of `output` and only some providers report it, so an
  // absent reading must stay absent rather than render as "0 reasoning tokens".
  const quiet = addUsage({}, { input: 1, output: 2 });
  assert.ok(!("reasoning" in quiet));
  assert.ok(!("reasoning" in buildUsage({ tokens: 1 }, quiet)!.totals!));

  const loud = addUsage(addUsage({}, { output: 2, reasoning: 1 }), { output: 4, reasoning: 3 });
  assert.equal(loud.reasoning, 4);
  // Reasoning is inside output, so counting it again would inflate the total.
  assert.equal(buildUsage({ tokens: 1 }, loud)!.totals!.total, 6);
});

test("addUsage ignores a message that measured nothing", () => {
  const acc = addUsage({}, { input: 5, cost: { total: 0.1 } });
  assert.deepEqual(addUsage(acc, undefined), acc);
  assert.deepEqual(addUsage(acc, { input: null, cost: { total: null } }), acc);
});

test("buildUsage omits a null token count instead of sending 0", () => {
  // pi returns null tokens right after compaction until a fresh assistant
  // response lands; a 0 would draw an empty bar instead of "not measured".
  const p = buildUsage({ tokens: null, contextWindow: 200000 }, {});
  assert.deepEqual(p, { contextWindow: 200000 });
  assert.ok(!("contextTokens" in p!));
});

test("buildUsage omits cost and totals when pi has measured neither", () => {
  const p = buildUsage({ tokens: 10, contextWindow: 100 }, addUsage({}, { cost: { total: null } }));
  assert.ok(!("cost" in p!));
  assert.ok(!("totals" in p!));
});

test("buildUsage keeps a real zero cost, which is not the same as unpriced", () => {
  // A free/local model legitimately costs 0.00 — that is a measurement.
  assert.deepEqual(buildUsage({ tokens: 10 }, addUsage({}, { cost: { total: 0 } }))!.cost, {
    amount: 0,
    currency: "USD",
  });
});

test("buildUsage returns undefined when pi knows nothing yet", () => {
  assert.equal(buildUsage(undefined, {}), undefined);
  assert.equal(buildUsage(null, {}), undefined);
  assert.equal(buildUsage({ tokens: null, contextWindow: null }, {}), undefined);
});

test("isWorthSending suppresses an unchanged repeat", () => {
  // pi fires message_end for tool-call-only messages too, so identical readings
  // are common; one request per real change, not per message.
  const a = { contextTokens: 10, contextWindow: 100 };
  assert.equal(isWorthSending(undefined, a), true);
  assert.equal(isWorthSending(a, { ...a }), false);
  assert.equal(isWorthSending(a, { contextTokens: 11, contextWindow: 100 }), true);
});

test("isWorthSending reacts to a totals change alone", () => {
  // A turn can leave the context reading identical while still burning cached
  // input, and the breakdown is the whole point of the panel.
  const base = { contextTokens: 10, contextWindow: 100 };
  const a = { ...base, totals: { total: 10, cachedInput: 5 } };
  assert.equal(isWorthSending(a, { ...base, totals: { total: 20, cachedInput: 15 } }), true);
  assert.equal(isWorthSending(a, { ...base, totals: { total: 10, cachedInput: 5 } }), false);
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

type FiredUsage = {
  input?: number | null;
  output?: number | null;
  cacheRead?: number | null;
  cacheWrite?: number | null;
  reasoning?: number | null;
  cost?: { total?: number | null };
};

type Entry = { type?: string; usage?: FiredUsage | null; message?: { role?: string; usage?: FiredUsage | null } | null };

type Handler = (
  event: unknown,
  ctx: {
    getContextUsage?: () => { tokens?: number | null; contextWindow?: number | null };
    sessionManager?: { getEntries?: () => Entry[] };
  },
) => void;

/**
 * Minimal pi host: captures the `turn_end` handler and any logs.
 *
 * `fire` appends the turn's usage to the session-entry log BEFORE invoking the
 * handler, which is the ordering pi guarantees at `turn_end` (and does not at
 * `message_end`): that log — not the event — is what the extension reads. [seed] stands in for the history a
 * RESUMED session inherits from a previous pi process.
 */
function fakeHost(seed: Entry[] = []) {
  let handler: Handler | undefined;
  const logs: string[] = [];
  const entries: Entry[] = [...seed];
  return {
    host: {
      on: (_e: "turn_end", h: Handler) => {
        handler = h;
      },
      log: (m: string) => logs.push(m),
    },
    fire: (tokens: number, usage?: FiredUsage) => {
      entries.push({ type: "message", message: { role: "assistant", usage: usage ?? { cost: { total: null } } } });
      handler?.(
        { turnIndex: 0 },
        {
          getContextUsage: () => ({ tokens, contextWindow: 200000 }),
          sessionManager: { getEntries: () => entries },
        },
      );
    },
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

test("a resumed session reports the whole session, not just this process's turns", async () => {
  const f = stubFetch([200]);
  try {
    // What a previous pi process billed before the resume.
    const { host, fire } = fakeHost([
      { type: "message", message: { role: "assistant", usage: { input: 100, output: 50, cost: { total: 22.0 } } } },
      { type: "compaction", usage: { input: 10, output: 5, cost: { total: 0.16 } } },
    ]);
    await withEnv(() => activate(host));

    fire(1000, { input: 1, output: 1, cost: { total: 0.04 } });
    await flush();

    const usage = f.calls[0]!.usage as { cost: { amount: number }; totals: Record<string, number> };
    assert.equal(usage.cost.amount, 22.2, "the first report must already carry the inherited spend");
    assert.equal(usage.totals.total, 167);
  } finally {
    f.restore();
  }
});

test("the reported cost and totals grow over the session, not per message", async () => {
  const f = stubFetch([200]);
  try {
    const { host, fire } = fakeHost();
    await withEnv(() => activate(host));
    fire(1000, { input: 10, output: 1, cacheRead: 1000, cacheWrite: 5, cost: { total: 0.2 } });
    await flush();
    fire(2000, { input: 20, output: 2, cacheRead: 2000, cost: { total: 0.3 } });
    await flush();

    assert.equal(f.calls.length, 2);
    const second = f.calls[1]!.usage as {
      cost: { amount: number };
      totals: Record<string, number>;
    };
    assert.equal(second.cost.amount, 0.5, "cost must be the session total, not the last message");
    assert.deepEqual(second.totals, {
      total: 3038,
      input: 3035,
      cachedInput: 3000,
      cacheWrite: 5,
      output: 3,
    });
  } finally {
    f.restore();
  }
});

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

test("posts nothing for a turn where pi measured nothing", async () => {
  // e.g. an aborted turn before any assistant reply: no context reading and no
  // billed entry. An empty snapshot would be rejected as a 400 anyway.
  const f = stubFetch([200]);
  try {
    let handler: Handler | undefined;
    await withEnv(() => activate({ on: (_e: "turn_end", h: Handler) => (handler = h) } as never));
    handler?.({}, { getContextUsage: () => ({ tokens: null, contextWindow: null }), sessionManager: { getEntries: () => [] } });
    await flush();
    assert.equal(f.calls.length, 0);
  } finally {
    f.restore();
  }
});
