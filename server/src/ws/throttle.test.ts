import { test } from "node:test";
import assert from "node:assert/strict";

import { throttleTrailing } from "./throttle.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("throttleTrailing fires immediately on the leading edge", () => {
  let calls = 0;
  const fn = throttleTrailing(() => calls++, 50);
  fn();
  assert.equal(calls, 1);
});

test("throttleTrailing coalesces a burst into one trailing call", async () => {
  let calls = 0;
  const fn = throttleTrailing(() => calls++, 40);
  for (let i = 0; i < 100; i++) fn();
  assert.equal(calls, 1, "burst → only the leading call so far");
  await sleep(80);
  assert.equal(calls, 2, "one trailing call flushes the burst");
});

test("throttleTrailing allows a fresh leading call after the interval", async () => {
  let calls = 0;
  const fn = throttleTrailing(() => calls++, 20);
  fn();
  await sleep(50);
  fn();
  assert.equal(calls, 2);
});
