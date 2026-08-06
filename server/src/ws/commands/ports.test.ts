import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { CommandDeps } from "./deps.js";
import { register as registerPorts } from "./ports.js";

function fakeClient(overrides: Partial<WsClient> = {}): WsClient & { sent: OutgoingFrame[] } {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    send: (f) => sent.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    watchingMetrics: false,
    watchingPorts: false,
    isLocal: true,
    ...overrides,
  };
}

interface Recorder {
  router: CommandRouter;
  recounts: number;
  snapshotSends: WsClient[];
}

function setup(): Recorder {
  const rec: Recorder = { router: new CommandRouter(), recounts: 0, snapshotSends: [] };
  const deps = {
    onPortsWatchersChanged: () => {
      rec.recounts++;
    },
    sendPortsSnapshot: (client: WsClient) => {
      rec.snapshotSends.push(client);
    },
  } as unknown as CommandDeps;
  registerPorts(rec.router, deps);
  return rec;
}

const dispatch = (r: CommandRouter, c: WsClient, env: Record<string, unknown>) =>
  r.dispatch(c, { v: 1, t: "cmd", id: "1", kind: "ports.watch", ...env } as never);

test("{on:true} acks, sets the flag, recounts, and sends one snapshot", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, { on: true });
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
  assert.equal(c.watchingPorts, true);
  assert.equal(rec.recounts, 1);
  assert.deepEqual(rec.snapshotSends, [c]);
});

test("a repeated {on:true} neither re-sends the snapshot nor re-scans (still recounts)", async () => {
  const rec = setup();
  const c = fakeClient({ watchingPorts: true });
  await dispatch(rec.router, c, { on: true });
  assert.equal(rec.snapshotSends.length, 0, "no snapshot re-send on a no-op repeat");
});

test("{on:false} clears the flag and recounts (disarms), sends no snapshot", async () => {
  const rec = setup();
  const c = fakeClient({ watchingPorts: true });
  await dispatch(rec.router, c, { on: false });
  assert.equal(c.watchingPorts, false);
  assert.equal(rec.recounts, 1);
  assert.equal(rec.snapshotSends.length, 0);
});

test('a malformed payload (on:"yes") is a no-op, not a crash', async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, { on: "yes" });
  assert.equal(c.watchingPorts, false, "a non-true `on` reads as false");
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 0);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
  assert.equal(rec.snapshotSends.length, 0);
});
