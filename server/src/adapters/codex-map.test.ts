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
  assert.equal((start.payload as any).name, "bash");
  assert.deepEqual((start.payload as any).args, { command: "ls -la", cwd: "/tmp" });
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

test("reasoning with a string summary (not array) does not throw and still emits thinking", () => {
  const { events, mapper } = collect();
  mapper.handle("item/completed", { item: { type: "reasoning", id: "r9", summary: "just a string" } });
  assert.equal((events.find((e) => e.kind === "agent.thinking")!.payload as any).text, "just a string");
});

test("thread/name/updated surfaces a title; error surfaces session.error", () => {
  const { events, titles, mapper } = collect();
  mapper.handle("thread/name/updated", { threadId: "th", threadName: "My thread" });
  mapper.handle("error", { error: { message: "boom" }, willRetry: false });
  assert.deepEqual(titles, ["My thread"]);
  assert.equal((events.find((e) => e.kind === "session.error")!.payload as any).message, "boom");
});

// ---------- MCP tool-result media (SPEC-assistant-display-media parity with the ACP path) --------

/** A `cua-driver`-shaped screenshot result: text summary + an image block. */
function captureResult(callId: string, data: string) {
  return {
    item: {
      type: "mcpToolCall",
      id: callId,
      server: "cua_driver",
      tool: "computer_use",
      arguments: { action: "capture" },
      result: {
        content: [
          { type: "text", text: "captured 1 display" },
          { type: "image", data, mimeType: "image/png" },
        ],
      },
    },
  };
}

function collectWithMedia() {
  const events: AdapterEvent[] = [];
  const puts: { data: string; mime: string }[] = [];
  const mapper = new CodexEventMapper({
    emit: (e) => events.push(e),
    putMedia: (data, mime) => {
      puts.push({ data, mime });
      return { mediaId: `sha-${data}`, mime, sizeBytes: data.length };
    },
  });
  return { events, puts, mapper };
}

test("stores images from an MCP tool result and emits agent.media before tool.call.end", () => {
  const { events, puts, mapper } = collectWithMedia();
  mapper.handle("item/completed", captureResult("t1", "AAAA"));

  assert.deepEqual(puts, [{ data: "AAAA", mime: "image/png" }]);
  const media = events.find((e) => e.kind === "agent.media")!;
  assert.equal((media.payload as any).mediaId, "sha-AAAA");
  assert.equal((media.payload as any).kind, "image");
  assert.equal((media.payload as any).callId, "t1");
  assert.ok(
    events.indexOf(media) < events.findIndex((e) => e.kind === "tool.call.end"),
    "media is announced before the tool completes",
  );
  // The text half of the result still lands as the tool output.
  assert.equal((events.find((e) => e.kind === "tool.call.end")!.payload as any).output, "captured 1 display");
});

test("a refused or absent media sink never blocks the tool result", () => {
  const noSink: AdapterEvent[] = [];
  new CodexEventMapper({ emit: (e) => noSink.push(e) }).handle("item/completed", captureResult("t2", "BBBB"));
  assert.equal(noSink.some((e) => e.kind === "agent.media"), false);
  assert.equal(noSink.some((e) => e.kind === "tool.call.end"), true);

  const refused: AdapterEvent[] = [];
  new CodexEventMapper({ emit: (e) => refused.push(e), putMedia: () => null }).handle(
    "item/completed",
    captureResult("t3", "CCCC"),
  );
  assert.equal(refused.some((e) => e.kind === "agent.media"), false);
  assert.equal(refused.some((e) => e.kind === "tool.call.end"), true);
});

test("the same blob is announced once, a new blob is announced again", () => {
  const { events, puts, mapper } = collectWithMedia();
  mapper.handle("item/completed", captureResult("t4", "AAAA"));
  mapper.handle("item/completed", captureResult("t5", "AAAA"));
  mapper.handle("item/completed", captureResult("t6", "DDDD"));
  assert.deepEqual(
    events.filter((e) => e.kind === "agent.media").map((e) => (e.payload as any).mediaId),
    ["sha-AAAA", "sha-DDDD"],
  );
  // The store is content-addressed, so re-putting identical bytes from a
  // different call is an idempotent no-op that resolves to the same id — the
  // *event* is what gets deduped, exactly as on the ACP path.
  assert.equal(puts.length, 3);
});

