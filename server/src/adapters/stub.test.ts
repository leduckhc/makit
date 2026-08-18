/**
 * StubAdapter configOptions round-trip (SPEC-acp-config-options-unified-composer): the stub emits a small
 * `session.meta.configOptions` catalog on start and applies `configOption`
 * actions by re-emitting the complete updated list — the keyless e2e stand-in
 * for the ACP/codex adapters' config surface.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { StubAdapter } from "./stub.js";
import type { AdapterEvent } from "./adapter.js";
import type { SessionConfigOption } from "../protocol.js";
import type { UIResponse } from "../uicall.js";

/** Poll until `ready`, bounded — never an unbounded await (node --test has no timeout). */
async function waitFor(ready: () => boolean, ms = 1000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!ready() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 5));
  if (!ready()) throw new Error("condition not met in time");
}

function collectMeta(adapter: StubAdapter): AdapterEvent[] {
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => {
    if (e.kind === "session.meta") events.push(e);
  });
  return events;
}

function optionsOf(e: AdapterEvent): SessionConfigOption[] {
  return (e.payload as { configOptions?: SessionConfigOption[] }).configOptions ?? [];
}

test("stub emits configOptions on start", async () => {
  const stub = new StubAdapter();
  const metas = collectMeta(stub);
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  assert.equal(metas.length, 1);
  const opts = optionsOf(metas[0]);
  assert.equal(opts.length, 4);
  assert.equal(opts[0].id, "model");
  assert.equal(opts[0].category, "model");
  assert.equal(opts[0].currentValue, "stub-normal");
  assert.equal(opts[1].id, "thought_level");
  assert.equal(opts[1].category, "thought_level");
  assert.equal(opts[2].id, "context");
  assert.equal(opts[2].category, "model_config");
  assert.equal(opts[3].id, "fast");
  assert.equal(opts[3].category, "model_config");
});

test("configOption action updates and re-emits the complete list", async () => {
  const stub = new StubAdapter();
  const metas = collectMeta(stub);
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  await stub.sendAction("configOption", { id: "thought_level", value: "high" });
  assert.equal(metas.length, 2);
  const opts = optionsOf(metas[1]);
  assert.equal(opts.length, 4, "complete list re-emitted");
  assert.equal(opts.find((o) => o.id === "thought_level")?.currentValue, "high");
  assert.equal(opts.find((o) => o.id === "model")?.currentValue, "stub-normal");
});

test("boolean option round-trips true and false", async () => {
  const stub = new StubAdapter();
  const metas = collectMeta(stub);
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  // `fast` starts true; a boolean action can disable it, then re-enable it.
  await stub.sendAction("configOption", { id: "fast", value: false });
  assert.equal(optionsOf(metas.at(-1)!).find((o) => o.id === "fast")?.currentValue, false);
  await stub.sendAction("configOption", { id: "fast", value: true });
  assert.equal(optionsOf(metas.at(-1)!).find((o) => o.id === "fast")?.currentValue, true);
});

test("unknown option id or non-configOption action is ignored", async () => {
  const stub = new StubAdapter();
  const metas = collectMeta(stub);
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  await stub.sendAction("configOption", { id: "nope", value: "x" });
  await stub.sendAction("compact");
  assert.equal(metas.length, 1, "no re-emit for unknown id / other actions");
});

test("an adapter with no steering primitive reports it (SPEC-mid-turn-steering-and-queue T1)", async () => {
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const before = events.length;

  assert.equal(await stub.steer({ text: "mid-turn" }), false);
  assert.equal(events.length, before, "steer() must not echo or emit anything");
});

test("SLOW keeps the stub busy so the pending queue is demoable (SPEC-pending-queue-edit-reorder)", async () => {
  const stub = new StubAdapter();
  const statuses: string[] = [];
  const events: AdapterEvent[] = [];
  stub.on("status", (s) => statuses.push(s));
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s1", cwd: "/tmp" });

  await stub.send({ text: "SLOW 120" });

  // Running immediately, and STILL running a moment later: without a turn that
  // outlives a keystroke there is no way to demo (or e2e) a queued message.
  assert.equal(statuses.at(-1), "running");
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(statuses.at(-1), "running");

  await new Promise((r) => setTimeout(r, 160));
  assert.equal(statuses.at(-1), "idle");
  assert.ok(
    events.some((e) => e.kind === "agent.message"),
    "the turn still produces a reply",
  );
});

