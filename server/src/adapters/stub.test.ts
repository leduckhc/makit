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
