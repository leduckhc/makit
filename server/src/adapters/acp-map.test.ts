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
  // `in_progress` + args present, so the mapper commits the deferred
  // `tool.call.start` (it waits for usable args before starting a row).
  const start = (id: string, kind: string): SessionUpdate =>
    ({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: id,
      kind,
      status: "in_progress",
      rawInput: { path: "x" },
    }) as SessionUpdate;
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

// Regression: pi-acp streams a tool call as an initial `tool_call` with empty
// rawInput, then fills the args in over later `tool_call_update`s. The mapper
// must DEFER `tool.call.start` until the args are ready so the app receives the
// real path/pattern (not empty args → "Read (no path)").
test("defers tool.call.start until streamed args are ready", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "r1",
    title: "read",
    kind: "read",
    status: "pending",
    rawInput: {},
  } as unknown as SessionUpdate);
  // No start yet — args not ready.
  assert.equal(events.filter((e) => e.kind === "tool.call.start").length, 0);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "r1",
    status: "pending",
    rawInput: { path: "pack" },
  } as unknown as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "r1",
    status: "in_progress",
    rawInput: { path: "package.json" },
  } as unknown as SessionUpdate);
  const starts = events.filter((e) => e.kind === "tool.call.start");
  assert.equal(starts.length, 1);
  assert.equal((starts[0]!.payload as { name: string }).name, "read");
  assert.deepEqual((starts[0]!.payload as { args: unknown }).args, { path: "package.json" });
});

// `ask_user` is answered through a separate ACP permission request that the app
// renders as a live inline ask card (SPEC-25), so no tool row may appear WHILE
// the question is open (it would duplicate the card) — but once answered the row
// must land, because the app's persisted "answered ask" card is that tool call.
test("defers the ask_user tool row until it is answered", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "a1",
    title: "ask_user",
    kind: "other",
    status: "in_progress",
    rawInput: { question: "Which language?", options: [{ title: "TypeScript" }] },
  } as unknown as SessionUpdate);
  // Question still open: nothing yet, not even the "Waiting for user input..." output.
  assert.deepEqual(events.filter((e) => e.kind.startsWith("tool.")), []);

  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "a1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "User answered: TypeScript" } }],
    rawOutput: {
      content: [{ type: "text", text: "User answered: TypeScript" }],
      details: {
        question: "Which language?",
        options: [{ title: "TypeScript" }],
        response: { kind: "selection", selections: ["TypeScript"] },
        cancelled: false,
      },
    },
  } as unknown as SessionUpdate);
  mapper.endTurn();

  const tools = events.filter((e) => e.kind.startsWith("tool."));
  assert.deepEqual(tools.map((e) => e.kind), ["tool.call.start", "tool.call.delta", "tool.call.end"]);
  const start = tools[0]!.payload as { name: string; args: unknown };
  assert.equal(start.name, "ask_user");
  assert.deepEqual(start.args, {
    question: "Which language?",
    options: [{ title: "TypeScript" }],
  });
  const end = tools[2]!.payload as { output: string; details: unknown };
  assert.equal(end.output, "User answered: TypeScript");
  // The app's answered-ask card prefers the structured `details` (cancelled
  // state, selections, comments) over parsing the output text.
  assert.deepEqual(end.details, {
    question: "Which language?",
    options: [{ title: "TypeScript" }],
    response: { kind: "selection", selections: ["TypeScript"] },
    cancelled: false,
  });
});

// The app matches renderers case-insensitively, so deferral must too — a title
// like " Ask_User " must not slip through as a second row beside the live card.
test("defers ask_user regardless of title casing or padding", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "a2",
    title: "  Ask_User  ",
    kind: "other",
    status: "in_progress",
    rawInput: { question: "Which language?" },
  } as unknown as SessionUpdate);
  assert.deepEqual(events.filter((e) => e.kind.startsWith("tool.")), []);
});

// A padded title would otherwise become the tool `name` verbatim and match no
// renderer, dropping the tool to the generic body.
test("trims a padded title so the app's renderer lookup still matches", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "r9",
    title: "  read  ",
    kind: "read",
    status: "in_progress",
    rawInput: { path: "package.json" },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "read");
});

// A subagent has no bespoke renderer; it must still reach the app so the generic
// tool body can show its description/prompt and result.
test("keeps the Agent (subagent) tool call, args and completion", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "s1",
    title: "Agent",
    kind: "other",
    status: "in_progress",
    rawInput: { description: "Count files", subagent_type: "Explore" },
  } as unknown as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "s1",
    status: "completed",
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "Agent");
  assert.equal((start!.payload as { args: { subagent_type: string } }).args.subagent_type, "Explore");
  assert.ok(events.some((e) => e.kind === "tool.call.end"));
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

