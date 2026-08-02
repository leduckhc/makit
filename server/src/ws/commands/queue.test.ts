/**
 * SPEC-35 — the two queue-touching commands: `queue.cancel` drops ONE pending
 * mid-turn message, and `cancel` (stop) drops the whole queue, because a
 * follow-up must never fire into a turn the user just aborted.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { EventEmitter } from "node:events";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { CommandDeps } from "./deps.js";
import { register as registerSession } from "./session.js";
import { Session } from "../../session.js";
import type { AgentAdapter } from "../../adapters/adapter.js";

function busyAdapter(): { adapter: AgentAdapter; cancels: number } {
  const a = new EventEmitter() as unknown as AgentAdapter;
  const box = { adapter: a, cancels: 0 };
  const any = a as unknown as Record<string, unknown>;
  any.agent = "pi";
  any.promptCapabilities = { image: false };
  any.start = async () => {};
  any.send = async () => {
    a.emit("status", "running");
  };
  any.steer = async () => false;
  any.cancel = async () => {
    box.cancels += 1;
  };
  any.kill = async () => {};
  return box;
}

function harness() {
  const box = busyAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: box.adapter });
  const r = new CommandRouter();
  const deps = {
    manager: { getSession: (id: string) => (id === session.id ? session : undefined) },
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
    askDevice: async () => ({}) as never,
    gateway: {} as never,
  } as unknown as CommandDeps;
  registerSession(r, deps);

  const sent: OutgoingFrame[] = [];
  const client: WsClient = {
    send: (f: OutgoingFrame) => sent.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
  } as unknown as WsClient;

  const cmd = (env: Record<string, unknown>) =>
    r.dispatch(client, { v: 1, t: "cmd", id: "1", ...env } as never);

  return { session, box, cmd, sent };
}

test("queue.cancel drops exactly the named pending message", async () => {
  const h = harness();
  await h.session.sendUserMessage("first");
  await h.session.sendUserMessage("a");
  await h.session.sendUserMessage("b");
  const [a] = h.session.queuedMessages;

  await h.cmd({ kind: "queue.cancel", sessionId: h.session.id, id: a.id });

  assert.deepEqual(h.session.queuedMessages.map((q) => q.text), ["b"]);
  assert.ok(h.sent.some((f) => f.t === "ack"));
});

test("queue.cancel with an unknown id is an ack, not an error", async () => {
  const h = harness();
  await h.session.sendUserMessage("first");
  await h.session.sendUserMessage("a");

  await h.cmd({ kind: "queue.cancel", sessionId: h.session.id, id: "nope" });

  assert.equal(h.session.queuedMessages.length, 1);
  assert.ok(h.sent.some((f) => f.t === "ack"));
  assert.ok(!h.sent.some((f) => f.t === "err"), "a stale id is a race, not a client bug");
});

test("queue.cancel on an unknown session errors", async () => {
  const h = harness();
  await h.cmd({ kind: "queue.cancel", sessionId: "ghost", id: "x" });
  assert.ok(h.sent.some((f) => f.t === "err"));
});

test("cancel (stop) interrupts the turn AND empties the queue", async () => {
  const h = harness();
  await h.session.sendUserMessage("first");
  await h.session.sendUserMessage("a");
  await h.session.sendUserMessage("b");
  assert.equal(h.session.queuedMessages.length, 2);

  await h.cmd({ kind: "cancel", sessionId: h.session.id });

  assert.equal(h.box.cancels, 1);
  assert.equal(h.session.queuedMessages.length, 0, "stop means stop");
});
