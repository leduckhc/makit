import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionManager } from "./manager.js";
import { piSessionsDir } from "./pi-sessions.js";
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
  const agentDir = mkdtempSync(join(tmpdir(), "pino-mgr-"));
  const prev = process.env.PINO_PI_AGENT_DIR;
  process.env.PINO_PI_AGENT_DIR = agentDir;
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
      if (prev === undefined) delete process.env.PINO_PI_AGENT_DIR;
      else process.env.PINO_PI_AGENT_DIR = prev;
      rmSync(agentDir, { recursive: true, force: true });
    }
  })();
}

test("attachPiSession backfills history, resumes via path, and dedups", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-proj-"));
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

      // Attaching the same pi session again returns the SAME pino session.
      const again = await manager.attachPiSession(projectId, "sess1");
      assert.equal(again.id, session.id);
      assert.equal(started.length, 1);
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("attachPiSession rejects an unknown pi session id", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "pino-proj-"));
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
