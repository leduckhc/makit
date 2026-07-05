/**
 * SPEC-05: spawnPiSessionInPane — pane spawn, token correlation, fallback,
 * and closePane lifecycle (session.kill, host.close, pi-exit).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import type { SpawnOpts } from "./adapters/adapter.js";
import type { MultiplexerAdapter, PaneHandle, SpawnPaneOpts } from "./mux/adapter.js";

// ---- helpers ---------------------------------------------------------------

function stubAdapter(started: SpawnOpts[]) {
  const e = new EventEmitter() as any;
  e.start = async (o: SpawnOpts) => started.push(o);
  e.send = async () => {};
  e.cancel = async () => {};
  e.kill = async () => {};
  return e;
}

interface FakeMuxOpts {
  available?: boolean;
  /** If set, spawnPane rejects with this message. */
  spawnError?: string;
}

interface FakeMux extends MultiplexerAdapter {
  spawned: SpawnPaneOpts[];
  closed: string[];
  renamed: { paneId: string; label: string }[];
  _handles: PaneHandle[];
}

function fakeMux(opts: FakeMuxOpts = {}): FakeMux {
  const spawned: SpawnPaneOpts[] = [];
  const closed: string[] = [];
  const renamed: { paneId: string; label: string }[] = [];
  const handles: PaneHandle[] = [];
  let paneCount = 0;

  return {
    name: "herdr",
    spawned,
    closed,
    renamed,
    _handles: handles,

    async isAvailable() {
      return opts.available !== false;
    },

    async spawnPane(o) {
      if (opts.spawnError) throw new Error(opts.spawnError);
      spawned.push(o);
      const handle: PaneHandle = { mux: "herdr", paneId: `w1:p${++paneCount}` };
      handles.push(handle);
      return handle;
    },

    async setLabel(handle, label) {
      renamed.push({ paneId: handle.paneId, label });
    },

    async closePane(handle) {
      closed.push(handle.paneId);
    },

    async paneExists(_handle) {
      return true;
    },
  };
}

/** Build a minimal SessionManager wired for pane tests. */
function makeManager(projects: string[], mux?: FakeMux) {
  const started: SpawnOpts[] = [];
  const manager = new SessionManager({
    projects,
    adapterFactory: () => stubAdapter(started),
    mux,
  });
  return { manager, started };
}

// ---- tests -----------------------------------------------------------------

