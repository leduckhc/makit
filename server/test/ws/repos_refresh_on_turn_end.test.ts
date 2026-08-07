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

/** The stub's echo of [text] — a marker that this turn actually ran. */
const agentEcho = (text: string) => (m: Record<string, unknown>) => {
  if (m.t !== "event" || m.kind !== "session.event") return false;
  const e = m.event as { kind?: string; payload?: { text?: string } } | undefined;
  return e?.kind === "agent.message" && e.payload?.text === `echo: ${text}`;
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
    // Wait for the connect-time burst to *settle* rather than for a fixed count:
    // a broadcast has two phases (git-only, then PR-enriched). Drawing the line
    // while one was still in flight would let it satisfy the assertion on its own,
    // with no turn-end refresh involved.
    await waitFor(() => c.msgs.filter(isReposSnapshot).length > 0);
    let stable = -1;
    for (let quiet = 0; quiet < 4; quiet++) {
      await new Promise((r) => setTimeout(r, 150));
      const n = c.msgs.filter(isReposSnapshot).length;
      if (n !== stable) {
        stable = n;
        quiet = -1;
      }
    }
    const before = stable;
    // Everything at or after this index belongs to the turn, which is what makes
    // the assertion about *this* turn rather than about connecting.
    const cursor = c.msgs.length;

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
    // The turn ran: the stub's echo is a per-turn marker. Deliberately *not* a
    // `running` sessions.snapshot — the sessions broadcast is coalesced over
    // 150ms, so a stub turn goes running→idle inside one window and every frame
    // that reaches the client already reads `idle`. The falling edge the server
    // watches is `session.status`, which is not the same thing as a frame.
    await waitFor(() => c.msgs.some(agentEcho("commit everything")));

    // The trigger is coalesced over a second, so allow for the trailing edge. The
    // frames must land at or after the cursor: a connect-time snapshot cannot
    // satisfy this.
    await waitFor(() => c.msgs.slice(cursor).some(isReposSnapshot), 5000);
    assert.ok(
      c.msgs.slice(cursor).some(isReposSnapshot),
      "a finished turn must push a fresh repos.snapshot",
    );
    assert.ok(
      c.msgs.filter(isReposSnapshot).length > before,
      "…and it must be additional to the connect-time ones",
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