test("a plain echo is a whole turn (running → idle), so a queue keeps draining", async () => {
  const a = new StubAdapter();
  const statuses: string[] = [];
  a.on("status", (s: string) => statuses.push(s));
  await a.start({ cwd: process.cwd(), sessionId: "s-turn" });
  statuses.length = 0;

  await a.send({ text: "hello" });
  await new Promise((r) => setTimeout(r, 120));

  assert.deepEqual(statuses, ["running", "idle"]);
});

// ---------------------------------------------------------------------------
// SPEC-cli-as-client T15 — the stub can be BLOCKED and can FAIL.
//
// `makit wait` promises distinct exit codes for "the agent finished" (0), "it is
// blocked on you" (10 / 11) and "it failed" (20). None of those could be proven
// against this stub, which only ever went running → idle: it had no
// `awaiting-*` path at all, and its two `session.error` emissions were both
// internal bridge faults with no way for a test to ask for one.
//
// The gates go through the shared `TurnStatusTracker`, not a hand-rolled emit,
// for the reason that class exists: the coarse `status` channel is typed
// `"idle" | "running"`, so a gate is a `session.status` EVENT, and having two
// spellings of that is what drifted acp and codex into stuck-spinner bugs.
// ---------------------------------------------------------------------------

function collectStatuses(adapter: StubAdapter): { coarse: string[]; gates: string[] } {
  const coarse: string[] = [];
  const gates: string[] = [];
  adapter.on("status", (s: string) => coarse.push(s));
  adapter.on("event", (e: AdapterEvent) => {
    if (e.kind === "session.status") gates.push((e.payload as { status: string }).status);
  });
  return { coarse, gates };
}

function collectKinds(adapter: StubAdapter, kind: string): AdapterEvent[] {
  const out: AdapterEvent[] = [];
  adapter.on("event", (e) => {
    if (e.kind === kind) out.push(e);
  });
  return out;
}

test("AWAIT_APPROVAL parks the turn on an approval gate and stays there", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const { coarse, gates } = collectStatuses(stub);
  await stub.send({ text: "please AWAIT_APPROVAL now" });
  // running first (a turn is genuinely in flight), then the gate.
  assert.deepEqual(coarse, ["running"]);
  assert.deepEqual(gates, ["awaiting-approval"]);
  // And it must NOT settle on its own — a gate that auto-clears would make
  // `makit wait --for approval` flaky-green.
  await new Promise((r) => setTimeout(r, 120));
  assert.deepEqual(coarse, ["running"], "the gate cleared itself");
});

test("AWAIT_INPUT parks on the input gate, routed identically", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const { coarse, gates } = collectStatuses(stub);
  await stub.send({ text: "AWAIT_INPUT" });
  assert.deepEqual(coarse, ["running"]);
  assert.deepEqual(gates, ["awaiting-input"]);
});

test("cancel releases a gate instead of wedging the session", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const { coarse } = collectStatuses(stub);
  await stub.send({ text: "AWAIT_APPROVAL" });
  await stub.cancel();
  assert.deepEqual(coarse, ["running", "idle"]);
  // The gate is gone, so a following turn behaves normally.
  await stub.send({ text: "hello" });
  await new Promise((r) => setTimeout(r, 120));
  assert.deepEqual(coarse, ["running", "idle", "running", "idle"]);
});

test("FAIL_TURN emits a terminal session.error and then settles IDLE", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const { coarse } = collectStatuses(stub);
  const errors = collectKinds(stub, "session.error");
  await stub.send({ text: "FAIL_TURN" });
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(errors.length, 1);
  assert.match((errors[0].payload as { message: string }).message, /FAIL_TURN/);
  // THE POINT of this test: the status ends `idle`, not `error`. Nothing in
  // makit emits `status: "error"`, so `makit wait` must key exit 20 off the
  // EVENT. If this ever ends "error", the exit-code design changes.
  assert.deepEqual(coarse, ["running", "idle"]);
});

