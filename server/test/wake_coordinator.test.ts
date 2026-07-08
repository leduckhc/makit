import { test } from "node:test";
import assert from "node:assert/strict";

import {
  devicesToWake,
  WakeCoordinator,
  type WakeRegistry,
  type PairedDeviceView,
} from "../src/push/wake_coordinator.js";
import {
  NoopPushSender,
  type PushSender,
  type PushTarget,
  type PushResult,
} from "../src/push/sender.js";
import { apnsDisposition } from "../src/push/apns.js";
import { buildWakePayload, type ApnsPayload } from "../src/push/payload.js";

function device(id: string, token?: string, platform = "apns"): PairedDeviceView {
  return { id, pushToken: token, pushPlatform: token ? platform : undefined };
}

/** In-memory registry recording clearPushToken calls. */
function fakeRegistry(devices: PairedDeviceView[]): WakeRegistry & { cleared: string[] } {
  const cleared: string[] = [];
  return {
    cleared,
    list: () => devices,
    clearPushToken: (id: string) => {
      cleared.push(id);
    },
  };
}

/** Fake sender recording each wake call; disposition per-device configurable. */
function fakeSender(
  enabled: boolean,
  results: Record<string, PushResult> = {},
): PushSender & { calls: { target: PushTarget; payload: ApnsPayload }[] } {
  const calls: { target: PushTarget; payload: ApnsPayload }[] = [];
  return {
    enabled,
    calls,
    wake: async (target, payload) => {
      calls.push({ target, payload });
      return results[target.deviceId] ?? "ok";
    },
  };
}

const flush = () => new Promise((r) => setImmediate(r));

// -------- devicesToWake (pure decision) ------------------------------------

test("wakes only paired devices with a token and no live socket", () => {
  const targets = devicesToWake({
    pairedDevices: [device("d1", "tok1"), device("d2", "tok2"), device("d3")],
    connectedDeviceIds: new Set(["d1"]),
  });
  assert.deepEqual(targets, [{ deviceId: "d2", token: "tok2", platform: "apns", env: undefined }]);
});

test("returns empty when every paired device is connected", () => {
  const targets = devicesToWake({
    pairedDevices: [device("d1", "tok1"), device("d2", "tok2")],
    connectedDeviceIds: new Set(["d1", "d2"]),
  });
  assert.deepEqual(targets, []);
});

// -------- WakeCoordinator dispatch gate (keep-pending contract) ------------

test("wake returns false with NoopPushSender even when a stale token is stored", () => {
  const sender = new NoopPushSender();
  const coord = new WakeCoordinator({
    registry: fakeRegistry([device("d2", "stale")]),
    connectedDeviceIds: () => new Set<string>(),
    sender,
    buildWakePayload,
  });
  const kept = coord.wake({ t: "srv.request", id: "x" }, { pendingCount: 1 });
  assert.equal(kept, false);
});

test("wake returns true when an enabled sender has ≥1 target", async () => {
  const sender = fakeSender(true);
  const coord = new WakeCoordinator({
    registry: fakeRegistry([device("d2", "tok2")]),
    connectedDeviceIds: () => new Set<string>(),
    sender,
    buildWakePayload,
  });
  const kept = coord.wake({ t: "srv.request", id: "x" }, { pendingCount: 2 });
  assert.equal(kept, true);
  await flush();
  assert.equal(sender.calls.length, 1);
  assert.deepEqual(sender.calls[0]!.payload, buildWakePayload({ pendingCount: 2 }));
});

test("wake returns false when enabled but no device needs waking", () => {
  const sender = fakeSender(true);
  const coord = new WakeCoordinator({
    registry: fakeRegistry([device("d1", "tok1")]),
    connectedDeviceIds: () => new Set(["d1"]),
    sender,
    buildWakePayload,
  });
  assert.equal(coord.wake({ t: "srv.request", id: "x" }, { pendingCount: 1 }), false);
  assert.equal(sender.calls.length, 0);
});

test("wake clears a dead token on 410/BadDeviceToken", async () => {
  const sender = fakeSender(true, { d2: "dead" });
  const registry = fakeRegistry([device("d2", "tok2")]);
  const coord = new WakeCoordinator({
    registry,
    connectedDeviceIds: () => new Set<string>(),
    sender,
    buildWakePayload,
  });
  coord.wake({ t: "srv.request", id: "x" }, { pendingCount: 1 });
  await flush();
  assert.deepEqual(registry.cleared, ["d2"]);
});

// -------- A7: APNs stale-token disposition (pure classifier) ---------------

test("410 Unregistered → dead", () => {
  assert.equal(apnsDisposition(410, "Unregistered"), "dead");
});

test("400 BadDeviceToken → dead", () => {
  assert.equal(apnsDisposition(400, "BadDeviceToken"), "dead");
});

test("200 → ok", () => {
  assert.equal(apnsDisposition(200), "ok");
});

test("429/500/503 → error (transient, token kept)", () => {
  assert.equal(apnsDisposition(429, "TooManyRequests"), "error");
  assert.equal(apnsDisposition(500, "InternalServerError"), "error");
  assert.equal(apnsDisposition(503, "ServiceUnavailable"), "error");
});
