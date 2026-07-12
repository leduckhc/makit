/**
 * Auto-mirror integration test: two live WS clients against a real
 * {@link startWsServer}. Proves that a session event produced via one client's
 * command fans out to EVERY authenticated client — even one that never sent a
 * `sub` — so all devices stay mirrored in real time.
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

function agentEcho(text: string) {
  return (m: Record<string, unknown>) => {
    if (m.t !== "event" || m.kind !== "session.event") return false;
    const e = m.event as { kind?: string; payload?: { text?: string } } | undefined;
    return e?.kind === "agent.message" && e.payload?.text === `echo: ${text}`;
  };
}

test("a session event fans out to every authed client, even one that never subscribed", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-mirror-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-mirror-proj-"));
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
    port: 0, // ephemeral
    manager,
    cert,
    registry,
    trustLocalhost: true, // loopback clients are auto-authed (no pairing needed)
  });

  // Default session must be created AFTER startWsServer so its "sessionCreated"
  // listener wires the event fan-out.
  await manager.ensureDefaultSessions();

  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });
  const port = (srv.https.address() as AddressInfo).port;

  const a = connect(port);
  const b = connect(port);
  try {
    await Promise.all([waitOpen(a.ws), waitOpen(b.ws)]);

    // Both trusted-local clients receive the sessions snapshot on connect.
    const snap = await waitFor(a, isSessionsSnapshot);
    await waitFor(b, isSessionsSnapshot);
    const sessions = snap.sessions as Array<{ id: string }>;
    assert.equal(sessions.length, 1, "one default session exists");
    const sessionId = sessions[0]!.id;

    // Client A sends a message. Client B never sends `sub`.
    a.ws.send(
      JSON.stringify({ v: 1, t: "cmd", id: "m1", kind: "send.message", sessionId, text: "mirror me" }),
    );

    // The agent echo must reach BOTH clients — B without ever subscribing.
    await waitFor(b, agentEcho("mirror me"));
    await waitFor(a, agentEcho("mirror me"));

    // Sanity: B truly never subscribed.
    assert.equal(
      b.msgs.some((m) => m.t === "ack" && m.id === "sub"),
      false,
      "client B never sent a sub",
    );
  } finally {
    a.ws.close();
    b.ws.close();
    srv.wss.close();
    srv.https.close();
    srv.localHttps?.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
