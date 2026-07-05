/**
 * Server-backed control backend tests (SPEC-01, phase 6).
 *
 * `createServerBackend` adapts the running server's existing internals
 * (registry, manager, cert, connected clients) to the ControlBackend the
 * control server dispatches to. We drive it with lightweight fakes to lock down
 * the mapping, the pair-token lifecycle, and the connected-device flag.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { createServerBackend, type ServerBackendDeps } from "./backend.js";

interface FakeDevice {
  id: string;
  label: string;
  pairedAt: number;
  lastSeenAt: number;
}

function deps(over: Partial<ServerBackendDeps> = {}): ServerBackendDeps {
  const devices: FakeDevice[] = [
    { id: "d1", label: "phone", pairedAt: 1, lastSeenAt: 2 },
    { id: "d2", label: "ipad", pairedAt: 3, lastSeenAt: 4 },
  ];
  let clock = 1000;
  return {
    registry: {
      list: () => devices.map((d) => ({ ...d })),
      mintPairToken: (_ttl?: number) => "TOKEN",
      revoke: (id: string) => {
        const i = devices.findIndex((d) => d.id === id);
        if (i < 0) return false;
        devices.splice(i, 1);
        return true;
      },
    },
    manager: {
      listSessions: () => [
        { id: "s1", projectId: "p", agent: "pi", title: "t", status: "running", policy: "ask", lastActivityAt: 0, lastPreview: "" },
        { id: "s2", projectId: "p", agent: "pi", title: "t", status: "idle", policy: "ask", lastActivityAt: 0, lastPreview: "" },
      ],
    },
    fingerprint: "fp",
    host: "0.0.0.0",
    port: 8787,
    advertiseHost: "10.0.0.5",
    version: "9.9.9",
    startedAt: 500,
    now: () => clock,
    connectedDeviceIds: () => new Set(["d1"]),
    buildUrl: (token: string) => `pino://pair?t=${token}`,
    requestStop: () => {},
    logPath: "/nonexistent/pino.log",
    ...over,
  } as ServerBackendDeps;
}

test("status maps process + server state", async () => {
  const b = createServerBackend(deps());
  const s = await b.status();
  assert.equal(s.host, "0.0.0.0");
  assert.equal(s.port, 8787);
  assert.equal(s.fingerprint, "fp");
  assert.equal(s.advertiseHost, "10.0.0.5");
  assert.equal(s.pairedDevices, 2);
  assert.equal(s.runningSessions, 1); // only s1 is running
  assert.equal(s.version, "9.9.9");
  assert.equal(s.uptimeMs, 500); // now 1000 - startedAt 500
  assert.equal(s.pid, process.pid);
});

test("pair.mint mints a token, builds a URL, and pair.current returns it until expiry", async () => {
  let clock = 1000;
  const b = createServerBackend(deps({ now: () => clock }));
  const minted = await b.pairMint({ ttlMs: 60_000 });
  assert.equal(minted.token, "TOKEN");
  assert.equal(minted.url, "pino://pair?t=TOKEN");
  assert.equal(minted.fingerprint, "fp");
  assert.equal(minted.expiresAt, 61_000);

  const current = await b.pairCurrent();
  assert.deepEqual(current, { url: "pino://pair?t=TOKEN", token: "TOKEN", expiresAt: 61_000 });

  clock = 61_001; // past expiry
  assert.equal(await b.pairCurrent(), null);
});

test("pair.current is null before any mint", async () => {
  const b = createServerBackend(deps());
  assert.equal(await b.pairCurrent(), null);
});

test("devices.list flags connected devices", async () => {
  const b = createServerBackend(deps());
  const { devices } = await b.devicesList();
  assert.equal(devices.length, 2);
  assert.equal(devices.find((d) => d.id === "d1")!.connected, true);
  assert.equal(devices.find((d) => d.id === "d2")!.connected, false);
});

test("devices.revoke delegates to the registry", async () => {
  const b = createServerBackend(deps());
  assert.deepEqual(await b.devicesRevoke({ id: "d2" }), { removed: true });
  assert.deepEqual(await b.devicesRevoke({ id: "nope" }), { removed: false });
});

test("sessions.list returns the manager DTOs", async () => {
  const b = createServerBackend(deps());
  const { sessions } = await b.sessionsList();
  assert.equal(sessions.length, 2);
  assert.equal(sessions[0]!.id, "s1");
});

test("server.stop requests a graceful shutdown", async () => {
  let stopped = false;
  const b = createServerBackend(deps({ requestStop: () => { stopped = true; } }));
  assert.deepEqual(await b.serverStop(), { stopping: true });
  assert.equal(stopped, true);
});
