import { test } from "node:test";
import assert from "node:assert/strict";
import type { SessionUpdate } from "@agentclientprotocol/sdk";
import { AcpEventMapper } from "./acp-map.js";
import type { AdapterEvent } from "./adapter.js";

function collect() {
  const events: AdapterEvent[] = [];
  const titles: string[] = [];
  const mapper = new AcpEventMapper({
    emit: (e) => events.push(e),
    onTitle: (t) => titles.push(t),
  });
  return { events, titles, mapper };
}

const text = (t: string): SessionUpdate =>
  ({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: t } }) as SessionUpdate;
const thought = (t: string): SessionUpdate =>
  ({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: t } }) as SessionUpdate;

test("streams agent text as deltas then a final message with a stable msgId", () => {
  const { events, mapper } = collect();
  mapper.handle(text("Hel"));
  mapper.handle(text("lo"));
  mapper.endTurn();

  const deltas = events.filter((e) => e.kind === "agent.message.delta");
  assert.equal(deltas.length, 2);
  assert.deepEqual(
    deltas.map((d) => (d.payload as { chunk: string }).chunk),
    ["Hel", "lo"],
  );
  const finals = events.filter((e) => e.kind === "agent.message");
  assert.equal(finals.length, 1);
  const final = finals[0].payload as { text: string; msgId: string };
  assert.equal(final.text, "Hello");
  // The msgId ties the deltas to the final message.
  const deltaMsgId = (deltas[0].payload as { msgId: string }).msgId;
  assert.equal(final.msgId, deltaMsgId);
  assert.equal((deltas[1].payload as { msgId: string }).msgId, deltaMsgId);
});

test("keeps thinking and message as separate streams", () => {
  const { events, mapper } = collect();
  mapper.handle(thought("reasoning"));
  mapper.handle(text("answer"));
  mapper.endTurn();

  const kinds = events.map((e) => e.kind);
  // thinking finalizes before the message text starts (flush-on-switch).
  assert.deepEqual(kinds, [
    "agent.thinking.delta",
    "agent.thinking",
    "agent.message.delta",
    "agent.message",
  ]);
});

test("maps a tool call lifecycle: start, output delta, end", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "t1",
    title: "read",
    kind: "read",
    status: "in_progress",
    rawInput: { path: "a.txt" },
  } as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "t1",
    status: "in_progress",
    content: [{ type: "content", content: { type: "text", text: "file body" } }],
  } as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "t1",
    status: "completed",
  } as SessionUpdate);

  const start = events.find((e) => e.kind === "tool.call.start");
  assert.ok(start);
  assert.equal((start!.payload as { name: string }).name, "read");
  assert.equal((start!.payload as { risk: string }).risk, "safe");
  assert.deepEqual((start!.payload as { args: unknown }).args, { path: "a.txt" });

  const delta = events.find((e) => e.kind === "tool.call.delta");
  assert.equal((delta!.payload as { chunk: string }).chunk, "file body");

  const end = events.find((e) => e.kind === "tool.call.end");
  assert.equal((end!.payload as { exitCode: number }).exitCode, 0);
  assert.equal((end!.payload as { output: string }).output, "file body");
});

test("classifies risk by tool kind", () => {
  const { events, mapper } = collect();
  const start = (id: string, kind: string): SessionUpdate =>
    ({ sessionUpdate: "tool_call", toolCallId: id, title: id, kind, status: "pending" }) as SessionUpdate;
  mapper.handle(start("r", "read"));
  mapper.handle(start("e", "edit"));
  mapper.handle(start("x", "execute"));
  mapper.handle(start("d", "delete"));
  const risks = Object.fromEntries(
    events
      .filter((e) => e.kind === "tool.call.start")
      .map((e) => [(e.payload as { callId: string }).callId, (e.payload as { risk: string }).risk]),
  );
  assert.deepEqual(risks, { r: "safe", e: "risky", x: "risky", d: "destructive" });
});

test("reads bash output and exit code from terminal _meta", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "b1",
    title: "ls -la",
    kind: "execute",
    status: "in_progress",
    content: [{ type: "terminal", terminalId: "b1" }],
    _meta: { terminal_info: { terminal_id: "b1", cwd: "/tmp" } },
  } as unknown as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "b1",
    status: "in_progress",
    _meta: { terminal_output: { terminal_id: "b1", data: "total 0\n" } },
  } as unknown as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "b1",
    status: "completed",
    _meta: { terminal_exit: { terminal_id: "b1", exit_code: 0 } },
  } as unknown as SessionUpdate);

  const delta = events.find((e) => e.kind === "tool.call.delta");
  assert.equal((delta!.payload as { chunk: string }).chunk, "total 0\n");
  const end = events.find((e) => e.kind === "tool.call.end");
  assert.equal((end!.payload as { exitCode: number }).exitCode, 0);
});

test("emits a failed tool call with exitCode 1", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "t1",
    title: "bash",
    kind: "execute",
    status: "in_progress",
  } as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "t1",
    status: "failed",
    content: [{ type: "content", content: { type: "text", text: "boom" } }],
  } as SessionUpdate);
  const end = events.find((e) => e.kind === "tool.call.end");
  assert.equal((end!.payload as { exitCode: number }).exitCode, 1);
});

test("maps available_commands_update to session.commands", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "available_commands_update",
    availableCommands: [
      { name: "compact", description: "Compact the session" },
      { name: "skill:foo", description: "" },
    ],
  } as SessionUpdate);
  const cmds = events.find((e) => e.kind === "session.commands");
  assert.ok(cmds);
  assert.deepEqual((cmds!.payload as { commands: unknown[] }).commands, [
    { name: "compact", description: "Compact the session", source: "command" },
    { name: "skill:foo", description: "", source: "command" },
  ]);
});

test("surfaces a session_info_update title via onTitle", () => {
  const { titles, mapper } = collect();
  mapper.handle({
    sessionUpdate: "session_info_update",
    title: "My session",
  } as SessionUpdate);
  assert.deepEqual(titles, ["My session"]);
});

test("maps user_message_chunk to user.message (history replay)", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "user_message_chunk",
    content: { type: "text", text: "hi there" },
  } as SessionUpdate);
  const um = events.find((e) => e.kind === "user.message");
  assert.equal((um!.payload as { text: string }).text, "hi there");
});
