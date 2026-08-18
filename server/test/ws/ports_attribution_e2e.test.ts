/**
 * SPEC-open-ports finding 27 regression: port attribution must work even when PR
 * enrichment (the `gh`-backed phase) never resolves. The scanner reads worktree
 * paths from the GIT-ONLY snapshot, which runs before enrichment and never
 * touches the network — so a missing / unauthenticated / rate-limited / slow
 * `gh` cannot silently kill attribution.
 *
 * The bug this guards: `listWorktreePaths` reading `lastEnrichedRepos` (undefined
 * until enrichment succeeds) would report every listener as unowned here.
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

test("port attribution survives a never-resolving PR enrichment (finding 27)", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-ports27-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-ports27-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  // A real git repo so its main worktree appears in the git-only snapshot.
  execFileSync("git", ["init", "-q"], { cwd: project });
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
    { cwd: project },
  );

  const manager = new SessionManager({
    projects: [project],
    adapterFactory: () => new StubAdapter(),
  });
  // Simulate `gh` hanging forever: enrichment never resolves, so the git-only
  // phase is the ONLY source of worktree paths.
  manager.enrichPrs = () => new Promise(() => {});

  // A deterministic scan: one listener in the project's cwd, no real lsof/ps.
  const PID = 4242;
  const portsExec: Exec = async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      return { code: 0, stdout: [`p${PID}`, "u501", "PTCP", "n127.0.0.1:5173"].join("\n"), stderr: "" };
    }
    if (cmd === "ps") return { code: 0, stdout: `  ${PID} 1 01:00:00 node vite`, stderr: "" };
    if (cmd === "lsof") return { code: 0, stdout: [`p${PID}`, "fcwd", `n${project}`].join("\n"), stderr: "" };
    return { code: 0, stdout: "", stderr: "" };
  };

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry,
    trustLocalhost: true,
    ports: { exec: portsExec },
  });

  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });
  const port = (srv.https.address() as AddressInfo).port;

  const c = connect(port);
  try {
    await waitOpen(c.ws);
    // Wait for the git-only repos.snapshot so lastGitOnlyRepos is populated
    // (enrichment never fires a second one).
    await waitFor(c, (m) => m.t === "event" && m.kind === "repos.snapshot");

    c.ws.send(JSON.stringify({ v: 1, t: "cmd", id: "w1", kind: "ports.watch", on: true }));

    const snap = await waitFor(
      c,
      (m) => m.t === "event" && m.kind === "ports.snapshot" && Array.isArray((m.snapshot as { ports?: unknown[] })?.ports) && (m.snapshot as { ports: unknown[] }).ports.length > 0,
    );
    const ports = (snap.snapshot as { ports: Array<{ pid: number; worktreePath?: string }> }).ports;
    const mine = ports.find((p) => p.pid === PID);
    assert.ok(mine, "the scan found our listener");
    assert.ok(
      mine!.worktreePath !== undefined,
      "attributed to the worktree despite PR enrichment never resolving",
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
