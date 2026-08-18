/**
 * SPEC-cli-as-client T20 / D13 — the audience ladder, stored eligibility, and response
 * authorization.
 *
 * The ladder routes a stranded prompt (an agent-spawned session nobody has on a
 * screen) up its lineage: the session's own subscribers → the nearest
 * ancestor's subscribers via `parentId` → every authed client → the wake push
 * (`onUndeliverable`, unchanged). It is never auto-answered.
 *
 * Two authorization holes close in the same task: `replayPendingTo` only
 * re-sends to a client that was eligible (D13b), and `handleResponse` accepts a
 * response only from a client in the audience and never from an agent-scoped
 * token (D13c). These are asserted on what was *sent* and on whether a response
 * was accepted — never by awaiting a pending prompt, which by definition does
 * not settle.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ReverseRpc } from "./reverse_rpc.js";
import type { WsClient, OutgoingFrame } from "./client.js";
import type { Principal } from "./principal.js";
import type { Envelope } from "../protocol.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(opts: { authed?: boolean; subs?: string[]; principal?: Principal } = {}): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: opts.authed ?? true,
    subscribed: new Set(opts.subs ?? []),
    principal: opts.principal,
    watchingMetrics: false,
    watchingDocs: false,
    watchingPorts: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

const agentToken = (sessionId: string): Principal => ({
  deviceId: sessionId,
  label: `agent:${sessionId}`,
  caps: ["read", "send", "spawn"],
  sessionId,
});
const phone: Principal = { deviceId: "d", label: "phone" }; // no caps = full access

function reqs(c: FakeClient): OutgoingFrame[] {
  return c.sent.filter((f) => f.t === "srv.request");
}

// lineage: child → parent → (root). Everything else is a root.
const parentOf = (sid: string): string | undefined => (sid === "child" ? "parent" : undefined);

// -------- D13a rung 1: the session's own subscribers ------------------------

test("rung 1: a prompt reaches a client subscribed to the session itself", async () => {
  const own = fakeClient({ subs: ["child"] });
  const other = fakeClient({ subs: ["unrelated"] });
  const rpc = new ReverseRpc({ clients: () => [own, other], parentOf });

  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(reqs(own).length, 1, "the session's own subscriber is asked");
  assert.equal(reqs(other).length, 0, "an unrelated subscriber is not");

  const id = String(own.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, own);
  await p;
});

// -------- D13a rung 2: the nearest ancestor's subscribers -------------------

test("rung 2: with only the PARENT open, a handoff child's prompt reaches the parent's watcher", async () => {
  const parentWatcher = fakeClient({ subs: ["parent"] });
  const stranger = fakeClient({ subs: ["unrelated"] });
  const rpc = new ReverseRpc({ clients: () => [parentWatcher, stranger], parentOf });

  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(reqs(parentWatcher).length, 1, "the parent's watcher owns the consequence");
  assert.equal(reqs(stranger).length, 0, "an unrelated session's watcher is not asked");

  const id = String(parentWatcher.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: false } as Envelope, parentWatcher);
  await p;
});

// -------- D13a rung 3: nobody up the lineage → every authed client ----------

test("rung 3: with parent closed too, the prompt reaches every authed client", async () => {
  const a = fakeClient({ subs: [] });
  const b = fakeClient({ subs: ["unrelated"] });
  const unauthed = fakeClient({ authed: false });
  const rpc = new ReverseRpc({ clients: () => [a, b, unauthed], parentOf });

  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(reqs(a).length, 1);
  assert.equal(reqs(b).length, 1);
  assert.equal(reqs(unauthed).length, 0, "an unauthed socket is never a target");

  const id = String(a.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, a);
  await p;
});

// -------- D13a rung 4: no client at all → wake path, stays pending ----------

test("rung 4: with no client the prompt takes the wake path and stays pending", async () => {
  let woke = false;
  const rpc = new ReverseRpc({
    clients: () => [],
    parentOf,
    onUndeliverable: () => {
      woke = true;
      return true; // a real wake was dispatched → keep pending
    },
  });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 60_000 });
  assert.equal(woke, true, "the wake push fired");
  assert.equal(rpc.pendingCount, 1, "the request is still pending, not auto-answered");

  // A woken device reconnects and answers.
  const woken = fakeClient({ subs: ["child"] });
  rpc.replayPendingTo(woken);
  const id = String(woken.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, woken);
  assert.equal((await p).approved, true);
});

test("rung 4: an elicitation with no client routes identically to a permission", async () => {
  let count = 0;
  const rpc = new ReverseRpc({ clients: () => [], parentOf, onUndeliverable: () => (++count, true) });
  rpc.askDevice({ kind: "elicit", prompt: "name?" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(count, 1, "awaiting-input takes the same ladder as awaiting-approval");
  assert.equal(rpc.pendingCount, 1);
});

// -------- D13b: replay is gated on the stored eligibility --------------------

test("D13b: a client that authed AFTER the prompt and was not in its audience gets nothing on replay", async () => {
  const parentWatcher = fakeClient({ subs: ["parent"] });
  const rpc = new ReverseRpc({ clients: () => [parentWatcher], parentOf });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(reqs(parentWatcher).length, 1);

  // A brand-new socket, subscribed only to an unrelated session, connects later.
  const latecomer = fakeClient({ subs: ["unrelated"] });
  assert.equal(rpc.replayPendingTo(latecomer), 0, "not eligible → no replay");
  assert.equal(reqs(latecomer).length, 0);

  // But a reconnect that subscribes to the child (or its parent) IS eligible.
  const rejoin = fakeClient({ subs: ["child"] });
  assert.equal(rpc.replayPendingTo(rejoin), 1);
  assert.equal(reqs(rejoin).length, 1);
  await p; // let the short timeout settle it (no lingering timer)
});

// -------- D13c: the response is authorized -----------------------------------

test("D13c: an srv.response from a client OUTSIDE the audience does not resolve the request", async () => {
  const parentWatcher = fakeClient({ subs: ["parent"] });
  const outsider = fakeClient({ subs: ["unrelated"] });
  const rpc = new ReverseRpc({ clients: () => [parentWatcher, outsider], parentOf });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => "settled");
  const id = String(parentWatcher.sent[0]!.id);

  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, outsider);
  assert.equal(rpc.pendingCount, 1, "the outsider's answer is ignored");
  await p; // let the short timeout settle it (no hang)
});

test("D13c: an agent cannot self-approve — it is not a target, and a stolen id still fails", async () => {
  // Originally this test made the agent a *target* and proved its answer was
  // refused. Excluding agents from every rung (D17) makes that setup impossible,
  // so the invariant is now asserted in its stronger form: the child's own token
  // is not sent the prompt at all, and even holding the id — which it could learn
  // by other means — its answer does not resolve the request.
  const agentClient = fakeClient({ subs: ["child"], principal: agentToken("child") });
  const human = fakeClient({ subs: ["child"] });
  const rpc = new ReverseRpc({ clients: () => [agentClient, human], parentOf });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => "settled");

  assert.equal(agentClient.sent.length, 0, "the agent is never asked");
  const id = String(human.sent[0]!.id);

  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, agentClient);
  assert.equal(rpc.pendingCount, 1, "an agent granting itself access is refused");
  await p;
});

test("D13c: an srv.response from a client IN the audience resolves it (positive control)", async () => {
  const parentWatcher = fakeClient({ subs: ["parent"] });
  const rpc = new ReverseRpc({ clients: () => [parentWatcher], parentOf });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 60_000 });
  const id = String(parentWatcher.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, parentWatcher);
  assert.equal((await p).approved, true);
});

// -------- Regression: an ordinary phone + app flow is unchanged --------------

test("regression: a phone (no caps) subscribed to the session is asked and its answer resolves", async () => {
  const app = fakeClient({ subs: ["s-1"], principal: phone });
  const rpc = new ReverseRpc({ clients: () => [app] });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "s-1", timeoutMs: 60_000 });
  assert.equal(reqs(app).length, 1);
  const id = String(app.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, app);
  assert.equal((await p).approved, true);
});

// -------- Base contract (preserved from the former test/ws/reverse_rpc.test.ts)

test("first response wins; a later response for the same id is a no-op", async () => {
  const client = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [client] });
  const promise = rpc.askDevice({ kind: "askUserQuestion" });
  const id = String(client.sent.find((f) => f.t === "srv.request")!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, answer: "first" } as Envelope, client);
  rpc.handleResponse({ v: 1, t: "srv.response", id, answer: "second" } as Envelope, client);
  assert.equal((await promise).answer, "first");
});

test("askDevice times out when no response arrives", async () => {
  const client = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [client] });
  await assert.rejects(rpc.askDevice({ kind: "askUserQuestion" }, { timeoutMs: 10 }), /timed out/);
});

test("askDevice rejects when there is no client to ask", async () => {
  const unauthed = fakeClient({ authed: false });
  const rpc = new ReverseRpc({ clients: () => [unauthed] });
  await assert.rejects(rpc.askDevice({ kind: "askUserQuestion" }), /no subscribed clients to ask/);
});

// -------- D14: the prompt is self-describing --------------------------------

test("D14: the srv.request carries the session caption for a client that never subscribed", async () => {
  // Rung 3: nobody has this session (or its lineage) on a screen, so the prompt
  // lands on a phone that never subscribed. It must carry enough to caption it.
  const stranger = fakeClient({ subs: ["unrelated"] });
  const rpc = new ReverseRpc({
    clients: () => [stranger],
    sessionCaption: (sid) =>
      sid === "child"
        ? {
            title: "Fix the parser",
            agent: "codex",
            parentId: "parent",
            handoffReason: "handed off for the risky refactor",
            origin: "agent",
          }
        : undefined,
  });

  const p = rpc
    .askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 })
    .catch(() => {});
  const env = reqs(stranger)[0]!;
  assert.deepEqual(env.session, {
    title: "Fix the parser",
    agent: "codex",
    parentId: "parent",
    handoffReason: "handed off for the risky refactor",
    origin: "agent",
  });
  const id = String(env.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, stranger);
  await p;
});

test("D14 is additive: no sessionCaption dep leaves the envelope unchanged", async () => {
  const client = fakeClient({ subs: ["child"] });
  const rpc = new ReverseRpc({ clients: () => [client] });
  const p = rpc
    .askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 })
    .catch(() => {});
  assert.equal(reqs(client)[0]!.session, undefined, "no caption when the dep is absent");
  const id = String(client.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, client);
  await p;
});

// -------- The lineage walk terminates on hostile data ------------------------

test("the lineage walk terminates on a parentId cycle and falls through to rung 3", async () => {
  // child → parent → child … a forged loop. No client subscribes up the chain,
  // so the walk must terminate and fall through to every authed client.
  const cyclic = (sid: string): string | undefined =>
    sid === "child" ? "parent" : sid === "parent" ? "child" : undefined;
  const a = fakeClient({ subs: [] });
  const rpc = new ReverseRpc({ clients: () => [a], parentOf: cyclic });
  const p = rpc.askDevice({ kind: "confirmAction" }, { sessionId: "child", timeoutMs: 50 }).catch(() => {});
  assert.equal(reqs(a).length, 1, "the walk did not hang and fell through to rung 3");
  const id = String(a.sent[0]!.id);
  rpc.handleResponse({ v: 1, t: "srv.response", id, approved: true } as Envelope, a);
  await p;
});

test("D13: an agent token is never in the rung-3 audience, even though it cannot answer", async () => {
  // Rung 3 ("ask every authed client") stored `eligibleSessions: undefined`, and
  // `isEligible` read that as "everyone" — including agent-scoped principals. The
  // response guard meant an agent could not *answer*, but it still received the
  // question plus D14's caption (title, harness, handoffReason) for a session it
  // has no business reading. Disclosure, not escalation — but D17 forbids it.
  const agentClient = fakeClient({
    principal: { deviceId: "a", label: "agent", caps: ["read", "send", "spawn"], sessionId: "a" },
  });
  const phone = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [agentClient, phone] });

  // A short timeout + a swallowed rejection: an unsettled prompt is a promise that
  // never resolves, and it keeps node --test's process alive until the runner's own
  // timeout kills the whole file.
  void rpc.askDevice({ kind: "confirmAction" }, { sessionId: "someone-elses", timeoutMs: 20 }).catch(() => {});

  assert.equal(
    agentClient.sent.filter((f) => f.t === "srv.request").length,
    0,
    "the agent must not receive a broadcast prompt",
  );
  assert.ok(phone.sent.some((f) => f.t === "srv.request"), "the human still does");
});

test("D13: replayPendingTo does not hand a broadcast prompt to a late-connecting agent", async () => {
  const phone = fakeClient();
  const rpc = new ReverseRpc({ clients: () => [phone] });
  void rpc.askDevice({ kind: "confirmAction" }, { sessionId: "someone-elses", timeoutMs: 20 }).catch(() => {});

  const latecomer = fakeClient({
    principal: { deviceId: "a", label: "agent", caps: ["read"], sessionId: "a" },
  });
  assert.equal(rpc.replayPendingTo(latecomer), 0);
});
