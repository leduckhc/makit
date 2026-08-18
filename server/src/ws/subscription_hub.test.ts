/**
 * SubscriptionHub fanout gate (SPEC-cli-as-client T5 / D17 rev 3).
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
    watchingDocs: false,
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
  // Fan-out is batched per window now (see subscription_hub_batch.test.ts); this
  // test is about the visibility rule, so close the window by hand.
  h.flush(client);

  assert.equal(client.events.length, 1, "should receive session A only, not B");
});

test("a no-caps principal (existing phone) still receives every session's events", () => {
  const h = hub();
  const client = fakeClient({ deviceId: "phone", label: "phone" }); // caps undefined = full
  h.register(client);

  h.fanout("A", ev());
  h.fanout("B", ev());
  // Fan-out is batched per window now (see subscription_hub_batch.test.ts); this
  // test is about the visibility rule, so close the window by hand.
  h.flush(client);

  assert.equal(client.events.length, 2, "auto-mirror must stay intact for a phone");
});

test("a client-cap principal (cli@host) keeps the auto-mirror too", () => {
  const h = hub();
  const client = fakeClient({ deviceId: "cli", label: "cli@host", caps: ["client"] });
  h.register(client);

  h.fanout("A", ev());
  h.fanout("B", ev());
  // Fan-out is batched per window now (see subscription_hub_batch.test.ts); this
  // test is about the visibility rule, so close the window by hand.
  h.flush(client);

  assert.equal(client.events.length, 2);
});

// ---------------------------------------------------------------------------
// D17 read paths beyond fanout (the hole T5's acceptance box did not cover)
// ---------------------------------------------------------------------------

/** A hub whose sessions exist and carry one event, with lineage root → child. */
const hubWithLog = () =>
  new SubscriptionHub({
    manager: {
      getSession: (id: string) =>
        ({
          eventsSince: () => [
            { seq: 1, sessionId: id, ts: 1, kind: "agent.message", payload: { text: "secret" } },
          ],
        }) as never,
    },
    parentOf: (id: string) => (id === "child" ? "root" : undefined),
  });

const subFrame = (sessionId: string) =>
  ({ v: 1, t: "sub", id: "s1", sessionId }) as never;

test("sub: an agent may NOT subscribe to an unrelated session — it would replay the log", () => {
  // `sub` bypasses the router (server.ts answers it in a switch before dispatch),
  // so the capability map never sees it. Without a check here, one frame hands an
  // agent token another user's entire transcript.
  const h = hubWithLog();
  const client = fakeClient({ deviceId: "root", label: "agent", caps: ["read"], sessionId: "root" });
  h.register(client);

  h.handleSub(client, subFrame("stranger"));

  assert.equal(client.events.length, 0, "no events replayed");
  assert.equal(client.subscribed.has("stranger"), false, "and no subscription recorded");
});

test("sub: an agent may subscribe to its own session and to a descendant", () => {
  const h = hubWithLog();
  const client = fakeClient({ deviceId: "root", label: "agent", caps: ["read"], sessionId: "root" });
  h.register(client);

  h.handleSub(client, subFrame("root"));
  h.handleSub(client, subFrame("child"));

  assert.ok(client.subscribed.has("root"));
  assert.ok(client.subscribed.has("child"), "the session it handed work off to");
});

test("sub: a phone still subscribes to anything", () => {
  const h = hubWithLog();
  const client = fakeClient(); // no principal at all = full access
  h.register(client);

  h.handleSub(client, subFrame("stranger"));

  assert.ok(client.subscribed.has("stranger"));
});

test("fanout reaches a descendant too, matching D17's wording", () => {
  const h = hubWithLog();
  const client = fakeClient({ deviceId: "root", label: "agent", caps: ["read"], sessionId: "root" });
  h.register(client);

  h.fanout("child", ev());
  h.flush(client);

  assert.equal(client.events.length, 1, "an agent sees the child it spawned");
});
