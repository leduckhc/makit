import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { Session, type SessionLifecycle } from "./session.js";
import type { AgentAdapter, AdapterEvent } from "./adapters/adapter.js";
import type { SessionEvent } from "./protocol.js";

function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "pi";
  (e as any).start = async () => {};
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

test("backfill seeds the event log without emitting, then live events continue the seq", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  const emitted: number[] = [];
  session.on("event", (ev) => emitted.push(ev.seq));

  const history: AdapterEvent[] = [
    { ts: 1, kind: "user.message", payload: { text: "hi" } },
    { ts: 2, kind: "agent.message", payload: { text: "hello back" } },
  ];
  session.backfill(history);

  // Backfill populates events but does NOT emit (replayed on sub instead).
  assert.equal(emitted.length, 0);
  assert.equal(session.events.length, 2);
  assert.deepEqual(session.events.map((e) => e.seq), [1, 2]);
  assert.equal(session.events[0].sessionId, session.id);
  assert.equal(session.lastPreview, "hello back");

  // A subsequent live event continues the seq space (3, not 1).
  session.adapter.emit("event", { ts: 3, kind: "user.message", payload: { text: "next" } });
  assert.deepEqual(emitted, [3]);
  assert.equal(session.events.length, 3);
});

test("setTitle updates the title, emits titleChanged, and dedups empty/unchanged", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  const changes: string[] = [];
  session.on("titleChanged", (t) => changes.push(t));

  // First real title → changes.
  assert.equal(session.setTitle("Fix the parser"), true);
  assert.equal(session.title, "Fix the parser");

  // Trims surrounding whitespace.
  assert.equal(session.setTitle("  Fix the parser  "), false); // same after trim
  assert.equal(session.setTitle("Rename me"), true);

  // Empty / whitespace-only is ignored.
  assert.equal(session.setTitle("   "), false);
  assert.equal(session.setTitle(""), false);
  assert.equal(session.title, "Rename me");

  assert.deepEqual(changes, ["Fix the parser", "Rename me"]);
});

test("adapter 'title' events retitle the session", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  const changes: string[] = [];
  session.on("titleChanged", (t) => changes.push(t));

  session.adapter.emit("title", "auto-named from pi");
  assert.equal(session.title, "auto-named from pi");
  assert.deepEqual(changes, ["auto-named from pi"]);
});

test("metaChanged fires on preview/status/title changes but NOT on streaming deltas (P2)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  let meta = 0;
  session.on("metaChanged", () => meta++);

  // A stream of N per-token deltas must NOT trigger the sessions-snapshot
  // fan-out (that is the O(clients × sessions) hot-path cliff P2 removes).
  for (let i = 0; i < 20; i++) {
    session.adapter.emit("event", { ts: i, kind: "agent.message.delta", payload: { text: "x" } });
  }
  session.adapter.emit("event", { ts: 21, kind: "agent.thinking.delta", payload: { text: "t" } });
  session.adapter.emit("event", { ts: 22, kind: "tool.call.delta", payload: {} });
  assert.equal(meta, 0, "streaming deltas must not change session-list meta");

  // A finalized agent.message changes the preview → one meta change.
  session.adapter.emit("event", { ts: 23, kind: "agent.message", payload: { text: "done" } });
  assert.equal(meta, 1);

  // A status transition changes the DTO → one meta change.
  session.adapter.emit("status", "running");
  assert.equal(meta, 2);

  // A title change is DTO-visible → one meta change.
  session.setTitle("Renamed");
  assert.equal(meta, 3);

  // An unchanged title does NOT emit.
  session.setTitle("Renamed");
  assert.equal(meta, 3);
});

test("metaChanged fires for non-streaming error/tool events (lastActivityAt advances)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  let meta = 0;
  session.on("metaChanged", () => meta++);

  // A tool-call start is a non-streaming event: it advances lastActivityAt, a
  // DTO-visible field, so the sessions list must refresh once.
  session.adapter.emit("event", { ts: 1000, kind: "tool.call.start", payload: { callId: "c1", name: "bash" } });
  assert.equal(meta, 1, "a tool.call.start refreshes the session list");

  // A session.error likewise advances lastActivityAt → one refresh.
  session.adapter.emit("event", { ts: 1001, kind: "session.error", payload: { message: "boom" } });
  assert.equal(meta, 2, "a session.error refreshes the session list");

  // But a tool.call.delta is a streaming delta → NO refresh.
  session.adapter.emit("event", { ts: 1002, kind: "tool.call.delta", payload: { callId: "c1", chunk: "x" } });
  assert.equal(meta, 2, "streaming tool delta must not refresh the session list");
});

