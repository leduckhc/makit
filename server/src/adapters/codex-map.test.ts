import { test } from "node:test";
import assert from "node:assert/strict";
import { CodexEventMapper } from "./codex-map.js";
import type { AdapterEvent } from "./adapter.js";

function collect() {
  const events: AdapterEvent[] = [];
  const titles: string[] = [];
  const mapper = new CodexEventMapper({ emit: (e) => events.push(e), onTitle: (t) => titles.push(t) });
  return { events, titles, mapper };
}

test("streams agent message deltas + finalizes on item/completed with itemId as msgId", () => {
  const { events, mapper } = collect();
  mapper.handle("item/agentMessage/delta", { itemId: "m1", delta: "Hel" });
  mapper.handle("item/agentMessage/delta", { itemId: "m1", delta: "lo" });
  mapper.handle("item/completed", { item: { type: "agentMessage", id: "m1", text: "Hello" } });

  const deltas = events.filter((e) => e.kind === "agent.message.delta");
  assert.deepEqual(deltas.map((d) => (d.payload as any).chunk), ["Hel", "lo"]);
  assert.equal((deltas[0].payload as any).msgId, "m1");
  const final = events.find((e) => e.kind === "agent.message")!;
  assert.equal((final.payload as any).text, "Hello");
  assert.equal((final.payload as any).msgId, "m1");
});

test("maps reasoning to the thinking stream", () => {
  const { events, mapper } = collect();
  mapper.handle("item/reasoning/textDelta", { itemId: "r1", delta: "thinking" });
  mapper.handle("item/completed", { item: { type: "reasoning", id: "r1", content: ["thinking hard"] } });
  assert.equal((events.find((e) => e.kind === "agent.thinking.delta")!.payload as any).thinkId, "r1");
  assert.equal((events.find((e) => e.kind === "agent.thinking")!.payload as any).text, "thinking hard");
});

test("maps a command execution lifecycle to tool.call.* with exit code", () => {
  const { events, mapper } = collect();
  mapper.handle("item/started", {
    item: { type: "commandExecution", id: "c1", command: "ls -la", cwd: "/tmp", status: "inProgress" },
  });
  mapper.handle("item/commandExecution/outputDelta", { itemId: "c1", delta: "total 0\n" });
  mapper.handle("item/completed", {
    item: { type: "commandExecution", id: "c1", command: "ls -la", status: "completed", exitCode: 0, aggregatedOutput: "total 0\n" },
  });

  const start = events.find((e) => e.kind === "tool.call.start")!;
  assert.equal((start.payload as any).name, "ls -la");
  assert.equal((start.payload as any).risk, "risky");
  assert.equal((events.find((e) => e.kind === "tool.call.delta")!.payload as any).chunk, "total 0\n");
  const end = events.find((e) => e.kind === "tool.call.end")!;
  assert.equal((end.payload as any).exitCode, 0);
  assert.equal((end.payload as any).output, "total 0\n");
});

test("a failed command yields exitCode 1 and emits start even without item/started", () => {
  const { events, mapper } = collect();
  mapper.handle("item/completed", {
    item: { type: "commandExecution", id: "c2", command: "false", status: "failed" },
  });
  assert.ok(events.find((e) => e.kind === "tool.call.start"));
  assert.equal((events.find((e) => e.kind === "tool.call.end")!.payload as any).exitCode, 1);
});

test("fileChange completion is a risky tool call summarizing paths", () => {
  const { events, mapper } = collect();
  mapper.handle("item/completed", {
    item: { type: "fileChange", id: "f1", status: "completed", changes: [{ path: "a.txt" }, { path: "b.txt" }] },
  });
  const start = events.find((e) => e.kind === "tool.call.start")!;
  assert.equal((start.payload as any).name, "apply_patch");
  assert.equal((start.payload as any).risk, "risky");
  assert.match((events.find((e) => e.kind === "tool.call.end")!.payload as any).output, /a\.txt/);
});

test("thread/name/updated surfaces a title; error surfaces session.error", () => {
  const { events, titles, mapper } = collect();
  mapper.handle("thread/name/updated", { threadId: "th", threadName: "My thread" });
  mapper.handle("error", { error: { message: "boom" }, willRetry: false });
  assert.deepEqual(titles, ["My thread"]);
  assert.equal((events.find((e) => e.kind === "session.error")!.payload as any).message, "boom");
});
