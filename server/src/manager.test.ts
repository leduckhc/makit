import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import { piSessionsDir } from "./pi-sessions.js";
import { DEFAULT_SESSION_TITLE } from "./protocol.js";
import type { AgentAdapter, SpawnOpts } from "./adapters/adapter.js";

/** A stub adapter that records the SpawnOpts it was started with. */
function stubAdapter(started: SpawnOpts[]): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "stub";
  (e as any).start = async (opts: SpawnOpts) => {
    started.push(opts);
  };
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

function withAgentDir(cwd: string, run: (agentDir: string) => Promise<void>) {
  const agentDir = mkdtempSync(join(tmpdir(), "makit-mgr-"));
  const prev = process.env.MAKIT_PI_AGENT_DIR;
  process.env.MAKIT_PI_AGENT_DIR = agentDir;
  return (async () => {
    try {
      const dir = piSessionsDir(cwd, agentDir);
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        join(dir, "2026-01-01T00-00-00-000Z_sess1.jsonl"),
        [
          JSON.stringify({ type: "session", version: 3, id: "sess1", timestamp: "2026-01-01T00:00:00.000Z", cwd }),
          JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "old task" }] } }),
        ].join("\n") + "\n",
      );
      await run(agentDir);
    } finally {
      if (prev === undefined) delete process.env.MAKIT_PI_AGENT_DIR;
      else process.env.MAKIT_PI_AGENT_DIR = prev;
      rmSync(agentDir, { recursive: true, force: true });
    }
  })();
}

