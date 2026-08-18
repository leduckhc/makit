/**
 * One frame per streamed token is one radio wake per token.
 *
 * The metrics dashboard measured a peak of 2184 outbound frames per second: the
 * hub sent every event to every client the moment it arrived. Each one is a JSON
 * encode, a socket write and — on a phone — a wake.
 *
 * The hub now collects a client's events and sends them as ONE
 * `session.events` frame per window. A client that did not announce the
 * capability in `hello` keeps receiving one `session.event` per event, so an
 * older app still works.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { SubscriptionHub } from "./subscription_hub.js";
import type { WsClient, OutgoingFrame } from "./client.js";
import type { SessionEvent } from "../protocol.js";

function evt(seq: number, sessionId = "s1"): SessionEvent {
  return { seq, sessionId, ts: seq, kind: "agent.message.delta", payload: { chunk: `c${seq}` } };
}

/** A client that records frames, with a hand-run flush window. */
function fakeClient(opts: { batches?: boolean } = {}) {
  const frames: OutgoingFrame[] = [];
  const client = {
    frames,
    send: (f: OutgoingFrame) => frames.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    acceptsEventBatches: opts.batches ?? false,
    watchingMetrics: false,
    watchingPorts: false,
    watchingDocs: false,
    isLocal: true,
  };
  return client as unknown as WsClient & { frames: OutgoingFrame[] };
}

function hubWith(pending: (fn: () => void) => void) {
  return new SubscriptionHub({
    manager: { getSession: () => ({ eventsSince: () => [] }) },
    schedule: (_ms, fn) => {
      pending(fn);
      return { cancel: () => {} };
    },
  });
}

test("a burst becomes one frame for a client that accepts batches", () => {
  let flush: (() => void) | undefined;
  const hub = hubWith((fn) => (flush = fn));
  const client = fakeClient({ batches: true });
  hub.register(client);

  for (let seq = 1; seq <= 30; seq++) hub.fanout("s1", evt(seq));
  assert.equal(client.frames.length, 0, "nothing goes before the window closes");

  flush?.();

  assert.equal(client.frames.length, 1, "30 events, one frame");
  const frame = client.frames[0] as unknown as { kind: string; events: SessionEvent[] };
  assert.equal(frame.kind, "session.events");
  assert.deepEqual(frame.events.map((e) => e.seq), Array.from({ length: 30 }, (_, i) => i + 1));
});

test("an app that did not announce the capability still gets one frame per event", () => {
  let flush: (() => void) | undefined;
  const hub = hubWith((fn) => (flush = fn));
  const client = fakeClient({ batches: false });
  hub.register(client);

  hub.fanout("s1", evt(1));
  hub.fanout("s1", evt(2));
  flush?.();

  assert.deepEqual(
    client.frames.map((f) => (f as unknown as { kind: string }).kind),
    ["session.event", "session.event"],
  );
});

test("any other frame flushes the pending events first, so order holds", () => {
  let flush: (() => void) | undefined;
  const hub = hubWith((fn) => (flush = fn));
  const client = fakeClient({ batches: true });
  hub.register(client);

  hub.fanout("s1", evt(1));
  // A `sub` ack, a sessions snapshot, an approval request: anything the server
  // sends outside the fan-out must not overtake the events already fanned out.
  hub.sendDirect(client, { t: "ack", id: "s-s1" });

  const kinds = client.frames.map((f) => (f as unknown as { kind?: string; t: string }).kind ?? f.t);
  assert.deepEqual(kinds, ["session.events", "ack"]);
  flush?.();
  assert.equal(client.frames.length, 2, "the flush finds nothing left");
});

test("a client that leaves takes its pending events with it", () => {
  let flush: (() => void) | undefined;
  const hub = hubWith((fn) => (flush = fn));
  const client = fakeClient({ batches: true });
  hub.register(client);

  hub.fanout("s1", evt(1));
  hub.unregister(client);
  flush?.();

  assert.equal(client.frames.length, 0, "a closed socket is not written to");
});

test("events of two sessions ride in one frame, in arrival order", () => {
  let flush: (() => void) | undefined;
  const hub = hubWith((fn) => (flush = fn));
  const client = fakeClient({ batches: true });
  hub.register(client);

  hub.fanout("s1", evt(1, "s1"));
  hub.fanout("s2", evt(1, "s2"));
  hub.fanout("s1", evt(2, "s1"));
  flush?.();

  const frame = client.frames[0] as unknown as { events: SessionEvent[] };
  assert.deepEqual(
    frame.events.map((e) => `${e.sessionId}#${e.seq}`),
    ["s1#1", "s2#1", "s1#2"],
  );
});
