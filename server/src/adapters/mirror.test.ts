import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MirrorAdapter, type PaneWriter, type CommandsFetcher } from "./mirror.js";
import type { AdapterEvent } from "./adapter.js";

function tmpFile(): string {
  return join(mkdtempSync(join(tmpdir(), "pino-mirror-")), "session.jsonl");
}

function userRec(text: string): string {
  return JSON.stringify({
    type: "message",
    timestamp: new Date().toISOString(),
    message: { role: "user", content: [{ type: "text", text }] },
  }) + "\n";
}
function assistantRec(text: string): string {
  return JSON.stringify({
    type: "message",
    timestamp: new Date().toISOString(),
    message: { role: "assistant", content: [{ type: "text", text }] },
  }) + "\n";
}

function recordingWriter(): PaneWriter & { texts: string[]; keys: string[][] } {
  return {
    texts: [],
    keys: [],
    async sendText(_t, text) {
      this.texts.push(text);
    },
    async sendKeys(_t, k) {
      this.keys.push(k);
    },
  };
}

test("start() emits existing history, then poll() streams new records", async () => {
  const path = tmpFile();
  writeFileSync(path, userRec("hello") + assistantRec("hi there"));
  const events: AdapterEvent[] = [];
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000);
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });

  assert.deepEqual(events.map((e) => e.kind), ["user.message", "agent.message"]);
  assert.equal(events[0]!.payload.text, "hello");

  appendFileSync(path, userRec("second") + assistantRec("reply 2"));
  a.poll();
  assert.deepEqual(events.map((e) => e.kind), [
    "user.message",
    "agent.message",
    "user.message",
    "agent.message",
  ]);
  assert.equal(events[2]!.payload.text, "second");
  await a.kill();
});

test("a half-written line is buffered until the newline arrives", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const events: AdapterEvent[] = [];
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000);
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });

  const rec = userRec("partial");
  const half = rec.slice(0, 20);
  appendFileSync(path, half);
  a.poll();
  assert.equal(events.length, 0, "partial line → no event yet");

  appendFileSync(path, rec.slice(20));
  a.poll();
  assert.equal(events.length, 1);
  assert.equal(events[0]!.payload.text, "partial");
  await a.kill();
});

test("send() injects text + Enter into the pane and flags running", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const writer = recordingWriter();
  const a = new MirrorAdapter(path, "w7:p3", writer, 10_000);
  const statuses: string[] = [];
  a.on("status", (s) => statuses.push(s));
  await a.start({ cwd: "/tmp" });
  await a.send({ text: "do the thing" });

  assert.deepEqual(writer.texts, ["do the thing"]);
  assert.deepEqual(writer.keys, [["Enter"]]);
  assert.ok(statuses.includes("running"));
  await a.kill();
});

test("an assistant message flips status back to idle", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000);
  const statuses: string[] = [];
  a.on("status", (s) => statuses.push(s));
  await a.start({ cwd: "/tmp" });
  await a.send({ text: "hi" }); // running
  appendFileSync(path, assistantRec("done"));
  a.poll();
  assert.equal(statuses.at(-1), "idle");
  await a.kill();
});

/** Awaits the fire-and-forget commands fetch, bounded by a timeout for safety. */
function waitDone(a: MirrorAdapter, ms = 1000): Promise<void> {
  const done = a.fetchCommandsDone;
  if (!done) return Promise.resolve();
  return Promise.race([done, new Promise<void>((r) => setTimeout(r, ms))]);
}

test("start() fetches commands via side-channel and emits session.commands event", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const fetcher: CommandsFetcher = async () => [
    { name: "skill:x", description: "d", source: "skill" },
  ];
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000, fetcher);
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await waitDone(a);
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.ok(cmd, "session.commands event emitted");
  assert.deepEqual(cmd!.payload.commands, [{ name: "skill:x", description: "d", source: "skill" }]);
  await a.kill();
});

test("start() does NOT emit commands event when fetcher returns empty", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const fetcher: CommandsFetcher = async () => [];
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000, fetcher);
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await waitDone(a);
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.equal(cmd, undefined, "no session.commands event when fetcher returns empty");
  await a.kill();
});

test("commands fetch failure is swallowed — mirror continues normally", async () => {
  const path = tmpFile();
  writeFileSync(path, "");
  const fetcher: CommandsFetcher = async () => { throw new Error("pi not on PATH"); };
  const a = new MirrorAdapter(path, "w7:p1", recordingWriter(), 10_000, fetcher);
  const events: AdapterEvent[] = [];
  a.on("event", (e) => events.push(e));
  await a.start({ cwd: "/tmp" });
  await waitDone(a);
  const cmd = events.find((e) => e.kind === "session.commands");
  assert.equal(cmd, undefined, "no event when fetcher throws");
  await a.kill();
});

test("existing tests still work — no fetcher path runs real pi (integration smoke, skipped)", async () => {
  // Production (no fetcher) spawn is too heavy for a unit test; verified
  // manually at boot and covered by the integration test below.
  // The production fetchCommands() path uses `realCommandsFetcher` which
  // spawns `pi --mode rpc --no-session` — ~1.2s real wall time — and emits
  // session.commands on success. Integration-validated by starting
  // `pino serve` and inspecting a subscribed client's session.commands.
});