test("lifecycle models draft → started as a discriminated union (P4)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  // A freshly-constructed session is live (started), not a draft.
  const initial: SessionLifecycle = session.lifecycle;
  assert.equal(initial.phase, "started");
  assert.equal(session.pending, false);

  // Entering the draft phase records the deferred agent + bound worktree.
  session.beginDraft({ agent: "codex", pendingWorktreePath: "/tmp/wt" });
  assert.equal(session.pending, true);
  assert.equal(session.pendingAgent, "codex");
  const draft: SessionLifecycle = session.lifecycle;
  if (draft.phase !== "draft") {
    assert.fail("expected a draft lifecycle");
  } else {
    assert.equal(draft.agent, "codex");
    assert.equal(draft.pendingWorktreePath, "/tmp/wt");
  }

  // setPendingAgent only mutates a draft.
  session.setPendingAgent("pi");
  assert.equal(session.pendingAgent, "pi");

  // markStarted is the transition: pending clears, branch/worktree are set.
  session.markStarted({ branch: "feature-x", worktreePath: "/tmp/wt" });
  assert.equal(session.pending, false);
  assert.equal(session.pendingAgent, undefined);
  assert.equal(session.branch, "feature-x");
  assert.equal(session.worktreePath, "/tmp/wt");
  const afterStart: SessionLifecycle = session.lifecycle;
  assert.equal(afterStart.phase, "started");

  // setPendingAgent is a no-op once started.
  session.setPendingAgent("codex");
  assert.equal(session.pendingAgent, undefined);
});

test("a draft's bound branch is not persisted, so rehydration keeps it unstarted-looking", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store });
  session.beginDraft({ agent: "pi", pendingWorktreePath: "/tmp/wt", branch: "feature-b" });
  // Any recorded event upserts meta — this must NOT persist the draft's branch,
  // or a restart would rehydrate the draft as a started session on that branch.
  session.adapter.emit("event", { ts: 1, kind: "user.message", payload: { text: "hi" } });

  const meta = store.loadSessions()[0];
  assert.equal(meta.branch, undefined);
  assert.equal(meta.worktreePath, undefined);
  store.close();
});

test("pendingWorktreePath is unreadable on a started lifecycle (P4 type-level guard)", () => {
  const lc: SessionLifecycle = { phase: "started", branch: "b", worktreePath: "/tmp/wt" };
  if (lc.phase === "started") {
    // @ts-expect-error pendingWorktreePath exists only on the draft variant —
    // reading it on a started session is a compile error (the P4 invariant).
    void lc.pendingWorktreePath;
  }
  const draft: SessionLifecycle = { phase: "draft", agent: "pi", pendingWorktreePath: "/tmp/pending" };
  if (draft.phase === "draft") {
    assert.equal(draft.pendingWorktreePath, "/tmp/pending");
  }
});

test("with a store, events persist durably and seq survives a session restart", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();

  const s1 = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store });
  s1.adapter.emit("event", { ts: 1, kind: "user.message", payload: { text: "hi" } });
  s1.adapter.emit("event", { ts: 2, kind: "agent.message", payload: { text: "hello" } });

  // Store holds both events under the session's id.
  assert.deepEqual(store.read(s1.id).map((e) => e.payload.text), ["hi", "hello"]);
  // Session metadata is persisted (title/status/preview).
  assert.equal(store.loadSessions()[0].lastPreview, "hello");

  // "Restart": rebuild the session from the store, hydrate cache, continue seqs.
  const s2 = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store, id: s1.id });
  s2.hydrate(store.read(s1.id));
  assert.equal(s2.events.length, 2);
  s2.adapter.emit("event", { ts: 3, kind: "user.message", payload: { text: "again" } });
  assert.deepEqual(store.read(s1.id).map((e) => e.seq), [1, 2, 3]);
  store.close();
});

test("lazy hydrateFrom is retained when the loader throws, and retried on next access", () => {
  const history: SessionEvent[] = [
    { seq: 1, sessionId: "s-lazy-retry", ts: 1, kind: "user.message", payload: { text: "old" } },
  ];
  let calls = 0;
  const session = new Session({
    id: "s-lazy-retry",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    hydrateFrom: () => {
      calls += 1;
      if (calls === 1) throw new Error("transient read failure");
      return history;
    },
  });

  // First access: loader throws → surfaced, and the loader is NOT consumed.
  assert.throws(() => session.events, /transient read failure/);
  // Retry: loader runs again and history is restored (not permanently lost).
  assert.equal(session.events.length, 1);
  assert.equal(session.events[0].payload.text, "old");
  assert.equal(calls, 2, "loader retried exactly once after the failure");
});