test("AWAIT_APPROVAL raises a real confirmAction prompt, and answering it ends the turn", async () => {
  // Production adapters go `awaiting-approval` *because* they asked the user
  // something: the status and the `srv.request` are one event. The stub used to
  // park the status without asking, which made the composed flow the CLI exists
  // for — `makit run` exits 10, you `makit approve`, the turn finishes —
  // impossible to exercise at all, and left "approve" looking broken against a
  // session that plainly says `[awaiting-approval]`.
  const asked: Record<string, unknown>[] = [];
  let answer: ((r: UIResponse) => void) | undefined;
  const stub = new StubAdapter({
    askUser: (body) => {
      asked.push(body);
      return new Promise<UIResponse>((res) => {
        answer = res;
      });
    },
  });
  await stub.start({ cwd: process.cwd(), sessionId: "s1" });
  // Two channels, as the other gate tests do: `status` is the coarse
  // running/idle signal, `session.status` events carry the gate itself.
  const { coarse, gates } = collectStatuses(stub);
  void stub.send({ text: "AWAIT_APPROVAL please" });
  await waitFor(() => asked.length === 1);

  assert.equal(asked[0]!.kind, "confirmAction", "a permission prompt, like the real adapters raise");
  assert.equal(asked[0]!.sessionId, "s1", "attributed to the session — D13 routes on this, and `approve <id>` matches it");
  assert.ok(gates.includes("awaiting-approval"), "and the status the CLI keys exit 10 off");
  assert.deepEqual(coarse, ["running"], "still mid-turn while the user is asked");

  // Answering it releases the turn — the half that could never be tested before.
  answer!({ kind: "confirmAction", approved: true } as UIResponse);
  await waitFor(() => coarse.at(-1) === "idle");
});

// ---------------------------------------------------------------------------
// A killed stub stops emitting
//
// SLOW's timer is stored in `slowTimeout` and cleared by both `cancel()` and
// `kill()`; FAIL_TURN's was not stored at all, so it kept firing after the
// adapter was gone and pushed `session.error` at whatever was still listening.
// This is the harness that the keyless e2e loop and every queue test run on, so
// a stray terminal event here is a flake with a plausible-looking cause.
// ---------------------------------------------------------------------------

test("kill() during a pending FAIL_TURN cancels it instead of erroring after the exit", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const errors = collectKinds(stub, "session.error");
  await stub.send({ text: "FAIL_TURN" });
  await stub.kill();
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(errors.length, 0, "a killed adapter must not emit a terminal error afterwards");
});

test("cancel() during a pending FAIL_TURN releases the turn without the error", async () => {
  const stub = new StubAdapter();
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const errors = collectKinds(stub, "session.error");
  const { coarse } = collectStatuses(stub);
  await stub.send({ text: "FAIL_TURN" });
  await stub.cancel();
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(errors.length, 0, "a cancelled turn is not a failed one");
  assert.equal(coarse.at(-1), "idle", "and the session is not left wedged running");
});

/**
 * "TOOLS" trigger: the keyless loop had no way to produce a tool row at all, so
 * the transcript's most common row type — and everything the app derives from it
 * (risk tint, duration, exit code, expanded body) — could only be exercised with
 * a real agent and an API key. Same rationale as STREAM/THINK/ASK_QUESTION.
 */
