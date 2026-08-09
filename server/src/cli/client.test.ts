/**
 * T6 (SPEC-46) — the shared WSS client module.
 *
 * Drives `cli/client.ts` against a throwaway stub WSS server (self-signed cert,
 * same `hello`/`cmd`/`ack` envelope the app speaks). Also covers D2/D3
 * credential resolution order against a fake control client.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync, readFileSync, mkdirSync, writeFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { openClient, resolveBearer, cliCredentialPath } from "./client.js";
import type { ControlResponse } from "../daemon/protocol.js";
import { startStubWss as startStub } from "../../test/support/stub_wss.js";

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
  const prevHome = process.env.MAKIT_HOME;
  const prevToken = process.env.MAKIT_CLI_TOKEN;
  process.env.MAKIT_HOME = dir;
  delete process.env.MAKIT_CLI_TOKEN;
  const restore = () => {
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
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
    mkdirSync(process.env.MAKIT_HOME!, { recursive: true });
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