// ---- SPEC-35: mid-turn messages (steer vs queue) --------------------------

/**
 * A fake adapter with the SPEC-35 surface: records what it was sent, and lets a
 * test decide whether steering is available (codex) or not (ACP/stub).
 */
function turnAdapter(opts: { steer?: boolean } = {}) {
  const a = fakeAdapter();
  const sent: string[] = [];
  const steered: string[] = [];
  const state = { steerable: opts.steer === true };
  (a as any).send = async (input: { text: string }) => {
    sent.push(input.text);
    a.emit("status", "running");
    a.emit("event", { ts: Date.now(), kind: "user.message", payload: { text: input.text } });
  };
  (a as any).steer = async (input: { text: string }) => {
    if (!state.steerable) return false;
    steered.push(input.text);
    a.emit("event", { ts: Date.now(), kind: "user.message", payload: { text: input.text } });
    return true;
  };
  return { adapter: a, sent, steered, state, idle: () => a.emit("status", "idle") };
}

const settle = () => new Promise((r) => setTimeout(r, 5));

test("SPEC-35: a mid-turn message is steered when the adapter can steer", async () => {
  const f = turnAdapter({ steer: true });
  const session = new Session({ projectId: "p", agent: "codex", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("mid-turn");

  assert.deepEqual(f.sent, ["first"], "no second turn was started");
  assert.deepEqual(f.steered, ["mid-turn"]);
  assert.equal(session.queuedMessages.length, 0, "a steered message is never queued");
});

test("SPEC-35: a mid-turn message is queued when the adapter cannot steer", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });
  const metas: number[] = [];
  session.on("metaChanged", () => metas.push(session.queuedMessages.length));

  await session.sendUserMessage("first");
  await session.sendUserMessage("later");

  assert.deepEqual(f.sent, ["first"]);
  assert.equal(session.queuedMessages.length, 1);
  assert.equal(session.queuedMessages[0].text, "later");
  assert.ok(metas.includes(1), "the queue change is broadcast");
  assert.equal(
    session.events.filter((e) => e.kind === "user.message").length,
    1,
    "a queued message is not in the transcript until it is delivered",
  );
});

test("SPEC-35: the queue flushes one message per idle, FIFO", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("a");
  await session.sendUserMessage("b");
  await session.sendUserMessage("c");
  assert.equal(session.queuedMessages.length, 3);

  f.idle();
  await settle();
  assert.deepEqual(f.sent, ["first", "a"]);
  assert.equal(session.queuedMessages.length, 2);

  f.idle();
  await settle();
  f.idle();
  await settle();
  assert.deepEqual(f.sent, ["first", "a", "b", "c"]);
  assert.equal(session.queuedMessages.length, 0);
});

test("SPEC-35: a non-empty queue takes priority even if the adapter looks idle", async () => {
  // Steering is unavailable for the first mid-turn message (e.g. codex refused
  // a review turn), so it queues; then it becomes available again.
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "codex", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("queued");
  f.state.steerable = true;
  // The turn ends, but the flush has not run yet: a new message must neither
  // overtake the one already waiting nor be steered past it.
  session.status = "idle";
  await session.sendUserMessage("newer");

  assert.deepEqual(
    session.queuedMessages.map((q) => q.text),
    ["queued", "newer"],
  );
  assert.deepEqual(f.steered, [], "no steering while a queue exists");
});

test("SPEC-35: cancelQueued removes one message; clearQueue empties it", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("a");
  await session.sendUserMessage("b");
  const [a, b] = session.queuedMessages;

  assert.equal(session.cancelQueued(a.id), true);
  assert.deepEqual(session.queuedMessages.map((q) => q.text), ["b"]);
  assert.equal(session.cancelQueued("nope"), false, "unknown id is a no-op");

  assert.equal(session.clearQueue(), true);
  assert.equal(session.queuedMessages.length, 0);
  assert.equal(session.clearQueue(), false, "already empty");
  assert.ok(b);

  f.idle();
  await settle();
  assert.deepEqual(f.sent, ["first"], "cancelled messages are never delivered");
});

test("SPEC-35: an adapter exit drops pending messages", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("never sent");
  f.adapter.emit("exit", 0);

  assert.equal(session.queuedMessages.length, 0);
});

test("SPEC-35: queued messages are exposed on the DTO", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("waiting", [
    { mediaId: "a".repeat(64), mime: "image/png", sizeBytes: 1 },
  ]);

  assert.deepEqual(
    session.toDTO().queued.map((q) => ({ text: q.text, attachmentCount: q.attachmentCount })),
    [{ text: "waiting", attachmentCount: 1 }],
  );
});

