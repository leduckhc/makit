/**
 * Unit tests for `decodeUIResponse` — the trust boundary for `srv.response`
 * envelopes coming back from a device (SPEC-18 T1). A malformed/hostile
 * response must decode to `null` rather than be blindly cast to `UIResponse`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeUIResponse } from "./codec.js";
import type { Envelope } from "../protocol.js";

/** Build a minimal `srv.response` envelope carrying the given flat fields. */
function env(fields: Record<string, unknown>): Envelope {
  return { v: 1, t: "srv.response", id: "srv-1", ...fields } as Envelope;
}

test("decodeUIResponse accepts a valid confirmAction response", () => {
  const r = decodeUIResponse(env({ kind: "confirmAction", approved: true }));
  assert.deepEqual(r, { kind: "confirmAction", approved: true });
});

test("decodeUIResponse accepts a valid askUserQuestion response (with optional answer)", () => {
  const r = decodeUIResponse(
    env({ kind: "askUserQuestion", indices: [0, 1], answers: ["a", "b"], answer: "a" }),
  );
  assert.deepEqual(r, {
    kind: "askUserQuestion",
    indices: [0, 1],
    answers: ["a", "b"],
    answer: "a",
  });
});

test("decodeUIResponse accepts an askUserQuestion response without the optional answer", () => {
  const r = decodeUIResponse(
    env({ kind: "askUserQuestion", indices: [], answers: [] }),
  );
  assert.deepEqual(r, { kind: "askUserQuestion", indices: [], answers: [] });
});

test("decodeUIResponse accepts a valid input response (value)", () => {
  const r = decodeUIResponse(env({ kind: "input", value: "hello" }));
  assert.deepEqual(r, { kind: "input", value: "hello" });
});

test("decodeUIResponse accepts a valid input response (cancelled)", () => {
  const r = decodeUIResponse(env({ kind: "input", cancelled: true }));
  assert.deepEqual(r, { kind: "input", cancelled: true });
});

test("decodeUIResponse rejects an unknown kind", () => {
  assert.equal(decodeUIResponse(env({ kind: "explode" })), null);
});

test("decodeUIResponse rejects a missing kind", () => {
  assert.equal(decodeUIResponse(env({ approved: true })), null);
});

test("decodeUIResponse rejects confirmAction without a boolean approved", () => {
  assert.equal(decodeUIResponse(env({ kind: "confirmAction" })), null);
  assert.equal(decodeUIResponse(env({ kind: "confirmAction", approved: "yes" })), null);
});

test("decodeUIResponse rejects askUserQuestion with non-array indices/answers", () => {
  assert.equal(
    decodeUIResponse(env({ kind: "askUserQuestion", indices: 0, answers: [] })),
    null,
  );
  assert.equal(
    decodeUIResponse(env({ kind: "askUserQuestion", indices: [], answers: "a" })),
    null,
  );
});

test("decodeUIResponse rejects askUserQuestion with wrong element types", () => {
  assert.equal(
    decodeUIResponse(env({ kind: "askUserQuestion", indices: ["0"], answers: [] })),
    null,
  );
  assert.equal(
    decodeUIResponse(env({ kind: "askUserQuestion", indices: [], answers: [1] })),
    null,
  );
});

test("decodeUIResponse rejects input with a non-string value", () => {
  assert.equal(decodeUIResponse(env({ kind: "input", value: 42 })), null);
});

test("decodeUIResponse rejects a non-record input", () => {
  assert.equal(decodeUIResponse(null), null);
  assert.equal(decodeUIResponse("nope" as unknown as Envelope), null);
});
