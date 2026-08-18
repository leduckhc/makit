/**
 * End-to-end attachment flow (SPEC-user-attachments T11) — the whole feature over real
 * transports, with no mocks between the two halves:
 *
 *   `POST /media` (HTTPS, bearer/loopback) → `send.message {attachments}` (WSS)
 *     → materialised file in the worktree → path named in the agent's prompt
 *     → `user.message` event carrying descriptors (never bytes)
 *
 * Uses the real {@link startWsServer} + {@link StubAdapter} — the keyless loop
 * described in AGENTS.md — so it needs no agent binary and no API key.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { request } from "node:https";
import { WebSocket } from "ws";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";
import { StubAdapter } from "../../src/adapters/stub.js";
import { resetSharedMediaStoreForTests } from "../../src/media/store.js";

const PNG = Buffer.from("89504e470d0a1a0a-pretend-png-bytes");

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
  timeoutMs = 3000,
): Promise<Record<string, unknown>> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = client.msgs.find(pred);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(
    `timeout; frames seen: ${client.msgs.map((m) => `${m.t}/${m.kind ?? ""}`).join(", ")}`,
  );
}

/** POST the bytes to the real media route over TLS (self-signed → unverified). */
function upload(
  port: number,
  bytes: Buffer,
  mime: string,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: "127.0.0.1",
        port,
        path: "/media",
        method: "POST",
        rejectUnauthorized: false,
        headers: { "Content-Type": mime, "Content-Length": bytes.length },
      },
      (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body }));
      },
    );
    req.on("error", reject);
    req.end(bytes);
  });
}

/** A git repo with one commit — what a session's worktree looks like. */
function initRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-e2e-attach-repo-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "ignore" });
  execFileSync("git", ["init", "-q", "-b", "main", dir], { stdio: "ignore" });
  g("config", "user.email", "t@example.com");
  g("config", "user.name", "T");
  writeFileSync(join(dir, "README.md"), "hi\n");
  g("add", "-A");
  g("commit", "-qm", "init");
  return dir;
}

const isSessionsSnapshot = (m: Record<string, unknown>) =>
  m.t === "event" && m.kind === "sessions.snapshot";

function userMessageFrame(m: Record<string, unknown>): boolean {
  if (m.t !== "event" || m.kind !== "session.event") return false;
  return (m.event as { kind?: string } | undefined)?.kind === "user.message";
}

test("an uploaded image reaches the agent as a worktree file and the app as a descriptor", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-e2e-attach-home-"));
  const project = initRepo();
  const prevHome = process.env.MAKIT_HOME;
  // Scopes the media store (and everything else) to a temp dir.
  process.env.MAKIT_HOME = home;
  // The shared store caches its directory on first use, so without this the
  // second test resolves blobs out of the first test's temp dir.
  resetSharedMediaStoreForTests();

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
  const client = connect(port);

  try {
    await waitOpen(client.ws);
    const snap = await waitFor(client, isSessionsSnapshot);
    const sessionId = (snap.sessions as { id: string }[])[0]!.id;

    // 1. Upload — the same route the app's pinned client posts to.
    const res = await upload(port, PNG, "image/png");
    assert.equal(res.status, 201, res.body);
    const { mediaId } = JSON.parse(res.body) as { mediaId: string };
    assert.match(mediaId, /^[a-f0-9]{64}$/);

    // 2. Send a turn naming that id.
    client.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "m1",
        kind: "send.message",
        sessionId,
        text: "what is wrong here?",
        attachments: [{ mediaId, name: "shot.png" }],
      }),
    );

    // 3. The echoed user.message carries descriptors — and NOT the bytes, which
    //    would be re-sent on every resume (the whole reason for the store).
    const frame = await waitFor(client, userMessageFrame);
    const payload = (frame.event as { payload: Record<string, unknown> }).payload;
    assert.equal(payload.text, "what is wrong here?");
    const attachments = payload.attachments as Record<string, unknown>[];
    assert.equal(attachments.length, 1);
    assert.equal(attachments[0]!.mediaId, mediaId);
    assert.equal(attachments[0]!.mime, "image/png");
    assert.equal(attachments[0]!.sizeBytes, PNG.length);
    assert.equal(attachments[0]!.name, "shot.png");
    assert.ok(
      !JSON.stringify(payload).includes(PNG.toString("base64")),
      "bytes must never ride on the event",
    );

    // 4. The agent's prompt names a file that exists and holds the bytes.
    const sent = manager.getSession(sessionId)!;
    const worktree = sent.worktreePath ?? project;
    const dir = join(worktree, ".makit", "attachments");
    const files = readdirSync(dir);
    assert.equal(files.length, 1, `expected one attachment file, got ${files.join(",")}`);
    assert.match(files[0]!, /^[a-f0-9]{7}-shot\.png$/);
    assert.deepEqual(readFileSync(join(dir, files[0]!)), PNG);

    // 5. The stub agent echoes the prompt it was given, so the path is visible
    //    on the wire — this is the assertion that the agent could actually act.
    const echo = await waitFor(client, (m) => {
      if (m.t !== "event" || m.kind !== "session.event") return false;
      const e = m.event as { kind?: string; payload?: { text?: string } };
      return e.kind === "agent.message" && (e.payload?.text ?? "").includes("Attached files:");
    });
    const echoText = (echo.event as { payload: { text: string } }).payload.text;
    assert.ok(echoText.includes(join(dir, files[0]!)), echoText);

    // 6. The user's repo stays clean — pasting a screenshot must not create a
    //    diff in their worktree.
    const status = execFileSync("git", ["status", "--porcelain"], {
      cwd: worktree,
      encoding: "utf8",
    });
    assert.equal(status.trim(), "", `worktree must stay clean, got:\n${status}`);
  } finally {
    client.ws.close();
    srv.https.close();
    srv.wss.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    resetSharedMediaStoreForTests();
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});

test("a stale mediaId is refused, and the turn is not sent", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-e2e-attach-home2-"));
  const project = initRepo();
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  // The shared store caches its directory on first use, so without this the
  // second test resolves blobs out of the first test's temp dir.
  resetSharedMediaStoreForTests();

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
  const client = connect(port);

  try {
    await waitOpen(client.ws);
    const snap = await waitFor(client, isSessionsSnapshot);
    const sessionId = (snap.sessions as { id: string }[])[0]!.id;

    client.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "m2",
        kind: "send.message",
        sessionId,
        text: "look",
        attachments: [{ mediaId: "b".repeat(64) }], // never uploaded
      }),
    );

    const err = await waitFor(client, (m) => m.t === "err" && m.id === "m2");
    assert.match(String(err.message), /attachment/i);
    // The user must not get an answer about an image the agent never saw.
    assert.equal(
      client.msgs.some(userMessageFrame),
      false,
      "no turn may be sent when an attachment cannot be resolved",
    );
  } finally {
    client.ws.close();
    srv.https.close();
    srv.wss.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    resetSharedMediaStoreForTests();
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
