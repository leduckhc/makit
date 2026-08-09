/**
 * SPEC-44 P4b e2e — forward a REAL loopback dev server over the REAL WSS
 * listener, and read its bytes back through the proxy.
 *
 * This is the claim that cannot be unit-tested: the forward route rides the HTTPS
 * listener that already carries the WebSocket (D1), so a forward opens **no new
 * host port** — the same `srv.https` serves the WS upgrade and `/forward/…`.
 * The test therefore mints a grant over the socket and then fetches through the
 * same port number, with the same TLS.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { createServer, type Server } from "node:http";
import { request as httpsRequest } from "node:https";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";
import { StubAdapter } from "../../src/adapters/stub.js";
import type { Exec } from "../../src/metrics/proc_table.js";

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
      /* ignore */
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
  timeoutMs = 4000,
): Promise<Record<string, unknown>> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = client.msgs.find(pred);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("timeout waiting for a frame");
}

/** GET over the pinned-but-unverified TLS listener (a stand-in for the phone). */
function getThroughProxy(
  port: number,
  path: string,
): Promise<{ status: number; body: string; headers: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      // No `Authorization` header on purpose: a browser cannot send one, so this
      // stands in for Safari (which would also show a self-signed-cert prompt —
      // the accepted wart of reusing the WSS listener's origin).
      { host: "127.0.0.1", port, path, method: "GET", rejectUnauthorized: false },
      (res) => {
        let body = "";
        res.on("data", (c: Buffer) => (body += c.toString()));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            body,
            headers: res.headers as Record<string, unknown>,
          }),
        );
      },
    );
    req.on("error", reject);
    req.end();
  });
}

test("a real loopback dev server is forwarded over the WSS listener itself", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-fwd-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-fwd-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  execFileSync("git", ["init", "-q"], { cwd: project });
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
    { cwd: project },
  );

  // A REAL dev server on loopback, in the worktree.
  let dev: Server | undefined;
  let srv: ReturnType<typeof startWsServer> | undefined;
  const c: { ws?: WebSocket; msgs: Record<string, unknown>[] } = { msgs: [] };
  try {
    dev = createServer((req, res) => {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(`<h1>your dev server</h1><p>${req.url}</p>`);
    });
    await new Promise<void>((r) => dev!.listen(0, "127.0.0.1", r));
    const devPort = (dev.address() as AddressInfo).port;

    // A scripted scan that reports the REAL listener (pid + port), attributed to
    // the project by cwd — so eligibility (D4) sees a real, HTTP-answering,
    // loopback, worktree-owned port.
    const portsExec: Exec = async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        return {
          code: 0,
          stdout: [`p${process.pid}`, "u501", "PTCP", `n127.0.0.1:${devPort}`].join("\n"),
          stderr: "",
        };
      }
      if (cmd === "ps") {
        return { code: 0, stdout: `  ${process.pid} 1 00:05:00 node dev-server`, stderr: "" };
      }
      if (cmd === "lsof") {
        return { code: 0, stdout: [`p${process.pid}`, "fcwd", `n${project}`].join("\n"), stderr: "" };
      }
      return { code: 0, stdout: "", stderr: "" };
    };

    const manager = new SessionManager({
      projects: [project],
      adapterFactory: () => new StubAdapter(),
    });
    const cert = await loadOrCreateCert();
    srv = startWsServer({
      host: "127.0.0.1",
      port: 0,
      manager,
      cert,
      registry: new DeviceRegistry(),
      trustLocalhost: true,
      ports: { exec: portsExec },
    });
    await new Promise<void>((resolve) => {
      if (srv!.https.listening) resolve();
      else srv!.https.once("listening", () => resolve());
    });
    const wsPort = (srv.https.address() as AddressInfo).port;

    const client = connect(wsPort);
    c.ws = client.ws;
    c.msgs = client.msgs;
    await waitOpen(client.ws);
    client.ws.send(JSON.stringify({ v: 1, t: "hello", id: "h1" }));
    await waitFor(client, (m) => m.t === "hello.ack");
    await waitFor(client, (m) => m.kind === "repos.snapshot");
    client.ws.send(JSON.stringify({ v: 1, t: "cmd", id: "w1", kind: "ports.watch", on: true }));
    // Wait for a snapshot where the port has an `openUrl`: the HTTP probe runs
    // AFTER publishing (stale-while-revalidate), so the verdict — and therefore
    // forward eligibility (D4.3) — lands on a later tick.
    const snap = await waitFor(
      client,
      (m) =>
        m.kind === "ports.snapshot" &&
        ((m.snapshot as { ports: { port: number; openUrl?: string }[] }).ports ?? []).some(
          (p) => p.port === devPort && p.openUrl !== undefined,
        ),
      12_000,
    );
    // The owner path comes from the SNAPSHOT, exactly as the app's sheet passes
    // back `port.worktreePath` — the server resolves symlinks (/var →
    // /private/var), so the raw temp path would not match.
    const row = (snap.snapshot as { ports: { port: number; worktreePath?: string; openUrl?: string }[] }).ports.find(
      (p) => p.port === devPort,
    );
    assert.ok(row?.worktreePath, "the real listener is attributed to the worktree");
    assert.ok(row.openUrl, "it answered the HTTP probe, so it is forwardable");

    // 1. Mint a BROWSER grant — the shape the system-browser hand-off uses.
    client.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "f1",
        kind: "ports.forward",
        worktreePath: row.worktreePath,
        port: devPort,
        browser: true,
      }),
    );
    const ack = await waitFor(client, (m) => m.t === "ack" && m.id === "f1");
    const grant = ack.grant as
      | { grantId: string; port: number; expiresAt: number; path: string; browser: boolean }
      | undefined;
    assert.ok(grant?.grantId, `no grant minted: ${JSON.stringify(ack)}`);
    assert.equal(grant.port, devPort);
    assert.equal(grant.browser, true);
    assert.equal(grant.path, `/forward/${grant.grantId}/`, "the client is told what to open");

    // 2. Read the dev server's bytes THROUGH the same listener the WS uses —
    // with NO Authorization header, exactly as Safari would. This is the whole
    // system-browser claim: same host, same port, same TLS, no in-app proxy.
    const proxied = await getThroughProxy(wsPort, `${grant.path}index.html`);
    assert.equal(proxied.status, 200);
    assert.match(proxied.body, /your dev server/);
    assert.match(proxied.body, /\/index\.html/, "the upstream saw the real path");
    assert.equal(
      proxied.headers["referrer-policy"],
      "no-referrer",
      "the grant URL must not leak onward from the previewed page",
    );

    // 3. Stop revokes it — the very next request is refused, not served stale.
    client.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "s1",
        kind: "ports.forward.stop",
        grantId: grant.grantId,
      }),
    );
    await waitFor(client, (m) => m.t === "ack" && m.id === "s1");
    const afterStop = await getThroughProxy(wsPort, `${grant.path}index.html`);
    assert.equal(afterStop.status, 403);
  } finally {
    c.ws?.close();
    srv?.wss.close();
    srv?.https.close();
    srv?.localHttps?.close();
    if (dev) await new Promise<void>((r) => dev!.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});

