import { test } from "node:test";
import assert from "node:assert/strict";
import { hostAskResultFrame } from "../../src/server.js";

/**
 * Regression guard for the World D host.ask relay. The bug: building the frame
 * as `{ t:"host.ask.result", id: askId, ...resp }` let the srv.response
 * envelope's own `t`/`id` clobber ours, so the pino-mirror extension (matching
 * `t === "host.ask.result"`) never resolved its ask promise — hanging both the
 * pi TUI and the phone.
 */
test("carries the answer under host.ask.result + the extension's askId", () => {
  const resp = {
    v: 1,
    t: "srv.response", // MUST NOT leak into the frame
    id: "srv-123-1", // MUST NOT leak into the frame
    kind: "askUserQuestion",
    indices: [0],
    answers: ["Apple"],
    answer: "Apple",
  };
  const frame = hostAskResultFrame("ask-abc", resp) as Record<string, unknown>;

  assert.equal(frame.t, "host.ask.result", "type must not be clobbered by resp.t");
  assert.equal(frame.id, "ask-abc", "id must be the extension's askId, not srv-…");
  assert.deepEqual(frame.answers, ["Apple"]);
  assert.deepEqual(frame.indices, [0]);
  assert.equal(frame.answer, "Apple");
});

test("propagates a cancellation", () => {
  const frame = hostAskResultFrame("ask-x", { cancelled: true }) as Record<string, unknown>;
  assert.equal(frame.t, "host.ask.result");
  assert.equal(frame.id, "ask-x");
  assert.equal(frame.cancelled, true);
});
