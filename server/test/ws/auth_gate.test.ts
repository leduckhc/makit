import { test } from "node:test";
import assert from "node:assert/strict";

import { AuthGate } from "../../src/ws/auth_gate.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";

interface FakeDevice {
  id: string;
  label: string;
  bearer: string;
}

/** Minimal registry stub honouring the two methods AuthGate consumes. */
function fakeRegistry(opts: {
  bearers?: Record<string, FakeDevice>;
  pairTokens?: Record<string, FakeDevice>;
}) {
  return {
    authenticate: (bearer: string) => opts.bearers?.[bearer] ?? null,
    consumePairToken: (token: string, _label: string) =>
      opts.pairTokens?.[token] ?? null,
  };
}

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
  closed: { code: number; reason: string } | null;
}

function fakeClient(authed = false): FakeClient {
  const sent: OutgoingFrame[] = [];
  const client: FakeClient = {
    sent,
    closed: null,
    authed,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: (code, reason) => {
      client.closed = { code, reason };
    },
  };
  return client;
}

function hello(fields: Partial<Envelope>): Envelope {
  return { v: 1, t: "hello", id: "h1", ...fields } as Envelope;
}

test("valid bearer authenticates and sends snapshots", () => {
  const device = { id: "dev-1", label: "phone", bearer: "good-bearer" };
  let snapshotsFor: WsClient | null = null;
  const gate = new AuthGate({
    registry: fakeRegistry({ bearers: { "good-bearer": device } }),
    onAuthenticated: (c) => {
      snapshotsFor = c;
    },
  });
  const client = fakeClient();

  gate.handleHello(client, hello({ bearer: "good-bearer" }));

  assert.equal(client.authed, true);
  assert.equal(client.deviceLabel, "phone");
  assert.equal(client.closed, null);
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack, "hello.ack sent");
  assert.equal(ack!.ok, true);
  assert.equal(ack!.deviceId, "dev-1");
  assert.equal(snapshotsFor, client);
});

test("unknown bearer is rejected and closed", () => {
  const gate = new AuthGate({
    registry: fakeRegistry({ bearers: {} }),
    onAuthenticated: () => assert.fail("must not authenticate"),
  });
  const client = fakeClient();

  gate.handleHello(client, hello({ bearer: "nope" }));

  assert.equal(client.authed, false);
  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err, "err frame sent");
  assert.deepEqual(client.closed, { code: 4401, reason: "unauthorized" });
});

test("valid pair token mints a device and returns its bearer", () => {
  const device = { id: "dev-2", label: "ipad", bearer: "fresh-bearer" };
  let snapshotsFor: WsClient | null = null;
  const gate = new AuthGate({
    registry: fakeRegistry({ pairTokens: { "pair-tok": device } }),
    onAuthenticated: (c) => {
      snapshotsFor = c;
    },
  });
  const client = fakeClient();

  gate.handleHello(client, hello({ pair: "pair-tok", label: "ipad" }));

  assert.equal(client.authed, true);
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack);
  assert.equal(ack!.bearer, "fresh-bearer");
  assert.equal(ack!.deviceId, "dev-2");
  assert.equal(snapshotsFor, client);
});

test("invalid pair token is rejected and closed", () => {
  const gate = new AuthGate({
    registry: fakeRegistry({ pairTokens: {} }),
    onAuthenticated: () => assert.fail("must not authenticate"),
  });
  const client = fakeClient();

  gate.handleHello(client, hello({ pair: "bad" }));

  assert.equal(client.authed, false);
  assert.ok(client.sent.find((f) => f.t === "err"));
  assert.deepEqual(client.closed, { code: 4401, reason: "unauthorized" });
});

test("hello without bearer or pair on an unauthed client is rejected", () => {
  const gate = new AuthGate({
    registry: fakeRegistry({}),
    onAuthenticated: () => assert.fail("must not authenticate"),
  });
  const client = fakeClient();

  gate.handleHello(client, hello({}));

  assert.equal(client.authed, false);
  assert.deepEqual(client.closed, { code: 4401, reason: "unauthorized" });
});

test("already-trusted (localhost) hello acks without a token", () => {
  let snapshotsFor: WsClient | null = null;
  const gate = new AuthGate({
    registry: fakeRegistry({}),
    onAuthenticated: (c) => {
      snapshotsFor = c;
    },
  });
  const client = fakeClient(true);

  gate.handleHello(client, hello({}));

  assert.equal(client.authed, true);
  assert.equal(client.closed, null);
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack);
  assert.equal(ack!.ok, true);
  assert.equal(snapshotsFor, client);
});

// ── SPEC-37: the app's reported pid is accepted ONLY on a loopback socket ────

test("hello {pid} on a loopback client sets appPid (SPEC-37 decision 6)", () => {
  const gate = new AuthGate({ registry: fakeRegistry({}), onAuthenticated: () => {} });
  const client = fakeClient(true);
  (client as { isLocal: boolean }).isLocal = true;

  gate.handleHello(client, hello({ pid: 4242 }));

  assert.equal(client.appPid, 4242, "a loopback client's reported pid is accepted");
});

test("hello {pid} on a non-loopback client is ignored, appPid stays unset (SPEC-37 decision 6)", () => {
  const device = { id: "dev-x", label: "phone", bearer: "good" };
  const gate = new AuthGate({
    registry: fakeRegistry({ bearers: { good: device } }),
    onAuthenticated: () => {},
  });
  const client = fakeClient(false);
  (client as { isLocal: boolean }).isLocal = false;

  // A phone must still connect normally — the pid is simply dropped.
  gate.handleHello(client, hello({ bearer: "good", pid: 4242 }));

  assert.equal(client.authed, true, "a non-loopback client still authenticates");
  assert.equal(client.appPid, undefined, "its reported pid is ignored");
});