test("canonicalizes an execute tool to `bash` with the command in args (command in title)", () => {
  const { events, mapper } = collect();
  // pi-acp carries the shell command in `title` and sends no rawInput for bash.
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "b1",
    title: "cd repo && pnpm test",
    kind: "execute",
    status: "in_progress",
    content: [{ type: "terminal", terminalId: "b1" }],
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "bash");
  assert.deepEqual((start!.payload as { args: unknown }).args, { command: "cd repo && pnpm test" });
});

test("canonicalizes an execute tool to `bash`, preferring rawInput.command over title", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "b2",
    title: "Run command",
    kind: "execute",
    status: "in_progress",
    rawInput: { command: "ls -la" },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "bash");
  assert.deepEqual((start!.payload as { args: unknown }).args, { command: "ls -la" });
});

test("canonicalizes execute preferring a non-blank rawInput.cmd over an empty command", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "b3",
    title: "Run command",
    kind: "execute",
    status: "in_progress",
    // command is present but blank; the valid `cmd` must not be dropped.
    rawInput: { command: "", cmd: "ls -la" },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "bash");
  assert.equal((start!.payload as { args: { command: string } }).args.command, "ls -la");
});

// The app's renderer registry keys the one-liner off (name, args): `edit`→
// "Edited <path>", `write`→"Wrote <path>", `grep`→"Grep <pattern>". pi-acp
// sends these non-bash tools with title=<toolName> + rawInput=<args>, so the
// mapper must pass the canonical name and args straight through.
test("passes an edit tool through as name `edit` with the path in args", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "e1",
    title: "edit",
    kind: "edit",
    status: "in_progress",
    rawInput: { path: "lib/foo.dart", edits: [{ oldText: "a", newText: "b" }] },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "edit");
  assert.equal((start!.payload as { args: { path: string } }).args.path, "lib/foo.dart");
});

test("passes a write tool through as name `write` with the path in args", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "w1",
    title: "write",
    kind: "edit",
    status: "in_progress",
    rawInput: { path: "out.txt", text: "hello" },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "write");
  assert.equal((start!.payload as { args: { path: string } }).args.path, "out.txt");
});

test("passes a grep tool through as name `grep` with the pattern in args", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "g1",
    title: "grep",
    kind: "other",
    status: "in_progress",
    rawInput: { pattern: "TODO", glob: "*.ts" },
  } as unknown as SessionUpdate);
  const start = events.find((e) => e.kind === "tool.call.start");
  assert.equal((start!.payload as { name: string }).name, "grep");
  assert.equal((start!.payload as { args: { pattern: string } }).args.pattern, "TODO");
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

// ---------------------------------------------------------------------------
// Assistant display media (SPEC-22). The shapes below are copied from a real
// pi-acp 0.0.32 wire capture ("read /tmp/probe-shot.png"): the image bytes are
// in `rawOutput.content[]`, NOT in the normalized ACP `content[]` (which only
// carries the "Read image file [image/png]" summary text).
// ---------------------------------------------------------------------------

/** Mapper + a fake media store recording what was ingested. */
function collectWithMedia() {
  const puts: Array<{ data: string; mime: string }> = [];
  const events: AdapterEvent[] = [];
  const mapper = new AcpEventMapper({
    emit: (e) => events.push(e),
    putMedia: (data, mime) => {
      puts.push({ data, mime });
      // Deterministic fake id per payload, mirroring content addressing.
      return { mediaId: `sha-${data}`, mime, sizeBytes: data.length };
    },
  });
  return { puts, events, mapper };
}

const imageToolResult = (callId: string, data = "AAAA"): SessionUpdate =>
  ({
    sessionUpdate: "tool_call_update",
    toolCallId: callId,
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "Read image file [image/png]" } }],
    rawOutput: {
      content: [
        { type: "text", text: "Read image file [image/png]" },
        { type: "image", data, mimeType: "image/png" },
      ],
    },
  }) as unknown as SessionUpdate;

test("an image in a tool result's rawOutput is ingested and emitted as agent.media", () => {
  const { puts, events, mapper } = collectWithMedia();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "c1",
    title: "read",
    kind: "read",
    status: "pending",
  } as SessionUpdate);
  mapper.handle(imageToolResult("c1"));

  assert.deepEqual(puts, [{ data: "AAAA", mime: "image/png" }]);
  const media = events.filter((e) => e.kind === "agent.media");
  assert.equal(media.length, 1);
  assert.deepEqual(media[0].payload, {
    mediaId: "sha-AAAA",
    mime: "image/png",
    kind: "image",
    sizeBytes: 4,
    callId: "c1",
  });
  // The media event precedes the tool's end so the transcript stays in order.
  const kinds = events.map((e) => e.kind);
  assert.ok(kinds.indexOf("agent.media") < kinds.indexOf("tool.call.end"));
  // The text summary still drives the collapsed tool card.
  const end = events.find((e) => e.kind === "tool.call.end")!.payload as { output: string };
  assert.match(end.output, /Read image file/);
});

