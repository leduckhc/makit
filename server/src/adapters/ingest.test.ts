import { test } from "node:test";
import assert from "node:assert/strict";
import { IngestAdapter } from "./ingest.js";
import type { AdapterEvent } from "./adapter.js";

test("ingestEvent/ingestStatus emit; send() relays to onPrompt", async () => {
  const prompts: string[] = [];
  const a = new IngestAdapter((t) => prompts.push(t));
  const events: AdapterEvent[] = [];
  const statuses: string[] = [];
  a.on("event", (e) => events.push(e));
  a.on("status", (s) => statuses.push(s));

  await a.start({ cwd: "/tmp" });
  a.ingestEvent({ ts: 1, kind: "agent.message", payload: { text: "hi" } });
  a.ingestStatus("running");
  await a.send({ text: "from phone" });

  assert.deepEqual(events.map((e) => e.kind), ["agent.message"]);
  assert.deepEqual(prompts, ["from phone"]);
  assert.ok(statuses.includes("idle")); // start()
  assert.ok(statuses.includes("running"));
});

test("after kill(), no more events emit and prompts stop relaying", async () => {
  const prompts: string[] = [];
  const a = new IngestAdapter((t) => prompts.push(t));
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.kill();
  a.ingestEvent({ ts: 1, kind: "agent.message", payload: { text: "late" } });
  await a.send({ text: "late" });
  assert.equal(events.length, 0);
  assert.equal(prompts.length, 0);
});
