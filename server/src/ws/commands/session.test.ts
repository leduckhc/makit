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
import { ForkPreconditionError } from "../../adapters/adapter.js";
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
  agent?: string;
  worktreePath?: string;
  branch?: string;
  lineage?: { parentId?: string; handoffReason?: string; origin?: string };
  policy?: string;
  resumeAgentSessionId?: string;
}

function harness(opts?: {
  principal?: Principal;
  boundError?: string | null;
  transcript?: unknown[];
  session?: unknown;
  /** Called by handlers that re-attach a cold session before acting on it. */
  ensureLive?: (id: string) => Promise<void>;
  /** A session resolved fresh on every lookup (so a re-attach can swap it). */
  sessionFor?: (id: string) => unknown;
}) {
  const spawnCalls: SpawnCall[] = [];
  const r = new CommandRouter();
  const deps = {
    manager: {
      spawnPendingSession: async (
        projectId: string,
        agent?: string,
        worktreePath?: string,
        branch?: string,
        _configOptions?: unknown,
        lineage?: SpawnCall["lineage"],
        policy?: string,
        resumeAgentSessionId?: string,
      ) => {
        spawnCalls.push({ projectId, agent, worktreePath, branch, lineage, policy, resumeAgentSessionId });
        return { id: "child-1" };
      },
      checkSpawnBounds: (_parentId: string) => opts?.boundError ?? null,
      getSession: (id: string) =>
        opts?.sessionFor ? opts.sessionFor(id) : opts && "session" in opts ? opts.session : { id: "s" },
      ensureLive: async (id: string) => {
        await opts?.ensureLive?.(id);
      },
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

/** An adapter that can fork, for the U4 tests. */
const forkableAdapter = () => ({
  capabilities: { fork: true },
  forkSession: async () => ({ agentSessionId: "th-forked" }),
});

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

// T10 originally asserted that a `client` principal's body `parentId` was
// *ignored*. That rule was superseded in P2 — see the "human credential may name
// the parent it handed off from" block below for why, and for its replacement.

test("T10: a full-access (phone/app) principal spawns a root with origin=app", async () => {
  const h = harness({ principal: phone });
  await h.cmd({ kind: "session.spawn", projectId: "p" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, undefined);
  assert.equal(h.spawnCalls[0]?.lineage?.origin, "app");
});

// ---- T20/D13: --yolo (a relaxed approval policy) is human-only --------------

test("T20/D13: policy=yolo from an agent-scoped credential is refused, not honoured", async () => {
  const h = harness({ principal: agent("S") });
  await h.cmd({ kind: "session.spawn", projectId: "p", policy: "yolo" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "an agent may not relax its own approval policy");
  assert.equal((err as { code?: string }).code, "bad_request");
  assert.equal(h.spawnCalls.length, 0, "the forged relaxation must not reach the manager");
});

test("T20/D13: a human CLI credential may set policy=yolo", async () => {
  const h = harness({ principal: cli });
  await h.cmd({ kind: "session.spawn", projectId: "p", policy: "yolo" });
  assert.ok(h.sent.some((f) => f.t === "ack"));
  assert.equal(h.spawnCalls[0]?.policy, "yolo");
});

test("T20/D13: an agent MAY set a stricter policy (ask-always) — only relaxation is gated", async () => {
  const h = harness({ principal: agent("S") });
  await h.cmd({ kind: "session.spawn", projectId: "p", policy: "ask-always" });
  assert.ok(h.sent.some((f) => f.t === "ack"));
  assert.equal(h.spawnCalls[0]?.policy, "ask-always");
});

test("T20/D13: an unknown policy value is dropped, not stored", async () => {
  const h = harness({ principal: cli });
  await h.cmd({ kind: "session.spawn", projectId: "p", policy: "bogus" });
  assert.ok(h.sent.some((f) => f.t === "ack"));
  assert.equal(h.spawnCalls[0]?.policy, undefined);
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

// ---- U-phase: a human credential may state the parent it handed off from ----

test("a human credential may name the parent it handed off from", async () => {
  // D9 refuses lineage *from the wire* to stop a confused or hostile **agent**
  // forging ancestry. A human credential is a different subject: by D17 it already
  // has full access to every session, so honouring the parent it states grants it
  // nothing new — while refusing it makes `makit handoff` from a terminal record a
  // `handoffReason` with no parent, which is exactly the mystery session D10 exists
  // to prevent (nothing to caption, nothing for `makit tree` to nest).
  const h = harness({ principal: cli });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "P", handoffReason: "out of context" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, "P");
  assert.equal(h.spawnCalls[0]?.lineage?.handoffReason, "out of context");
  assert.equal(h.spawnCalls[0]?.lineage?.origin, "cli");
});

test("a phone may state a parent too — the app captions handoffs it initiates", async () => {
  const h = harness({ principal: phone });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "P" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, "P");
  assert.equal(h.spawnCalls[0]?.lineage?.origin, "app");
});

test("a human spawn with no parentId is still a root", async () => {
  const h = harness({ principal: cli });
  await h.cmd({ kind: "session.spawn", projectId: "p" });
  assert.equal(h.spawnCalls[0]?.lineage?.parentId, undefined);
});

test("a human-stated parent that does not exist is refused, not persisted dangling", async () => {
  // Honouring a stated parent is not trusting any string: a dangling parentId
  // would persist lineage pointing at nothing, which the D13 ladder walks and
  // `tree` then has to special-case.
  const h = harness({ principal: cli, session: undefined });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "ghost" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.equal(h.spawnCalls.length, 0);
});

test("the depth/fan-out bound applies to a human-stated parent too", async () => {
  // Otherwise the CLI is a hole in the anti-runaway guard: an agent refused at
  // depth 3 could shell out to a human-credentialled handoff instead.
  const h = harness({ principal: cli, boundError: "spawn refused: at maximum depth of 3" });
  await h.cmd({ kind: "session.spawn", projectId: "p", parentId: "P" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.match(String((err as { message?: string }).message), /maximum depth/);
  assert.equal(h.spawnCalls.length, 0);
});

// ---------------------------------------------------------------------------
// SPEC-46 U4 — session.fork: an adapter-native head fork (codex thread/fork),
// deliberately NOT handoff (D6). The child adopts the forked thread through the
// resume path, records the source as its parent with NO handoffReason, and is
// held to the same depth/fan-out guard as any spawn.
// ---------------------------------------------------------------------------

/** A live, fork-capable source session (codex). */
function forkable(over: Record<string, unknown> = {}) {
  return {
    id: "src",
    projectId: "p",
    agent: "codex",
    pending: false,
    adapter: {
      capabilities: { fork: true },
      forkSession: async () => ({ agentSessionId: "th-forked" }),
    },
    ...over,
  };
}

test("U4: a head fork resumes the forked thread and records the source as parent, no handoffReason", async () => {
  const h = harness({ principal: cli, session: forkable() });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  assert.ok(h.sent.some((f) => f.t === "ack"), "the fork is acked");
  assert.equal(h.spawnCalls.length, 1);
  const call = h.spawnCalls[0]!;
  assert.equal(call.projectId, "p", "the child stays in the source's project");
  assert.equal(call.resumeAgentSessionId, "th-forked", "the child resumes the FORKED thread");
  assert.equal(call.lineage?.parentId, "src", "the source is the parent (D10)");
  assert.equal(call.lineage?.handoffReason, undefined, "a fork is not a handoff (D6)");
});

test("U4: the child inherits the worktree and branch the client resolved (D15 inverse)", async () => {
  const h = harness({ principal: cli, session: forkable() });
  await h.cmd({ kind: "session.fork", sessionId: "src", worktreePath: "/wt/src", branch: "feat/x" });
  const call = h.spawnCalls[0]!;
  assert.equal(call.worktreePath, "/wt/src");
  assert.equal(call.branch, "feat/x");
});

test("U4: pi is refused with D6's precise sentence naming handoff, never a bare boolean", async () => {
  const pi = forkable({ agent: "pi", adapter: { capabilities: { fork: false } } });
  const h = harness({ principal: cli, session: pi });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.equal(
    String((err as { message?: string }).message),
    "pi cannot fork: pi-acp advertises no `session/fork` — use `makit handoff` instead",
  );
  assert.equal(h.spawnCalls.length, 0, "no child is created when fork is unsupported");
});

test("U4: a harness that is not run under pi-acp is refused without inventing a component", async () => {
  // D6's sentence names `pi-acp` because pi genuinely runs under it. Deriving
  // "<agent>-acp" for every harness makes makit cite a binary that does not
  // exist ("stub-acp", "codex-acp") — a refusal a user cannot act on and cannot
  // search for.
  const h = harness({
    principal: cli,
    session: { id: "src", agent: "stub", pending: false, adapter: { capabilities: { fork: false } } },
  });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  const err = h.sent.find((f) => f.t === "err");
  const message = String((err as { message?: string }).message);
  assert.doesNotMatch(message, /stub-acp/, "no fabricated component name");
  assert.match(message, /stub cannot fork/);
  assert.match(message, /makit handoff/, "and it still names the way forward");
});

test("U4: a session that has not completed a turn is refused in plain words (rollout precondition)", async () => {
  const noTurn = forkable({
    adapter: {
      capabilities: { fork: true },
      forkSession: async () => {
        throw new ForkPreconditionError("no rollout found for thread id th1");
      },
    },
  });
  const h = harness({ principal: cli, session: noTurn });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  const msg = String((err as { message?: string }).message);
  assert.match(msg, /has not run a turn yet/);
  assert.doesNotMatch(msg, /-32600|rollout/, "never relays the JSON-RPC string");
  assert.equal(h.spawnCalls.length, 0);
});

test("U4: a draft source (never promoted) is refused in the same plain words", async () => {
  const draft = forkable({ pending: true, adapter: { capabilities: { fork: false } } });
  const h = harness({ principal: cli, session: draft });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.match(String((err as { message?: string }).message), /has not run a turn yet/);
  assert.equal(h.spawnCalls.length, 0);
});

test("U4: the depth/fan-out bound refuses a fork, and never forks the thread first", async () => {
  let forked = false;
  const source = forkable({
    adapter: {
      capabilities: { fork: true },
      forkSession: async () => {
        forked = true;
        return { agentSessionId: "th-forked" };
      },
    },
  });
  const h = harness({ principal: cli, session: source, boundError: "spawn refused: at maximum depth of 3" });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.match(String((err as { message?: string }).message), /maximum depth/);
  assert.equal(forked, false, "the bound is checked BEFORE forking, so no orphan thread is left");
  assert.equal(h.spawnCalls.length, 0);
});

test("U4: forking a session that does not exist is refused", async () => {
  const h = harness({ principal: cli, session: undefined });
  await h.cmd({ kind: "session.fork", sessionId: "ghost" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.equal(h.spawnCalls.length, 0);
});

test("D17: session.transcript refuses a session the agent may not read", async () => {
  // The `read` cap grants this command, which is correct — but the *subject* still
  // has to own the session. Without this check a `read`-capped agent token could
  // pull any session's last 200 events, which is the same leak `sub` had.
  const h = harness({ principal: agent("mine"), transcript: [{ seq: 1, kind: "agent.message" }] });
  await h.cmd({ kind: "session.transcript", sessionId: "someone-elses", limit: 5 });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.equal(h.sent.some((f) => f.t === "ack"), false, "and must not return events");
});

test("D17: session.transcript serves the agent's OWN session", async () => {
  const h = harness({ principal: agent("mine"), transcript: [{ seq: 1, kind: "agent.message" }] });
  await h.cmd({ kind: "session.transcript", sessionId: "mine", limit: 5 });
  const ack = h.sent.find((f) => f.t === "ack") as { events?: unknown[] } | undefined;
  assert.ok(ack, "own session is readable");
  assert.equal(ack!.events?.length, 1);
});

test("D17: a human credential reads any transcript, as before", async () => {
  const h = harness({ principal: cli, transcript: [{ seq: 1, kind: "agent.message" }] });
  await h.cmd({ kind: "session.transcript", sessionId: "anyones", limit: 5 });
  assert.ok(h.sent.some((f) => f.t === "ack"));
});

test("U4: the fork's child runs on the SOURCE's harness, not the default one", async () => {
  // A native fork is a continuation of *that back end's* thread. The handler passed
  // the optional `--agent` through and, when absent, let the manager fall back to
  // the project default — so forking a codex session produced a **pi** child, which
  // was then handed a codex thread id and died on `session/load: Invalid params`.
  // The child was created successfully and could never start: a fork that looks
  // like it worked and is permanently broken.
  const h = harness({
    principal: cli,
    session: { id: "src", agent: "codex", pending: false, adapter: forkableAdapter() },
  });
  await h.cmd({ kind: "session.fork", sessionId: "src" });
  assert.equal(h.spawnCalls[0]?.agent, "codex", "inherits the source's harness");
});

test("U4: --agent naming a DIFFERENT harness is refused, and points at handoff", async () => {
  // Moving harness is what `handoff` is for (D6). A codex thread cannot be resumed
  // by pi, so honouring `--agent pi` here would mint another dead session.
  const h = harness({
    principal: cli,
    session: { id: "src", agent: "codex", pending: false, adapter: forkableAdapter() },
  });
  await h.cmd({ kind: "session.fork", sessionId: "src", agent: "pi" });
  const err = h.sent.find((f) => f.t === "err");
  assert.ok(err, "must refuse");
  assert.match(String((err as { message?: string }).message), /handoff/);
  assert.equal(h.spawnCalls.length, 0, "and nothing is created");
});

test("U4: --agent naming the SAME harness is accepted (a harmless no-op)", async () => {
  const h = harness({
    principal: cli,
    session: { id: "src", agent: "codex", pending: false, adapter: forkableAdapter() },
  });
  await h.cmd({ kind: "session.fork", sessionId: "src", agent: "codex" });
  assert.equal(h.spawnCalls[0]?.agent, "codex");
});

test("U4: a COLD session is re-attached before its fork capability is judged", async () => {
  // After a server restart a session is rehydrated with a process-less placeholder
  // adapter whose capabilities are all false. Reading `fork` off that reported
  // "codex cannot fork: its back end advertises no native fork" — about codex,
  // which plainly can. `send.message` already re-attaches first (ensureLive); fork
  // must too, or the verb is broken for exactly the sessions worth forking: the
  // ones you left running yesterday.
  let live = false;
  const cold = { capabilities: { fork: false } }; // the placeholder
  const warm = { capabilities: { fork: true }, forkSession: async () => ({ agentSessionId: "th-forked" }) };
  const h = harness({
    principal: cli,
    ensureLive: async () => {
      live = true;
    },
    // getSession is consulted again after ensureLive, so it must reflect the swap.
    sessionFor: () => ({ id: "src", agent: "codex", pending: false, adapter: live ? warm : cold }),
  });

  await h.cmd({ kind: "session.fork", sessionId: "src" });

  assert.equal(live, true, "it re-attached");
  assert.equal(h.spawnCalls.length, 1, "and then forked");
});
