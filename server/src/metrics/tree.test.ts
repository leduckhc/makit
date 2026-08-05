import { test } from "node:test";
import assert from "node:assert/strict";

import { childIndex, descendants, sumTree, type ProcLike } from "./tree.js";

function row(pid: number, ppid: number, rssBytes: number, cpuSeconds: number, comm = "proc"): ProcLike {
  return { pid, ppid, rssBytes, cpuSeconds, comm };
}

function table(rows: ProcLike[]): Map<number, ProcLike> {
  return new Map(rows.map((r) => [r.pid, r]));
}

test("childIndex maps each parent to its direct children", () => {
  const t = table([row(1, 0, 0, 0), row(2, 1, 0, 0), row(3, 1, 0, 0), row(4, 2, 0, 0)]);
  const idx = childIndex(t);
  assert.deepEqual(idx.get(1), [2, 3]);
  assert.deepEqual(idx.get(2), [4]);
  assert.equal(idx.get(3), undefined);
});

test("descendants returns a 3-level forest including the root", () => {
  // 1 -> 2 -> 4, 1 -> 3 -> 5
  const t = table([row(1, 0, 0, 0), row(2, 1, 0, 0), row(3, 1, 0, 0), row(4, 2, 0, 0), row(5, 3, 0, 0)]);
  const idx = childIndex(t);
  const d = descendants(idx, 1).sort((a, b) => a - b);
  assert.deepEqual(d, [1, 2, 3, 4, 5]);
});

test("descendants of a leaf is just itself", () => {
  const t = table([row(1, 0, 0, 0), row(2, 1, 0, 0)]);
  const idx = childIndex(t);
  assert.deepEqual(descendants(idx, 2), [2]);
});

test("descendants is cycle-safe (ppid cycle does not hang or duplicate)", () => {
  // 1 -> 2 -> 3 -> 1 (impossible in reality, fatal if unguarded)
  const t = table([row(1, 3, 0, 0), row(2, 1, 0, 0), row(3, 2, 0, 0)]);
  const idx = childIndex(t);
  const d = descendants(idx, 1).sort((a, b) => a - b);
  assert.deepEqual(d, [1, 2, 3]);
});

test("sumTree totals rss and proc count over the whole tree", () => {
  const t = table([
    row(1, 0, 100, 1),
    row(2, 1, 200, 2),
    row(3, 1, 300, 3),
    row(4, 2, 400, 4),
  ]);
  const idx = childIndex(t);
  assert.deepEqual(sumTree(t, idx, 1), { rssBytes: 1000, procs: 4 });
});

test("orphan root (ppid not in table) sums only itself", () => {
  const t = table([row(99, 42, 500, 7)]); // ppid 42 absent
  const idx = childIndex(t);
  assert.deepEqual(sumTree(t, idx, 99), { rssBytes: 500, procs: 1 });
});

test("unknown root yields zeros, never a throw", () => {
  const t = table([row(1, 0, 100, 1)]);
  const idx = childIndex(t);
  assert.deepEqual(descendants(idx, 12345), [12345]);
  assert.deepEqual(sumTree(t, idx, 12345), { rssBytes: 0, procs: 0 });
});

test("an unknown root that is an orphan's ppid must NOT absorb that orphan (review finding)", () => {
  // pid 200 was reparented: its ppid 999 is not in the table. Asking for the tree
  // of the dead pid 999 previously walked the index and returned pid 200's whole
  // subtree, attributing a stranger's memory to a dead agent.
  const t = table([row(200, 999, 5_000_000, 42, "rg")]);
  const idx = childIndex(t);
  assert.deepEqual(sumTree(t, idx, 999), { rssBytes: 0, procs: 0 });
});
