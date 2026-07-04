import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  decodeFrame,
  decodeSessionEvent,
  encodeEvent,
  encodeFrame,
  WireErrorCode,
} from "../../src/protocol/codec.js";
import type { SessionEvent } from "../../src/protocol.js";

const here = dirname(fileURLToPath(import.meta.url));
const fixtures = join(here, "..", "fixtures");

function load(name: string): unknown[] {
  return JSON.parse(readFileSync(join(fixtures, name), "utf8"));
}

const frames = load("frames.json") as Record<string, unknown>[];
const snapshots = load("snapshots.json") as Record<string, unknown>[];
const events = load("events.json") as SessionEvent[];

test("frames.json covers every MsgType exactly once", () => {
  const seen = new Set(frames.map((f) => f.t as string));
  assert.deepEqual(
    [...seen].sort(),
    [
      "ack",
      "cmd",
      "err",
      "event",
      "hello",
      "hello.ack",
      "ping",
      "pong",
      "presence",
      "srv.request",
      "srv.response",
      "sub",
      "unsub",
    ],
  );
});

test("events.json covers every EventKind exactly once", () => {
  const seen = new Set(events.map((e) => e.kind));
  assert.deepEqual(
    [...seen].sort(),
    [
      "agent.message",
      "agent.message.delta",
      "agent.thinking",
      "session.action_error",
      "session.commands",
      "session.error",
      "session.meta",
      "session.status",
      "tool.call.delta",
      "tool.call.end",
      "tool.call.start",
      "user.message",
    ],
  );
});

test("frames round-trip decode → encode (both directions)", () => {
  for (const frame of [...frames, ...snapshots]) {
    const raw = JSON.stringify(frame);
    const decoded = decodeFrame(raw);
    assert.notEqual(decoded, null, `decodeFrame returned null for ${frame.t}`);
    // decode → encode → parse must equal the original frame.
    assert.deepEqual(JSON.parse(encodeFrame(decoded!)), frame);
  }
});

test("session events round-trip decode → encode (both directions)", () => {
  for (const event of events) {
    const decoded = decodeSessionEvent(event);
    assert.notEqual(decoded, null, `decodeSessionEvent null for ${event.kind}`);
    assert.deepEqual(decoded, event);
    // encode → decode is the inverse.
    assert.deepEqual(encodeEvent(decoded!), event);
  }
});

test("decodeFrame rejects malformed input without throwing", () => {
  assert.equal(decodeFrame("not json"), null);
  assert.equal(decodeFrame("[]"), null);
  assert.equal(decodeFrame(JSON.stringify({ t: "nope", id: "x", v: 1 })), null);
  assert.equal(decodeFrame(JSON.stringify({ t: "ack", v: 1 })), null); // no id
  assert.equal(decodeFrame(JSON.stringify({ t: "ack", id: "x" })), null); // no v
});

test("decodeSessionEvent rejects malformed input without throwing", () => {
  assert.equal(decodeSessionEvent(null), null);
  assert.equal(decodeSessionEvent({ seq: 1 }), null);
  assert.equal(
    decodeSessionEvent({ seq: 1, sessionId: "s", ts: 1, kind: "nope", payload: {} }),
    null,
  );
  assert.equal(
    decodeSessionEvent({ seq: 1, sessionId: "s", ts: 1, kind: "user.message" }),
    null, // no payload
  );
});

test("WireErrorCode exposes canonical codes", () => {
  assert.equal(WireErrorCode.Unauthorized, "unauthorized");
  assert.equal(WireErrorCode.NoSuchSession, "no_such_session");
  assert.equal(WireErrorCode.BadRequest, "bad_request");
});
