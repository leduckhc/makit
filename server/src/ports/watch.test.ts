import assert from "node:assert/strict";
import { test } from "node:test";

import { WATCH_DOWN_GRACE_MS, PortDownDetector } from "./watch.js";
import type { PortDTO } from "../protocol.js";
import type { WatchedPort } from "./watch_store.js";

const WATCHED: WatchedPort[] = [{ worktreePath: "/repo/wt-a", port: 5173 }];

function listening(overrides: Partial<PortDTO> = {}): PortDTO {
  return {
    key: "200:127.0.0.1:5173",
    port: 5173,
    address: "127.0.0.1",
    reach: "loopback",
    pid: 200,
    command: "node vite",
    worktreePath: "/repo/wt-a",
    ...overrides,
  };
}

interface Harness {
  detector: PortDownDetector;
  fired: WatchedPort[];
  at: (ms: number, ports: PortDTO[], watched?: WatchedPort[]) => void;
}

function harness(): Harness {
  const fired: WatchedPort[] = [];
  let now = 0;
  const detector = new PortDownDetector({
    now: () => now,
    onDown: (w) => fired.push(w),
  });
  return {
    detector,
    fired,
    at: (ms, ports, watched = WATCHED) => {
      now = ms;
      detector.observe(ports, watched);
    },
  };
}

test("WATCH_DOWN_GRACE_MS is 20s — about five scan ticks", () => {
  assert.equal(WATCH_DOWN_GRACE_MS, 20_000);
});

test("a listening watched port fires nothing, ever", () => {
  const h = harness();
  for (let t = 0; t < 10; t++) h.at(t * 4_000, [listening()]);
  assert.deepEqual(h.fired, []);
});

test("absent for the whole grace window fires EXACTLY ONE notification", () => {
  const h = harness();
  h.at(0, [listening()]);
  h.at(4_000, []); // first absent tick — arms, does not fire
  assert.deepEqual(h.fired, []);
  h.at(4_000 + WATCH_DOWN_GRACE_MS - 1, []);
  assert.deepEqual(h.fired, [], "still inside the window");
  h.at(4_000 + WATCH_DOWN_GRACE_MS, []);
  assert.deepEqual(h.fired, WATCHED);

  // And it does not keep firing every 4 s afterwards.
  h.at(100_000, []);
  h.at(200_000, []);
  assert.deepEqual(h.fired, WATCHED, "one notification per outage, not per scan");
});

test("a BOUNCE inside the window cancels it — the anti-firehose rule (D8)", () => {
  // "A build restarts its dev server ten times an hour": a bare down→notify
  // would fire on every rebuild, which is why the grace window exists.
  const h = harness();
  h.at(0, [listening()]);
  h.at(4_000, []);
  h.at(8_000, [listening({ pid: 999, key: "999:127.0.0.1:5173" })]); // restarted, new pid
  h.at(60_000, [listening({ pid: 999, key: "999:127.0.0.1:5173" })]);
  assert.deepEqual(h.fired, [], "a restart is not an outage");
});

test("a REAL outage after a recovery re-arms and fires again", () => {
  const h = harness();
  h.at(0, [listening()]);
  h.at(4_000, []);
  h.at(4_000 + WATCH_DOWN_GRACE_MS, []);
  assert.equal(h.fired.length, 1);

  h.at(60_000, [listening()]); // back up
  h.at(64_000, []); // down again
  h.at(64_000 + WATCH_DOWN_GRACE_MS, []);
  assert.equal(h.fired.length, 2, "each outage is its own notification");
});

test("a port that is BOUND but refusing counts as down (D8)", () => {
  // "Stopped listening" is about usefulness, not about the socket table: a
  // crashed server still holding its socket is exactly the case worth telling
  // someone about.
  const h = harness();
  h.at(0, [listening()]);
  const refused = listening({
    health: { kind: "refused", probedAt: 1 },
  });
  h.at(4_000, [refused]);
  h.at(4_000 + WATCH_DOWN_GRACE_MS, [refused]);
  assert.deepEqual(h.fired, WATCHED);
});

test("an UNWATCHED port never notifies, however long it is gone", () => {
  const h = harness();
  h.at(0, [listening()], []);
  h.at(4_000, [], []);
  h.at(500_000, [], []);
  assert.deepEqual(h.fired, []);
});

test("un-watching a port mid-outage cancels its pending notification", () => {
  const h = harness();
  h.at(0, [listening()]);
  h.at(4_000, []);
  h.at(4_000 + WATCH_DOWN_GRACE_MS, [], []); // the user removed the watch
  assert.deepEqual(h.fired, []);
});

test("a port that was never seen up does not fire on the first tick", () => {
  // Watching a port whose server is not running yet must not immediately alert:
  // the alert means "it stopped", which requires having seen it start.
  const h = harness();
  h.at(0, []);
  h.at(WATCH_DOWN_GRACE_MS * 2, []);
  assert.deepEqual(h.fired, []);
});

test("two watched ports track independently", () => {
  const other: WatchedPort = { worktreePath: "/repo/wt-b", port: 5174 };
  const watched = [...WATCHED, other];
  const bPort = listening({
    key: "300:127.0.0.1:5174",
    port: 5174,
    pid: 300,
    worktreePath: "/repo/wt-b",
  });
  const h = harness();
  h.at(0, [listening(), bPort], watched);
  h.at(4_000, [bPort], watched); // only A went down
  h.at(4_000 + WATCH_DOWN_GRACE_MS, [bPort], watched);
  assert.deepEqual(h.fired, WATCHED);
});