test("a database port is refused even when the client asks nicely", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-fwd2-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-fwd2-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  let srv: ReturnType<typeof startWsServer> | undefined;
  const client: { ws?: WebSocket } = {};
  try {
    execFileSync("git", ["init", "-q"], { cwd: project });
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
      { cwd: project },
    );
    const portsExec: Exec = async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        return { code: 0, stdout: ["p900", "u501", "PTCP", "n127.0.0.1:5432"].join("\n"), stderr: "" };
      }
      if (cmd === "ps") return { code: 0, stdout: "  900 1 01:00:00 postgres", stderr: "" };
      return { code: 0, stdout: ["p900", "fcwd", `n${project}`].join("\n"), stderr: "" };
    };
    const cert = await loadOrCreateCert();
    srv = startWsServer({
      host: "127.0.0.1",
      port: 0,
      manager: new SessionManager({ projects: [project], adapterFactory: () => new StubAdapter() }),
      cert,
      registry: new DeviceRegistry(),
      trustLocalhost: true,
      ports: { exec: portsExec },
    });
    await new Promise<void>((resolve) => {
      if (srv!.https.listening) resolve();
      else srv!.https.once("listening", () => resolve());
    });
    const wsPort = (srv.https.address() as AddressInfo).port;
    const c = connect(wsPort);
    client.ws = c.ws;
    await waitOpen(c.ws);
    c.ws.send(JSON.stringify({ v: 1, t: "hello", id: "h1" }));
    await waitFor(c, (m) => m.t === "hello.ack");
    await waitFor(c, (m) => m.kind === "repos.snapshot");
    c.ws.send(JSON.stringify({ v: 1, t: "cmd", id: "w9", kind: "ports.watch", on: true }));
    const snap = await waitFor(
      c,
      (m) =>
        m.kind === "ports.snapshot" &&
        ((m.snapshot as { ports: { port: number }[] }).ports ?? []).some((p) => p.port === 5432),
    );
    const owner = (snap.snapshot as { ports: { port: number; worktreePath?: string }[] }).ports.find(
      (p) => p.port === 5432,
    )?.worktreePath;
    assert.ok(owner, "postgres is attributed to the worktree — and still refused");
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "f9",
        kind: "ports.forward",
        worktreePath: owner,
        port: 5432,
      }),
    );
    const err = await waitFor(c, (m) => m.t === "err" && m.id === "f9");
    assert.match(String(err.message), /database and shell ports/);
  } finally {
    client.ws?.close();
    srv?.wss.close();
    srv?.https.close();
    srv?.localHttps?.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});
