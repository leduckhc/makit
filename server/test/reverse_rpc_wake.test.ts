import { test } from "node:test";
import assert from "node:assert/strict";

import { ReverseRpc } from "../src/ws/reverse_rpc.js";
import { WakeCoordinator } from "../src/push/wake_coordinator.js";
import { NoopPushSender, type PushSender, type PushResult } from "../src/push/sender.js";
import { buildWakePayload } from "../src/push/payload.js";
import type { WsClient, OutgoingFrame } from "../src/ws/client.js";
import type { Envelope } from "../src/protocol.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(authed = true, subs: string[] = []): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed,
    subscribed: new Set(subs),
    watchingMetrics: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

// -------- A5: keep-pending gated on the onUndeliverable hook ----------------

test("keeps request pending when onUndeliverable returns true", async () => {
  const seen: { env: Envelope; ctx: { pendingCount: number } }[] = [];
  const rpc = new ReverseRpc({
    clients: () => [],
    onUndeliverable: (env, ctx) => {
      seen.push({ env, ctx });
      return true;
    },
  });

  const promise = rpc.askDevice({ kind: "confirmAction" }, { timeoutMs: 60_000 });
  // Not rejected synchronously; the hook saw the envelope + a numeric count.
  assert.equal(seen.length, 1, "hook was called");
  assert.equal(seen[0]!.env.t, "srv.request");
  assert.equal(typeof seen[0]!.ctx.pendingCount, "number");

  const id = seen[0]!.env.id;
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope);
  assert.equal((await promise).approved, true);
});

test("rejects immediately when onUndeliverable returns false", async () => {
  const rpc = new ReverseRpc({ clients: () => [], onUndeliverable: () => false });
  await assert.rejects(rpc.askDevice({ kind: "confirmAction" }), /no subscribed clients to ask/);
});

test("rejects immediately when no hook is provided (today's behaviour)", async () => {
  const rpc = new ReverseRpc({ clients: () => [] });
  await assert.rejects(rpc.askDevice({ kind: "confirmAction" }), /no subscribed clients to ask/);
});

test("pendingCount getter reflects in-flight requests", async () => {
  const observed: number[] = [];
  const rpc = new ReverseRpc({
    clients: () => [],
    onUndeliverable: (_env, ctx) => {
      observed.push(ctx.pendingCount);
      return true; // keep them pending so they accumulate
    },
  });
  // Short timeout so lingering timers reject (and are caught) after the sync
  // assertions below — keeps the test process from hanging on 5-min timers.
  const ps = [0, 1, 2].map(() =>
    rpc.askDevice({ kind: "confirmAction" }, { timeoutMs: 20 }).catch(() => {}),
  );
  assert.equal(rpc.pendingCount, 3);
  // Each call observed the count including itself: 1, 2, 3.
  assert.deepEqual(observed, [1, 2, 3]);
  await Promise.all(ps);
});

// -------- A5 end-to-end: real WakeCoordinator as the hook -------------------

function wakeRegistry(devices: { id: string; pushToken?: string; pushPlatform?: string }[]) {
  return { list: () => devices, clearPushToken: () => {} };
}

test("Noop sender + stale stored token → askDevice rejects immediately (no hang)", async () => {
  const coord = new WakeCoordinator({
    registry: wakeRegistry([{ id: "d2", pushToken: "stale", pushPlatform: "apns" }]),
    connectedDeviceIds: () => new Set<string>(),
    sender: new NoopPushSender(),
    buildWakePayload,
  });
  const rpc = new ReverseRpc({
    clients: () => [],
    onUndeliverable: (env, ctx) => coord.wake(env, ctx),
  });
  await assert.rejects(rpc.askDevice({ kind: "confirmAction" }), /no subscribed clients to ask/);
  assert.equal(rpc.pendingCount, 0, "no timer/entry left armed");
});

test("real (enabled fake) sender + token + not-connected → stays pending", async () => {
  const enabledSender: PushSender = {
    enabled: true,
    wake: async (): Promise<PushResult> => "ok",
  };
  const coord = new WakeCoordinator({
    registry: wakeRegistry([{ id: "d2", pushToken: "tok", pushPlatform: "apns" }]),
    connectedDeviceIds: () => new Set<string>(),
    sender: enabledSender,
    buildWakePayload,
  });
  const rpc = new ReverseRpc({
    clients: () => [],
    onUndeliverable: (env, ctx) => coord.wake(env, ctx),
  });
  const promise = rpc.askDevice({ kind: "confirmAction" }, { timeoutMs: 60_000 });
  assert.equal(rpc.pendingCount, 1, "request kept pending");
  // Grab the pending request id via a replay, then answer it.
  const probe = fakeClient();
  rpc.replayPendingTo(probe);
  const reqId = String(probe.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id: reqId, approved: false } as Envelope);
  assert.equal((await promise).approved, false);
});

// -------- A6: replay pending to a newly-authed client (once) ----------------

test("replayPendingTo delivers each pending request once per client", async () => {
  const rpc = new ReverseRpc({ clients: () => [], onUndeliverable: () => true });
  const promise = rpc.askDevice({ kind: "confirmAction" }, { timeoutMs: 60_000 });

  const client = fakeClient();
  const first = rpc.replayPendingTo(client);
  assert.equal(first, 1);
  assert.equal(client.sent.filter((f) => f.t === "srv.request").length, 1);

  // A second replay to the same client sends nothing (de-duplicated).
  const second = rpc.replayPendingTo(client);
  assert.equal(second, 0);
  assert.equal(client.sent.filter((f) => f.t === "srv.request").length, 1);

  const reqId = String(client.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id: reqId, approved: true } as Envelope);
  await promise;
});

test("a client already sent the request live is not re-delivered on replay", async () => {
  const live = fakeClient(true, ["sess-1"]);
  const rpc = new ReverseRpc({ clients: () => [live] });
  const promise = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "sess-1", timeoutMs: 60_000 });
  assert.equal(live.sent.filter((f) => f.t === "srv.request").length, 1);

  // Replaying to the same live client must not double-send.
  assert.equal(rpc.replayPendingTo(live), 0);
  assert.equal(live.sent.filter((f) => f.t === "srv.request").length, 1);

  const reqId = String(live.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id: reqId, approved: true } as Envelope);
  await promise;
});
