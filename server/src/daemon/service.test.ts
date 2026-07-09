/**
 * Daemon service tests (SPEC-01, phase 4).
 *
 * The service manages the background lifecycle (start/stop/restart/status/logs)
 * plus the PID file. We test the pure pieces (argv builder, PID file read/write,
 * status formatting) directly, and the orchestration with injected spawn/kill/
 * control-client stubs so no real process is launched and no real ~/.makit is
 * touched.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  buildServeArgv,
  readPidFile,
  writePidFile,
  createDaemon,
  type DaemonDeps,
  type SpawnedChild,
} from "./service.js";
import type { ControlClient } from "./control-client.js";

test("buildServeArgv forwards serve flags after the entry path", () => {
  const argv = buildServeArgv("/x/index.js", {
    host: "127.0.0.1",
    port: 9999,
    projects: ["/a", "/b"],
    noAuth: true,
    advertise: "host.local",
  });
  assert.deepEqual(argv, [
    "/x/index.js",
    "serve",
    "--host",
    "127.0.0.1",
    "--port",
    "9999",
    "--advertise",
    "host.local",
    "--no-auth",
    "--project",
    "/a",
    "--project",
    "/b",
  ]);
});

test("PID file round-trips; missing/corrupt reads as null", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-svc-"));
  const pid = join(dir, "makit.pid");
  assert.equal(readPidFile(pid), null);
  writePidFile(pid, 4321);
  assert.equal(readPidFile(pid), 4321);
  writeFileSync(pid, "not-a-number");
  assert.equal(readPidFile(pid), null);
  rmSync(dir, { recursive: true, force: true });
});

interface Harness {
  deps: DaemonDeps;
  out: string[];
  spawned: Array<{ cmd: string; args: string[] }>;
  killed: Array<{ pid: number; signal: string }>;
  dir: string;
}

function harness(over: Partial<DaemonDeps> = {}): Harness {
  const dir = mkdtempSync(join(tmpdir(), "makit-svc-"));
  const out: string[] = [];
  const spawned: Array<{ cmd: string; args: string[] }> = [];
  const killed: Array<{ pid: number; signal: string }> = [];
  const deps: DaemonDeps = {
    entry: "/x/index.js",
    execPath: "/usr/bin/node",
    socketPath: join(dir, "control.sock"),
    pidPath: join(dir, "makit.pid"),
    logPath: join(dir, "makit.log"),
    out: (line) => out.push(line),
    spawn: (cmd, args): SpawnedChild => {
      spawned.push({ cmd, args });
      return { pid: 5555, unref() {} };
    },
    openLogFd: () => 3,
    kill: (pid, signal) => {
      killed.push({ pid, signal });
    },
    isAlive: () => true,
    connect: async () => {
      throw new Error("not running");
    },
    ...over,
  };
  return { deps, out, spawned, killed, dir };
}

function cleanup(h: Harness) {
  rmSync(h.dir, { recursive: true, force: true });
}

/** A `connect` that resolves to a control client whose `status` reports `pid`. */
function okStatus(pid: number): DaemonDeps["connect"] {
  return async () => ({
    request: (async () => ({
      id: "1",
      ok: true,
      data: {
        pid,
        uptimeMs: 5,
        host: "0.0.0.0",
        port: 8787,
        fingerprint: "fp",
        advertiseHost: "",
        pairedDevices: 0,
        runningSessions: 0,
        version: "0.1.0",
      },
    })) as ControlClient["request"],
    close() {},
  });
}

test("start: spawns detached, writes the PID file, returns 0", async () => {
  const h = harness({ isAlive: () => false, connect: okStatus(5555), sleep: async () => {} });
  const daemon = createDaemon(h.deps);
  const code = await daemon.start({ host: "0.0.0.0", port: 8787, projects: [], noAuth: false, advertise: "" });
  assert.equal(code, 0);
  assert.equal(h.spawned.length, 1);
  assert.equal(h.spawned[0]!.cmd, "/usr/bin/node");
  assert.equal(h.spawned[0]!.args[0], "/x/index.js");
  assert.equal(readPidFile(h.deps.pidPath), 5555);
  cleanup(h);
});

test("start: idempotent — already running prints status and does not spawn", async () => {
  const h = harness({
    isAlive: () => true,
    connect: async () => ({
      request: (async () => ({
        id: "1",
        ok: true,
        data: {
          pid: 42,
          uptimeMs: 5,
          host: "0.0.0.0",
          port: 8787,
          fingerprint: "fp",
          advertiseHost: "",
          pairedDevices: 0,
          runningSessions: 0,
          version: "0.1.0",
        },
      })) as ControlClient["request"],
      close() {},
    }),
  });
  writePidFile(h.deps.pidPath, 42);
  const daemon = createDaemon(h.deps);
  const code = await daemon.start({ host: "0.0.0.0", port: 8787, projects: [], noAuth: false, advertise: "" });
  assert.equal(code, 0);
  assert.equal(h.spawned.length, 0);
  assert.ok(h.out.join("\n").includes("already running"));
  cleanup(h);
});

