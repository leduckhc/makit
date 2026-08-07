/**
 * REAL-agent proof for server-restart re-attach. Not a `*.test.ts`, so it stays
 * out of `pnpm test` — it spawns the genuine `pi` binary (same convention as
 * e2e-server.ts). Run:
 *
 *   pnpm exec tsx test/e2e-reattach-real.ts
 *
 * Everything in the automated suite uses StubAdapter. This closes the one gap
 * that matters: a REAL pi session, over the real ACP adapter, across a real
 * server restart backed by a real on-disk SQLite event log.
 *
 * Proves four things:
 *   1. after the restart the session rehydrates COLD (status exited, resumable);
 *   2. a plain `sub` brings it back live — no client-side attach command;
 *   3. pi honours the resume: its native session id is UNCHANGED, i.e. the
 *      adapter resumed rather than silently starting a fresh agent;
 *   4. the resumed session takes a NEW turn (new reply, no new error), scoped by
 *      `seq` so a replayed pre-restart event cannot be mistaken for proof.
 *
 * It ASKS for the local fake-model server, but that swap does not currently take
 * effect for pi (pi-acp forwards no `-e`, so the fake provider never loads), so
 * prompting here bills the configured provider. The billing guard refuses to run
 * unless MAKIT_E2E_ALLOW_REAL_MODEL=1. Context retention is therefore reported,
 * not asserted.
 */

import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { SessionManager } from "../src/manager.js";
import { startWsServer } from "../src/server.js";
import { startBridge } from "../src/bridge.js";
import { loadOrCreateCert } from "../src/pairing/cert.js";
import { DeviceRegistry } from "../src/pairing/registry.js";
import { SqliteEventStore } from "../src/storage/sqlite_event_store.js";
import { startFakeModelServer } from "./fake-model/server.js";
import { guardAgainstRealBilling, currentModelFromEvents } from "./fake-model/billing-guard.js";

const FAKE_PROVIDER_EXT = fileURLToPath(
  new URL("./fake-model/provider-extension.ts", import.meta.url),
);
const FAKE_MODEL = "makit-fake/fake-1";
/** Distinctive token planted before the restart and looked for after it. */
const NONCE = "zarquon-7741";

// ---------------------------------------------------------------------------
// tiny WSS client
// ---------------------------------------------------------------------------

interface Client {
  ws: WebSocket;
  msgs: Record<string, unknown>[];
}

async function connect(port: number): Promise<Client> {
  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const msgs: Record<string, unknown>[] = [];
  ws.on("message", (b: Buffer) => {
    try {
      msgs.push(JSON.parse(b.toString()));
    } catch {
      /* ignore */
    }
  });
  await new Promise<void>((res, rej) => {
    ws.once("open", () => res());
    ws.once("error", rej);
  });
  return { ws, msgs };
}

async function waitFor(
  c: Client,
  pred: (m: Record<string, unknown>) => boolean,
  what: string,
  timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const hit = c.msgs.find(pred);
    if (hit) return hit;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`timeout waiting for ${what}`);
}

const isSessionsSnapshot = (m: Record<string, unknown>) =>
  m.t === "event" && m.kind === "sessions.snapshot";

const eventOf = (sessionId: string, kind: string, afterSeq = 0) =>
  (m: Record<string, unknown>) => {
    if (m.t !== "event" || m.kind !== "session.event") return false;
    const e = m.event as { kind?: string; sessionId?: string; seq?: number } | undefined;
    // `afterSeq` is essential after a restart: `sub` REPLAYS the whole
    // transcript, so matching on kind alone would happily accept run 1's reply
    // (or run 1's teardown error) as proof about the resumed agent.
    return e?.kind === kind && e.sessionId === sessionId && (e.seq ?? 0) > afterSeq;
  };

// ---------------------------------------------------------------------------
// recording proxy in front of the fake model
// ---------------------------------------------------------------------------