test("an image block in the normalized ACP content[] is ingested too", () => {
  const { puts, events, mapper } = collectWithMedia();
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "c2",
    status: "completed",
    content: [{ type: "content", content: { type: "image", data: "BBBB", mimeType: "image/gif" } }],
  } as unknown as SessionUpdate);

  assert.deepEqual(puts, [{ data: "BBBB", mime: "image/gif" }]);
  assert.equal(events.filter((e) => e.kind === "agent.media").length, 1);
});

test("the same image seen on repeated updates is emitted once per tool call", () => {
  const { puts, events, mapper } = collectWithMedia();
  // Cumulative updates re-send rawOutput; content addressing must not produce
  // a duplicate bubble in the transcript.
  mapper.handle(imageToolResult("c3"));
  mapper.handle(imageToolResult("c3"));

  assert.equal(events.filter((e) => e.kind === "agent.media").length, 1);
  assert.equal(puts.length, 1);
});

test("an image in an agent message chunk is ingested and does not break text", () => {
  const { events, mapper } = collectWithMedia();
  mapper.handle({
    sessionUpdate: "agent_message_chunk",
    content: { type: "image", data: "CCCC", mimeType: "image/png" },
  } as unknown as SessionUpdate);
  mapper.handle(text("after"));
  mapper.endTurn();

  assert.equal(events.filter((e) => e.kind === "agent.media").length, 1);
  const final = events.find((e) => e.kind === "agent.message")!.payload as { text: string };
  assert.equal(final.text, "after");
});

test("with no media hook (or a rejected blob) nothing is emitted and text is unaffected", () => {
  const events: AdapterEvent[] = [];
  const mapper = new AcpEventMapper({ emit: (e) => events.push(e) }); // no putMedia
  mapper.handle(imageToolResult("c4"));
  assert.equal(events.some((e) => e.kind === "agent.media"), false);

  const rejected: AdapterEvent[] = [];
  const strict = new AcpEventMapper({
    emit: (e) => rejected.push(e),
    putMedia: () => null, // over cap / disallowed mime
  });
  strict.handle(imageToolResult("c5"));
  assert.equal(rejected.some((e) => e.kind === "agent.media"), false);
  assert.equal(rejected.some((e) => e.kind === "tool.call.end"), true, "the tool still completes");
});

test("a local image path in the final agent message is rewritten to a media URI", () => {
  const events: AdapterEvent[] = [];
  const mapper = new AcpEventMapper({
    emit: (e) => events.push(e),
    rewriteMedia: (t) => t.replace("/tmp/out2.png)", "makit-media:deadbeef)"),
  });
  mapper.handle(text("see ![shot](/tmp/out2.png)"));
  mapper.endTurn();

  const final = events.find((e) => e.kind === "agent.message")!.payload as { text: string };
  assert.equal(final.text, "see ![shot](makit-media:deadbeef)");
  // Deltas stream raw (nothing is buffered for a rewrite that may never apply).
  const delta = events.find((e) => e.kind === "agent.message.delta")!.payload as { chunk: string };
  assert.equal(delta.chunk, "see ![shot](/tmp/out2.png)");
});

// A start with no end leaves the app's tool row spinning forever, so a turn that
// dies mid-tool (abort/refusal) must still close every tool it opened.
test("endTurn closes a tool that never completed instead of leaving it running", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "t1",
    title: "read",
    kind: "read",
    status: "in_progress",
    rawInput: { path: "package.json" },
  } as unknown as SessionUpdate);
  mapper.endTurn();
  const kinds = events.filter((e) => e.kind.startsWith("tool.")).map((e) => e.kind);
  assert.deepEqual(kinds, ["tool.call.start", "tool.call.end"]);
  const end = events.find((e) => e.kind === "tool.call.end");
  assert.equal((end!.payload as { exitCode: number }).exitCode, 1);
});

// Regression for the ordering assumption: an agent that flips to `in_progress`
// BEFORE it finishes streaming rawInput must still produce a row with real args,
// not the empty-args "Read (no path)" render this PR set out to kill.
test("waits for args even when in_progress arrives before them", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "r2",
    title: "read",
    kind: "read",
    status: "in_progress",
    rawInput: {},
  } as unknown as SessionUpdate);
  assert.equal(events.filter((e) => e.kind === "tool.call.start").length, 0);
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "r2",
    status: "in_progress",
    rawInput: { path: "package.json" },
  } as unknown as SessionUpdate);
  const starts = events.filter((e) => e.kind === "tool.call.start");
  assert.equal(starts.length, 1);
  assert.deepEqual((starts[0]!.payload as { args: unknown }).args, { path: "package.json" });
});

