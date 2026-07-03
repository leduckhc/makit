import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, appendFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MirrorAdapter, type PaneWriter } from "./mirror.js";
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