test("native pi fallback keeps agent=pi when no mux", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const agents: string[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: (ctx) => {
        agents.push(ctx.agent);
        return stubAdapter([]);
      },
    });
    const projectId = manager.listProjects()[0].id;
    await manager.spawnSession(projectId, "t", "pi"); // explicit native pi
    assert.deepEqual(agents, ["pi"]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnSession threads the chosen agent id into the adapter factory", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const agents: string[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: (ctx) => {
        agents.push(ctx.agent);
        return stubAdapter([]);
      },
    });
    const projectId = manager.listProjects()[0].id;

    await manager.spawnSession(projectId, "t", "codex");
    await manager.spawnSession(projectId, "t"); // default native pi

    assert.deepEqual(agents, ["codex", "pi"]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("listAgents exposes pi without pi-acp", () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const manager = new SessionManager({ projects: [cwd] });
    const ids = manager.listAgents().map((a) => a.id);
    assert.ok(ids.includes("pi"));
    assert.ok(!ids.includes("pi-acp"));
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("attachPiSession backfills history, resumes via path, and dedups", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const started: SpawnOpts[] = [];
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => stubAdapter(started),
      });
      const projectId = manager.listProjects()[0].id;

      const metas = manager.listPiSessions(projectId);
      assert.equal(metas.length, 1);
      assert.equal(metas[0].piSessionId, "sess1");
      assert.equal(metas[0].preview, "old task");

      const session = await manager.attachPiSession(projectId, "sess1");
      // History was backfilled before the adapter went live.
      assert.equal(session.events[0].kind, "user.message");
      assert.equal(session.events[0].payload.text, "old task");
      // Resumed by path, not a fresh session-id.
      assert.equal(started.length, 1);
      assert.ok(started[0].resumeSessionPath?.endsWith("sess1.jsonl"));

      // Attaching the same pi session again returns the SAME makit session.
      const again = await manager.attachPiSession(projectId, "sess1");
      assert.equal(again.id, session.id);
      assert.equal(started.length, 1);
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("addProject dedupes by resolved path and fires onProjectsChanged", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  const b = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const changes: string[][] = [];
    const manager = new SessionManager({
      projects: [a],
      onProjectsChanged: (paths) => changes.push(paths),
    });

    const first = manager.addProject(b);
    assert.equal(manager.listProjects().length, 2);
    assert.deepEqual(changes.at(-1), [a, b]);

    const again = manager.addProject(b + "/");
    assert.equal(again.id, first.id);
    assert.equal(manager.listProjects().length, 2);
    assert.equal(changes.length, 1);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("removeProject removes the entry and fires onProjectsChanged", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  const b = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const changes: string[][] = [];
    const manager = new SessionManager({
      projects: [a, b],
      onProjectsChanged: (paths) => changes.push(paths),
    });
    const target = manager.listProjects()[0];

    manager.removeProject(target.id);
    assert.equal(manager.listProjects().length, 1);
    assert.ok(!manager.listProjects().some((p) => p.id === target.id));
    assert.equal(changes.length, 1);
    assert.equal(changes[0].length, 1);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("removeProject throws on an unknown id", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const manager = new SessionManager({ projects: [a] });
    assert.throws(() => manager.removeProject("nope"));
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("attachPiSession rejects an unknown pi session id", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
      const projectId = manager.listProjects()[0].id;
      await assert.rejects(() => manager.attachPiSession(projectId, "does-not-exist"));
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("killSession kills the adapter, drops it from the registry, and errors on unknown id", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      let killed = 0;
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => {
          const a = stubAdapter([]);
          (a as any).kill = async () => {
            killed++;
          };
          return a;
        },
      });
      const projectId = manager.listProjects()[0].id;
      const session = await manager.spawnPiSession(projectId);
      assert.ok(manager.getSession(session.id));

      await manager.killSession(session.id);
      assert.equal(killed, 1);
      assert.equal(manager.getSession(session.id), undefined);
      assert.equal(manager.listSessions().length, 0);

      await assert.rejects(() => manager.killSession("nope"));
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSession without an explicit title uses the shared default", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => stubAdapter([]),
      });
      const projectId = manager.listProjects()[0].id;
      const session = await manager.spawnPiSession(projectId);
      assert.equal(session.title, DEFAULT_SESSION_TITLE);
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("rehydrates persisted sessions on boot as read-only history", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  // Seed a session + one event as if a prior server run had persisted them.
  store.saveSession({
    id: "sess-persist",
    projectId: "proj-x",
    agent: "pi",
    title: "resumed work",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old task",
  });
  store.append("sess-persist", { ts: 2, kind: "user.message", payload: { text: "old task" } });

  const mgr = new SessionManager({ projects: [], store });
  const dto = mgr.getSession("sess-persist")?.toDTO();
  assert.ok(dto, "session rehydrated");
  assert.equal(dto!.title, "resumed work");
  assert.equal(dto!.status, "exited");
  assert.equal(mgr.getSession("sess-persist")!.events.length, 1);

  // Sending to a cold session surfaces a re-attach error rather than crashing.
  const errs: string[] = [];
  mgr.getSession("sess-persist")!.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await mgr.getSession("sess-persist")!.sendUserMessage("hi again");
  assert.match(errs[0] ?? "", /re-attach/);
  store.close();
});

test("reattachSession resumes a cold pi session and continues the durable seq space", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      // --- first run: attach a prior pi transcript so a resume path persists.
      const mgr1 = new SessionManager({
        projects: [cwd],
        store,
        adapterFactory: () => stubAdapter([]),
      });
      const projectId = mgr1.listProjects()[0].id;
      const s = await mgr1.attachPiSession(projectId, "sess1");
      const sessionId = s.id;
      // A live turn after attach.
      s.adapter.emit("event", { ts: 10, kind: "user.message", payload: { text: "live turn" } });
      const maxSeq1 = store.read(sessionId).at(-1)!.seq;
      assert.ok(maxSeq1 >= 2);

      // --- restart: a fresh manager over the same store rehydrates it cold.
      const started: SpawnOpts[] = [];
      const mgr2 = new SessionManager({
        projects: [cwd],
        store,
        adapterFactory: () => stubAdapter(started),
      });
      const cold = mgr2.getSession(sessionId)!;
      assert.equal(cold.status, "exited");
      assert.equal(cold.events.length, maxSeq1); // full history intact

      // Re-attach: rebuild a live adapter and continue.
      const live = await mgr2.reattachSession(sessionId);
      assert.equal(live.id, sessionId);
      assert.equal(started.length, 1); // adapter really started
      assert.equal(started[0].resumeSessionPath !== undefined, true); // resumed via transcript

      // A new event must get the NEXT seq (no reset / collision).
      live.adapter.emit("event", { ts: 20, kind: "user.message", payload: { text: "after reattach" } });
      const seqs = store.read(sessionId).map((e) => e.seq);
      assert.deepEqual(seqs, [...Array(maxSeq1 + 1)].map((_, i) => i + 1));
      assert.equal(live.events.length, maxSeq1 + 1);
    });
  } finally {
    store.close();
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("reattachSession refuses a cold session with no resume path; it stays history-only", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  store.saveSession({
    id: "sess-noresume",
    projectId: "proj-x",
    agent: "pi",
    title: "no resume path",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old",
  });
  store.append("sess-noresume", { ts: 2, kind: "user.message", payload: { text: "old" } });

  const mgr = new SessionManager({ projects: [], store });
  await assert.rejects(() => mgr.reattachSession("sess-noresume"), /history only|resume/);
  await assert.rejects(() => mgr.reattachSession("does-not-exist"), /no such session/);

  // Still cold: sending surfaces the re-attach error rather than crashing.
  const errs: string[] = [];
  mgr.getSession("sess-noresume")!.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await mgr.getSession("sess-noresume")!.sendUserMessage("hi");
  assert.match(errs[0] ?? "", /re-attach/);
  store.close();
});
