import assert from "node:assert/strict";
import { test } from "node:test";

import { cwdPidSet, MAX_ANCESTOR_DEPTH } from "./ancestors.js";
import type { ProcInfo } from "./proc.js";

function procs(rows: Array<[pid: number, ppid: number]>): Map<number, ProcInfo> {
  const m = new Map<number, ProcInfo>();
  for (const [pid, ppid] of rows) m.set(pid, { pid, ppid, command: `p${pid}` });
  return m;
}

test("includes each listener AND its ancestors (the pnpm→node blocker)", () => {
  // 200 (node, listens) is a child of 100 (pnpm, owns the worktree cwd).
  const table = procs([[100, 1], [200, 100]]);
  const set = cwdPidSet([200], table);
  assert.ok(set.has(200), "the listener itself");
  assert.ok(set.has(100), "its parent, so the cwd fallback is not dead code");
});

test("walks multiple generations up to the root", () => {
  const table = procs([[10, 5], [20, 10], [30, 20]]);
  const set = cwdPidSet([30], table);
  for (const pid of [10, 20, 30]) assert.ok(set.has(pid), `climbs to ${pid}`);
});

test("a ppid cycle (a→b→a) terminates, does not hang", () => {
  const table = procs([[1, 2], [2, 1]]);
  const set = cwdPidSet([1], table);
  assert.ok(set.has(1) && set.has(2));
});

test("depth is bounded by MAX_ANCESTOR_DEPTH", () => {
  // A long chain 0←1←2←…←N. From the deepest listener we climb at most MAX steps.
  const rows: Array<[number, number]> = [];
  const chainLength = MAX_ANCESTOR_DEPTH + 5;
  for (let i = 1; i <= chainLength; i++) rows.push([i, i - 1]);
  const table = procs(rows);
  const set = cwdPidSet([chainLength], table);
  // The listener plus MAX_ANCESTOR_DEPTH ancestors.
  assert.equal(set.size, MAX_ANCESTOR_DEPTH + 1);
});

test("a listener not in the table still appears (its own pid), no crash", () => {
  const set = cwdPidSet([999], procs([]));
  assert.deepEqual([...set], [999]);
});
