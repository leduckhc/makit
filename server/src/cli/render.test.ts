import { test } from "node:test";
import assert from "node:assert/strict";
import { renderEvent, type RenderState } from "./render.js";
import type { SessionEvent, EventKind } from "../protocol.js";

function ev(kind: EventKind, payload: Record<string, unknown>): SessionEvent {
  return { seq: 1, sessionId: "s", ts: 0, kind, payload };
}

test("user.message renders with a 'you' prefix and the text", () => {
  const { out } = renderEvent(ev("user.message", { text: "hello" }), {});
  assert.match(out, /you/);
  assert.match(out, /hello/);
});

test("streaming deltas print prefix once, then bare chunks", () => {
  let st: RenderState = {};
  const a = renderEvent(ev("agent.message.delta", { msgId: "m1", chunk: "Hel" }), st);
  assert.match(a.out, /pi/);
  assert.match(a.out, /Hel/);
  assert.equal(a.st.streamingMsgId, "m1");
  assert.equal(a.st.midLine, true);

  const b = renderEvent(ev("agent.message.delta", { msgId: "m1", chunk: "lo" }), a.st);
  assert.equal(b.out, "lo"); // no prefix, just the chunk
  assert.equal(b.st.midLine, true);
});

test("agent.message finalizing a streamed msgId does NOT reprint the text", () => {
  const st: RenderState = { streamingMsgId: "m1", midLine: true };
  const { out } = renderEvent(ev("agent.message", { msgId: "m1", text: "Hello" }), st);
  assert.equal(out, "\n"); // just closes the line
  assert.doesNotMatch(out, /Hello/);
});

test("non-streamed agent.message prints the text", () => {
  const { out } = renderEvent(ev("agent.message", { text: "done" }), {});
  assert.match(out, /done/);
});

test("a non-delta event after a mid-line stream closes the open line first", () => {
  const st: RenderState = { streamingMsgId: "m1", midLine: true };
  const { out } = renderEvent(ev("session.status", { status: "idle" }), st);
  assert.ok(out.startsWith("\n"), "should prepend a newline to close the stream line");
  assert.match(out, /idle/);
});

test("thinking is rendered as a dim one-liner", () => {
  const { out } = renderEvent(ev("agent.thinking", { text: "let me think about this" }), {});
  assert.match(out, /think/);
  assert.match(out, /\x1b\[2m/); // dim
});

test("tool.call.end marks failures differently", () => {
  const ok = renderEvent(ev("tool.call.end", { exitCode: 0, summary: "fine" }), {});
  const bad = renderEvent(ev("tool.call.end", { exitCode: 1, summary: "boom" }), {});
  assert.match(ok.out, /✓/);
  assert.match(bad.out, /✗/);
});

test("ignored kinds produce no output and preserve state", () => {
  const st: RenderState = { streamingMsgId: "m1", midLine: true };
  const { out, st: next } = renderEvent(ev("tool.call.delta", { chunk: "x" }), st);
  assert.equal(out, "");
  assert.equal(next.streamingMsgId, "m1");
});
