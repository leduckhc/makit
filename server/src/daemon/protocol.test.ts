/**
 * Control-plane protocol codec tests (SPEC-daemon-control-plane, phase 1).
 *
 * The wire format is newline-delimited JSON over the unix control socket.
 * The codec must round-trip valid messages and NEVER throw on malformed
 * input — it returns `null` instead, so a hostile/local process cannot crash
 * the daemon by writing garbage to the socket.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  encodeMessage,
  decodeRequest,
  decodeResponse,
  LineBuffer,
  type ControlRequest,
  type ControlResponse,
} from "./protocol.js";
import { MAX_LINE_BUFFER_BYTES, LineBufferOverflowError } from "./protocol.js";

test("encodeMessage produces one newline-terminated JSON line", () => {
  const req: ControlRequest = { id: "1", verb: "status" };
  const wire = encodeMessage(req);
  assert.equal(wire.endsWith("\n"), true);
  assert.equal(wire.includes("\n"), true);
  assert.equal(wire.split("\n").length, 2); // payload + trailing empty
  assert.deepEqual(JSON.parse(wire.trimEnd()), req);
});

test("request round-trips through encode/decode", () => {
  const req: ControlRequest = { id: "abc", verb: "pair.mint", args: { ttlMs: 1000 } };
  const decoded = decodeRequest(encodeMessage(req).trimEnd());
  assert.deepEqual(decoded, req);
});

test("ok response round-trips", () => {
  const res: ControlResponse = { id: "abc", ok: true, data: { pid: 42 } };
  const decoded = decodeResponse(encodeMessage(res).trimEnd());
  assert.deepEqual(decoded, res);
});

test("error response round-trips", () => {
  const res: ControlResponse = { id: "abc", ok: false, error: "boom" };
  const decoded = decodeResponse(encodeMessage(res).trimEnd());
  assert.deepEqual(decoded, res);
});

test("decodeRequest rejects malformed input without throwing", () => {
  assert.equal(decodeRequest("{ not json"), null);
  assert.equal(decodeRequest("[]"), null);
  assert.equal(decodeRequest("42"), null);
  assert.equal(decodeRequest(JSON.stringify({ id: "1" })), null); // no verb
  assert.equal(decodeRequest(JSON.stringify({ verb: "status" })), null); // no id
  assert.equal(decodeRequest(JSON.stringify({ id: "1", verb: "nope" })), null); // bad verb
  assert.equal(
    decodeRequest(JSON.stringify({ id: "1", verb: "status", args: 5 })),
    null,
  ); // args not object
});

test("decodeResponse rejects malformed input without throwing", () => {
  assert.equal(decodeResponse("nope"), null);
  assert.equal(decodeResponse(JSON.stringify({ id: "1" })), null); // no ok
  assert.equal(decodeResponse(JSON.stringify({ ok: true })), null); // no id
  assert.equal(
    decodeResponse(JSON.stringify({ id: "1", ok: false })),
    null,
  ); // error required when !ok
});

test("LineBuffer splits complete lines and retains partial remainder", () => {
  const buf = new LineBuffer();
  assert.deepEqual(buf.push("hello\nwor"), ["hello"]);
  assert.deepEqual(buf.push("ld\n"), ["world"]);
  assert.deepEqual(buf.push("a\nb\nc"), ["a", "b"]);
  assert.deepEqual(buf.push("\n"), ["c"]);
  assert.deepEqual(buf.push(""), []);
});

test("LineBuffer rejects an unterminated line that exceeds the cap", () => {
  const buf = new LineBuffer(16);
  // A stream of complete small lines never overflows, regardless of total size.
  assert.deepEqual(buf.push("a\nb\nc\nd\ne\nf\ng\nh\n"), ["a", "b", "c", "d", "e", "f", "g", "h"]);
  // A single unterminated line past the cap overflows and resets the buffer.
  assert.throws(() => buf.push("x".repeat(17)), LineBufferOverflowError);
  // After overflow the buffer is clear, so a fresh well-formed line parses.
  assert.deepEqual(buf.push("ok\n"), ["ok"]);
});

test("MAX_LINE_BUFFER_BYTES defaults to 1 MiB", () => {
  assert.equal(MAX_LINE_BUFFER_BYTES, 1024 * 1024);
});
