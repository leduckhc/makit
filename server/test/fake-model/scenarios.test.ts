import { test } from "node:test";
import assert from "node:assert/strict";
import { chooseScenario, toSseLines } from "./scenarios.js";

/**
 * The fake model is the deterministic LLM behind the real-pi e2e. These guard
 * the two invariants the integration relies on: (1) prompts map to a stable
 * scenario, and (2) each scenario serializes to well-formed OpenAI
 * chat-completions SSE that pi's openai-completions client can parse.
 */

test("default prompt → deterministic text scenario, no tool call", () => {
  const s = chooseScenario("hello there");
  assert.equal(s.name, "text");
  assert.ok(s.textDeltas.length > 0);
  assert.equal(s.toolCall, undefined);
  assert.equal(s.finishReason, "stop");
  assert.equal(s.textDeltas.join(""), "makit e2e ok");
});

test("[[tool]] marker → tool-call scenario", () => {
  const s = chooseScenario("please [[tool]] now");
  assert.equal(s.name, "tool");
  assert.equal(s.finishReason, "tool_calls");
  assert.ok(s.toolCall);
  assert.equal(s.toolCall?.name, "ls");
});

test("marker match is case-insensitive", () => {
  assert.equal(chooseScenario("[[TOOL]]").name, "tool");
});

test("toSseLines emits role, content, finish and [DONE] terminator", () => {
  const lines = toSseLines(chooseScenario("hi"), "fake-1", () => 1_700_000_000_000);
  // First data chunk announces the assistant role.
  const chunks = lines
    .filter((l) => l.startsWith("data: ") && !l.includes("[DONE]"))
    .map((l) => JSON.parse(l.slice("data: ".length)));
  assert.equal(chunks[0]?.choices[0].delta.role, "assistant");
  // Concatenated content deltas reconstruct the reply.
  const text = chunks
    .map((c) => c.choices[0].delta.content ?? "")
    .join("");
  assert.equal(text, "makit e2e ok");
  // A chunk carries the terminal finish_reason.
  assert.ok(chunks.some((c) => c.choices[0].finish_reason === "stop"));
  // SSE stream is [DONE]-terminated.
  assert.equal(lines.at(-1), "data: [DONE]\n\n");
  // Chunk shape pi expects.
  assert.equal(chunks[0]?.object, "chat.completion.chunk");
  assert.equal(chunks[0]?.model, "fake-1");
});

test("tool scenario serializes a tool_calls delta with finish_reason tool_calls", () => {
  const lines = toSseLines(chooseScenario("[[tool]]"), "fake-1");
  const chunks = lines
    .filter((l) => l.startsWith("data: ") && !l.includes("[DONE]"))
    .map((l) => JSON.parse(l.slice("data: ".length)));
  const toolChunk = chunks.find((c) => c.choices[0].delta.tool_calls);
  assert.ok(toolChunk, "expected a tool_calls delta");
  assert.equal(toolChunk.choices[0].delta.tool_calls[0].function.name, "ls");
  assert.ok(chunks.some((c) => c.choices[0].finish_reason === "tool_calls"));
});
