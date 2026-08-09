/**
 * SPEC-46 T10 — session.spawn lineage (D9/D10): `parentId` and `origin` are
 * derived from the credential, never taken from the wire.
 *
 * Drives a fake manager (the queue.test.ts pattern) so the lineage a spawn
 * actually records, and the forgery refusal, are observable at the
 * `cmd`/`ack`/`err` seam without a live agent.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { Principal } from "../principal.js";
import type { CommandDeps } from "./deps.js";
import { register as registerSession } from "./session.js";

interface SpawnCall {
  projectId: string;
  lineage?: { parentId?: string; handoffReason?: string; origin?: string };
}

function harness(opts?: {
  principal?: Principal;
  boundError?: string | null;
  transcript?: unknown[];
  session?: unknown;
}) {
  const spawnCalls: SpawnCall[] = [];
  const r = new CommandRouter();
  const deps = {
    manager: {
      spawnPendingSession: async (
        projectId: string,
        _agent?: string,
        _worktreePath?: string,
        _branch?: string,
        _configOptions?: unknown,
        lineage?: SpawnCall["lineage"],
      ) => {
        spawnCalls.push({ projectId, lineage });
        return { id: "child-1" };
      },
      checkSpawnBounds: (_parentId: string) => opts?.boundError ?? null,
      getSession: (_id: string) => (opts && "session" in opts ? opts.session : { id: "s" }),
      readTranscript: (_id: string) => opts?.transcript ?? [],
    },
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
    askDevice: async () => ({}) as never,
    gateway: {} as never,
  } as unknown as CommandDeps;
  registerSession(r, deps);

  const sent: OutgoingFrame[] = [];
  const client: WsClient = {
    send: (f: OutgoingFrame) => sent.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    principal: opts?.principal,
  } as unknown as WsClient;

  const cmd = (env: Record<string, unknown>) =>
    r.dispatch(client, { v: 1, t: "cmd", id: "1", ...env } as never);

  return { cmd, sent, spawnCalls };
}

const agent = (sessionId: string): Principal => ({
  deviceId: sessionId,
  label: `agent:${sessionId}`,
  caps: ["read", "send", "spawn"],
  sessionId,
});
const cli: Principal = { deviceId: "d", label: "cli@host", caps: ["client"] };
const phone: Principal = { deviceId: "d", label: "phone" }; // no caps = full access

test("T10: an agent-scoped spawn records the token's session as parent, origin=agent", async () => {
  const h = harness({ principal: agent("S") });
  await h.cmd({ kind: "session.spawn", projectId: "p" });
  assert.equal(h.spawnCalls.length, 1);
  assert.equal(h.spawnCalls[0].lineage?.parentId, "S");
  assert.equal(h.spawnCalls[0].lineage?.origin, "agent");
  assert.ok(h.sent.some((f) => f.t === "ack"));
});

test("T10: a body parentId naming a DIFFERENT session is refused BadRequest, not honoured", async () => {
  const h = harness({ principal: agent("S") });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "OTHER" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.equal((err as { code?: string }).code, "bad_request");
  assert.equal(h.spawnCalls.length, 0, "the forged spawn must not reach the manager");
});

test("T10: a body parentId equal to the credential's session is accepted", async () => {
  const h = harness({ principal: agent("S") });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "S" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, "S");
  assert.ok(h.sent.some((f) => f.t === "ack"));
});

test("T10: a CLI (client) principal spawns a root with origin=cli", async () => {
  const h = harness({ principal: cli });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "ignored" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, undefined, "no parent from the wire");
  assert.equal(h.spawnCalls[0]?.lineage?.origin, "cli");
});

test("T10: a full-access (phone/app) principal spawns a root with origin=app", async () => {
  const h = harness({ principal: phone });
  await h.cmd({ kind: "session.spawn", projectId: "p" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, undefined);
  assert.equal(h.spawnCalls[0]?.lineage?.origin, "app");
});