test("SPEC-35: two idle transitions in a row deliver only one queued message", async () => {
  // TurnStatusTracker settles to idle on more than one path (turn completed, a
  // failed turn/start, an approval leaving with no turn left), so a duplicate
  // `idle` must not fire two turns at once.
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("a");
  await session.sendUserMessage("b");

  f.idle();
  f.idle();
  await settle();

  assert.deepEqual(f.sent, ["first", "a"]);
  assert.equal(session.queuedMessages.length, 1);
});

// ---- SPEC-38: editing + reordering pending messages -----------------------

test("SPEC-38: updateQueued replaces the text; empty text cancels", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });
  await session.sendUserMessage("first");
  await session.sendUserMessage("a");
  await session.sendUserMessage("b");
  const [a, b] = session.queuedMessages;

  assert.equal(session.updateQueued(a.id, "a, but better"), true);
  assert.deepEqual(session.queuedMessages.map((q) => q.text), ["a, but better", "b"]);
  assert.equal(session.updateQueued("nope", "x"), false, "unknown id is a no-op");

  // Clearing the text is a cancel: a blank pending message is not a thing.
  assert.equal(session.updateQueued(b.id, "   "), true);
  assert.deepEqual(session.queuedMessages.map((q) => q.text), ["a, but better"]);

  f.idle();
  await settle();
  assert.deepEqual(f.sent, ["first", "a, but better"], "the EDITED text is delivered");
});

test("SPEC-38: reorderQueue applies a full order", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });
  await session.sendUserMessage("first");
  for (const t of ["a", "b", "c"]) await session.sendUserMessage(t);
  const ids = session.queuedMessages.map((q) => q.id);

  assert.equal(session.reorderQueue([ids[2], ids[0], ids[1]]), true);
  assert.deepEqual(session.queuedMessages.map((q) => q.text), ["c", "a", "b"]);
});

test("SPEC-38: reorderQueue treats a stale id list as a hint, never an error", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });
  await session.sendUserMessage("first");
  for (const t of ["a", "b", "c"]) await session.sendUserMessage(t);
  const ids = session.queuedMessages.map((q) => q.id);

  // The client names only `c`, plus an id that has since been delivered.
  assert.equal(session.reorderQueue(["gone", ids[2]]), true);
  assert.deepEqual(
    session.queuedMessages.map((q) => q.text),
    ["c", "a", "b"],
    "named ids first, unmentioned keep their relative order, unknown ignored",
  );
  assert.equal(session.reorderQueue([]), false, "nothing named = nothing to do");
});

// ---- SPEC-39: promote (the queue tray's ⤒) --------------------------------

test("SPEC-39: promoteQueued interrupts the turn and sends THAT message next", async () => {
  const f = turnAdapter();
  const cancels: number[] = [];
  (f.adapter as any).cancel = async () => {
    cancels.push(Date.now());
    // A real adapter reports idle once the turn is actually aborted.
    f.adapter.emit("status", "idle");
  };
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("long running task");
  await session.sendUserMessage("a");
  await session.sendUserMessage("b");
  const [, b] = session.queuedMessages;

  assert.equal(await session.promoteQueued(b.id), true);
  await settle();

  assert.equal(cancels.length, 1, "the running turn is interrupted");
  assert.deepEqual(f.sent, ["long running task", "b"], "the promoted message goes first");
  assert.deepEqual(
    session.queuedMessages.map((q) => q.text),
    ["a"],
    "promote keeps the rest of the queue — unlike cancel, which drops it",
  );
});

test("SPEC-39: promoting the head is still an interrupt, not a no-op", async () => {
  const f = turnAdapter();
  (f.adapter as any).cancel = async () => f.adapter.emit("status", "idle");
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("only");
  const [only] = session.queuedMessages;

  assert.equal(await session.promoteQueued(only.id), true);
  await settle();
  assert.deepEqual(f.sent, ["first", "only"]);
  assert.equal(session.queuedMessages.length, 0);
});

test("SPEC-39: promoting an id the queue no longer holds is a no-op, not an interrupt", async () => {
  const f = turnAdapter();
  let cancels = 0;
  (f.adapter as any).cancel = async () => {
    cancels += 1;
    f.adapter.emit("status", "idle");
  };
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("queued");

  assert.equal(await session.promoteQueued("flushed-already"), false);
  await settle();
  assert.equal(cancels, 0, "an unknown id must not abort the user's turn");
  assert.deepEqual(f.sent, ["first"]);
  assert.equal(session.queuedMessages.length, 1);
});

