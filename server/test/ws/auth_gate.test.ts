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

function fakeClient(authed = false, isLocal = true): FakeClient {
  const sent: OutgoingFrame[] = [];
  const client: FakeClient = {
    sent,
    closed: null,
    authed,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    watchingPorts: false,
    watchingDocs: false,
    isLocal,
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

// ── SPEC-performance-metrics-dashboard: the app's reported pid is accepted ONLY on a loopback socket ────

test("hello {pid} on a loopback client sets appPid (SPEC-performance-metrics-dashboard decision 6)", () => {
  const gate = new AuthGate({ registry: fakeRegistry({}), onAuthenticated: () => {} });
  const client = fakeClient(true);
  (client as { isLocal: boolean }).isLocal = true;

  gate.handleHello(client, hello({ pid: 4242 }));

  assert.equal(client.appPid, 4242, "a loopback client's reported pid is accepted");
});

test("hello {pid} on a non-loopback client is ignored, appPid stays unset (SPEC-performance-metrics-dashboard decision 6)", () => {
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

// D8 rev 2: the app must not infer locality from its own stored host — mDNS
// rediscovery can rewrite that behind it (see connection.dart), so the server
// states it, per client, at the one moment the app is guaranteed to be listening.
test("hello.ack carries isLocal so the client never has to guess", () => {
  const device = { id: "dev-1", label: "phone", bearer: "good-bearer" };
  const gate = () =>
    new AuthGate({
      registry: fakeRegistry({ bearers: { "good-bearer": device } }),
      onAuthenticated: () => {},
    });

  const local = fakeClient();
  gate().handleHello(local, hello({ bearer: "good-bearer" }));
  assert.equal(local.sent.find((f) => f.t === "hello.ack")?.isLocal, true);

  const remote = fakeClient(false, false);
  gate().handleHello(remote, hello({ bearer: "good-bearer" }));
  assert.equal(remote.sent.find((f) => f.t === "hello.ack")?.isLocal, false);
});

// There are THREE hello.ack sends (already-trusted, bearer, pair) and the first
// pass patched two. A device that pairs would then never learn it is local, and
// would silently publish instead of opening — the feature quietly off.
test("every hello.ack path states isLocal, including the pairing one", () => {
  const registry = fakeRegistry({ pairTokens: { "pair-1": { id: "d1", label: "mac", bearer: "b1" } } });
  const client = fakeClient();
  new AuthGate({ registry, onAuthenticated: () => {} }).handleHello(
    client,
    hello({ pair: "pair-1", label: "mac" }),
  );
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack, "pairing must ack");
  assert.equal(ack?.isLocal, true, "the pairing ack must carry isLocal too");
});

// The two remaining hello.ack paths: the already-trusted (bearer-less loopback)
// ack, and a REMOTE pairing client which must learn it is NOT local so it
// publishes rather than trying to open on a host it is not on.
test("the already-trusted (loopback) hello.ack states isLocal: true", () => {
  const client = fakeClient(true); // authed, no token, local
  new AuthGate({ registry: fakeRegistry({}), onAuthenticated: () => {} }).handleHello(
    client,
    hello({}),
  );
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack, "an already-trusted client must ack");
  assert.equal(ack?.isLocal, true);
});

test("a remote pairing client's hello.ack states isLocal: false", () => {
  const registry = fakeRegistry({ pairTokens: { "pair-2": { id: "d2", label: "phone", bearer: "b2" } } });
  const client = fakeClient(false, false); // unauthed, remote
  new AuthGate({ registry, onAuthenticated: () => {} }).handleHello(
    client,
    hello({ pair: "pair-2", label: "phone" }),
  );
  const ack = client.sent.find((f) => f.t === "hello.ack");
  assert.ok(ack, "pairing must ack");
  assert.equal(ack?.isLocal, false, "a remote pairing client must learn it is not local");
});
