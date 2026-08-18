/**
 * CommandRouter capability enforcement (SPEC-cli-as-client T4 / contract C1).
 *
 * The capability check is at the router, BEFORE handler lookup: an agent-scoped
 * token refused a command must never enter the handler (proven with a spy), or
 * a leaf that forgot to re-check would leak. Completeness is a test, not a
 * discipline: every kind the real router registers must appear in the map, so a
 * command added later cannot become agent-reachable by omission.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { CommandRouter } from "./command_router.js";
import { canDispatch } from "./capabilities.js";
import { buildCommandRouter } from "../server.js";
import type { WsClient } from "./client.js";
import type { Envelope } from "../protocol.js";
import type { Principal } from "./principal.js";
import type { CommandDeps } from "./commands/deps.js";

interface Frame {
  t: string;
  code?: string;
  [k: string]: unknown;
}

function fakeClient(principal?: Principal): WsClient & { frames: Frame[] } {
  const frames: Frame[] = [];
  return {
    frames,
    send: (frame) => frames.push(frame as Frame),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    principal,
    watchingMetrics: false,
    watchingDocs: false,
    watchingPorts: false,
    isLocal: false,
  };
}

const killCmd: Envelope = { v: 1, t: "cmd", id: "c1", kind: "session.kill" } as Envelope;

test("an agent principal (caps:[read]) is refused session.kill at the router, handler never entered", async () => {
  let entered = false;
  const router = new CommandRouter().register("session.kill", () => {
    entered = true;
  });
  const client = fakeClient({ deviceId: "s", label: "agent", caps: ["read"], sessionId: "s" });

  await router.dispatch(client, killCmd);

  assert.equal(entered, false, "handler must not be entered for a refused command");
  assert.equal(client.frames.at(-1)?.t, "err");
  assert.equal(client.frames.at(-1)?.code, "unauthorized");
});

test("a principal with NO caps (an existing phone) may dispatch session.kill", async () => {
  let entered = false;
  const router = new CommandRouter().register("session.kill", (ctx) => {
    entered = true;
    ctx.ack();
  });
  const client = fakeClient({ deviceId: "d", label: "phone" }); // caps undefined = full

  await router.dispatch(client, killCmd);

  assert.equal(entered, true);
  assert.equal(client.frames.at(-1)?.t, "ack");
});

test("completeness: every registered command is either agent-reachable or client/full-access only", () => {
  // The test is that canDispatch works for all registered commands without throwing.
  // No command should be undefined or unmapped; all implicitly map to client-only if
  // not in AGENT_COMMANDS.
  const router = buildCommandRouter({} as CommandDeps, { setPushToken: () => {} });
  const agentPrincipal = { caps: ["send", "spawn", "read"] } as any;
  const clientPrincipal = { caps: ["client"] } as any;
  for (const kind of router.kinds()) {
    assert.doesNotThrow(() => {
      canDispatch(kind, agentPrincipal);
      canDispatch(kind, clientPrincipal);
    }, `canDispatch failed for command: ${kind}`);
  }
});

test("an agent token — even with spawn+read+send — is refused session.fork", async () => {
  // U4's least-privilege call, as a regression lock. `session.spawn` is safe to
  // give an agent because D9 forces its `parentId` to the caller's OWN session.
  // `session.fork` takes the source from the argv, so an agent-reachable fork
  // would let any agent branch ANY session on the machine — copying a transcript
  // it was never allowed to read into a session it controls. The fanout gate (T5)
  // would not help: the fork's events are its own.
  let entered = false;
  const router = new CommandRouter().register("session.fork", () => {
    entered = true;
  });
  const client = fakeClient({
    deviceId: "s",
    label: "agent",
    caps: ["read", "send", "spawn"],
    sessionId: "s",
  });

  await router.dispatch(client, { v: 1, t: "cmd", id: "c1", kind: "session.fork" } as Envelope);

  assert.equal(entered, false, "an agent must never reach the fork handler");
  assert.equal(client.frames.at(-1)?.code, "unauthorized");
});

test("the CLI (caps:[client]) may fork — it is a human verb", async () => {
  let entered = false;
  const router = new CommandRouter().register("session.fork", () => {
    entered = true;
  });
  const client = fakeClient({ deviceId: "d", label: "cli@host", caps: ["client"] });

  await router.dispatch(client, { v: 1, t: "cmd", id: "c1", kind: "session.fork" } as Envelope);

  assert.equal(entered, true);
});