test("spawnPiSessionInPane: opens pane with correct cwd, label, and PINO_SPAWN_TOKEN in command", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux();
    const { manager } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    // The spawn will wait for host.open — we drive it from a parallel task.
    const spawnPromise = manager.spawnPiSessionInPane(projectId, "test session");

    // Verify pane was opened with the right options before host.open arrives.
    // Give the async spawn a tick to run.
    await new Promise((r) => setImmediate(r));

    assert.equal(mux.spawned.length, 1, "one pane should be spawned");
    const paneOpts = mux.spawned[0];
    assert.equal(paneOpts.cwd, cwd);
    assert.match(paneOpts.label ?? "", /^pino: test session$/);
    assert.match(paneOpts.command, /PINO_SPAWN_TOKEN=[0-9a-f-]+/);
    assert.ok(!paneOpts.focus, "pane should be unfocused by default");

    // Simulate host.open arriving with the token extracted from the command.
    const tokenMatch = paneOpts.command.match(/PINO_SPAWN_TOKEN=([0-9a-f-]+)/);
    assert.ok(tokenMatch, "command must contain PINO_SPAWN_TOKEN");
    const spawnToken = tokenMatch![1];

    // Simulate pino-mirror sending host.open — resolve the pending spawn.
    const session = await manager.simulateHostOpen(spawnToken, "test session", cwd, projectId);
    assert.ok(session, "session should be created via openHostSession");

    // Now spawnPiSessionInPane should resolve with the session.
    const result = await spawnPromise;
    assert.equal(result.id, session.id);

    // PaneHandle should be attached to the session.
    assert.deepEqual(result.pane, mux._handles[0]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: pane close called on session.kill", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux();
    const { manager } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    const spawnPromise = manager.spawnPiSessionInPane(projectId, "kill-test");
    await new Promise((r) => setImmediate(r));

    const paneOpts = mux.spawned[0];
    const spawnToken = paneOpts.command.match(/PINO_SPAWN_TOKEN=([0-9a-f-]+)/)![1];
    const session = await manager.simulateHostOpen(spawnToken, "kill-test", cwd, projectId);
    await spawnPromise;

    await manager.killSession(session.id);
    assert.equal(mux.closed.length, 1, "closePane must be called on kill");
    assert.equal(mux.closed[0], mux._handles[0].paneId);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: pane close called on host.close (pi exit)", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux();
    const { manager } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    const spawnPromise = manager.spawnPiSessionInPane(projectId, "close-test");
    await new Promise((r) => setImmediate(r));

    const paneOpts = mux.spawned[0];
    const spawnToken = paneOpts.command.match(/PINO_SPAWN_TOKEN=([0-9a-f-]+)/)![1];
    const session = await manager.simulateHostOpen(spawnToken, "close-test", cwd, projectId);
    await spawnPromise;

    // host.close path: kill the session as server.ts does on host.close.
    await manager.killSession(session.id).catch(() => {});
    assert.equal(mux.closed.length, 1, "closePane must be called on host.close");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: fallback to headless when mux is unavailable", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux({ available: false });
    const { manager, started } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    const session = await manager.spawnPiSessionInPane(projectId, "headless");
    assert.equal(mux.spawned.length, 0, "no pane should be spawned");
    assert.equal(started.length, 1, "headless adapter should start");
    assert.equal(session.pane, undefined, "session should have no pane handle");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: fallback to headless when mux is not configured (undefined)", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const { manager, started } = makeManager([cwd], undefined);
    const projectId = manager.listProjects()[0].id;

    const session = await manager.spawnPiSessionInPane(projectId, "no-mux");
    assert.equal(started.length, 1, "headless adapter should start");
    assert.equal(session.pane, undefined, "session should have no pane handle");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: fallback to headless when pane spawn fails", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux({ spawnError: "pane_not_found" });
    const { manager, started } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    const session = await manager.spawnPiSessionInPane(projectId, "spawn-fail");
    assert.equal(started.length, 1, "headless adapter should start on spawn failure");
    assert.equal(session.pane, undefined);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSessionInPane: timeout closes the pane and rejects", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux();
    const { manager } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    // Use a very short timeout for the test.
    const spawnPromise = manager.spawnPiSessionInPane(projectId, "timeout-test", {
      timeoutMs: 20,
    });
    await new Promise((r) => setImmediate(r));
    assert.equal(mux.spawned.length, 1, "pane should have been created");

    await assert.rejects(spawnPromise, /spawn timeout/i);
    assert.equal(mux.closed.length, 1, "orphan pane should be closed on timeout");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("updatePaneLabel: relabels the pane when session has a handle", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-pane-"));
  try {
    const mux = fakeMux();
    const { manager } = makeManager([cwd], mux);
    const projectId = manager.listProjects()[0].id;

    const spawnPromise = manager.spawnPiSessionInPane(projectId, "orig-title");
    await new Promise((r) => setImmediate(r));

    const paneOpts = mux.spawned[0];
    const spawnToken = paneOpts.command.match(/PINO_SPAWN_TOKEN=([0-9a-f-]+)/)![1];
    const session = await manager.simulateHostOpen(spawnToken, "orig-title", cwd, projectId);
    await spawnPromise;

    await manager.updatePaneLabel(session.id, "new-title");
    assert.ok(
      mux.renamed.some((r) => r.label === "pino: new-title"),
      "setLabel should be called with updated title",
    );
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});