test("TOOLS emits a representative tool-call sequence", async (t) => {
  process.env.MAKIT_STUB_TOOL_SCALE = "0.01";
  // `t.after` rather than a line at the end: `send` can reject, and the runner
  // shares one process per file, so a leaked scale would shrink every later test.
  t.after(() => {
    delete process.env.MAKIT_STUB_TOOL_SCALE;
  });
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  const statuses: string[] = [];
  stub.on("event", (e) => events.push(e));
  stub.on("status", (s) => statuses.push(String(s)));
  await stub.start({ sessionId: "s-tools", cwd: "/tmp" });
  events.length = 0;
  statuses.length = 0;
  // Streams like a real adapter: send returns immediately, events follow.
  await stub.send({ text: "TOOLS" });
  for (let i = 0; i < 200 && statuses.at(-1) !== "idle"; i++) {
    await new Promise((r) => setTimeout(r, 10));
  }
  // The turn opens and closes, or the composer stays disabled forever.
  assert.deepEqual(statuses, ["running", "idle"]);
  const kinds = events.map((e) => e.kind);
  assert.ok(kinds.includes("agent.thinking"), "a reasoning row leads the turn");
  assert.ok(kinds.includes("tool.call.start"));
  assert.ok(kinds.includes("tool.call.end"));

  const starts = events.filter((e) => e.kind === "tool.call.start");
  const ends = events.filter((e) => e.kind === "tool.call.end");
  // Every start is closed: a dangling start renders as a row that spins forever.
  assert.deepEqual(
    starts.map((e) => (e.payload as { callId: string }).callId).sort(),
    ends.map((e) => (e.payload as { callId: string }).callId).sort(),
  );

  const names = starts.map((e) => (e.payload as { name: string }).name);
  assert.ok(names.includes("read"), "a safe read");
  assert.ok(names.includes("bash"), "a shell call");
  assert.ok(names.includes("edit"), "an edit, for the diff body");

  // Risk classification must span the app's three branches, since the UI tints
  // only `destructive` now and the other two must prove they do NOT.
  const risks = new Set(starts.map((e) => (e.payload as { risk?: string }).risk));
  assert.deepEqual([...risks].sort(), ["destructive", "risky", "safe"]);

  // A failure, so the error caption/hue has something to render.
  assert.ok(
    ends.some((e) => (e.payload as { exitCode?: number }).exitCode === 1),
    "one call fails",
  );
  // A multi-command shell call, so `commandNames` has something to summarise.
  const commands = starts
    .filter((e) => (e.payload as { name: string }).name === "bash")
    .map((e) => String((e.payload as { args?: { command?: string } }).args?.command ?? ""));
  assert.ok(
    commands.some((c) => c.includes("&&") || c.includes("|")),
    "one shell call chains several commands",
  );
  // The turn ends with the agent's reply, after every call is closed.
  assert.equal(events.at(-1)?.kind, "agent.message");
});

/**
 * cancel()/kill() must stop the scripted turn. The SLOW turn already guards its
 * timeout (see `slowTimeout`); the TOOLS turn emits far more late events — six
 * starts, six ends, a reply and a second `idle` — so it needs the same guard.
 *
 * Scale 0.05 puts the whole script at ~265 ms, so the 900 ms settle below
 * genuinely outlives it: with a shorter settle the assertions pass while the
 * script is merely parked inside its next `wait`.
 */
