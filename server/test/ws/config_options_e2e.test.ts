/**
 * SPEC-26 configOptions wire e2e: a live WS client against a real
 * {@link startWsServer} + {@link StubAdapter}. Proves the unified config
 * surface end-to-end over the wire:
 *   1. a spawned session emits `session.meta` carrying `configOptions`;
 *   2. a `session.action` `configOption {id,value}` round-trips — the adapter
 *      re-emits the COMPLETE updated list to the client.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";
import { StubAdapter } from "../../src/adapters/stub.js";
import type { SessionConfigOption } from "../../src/protocol.js";

interface Client {
  ws: WebSocket;
  msgs: Record<string, unknown>[];
}

function connect(port: number): Client {
  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const msgs: Record<string, unknown>[] = [];
  ws.on("message", (b: Buffer) => {
    try {
      msgs.push(JSON.parse(b.toString()));
    } catch {
      /* ignore non-JSON */
    }
  });
  return { ws, msgs };
}

function waitOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
}

async function waitFor(
  client: Client,
  pred: (m: Record<string, unknown>) => boolean,
  timeoutMs = 2000,
): Promise<Record<string, unknown>> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = client.msgs.find(pred);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("timeout waiting for a matching frame");
}

const isSessionsSnapshot = (m: Record<string, unknown>) =>
  m.t === "event" && m.kind === "sessions.snapshot";

/** session.meta frames for [sessionId] whose payload carries configOptions. */
function metaWithOptions(sessionId: string) {
  return (m: Record<string, unknown>) => {
    if (m.t !== "event" || m.kind !== "session.event") return false;
    const e = m.event as
      | { kind?: string; sessionId?: string; payload?: { configOptions?: unknown } }
      | undefined;
    return (
      e?.kind === "session.meta" &&
      e.sessionId === sessionId &&
      Array.isArray(e.payload?.configOptions)
    );
  };
}

function optionsOf(m: Record<string, unknown>): SessionConfigOption[] {
  const e = m.event as { payload: { configOptions: SessionConfigOption[] } };
  return e.payload.configOptions;
}

test("configOptions flow over the wire and a configOption action round-trips", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-cfgopt-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-cfgopt-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  const manager = new SessionManager({
    projects: [project],
    adapterFactory: () => new StubAdapter(),
  });

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry,
    trustLocalhost: true,
  });
  await manager.ensureDefaultSessions();

  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });
  const port = (srv.https.address() as AddressInfo).port;

  const c = connect(port);
  try {
    await waitOpen(c.ws);
    const snap = await waitFor(c, isSessionsSnapshot);
    const sessions = snap.sessions as Array<{ id: string }>;
    assert.equal(sessions.length, 1, "one default stub session exists");
    const sessionId = sessions[0]!.id;

    // Subscribe to replay the stub's start-time event log (incl. session.meta).
    c.ws.send(JSON.stringify({ v: 1, t: "sub", id: "s1", sessionId }));

    // 1. The stub's catalog reaches the client on session.meta.
    const meta = await waitFor(c, metaWithOptions(sessionId));
    const opts = optionsOf(meta);
    assert.equal(opts.length, 4);
    assert.equal(opts[0]!.id, "model");
    assert.equal(opts[0]!.currentValue, "stub-normal");
    assert.equal(opts[1]!.id, "thought_level");
    assert.equal(opts[1]!.currentValue, "low");
    assert.equal(opts[2]!.id, "context");
    assert.equal(opts[3]!.id, "fast");

    // 2. Set thought_level=high via the unified action; the COMPLETE updated
    //    list comes back over the wire.
    c.ws.send(
      JSON.stringify({
        v: 1, t: "cmd", id: "c2", kind: "session.action", sessionId,
        action: "configOption", args: { id: "thought_level", value: "high" },
      }),
    );
    const updated = await waitFor(c, (m) => {
      if (!metaWithOptions(sessionId)(m)) return false;
      const o = optionsOf(m);
      return o.find((x) => x.id === "thought_level")?.currentValue === "high";
    });
    const after = optionsOf(updated);
    assert.equal(after.length, 4, "complete list re-emitted");
    assert.equal(after.find((o) => o.id === "model")?.currentValue, "stub-normal");
  } finally {
    c.ws.close();
    srv.wss.close();
    srv.https.close();
    srv.localHttps?.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
