import { test } from "node:test";
import assert from "node:assert/strict";

import { ReverseRpc } from "../../src/ws/reverse_rpc.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";

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

test("askDevice resolves with the first srv.response", async () => {
  const client = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [client] });

  const promise = rpc.askDevice({ kind: "askUserQuestion" });
  const req = client.sent.find((f) => f.t === "srv.request");
  assert.ok(req, "srv.request sent");

  rpc.handleResponse({ v: 1, t: "srv.response", id: String(req!.id), answer: "Yes" } as Envelope);

  const resp = await promise;
  assert.equal(resp.answer, "Yes");
});

test("first response wins; later responses for the same id are ignored", async () => {
  const client = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [client] });

  const promise = rpc.askDevice({ kind: "askUserQuestion" });
  const id = String(client.sent.find((f) => f.t === "srv.request")!.id);

  rpc.handleResponse({ v: 1, t: "srv.response", id, answer: "first" } as Envelope);
  // Second response must be a no-op (no throw, promise already settled).
  rpc.handleResponse({ v: 1, t: "srv.response", id, answer: "second" } as Envelope);

  assert.equal((await promise).answer, "first");
});

test("askDevice times out when no response arrives", async () => {
  const client = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [client] });

  await assert.rejects(
    rpc.askDevice({ kind: "askUserQuestion" }, { timeoutMs: 10 }),
    /timed out/,
  );
});

test("askDevice rejects when there are no subscribed clients to ask", async () => {
  const unauthed = fakeClient(false);
  const rpc = new ReverseRpc({ clients: () => [unauthed] });

  await assert.rejects(
    rpc.askDevice({ kind: "askUserQuestion" }),
    /no subscribed clients to ask/,
  );
});

test("sessionId scoping only asks clients subscribed to that session", async () => {
  const subscribed = fakeClient(true, ["sess-1"]);
  const other = fakeClient(true, ["sess-2"]);
  const rpc = new ReverseRpc({ clients: () => [subscribed, other] });

  const promise = rpc.askDevice({ kind: "askUserQuestion" }, { sessionId: "sess-1" });

  assert.equal(subscribed.sent.filter((f) => f.t === "srv.request").length, 1);
  assert.equal(other.sent.filter((f) => f.t === "srv.request").length, 0);
  const req = subscribed.sent.find((f) => f.t === "srv.request")!;
  assert.equal(req.sessionId, "sess-1");

  rpc.handleResponse({ v: 1, t: "srv.response", id: String(req.id), ok: true } as Envelope);
  assert.equal((await promise).ok, true);
});

test("scoped askDevice rejects when no subscriber matches the session", async () => {
  const other = fakeClient(true, ["sess-2"]);
  const rpc = new ReverseRpc({ clients: () => [other] });

  await assert.rejects(
    rpc.askDevice({ kind: "askUserQuestion" }, { sessionId: "sess-1" }),
    /no subscribed clients to ask/,
  );
});
