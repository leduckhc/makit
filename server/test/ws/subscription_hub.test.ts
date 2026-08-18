import { test } from "node:test";
import assert from "node:assert/strict";

import { SubscriptionHub } from "../../src/ws/subscription_hub.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope, SessionEvent } from "../../src/protocol.js";
import { WireErrorCode } from "../../src/protocol/codec.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(authed = true): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    watchingPorts: false,
    watchingDocs: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

function evt(seq: number, sessionId: string): SessionEvent {
  return { seq, sessionId, ts: seq, kind: "agent.message", payload: { text: `m${seq}` } };
}

function subEnv(sessionId?: string, fromSeq?: number): Envelope {
  return {
    v: 1,
    t: "sub",
    id: "s1",
    ...(sessionId ? { sessionId } : {}),
    ...(fromSeq !== undefined ? { fromSeq } : {}),
  } as Envelope;
}

function fakeManager(sessions: Record<string, SessionEvent[]>) {
  return {
    getSession: (id: string) =>
      id in sessions
        ? {
            // The real session serves the tail from memory and the rest from the
            // store; the hub only cares that it gets events above the cursor.
            eventsSince: (fromSeq: number) =>
              sessions[id].filter((e) => e.seq > fromSeq),
          }
        : undefined,
  };
}

test("sub to a known session replays events and acks", () => {
  const hub = new SubscriptionHub({
    manager: fakeManager({ "sess-1": [evt(1, "sess-1"), evt(2, "sess-1")] }),
  });
  const client = fakeClient();
  hub.register(client);

  hub.handleSub(client, subEnv("sess-1"));

  assert.ok(client.subscribed.has("sess-1"));
  const events = client.sent.filter((f) => f.t === "event");
  assert.equal(events.length, 2);
  assert.ok(client.sent.find((f) => f.t === "ack" && f.id === "s1"));
});

test("sub with fromSeq replays only events after the cursor", () => {
  const hub = new SubscriptionHub({
    manager: fakeManager({
      "sess-1": [evt(1, "sess-1"), evt(2, "sess-1"), evt(3, "sess-1")],
    }),
  });
  const client = fakeClient();
  hub.register(client);

  hub.handleSub(client, subEnv("sess-1", 2));

  const events = client.sent.filter((f) => f.t === "event") as Array<{
    event: SessionEvent;
  }>;
  assert.deepEqual(
    events.map((f) => f.event.seq),
    [3],
  );
  assert.ok(client.sent.find((f) => f.t === "ack" && f.id === "s1"));
});

test("sub with fromSeq=0 replays the full log (back-compat)", () => {
  const hub = new SubscriptionHub({
    manager: fakeManager({ "sess-1": [evt(1, "sess-1"), evt(2, "sess-1")] }),
  });
  const client = fakeClient();
  hub.register(client);

  hub.handleSub(client, subEnv("sess-1", 0));

  assert.equal(client.sent.filter((f) => f.t === "event").length, 2);
});

test("sub without sessionId is a bad_request", () => {
  const hub = new SubscriptionHub({ manager: fakeManager({}) });
  const client = fakeClient();
  hub.register(client);

  hub.handleSub(client, subEnv());

  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.equal(client.subscribed.size, 0);
});

test("sub to an unknown session errors with no_such_session", () => {
  const hub = new SubscriptionHub({ manager: fakeManager({}) });
  const client = fakeClient();
  hub.register(client);

  hub.handleSub(client, subEnv("ghost"));

  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.NoSuchSession);
});

test("unsub removes the subscription and acks", () => {
  const hub = new SubscriptionHub({
    manager: fakeManager({ "sess-1": [] }),
  });
  const client = fakeClient();
  hub.register(client);
  hub.handleSub(client, subEnv("sess-1"));

  hub.handleUnsub(client, { v: 1, t: "unsub", id: "u1", sessionId: "sess-1" } as Envelope);

  assert.equal(client.subscribed.has("sess-1"), false);
  assert.ok(client.sent.find((f) => f.t === "ack" && f.id === "u1"));
});

test("fanout auto-mirrors to every authed client regardless of subscription", () => {
  const hub = new SubscriptionHub({
    manager: fakeManager({ "sess-1": [] }),
  });
  const subscribed = fakeClient(true);
  const notSubscribed = fakeClient(true);
  const unauthed = fakeClient(false);
  hub.register(subscribed);
  hub.register(notSubscribed);
  hub.register(unauthed);

  hub.handleSub(subscribed, subEnv("sess-1"));
  unauthed.subscribed.add("sess-1"); // authed=false → still excluded

  const count = hub.fanout("sess-1", evt(3, "sess-1"));
  // Fan-out is batched per window; close it so the frames are countable here.
  hub.flushAll();

  // Auto-mirror: both authed clients receive it, even the one that never subbed.
  assert.equal(count, 2);
  assert.ok(subscribed.sent.find((f) => f.t === "event" && f.kind === "session.event"));
  assert.ok(notSubscribed.sent.find((f) => f.t === "event" && f.kind === "session.event"));
  assert.equal(unauthed.sent.filter((f) => f.t === "event").length, 0);
});

test("unregister stops fan-out to a client", () => {
  const hub = new SubscriptionHub({ manager: fakeManager({ "sess-1": [] }) });
  const client = fakeClient(true);
  hub.register(client);
  hub.handleSub(client, subEnv("sess-1"));

  hub.unregister(client);
  const count = hub.fanout("sess-1", evt(4, "sess-1"));

  assert.equal(count, 0);
});
