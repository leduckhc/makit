import { test } from "node:test";
import assert from "node:assert/strict";

import { TurnStatusTracker } from "./turn-status.js";

/** Build a tracker that records every transition it emits. */
function makeTracker(exited = { value: false }) {
  const statuses: Array<"idle" | "running"> = [];
  const gates: Array<"awaiting-approval" | "awaiting-input"> = [];
  const tracker = new TurnStatusTracker({
    emitStatus: (s) => statuses.push(s),
    emitSessionStatus: (g) => gates.push(g),
    isExited: () => exited.value,
  });
  return { tracker, statuses, gates, exited };
}

test("entering a turn emits running; leaving the last one emits idle", () => {
  const { tracker, statuses } = makeTracker();
  const key = tracker.enterTurn();
  assert.deepEqual(statuses, ["running"]);
  tracker.leaveTurn(key);
  assert.deepEqual(statuses, ["running", "idle"]);
});

test("idle is only emitted once the last of several turns leaves", () => {
  const { tracker, statuses } = makeTracker();
  const a = tracker.enterTurn("a");
  const b = tracker.enterTurn("b");
  tracker.leaveTurn(a);
  // Still one turn in flight → no idle yet.
  assert.deepEqual(statuses, ["running", "running"]);
  tracker.leaveTurn(b);
  assert.deepEqual(statuses.at(-1), "idle");
});

test("the first approval flips the gate; leaving it resumes running mid-turn", () => {
  const { tracker, statuses, gates } = makeTracker();
  tracker.enterTurn("t");
  tracker.enterApproval("awaiting-approval");
  tracker.enterApproval("awaiting-approval"); // second one must NOT re-flip
  assert.deepEqual(gates, ["awaiting-approval"]);
  tracker.leaveApproval();
  // Still one approval pending → no running resume yet.
  assert.deepEqual(statuses, ["running"]);
  tracker.leaveApproval();
  assert.deepEqual(statuses, ["running", "running"]);
});

test("a turn that ends while an approval is pending does not go idle early", () => {
  const { tracker, statuses } = makeTracker();
  tracker.enterTurn("t");
  tracker.enterApproval("awaiting-input");
  tracker.leaveTurn("t");
  // Approval still pending → not settled.
  assert.equal(statuses.includes("idle"), false);
  tracker.leaveApproval();
  // Now fully settled.
  tracker.settleIdle();
  assert.equal(statuses.at(-1), "idle");
});

test("nothing is emitted once the adapter has exited", () => {
  const exited = { value: false };
  const { tracker, statuses } = makeTracker(exited);
  const key = tracker.enterTurn();
  exited.value = true;
  tracker.leaveTurn(key);
  tracker.settleIdle();
  assert.deepEqual(statuses, ["running"]); // no trailing idle
});

test("hasActiveTurns reflects in-flight turns", () => {
  const { tracker } = makeTracker();
  assert.equal(tracker.hasActiveTurns, false);
  const key = tracker.enterTurn();
  assert.equal(tracker.hasActiveTurns, true);
  tracker.leaveTurn(key);
  assert.equal(tracker.hasActiveTurns, false);
});