// …but a tool that never gets args must never be lost: completion always starts it.
test("still emits a tool that completes without ever streaming args", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "n1",
    title: "pwd_tool",
    kind: "other",
    status: "completed",
  } as unknown as SessionUpdate);
  const kinds = events.filter((e) => e.kind.startsWith("tool.")).map((e) => e.kind);
  assert.deepEqual(kinds, ["tool.call.start", "tool.call.end"]);
});

// A turn that dies while a tool is still waiting on its args: the tool never ran,
// so an empty-args "failed" row would be pure noise.
test("endTurn drops a tool that never got args, keeps one that did", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "p1",
    title: "read",
    kind: "read",
    status: "pending",
    rawInput: {},
  } as unknown as SessionUpdate);
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "p2",
    title: "read",
    kind: "read",
    status: "pending",
    rawInput: { path: "lib/foo.dart" },
  } as unknown as SessionUpdate);
  mapper.endTurn();
  const tools = events.filter((e) => e.kind.startsWith("tool."));
  assert.deepEqual(
    tools.map((e) => [e.kind, (e.payload as { callId: string }).callId]),
    [
      ["tool.call.start", "p2"],
      ["tool.call.end", "p2"],
    ],
  );
});

// Output can arrive before args. `tool.call.start` is immutable in the app, so
// starting on output alone would pin an empty-args row ("Read (no path)") that a
// later rawInput can never amend. The buffered output must survive the wait.
test("output before args does not start the row, and is replayed after it", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "o1",
    title: "read",
    kind: "read",
    status: "in_progress",
    rawInput: {},
    content: [{ type: "content", content: { type: "text", text: "early output" } }],
  } as unknown as SessionUpdate);
  assert.deepEqual(events.filter((e) => e.kind.startsWith("tool.")), []);

  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "o1",
    status: "in_progress",
    rawInput: { path: "package.json" },
  } as unknown as SessionUpdate);
  const tool = events.filter((e) => e.kind.startsWith("tool."));
  assert.deepEqual(tool.map((e) => e.kind), ["tool.call.start", "tool.call.delta"]);
  assert.deepEqual((tool[0]!.payload as { args: unknown }).args, { path: "package.json" });
  assert.equal((tool[1]!.payload as { chunk: string }).chunk, "early output");

  // …and the output is not duplicated when the same cumulative text repeats.
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "o1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "early output" } }],
  } as unknown as SessionUpdate);
  const end = events.find((e) => e.kind === "tool.call.end");
  assert.equal((end!.payload as { output: string }).output, "early output");
  assert.equal(events.filter((e) => e.kind === "tool.call.delta").length, 1);
});

// A tool that only ever produced output (no args, no terminal status) must still
// be surfaced and closed when the turn ends, not dropped.
test("endTurn keeps an args-less tool that produced output", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "o2",
    title: "mystery",
    kind: "other",
    status: "pending",
    content: [{ type: "content", content: { type: "text", text: "some output" } }],
  } as unknown as SessionUpdate);
  mapper.endTurn();
  assert.deepEqual(
    events.filter((e) => e.kind.startsWith("tool.")).map((e) => e.kind),
    ["tool.call.start", "tool.call.delta", "tool.call.end"],
  );
});

// An array rawInput yields `{}` from canonicalizeTool, so it must not count as
// usable args — otherwise the row starts empty, the bug this defers to avoid.
test("an array rawInput does not count as usable args", () => {
  const { events, mapper } = collect();
  mapper.handle({
    sessionUpdate: "tool_call",
    toolCallId: "arr",
    title: "read",
    kind: "read",
    status: "in_progress",
    rawInput: ["package.json"],
  } as unknown as SessionUpdate);
  assert.deepEqual(events.filter((e) => e.kind === "tool.call.start"), []);
});

test("two same-length images that diverge late are both announced", () => {
  const { events, puts, mapper } = collectWithMedia();
  // Same collision class as the codex path: length + a fixed-length prefix is
  // not an identity. The cumulative-update guard must stay, but keyed exactly.
  const a = "y".repeat(70) + "AAAA";
  const b = "y".repeat(70) + "BBBB";
  mapper.handle({
    sessionUpdate: "tool_call_update",
    toolCallId: "c9",
    status: "completed",
    content: [
      { type: "content", content: { type: "image", data: a, mimeType: "image/png" } },
      { type: "content", content: { type: "image", data: b, mimeType: "image/png" } },
    ],
  } as never);
  assert.deepEqual(puts.map((p) => p.data), [a, b], "both payloads must reach the store");
  assert.equal(events.filter((e) => e.kind === "agent.media").length, 2);
});
