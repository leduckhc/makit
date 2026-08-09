/**
 * T6 (SPEC-46) — the shared WSS client module.
 *
 * Drives `cli/client.ts` against a throwaway stub WSS server (self-signed cert,
 * same `hello`/`cmd`/`ack` envelope the app speaks). Also covers D2/D3
 * credential resolution order against a fake control client.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:https";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import type { AddressInfo } from "node:net";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import selfsigned from "selfsigned";

import { openClient, resolveBearer, cliCredentialPath } from "./client.js";
import type { ControlResponse } from "../daemon/protocol.js";

interface StubOpts {
  /** When set, a `hello` whose bearer differs is rejected (err + close 4401). */
  acceptBearer?: string;
  /** Pushed as a `sessions.snapshot` event right after `hello.ack`. */
  sessions?: unknown[];
  /** Called for each `cmd` frame; returns the ack payload to merge into the reply. */
  onCmd?: (m: Record<string, unknown>) => Record<string, unknown>;
}

interface Stub {
  port: number;
  close: () => Promise<void>;
}

async function startStub(opts: StubOpts = {}): Promise<Stub> {
  const pems = await selfsigned.generate([{ name: "commonName", value: "makit" }], {
    keySize: 2048,
    algorithm: "sha256",
  });
  const https: Server = createServer({ cert: pems.cert, key: pems.private });
  const wss = new WebSocketServer({ server: https });
  wss.on("connection", (ws: WsSocket) => {
    ws.on("message", (buf: Buffer) => {
      let m: Record<string, unknown>;
      try {
        m = JSON.parse(buf.toString());
      } catch {
        return;
      }
      if (m.t === "hello") {
        if (opts.acceptBearer !== undefined && m.bearer !== opts.acceptBearer) {
          ws.send(JSON.stringify({ t: "err", id: m.id, code: "unauthorized", message: "unknown device" }));
          ws.close(4401, "unauthorized");
          return;
        }
        ws.send(JSON.stringify({ t: "hello.ack", id: m.id, ok: true, deviceId: "d1" }));
        if (opts.sessions) {
          ws.send(JSON.stringify({ t: "event", id: "snap", kind: "sessions.snapshot", sessions: opts.sessions }));
        }
        return;
      }
      if (m.t === "cmd") {
        const extra = opts.onCmd ? opts.onCmd(m) : {};
        ws.send(JSON.stringify({ t: "ack", id: m.id, ...extra }));
        return;
      }
    });
  });
  await new Promise<void>((resolve) => https.listen(0, "127.0.0.1", resolve));
  const port = (https.address() as AddressInfo).port;
  return {
    port,
    close: () =>
      new Promise<void>((resolve) => {
        wss.close(() => https.close(() => resolve()));
      }),
  };
}

test("openClient + hello: authenticates and caches the pushed snapshot", async () => {
  const stub = await startStub({ acceptBearer: "good", sessions: [{ id: "s1" }] });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  try {
    await client.hello();
    const snap = await client.awaitSnapshot();
    assert.deepEqual(snap.sessions, [{ id: "s1" }]);
  } finally {
    client.close();
    await stub.close();
  }
});

test("cmd/ack correlate by frame id, even when replies arrive out of order", async () => {
  // The stub echoes each cmd's own marker back on its own id, but the client
  // must not confuse two in-flight cmds — correlation is by id, not arrival.
  const stub = await startStub({
    acceptBearer: "good",
    onCmd: (m) => ({ marker: m.marker }),
  });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  try {
    await client.hello();
    const [a, b] = await Promise.all([
      client.cmd("session.a", { marker: "AAA" }),
      client.cmd("session.b", { marker: "BBB" }),
    ]);
    assert.equal(a.marker, "AAA");
    assert.equal(b.marker, "BBB");
  } finally {
    client.close();
    await stub.close();
  }
});

test("a rejected hello surfaces as an auth error and does NOT hang", async () => {
  const stub = await startStub({ acceptBearer: "good" });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "WRONG" });
  try {
    await assert.rejects(client.hello(), /auth|unauthorized|unknown device/i);
  } finally {
    client.close();
    await stub.close();
  }
});

test("teardown: close() rejects in-flight cmds and leaves no open socket", async () => {
  const stub = await startStub({ acceptBearer: "good" }); // never acks cmds
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  await client.hello();
  const inflight = client.cmd("session.never");
  client.close();
  await assert.rejects(inflight, /closed/i);
  await assert.rejects(client.cmd("session.after"), /closed/i);
  await stub.close();
});

// --------------------------------------------------------------------------
// D2/D3 credential resolution order: env → cli.json → cli.grant (cached 0600)
// --------------------------------------------------------------------------

function withTempHome<T>(fn: () => Promise<T>): Promise<T> {
  const dir = mkdtempSync(join(tmpdir(), "makit-cli-home-"));
  const prevHome = process.env.HOME;
  const prevToken = process.env.MAKIT_CLI_TOKEN;
  process.env.HOME = dir;
  delete process.env.MAKIT_CLI_TOKEN;
  const restore = () => {
    if (prevHome === undefined) delete process.env.HOME;
    else process.env.HOME = prevHome;
    if (prevToken === undefined) delete process.env.MAKIT_CLI_TOKEN;
    else process.env.MAKIT_CLI_TOKEN = prevToken;
    rmSync(dir, { recursive: true, force: true });
  };
  return fn().finally(restore);
}

const okGrant = (): { request: (v: string) => Promise<ControlResponse> } => ({
  request: async () =>
    ({ id: "1", ok: true, data: { deviceId: "cli-1", label: "cli@host", bearer: "GRANTED", created: true } }) as ControlResponse,
});

test("resolveBearer prefers MAKIT_CLI_TOKEN and never touches the control socket", async () => {
  await withTempHome(async () => {
    process.env.MAKIT_CLI_TOKEN = "env-token";
    let called = false;
    const control = { request: async () => { called = true; return { id: "1", ok: true } as ControlResponse; } };
    const bearer = await resolveBearer(control);
    assert.equal(bearer, "env-token");
    assert.equal(called, false);
  });
});

test("resolveBearer returns the cached cli.json bearer without granting", async () => {
  await withTempHome(async () => {
    mkdirSync(join(process.env.HOME!, ".makit"), { recursive: true });
    writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@host", bearer: "CACHED" }));
    let called = false;
    const control = { request: async () => { called = true; return { id: "1", ok: true } as ControlResponse; } };
    const bearer = await resolveBearer(control);
    assert.equal(bearer, "CACHED");
    assert.equal(called, false);
  });
});

test("resolveBearer mints via cli.grant and caches it at mode 0600", async () => {
  await withTempHome(async () => {
    const bearer = await resolveBearer(okGrant());
    assert.equal(bearer, "GRANTED");
    assert.ok(existsSync(cliCredentialPath()), "cli.json must be written");
    assert.equal(JSON.parse(readFileSync(cliCredentialPath(), "utf8")).bearer, "GRANTED");
    assert.equal(statSync(cliCredentialPath()).mode & 0o777, 0o600);
  });
});
