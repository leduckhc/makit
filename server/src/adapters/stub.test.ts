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

test("unknown option id or non-configOption action is ignored", async () => {
  const stub = new StubAdapter();
  const metas = collectMeta(stub);
  await stub.start({ sessionId: "s1", cwd: "/tmp" });
  await stub.sendAction("configOption", { id: "nope", value: "x" });
  await stub.sendAction("compact");
  assert.equal(metas.length, 1, "no re-emit for unknown id / other actions");
});
