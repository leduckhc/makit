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

test("a gate that closes after its turn already ended settles to idle", () => {
  // The ordering that wedged a real session: pi's `ask_user` opened the gate,
  // the ACP prompt resolved while it was still open, and the answer (or the
  // askDevice timeout) arrived last. `leaveApproval` had no turn left to resume,
  // so it emitted nothing and the session stayed `awaiting-approval` forever —
  // permanently "busy", which queues every later message and never flushes.
  const { tracker, statuses } = makeTracker();
  tracker.enterTurn("t");
  tracker.enterApproval("awaiting-approval");
  tracker.leaveTurn("t");
  assert.equal(statuses.includes("idle"), false, "not settled while the gate is open");

  tracker.leaveApproval();

  assert.equal(statuses.at(-1), "idle", "the closing gate settles it, unprompted");
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

// ---------------------------------------------------------------------------
// Work evidence: an agent that keeps streaming after its prompt was answered.
//
// A pi session ran for an hour with `status: idle`, because pi-acp resolved
// `session/prompt` (a duplicate `agent_end`) while pi kept working. The app
// hides the working shimmer and the live dot whenever status is not `running`,
// so both went quiet while 6,147 work events streamed in.
// ---------------------------------------------------------------------------

test("work arriving while nothing is in flight re-enters running", () => {
  const { tracker, statuses } = makeTracker();
  const key = tracker.enterTurn();
  tracker.leaveTurn(key); // the prompt was answered early
  assert.deepEqual(statuses, ["running", "idle"]);

  tracker.noteWork();

  assert.deepEqual(statuses, ["running", "idle", "running"]);
  assert.equal(tracker.hasActiveTurns, true);
});

test("more work while already running emits nothing new", () => {
  const { tracker, statuses } = makeTracker();
  tracker.noteWork();
  tracker.noteWork();
  tracker.noteWork();
  assert.deepEqual(statuses, ["running"], "one transition, not one per token");
});

test("work during a real turn does not outlive it", () => {
  const { tracker, statuses } = makeTracker();
  const key = tracker.enterTurn();
  tracker.noteWork(); // no second turn: the real one is already open
  tracker.leaveTurn(key);
  assert.deepEqual(statuses, ["running", "idle"]);
});

test("the agent's own settle closes a turn opened by work evidence", () => {
  const { tracker, statuses } = makeTracker();
  tracker.noteWork();
  tracker.noteAgentSettled();
  assert.deepEqual(statuses, ["running", "idle"]);
});

test("a settle for a turn nobody opened emits nothing", () => {
  const { tracker, statuses } = makeTracker();
  tracker.noteAgentSettled();
  assert.deepEqual(statuses, []);
});

test("the agent's settle never cuts a real prompt turn short", () => {
  const { tracker, statuses } = makeTracker();
  const key = tracker.enterTurn();
  tracker.noteAgentSettled();
  assert.deepEqual(statuses, ["running"], "the prompt is still in flight");
  tracker.leaveTurn(key);
  assert.deepEqual(statuses, ["running", "idle"]);
});

test("no work turn is opened once the adapter has exited", () => {
  const exited = { value: true };
  const { tracker, statuses } = makeTracker(exited);
  tracker.noteWork();
  assert.deepEqual(statuses, []);
  assert.equal(tracker.hasActiveTurns, false);
});
