/**
 * Automatic re-attach after a server restart, over the wire.
 *
 * A session the user had open when the desktop server restarted comes back
 * COLD: the transcript is in the durable store, but the agent process is gone
 * and the session holds a {@link DetachedAdapter}. The app re-issues its `sub`
 * on reconnect, so `sub` is the trigger that must bring the agent back — the
 * client cannot decide this itself, because at reconnect time it still holds
 * the pre-restart status (`idle`/`running`), not `exited`.
 *
 * Proves, against a real {@link startWsServer} + {@link StubAdapter}:
 *   1. `sub` alone re-attaches a cold resumable session (no send required);
 *   2. a `send.message` racing that `sub` still lands on the live agent —
 *      one agent, one reply, and never the cold-session `session.error`.
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
import { SqliteEventStore } from "../../src/storage/sqlite_event_store.js";
import type { SessionDTO } from "../../src/protocol.js";

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

function sessionsOf(m: Record<string, unknown>): SessionDTO[] {
  return m.sessions as SessionDTO[];
}

/** A session.event frame of [kind] for [sessionId]. */
function eventOf(sessionId: string, kind: string) {
  return (m: Record<string, unknown>) => {
    if (m.t !== "event" || m.kind !== "session.event") return false;
    const e = m.event as { kind?: string; sessionId?: string } | undefined;
    return e?.kind === kind && e.sessionId === sessionId;
  };
}

/**
 * The `seq` of every session.event frame the client received, in ARRIVAL order.
 * Replayed history and live events share one durable seq space, so this being
 * sorted is exactly the claim "history reached the client before the resumed
 * agent's live events".
 */
function arrivalSeqs(c: Client, sessionId: string): number[] {
  return c.msgs
    .filter((m) => m.t === "event" && m.kind === "session.event")
    .map((m) => m.event as { sessionId: string; seq: number })
    .filter((e) => e.sessionId === sessionId)
    .map((e) => e.seq);
}

function assertInOrder(seqs: number[], why: string): void {
  assert.ok(seqs.length > 1, `${why}: expected more than one event, got ${seqs.length}`);
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), why);
}

/**
 * A live session persisted into [store], then a server restart: returns a
 * second manager that has rehydrated it COLD, plus a listening WS server.
 */
async function restartWith(store: SqliteEventStore, project: string) {
  const live = new SessionManager({
    projects: [project],
    store,
    adapterFactory: () => new StubAdapter(),
  });
  await live.ensureDefaultSessions();
  const sessionId = live.allSessions()[0]!.id;

  // --- the restart: a fresh manager over the same store, cold sessions only.
  const manager = new SessionManager({
    projects: [project],
    store,
    adapterFactory: () => new StubAdapter(),
  });
  assert.equal(manager.getSession(sessionId)!.status, "exited", "rehydrated cold");
  assert.equal(manager.getSession(sessionId)!.toDTO().resumable, true, "and resumable");

  const cert = await loadOrCreateCert();
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry: new DeviceRegistry(),
    trustLocalhost: true,
  });
  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });
  return { manager, srv, sessionId, port: (srv.https.address() as AddressInfo).port };
}

function withEnv(run: (project: string, store: SqliteEventStore) => Promise<void>) {
  const home = mkdtempSync(join(tmpdir(), "makit-reattach-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-reattach-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  const store = new SqliteEventStore();
  return (async () => {
    try {
      await run(project, store);
    } finally {
      store.close();
      if (prevHome === undefined) delete process.env.MAKIT_HOME;
      else process.env.MAKIT_HOME = prevHome;
      rmSync(home, { recursive: true, force: true });
      rmSync(project, { recursive: true, force: true });
    }
  })();
}

test("`sub` re-attaches a cold session after a server restart", async () => {
  await withEnv(async (project, store) => {
    const { manager, srv, sessionId, port } = await restartWith(store, project);
    const c = connect(port);
    try {
      await waitOpen(c.ws);
      const cold = await waitFor(c, isSessionsSnapshot);
      assert.equal(sessionsOf(cold)[0]!.status, "exited", "client first sees it cold");

      // The app re-issues exactly this on reconnect — no send, no attach cmd.
      c.ws.send(JSON.stringify({ v: 1, t: "sub", id: "s1", sessionId }));

      const warm = await waitFor(
        c,
        (m) => isSessionsSnapshot(m) && sessionsOf(m)[0]?.status !== "exited",
      );
      assert.notEqual(sessionsOf(warm)[0]!.status, "exited", "live again for the client");
      assert.equal(manager.getSession(sessionId)!.resumable, true);

      // Ordering: the re-attach is fired AFTER the replay, so the transcript
      // reaches the client before the resumed agent's first live events.
      assertInOrder(arrivalSeqs(c, sessionId), "replayed history precedes live events");
    } finally {
      c.ws.close();
      srv.wss.close();
      srv.https.close();
      srv.localHttps?.close();
    }
  });
});

test("a `send.message` racing the `sub` lands on one live agent, not a cold-session error", async () => {
  await withEnv(async (project, store) => {
    const { srv, sessionId, port } = await restartWith(store, project);
    const c = connect(port);
    try {
      await waitOpen(c.ws);
      await waitFor(c, isSessionsSnapshot);

      // Back-to-back, as the app does when a queued message follows the
      // reconnect resubscribe: both need the agent, neither may spawn a second.
      c.ws.send(JSON.stringify({ v: 1, t: "sub", id: "s1", sessionId }));
      c.ws.send(
        JSON.stringify({ v: 1, t: "cmd", id: "c1", kind: "send.message", sessionId, text: "hello" }),
      );

      const reply = await waitFor(c, eventOf(sessionId, "agent.message"));
      const payload = (reply.event as { payload: { text?: string } }).payload;
      assert.match(String(payload.text), /echo: hello/);
      assert.equal(
        c.msgs.some(eventOf(sessionId, "session.error")),
        false,
        "never the cold-session re-attach error",
      );
      // `handleSub` stays synchronous, so the `cmd` right behind it cannot
      // overtake the replay: every event still arrives in seq order.
      assertInOrder(arrivalSeqs(c, sessionId), "replay precedes the new turn's events");
    } finally {
      c.ws.close();
      srv.wss.close();
      srv.https.close();
      srv.localHttps?.close();
    }
  });
});
