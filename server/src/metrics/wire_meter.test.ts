import { test } from "node:test";
import assert from "node:assert/strict";

import { WireMeter } from "./wire_meter.js";

test("sampleRates computes per-second rates over a 2s window then resets", () => {
  const m = new WireMeter();
  m.addIn(2000);
  m.addOut(4000);
  m.frame();
  m.frame();
  // First call establishes the baseline timestamp.
  m.sampleRates(1000);

  m.addIn(2000);
  m.addOut(4000);
  m.frame();
  m.frame();
  const r = m.sampleRates(3000); // 2000ms elapsed
  assert.equal(r.inBytesPerSec, 1000);
  assert.equal(r.outBytesPerSec, 2000);
  assert.equal(r.framesPerSec, 1); // 2 frames over a 2s window

  // Accumulators reset: a subsequent window with no traffic is all zeros.
  const r2 = m.sampleRates(4000);
  assert.equal(r2.inBytesPerSec, 0);
  assert.equal(r2.outBytesPerSec, 0);
  assert.equal(r2.framesPerSec, 0);
});

test("sampleRates does not divide by zero when called twice at the same now", () => {
  const m = new WireMeter();
  m.sampleRates(5000);
  m.addIn(500);
  m.addOut(250);
  m.frame();
  const r = m.sampleRates(5000); // zero-duration window
  assert.equal(r.inBytesPerSec, 0);
  assert.equal(r.outBytesPerSec, 0);
  // Frames is normalised like the byte rates, so a zero-duration window is 0.
  assert.equal(r.framesPerSec, 0); // no measurable window yet
  assert.ok(Number.isFinite(r.inBytesPerSec));
  assert.ok(Number.isFinite(r.outBytesPerSec));
});