// ---- terminal failure + the queue cap -------------------------------------

test("SPEC-35: an adapter.send rejection drops the queue AND names what was lost", async () => {
  const f = turnAdapter();
  let failNext = false;
  (f.adapter as any).send = async (input: { text: string }) => {
    if (failNext) throw new Error("child process is gone");
    f.sent.push(input.text);
    f.adapter.emit("status", "running");
  };
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  await session.sendUserMessage("the one that fails");
  await session.sendUserMessage("collateral damage");
  assert.equal(session.queuedMessages.length, 2);

  failNext = true;
  f.idle();
  await settle();

  assert.equal(session.queuedMessages.length, 0, "the queue is dropped, not retried");
  const errors = session.events
    .filter((e) => e.kind === "session.error")
    .map((e) => (e.payload as { message: string }).message);
  assert.ok(
    errors.some((m) => m.includes("child process is gone") && m.includes("the one that fails")),
    `the failed message's text must be recoverable from the error: ${errors.join(" | ")}`,
  );
  assert.ok(
    errors.some((m) => m.includes("collateral damage")),
    `a dropped message the user never saw fail must be named too: ${errors.join(" | ")}`,
  );
});

test("SPEC-35: the queue is capped, and the refusal names the message", async () => {
  const f = turnAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: f.adapter });

  await session.sendUserMessage("first");
  for (let i = 0; i < 60; i++) await session.sendUserMessage(`queued ${i}`);

  assert.equal(session.queuedMessages.length, 50, "capped at MAX_QUEUED_MESSAGES");
  assert.deepEqual(
    session.queuedMessages.at(-1)?.text,
    "queued 49",
    "the OLDEST accepted messages are kept; the newest are refused",
  );
  const errors = session.events
    .filter((e) => e.kind === "session.error")
    .map((e) => (e.payload as { message: string }).message);
  assert.ok(
    errors.some((m) => m.includes("already waiting") && m.includes("queued 50")),
    `the refused message must be named: ${errors.slice(0, 2).join(" | ")}`,
  );
});

test("agentPid is undefined for an adapter with no child process (stub/fake)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  assert.equal(session.agentPid, undefined);
});

test("agentPid returns the adapter's pid when the adapter exposes one", () => {
  const adapter = fakeAdapter();
  (adapter as any).agentPid = 4242;
  const session = new Session({ projectId: "p", agent: "pi", adapter });
  assert.equal(session.agentPid, 4242);
});

test("replaceAdapter unbinds only the session's own listeners, not a third party's", () => {
  const outgoing = fakeAdapter();
  const session = new Session({ projectId: "p", agent: "pi", adapter: outgoing });

  // Somebody else is also watching this adapter — e.g. a metrics collector, a
  // test harness, or a probe. Replacing the session's adapter must not silently
  // cancel their subscription.
  const foreignExits: unknown[] = [];
  const foreignEvents: unknown[] = [];
  outgoing.on("exit", (code) => foreignExits.push(code));
  outgoing.on("event", (e) => foreignEvents.push(e));

  session.replaceAdapter(fakeAdapter());

  const before = session.events.length;
  outgoing.emit("event", { ts: Date.now(), kind: "user.message", payload: { text: "ghost" } });
  outgoing.emit("exit", 0);

  // The session must be deaf to its old adapter...
  assert.equal(session.events.length, before, "no ghost event reached the session");
  // ...while the third party keeps hearing it.
  assert.deepEqual(foreignExits, [0], "a foreign exit listener survived the swap");
  assert.equal(foreignEvents.length, 1, "a foreign event listener survived the swap");
});

test("toDTO projects SPEC-46 lineage hydrated from meta (D10)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const session = new Session({
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
    parentId: "parent-1",
    handoffReason: "out of context",
    origin: "agent",
  });

  const dto = session.toDTO();
  assert.equal(dto.parentId, "parent-1");
  assert.equal(dto.handoffReason, "out of context");
  assert.equal(dto.origin, "agent");

  // Lineage is persisted on meta too, so a rehydrated session still reports it.
  const meta = store.loadSessions()[0];
  assert.equal(meta.parentId, "parent-1");
  assert.equal(meta.handoffReason, "out of context");
  assert.equal(meta.origin, "agent");
  store.close();
});

test("toDTO omits lineage for a session with no parent (pre-SPEC-46 / app-spawned)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  const dto = session.toDTO();
  assert.equal(dto.parentId, undefined);
  assert.equal(dto.handoffReason, undefined);
  assert.equal(dto.origin, undefined);
});
