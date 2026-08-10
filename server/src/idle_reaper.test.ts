import { test } from "node:test";
import assert from "node:assert/strict";

import { IdleReaper, resolveIdleCloseMs, DEFAULT_IDLE_CLOSE_MS } from "./idle_reaper.js";
import type { Session } from "./session.js";
import type { SessionStatus } from "./protocol.js";

/**
 * The reaper only ever reads a handful of session fields, so a plain object is a
 * truer test double than a real `SessionManager` + SQLite + temp dir: each case
 * states exactly the session shape it is about, and nothing else can influence
 * the outcome.
 */
function session(over: Partial<Session> & { id?: string } = {}): Session {
  return {
    id: over.id ?? "sess-1",
    title: "a session",
    closed: false,
    pending: false,
    cold: false,
    status: "idle" as SessionStatus,
    resumable: true,
    lastActivityAt: 0,
    ...over,
  } as unknown as Session;
}

function reaper(
  sessions: Session[],
  over: { idleCloseMs?: number; now?: () => number } = {},
) {
  const closed: string[] = [];
  const r = new IdleReaper({
    sessions: () => sessions,
    close: async (id) => {
      closed.push(id);
      const s = sessions.find((x) => x.id === id)!;
      (s as { closed: boolean }).closed = true;
    },
    idleCloseMs: over.idleCloseMs ?? 60_000,
    now: over.now ?? (() => 10 * 60_000),
  });
  return { r, closed };
}

test("closes a session idle past the window", async () => {
  const { r, closed } = reaper([session({ lastActivityAt: 0 })]);
  assert.deepEqual(await r.sweep(), ["sess-1"]);
  assert.deepEqual(closed, ["sess-1"]);
});

test("leaves a recently-active session alone", async () => {
  const s = session({ lastActivityAt: 10 * 60_000 - 5_000 });
  const { r } = reaper([s]);
  assert.deepEqual(await r.sweep(), []);
  assert.equal(s.closed, false);
});

/**
 * The guards that make auto-close safe. Each of these would either destroy work
 * or free nothing, so a stale timestamp alone must never be enough.
 */
test("never closes a session that would lose work or free nothing", async () => {
  const cases: Array<[string, Partial<Session>]> = [
    ["mid-turn", { status: "running" as SessionStatus }],
    ["awaiting input", { status: "awaiting-input" as SessionStatus }],
    ["awaiting approval", { status: "awaiting-approval" as SessionStatus }],
    ["a draft", { pending: true }],
    ["already cold", { cold: true }],
    ["already closed", { closed: true }],
    ["not resumable", { resumable: false }],
  ];
  for (const [label, over] of cases) {
    const s = session({ lastActivityAt: 0, ...over });
    const { r, closed } = reaper([s]);
    assert.deepEqual(await r.sweep(), [], `must skip ${label}`);
    assert.deepEqual(closed, [], `must skip ${label}`);
  }
});

test("idleCloseMs = 0 disables the reaper entirely", async () => {
  const { r } = reaper([session({ lastActivityAt: 0 })], { idleCloseMs: 0 });
  assert.equal(r.enabled, false);
  assert.deepEqual(await r.sweep(), []);
});

/**
 * The guards are re-checked immediately before each close, not once when the
 * candidate list is built. A sweep is SLOW — every close awaits an agent
 * round-trip plus up to the SIGTERM grace period — so with several sessions the
 * window is tens of seconds. A message arriving in that window flips a later
 * candidate to `running`; closing it anyway would tear the agent out from under a
 * live turn, which is exactly the data loss the guards exist to prevent.
 */
test("re-checks each candidate after the awaits (no close mid-turn)", async () => {
  const first = session({ id: "first", lastActivityAt: 0 });
  const second = session({ id: "second", lastActivityAt: 0 });
  const closed: string[] = [];
  const r = new IdleReaper({
    sessions: () => [first, second],
    close: async (id) => {
      closed.push(id);
      // While the first is closing, a user message lands on the second.
      if (id === "first") (second as { status: SessionStatus }).status = "running";
    },
    idleCloseMs: 60_000,
    now: () => 10 * 60_000,
  });

  assert.deepEqual(await r.sweep(), ["first"]);
  assert.deepEqual(closed, ["first"], "the session that started a turn must be spared");
});

test("one failing close does not stop the rest being reclaimed", async () => {
  const bad = session({ id: "bad", lastActivityAt: 0 });
  const good = session({ id: "good", lastActivityAt: 0 });
  const r = new IdleReaper({
    sessions: () => [bad, good],
    close: async (id) => {
      if (id === "bad") throw new Error("wedged");
    },
    idleCloseMs: 60_000,
    now: () => 10 * 60_000,
  });
  assert.deepEqual(await r.sweep(), ["good"]);
});

test("start() arms the injected timer and stop() clears it", () => {
  let armed: number | undefined;
  let cleared = false;
  const r = new IdleReaper({
    sessions: () => [],
    close: async () => {},
    idleCloseMs: 60_000,
    sweepMs: 5_000,
    setTimer: (_fn, ms) => {
      armed = ms;
      return "handle";
    },
    clearTimer: () => {
      cleared = true;
    },
  });
  r.start();
  assert.equal(armed, 5_000);
  r.start(); // idempotent — must not arm a second interval
  assert.equal(armed, 5_000);
  r.stop();
  assert.equal(cleared, true);
});

test("a disabled reaper never arms a timer", () => {
  let armed = false;
  const r = new IdleReaper({
    sessions: () => [],
    close: async () => {},
    idleCloseMs: 0,
    setTimer: () => {
      armed = true;
      return "h";
    },
  });
  r.start();
  assert.equal(armed, false);
});

test("resolveIdleCloseMs reads minutes, defaults, and honours 0", () => {
  assert.equal(resolveIdleCloseMs({} as NodeJS.ProcessEnv), DEFAULT_IDLE_CLOSE_MS);
  assert.equal(resolveIdleCloseMs({ MAKIT_IDLE_CLOSE_MIN: "" } as NodeJS.ProcessEnv), DEFAULT_IDLE_CLOSE_MS);
  assert.equal(resolveIdleCloseMs({ MAKIT_IDLE_CLOSE_MIN: "5" } as NodeJS.ProcessEnv), 5 * 60_000);
  assert.equal(resolveIdleCloseMs({ MAKIT_IDLE_CLOSE_MIN: "0" } as NodeJS.ProcessEnv), 0);
  // Garbage must fall back to the default, not silently disable memory hygiene.
  assert.equal(resolveIdleCloseMs({ MAKIT_IDLE_CLOSE_MIN: "soon" } as NodeJS.ProcessEnv), DEFAULT_IDLE_CLOSE_MS);
  assert.equal(resolveIdleCloseMs({ MAKIT_IDLE_CLOSE_MIN: "-3" } as NodeJS.ProcessEnv), DEFAULT_IDLE_CLOSE_MS);
});