async function startsSeen(events: AdapterEvent[], n = 1): Promise<void> {
  for (let i = 0; i < 300; i++) {
    if (events.filter((e) => e.kind === "tool.call.start").length >= n) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error(`the script never opened ${n} tool call(s)`);
}

async function firstStart(stub: StubAdapter, events: AdapterEvent[]) {
  await stub.send({ text: "TOOLS" });
  await startsSeen(events, 1);
}

test("cancel stops the TOOLS script mid-flight", async (t) => {
  process.env.MAKIT_STUB_TOOL_SCALE = "0.05";
  t.after(() => {
    delete process.env.MAKIT_STUB_TOOL_SCALE;
  });
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  const statuses: string[] = [];
  stub.on("event", (e) => events.push(e));
  stub.on("status", (s) => statuses.push(String(s)));
  await stub.start({ sessionId: "s-cancel", cwd: "/tmp" });
  await firstStart(stub, events);

  await stub.cancel();
  const afterCancel = events.length;
  await new Promise((r) => setTimeout(r, 900));

  assert.equal(events.length, afterCancel, "no events after cancel");
  assert.equal(
    statuses.filter((s) => s === "idle").length,
    2,
    "start's idle + cancel's idle, and no third from the script finishing",
  );
  assert.ok(
    !events.some((e) => e.kind === "agent.message"),
    "the script's closing reply never lands",
  );
});

/**
 * Aborting must SETTLE the pending wait, not just clear its timer. The timeout
 * callback was the only thing that resolved `wait`, so a cancelled script stayed
 * suspended at `await wait(...)` forever — no further events (which is why the
 * tests above passed) but the closure and its call data were retained for the
 * life of the adapter, once per cancellation.
 */
test("a cancelled TOOLS script settles instead of hanging", async () => {
  // Unscaled, so the cancel below lands inside the script's 2.6 s wait — a wait
  // far longer than the race that follows. A short scale would let the timer
  // fire on its own and the assertion would pass either way.
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s-settle", cwd: "/tmp" });
  await stub.send({ text: "TOOLS" });
  await startsSeen(events, 2);

  await stub.cancel();
  const settled = await Promise.race([
    stub.toolScript!.then(() => "settled"),
    new Promise((r) => setTimeout(() => r("hung"), 500)),
  ]);
  assert.equal(settled, "settled", "the script resumed and returned");
});

/**
 * A cancelled script must stay cancelled even if the NEXT turn starts before it
 * resumes. `cancel()` settles the pending wait (queueing the script's
 * continuation) and then emits `idle` synchronously; the session layer flushes
 * its queue on `idle`, so a queued TOOLS turn could begin — and a shared
 * `toolAborted` flag would be reset to false before the old script resumed,
 * letting it emit the rest of its calls interleaved with the new turn.
 */
test("a cancelled script stays cancelled when the next turn starts first", async (t) => {
  process.env.MAKIT_STUB_TOOL_SCALE = "0.05";
  t.after(() => {
    delete process.env.MAKIT_STUB_TOOL_SCALE;
  });
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s-requeue", cwd: "/tmp" });

  await stub.send({ text: "TOOLS" });
  await startsSeen(events, 2);

  // Exactly what the session layer does: start the queued turn on idle, in the
  // same tick, before the cancelled script has resumed.
  let requeued = false;
  stub.on("status", (status) => {
    if (status === "idle" && !requeued) {
      requeued = true;
      void stub.send({ text: "TOOLS" });
    }
  });
  await stub.cancel();
  await new Promise((r) => setTimeout(r, 1200));

  const starts = events.filter((e) => e.kind === "tool.call.start").length;
  const replies = events.filter((e) => e.kind === "agent.message").length;
  // 2 from the cancelled script + 6 from the new one. More means the cancelled
  // script resumed and kept going.
  assert.equal(starts, 8, "the cancelled script contributed no further calls");
  assert.equal(replies, 1, "only the new turn reports a closing reply");
});

/**
 * A second TOOLS turn while the first is still in flight. Bumping the run token
 * stops the old script from *emitting*, but the timer handle and the wait
 * resolver are shared fields: the old script stayed parked on a live timer,
 * whose callback then nulled the NEW script's handles (verified by probe — it
 * really does fire while run 2 is live), leaving a window in which the new
 * script could not be aborted at all.
 *
 * The crisp, race-free invariant: starting a turn releases the previous script
 * at once, well before its own timer would have fired.
 */
test("a re-send releases the previous script immediately", async (t) => {
  process.env.MAKIT_STUB_TOOL_SCALE = "0.05";
  t.after(() => {
    delete process.env.MAKIT_STUB_TOOL_SCALE;
  });
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s-resend", cwd: "/tmp" });

  await stub.send({ text: "TOOLS" });
  await startsSeen(events, 2); // script 1 is inside its 2.6 s × 0.05 wait
  const first = stub.toolScript!;

  await stub.send({ text: "TOOLS" });
  const released = await Promise.race([
    first.then(() => "released"),
    new Promise((r) => setTimeout(() => r("parked"), 40)),
  ]);
  assert.equal(
    released,
    "released",
    "the previous script must not stay parked on a timer that outlives it",
  );

  // And the new script is still fully abortable afterwards.
  await stub.cancel();
  const settled = await Promise.race([
    stub.toolScript!.then(() => "settled"),
    new Promise((r) => setTimeout(() => r("hung"), 500)),
  ]);
  assert.equal(settled, "settled");
});

test("kill stops the TOOLS script mid-flight", async (t) => {
  process.env.MAKIT_STUB_TOOL_SCALE = "0.05";
  t.after(() => {
    delete process.env.MAKIT_STUB_TOOL_SCALE;
  });
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s-kill", cwd: "/tmp" });
  await firstStart(stub, events);
  await stub.kill();
  const afterKill = events.length;
  await new Promise((r) => setTimeout(r, 900));
  assert.equal(events.length, afterKill, "an exited adapter emits nothing");
});
