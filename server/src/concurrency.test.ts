import { test } from "node:test";
import assert from "node:assert/strict";

import { mapLimit } from "./concurrency.js";

test("mapLimit preserves input order in the result", async () => {
  const out = await mapLimit([1, 2, 3, 4, 5], 2, async (n) => {
    await new Promise((r) => setTimeout(r, (6 - n) * 5)); // later items finish first
    return n * 10;
  });
  assert.deepEqual(out, [10, 20, 30, 40, 50]);
});

test("mapLimit never runs more than `limit` tasks at once", async () => {
  let inFlight = 0;
  let peak = 0;
  await mapLimit(Array.from({ length: 20 }, (_, i) => i), 3, async () => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight--;
  });
  assert.ok(peak <= 3, `peak concurrency ${peak} exceeded limit 3`);
});

test("mapLimit rejects if any task rejects (fail-fast like Promise.all)", async () => {
  await assert.rejects(
    mapLimit([1, 2, 3], 2, async (n) => {
      if (n === 2) throw new Error("boom");
      return n;
    }),
    /boom/,
  );
});

test("mapLimit with an empty list resolves to an empty array", async () => {
  assert.deepEqual(await mapLimit([], 4, async (n) => n), []);
});

test("mapLimit treats limit <= 0 as unbounded (runs all, order preserved)", async () => {
  const out = await mapLimit([1, 2, 3], 0, async (n) => n * 2);
  assert.deepEqual(out, [2, 4, 6]);
});
