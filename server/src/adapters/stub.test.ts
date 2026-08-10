/**
 * StubAdapter configOptions round-trip (SPEC-26): the stub emits a small
 * `session.meta.configOptions` catalog on start and applies `configOption`
 * actions by re-emitting the complete updated list — the keyless e2e stand-in
 * for the ACP/codex adapters' config surface.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { StubAdapter } from "./stub.js";
import type { AdapterEvent } from "./adapter.js";
import type { SessionConfigOption } from "../protocol.js";

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

test("an adapter with no steering primitive reports it (SPEC-35 T1)", async () => {
  const stub = new StubAdapter();
  const events: AdapterEvent[] = [];
  stub.on("event", (e) => events.push(e));
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  const before = events.length;

  assert.equal(await stub.steer({ text: "mid-turn" }), false);
  assert.equal(events.length, before, "steer() must not echo or emit anything");
});

test("SLOW keeps the stub busy so the pending queue is demoable (SPEC-38)", async () => {
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
async function firstStart(stub: StubAdapter, events: AdapterEvent[]) {
  await stub.send({ text: "TOOLS" });
  for (let i = 0; i < 200; i++) {
    if (events.some((e) => e.kind === "tool.call.start")) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("the script never opened a tool call");
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
