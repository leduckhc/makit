import { test } from "node:test";
import assert from "node:assert/strict";

import { SelfProbe, type DelayHistogram } from "./self.js";

/** Records reset() calls and returns scripted percentile values (in ns). */
function fakeHistogram(scripts: Array<{ p50: number; p99: number }>): {
  hist: DelayHistogram;
  enableCount: () => number;
  resetCount: () => number;
} {
  let enables = 0;
  let resets = 0;
  let call = 0;
  const hist: DelayHistogram = {
    enable() {
      enables++;
    },
    reset() {
      resets++;
    },
    percentile(p: number): number {
      const s = scripts[Math.min(call, scripts.length - 1)];
      return p === 50 ? s.p50 : s.p99;
    },
  };
  return {
    hist,
    enableCount: () => enables,
    resetCount: () => resets,
  };
}

test("cpuPercent is null on the first sample (no baseline)", () => {
  const { hist } = fakeHistogram([{ p50: 0, p99: 0 }]);
  const probe = new SelfProbe({
    now: () => 1000,
    cpuUsage: () => ({ user: 0, system: 0 }),
    rss: () => 123,
    histogram: hist,
  });
  const s = probe.sample();
  assert.equal(s.cpuPercent, null);
  assert.equal(s.rssBytes, 123);
});

test("cpuPercent computes (user+system)µs / Δwall µs * 100", () => {
  let nowMs = 1000;
  // 200_000µs user + 100_000µs system over 1000ms(=1_000_000µs) => 30%.
  const cpuScript = [
    { user: 0, system: 0 },
    { user: 200_000, system: 100_000 },
  ];
  let call = 0;
  const { hist } = fakeHistogram([{ p50: 0, p99: 0 }]);
  const probe = new SelfProbe({
    now: () => nowMs,
    cpuUsage: () => cpuScript[Math.min(call++, cpuScript.length - 1)],
    rss: () => 0,
    histogram: hist,
  });
  probe.sample(); // baseline
  nowMs = 2000; // Δwall = 1000ms
  const s = probe.sample();
  assert.equal(s.cpuPercent, 30);
});

test("cpuPercent is null (not 0) when Δwall === 0", () => {
  let call = 0;
  const cpuScript = [
    { user: 0, system: 0 },
    { user: 5_000, system: 5_000 },
  ];
  const { hist } = fakeHistogram([{ p50: 0, p99: 0 }]);
  const probe = new SelfProbe({
    now: () => 1000, // never advances
    cpuUsage: () => cpuScript[Math.min(call++, cpuScript.length - 1)],
    rss: () => 0,
    histogram: hist,
  });
  probe.sample();
  const s = probe.sample();
  assert.equal(s.cpuPercent, null);
});

test("percentiles convert nanoseconds to milliseconds", () => {
  const { hist } = fakeHistogram([{ p50: 2_500_000, p99: 40_000_000 }]);
  const probe = new SelfProbe({
    now: () => 0,
    cpuUsage: () => ({ user: 0, system: 0 }),
    rss: () => 0,
    histogram: hist,
  });
  const s = probe.sample();
  assert.equal(s.loopDelayP50Ms, 2.5); // 2_500_000 ns
  assert.equal(s.loopDelayP99Ms, 40); // 40_000_000 ns
});

test("histogram is reset per window: consecutive samples do not share history", () => {
  // First window reads 5ms p99; second window reads 1ms p99. If reset were
  // missing, a real lifetime histogram would carry the 5ms spike forward.
  const { hist, enableCount, resetCount } = fakeHistogram([
    { p50: 1_000_000, p99: 5_000_000 },
    { p50: 500_000, p99: 1_000_000 },
  ]);
  // The fake advances its script on each reset() to model window isolation.
  let call = 0;
  const scripts = [
    { p50: 1_000_000, p99: 5_000_000 },
    { p50: 500_000, p99: 1_000_000 },
  ];
  const isolating: DelayHistogram = {
    enable: hist.enable,
    reset() {
      call++;
      hist.reset();
    },
    percentile(p: number): number {
      const s = scripts[Math.min(call, scripts.length - 1)];
      return p === 50 ? s.p50 : s.p99;
    },
  };
  const probe = new SelfProbe({
    now: () => 0,
    cpuUsage: () => ({ user: 0, system: 0 }),
    rss: () => 0,
    histogram: isolating,
  });
  const first = probe.sample();
  const second = probe.sample();
  assert.equal(first.loopDelayP99Ms, 5);
  assert.equal(second.loopDelayP99Ms, 1); // proves the window advanced via reset
  assert.equal(enableCount(), 1); // enabled exactly once, in the constructor
  assert.equal(resetCount(), 2); // reset once per sample
});
