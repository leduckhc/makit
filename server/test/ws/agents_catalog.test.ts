/**
 * Lane-1 (SPEC-27) `agents.list` / `agents.refresh` handler tests: the session
 * command registrars serve enriched descriptors from the capability cache and
 * `agents.refresh` forces a re-probe. Uses the real {@link CommandRouter} with
 * a minimal fake manager (only the two methods these handlers call).
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { CommandRouter } from "../../src/ws/command_router.js";
import { register } from "../../src/ws/commands/session.js";
import type { CommandDeps } from "../../src/ws/commands/deps.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";
import type { AgentDescriptor } from "../../src/adapters/catalog.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: true,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    watchingPorts: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

function cmd(kind: string, fields: Partial<Envelope> = {}): Envelope {
  return { v: 1, t: "cmd", id: "c1", kind, ...fields } as Envelope;
}

const PI: AgentDescriptor = {
  id: "pi",
  label: "Pi (ACP)",
  transport: "acp",
  available: true,
  fingerprint: "fp1",
  configOptions: [
    { id: "model", name: "Model", category: "model", type: "select", currentValue: "gpt-5", options: [{ value: "gpt-5", name: "GPT-5" }] },
  ],
};

function routerWith(manager: Partial<CommandDeps["manager"]>): { router: CommandRouter; client: FakeClient } {
  const router = new CommandRouter();
  const deps = {
    manager: manager as CommandDeps["manager"],
    gateway: {} as CommandDeps["gateway"],
    budgetWatch: {} as CommandDeps["budgetWatch"],
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
      onMetricsWatchersChanged: () => {},
      sendMetricsHistory: () => {},
      onPortsWatchersChanged: () => {},
      sendPortsSnapshot: () => {},
    askDevice: async () => ({}) as Envelope,
  } satisfies CommandDeps;
  register(router, deps);
  return { router, client: fakeClient() };
}

test("agents.list acks descriptors enriched from the capability cache", async () => {
  const { router, client } = routerWith({
    listAgentsWithCapabilities: async () => [PI],
  });
  await router.dispatch(client, cmd("agents.list"));
  const ack = client.sent.find((f) => f.t === "ack");
  assert.ok(ack);
  const agents = (ack as any).agents as AgentDescriptor[];
  assert.equal(agents.length, 1);
  assert.equal(agents[0].id, "pi");
  assert.equal(agents[0].configOptions?.[0].id, "model");
  assert.equal(agents[0].fingerprint, "fp1");
});

test("agents.refresh forces a re-probe and acks the fresh descriptor", async () => {
  let refreshed: string | undefined;
  const { router, client } = routerWith({
    refreshAgent: async (agent: string) => {
      refreshed = agent;
      return { ...PI, fingerprint: "fp2" };
    },
  });
  await router.dispatch(client, cmd("agents.refresh", { agent: "pi" }));
  assert.equal(refreshed, "pi");
  const ack = client.sent.find((f) => f.t === "ack");
  assert.ok(ack);
  assert.equal(((ack as any).agent as AgentDescriptor).fingerprint, "fp2");
});

test("agents.refresh without an agent is a bad_request", async () => {
  const { router, client } = routerWith({ refreshAgent: async () => undefined });
  await router.dispatch(client, cmd("agents.refresh"));
  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.match(String((err as any).message), /requires an .agent/);
});

test("agents.refresh for an unknown agent is a bad_request", async () => {
  const { router, client } = routerWith({ refreshAgent: async () => undefined });
  await router.dispatch(client, cmd("agents.refresh", { agent: "ghost" }));
  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.match(String((err as any).message), /unknown agent/);
});
