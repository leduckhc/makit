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

test("pid reuse is counted once and never lowers the total (review finding)", () => {
  const l = new CpuLedger();
  const t1 = table([row(1, 2), row(2, 5, "rg")]);
  l.observe(1, [1, 2], t1); // credits pid 2 (rg) = 5

  // pid 2 vanishes: its final 5s is banked, so the total carries it.
  const gap = l.observe(1, [1], table([row(1, 2)]));
  assert.equal(gap, 7); // 2 live + 5 banked

  // OS reuses pid 2 for an unrelated process "bash" with 1s of its own.
  const t3 = table([row(1, 2), row(2, 1, "bash")]);
  const reused = l.observe(1, [1, 2], t3);
  // 5 (banked rg) + 2 (root) + 1 (new bash) = 8. The old rg CPU is neither lost
  // (which would drop the total and render a negative CPU%) nor counted twice.
  assert.equal(reused, 8);
  assert.ok(reused >= gap, "total must never decrease across pid reuse");
});

test("pid reuse while still visible (no gap tick) also never lowers the total", () => {
  const l = new CpuLedger();
  // Tick 1: child pid 2 is `rg` with 9s.
  const first = l.observe(1, [1, 2], table([row(1, 1), row(2, 9, "rg")]));
  assert.equal(first, 10);
  // Tick 2: pid 2 is now `bash` with 1s — reused without ever being absent.
  // Detected by BOTH the dropped cumulative time and the changed comm.
  const second = l.observe(1, [1, 2], table([row(1, 1), row(2, 1, "bash")]));
  assert.equal(second, 11); // 9 banked + 1 root + 1 new
  assert.ok(second >= first, "total must never decrease");
});

test("live tracking stays bounded as children churn (no slow leak)", () => {
  const l = new CpuLedger();
  // 200 ripgreps, one per tick, each exiting before the next appears.
  for (let i = 0; i < 200; i++) {
    const child = 1000 + i;
    l.observe(1, [1, child], table([row(1, 1), row(child, 0.5, "rg")]));
  }
  // Only the most recent tick's pids are retained, not all 200.
  assert.equal(l.trackedPids(1), 2, "live map must not grow with every pid ever seen");
  // ...and every one of those 200 half-seconds is still counted.
  const total = l.observe(1, [1], table([row(1, 1)]));
  assert.equal(total, 1 + 200 * 0.5);
});

test("dispose and retainOnly drop dead roots (no per-session leak)", () => {
  const l = new CpuLedger();
  l.observe(1, [1], table([row(1, 1)]));
  l.observe(2, [2], table([row(2, 1)]));
  l.observe(3, [3], table([row(3, 1)]));
  assert.equal(l.trackedRoots, 3);
  l.dispose(2);
  assert.equal(l.trackedRoots, 2);
  l.retainOnly([1]);
  assert.equal(l.trackedRoots, 1);
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
