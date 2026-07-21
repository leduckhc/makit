/**
 * Control-client tests (SPEC-01, phase 3).
 *
 * The client is the reusable half SPEC-02's CLI consumes. We test it against a
 * real control server backed by a fake backend over a temp-dir socket.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { connectControlClient } from "./control-client.js";
import { createControlServer, type ControlBackend } from "./control-server.js";

function fakeBackend(over: Partial<ControlBackend> = {}): ControlBackend {
  return {
    status: () => ({
      pid: 7,
      uptimeMs: 1,
      host: "0.0.0.0",
      port: 7788,
      fingerprint: "fp",
      advertiseHost: "1.2.3.4",
      pairedDevices: 2,
      runningSessions: 1,
      version: "0.1.0",
    }),
    pairMint: () => ({ url: "u", token: "t", expiresAt: 1, fingerprint: "fp" }),
    pairCurrent: () => null,
    devicesList: () => ({ devices: [] }),
    devicesRevoke: () => ({ removed: false }),
    sessionsList: () => ({ sessions: [] }),
    serverStop: () => ({ stopping: true }),
    logsTail: () => undefined,
    ...over,
  };
}

async function withServer(
  backend: ControlBackend,
  fn: (path: string) => Promise<void>,
) {
  const dir = mkdtempSync(join(tmpdir(), "makit-cli-"));
  const path = join(dir, "control.sock");
  const handle = await createControlServer({ socketPath: path, backend });
  try {
    await fn(path);
  } finally {
    await handle.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

test("client request resolves an ok response with typed data", async () => {
  await withServer(fakeBackend(), async (path) => {
    const client = await connectControlClient(path);
    const res = await client.request("status");
    assert.equal(res.ok, true);
    assert.equal((res as { data: { pairedDevices: number } }).data.pairedDevices, 2);
    client.close();
  });
});

test("client forwards args and correlates concurrent requests by id", async () => {
  const backend = fakeBackend({
    devicesRevoke: (args) => ({ removed: args.id === "yes" }),
  });
  await withServer(backend, async (path) => {
    const client = await connectControlClient(path);
    const [a, b] = await Promise.all([
      client.request("devices.revoke", { id: "yes" }),
      client.request("devices.revoke", { id: "no" }),
    ]);
    assert.equal((a as { data: { removed: boolean } }).data.removed, true);
    assert.equal((b as { data: { removed: boolean } }).data.removed, false);
    client.close();
  });
});

test("client surfaces backend errors as ok:false responses", async () => {
  const backend = fakeBackend({
    status: () => {
      throw new Error("nope");
    },
  });
  await withServer(backend, async (path) => {
    const client = await connectControlClient(path);
    const res = await client.request("status");
    assert.equal(res.ok, false);
    assert.equal((res as { error: string }).error, "nope");
    client.close();
  });
});

test("connect rejects when no daemon is listening", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-cli-"));
  const path = join(dir, "absent.sock");
  await assert.rejects(() => connectControlClient(path));
  rmSync(dir, { recursive: true, force: true });
});

test("pending requests reject if the socket closes first", async () => {
  await withServer(fakeBackend(), async (path) => {
    const client = await connectControlClient(path);
    const pending = client.request("status");
    client.close();
    await assert.rejects(() => pending);
  });
});