test("two same-length images that diverge late are both announced", () => {
  const { events, puts, mapper } = collectWithMedia();
  // Real captures of one display share a byte-identical PNG header + IHDR, so a
  // dedup key built from length + a fixed-length prefix collides and silently
  // drops the second image.
  const a = "x".repeat(70) + "AAAA";
  const b = "x".repeat(70) + "BBBB";
  mapper.handle("item/completed", {
    item: {
      type: "mcpToolCall",
      id: "t7",
      server: "cua_driver",
      tool: "get_desktop_state",
      result: {
        content: [
          { type: "image", data: a, mimeType: "image/png" },
          { type: "image", data: b, mimeType: "image/png" },
        ],
      },
    },
  });
  assert.deepEqual(puts.map((p) => p.data), [a, b], "both payloads must reach the store");
  assert.deepEqual(
    events.filter((e) => e.kind === "agent.media").map((e) => (e.payload as any).mediaId),
    ["sha-" + a, "sha-" + b],
  );
});

// ---- SPEC-context-usage: context usage -------------------------------------------------

/**
 * Payload shape + numbers taken from a real `codex app-server` spike (two turns
 * on the default model), so the assertions below are ground truth rather than a
 * guess at the schema.
 */
const TOKEN_USAGE_TURN2 = {
  threadId: "th1",
  turnId: "t2",
  tokenUsage: {
    total: {
      totalTokens: 39000,
      inputTokens: 38990,
      cachedInputTokens: 19200,
      cacheWriteInputTokens: 0,
      outputTokens: 10,
      reasoningOutputTokens: 0,
    },
    last: {
      totalTokens: 19508,
      inputTokens: 19503,
      cachedInputTokens: 19200,
      cacheWriteInputTokens: 0,
      outputTokens: 5,
      reasoningOutputTokens: 0,
    },
    modelContextWindow: 258400,
  },
};

test("maps thread/tokenUsage/updated to session.usage with the window", () => {
  const { events, mapper } = collect();
  mapper.handle("thread/tokenUsage/updated", TOKEN_USAGE_TURN2);

  const usage = events.filter((e) => e.kind === "session.usage");
  assert.equal(usage.length, 1, "one snapshot per notification");
  const p = usage[0].payload as any;
  assert.equal(p.contextWindow, 258400);
  assert.equal(typeof p.measuredAt, "number");
});

test("context occupancy is the LAST request's total, not the session total", () => {
  // The regression this guards: `total` accumulates across turns, so drawing it
  // against the window reads ~15% full when the context is ~7.5% full, and
  // crosses 100% on a long session that never neared compaction.
  const { events, mapper } = collect();
  mapper.handle("thread/tokenUsage/updated", TOKEN_USAGE_TURN2);

  const p = events.find((e) => e.kind === "session.usage")!.payload as any;
  assert.equal(p.contextTokens, 19508, "must be last.totalTokens");
  assert.notEqual(p.contextTokens, 39000, "must NOT be total.totalTokens");
});

test("carries cumulative totals separately for billing", () => {
  const { events, mapper } = collect();
  mapper.handle("thread/tokenUsage/updated", TOKEN_USAGE_TURN2);

  const p = events.find((e) => e.kind === "session.usage")!.payload as any;
  assert.deepEqual(p.totals, {
    total: 39000,
    input: 38990,
    cachedInput: 19200,
    cacheWrite: 0,
    output: 10,
    reasoning: 0,
  });
});

test("omits contextWindow when codex reports none rather than sending 0", () => {
  // A zeroed window would render as a full bar; unknown must stay unknown.
  const { events, mapper } = collect();
  mapper.handle("thread/tokenUsage/updated", {
    ...TOKEN_USAGE_TURN2,
    tokenUsage: { ...TOKEN_USAGE_TURN2.tokenUsage, modelContextWindow: null },
  });

  const p = events.find((e) => e.kind === "session.usage")!.payload as any;
  assert.ok(!("contextWindow" in p), "absent, not zero");
  assert.equal(p.contextTokens, 19508);
});

test("ignores a malformed tokenUsage instead of emitting a hollow snapshot", () => {
  const { events, mapper } = collect();
  mapper.handle("thread/tokenUsage/updated", { threadId: "th1", turnId: "t1" });
  assert.equal(events.filter((e) => e.kind === "session.usage").length, 0);
});
