import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DeviceRegistry } from "../src/pairing/registry.js";
import { CommandRouter } from "../src/ws/command_router.js";
import { registerPushCommands } from "../src/push/register_cmd.js";
import type { WsClient, OutgoingFrame } from "../src/ws/client.js";
import type { Envelope } from "../src/protocol.js";

async function withHome(fn: (home: string) => void | Promise<void>) {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-push-test-"));
  process.env.MAKIT_HOME = home;
  try {
    await fn(home);
  } finally {
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

function pairedDevice(reg: DeviceRegistry) {
  return reg.consumePairToken(reg.mintPairToken(), "phone")!;
}

// -------- A3: registry persistence -----------------------------------------

test("setPushToken persists across reload", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const d = pairedDevice(reg);
    reg.setPushToken(d.id, { token: "apns-tok", platform: "apns", env: "sandbox" });

    const reloaded = new DeviceRegistry();
    const found = reloaded.list().find((x) => x.id === d.id)!;
    assert.equal(found.pushToken, "apns-tok");
    assert.equal(found.pushPlatform, "apns");
    assert.equal(found.pushEnv, "sandbox");
  }));

test("clearPushToken drops the token and persists across reload", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const d = pairedDevice(reg);
    reg.setPushToken(d.id, { token: "apns-tok", platform: "apns" });
    reg.clearPushToken(d.id);

    const reloaded = new DeviceRegistry();
    const found = reloaded.list().find((x) => x.id === d.id)!;
    assert.ok(found, "device is still paired");
    assert.equal(found.pushToken, undefined);
    assert.equal(found.pushPlatform, undefined);
  }));

test("revoke clears the push token", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const d = pairedDevice(reg);
    reg.setPushToken(d.id, { token: "apns-tok", platform: "apns" });
    assert.equal(reg.revoke(d.id), true);
    assert.equal(reg.list().find((x) => x.id === d.id), undefined);
  }));

test("setPushToken/clearPushToken on unknown device is a no-op", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    assert.doesNotThrow(() => reg.setPushToken("nope", { token: "t", platform: "apns" }));
    assert.doesNotThrow(() => reg.clearPushToken("nope"));
    assert.equal(reg.list().length, 0);
  }));

// -------- A4: push.register cmd handler ------------------------------------

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(deviceId?: string): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: deviceId !== undefined,
    deviceId,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    watchingPorts: false,
    watchingDocs: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

function fakeRegistry() {
  const calls: { deviceId: string; token: string; platform: string; env?: string }[] = [];
  return {
    calls,
    setPushToken: (
      deviceId: string,
      info: { token: string; platform: string; env?: string },
    ) => {
      calls.push({ deviceId, ...info });
    },
  };
}

function dispatch(router: CommandRouter, client: WsClient, fields: Partial<Envelope>) {
  return router.dispatch(client, { v: 1, t: "cmd", id: "c1", kind: "push.register", ...fields } as Envelope);
}

test("push.register stores the token for the authed device", async () => {
  const registry = fakeRegistry();
  const router = new CommandRouter();
  registerPushCommands(router, registry);
  const client = fakeClient("d1");

  await dispatch(router, client, { token: "tok-abc", platform: "apns", env: "sandbox" });

  assert.deepEqual(registry.calls, [
    { deviceId: "d1", token: "tok-abc", platform: "apns", env: "sandbox" },
  ]);
  assert.ok(client.sent.some((f) => f.t === "ack"));
});

test("push.register defaults platform to apns when none is provided", async () => {
  const registry = fakeRegistry();
  const router = new CommandRouter();
  registerPushCommands(router, registry);
  const client = fakeClient("d1");

  await dispatch(router, client, { token: "x" });

  assert.deepEqual(registry.calls, [
    { deviceId: "d1", token: "x", platform: "apns", env: undefined },
  ]);
  assert.ok(client.sent.some((f) => f.t === "ack"));
});

test("push.register with no token → err bad_request", async () => {
  const registry = fakeRegistry();
  const router = new CommandRouter();
  registerPushCommands(router, registry);
  const client = fakeClient("d1");

  await dispatch(router, client, { platform: "apns" });

  assert.equal(registry.calls.length, 0);
  assert.ok(client.sent.some((f) => f.t === "err" && f.code === "bad_request"));
});

test("push.register from an unauthed/deviceless client → err", async () => {
  const registry = fakeRegistry();
  const router = new CommandRouter();
  registerPushCommands(router, registry);
  const client = fakeClient(); // no deviceId, unauthed

  await dispatch(router, client, { token: "tok-abc", platform: "apns" });

  assert.equal(registry.calls.length, 0);
  assert.ok(client.sent.some((f) => f.t === "err"));
});