test("status: not running returns exit code 3", async () => {
  const h = harness();
  const daemon = createDaemon(h.deps);
  const code = await daemon.status();
  assert.equal(code, 3);
  assert.ok(h.out.join("\n").toLowerCase().includes("not running"));
  cleanup(h);
});

test("status: running prints pid/port/fingerprint and returns 0", async () => {
  const h = harness({
    connect: async () => ({
      request: (async () => ({
        id: "1",
        ok: true,
        data: {
          pid: 42,
          uptimeMs: 5,
          host: "0.0.0.0",
          port: 8787,
          fingerprint: "deadbeef",
          advertiseHost: "",
          pairedDevices: 3,
          runningSessions: 1,
          version: "0.1.0",
        },
      })) as ControlClient["request"],
      close() {},
    }),
  });
  const daemon = createDaemon(h.deps);
  const code = await daemon.status();
  assert.equal(code, 0);
  const text = h.out.join("\n");
  assert.ok(text.includes("42"));
  assert.ok(text.includes("8787"));
  assert.ok(text.includes("deadbeef"));
  cleanup(h);
});

test("stop: running sends SIGTERM and removes the PID file", async () => {
  const h = harness({ connect: okStatus(9090) });
  writePidFile(h.deps.pidPath, 9090);
  const daemon = createDaemon(h.deps);
  const code = await daemon.stop();
  assert.equal(code, 0);
  assert.deepEqual(h.killed, [{ pid: 9090, signal: "SIGTERM" }]);
  assert.equal(existsSync(h.deps.pidPath), false);
  cleanup(h);
});

test("stop: not running reports nothing to do", async () => {
  const h = harness({ isAlive: () => false });
  const daemon = createDaemon(h.deps);
  const code = await daemon.stop();
  assert.equal(code, 0);
  assert.equal(h.killed.length, 0);
  assert.ok(h.out.join("\n").toLowerCase().includes("not running"));
  cleanup(h);
});

test("stop: stale pid (socket refuses) does not kill; clears the pid file", async () => {
  const h = harness({ isAlive: () => true }); // default connect throws → unconfirmed
  writePidFile(h.deps.pidPath, 9090);
  const daemon = createDaemon(h.deps);
  const code = await daemon.stop();
  assert.equal(code, 0);
  assert.equal(h.killed.length, 0, "must not SIGTERM an unconfirmed pid");
  assert.equal(existsSync(h.deps.pidPath), false);
  assert.ok(h.out.join("\n").toLowerCase().includes("stale"));
  cleanup(h);
});

test("stop: socket reports a different pid → does not kill", async () => {
  const h = harness({ connect: okStatus(1) });
  writePidFile(h.deps.pidPath, 9090);
  const daemon = createDaemon(h.deps);
  const code = await daemon.stop();
  assert.equal(code, 0);
  assert.equal(h.killed.length, 0);
  cleanup(h);
});

test("start: exits 1 and cleans the pid file when the server never answers", async () => {
  const h = harness({ isAlive: () => false, sleep: async () => {}, startupTimeoutMs: 100 });
  const daemon = createDaemon(h.deps);
  const code = await daemon.start({ host: "0.0.0.0", port: 8787, projects: [], noAuth: false, advertise: "" });
  assert.equal(code, 1);
  assert.equal(existsSync(h.deps.pidPath), false, "stale pid file removed on failed start");
  assert.ok(h.out.join("\n").toLowerCase().includes("failed to start"));
  cleanup(h);
});

test("restart: stops the running daemon then starts a fresh one", async () => {
  const h = harness({ connect: okStatus(5555), sleep: async () => {} });
  writePidFile(h.deps.pidPath, 5555);
  const daemon = createDaemon(h.deps);
  const code = await daemon.restart({ host: "0.0.0.0", port: 8787, projects: [], noAuth: false, advertise: "" });
  assert.equal(code, 0);
  assert.deepEqual(h.killed, [{ pid: 5555, signal: "SIGTERM" }]);
  assert.equal(h.spawned.length, 1);
  cleanup(h);
});

test("logs: prints the last N lines of the log file", async () => {
  const h = harness();
  writeFileSync(h.deps.logPath, "a\nb\nc\nd\ne\n");
  const daemon = createDaemon(h.deps);
  const code = await daemon.logs({ lines: 2, follow: false });
  assert.equal(code, 0);
  assert.deepEqual(h.out, ["d", "e"]);
  cleanup(h);
});
