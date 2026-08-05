import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import { register as registerDiagnostics } from "./diagnostics.js";

/** Minimal WsClient fake that records the frames it is asked to send. */
function fakeClient(overrides: Partial<WsClient> = {}): WsClient & { sent: OutgoingFrame[] } {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    send: (f) => sent.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    watchingMetrics: false,
    isLocal: true,
    ...overrides,
  };
}

/** Run the handler and capture what the shared logger wrote to stderr. */
async function dispatchCapturingLog(
  env: Record<string, unknown>,
  client: WsClient,
): Promise<{ logged: string[]; client: WsClient }> {
  const prev = process.env.MAKIT_LOG;
  process.env.MAKIT_LOG = "info";
  const original = console.error;
  const logged: string[] = [];
  // eslint-disable-next-line no-console
  console.error = (...args: unknown[]) => logged.push(args.join(" "));
  try {
    const r = new CommandRouter();
    registerDiagnostics(r);
    await r.dispatch(client, { v: 1, t: "cmd", id: "1", ...env } as never);
  } finally {
    console.error = original;
    if (prev === undefined) delete process.env.MAKIT_LOG;
    else process.env.MAKIT_LOG = prev;
  }
  return { logged, client };
}

test("client.log writes each record to the server log, tagged by device", async () => {
  const client = fakeClient({ deviceLabel: "Léo's iPhone", deviceId: "dev-1" });
  const { logged } = await dispatchCapturingLog(
    {
      kind: "client.log",
      platform: "ios",
      records: [
        { ts: 1, level: "error", tag: "flutter", message: "_dependents.isEmpty" },
        { ts: 2, level: "warn", tag: "ws", message: "connect failed" },
      ],
    },
    client,
  );
  assert.equal(logged.length, 2);
  assert.match(logged[0], /\[client:ios:Léo's iPhone\]/);
  assert.match(logged[0], /ERROR \[flutter\] _dependents\.isEmpty/);
  assert.match(logged[1], /WARN \[ws\] connect failed/);
});

test("client.log acks with the number of records received", async () => {
  const client = fakeClient({ deviceId: "dev-1" });
  const { client: c } = await dispatchCapturingLog(
    { kind: "client.log", platform: "ios", records: [{ level: "info", tag: "t", message: "m" }] },
    client,
  );
  const acks = (c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack");
  assert.equal(acks.length, 1);
  assert.equal((acks[0] as Record<string, unknown>).received, 1);
});

test("client.log tolerates missing/garbage records without throwing", async () => {
  const client = fakeClient({ deviceId: "dev-1" });
  const { logged, client: c } = await dispatchCapturingLog(
    { kind: "client.log", platform: "ios" }, // no records array at all
    client,
  );
  assert.equal(logged.length, 0);
  const sent = (c as ReturnType<typeof fakeClient>).sent;
  assert.equal(sent.filter((f) => f.t === "err").length, 0, "must not error");
  assert.equal(sent.filter((f) => f.t === "ack").length, 1);
});

test("client.log caps the number of records it will process", async () => {
  const client = fakeClient({ deviceId: "dev-1" });
  const records = Array.from({ length: 2000 }, (_, i) => ({
    level: "info",
    tag: "t",
    message: `m${i}`,
  }));
  const { logged } = await dispatchCapturingLog(
    { kind: "client.log", platform: "ios", records },
    client,
  );
  assert.ok(logged.length <= 1000, `expected a cap, got ${logged.length}`);
});
