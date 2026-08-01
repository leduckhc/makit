import assert from "node:assert/strict";
import { test } from "node:test";

import { installProcessCrashHandlers } from "./crash_capture.js";

/** Capture what the shared logger writes to stderr while `fn` runs. */
function captureLog(fn: () => void): string[] {
  const prev = process.env.MAKIT_LOG;
  process.env.MAKIT_LOG = "error";
  const original = console.error;
  const logged: string[] = [];
  console.error = (...args: unknown[]) => logged.push(args.join(" "));
  try {
    fn();
  } finally {
    console.error = original;
    if (prev === undefined) delete process.env.MAKIT_LOG;
    else process.env.MAKIT_LOG = prev;
  }
  return logged;
}

test("logs an unhandledRejection without exiting", () => {
  const exits: number[] = [];
  const logged = captureLog(() => {
    const uninstall = installProcessCrashHandlers({ exit: (c) => exits.push(c) });
    const listener = process.listeners("unhandledRejection").at(-1) as (r: unknown) => void;
    listener(new Error("promise boom"));
    uninstall();
  });
  assert.ok(logged.some((l) => /unhandledRejection/.test(l) && /promise boom/.test(l)));
  assert.deepEqual(exits, [], "a rejection must not kill the server");
});

test("logs an uncaughtException and then exits non-zero (fail-fast)", () => {
  const exits: number[] = [];
  const logged = captureLog(() => {
    const uninstall = installProcessCrashHandlers({ exit: (c) => exits.push(c) });
    const listener = process.listeners("uncaughtException").at(-1) as (e: unknown) => void;
    listener(new Error("fatal boom"));
    uninstall();
  });
  assert.ok(logged.some((l) => /uncaughtException/.test(l) && /fatal boom/.test(l)));
  assert.deepEqual(exits, [1], "an uncaught exception must fail fast");
});

test("uninstall removes the listeners it added", () => {
  const before = process.listenerCount("uncaughtException");
  const uninstall = installProcessCrashHandlers({ exit: () => {} });
  assert.equal(process.listenerCount("uncaughtException"), before + 1);
  uninstall();
  assert.equal(process.listenerCount("uncaughtException"), before);
});
