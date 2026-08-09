/**
 * CommandRouter capability enforcement (SPEC-46 T4 / contract C1).
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
import { COMMAND_CAPABILITIES } from "./capabilities.js";
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

test("completeness: every kind the real router registers appears in the capability map", () => {
  const router = buildCommandRouter({} as CommandDeps, { setPushToken: () => {} });
  const missing = router.kinds().filter((k) => !(k in COMMAND_CAPABILITIES));
  assert.deepEqual(missing, [], `command kinds missing from the capability map: ${missing.join(", ")}`);
});
