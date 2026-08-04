import { test } from "node:test";
import assert from "node:assert/strict";

import { watchBudget } from "./budget_watch.js";

/** A manual interval: `fire()` runs the pending callback, `live` counts timers. */
function fakeTimers() {
  let fn: (() => void) | undefined;
  let live = 0;
  return {
    setTimer: (cb: () => void) => {
      fn = cb;
      live += 1;
      return { unref: () => undefined } as unknown as ReturnType<typeof setInterval>;
    },
    clearTimer: () => {
      fn = undefined;
      live -= 1;
    },
    fire: () => fn?.(),
    get live() {
      return live;
    },
  };
}

function harness() {
  const timers = fakeTimers();
  let refreshes = 0;
  const sentTo: ReadonlyArray<object>[] = [];
  const watch = watchBudget({
    refresh: async () => {
      refreshes += 1;
    },
    broadcast: (watchers) => sentTo.push(watchers),
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
  });
  return {
    watch,
    timers,
    sentTo,
    get refreshes() {
      return refreshes;
    },
    get broadcasts() {
      return sentTo.length;
    },
  };
}

test("no timer runs while nobody is watching", () => {
  const h = harness();
  assert.equal(h.timers.live, 0);
  assert.equal(h.watch.size, 0);
});

test("the first watcher refreshes at once, so opening the panel shows fresh numbers", async () => {
  const h = harness();
  h.watch.add({});
  await h.watch.settled();
  assert.equal(h.refreshes, 1);
  assert.equal(h.broadcasts, 1);
  assert.equal(h.timers.live, 1, "and arms the fast loop");
});

test("each tick refreshes and broadcasts unconditionally", async () => {
  const h = harness();
  h.watch.add({});
  await h.watch.settled();
  h.timers.fire();
  await h.watch.settled();
  h.timers.fire();
  await h.watch.settled();
  // The whole point of the fast loop: `remaining`/`mine`/`others` move without
  // a level change, which the gateway's own change-gated emit would swallow.
  assert.equal(h.refreshes, 3);
  assert.equal(h.broadcasts, 3);
});

test("a second watcher shares the one loop rather than arming another", async () => {
  const h = harness();
  const a = {};
  const b = {};
  h.watch.add(a);
  h.watch.add(b);
  await h.watch.settled();
  assert.equal(h.timers.live, 1);
  assert.equal(h.watch.size, 2);
  // Adding the same client twice must not double-count, or `remove` would never
  // reach zero and the fast loop would run forever.
  h.watch.add(a);
  assert.equal(h.watch.size, 2);
});

test("the loop stops only when the last watcher leaves", async () => {
  const h = harness();
  const a = {};
  const b = {};
  h.watch.add(a);
  h.watch.add(b);
  await h.watch.settled();
  h.watch.remove(a);
  assert.equal(h.timers.live, 1, "b is still watching");
  h.watch.remove(b);
  assert.equal(h.timers.live, 0);
  assert.equal(h.watch.size, 0);
});

test("removing an unknown watcher is a no-op (a client that never watched, closing)", () => {
  const h = harness();
  h.watch.remove({});
  assert.equal(h.timers.live, 0);
});

test("re-opening after the last close arms the loop again", async () => {
  const h = harness();
  const a = {};
  h.watch.add(a);
  await h.watch.settled();
  h.watch.remove(a);
  h.watch.add(a);
  await h.watch.settled();
  assert.equal(h.timers.live, 1);
  assert.equal(h.refreshes, 2);
});

test("a failing refresh still broadcasts and keeps the loop alive", async () => {
  const timers = fakeTimers();
  let broadcasts = 0;
  const watch = watchBudget({
    refresh: () => Promise.reject(new Error("gh exploded")),
    broadcast: () => {
      broadcasts += 1;
    },
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
  });
  watch.add({});
  await watch.settled();
  // The last-known snapshot is still worth sending, and one failed `gh` must not
  // silently kill the panel's liveness for the rest of the session.
  assert.equal(broadcasts, 1);
  assert.equal(timers.live, 1);
  timers.fire();
  await watch.settled();
  assert.equal(broadcasts, 2);
});

test("a tick still in flight is skipped, never stacked (the gate can be busy)", async () => {
  const timers = fakeTimers();
  let started = 0;
  let release: (() => void) | undefined;
  const watch = watchBudget({
    refresh: () => {
      started += 1;
      return new Promise<void>((r) => (release = r));
    },
    broadcast: () => undefined,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
  });
  watch.add({});
  assert.equal(started, 1, "the immediate read is in flight");

  // `/rate_limit` shares the gateway's concurrency gate with PR lookups, so a
  // read CAN outlive the interval. Stacking would spawn a second `gh` per tick
  // and pile up without bound.
  timers.fire();
  timers.fire();
  assert.equal(started, 1, "ticks during an in-flight read are dropped");

  release?.();
  await watch.settled();
  timers.fire();
  assert.equal(started, 2, "and the loop resumes once it completes");
});

test("re-opening during an in-flight read is served by that read, not a second one", async () => {
  // Close-then-reopen inside one read window must not spawn a second `gh`: the
  // read already in flight is at most a moment old, and its broadcast goes to
  // whoever is watching when it lands — including the re-added watcher.
  const timers = fakeTimers();
  let started = 0;
  const sentTo: ReadonlyArray<object>[] = [];
  let release: (() => void) | undefined;
  const watch = watchBudget<object>({
    refresh: () => {
      started += 1;
      return new Promise<void>((r) => (release = r));
    },
    broadcast: (watchers) => sentTo.push(watchers),
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer,
  });
  const a = {};
  watch.add(a);
  watch.remove(a);
  watch.add(a);
  assert.equal(started, 1, "no redundant read");

  release?.();
  await watch.settled();
  assert.deepEqual(sentTo.at(-1), [a], "the in-flight read still serves the re-opened panel");
});

test("each broadcast targets the watchers only, not every client", async () => {
  // A phone paired to the same server has no budget panel at all; pushing it a
  // ~1KB snapshot (60 history slots + stats) every 10s because a desktop has the
  // panel open is pure waste on a metered link.
  const h = harness();
  // Labelled, not bare `{}`: two structurally identical objects make a deepEqual
  // of `[a]` pass just as well for `[b]`, so the assertions below would not
  // actually pin down *which* client each snapshot went to.
  const a = { client: "desktop-a" };
  const b = { client: "desktop-b" };
  h.watch.add(a);
  await h.watch.settled();
  assert.deepEqual(h.sentTo.at(-1), [a]);
  h.watch.add(b);
  h.timers.fire();
  await h.watch.settled();
  assert.deepEqual(h.sentTo.at(-1), [a, b]);
  h.watch.remove(a);
  h.timers.fire();
  await h.watch.settled();
  assert.deepEqual(h.sentTo.at(-1), [b]);
});

test("close() drops every watcher and disarms the loop", async () => {
  const h = harness();
  h.watch.add({});
  await h.watch.settled();
  h.watch.close();
  assert.equal(h.timers.live, 0);
  assert.equal(h.watch.size, 0);
});

test("add() after close() never re-arms (the server is shutting down)", async () => {
  const h = harness();
  h.watch.close();
  h.watch.add({});
  await h.watch.settled();
  assert.equal(h.timers.live, 0);
  assert.equal(h.refreshes, 0);
});
