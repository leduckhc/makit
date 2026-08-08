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
import { mkdtempSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createServerBackend, type ServerBackendDeps } from "./backend.js";
import type { LogTailStop } from "./control-server.js";

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
      grantCli: () => ({
        device: { id: "cli-1", label: "cli@host", bearer: "cli-bearer" },
        created: true,
      }),
    },
    manager: {
      listSessions: () => [
        { id: "s1", projectId: "p", agent: "pi", title: "t", status: "running", policy: "ask", lastActivityAt: 0, lastPreview: "" },
        { id: "s2", projectId: "p", agent: "pi", title: "t", status: "idle", policy: "ask", lastActivityAt: 0, lastPreview: "" },
      ],
    },
    fingerprint: "fp",
    host: "0.0.0.0",
    port: 7788,
    advertiseHost: "10.0.0.5",
    version: "9.9.9",
    startedAt: 500,
    now: () => clock,
    connectedDeviceIds: () => new Set(["d1"]),
    buildUrl: (token: string) => `makit://pair?t=${token}`,
    requestStop: () => {},
    logPath: "/nonexistent/makit.log",
    ...over,
  } as ServerBackendDeps;
}

test("status maps process + server state", async () => {
  const b = createServerBackend(deps());
  const s = await b.status();
  assert.equal(s.host, "0.0.0.0");
  assert.equal(s.port, 7788);
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
  assert.equal(minted.url, "makit://pair?t=TOKEN");
  assert.equal(minted.fingerprint, "fp");
  assert.equal(minted.expiresAt, 61_000);

  const current = await b.pairCurrent();
  assert.deepEqual(current, { url: "makit://pair?t=TOKEN", token: "TOKEN", expiresAt: 61_000 });

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

/** Wait until `predicate` is true or the deadline elapses (watcher is async). */
async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("waitFor: timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
}

test("logs.tail --follow streams appended lines and the stop fn closes the watcher", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-logtail-"));
  const logPath = join(dir, "makit.log");
  writeFileSync(logPath, "backlog\n");
  const b = createServerBackend(deps({ logPath }));

  const lines: string[] = [];
  const stop = (await b.logsTail({ follow: true }, (line) => lines.push(line))) as LogTailStop;
  try {
    assert.equal(typeof stop, "function");
    assert.deepEqual(lines, ["backlog"]); // backlog emitted synchronously
    // Give the fs.watch a tick to arm before mutating (FSEvents misses writes
    // that land before the watcher is fully registered).
    await new Promise((r) => setTimeout(r, 50));
    appendFileSync(logPath, "live-1\n");
    await waitFor(() => lines.includes("live-1"));
    assert.deepEqual(lines, ["backlog", "live-1"]);

    // Stopping closes the fs.watch handle: subsequent appends must not emit.
    stop();
    appendFileSync(logPath, "after-stop\n");
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(lines.includes("after-stop"), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
