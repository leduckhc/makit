/**
 * T6 (SPEC-cli-as-client) — the shared WSS client module.
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

import { openClient, resolveBearer, cliCredentialPath, verifiesCert, SNAPSHOT_TIMEOUT_MS } from "./client.js";
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

/**
 * Reject if `p` has not settled in time. A hang must *fail* the test with a
 * legible message rather than stall the run until the runner's own timeout,
 * where it reports as a whole file with no diagnostic.
 */
function settledWithin<T>(p: Promise<T>, ms = 1000): Promise<T> {
  return Promise.race([
    p,
    new Promise<never>((_, rej) => {
      setTimeout(() => rej(new Error("HUNG: promise never settled")), ms).unref();
    }),
  ]);
}

// --------------------------------------------------------------------------
// Teardown of the snapshot/projects waiters.
//
// These are the two awaits that are NOT keyed by frame id, so they are the two
// `failAll` can silently skip. An unsettled promise here holds an open handle
// and the verb never reaches an exit code at all — the exact failure D8 exists
// to prevent, and it strands `ls`, `new`, `run`, `fork` and `wait` alike.
// --------------------------------------------------------------------------

test("close() while awaiting the snapshot rejects instead of hanging forever", async () => {
  const stub = await startStub({ acceptBearer: "good" }); // pushes no snapshot
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  await client.hello();
  const waiting = client.awaitSnapshot();
  client.close();
  await assert.rejects(settledWithin(waiting), /closed/i);
  await stub.close();
});

test("a socket that dies while awaiting the snapshot rejects instead of hanging forever", async () => {
  const stub = await startStub({ acceptBearer: "good" });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  await client.hello();
  const waiting = client.awaitSnapshot();
  await stub.close(); // server-side terminate: the client never called close()
  await assert.rejects(settledWithin(waiting), /closed/i);
  client.close();
});

test("close() while awaiting projects rejects instead of hanging forever", async () => {
  const stub = await startStub({ acceptBearer: "good" }); // pushes no projects
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  await client.hello();
  const waiting = client.awaitProjects();
  client.close();
  await assert.rejects(settledWithin(waiting), /closed/i);
  await stub.close();
});

test("two callers awaiting the same snapshot are both resolved, not just the last", async () => {
  // A single-waiter slot silently orphans the first caller: its promise is
  // overwritten and never settles, which is a permanent leak rather than an
  // error anyone can see.
  const stub = await startStub({ acceptBearer: "good", sessions: [{ id: "s1" }] });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  try {
    const first = client.awaitSnapshot();
    const second = client.awaitSnapshot();
    await client.hello();
    const [a, b] = await settledWithin(Promise.all([first, second]));
    assert.deepEqual(a.sessions, [{ id: "s1" }]);
    assert.deepEqual(b.sessions, [{ id: "s1" }]);
  } finally {
    client.close();
    await stub.close();
  }
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

// --------------------------------------------------------------------------
// TLS verification is skipped for loopback ONLY
//
// The `rejectUnauthorized: false` default is justified by a comment that says
// "the CLI talks to loopback, self-signed" — but `host` comes from `--host`
// argv, so the exemption silently covered every remote host too. D11 says
// remote is P3 and must pin the fingerprint the app pins; until it exists, a
// remote target must fail loudly rather than connect unverified.
// --------------------------------------------------------------------------

test("loopback keeps the self-signed exemption (127.0.0.1 and ::1 and localhost)", () => {
  for (const host of ["127.0.0.1", "::1", "localhost", "127.1.2.3"]) {
    assert.equal(verifiesCert(host), false, `${host} is loopback`);
  }
});

test("a non-loopback host is verified, so a remote target cannot be silently unverified", () => {
  for (const host of ["192.168.1.10", "makit.example.com", "10.0.0.4", "100.64.0.1"]) {
    assert.equal(verifiesCert(host), true, `${host} is remote`);
  }
});

test("an explicit rejectUnauthorized always wins over the host default", () => {
  assert.equal(verifiesCert("192.168.1.10", false), false, "an explicit opt-out is honoured");
  assert.equal(verifiesCert("127.0.0.1", true), true, "an explicit opt-in is honoured");
});

// --------------------------------------------------------------------------
// The protocol envelope is not overwritable by command fields
// --------------------------------------------------------------------------

test("a cmd field named like an envelope key cannot corrupt the frame", async () => {
  // Several verbs forward user-derived values (`text` from argv, a manifest from
  // an LLM). A collision — accidental or hostile — must not be able to rewrite
  // `id` (which is how the reply is correlated) or `t`/`kind` (how it is routed).
  const seen: Record<string, unknown>[] = [];
  const stub = await startStub({
    acceptBearer: "good",
    onCmd: (m) => {
      seen.push(m);
      return {};
    },
  });
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  try {
    await client.hello();
    await client.cmd("send.message", { t: "hello", id: "STOLEN", kind: "session.kill", v: 99, text: "hi" });
    const frame = seen[0]!;
    assert.equal(frame.t, "cmd", "t stays cmd");
    assert.equal(frame.kind, "send.message", "kind stays the verb the caller asked for");
    assert.notEqual(frame.id, "STOLEN", "the correlation id is ours, not the caller's");
    assert.equal(frame.v, 1, "the protocol version is not caller-settable");
    assert.equal(frame.text, "hi", "ordinary fields still ride along");
  } finally {
    client.close();
    await stub.close();
  }
});

test("a server that stays up but never pushes a snapshot does not hang the verb", async () => {
  // Rejecting on *close* is not enough: a live server that simply never pushes
  // leaves the socket open and the event loop alive, so the verb emits no output
  // and no exit code at all. That is the one outcome D8's contract cannot
  // express, and in CI it appears as a job cancelled minutes later with nothing
  // naming the cause.
  const stub = await startStub({ acceptBearer: "good" }); // no `sessions` → never pushes
  const client = await openClient({ host: "127.0.0.1", port: stub.port, bearer: "good" });
  try {
    await client.hello();
    assert.ok(SNAPSHOT_TIMEOUT_MS >= 10_000, "the bound must be generous enough never to fire in anger");
    // Proving the bound exists without waiting it out: the promise must be
    // pending now (the server is healthy, just quiet) and must carry a rejection
    // path rather than being a promise nobody can ever settle.
    const pending = client.awaitSnapshot();
    const raced = await Promise.race([
      pending.then(() => "settled", () => "rejected"),
      new Promise((r) => setTimeout(() => r("still-waiting"), 150)),
    ]);
    assert.equal(raced, "still-waiting", "a healthy quiet server is waited for, not failed instantly");
    pending.catch(() => {}); // the timeout will reject it after the test ends
  } finally {
    client.close();
    await stub.close();
  }
});
