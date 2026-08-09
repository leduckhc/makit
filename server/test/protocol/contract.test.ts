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
import type { PortDTO, SessionEvent } from "../../src/protocol.js";

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
      "agent.media",
      "agent.message",
      "agent.message.delta",
      "agent.thinking",
      "agent.thinking.delta",
      "session.action_error",
      "session.commands",
      "session.error",
      "session.meta",
      "session.status",
      "session.usage",
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

// ── SPEC-41 ────────────────────────────────────────────────────────────────
// `ports.snapshot` is a HOST-WIDE broadcast, so it lives in snapshots.json (the
// frame fixtures) and must be rejected by `decodeSessionEvent`.
//
// `ports.snapshot` is now a member of `EVENT_KINDS` (this PR added it), so
// `decodeFrame` accepts it as a valid event kind. The rejection below therefore
// genuinely depends on the runtime `HOST_ONLY_KINDS` entry — the type-level
// `SessionEventKind` exclusion cannot enforce it at runtime — without which a
// machine-wide broadcast could be persisted into a session's append-only log.
test("ports.snapshot decodes as a frame but never as a session event", () => {
  const frame = snapshots.find((f) => f.kind === "ports.snapshot");
  assert.ok(frame, "snapshots.json is missing a ports.snapshot envelope");
  assert.notEqual(decodeFrame(JSON.stringify(frame)), null);
  assert.equal(
    decodeSessionEvent({ seq: 1, sessionId: "s1", ts: 1, kind: "ports.snapshot", payload: {} }),
    null,
    "ports.snapshot must be in HOST_ONLY_KINDS — a host broadcast may not enter a session log",
  );
});

// ── SPEC-42 P2b ────────────────────────────────────────────────────────────
// The orphan/collision annotations are OPTIONAL fields on an EXISTING event, so
// no `EventKind` / `HOST_ONLY_KINDS` entry is added. This asserts both halves
// still hold with the richer payload: the frame round-trips, and the carve-out
// was not disturbed. It is deliberately typed against `PortDTO` so the fixture
// cannot drift from the interface without `tsc` failing.
test("ports.snapshot carries orphan and collision annotations", () => {
  const frame = snapshots.find((f) => f.kind === "ports.snapshot");
  assert.ok(frame);
  const decoded = decodeFrame(JSON.stringify(frame));
  assert.notEqual(decoded, null);

  const ports = (frame as { snapshot: { ports: PortDTO[] } }).snapshot.ports;
  const orphan = ports.find((p) => p.orphan !== undefined);
  assert.ok(orphan, "fixture must cover an orphan-annotated port");
  assert.equal(orphan.orphan?.formerBranch, "feat/desktop-tabs");
  assert.equal(orphan.orphan?.removedAt, 2500);
  assert.equal(
    orphan.worktreePath,
    undefined,
    "an orphan is by definition unowned — it has no active worktree",
  );

  const collision = ports.find((p) => p.collision !== undefined);
  assert.ok(collision, "fixture must cover a collision-annotated port");
  assert.equal(collision.collision?.withBranch, "chore/deps");
});

// ── SPEC-42 P2c ────────────────────────────────────────────────────────────
// `docker` is a third OPTIONAL annotation on the same event (D13): an ownership
// fact, never a `reach`. The fixture's container port is bound to `0.0.0.0`, so
// this also pins the half of D13 that is easiest to regress — the annotation
// must not rewrite `reach` into a `docker` value the type does not have.
test("ports.snapshot carries a docker annotation without touching reach", () => {
  const frame = snapshots.find((f) => f.kind === "ports.snapshot");
  assert.ok(frame);
  assert.notEqual(decodeFrame(JSON.stringify(frame)), null);

  const ports = (frame as { snapshot: { ports: PortDTO[] } }).snapshot.ports;
  const container = ports.find((p) => p.docker !== undefined);
  assert.ok(container, "fixture must cover a docker-annotated port");
  assert.equal(container.docker?.container, "chat-ui-db-1");
  assert.equal(container.docker?.compose, "/repo/chat-ui/compose.yml");
  assert.equal(container.reach, "exposed", "docker is ownership, not reach (D13)");
});
