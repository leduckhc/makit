/**
 * SPEC-38: the composer's next-step bar asserts a *count* — `13 files
 * uncommitted`, and a `Commit & push` button to clear it — and reads it from the
 * repos snapshot. The snapshot was recomputed on connect, spawn, kill,
 * pull-to-refresh and worktree add/remove, and on none of those does an agent
 * committing mid-turn appear: the bar went on offering to commit files it had
 * already committed and pushed, until the client reconnected.
 *
 * So a finished turn re-derives it. This drives a real {@link startWsServer} with
 * the stub adapter and asserts a fresh `repos.snapshot` lands after the turn goes
 * idle, having sent nothing else that would trigger one.
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
  pred: () => boolean,
  timeoutMs = 5000,
): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("timeout waiting for condition");
}

const isReposSnapshot = (m: Record<string, unknown>) =>
  m.t === "event" && m.kind === "repos.snapshot";

const isIdle = (sessionId: string) => (m: Record<string, unknown>) => {
  if (m.t !== "event" || m.kind !== "sessions.snapshot") return false;
  const s = (m.sessions as Array<{ id: string; status: string }>).find((x) => x.id === sessionId);
  return s?.status === "idle";
};

test("a finished turn re-derives the repos snapshot", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-turnend-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-turnend-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  const manager = new SessionManager({
    projects: [project],
    adapterFactory: () => new StubAdapter(),
  });
  const cert = await loadOrCreateCert();
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry: new DeviceRegistry(),
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
    // Connecting already pushes one (git-only, then PR-enriched), so wait for the
    // session list and then count from a known baseline.
    await waitFor(() => c.msgs.some((m) => m.t === "event" && m.kind === "sessions.snapshot"));
    const sessions = (
      c.msgs.find((m) => m.kind === "sessions.snapshot")!.sessions as Array<{ id: string }>
    );
    const sessionId = sessions[0]!.id;
    await waitFor(() => c.msgs.filter(isReposSnapshot).length > 0);
    // Let the connect-time snapshots settle, then draw the line.
    await new Promise((r) => setTimeout(r, 400));
    const before = c.msgs.filter(isReposSnapshot).length;

    // One turn. The stub echoes and returns to idle; nothing here adds or removes
    // a project, a session or a worktree, so the only remaining trigger is the
    // turn ending.
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "m1",
        kind: "send.message",
        sessionId,
        text: "commit everything",
      }),
    );
    await waitFor(() => c.msgs.some(isIdle(sessionId)));

    // The trigger is coalesced over a second, so allow for the trailing edge.
    await waitFor(() => c.msgs.filter(isReposSnapshot).length > before, 5000);
    assert.ok(
      c.msgs.filter(isReposSnapshot).length > before,
      "a finished turn must push a fresh repos.snapshot",
    );
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
