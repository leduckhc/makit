import { test } from "node:test";
import assert from "node:assert/strict";

import { Ring } from "./ring.js";

interface Tick {
  ts: number;
  v: number;
}

test("toArray returns oldest first before any rollover", () => {
  const ring = new Ring<Tick>(4);
  ring.push({ ts: 1, v: 10 });
  ring.push({ ts: 2, v: 20 });
  assert.deepEqual(
    ring.toArray().map((t) => t.v),
    [10, 20],
  );
});

test("rollover preserves chronological order (oldest first)", () => {
  const ring = new Ring<Tick>(3);
  for (let i = 1; i <= 5; i++) ring.push({ ts: i, v: i });
  // Capacity 3 keeps the last three pushes, oldest first.
  assert.deepEqual(
    ring.toArray().map((t) => t.ts),
    [3, 4, 5],
  );
});

test("sinceMs boundary is inclusive: ts === now - ms is included", () => {
  const ring = new Ring<Tick>(8);
  ring.push({ ts: 100, v: 1 });
  ring.push({ ts: 150, v: 2 });
  ring.push({ ts: 200, v: 3 });
  // window of 100ms ending at now=200 => cutoff 100, inclusive.
  const got = ring.sinceMs(200, 100).map((t) => t.ts);
  assert.deepEqual(got, [100, 150, 200]);
});

test("sinceMs excludes items strictly older than the cutoff", () => {
  const ring = new Ring<Tick>(8);
  ring.push({ ts: 99, v: 1 });
  ring.push({ ts: 100, v: 2 });
  ring.push({ ts: 250, v: 3 });
  const got = ring.sinceMs(200, 100).map((t) => t.ts); // cutoff = 100
  assert.deepEqual(got, [100, 250]);
});

test("capacity 1 keeps only the most recent item and does not crash", () => {
  const ring = new Ring<Tick>(1);
  ring.push({ ts: 1, v: 1 });
  ring.push({ ts: 2, v: 2 });
  assert.deepEqual(
    ring.toArray().map((t) => t.v),
    [2],
  );
  assert.deepEqual(ring.sinceMs(2, 10).map((t) => t.v), [2]);
});

test("capacity 0 never stores anything and does not crash", () => {
  const ring = new Ring<Tick>(0);
  ring.push({ ts: 1, v: 1 });
  ring.push({ ts: 2, v: 2 });
  assert.deepEqual(ring.toArray(), []);
  assert.deepEqual(ring.sinceMs(2, 100), []);
});
