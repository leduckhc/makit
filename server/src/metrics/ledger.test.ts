import { test } from "node:test";
import assert from "node:assert/strict";

import { CpuLedger } from "./ledger.js";
import type { ProcLike } from "./tree.js";

function row(pid: number, cpuSeconds: number, comm = "proc"): ProcLike {
  return { pid, ppid: 0, rssBytes: 0, cpuSeconds, comm };
}

function table(rows: ProcLike[]): Map<number, ProcLike> {
  return new Map(rows.map((r) => [r.pid, r]));
}

test("observe returns the sum of cpuSeconds seen this tick", () => {
  const l = new CpuLedger();
  const t = table([row(1, 10), row(2, 5)]);
  assert.equal(l.observe(1, [1, 2], t), 15);
});

test("total stays monotonic across a vanished child (the ledger's whole point)", () => {
  const l = new CpuLedger();
  // Tick 1: root 1 plus a ripgrep child 2 that burned 5s.
  const t1 = table([row(1, 3), row(2, 5, "rg")]);
  const first = l.observe(1, [1, 2], t1);
  assert.equal(first, 8);

  // Tick 2: ripgrep exited; root itself advanced to 4s.
  const t2 = table([row(1, 4)]);
  const second = l.observe(1, [1], t2);

  // 4 (live root) + 5 (frozen credit for vanished child) = 9. Must not drop to 4.
  assert.equal(second, 9);
  assert.ok(second >= first, "total must never decrease");
});

test("pid reuse with a changed comm does not double-count the frozen credit", () => {
  const l = new CpuLedger();
  const t1 = table([row(1, 2), row(2, 5, "rg")]);
  l.observe(1, [1, 2], t1); // credits pid 2 (rg) = 5

  // pid 2 vanishes, total should carry the frozen 5.
  const gap = l.observe(1, [1], table([row(1, 2)]));
  assert.equal(gap, 7); // 2 live + 5 frozen

  // OS reuses pid 2 for an unrelated process "bash" with 1s.
  const t3 = table([row(1, 2), row(2, 1, "bash")]);
  const reused = l.observe(1, [1, 2], t3);
  // Frozen rg credit dropped; only live 2 + 1 = 3. Not 8.
  assert.equal(reused, 3);
});

test("two roots are tracked independently and do not contaminate", () => {
  const l = new CpuLedger();
  const ta = table([row(1, 10), row(2, 4, "rg")]);
  const tb = table([row(3, 100), row(4, 40, "rg")]);
  assert.equal(l.observe(1, [1, 2], ta), 14);
  assert.equal(l.observe(3, [3, 4], tb), 140);

  // Children vanish from both.
  assert.equal(l.observe(1, [1], table([row(1, 10)])), 14); // 10 + frozen 4
  assert.equal(l.observe(3, [3], table([row(3, 100)])), 140); // 100 + frozen 40
});

test("unknown root observed with no pids returns 0", () => {
  const l = new CpuLedger();
  assert.equal(l.observe(7, [], new Map()), 0);
});
