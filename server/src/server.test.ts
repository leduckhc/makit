import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { startWsServer } from "./server.js";
import { SessionManager } from "./manager.js";
import { loadOrCreateCert } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { Envelope } from "./protocol.js";
import { EventEmitter } from "node:events";
import type { AgentAdapter } from "./adapters/adapter.js";

/** Minimal in-process adapter whose events can be driven from the test. */
function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as unknown as { agent: string }).agent = "stub";
  (e as unknown as { start: () => Promise<void> }).start = async () => {};
  (e as unknown as { send: () => Promise<void> }).send = async () => {};
  (e as unknown as { cancel: () => Promise<void> }).cancel = async () => {};
  (e as unknown as { kill: () => Promise<void> }).kill = async () => {};
  return e;
}

/**
 * SPEC-17 P2: a stream of per-token deltas must NOT re-broadcast the full
 * sessions snapshot (the O(clients × sessions) hot-path cliff), while a DTO-
 * visible change (status) still does. Drives a real WS server end-to-end and
 * counts `sessions.snapshot` frames on the wire.
 */
test("streaming deltas do not re-broadcast the sessions snapshot; a status change does (P2)", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-srv-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const manager = new SessionManager({ projects: [project], adapterFactory: () => fakeAdapter() });
  const projectId = manager.listProjects()[0].id;
  const session = await manager.spawnPiSession(projectId);

  // Wire sessions created before startWsServer via allSessions().
  const server = startWsServer({ host: "127.0.0.1", port: 0, manager, cert, registry, trustLocalhost: true });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;

  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  let snapshotCount = 0;
  const pongs: string[] = [];
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope;
    if (env.t === "event" && env.kind === "sessions.snapshot") snapshotCount++;
    if (env.t === "pong") pongs.push(env.id);
  });

  const ping = (id: string) =>
    new Promise<void>((resolve, reject) => {
      const before = pongs.length;
      const timer = setInterval(() => {
        if (pongs.length > before && pongs.includes(id)) {
          clearInterval(timer);
          clearTimeout(timeout);
          resolve();
        }
      }, 5);
      // A missing pong must not leave the promise + interval alive forever
      // (hanging the whole test run). Bound the barrier and fail loudly.
      const timeout = setTimeout(() => {
        clearInterval(timer);
        reject(new Error(`ping ${id} timed out waiting for pong`));
      }, 5000);
      ws.send(JSON.stringify({ v: PROTOCOL_VERSION, t: "ping", id, ts: Date.now() }));
    });

  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    // Barrier: the trusted-local client receives the initial snapshots on
    // connect. Flush them before counting.
    await ping("p0");
    const baseline = snapshotCount;
    assert.ok(baseline >= 1, "client receives an initial sessions.snapshot");

    // A stream of N per-token deltas.
    for (let i = 0; i < 25; i++) {
      session.adapter.emit("event", { ts: i, kind: "agent.message.delta", payload: { text: "x" } });
    }
    await ping("p1");
    assert.equal(snapshotCount, baseline, "per-token deltas must NOT re-broadcast the sessions snapshot");

    // A status transition IS a DTO-visible change → exactly one broadcast.
    session.adapter.emit("status", "running");
    await ping("p2");
    assert.equal(snapshotCount, baseline + 1, "a status change broadcasts exactly one sessions.snapshot");
  } finally {
    ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
