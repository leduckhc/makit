import { test } from "node:test";
import assert from "node:assert/strict";
import { IngestAdapter } from "./ingest.js";
import type { AdapterEvent } from "./adapter.js";
import type { CommandsFetcher } from "./commands.js";

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

test("sendAction() relays action+args to onAction; no-op after kill()", async () => {
  const actions: Array<{ action: string; args?: Record<string, unknown> }> = [];
  const a = new IngestAdapter(
    () => {},
    undefined,
    (action, args) => actions.push({ action, args }),
  );
  await a.start({ cwd: "/tmp" });
  await a.sendAction("compact");
  await a.sendAction("thinking", { level: "high" });
  assert.deepEqual(actions, [
    { action: "compact", args: undefined },
    { action: "thinking", args: { level: "high" } },
  ]);

  await a.kill();
  await a.sendAction("compact");
  assert.equal(actions.length, 2, "no relay after kill()");
});

/** Awaits the fire-and-forget commands fetch, bounded by a timeout for safety. */
function waitDone(a: IngestAdapter, ms = 1000): Promise<void> {
  const done = a.fetchCommandsDone;
  if (!done) return Promise.resolve();
  return Promise.race([done, new Promise<void>((r) => setTimeout(r, ms))]);
}

test("enableCommands() + start() emits session.commands event via injected fetcher", async () => {
  const prompts: string[] = [];
  const a = new IngestAdapter((t) => prompts.push(t));
  const fetcher: CommandsFetcher = async () => [
    { name: "skill:x", description: "d", source: "skill" },
  ];
  a.enableCommands(fetcher);
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await waitDone(a);
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.ok(cmd, "session.commands event emitted");
  assert.deepEqual(cmd!.payload.commands, [{ name: "skill:x", description: "d", source: "skill" }]);
  await a.kill();
});

test("without enableCommands(), no commands event emitted", async () => {
  const a = new IngestAdapter(() => {});
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await new Promise((r) => setTimeout(r, 50));
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.equal(cmd, undefined);
  await a.kill();
});

test("commands fetch failure is swallowed — adapter continues normally", async () => {
  const a = new IngestAdapter(() => {});
  const fetcher: CommandsFetcher = async () => { throw new Error("pi not found"); };
  a.enableCommands(fetcher);
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await waitDone(a);
  // Ingest API should still work normally after a failed commands fetch.
  a.ingestEvent({ ts: 1, kind: "agent.message", payload: { text: "still works" } });
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.equal(cmd, undefined);
  const msg = events.find((e) => e.kind === "agent.message");
  assert.ok(msg, "ingested events still flow after fetch failure");
  await a.kill();
});
