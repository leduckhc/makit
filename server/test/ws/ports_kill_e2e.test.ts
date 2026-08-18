/**
 * SPEC-ports-kill P3a e2e — `ports.kill` over the real WSS server.
 *
 * Three properties no unit test can prove together:
 *  1. an **unauthed** frame never reaches the handler (D4's floor: the paired
 *     bearer, or loopback under `trustLocalhost`, is the gate),
 *  2. a confirmed, worktree-owned tuple is signalled and the released endpoint
 *     disappears from the very next broadcast (the immediate re-scan),
 *  3. a **system** listener is refused with `not_owned` and **no signal at all**
 *     (D3's whitelist, end to end).
 *
 * `signal` is injected: the scan is scripted, so its pids are fictional and a
 * real `process.kill` could land on an unrelated process on the dev machine.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";
import { StubAdapter } from "../../src/adapters/stub.js";
import type { Exec } from "../../src/metrics/proc_table.js";

const DEV_PID = 4242;
const SSHD_PID = 77;

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
  throw new Error("timeout waiting for a matching frame");
}

/** Fixed clock so `startedAt` is deterministic for the identity tuple (D1). */
const NOW = 1_700_000_000_000;
/** `01:00:00` of etime against {@link NOW}. */
const DEV_STARTED_AT = NOW - 3_600_000;

interface Harness {
  port: number;
  signals: { pid: number; sig: string }[];
  stop: () => void;
}

async function startHarness({ trustLocalhost = true } = {}): Promise<Harness> {
  const home = mkdtempSync(join(tmpdir(), "makit-kill-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-kill-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  execFileSync("git", ["init", "-q"], { cwd: project });
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
    { cwd: project },
  );

  const signals: { pid: number; sig: string }[] = [];
  /** Flipped by a SIGTERM to the dev server, so the next scan sees it gone. */
  let devAlive = true;

  const portsExec: Exec = async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      const rows = [`p${SSHD_PID}`, "u0", "PTCP", "n0.0.0.0:22"];
      if (devAlive) rows.push(`p${DEV_PID}`, "u501", "PTCP", "n127.0.0.1:5173");
      return { code: 0, stdout: rows.join("\n"), stderr: "" };
    }
    if (cmd === "ps") {
      return {
        code: 0,
        stdout: [`  ${SSHD_PID} 1 10:00:00 /usr/sbin/sshd`, `  ${DEV_PID} 1 01:00:00 node vite`].join("\n"),
        stderr: "",
      };
    }
    if (cmd === "lsof") {
      return {
        code: 0,
        stdout: [`p${DEV_PID}`, "fcwd", `n${project}`, `p${SSHD_PID}`, "fcwd", "n/"].join("\n"),
        stderr: "",
      };
    }
    return { code: 0, stdout: "", stderr: "" };
  };

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
    trustLocalhost,
    ports: {
      exec: portsExec,
      now: () => NOW,
      signal: (pid, sig) => {
        signals.push({ pid, sig });
        if (pid === DEV_PID && sig === "SIGTERM") devAlive = false;
      },
      sleep: async () => {},
    },
  });

  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });

  return {
    port: (srv.https.address() as AddressInfo).port,
    signals,
    stop: () => {
      srv.wss.close();
      srv.https.close();
      srv.localHttps?.close();
      if (prevHome === undefined) delete process.env.MAKIT_HOME;
      else process.env.MAKIT_HOME = prevHome;
      rmSync(home, { recursive: true, force: true });
      rmSync(project, { recursive: true, force: true });
    },
  };
}

test("an UNAUTHED ports.kill is rejected and never signals anything", async () => {
  // No dev-mode carve-out here: `trustLocalhost:false` is how a real device
  // connects, so a socket that never said `hello` is unauthed.
  const h = await startHarness({ trustLocalhost: false });
  const c = connect(h.port);
  try {
    await waitOpen(c.ws);
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "k1",
        kind: "ports.kill",
        address: "127.0.0.1",
        port: 5173,
        pid: DEV_PID,
        startedAt: DEV_STARTED_AT,
      }),
    );
    const err = await waitFor(c, (m) => m.t === "err");
    assert.equal(err.code, "unauthorized");
    assert.deepEqual(h.signals, []);
  } finally {
    c.ws.close();
    h.stop();
  }
});

test("a confirmed worktree-owned tuple is killed and vanishes from the next snapshot", async () => {
  const h = await startHarness();
  const c = connect(h.port);
  try {
    await waitOpen(c.ws);
    c.ws.send(JSON.stringify({ v: 1, t: "hello", id: "h1" }));
    await waitFor(c, (m) => m.t === "hello.ack");
    // Attribution reads worktree paths from the GIT-ONLY repos snapshot, so wait
    // for it before asserting ownership (the finding-27 lesson next door).
    await waitFor(c, (m) => m.t === "event" && m.kind === "repos.snapshot");
    c.ws.send(JSON.stringify({ v: 1, t: "cmd", id: "w1", kind: "ports.watch", on: true }));

    const first = await waitFor(
      c,
      (m) =>
        m.kind === "ports.snapshot" &&
        ((m.snapshot as { ports: { pid: number }[] }).ports ?? []).some((p) => p.pid === DEV_PID),
    );
    const dev = (first.snapshot as { ports: { pid: number; worktreePath?: string }[] }).ports.find(
      (p) => p.pid === DEV_PID,
    );
    assert.ok(dev?.worktreePath, "the dev server is attributed to the worktree");

    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "k2",
        kind: "ports.kill",
        address: "127.0.0.1",
        port: 5173,
        pid: DEV_PID,
        startedAt: DEV_STARTED_AT,
      }),
    );
    const ack = await waitFor(c, (m) => m.t === "ack" && m.id === "k2");
    assert.equal(ack.outcome, "released");
    assert.equal(ack.port, 5173);
    assert.deepEqual(h.signals, [{ pid: DEV_PID, sig: "SIGTERM" }], "one signal, no SIGKILL");

    // The releasing outcome triggers an immediate re-scan + broadcast, so the
    // row is gone without waiting a whole scan interval.
    const after = await waitFor(
      c,
      (m) =>
        m.kind === "ports.snapshot" &&
        !((m.snapshot as { ports: { pid: number }[] }).ports ?? []).some((p) => p.pid === DEV_PID),
    );
    assert.ok(after);
  } finally {
    c.ws.close();
    h.stop();
  }
});

test("a SYSTEM listener is refused with not_owned, and is never signalled (D3)", async () => {
  const h = await startHarness();
  const c = connect(h.port);
  try {
    await waitOpen(c.ws);
    c.ws.send(JSON.stringify({ v: 1, t: "hello", id: "h1" }));
    await waitFor(c, (m) => m.t === "hello.ack");
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "k3",
        kind: "ports.kill",
        address: "0.0.0.0",
        port: 22,
        pid: SSHD_PID,
        startedAt: NOW - 36_000_000,
      }),
    );
    const ack = await waitFor(c, (m) => m.t === "ack" && m.id === "k3");
    assert.equal(ack.outcome, "not_owned");
    assert.deepEqual(h.signals, [], "sshd is not ours to signal");
  } finally {
    c.ws.close();
    h.stop();
  }
});