/** Records every request body pi sends to the model, then forwards verbatim. */
async function startRecordingProxy(upstreamPort: number) {
  const bodies: string[] = [];
  const server: Server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = Buffer.concat(chunks);
    if (body.length > 0) bodies.push(body.toString());
    const upstream = await fetch(`http://127.0.0.1:${upstreamPort}${req.url}`, {
      method: req.method,
      headers: { "content-type": "application/json" },
      body: body.length > 0 ? body : undefined,
    });
    res.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") ?? "application/json",
    });
    if (upstream.body) {
      for await (const chunk of upstream.body as unknown as AsyncIterable<Uint8Array>) {
        res.write(Buffer.from(chunk));
      }
    }
    res.end();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}/v1`,
    bodies,
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

// ---------------------------------------------------------------------------
// server lifecycle
// ---------------------------------------------------------------------------

async function boot(project: string, store: SqliteEventStore) {
  const cert = await loadOrCreateCert();
  const manager = new SessionManager({
    projects: [project],
    store,
    defaultModel: FAKE_MODEL,
    // No adapterFactory => the REAL adapter for the default agent (pi over ACP).
  });
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry: new DeviceRegistry(),
    trustLocalhost: true,
  });
  const bridge = await startBridge({ askDevice: async () => ({}) as never });
  // extensionPaths only reach the agent when a bridge is set; without this pi
  // would never load the fake provider and --model would not resolve.
  manager.setBridge({
    url: bridge.url,
    token: bridge.token,
    extensionPaths: [FAKE_PROVIDER_EXT],
  });
  await new Promise<void>((r) => {
    if (srv.https.listening) r();
    else srv.https.once("listening", () => r());
  });
  return {
    manager,
    port: (srv.https.address() as AddressInfo).port,
    async stop() {
      srv.wss.close();
      srv.https.close();
      srv.localHttps?.close();
      await bridge.stop();
    },
  };
}

// ---------------------------------------------------------------------------

async function main() {
  const home = mkdtempSync(join(tmpdir(), "makit-reattach-real-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-reattach-real-proj-"));
  process.env.MAKIT_HOME = home;
  const store = new SqliteEventStore(resolve(home, "makit.db"));

  const fake = await startFakeModelServer();
  const proxy = await startRecordingProxy(fake.port);
  process.env.MAKIT_FAKE_MODEL_URL = proxy.url;

  let phase = "boot";
  try {
    // === run 1: a real pi session takes one turn ==========================
    phase = "first run";
    const first = await boot(project, store);
    await first.manager.ensureDefaultSessions();
    const session = first.manager.allSessions()[0]!;
    const sessionId = session.id;

    // Before the FIRST prompt: refuse to bill a real provider by accident.
    guardAgainstRealBilling("e2e-reattach-real", currentModelFromEvents(session.events));

    const c1 = await connect(first.port);
    c1.ws.send(JSON.stringify({ v: 1, t: "sub", id: "s1", sessionId }));
    c1.ws.send(
      JSON.stringify({
        v: 1, t: "cmd", id: "c1", kind: "send.message", sessionId,
        text: `Remember this token: ${NONCE}`,
      }),
    );
    await waitFor(c1, eventOf(sessionId, "agent.message"), "the first real reply");
    // Let the turn settle before killing: tearing the adapter down mid-stream
    // records a real `prompt failed` error into the durable log, which the
    // post-restart `sub` would then replay and this test would misread.
    for (let i = 0; i < 100 && session.status !== "idle"; i++) {
      await new Promise((r) => setTimeout(r, 50));
    }
    const idBefore = session.agentSessionId;
    assert.ok(idBefore, "pi reported a native session id (needed to resume)");
    console.log(`[1/4] real pi replied; native session id = ${idBefore}`);

    // Simulate the crash: the agent process dies with the server.
    await session.adapter.kill();
    c1.ws.close();
    await first.stop();

    // === run 2: restart over the SAME event log ===========================
    phase = "restart";
    const second = await boot(project, store);
    const cold = second.manager.getSession(sessionId);
    assert.ok(cold, "the session rehydrated from the event log");
    assert.equal(cold!.status, "exited", "it came back COLD");
    assert.equal(cold!.toDTO().resumable, true, "and advertises itself resumable");
    console.log("[2/4] after restart: session is cold + resumable");

    // === the fix: a plain `sub` must bring it back ========================
    phase = "sub re-attach";
    // Trace the adapter swap + status so a failure shows the real sequence
    // (Detached -> Acp -> ...?) instead of only its last symptom.
    const t0 = Date.now();
    let last = "";
    const trace = setInterval(() => {
      const s2 = second.manager.getSession(sessionId);
      if (!s2) return;
      const now = `${s2.adapter.constructor.name}/${s2.status}`;
      if (now !== last) {
        last = now;
        console.log(`    t+${String(Date.now() - t0).padStart(5)}ms  ${now}`);
      }
    }, 20);
    const c2 = await connect(second.port);
    await waitFor(c2, isSessionsSnapshot, "the cold snapshot");
    c2.ws.send(JSON.stringify({ v: 1, t: "sub", id: "s2", sessionId }));
    await waitFor(
      c2,
      (m) =>
        isSessionsSnapshot(m) &&
        (m.sessions as Array<{ id: string; status: string }>).find((s) => s.id === sessionId)
          ?.status !== "exited",
      "the session going live again after a bare `sub`",
    );
    const idAfter = second.manager.getSession(sessionId)!.agentSessionId;
    assert.equal(idAfter, idBefore, "pi RESUMED its session rather than starting fresh");
    console.log("[3/4] `sub` alone re-attached it; pi resumed the same session id");

    // Give pi a moment to fully initialize the resumed session before sending input
    await new Promise((r) => setTimeout(r, 500));

    // === and it is really usable, with its context ========================
    phase = "post-restart turn";
    const before = proxy.bodies.length;
    const seqBefore = second.manager.getSession(sessionId)!.events.at(-1)?.seq ?? 0;
    c2.ws.send(
      JSON.stringify({
        v: 1, t: "cmd", id: "c2", kind: "send.message", sessionId,
        text: "Which token did I ask you to remember?",
      }),
    );
    await waitFor(
      c2,
      eventOf(sessionId, "agent.message", seqBefore),
      "a NEW reply from the resumed agent",
      90_000,
    );
    const newErrors = c2.msgs
      .filter(eventOf(sessionId, "session.error", seqBefore))
      .map((m) => String(((m.event as { payload?: { message?: unknown } }).payload ?? {}).message));
    assert.deepEqual(newErrors, [], `the resumed turn errored: ${newErrors.join(" | ")}`);
    // Context retention is reported, not asserted: the fake-model provider is
    // NOT actually in play here (pi answers from its own configured model, so
    // the recording proxy sees no traffic), and string-matching a real model's
    // prose would be flaky. What IS asserted above is the part this feature
    // owns: the resumed session took a NEW turn and produced a NEW reply with
    // no error.
    const newReply = c2.msgs
      .filter(eventOf(sessionId, "agent.message", seqBefore))
      .map((m) => String(((m.event as { payload?: { text?: unknown } }).payload ?? {}).text ?? ""))
      .join("");
    const sawModelTraffic = proxy.bodies.length > before;
    console.log(
      `      context check: ${
        newReply.includes(NONCE) ? "the resumed agent echoed the pre-restart token" : "inconclusive (model prose)"
      }; fake-model traffic=${sawModelTraffic}`,
    );
    clearInterval(trace);
    console.log("[4/4] the resumed agent took a NEW turn: new reply, no new error");

    c2.ws.close();
    await second.manager.getSession(sessionId)!.adapter.kill();
    await second.stop();
    console.log("\nPASS — real pi session survived a server restart via `sub` alone.");
  } catch (e) {
    console.error(`\nFAIL during "${phase}": ${(e as Error).message}`);
    process.exitCode = 1;
  } finally {
    await proxy.close();
    await fake.close();
    store.close();
    if (existsSync(home)) rmSync(home, { recursive: true, force: true });
    if (existsSync(project)) rmSync(project, { recursive: true, force: true });
  }
}

await main();
