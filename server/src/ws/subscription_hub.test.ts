/**
 * SubscriptionHub fanout gate (SPEC-46 T5 / D17 rev 3).
 *
 * `fanout` deliberately ignores subscription and auto-mirrors every session's
 * events to every authed client — correct for a phone, which must stay in sync
 * without sub'ing first. But it is NOT a command, so the router's capability
 * check does not cover it: an agent-scoped token that merely connects would
 * otherwise receive every transcript on the machine. The gate closes that: a
 * session-scoped principal receives only its own session; everything else keeps
 * today's auto-mirror.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { SubscriptionHub } from "./subscription_hub.js";
import type { WsClient } from "./client.js";
import type { Principal } from "./principal.js";
import type { SessionEvent } from "../protocol.js";

function fakeClient(principal?: Principal): WsClient & { events: string[] } {
  const events: string[] = [];
  return {
    events,
    send: (frame) => {
      const f = frame as { kind?: string; event?: { sessionId?: string } };
      if (f.kind === "session.event") events.push("event");
    },
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    principal,
    watchingMetrics: false,
    watchingPorts: false,
    isLocal: false,
  };
}

const hub = () => new SubscriptionHub({ manager: { getSession: () => undefined } });
const ev = (): SessionEvent => ({ seq: 1, kind: "session.delta", text: "x" }) as unknown as SessionEvent;

test("a session-scoped principal receives only its own session's events", () => {
  const h = hub();
  const client = fakeClient({ deviceId: "A", label: "agent", caps: ["read"], sessionId: "A" });
  h.register(client);

  h.fanout("A", ev());
  h.fanout("B", ev());

  assert.equal(client.events.length, 1, "should receive session A only, not B");
});

test("a no-caps principal (existing phone) still receives every session's events", () => {
  const h = hub();
  const client = fakeClient({ deviceId: "phone", label: "phone" }); // caps undefined = full
  h.register(client);

  h.fanout("A", ev());
  h.fanout("B", ev());

  assert.equal(client.events.length, 2, "auto-mirror must stay intact for a phone");
});

test("a client-cap principal (cli@host) keeps the auto-mirror too", () => {
  const h = hub();
  const client = fakeClient({ deviceId: "cli", label: "cli@host", caps: ["client"] });
  h.register(client);

  h.fanout("A", ev());
  h.fanout("B", ev());

  assert.equal(client.events.length, 2);
});
