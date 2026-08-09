/**
 * SPEC-46 — session.spawn lineage (T10, D9/D10), the depth/fan-out guard (T11)
 * and the bounded session.transcript command (T13, contract C3).
 *
 * The handler tests drive a fake manager (the queue.test.ts pattern): the
 * lineage a spawn actually records, and the refusals, are observable at the
 * `cmd`/`ack`/`err` seam without a live agent. The hostile-data walk (a forged
 * `parentId` cycle, a missing/archived ancestor) is unit-tested against the
 * pure functions in `lineage.ts` directly, so it exercises the real code rather
 * than a stub.
 */

import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { Principal } from "../principal.js";
import type { CommandDeps } from "./deps.js";
import { register as registerSession } from "./session.js";
import {
  spawnDepth,
  liveChildCount,
  spawnBoundError,
  MAX_SPAWN_DEPTH,
  MAX_LIVE_CHILDREN,
  type LineageNode,
} from "../../lineage.js";

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

// ---- T10: parentId comes from the credential, never the wire ---------------

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

// ---- T11: the spawn handler refuses past the bounds ------------------------

test("T11: a spawn refused by the bound guard errors and never reaches the manager", async () => {
  const h = harness({ principal: agent("S"), boundError: `spawn refused: maximum depth ${MAX_SPAWN_DEPTH}` });
  await h.cmd({ kind: "session.spawn", projectId: "p" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.match(String((err as { message?: string }).message), new RegExp(String(MAX_SPAWN_DEPTH)));
  assert.equal(h.spawnCalls.length, 0);
});

// ---- T11: the lineage walk over hostile persisted data ---------------------

function nodes(list: LineageNode[]): Map<string, LineageNode> {
  return new Map(list.map((n) => [n.id, n]));
}

test("T11 walk: depth counts one per ancestor link up to the root", () => {
  const m = nodes([
    { id: "a" },
    { id: "b", parentId: "a" },
    { id: "c", parentId: "b" },
  ]);
  assert.equal(spawnDepth("a", m), 1, "child of a root is depth 1");
  assert.equal(spawnDepth("c", m), 3);
});

test("T11 walk: a forged parentId CYCLE terminates the walk instead of looping", () => {
  const m = nodes([
    { id: "a", parentId: "c" },
    { id: "b", parentId: "a" },
    { id: "c", parentId: "b" },
  ]);
  // Every node is visited at most once, so the walk returns and does not hang.
  assert.equal(spawnDepth("a", m), 3);
});

test("T11 walk: a missing (killed) ancestor ends the walk without throwing", () => {
  const m = nodes([{ id: "b", parentId: "gone" }]);
  assert.equal(spawnDepth("b", m), 2, "b + the dangling link, then it stops");
});

test("T11 walk: an archived ancestor is walked through, not a crash", () => {
  const m = nodes([
    { id: "a", archived: true },
    { id: "b", parentId: "a" },
  ]);
  assert.equal(spawnDepth("b", m), 2);
});

test("T11 walk: liveChildCount excludes archived children", () => {
  const list: LineageNode[] = [
    { id: "x1", parentId: "P" },
    { id: "x2", parentId: "P", archived: true },
    { id: "x3", parentId: "P" },
    { id: "y", parentId: "Q" },
  ];
  assert.equal(liveChildCount("P", list), 2);
});

test("T11 walk: spawnBoundError names the depth limit past MAX_SPAWN_DEPTH", () => {
  // A chain root→1→2→3: the child of the deepest node would be depth 4.
  const chain: LineageNode[] = [{ id: "n0" }];
  for (let i = 1; i <= MAX_SPAWN_DEPTH; i++) chain.push({ id: `n${i}`, parentId: `n${i - 1}` });
  const m = nodes(chain);
  const err = spawnBoundError(`n${MAX_SPAWN_DEPTH}`, m);
  assert.ok(err && err.includes(String(MAX_SPAWN_DEPTH)));
  assert.equal(spawnBoundError(`n${MAX_SPAWN_DEPTH - 1}`, m), null, "one level shallower is allowed");
});

test("T11 walk: spawnBoundError names the fan-out limit at the (max+1)th live child", () => {
  const children: LineageNode[] = [];
  for (let i = 0; i < MAX_LIVE_CHILDREN; i++) children.push({ id: `c${i}`, parentId: "P" });
  const m = nodes([{ id: "P" }, ...children]);
  const err = spawnBoundError("P", m);
  assert.ok(err && err.includes(String(MAX_LIVE_CHILDREN)));
});

// ---- T13: session.transcript (contract C3) ---------------------------------

const evt = (seq: number) => ({ seq, sessionId: "s", kind: "agent.message", ts: seq, text: `e${seq}` });

test("T13: returns the LAST `limit` events, oldest-first, verbatim", async () => {
  const all = [evt(1), evt(2), evt(3), evt(4), evt(5)];
  const h = harness({ principal: phone, transcript: all });
  await h.cmd({ kind: "session.transcript", sessionId: "s", limit: 3 });
  const ack = h.sent.find((f) => f.t === "ack") as { events?: unknown[] } | undefined;
  assert.deepEqual(ack?.events, [evt(3), evt(4), evt(5)]);
});

test("T13: a session shorter than `limit` returns all of it", async () => {
  const all = [evt(1), evt(2)];
  const h = harness({ principal: phone, transcript: all });
  await h.cmd({ kind: "session.transcript", sessionId: "s", limit: 50 });
  const ack = h.sent.find((f) => f.t === "ack") as { events?: unknown[] } | undefined;
  assert.deepEqual(ack?.events, all);
});

test("T13: limit is clamped to 1..200", async () => {
  const all = Array.from({ length: 250 }, (_, i) => evt(i + 1));
  const low = harness({ principal: phone, transcript: all });
  await low.cmd({ kind: "session.transcript", sessionId: "s", limit: 0 });
  const lowAck = low.sent.find((f) => f.t === "ack") as { events?: unknown[] } | undefined;
  assert.equal(lowAck?.events?.length, 1, "0 clamps up to 1");

  const high = harness({ principal: phone, transcript: all });
  await high.cmd({ kind: "session.transcript", sessionId: "s", limit: 9999 });
  const highAck = high.sent.find((f) => f.t === "ack") as { events?: unknown[] } | undefined;
  assert.equal(highAck?.events?.length, 200, "9999 clamps down to 200");
});

test("T13: an unknown session errors", async () => {
  const h = harness({ principal: phone, session: undefined });
  await h.cmd({ kind: "session.transcript", sessionId: "ghost", limit: 5 });
  assert.ok(h.sent.some((f) => f.t === "err"));
});

test("T13: a read-scoped agent token may call session.transcript", async () => {
  const h = harness({ principal: { deviceId: "S", label: "a", caps: ["read"], sessionId: "S" }, transcript: [evt(1)] });
  await h.cmd({ kind: "session.transcript", sessionId: "S", limit: 5 });
  assert.ok(h.sent.some((f) => f.t === "ack"), "read grants transcript");
});
